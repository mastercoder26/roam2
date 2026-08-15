import type { RouteStep } from "../types.js";
import { METERS_PER_MILE, smoothstep } from "./helpers.js";

// --- Highway ---

// Matches interstate, US routes, and all 50 state abbreviation highway codes
const HIGHWAY_INSTRUCTION_RE =
  /\b(I-\d+|Interstate\s*\d+|US\s*-?\s*\d+|US\s*Hwy\s*\d+|(?:AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY)-\d+|State\s*(?:Hwy|Route|Rd)\s*\d+|Hwy|Highway|Freeway|Expressway|Motorway|Turnpike|Tollway|Beltway|Bypass)\b/i;

const RAMP_MANEUVERS = new Set(["RAMP_LEFT", "RAMP_RIGHT", "MERGE"]);
const STRAIGHT_MANEUVERS = new Set(["STRAIGHT", "NAME_CHANGE"]);

// Proportion of highway share that counts as baseline "high-speed alertness" difficulty.
// Even on a straight highway, 70 mph driving demands sustained attention.
const HIGHWAY_SPEED_BASELINE = 0.3;

export interface HighwayResult {
  highwayShare: number;
  subscore: number;
}

export function isHighwayStep(
  step: RouteStep,
  stepSpeedMph?: number
): boolean {
  if (step.navigationInstruction && HIGHWAY_INSTRUCTION_RE.test(step.navigationInstruction)) {
    return true;
  }

  const maneuver = step.maneuver ?? "";
  if (RAMP_MANEUVERS.has(maneuver) && step.distanceMeters >= 500) {
    return true;
  }

  if (STRAIGHT_MANEUVERS.has(maneuver) && step.distanceMeters >= 2000) {
    return true;
  }

  if (stepSpeedMph !== undefined && stepSpeedMph >= 55) {
    return true;
  }

  return false;
}

export function computeHighwayShare(
  steps: RouteStep[],
  stepSpeedsMph?: Map<number, number>
): HighwayResult {
  let totalMeters = 0;
  let highwayMeters = 0;

  steps.forEach((step, index) => {
    const distance = step.distanceMeters;
    if (distance <= 0) return;

    totalMeters += distance;
    const speed = stepSpeedsMph?.get(index);
    if (isHighwayStep(step, speed)) {
      highwayMeters += distance;
    }
  });

  const highwayShare = totalMeters > 0 ? highwayMeters / totalMeters : 0;

  // U-shape: pure local roads = max difficulty (1.0), pure highway = baseline
  // difficulty for high-speed sustained driving (0.3), mixed = higher of the two.
  const subscore = Math.max(1 - highwayShare, highwayShare * HIGHWAY_SPEED_BASELINE);

  return { highwayShare, subscore };
}


// --- Maneuvers ---

export interface ManeuverResult {
  weightedCount: number;
  maneuversPer10Mi: number;
  subscore: number;
}

const MANEUVER_EXCLUDED = new Set(["DEPART", "STRAIGHT", "NAME_CHANGE"]);

const MANEUVER_WEIGHTS: Record<string, number> = {
  TURN_SHARP_LEFT: 2.4,
  TURN_SHARP_RIGHT: 2.0,
  UTURN_LEFT: 2.3,
  UTURN_RIGHT: 2.1,
  ROUNDABOUT_LEFT: 2.0,
  ROUNDABOUT_RIGHT: 2.0,
  ROUNDABOUT_STRAIGHT: 1.6,
  ROUNDABOUT_U_TURN: 2.2,
  TURN_LEFT: 1.9,
  TURN_RIGHT: 1.2,
  FORK_LEFT: 1.6,
  FORK_RIGHT: 1.4,
  TURN_SLIGHT_LEFT: 1.15,
  TURN_SLIGHT_RIGHT: 0.9,
  RAMP_LEFT: 1.15,
  RAMP_RIGHT: 1.0,
  MERGE: 1.2,
};

function maneuverWeight(maneuver: string): number {
  if (maneuver in MANEUVER_WEIGHTS) return MANEUVER_WEIGHTS[maneuver]!;
  if (maneuver.startsWith("TURN_SHARP_LEFT")) return 2.4;
  if (maneuver.startsWith("TURN_SHARP_")) return 2.0;
  if (maneuver.startsWith("UTURN_LEFT")) return 2.3;
  if (maneuver.startsWith("UTURN_")) return 2.1;
  if (maneuver.startsWith("ROUNDABOUT_")) return 1.8;
  if (maneuver.startsWith("FORK_LEFT")) return 1.6;
  if (maneuver.startsWith("FORK_")) return 1.4;
  if (maneuver.startsWith("TURN_SLIGHT_LEFT")) return 1.15;
  if (maneuver.startsWith("TURN_SLIGHT_")) return 0.9;
  if (maneuver.startsWith("TURN_LEFT")) return 1.9;
  if (maneuver.startsWith("TURN_RIGHT")) return 1.2;
  if (maneuver.startsWith("RAMP_")) return 1.05;
  return 1.0;
}

export function computeManeuverComplexity(
  steps: RouteStep[],
  distanceMeters: number
): ManeuverResult {
  let weightedCount = 0;

  for (const step of steps) {
    const maneuver = step.maneuver ?? "";
    if (!maneuver || MANEUVER_EXCLUDED.has(maneuver)) continue;
    weightedCount += maneuverWeight(maneuver);
  }

  const distanceMiles = distanceMeters / METERS_PER_MILE;
  // Floor distance so tiny hops don't look like dense urban grids
  const rateMiles = Math.max(distanceMiles, 10);
  const maneuversPer10Mi =
    rateMiles > 0 ? weightedCount / (rateMiles / 10) : 0;
  // 6 weighted maneuvers per 10 miles marks dense urban complexity.
  const subscore = smoothstep(maneuversPer10Mi / 6);

  return { weightedCount, maneuversPer10Mi, subscore };
}

// --- Merge burden ---

export interface MergeBurdenResult {
  mergeCount: number;
  weaveCount: number;
  rampCount: number;
  exponentialSpacing: number;
  mergeClusterCount: number;
  rampDensity: number;
  interchangeDensity: number;
  weaveScore: number;
  weaveSectionScore: number;
  subscore: number;
}

/** Distance decay constant (meters) for merge spacing penalty. */
export const MERGE_TAU_METERS = 800;

export const MERGE_COEFFICIENTS = {
  b1: 0.18,
  b2: 0.22,
  b3: 0.35,
  b4: 0.15,
  b5: 0.1,
} as const;

const MERGE_MANEUVERS = new Set(["MERGE", "RAMP_LEFT", "RAMP_RIGHT"]);
const WEAVE_WINDOW_METERS = 500;

interface MergeEvent {
  distanceMeters: number;
  maneuver: string;
}

function collectMergeEvents(steps: RouteStep[]): MergeEvent[] {
  const events: MergeEvent[] = [];
  let cumulative = 0;

  for (const step of steps) {
    cumulative += step.distanceMeters;
    const maneuver = step.maneuver ?? "";
    if (MERGE_MANEUVERS.has(maneuver)) {
      events.push({ distanceMeters: cumulative, maneuver });
    }
  }

  return events;
}

function countWeaves(events: MergeEvent[]): number {
  let weaves = 0;
  for (let i = 1; i < events.length; i++) {
    const gap = events[i].distanceMeters - events[i - 1].distanceMeters;
    if (gap <= WEAVE_WINDOW_METERS) weaves++;
  }
  return weaves;
}

function countMergeClusters(events: MergeEvent[]): number {
  if (events.length < 2) return 0;

  let clusters = 0;
  let clusterSize = 1;

  for (let i = 1; i < events.length; i++) {
    const gap = events[i].distanceMeters - events[i - 1].distanceMeters;
    if (gap > WEAVE_WINDOW_METERS * 2) {
      if (clusterSize >= 2) clusters++;
      clusterSize = 1;
    } else {
      clusterSize++;
    }
  }
  if (clusterSize >= 2) clusters++;

  return clusters;
}

function mergeExponentialSpacingSum(events: MergeEvent[], tau: number): number {
  if (events.length <= 1) return events.length;

  let sum = 0;
  for (let i = 1; i < events.length; i++) {
    const d = events[i].distanceMeters - events[i - 1].distanceMeters;
    sum += Math.exp(-d / tau);
  }
  return sum + 1;
}

export function computeMergeBurden(
  steps: RouteStep[],
  distanceMeters: number,
  trafficRatio: number
): MergeBurdenResult {
  const delayRatio = Math.max(0, trafficRatio - 1);
  const events = collectMergeEvents(steps);
  const mergeCount = events.filter((e) => e.maneuver === "MERGE").length;
  const rampCount = events.filter((e) => e.maneuver.startsWith("RAMP_")).length;
  const weaveCount = countWeaves(events);
  const mergeClusterCount = countMergeClusters(events);
  const exponentialSpacing = mergeExponentialSpacingSum(events, MERGE_TAU_METERS);

  const distanceMiles = distanceMeters / METERS_PER_MILE;
  const rampDensity = distanceMiles > 0 ? (mergeCount + rampCount) / distanceMiles : 0;
  const interchangeDensity = rampDensity;
  const weaveScore = smoothstep(weaveCount / 4);
  const mergeTraffic = smoothstep(delayRatio / 0.25);

  const raw =
    MERGE_COEFFICIENTS.b1 * mergeCount +
    MERGE_COEFFICIENTS.b2 * weaveCount +
    MERGE_COEFFICIENTS.b3 * exponentialSpacing +
    MERGE_COEFFICIENTS.b4 * rampDensity * 6 +
    MERGE_COEFFICIENTS.b5 * mergeTraffic;

  const subscore = smoothstep(raw / 2.5);

  return {
    mergeCount,
    weaveCount,
    rampCount,
    exponentialSpacing,
    mergeClusterCount,
    rampDensity,
    interchangeDensity,
    weaveScore,
    weaveSectionScore: weaveScore,
    subscore,
  };
}

// --- Turn clustering ---

export interface TurnClusterResult {
  turnCount: number;
  closeTurnPairs: number;
  turnClusterCount: number;
  exponentialSpacing: number;
  turnSpacingPressure: number;
  peakDecisionsPerMile: number;
  sharpTurnCount: number;
  subscore: number;
}

/** Turns within this distance count as close together. */
export const TURN_CLUSTER_WINDOW_METERS = 400;

/** Distance decay constant (meters) for turn spacing penalty. */
export const TURN_TAU_METERS = 600;

/** Gap beyond which a new turn cluster starts. */
export const TURN_CLUSTER_GAP_METERS = 800;

export const TURN_CLUSTER_COEFFICIENTS = {
  c1: 0.2,
  c2: 0.25,
  c3: 0.35,
  c4: 0.2,
} as const;

const TURN_EXCLUDED = new Set(["DEPART", "STRAIGHT", "NAME_CHANGE", "MERGE", "RAMP_LEFT", "RAMP_RIGHT"]);

interface TurnEvent {
  distanceMeters: number;
  maneuver: string;
  isSharp: boolean;
}

function isTurnManeuver(maneuver: string): boolean {
  if (!maneuver || TURN_EXCLUDED.has(maneuver)) return false;
  return (
    maneuver.startsWith("TURN_") ||
    maneuver.startsWith("FORK_") ||
    maneuver.startsWith("ROUNDABOUT_") ||
    maneuver.startsWith("UTURN_")
  );
}

function isSharpManeuver(maneuver: string): boolean {
  return (
    maneuver.includes("SHARP") ||
    maneuver.startsWith("UTURN_") ||
    maneuver.startsWith("ROUNDABOUT_")
  );
}

function collectTurnEvents(steps: RouteStep[]): TurnEvent[] {
  const events: TurnEvent[] = [];
  let cumulative = 0;

  for (const step of steps) {
    cumulative += step.distanceMeters;
    const maneuver = step.maneuver ?? "";
    if (isTurnManeuver(maneuver)) {
      events.push({
        distanceMeters: cumulative,
        maneuver,
        isSharp: isSharpManeuver(maneuver),
      });
    }
  }

  return events;
}

function countCloseTurnPairs(events: TurnEvent[]): number {
  let pairs = 0;
  for (let i = 1; i < events.length; i++) {
    const gap = events[i].distanceMeters - events[i - 1].distanceMeters;
    if (gap <= TURN_CLUSTER_WINDOW_METERS) pairs++;
  }
  return pairs;
}

function countTurnClusters(events: TurnEvent[]): number {
  if (events.length < 2) return 0;

  let clusters = 0;
  let clusterSize = 1;

  for (let i = 1; i < events.length; i++) {
    const gap = events[i].distanceMeters - events[i - 1].distanceMeters;
    if (gap > TURN_CLUSTER_GAP_METERS) {
      if (clusterSize >= 2) clusters++;
      clusterSize = 1;
    } else {
      clusterSize++;
    }
  }
  if (clusterSize >= 2) clusters++;

  return clusters;
}

function turnExponentialSpacingSum(events: TurnEvent[], tau: number): number {
  if (events.length <= 1) return events.length > 0 ? 0.5 : 0;

  let sum = 0;
  for (let i = 1; i < events.length; i++) {
    const d = events[i].distanceMeters - events[i - 1].distanceMeters;
    sum += Math.exp(-d / tau);
  }
  return sum;
}

function computePeakDecisionsPerMile(steps: RouteStep[]): number {
  const windowMeters = 800;
  const events: Array<{ distanceMeters: number }> = [];
  let cumulative = 0;

  for (const step of steps) {
    cumulative += step.distanceMeters;
    const maneuver = step.maneuver ?? "";
    if (maneuver && !TURN_EXCLUDED.has(maneuver)) {
      events.push({ distanceMeters: cumulative });
    }
  }

  if (events.length === 0) return 0;

  let maxDensity = 0;
  for (let i = 0; i < events.length; i++) {
    const windowStart = events[i].distanceMeters;
    const windowEnd = windowStart + windowMeters;
    let decisions = 0;
    for (let j = i; j < events.length; j++) {
      if (events[j].distanceMeters <= windowEnd) decisions++;
      else break;
    }
    const miles = windowMeters / METERS_PER_MILE;
    maxDensity = Math.max(maxDensity, decisions / miles);
  }

  return maxDensity;
}

export function computeTurnClustering(
  steps: RouteStep[],
  distanceMeters: number
): TurnClusterResult {
  const events = collectTurnEvents(steps);
  const turnCount = events.length;
  const closeTurnPairs = countCloseTurnPairs(events);
  const turnClusterCount = countTurnClusters(events);
  const exponentialSpacing = turnExponentialSpacingSum(events, TURN_TAU_METERS);
  const peakDecisionsPerMile = computePeakDecisionsPerMile(steps);
  const sharpTurnCount = events.filter((e) => e.isSharp).length;

  const distanceMiles = distanceMeters / METERS_PER_MILE;
  const turnDensity = distanceMiles > 0 ? turnCount / distanceMiles : 0;

  const turnSpacingPressure = smoothstep(
    (closeTurnPairs * 0.4 + exponentialSpacing * 0.3 + turnClusterCount * 0.5) / 3
  );

  const raw =
    TURN_CLUSTER_COEFFICIENTS.c1 * closeTurnPairs +
    TURN_CLUSTER_COEFFICIENTS.c2 * turnClusterCount +
    TURN_CLUSTER_COEFFICIENTS.c3 * exponentialSpacing +
    TURN_CLUSTER_COEFFICIENTS.c4 * smoothstep(turnDensity * 2);

  const subscore = smoothstep(raw / 1.7);

  return {
    turnCount,
    closeTurnPairs,
    turnClusterCount,
    exponentialSpacing,
    turnSpacingPressure,
    peakDecisionsPerMile,
    sharpTurnCount,
    subscore,
  };
}

// --- Speed helpers ---
const MPS_TO_MPH = 2.237;

export function impliedStepSpeedMph(step: RouteStep): number {
  if (step.staticDurationSeconds <= 0) return 0;
  return (step.distanceMeters / step.staticDurationSeconds) * MPS_TO_MPH;
}

export function speedLimitToMph(limit: number, unit?: "KPH" | "MPH"): number {
  if (unit === "KPH") return limit * 0.621371;
  return limit;
}

