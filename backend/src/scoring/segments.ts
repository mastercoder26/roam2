import type { ParsedRoute, RouteStep } from "../types.js";
import { METERS_PER_MILE } from "./helpers.js";
import { isHighwayStep } from "./signals.js";

export interface RouteSegment {
  index: number;
  stepIndices: number[];
  distanceMeters: number;
  durationSeconds: number;
  staticDurationSeconds: number;
  maneuvers: string[];
  cumulativeTimeSeconds: number;
  /** Alias used by feature engineering */
  cumulativeSecondsFromStart: number;
  isHighway: boolean;
  impliedSpeedMph: number;
  polyline?: string;
}

const TARGET_DURATION_SEC = 60;
const MIN_DISTANCE_M = 800; // ~0.5 mi
const MAX_DISTANCE_M = 1609; // ~1.0 mi

function stepDuration(step: RouteStep): number {
  return step.staticDurationSeconds > 0
    ? step.staticDurationSeconds
    : Math.max(1, step.distanceMeters / 15);
}

function mergeSegment(
  acc: Omit<RouteSegment, "index">,
  step: RouteStep,
  stepIndex: number,
  stepSpeedMph?: number
): Omit<RouteSegment, "index"> {
  const duration = stepDuration(step);
  const maneuver = step.maneuver ?? "";
  const highway = isHighwayStep(step, stepSpeedMph);

  return {
    stepIndices: [...acc.stepIndices, stepIndex],
    distanceMeters: acc.distanceMeters + step.distanceMeters,
    durationSeconds: acc.durationSeconds + duration,
    staticDurationSeconds: acc.staticDurationSeconds + step.staticDurationSeconds,
    maneuvers:
      maneuver && maneuver !== "DEPART" && maneuver !== "STRAIGHT"
        ? [...acc.maneuvers, maneuver]
        : acc.maneuvers,
    cumulativeTimeSeconds: acc.cumulativeTimeSeconds,
    cumulativeSecondsFromStart: acc.cumulativeTimeSeconds,
    isHighway: acc.isHighway && highway,
    impliedSpeedMph: 0,
    polyline: acc.polyline ?? step.polyline,
  };
}

function finalizeSegment(
  partial: Omit<RouteSegment, "index">,
  index: number
): RouteSegment {
  const hours = partial.durationSeconds / 3600;
  const miles = partial.distanceMeters / METERS_PER_MILE;
  const impliedSpeedMph =
    hours > 0 ? miles / hours : partial.isHighway ? 65 : 25;

  return {
    index,
    ...partial,
    impliedSpeedMph,
    cumulativeSecondsFromStart: partial.cumulativeTimeSeconds,
  };
}

function shouldFlush(
  acc: Omit<RouteSegment, "index">,
  nextStep: RouteStep
): boolean {
  const nextDuration = stepDuration(nextStep);
  const wouldDuration = acc.durationSeconds + nextDuration;
  const wouldDistance = acc.distanceMeters + nextStep.distanceMeters;

  if (acc.distanceMeters === 0) return false;
  if (wouldDuration >= TARGET_DURATION_SEC * 1.5) return true;
  if (wouldDistance >= MAX_DISTANCE_M) return true;
  if (
    acc.durationSeconds >= TARGET_DURATION_SEC &&
    acc.distanceMeters >= MIN_DISTANCE_M
  ) {
    return true;
  }
  return false;
}

export function segmentRoute(
  routeOrSteps: ParsedRoute | RouteStep[],
  stepSpeedsMph?: Map<number, number>
): RouteSegment[] {
  const isRoute = !Array.isArray(routeOrSteps);
  const steps = isRoute ? routeOrSteps.steps : routeOrSteps;
  // Scale static step times by live/static ratio so night windows & density
  // reflect traffic-aware ETAs when available.
  const trafficScale =
    isRoute &&
    routeOrSteps.staticDurationSeconds > 0 &&
    routeOrSteps.durationSeconds > 0
      ? routeOrSteps.durationSeconds / routeOrSteps.staticDurationSeconds
      : 1;

  const segments: RouteSegment[] = [];
  let acc: Omit<RouteSegment, "index"> | null = null;
  let cumulativeTime = 0;
  let segmentIndex = 0;

  for (let i = 0; i < steps.length; i++) {
    const step = steps[i];
    if (step.distanceMeters <= 0) continue;

    const speed = stepSpeedsMph?.get(i);
    const scaledStep: RouteStep = {
      ...step,
      staticDurationSeconds: step.staticDurationSeconds,
    };
    // Apply traffic scale via a temporary duration override in merge.
    const liveDuration = stepDuration(step) * trafficScale;

    if (!acc) {
      acc = mergeSegment(
        {
          stepIndices: [],
          distanceMeters: 0,
          durationSeconds: 0,
          staticDurationSeconds: 0,
          maneuvers: [],
          cumulativeTimeSeconds: cumulativeTime,
          cumulativeSecondsFromStart: cumulativeTime,
          isHighway: true,
          impliedSpeedMph: 0,
        },
        scaledStep,
        i,
        speed
      );
      // Replace static-based duration with traffic-scaled duration.
      acc = {
        ...acc,
        durationSeconds: liveDuration,
      };
      continue;
    }

    if (shouldFlush(acc, step)) {
      segments.push(finalizeSegment(acc, segmentIndex++));
      cumulativeTime += acc.durationSeconds;
      acc = mergeSegment(
        {
          stepIndices: [],
          distanceMeters: 0,
          durationSeconds: 0,
          staticDurationSeconds: 0,
          maneuvers: [],
          cumulativeTimeSeconds: cumulativeTime,
          cumulativeSecondsFromStart: cumulativeTime,
          isHighway: true,
          impliedSpeedMph: 0,
        },
        scaledStep,
        i,
        speed
      );
      acc = { ...acc, durationSeconds: liveDuration };
    } else {
      const merged = mergeSegment(acc, scaledStep, i, speed);
      acc = {
        ...merged,
        durationSeconds: acc.durationSeconds + liveDuration,
      };
    }
  }

  if (acc && acc.distanceMeters > 0) {
    segments.push(finalizeSegment(acc, segmentIndex));
  }

  return segments;
}

export function scoreSegmentLocal(segment: RouteSegment): number {
  const miles = segment.distanceMeters / METERS_PER_MILE;
  const maneuverDensity =
    miles > 0 ? segment.maneuvers.length / miles : segment.maneuvers.length;

  let score = 0.08;
  score += Math.min(0.32, maneuverDensity * 0.13);

  const mergeCount = segment.maneuvers.filter(
    (m) => m === "MERGE" || m.startsWith("RAMP_")
  ).length;
  score += Math.min(0.35, mergeCount * 0.13);

  if (segment.impliedSpeedMph >= 60 && mergeCount === 0) score += 0.03;
  if (!segment.isHighway) score += 0.16;

  const leftTurns = segment.maneuvers.filter(
    (m) => m.startsWith("TURN_") && m.includes("LEFT")
  ).length;
  score += Math.min(0.22, leftTurns * 0.09);

  const sharpTurns = segment.maneuvers.filter(
    (m) => m.includes("SHARP") || m.startsWith("UTURN")
  ).length;
  score += Math.min(0.22, sharpTurns * 0.11);

  const turnCount = segment.maneuvers.filter(
    (m) =>
      m.startsWith("TURN_") ||
      m.startsWith("FORK_") ||
      m.startsWith("ROUNDABOUT_") ||
      m.startsWith("UTURN_")
  ).length;
  if (turnCount >= 2 && miles < 0.3) {
    score += Math.min(0.2, turnCount * 0.07);
  }

  return Math.max(0, Math.min(1, score));
}

export const SEGMENT_AGGREGATE_WEIGHTS = {
  mean: 0.55,
  p90: 0.25,
  max: 0.2,
} as const;

export interface SegmentAggregateResult {
  mean: number;
  p90: number;
  max: number;
  aggregated: number;
}

function percentile(values: number[], p: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.min(
    sorted.length - 1,
    Math.max(0, Math.ceil(p * sorted.length) - 1)
  );
  return sorted[idx];
}

export function aggregateSegmentScores(
  segmentScores: number[]
): SegmentAggregateResult;
export function aggregateSegmentScores(
  segments: RouteSegment[]
): SegmentAggregateResult;
export function aggregateSegmentScores(
  input: number[] | RouteSegment[]
): SegmentAggregateResult {
  const scores =
    input.length > 0 && typeof input[0] === "number"
      ? (input as number[])
      : (input as RouteSegment[]).map(scoreSegmentLocal);

  if (scores.length === 0) {
    return { mean: 0, p90: 0, max: 0, aggregated: 0 };
  }

  const mean = scores.reduce((a, b) => a + b, 0) / scores.length;
  const p90 = percentile(scores, 0.9);
  const max = Math.max(...scores);
  const aggregated =
    SEGMENT_AGGREGATE_WEIGHTS.mean * mean +
    SEGMENT_AGGREGATE_WEIGHTS.p90 * p90 +
    SEGMENT_AGGREGATE_WEIGHTS.max * max;

  return { mean, p90, max, aggregated };
}

export function aggregateMeanOnly(segmentScores: number[]): number {
  if (segmentScores.length === 0) return 0;
  return segmentScores.reduce((a, b) => a + b, 0) / segmentScores.length;
}
