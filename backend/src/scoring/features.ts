import type { Bounds, ParsedRoute } from "../types.js";
import type { RouteConditions } from "../enrichment/types.js";
import { METERS_PER_MILE, finiteOr, smoothstep } from "./helpers.js";
import {
  computeHighwayShare,
  isHighwayStep,
  computeManeuverComplexity,
  computeMergeBurden,
  computeTurnClustering,
} from "./signals.js";
import {
  aggregateSegmentScores,
  scoreSegmentLocal,
  segmentRoute,
  type RouteSegment,
  type SegmentAggregateResult,
} from "./segments.js";

export interface RouteFeatures {
  meanSpeedMph: number;
  maxSpeedMph: number;
  fractionAbove45Mph: number;
  fractionAbove60Mph: number;
  durationMinutes: number;
  durationHours: number;
  distanceMiles: number;
  stepCount: number;
  turnDensity: number;
  leftTurnCount: number;
  rampCount: number;
  mergeCount: number;
  interchangeDensity: number;
  exponentialSpacing: number;
  mergeClusterCount: number;
  weaveCount: number;
  weaveSectionScore: number;
  mergeBurdenSubscore: number;
  trafficRatio: number;
  trafficVariance: number;
  nighttimeShare: number;
  urbanShare: number;
  highwayShare: number;
  longestHighwaySegmentMiles: number;
  monotonyScore: number;
  decisionPointDensity: number;
  segmentP90Difficulty: number;
  segmentMaxDifficulty: number;
  segmentMeanDifficulty: number;
  segmentAggregated: number;
  laneChangeUrgency: number;
  turnClusterCount: number;
  closeTurnPairs: number;
  turnSpacingPressure: number;
  turnClusterSubscore: number;
  sharpTurnCount: number;
  maneuversPer10Mi: number;
  stepsPerMile: number;
  delayRatio: number;
  /** 0–1 combined weather severity at drive time (rain, snow, wind, fog, ice). */
  weatherSeverity: number;
  precipIntensity: number;
  snowRisk: number;
  windSeverity: number;
  lowVisibilityRisk: number;
  icyRisk: number;
  /** 0–1: how much of the route runs on small/narrow roads (higher = harder). */
  roadSizeScore: number;
  narrowRoadShare: number;
  majorRoadShare: number;
  unpavedShare: number;
  avgLanes: number;
  constructionZones: number;
  /** 0–1 normalized construction burden. */
  constructionSeverity: number;
  /** Left turns without signal/stop protection (crossing oncoming traffic). */
  unprotectedLeftTurns: number;
  /** 0–1 share of left turns that are unprotected. */
  unprotectedTurnShare: number;
}

export interface BuildFeaturesInput {
  route: ParsedRoute;
  segments: RouteSegment[];
  /** Pre-computed `scoreSegmentLocal` results, to avoid scoring twice. */
  segmentScores?: number[];
  stepSpeedsMph?: Map<number, number>;
  departureTime?: string;
  /** Local clock minutes supplied by the client (0 = midnight). */
  departureLocalMinutes?: number;
  conditions?: RouteConditions;
}

export function isValidDepartureLocalMinutes(
  value: unknown
): value is number {
  return (
    typeof value === "number" &&
    Number.isInteger(value) &&
    value >= 0 &&
    value < 24 * 60
  );
}

/**
 * Resolve a client-local clock for route timing. New clients always supply
 * `departureLocalMinutes`; the timestamp path is retained only so older
 * clients keep a deterministic, host-timezone-independent fallback.
 */
export function resolveDepartureLocalMinutes(
  departureLocalMinutes?: number,
  departureTime?: string
): number | undefined {
  if (isValidDepartureLocalMinutes(departureLocalMinutes)) {
    return departureLocalMinutes;
  }

  if (!departureTime) return undefined;
  const legacyDeparture = new Date(departureTime);
  if (Number.isNaN(legacyDeparture.getTime())) return undefined;

  return (
    legacyDeparture.getUTCHours() * 60 + legacyDeparture.getUTCMinutes()
  );
}

export interface SolarWindow {
  sunriseLocalMinutes: number;
  sunsetLocalMinutes: number;
  /**
   * True when sunrise/sunset could not be estimated and the conservative
   * fixed clock window is standing in. Callers that describe the result to a
   * user must say which basis they used rather than implying a real sunset.
   */
  usesClockFallback: boolean;
}

/** Conservative 8 PM–6 AM stand-in when solar position cannot be estimated. */
const FALLBACK_SOLAR_WINDOW: SolarWindow = {
  sunriseLocalMinutes: 6 * 60,
  sunsetLocalMinutes: 20 * 60,
  usesClockFallback: true,
};

const MINUTES_PER_DAY = 24 * 60;

/** Every IANA UTC offset is a whole multiple of 15 minutes. */
const UTC_OFFSET_GRANULARITY_MINUTES = 15;

function normalizeDayMinutes(value: number): number {
  return ((value % MINUTES_PER_DAY) + MINUTES_PER_DAY) % MINUTES_PER_DAY;
}

/**
 * Estimates local sunrise and sunset from the route midpoint and departure
 * date using NOAA's standard solar-position approximation. The client gives
 * both an absolute timestamp and local clock time, which lets us infer the
 * route's UTC offset without relying on the server's timezone.
 */
export function estimateSolarWindow(
  bounds: Bounds,
  departureTime?: string,
  departureLocalMinutes?: number
): SolarWindow {
  if (!departureTime || !isValidDepartureLocalMinutes(departureLocalMinutes)) {
    return FALLBACK_SOLAR_WINDOW;
  }

  const date = new Date(departureTime);
  if (Number.isNaN(date.getTime())) return FALLBACK_SOLAR_WINDOW;

  const latitude = (bounds.southwest.lat + bounds.northeast.lat) / 2;
  const longitude = (bounds.southwest.lng + bounds.northeast.lng) / 2;
  if (
    !Number.isFinite(latitude) ||
    !Number.isFinite(longitude) ||
    Math.abs(latitude) > 90 ||
    Math.abs(longitude) > 180
  ) {
    return FALLBACK_SOLAR_WINDOW;
  }

  const startOfYearUtc = Date.UTC(date.getUTCFullYear(), 0, 0);
  const dayOfYear = Math.floor((date.getTime() - startOfYearUtc) / 86_400_000);
  const utcMinutes = date.getUTCHours() * 60 + date.getUTCMinutes();
  // Every real UTC offset is a multiple of 15 minutes. Snapping absorbs minor
  // client clock skew between the timestamp and the local clock, which would
  // otherwise shift the estimated sunset by up to half an hour.
  let utcOffsetMinutes =
    Math.round((departureLocalMinutes - utcMinutes) / UTC_OFFSET_GRANULARITY_MINUTES) *
    UTC_OFFSET_GRANULARITY_MINUTES;
  if (utcOffsetMinutes > 12 * 60) utcOffsetMinutes -= MINUTES_PER_DAY;
  if (utcOffsetMinutes < -12 * 60) utcOffsetMinutes += MINUTES_PER_DAY;

  // `departureLocalMinutes` is authoritative for scoring, even if an older
  // client sent an unrelated or stale timestamp. Solar timing needs a real
  // location/timezone pairing, however, so use the deterministic clock
  // fallback rather than manufacturing a sunrise when they disagree wildly.
  const longitudeOffsetMinutes = Math.round(longitude / 15) * 60;
  if (Math.abs(utcOffsetMinutes - longitudeOffsetMinutes) > 3 * 60) {
    return FALLBACK_SOLAR_WINDOW;
  }

  const gamma = (2 * Math.PI / 365) * (dayOfYear - 1);
  const equationOfTime =
    229.18 *
    (0.000075 +
      0.001868 * Math.cos(gamma) -
      0.032077 * Math.sin(gamma) -
      0.014615 * Math.cos(2 * gamma) -
      0.040849 * Math.sin(2 * gamma));
  const declination =
    0.006918 -
    0.399912 * Math.cos(gamma) +
    0.070257 * Math.sin(gamma) -
    0.006758 * Math.cos(2 * gamma) +
    0.000907 * Math.sin(2 * gamma) -
    0.002697 * Math.cos(3 * gamma) +
    0.00148 * Math.sin(3 * gamma);
  const latitudeRadians = (latitude * Math.PI) / 180;
  const zenithRadians = (90.833 * Math.PI) / 180;
  const hourAngleCosine =
    (Math.cos(zenithRadians) - Math.sin(latitudeRadians) * Math.sin(declination)) /
    (Math.cos(latitudeRadians) * Math.cos(declination));
  if (hourAngleCosine < -1 || hourAngleCosine > 1) {
    return FALLBACK_SOLAR_WINDOW;
  }

  const hourAngleDegrees = (Math.acos(hourAngleCosine) * 180) / Math.PI;
  const solarNoonUtcMinutes = 720 - 4 * longitude - equationOfTime;
  return {
    sunriseLocalMinutes: normalizeDayMinutes(
      solarNoonUtcMinutes - 4 * hourAngleDegrees + utcOffsetMinutes
    ),
    sunsetLocalMinutes: normalizeDayMinutes(
      solarNoonUtcMinutes + 4 * hourAngleDegrees + utcOffsetMinutes
    ),
    usesClockFallback: false,
  };
}

export function isNightLocalMinute(
  localMinutes: number,
  solar: SolarWindow
): boolean {
  const minute = normalizeDayMinutes(localMinutes);
  return minute >= solar.sunsetLocalMinutes || minute < solar.sunriseLocalMinutes;
}

/**
 * Seconds from `localMinutes` until the next light/dark transition.
 *
 * Always strictly positive, so callers can walk a drive interval boundary by
 * boundary without risking a zero-length step that never terminates.
 */
export function secondsUntilSolarBoundary(
  localMinutes: number,
  solar: SolarWindow
): number {
  const minute = normalizeDayMinutes(localMinutes);
  const boundaryMinutes = isNightLocalMinute(minute, solar)
    ? minute < solar.sunriseLocalMinutes
      ? solar.sunriseLocalMinutes
      : MINUTES_PER_DAY + solar.sunriseLocalMinutes
    : solar.sunsetLocalMinutes;
  return Math.max(MIN_BOUNDARY_STEP_SECONDS, (boundaryMinutes - minute) * 60);
}

/**
 * Floor on a boundary step. A degenerate solar window (sunrise == sunset)
 * could otherwise yield a zero-second step and spin the walking loops below.
 */
const MIN_BOUNDARY_STEP_SECONDS = 0.001;

/** Exact overlap with the repeating local solar-night window. */
function nighttimeSecondsInInterval(
  startLocalMinutes: number,
  durationSeconds: number,
  solar: SolarWindow
): number {
  let remainingSeconds = Math.max(0, finiteOr(durationSeconds));
  let cursorMinutes = normalizeDayMinutes(startLocalMinutes);
  let nighttimeSeconds = 0;

  while (remainingSeconds > MIN_BOUNDARY_STEP_SECONDS) {
    const spanSeconds = Math.min(
      remainingSeconds,
      secondsUntilSolarBoundary(cursorMinutes, solar)
    );
    if (isNightLocalMinute(cursorMinutes, solar)) {
      nighttimeSeconds += spanSeconds;
    }
    remainingSeconds -= spanSeconds;
    cursorMinutes = normalizeDayMinutes(cursorMinutes + spanSeconds / 60);
  }

  return nighttimeSeconds;
}

function computeSpeedStats(
  route: ParsedRoute,
  stepSpeedsMph?: Map<number, number>
): Pick<
  RouteFeatures,
  "meanSpeedMph" | "maxSpeedMph" | "fractionAbove45Mph" | "fractionAbove60Mph"
> {
  let measuredMeters = 0;
  let weightedSpeed = 0;
  let maxSpeed = 0;
  let above45 = 0;
  let above60 = 0;

  route.steps.forEach((step, index) => {
    const distanceMeters = step.distanceMeters;
    if (!Number.isFinite(distanceMeters) || distanceMeters <= 0) return;

    const speed = stepSpeedMph(step, stepSpeedsMph?.get(index));
    // A step with no supplied speed and no usable static duration has no
    // speed evidence. Skip it rather than counting it as 0 mph, which would
    // drag the mean down and understate fast-road exposure.
    if (speed === undefined) return;

    measuredMeters += distanceMeters;
    weightedSpeed += speed * distanceMeters;
    maxSpeed = Math.max(maxSpeed, speed);
    if (speed >= 45) above45 += distanceMeters;
    if (speed >= 60) above60 += distanceMeters;
  });

  if (measuredMeters <= 0) {
    return {
      meanSpeedMph: 0,
      maxSpeedMph: 0,
      fractionAbove45Mph: 0,
      fractionAbove60Mph: 0,
    };
  }

  return {
    meanSpeedMph: weightedSpeed / measuredMeters,
    maxSpeedMph: maxSpeed,
    fractionAbove45Mph: above45 / measuredMeters,
    fractionAbove60Mph: above60 / measuredMeters,
  };
}

/** Resolved step speed in mph, or `undefined` when nothing supports one. */
function stepSpeedMph(
  step: ParsedRoute["steps"][number],
  suppliedSpeedMph: number | undefined
): number | undefined {
  if (suppliedSpeedMph !== undefined) {
    // A malformed posted-speed lookup must not become a NaN mean speed.
    return Number.isFinite(suppliedSpeedMph) && suppliedSpeedMph >= 0
      ? suppliedSpeedMph
      : undefined;
  }
  if (!Number.isFinite(step.staticDurationSeconds) || step.staticDurationSeconds <= 0) {
    return undefined;
  }
  return step.distanceMeters / METERS_PER_MILE / (step.staticDurationSeconds / 3600);
}

function longestHighwayRunMiles(
  route: ParsedRoute,
  stepSpeedsMph?: Map<number, number>
): number {
  let longest = 0;
  let current = 0;
  route.steps.forEach((step, i) => {
    if (isHighwayStep(step, stepSpeedsMph?.get(i))) {
      current += step.distanceMeters / METERS_PER_MILE;
      longest = Math.max(longest, current);
    } else {
      current = 0;
    }
  });
  return longest;
}

function computeNighttimeShare(
  segments: RouteSegment[],
  bounds: Bounds,
  departureLocalMinutes?: number,
  departureTime?: string
): number {
  if (segments.length === 0) return 0;
  const startLocalMinutes = resolveDepartureLocalMinutes(
    departureLocalMinutes,
    departureTime
  );
  if (startLocalMinutes === undefined) return 0;

  const solar = estimateSolarWindow(bounds, departureTime, startLocalMinutes);

  let nightSeconds = 0;
  let totalSeconds = 0;
  for (const seg of segments) {
    totalSeconds += seg.durationSeconds;
    nightSeconds += nighttimeSecondsInInterval(
      startLocalMinutes + seg.cumulativeSecondsFromStart / 60,
      seg.durationSeconds,
      solar
    );
  }
  return totalSeconds > 0 ? nightSeconds / totalSeconds : 0;
}

function computeDecisionPointDensity(segments: RouteSegment[]): number {
  const windowSeconds = 300;
  let maxDensity = 0;

  for (const seg of segments) {
    const windowStart = seg.cumulativeSecondsFromStart;
    const windowEnd = windowStart + windowSeconds;
    let decisions = 0;
    let miles = 0;

    for (const other of segments) {
      const segMid = other.cumulativeSecondsFromStart + other.durationSeconds / 2;
      if (segMid >= windowStart && segMid <= windowEnd) {
        decisions += other.maneuvers.length;
        miles += other.distanceMeters / METERS_PER_MILE;
      }
    }
    if (miles > 0) {
      maxDensity = Math.max(maxDensity, decisions / miles);
    }
  }
  return maxDensity;
}

function computeMonotony(
  highwayShare: number,
  longestHighwaySegmentMiles: number,
  durationHours: number
): number {
  if (highwayShare < 0.5) return 0;
  return Math.min(
    1,
    (longestHighwaySegmentMiles / 40) * 0.5 + (durationHours / 4) * 0.5
  );
}

/** Reference cruising speed used to normalize per-segment pace. */
const REFERENCE_SPEED_MPH = 55;

/**
 * Mean absolute deviation of per-segment pace, amplified by the route's
 * overall delay: an uneven route in heavy traffic is harder than the same
 * unevenness in free flow.
 *
 * The result is clamped to 0–1. Its consumers (`computeTrafficComponent`,
 * `computeRawScore`) all feed it through `smoothstep`, which clamps anyway,
 * but `trafficDemand` reports `trafficVariance * 0.65` directly — so letting
 * the raw value exceed 1 made the published demand intensity depend on how
 * far past saturation the amplifier had already pushed it.
 */
function computeTrafficVariance(
  segments: RouteSegment[],
  delayRatio: number
): number {
  if (segments.length === 0) return 0;

  const speedRatios = segments.map(
    (segment) => segment.impliedSpeedMph / REFERENCE_SPEED_MPH
  );
  const meanRatio =
    speedRatios.reduce((sum, ratio) => sum + ratio, 0) / speedRatios.length;
  const meanAbsoluteDeviation =
    speedRatios.reduce((sum, ratio) => sum + Math.abs(ratio - meanRatio), 0) /
    speedRatios.length;

  return Math.max(
    0,
    Math.min(1, finiteOr(meanAbsoluteDeviation) * (1 + delayRatio))
  );
}

function computeLaneChangeUrgency(segments: RouteSegment[]): number {
  let urgency = 0;
  for (const seg of segments) {
    const mergeLike = seg.maneuvers.filter(
      (m) => m === "MERGE" || m.startsWith("RAMP_") || m.startsWith("FORK_")
    ).length;
    if (mergeLike >= 2) urgency += 0.25;
    else if (mergeLike === 1 && seg.impliedSpeedMph >= 55) urgency += 0.15;
  }
  return Math.min(1, urgency / Math.max(1, segments.length * 0.08));
}

interface ConditionFeatures {
  weatherSeverity: number;
  precipIntensity: number;
  snowRisk: number;
  windSeverity: number;
  lowVisibilityRisk: number;
  icyRisk: number;
  roadSizeScore: number;
  narrowRoadShare: number;
  majorRoadShare: number;
  unpavedShare: number;
  avgLanes: number;
  constructionZones: number;
  constructionSeverity: number;
  unprotectedLeftTurns: number;
  unprotectedTurnShare: number;
}

function deriveConditionFeatures(
  conditions?: RouteConditions
): ConditionFeatures {
  const turns = conditions?.turns;

  // Without intersection-control data, stay neutral (0) so missing OSM does
  // not invent difficulty. Left-turn count still feeds the turn component.
  const unprotectedLeftTurns = turns?.available ? turns.unprotectedLeftTurns : 0;
  const unprotectedTurnShare = turns?.available ? turns.unprotectedTurnShare : 0;

  // A provider may return a partial/stale payload alongside `available: false`.
  // Treat every derived field as unavailable in that case — otherwise a stale
  // `snowRisk` on an unavailable payload would produce a "Snow or ice
  // expected" reason that reads as a verified forecast it never gave.
  const verifiedWeather = conditions?.weather?.available
    ? conditions.weather
    : undefined;
  const verifiedRoad = conditions?.road?.available ? conditions.road : undefined;
  const constructionZones = verifiedRoad?.constructionZones ?? 0;

  return {
    weatherSeverity: verifiedWeather?.severity ?? 0,
    precipIntensity: verifiedWeather?.precipIntensity ?? 0,
    snowRisk: verifiedWeather?.snowRisk ?? 0,
    windSeverity: verifiedWeather?.windSeverity ?? 0,
    lowVisibilityRisk: verifiedWeather?.lowVisibilityRisk ?? 0,
    icyRisk: verifiedWeather?.icyRisk ?? 0,
    roadSizeScore: verifiedRoad?.roadSizeScore ?? 0,
    narrowRoadShare: verifiedRoad?.narrowRoadShare ?? 0,
    majorRoadShare: verifiedRoad?.majorRoadShare ?? 0,
    unpavedShare: verifiedRoad?.unpavedShare ?? 0,
    avgLanes: verifiedRoad?.avgLanes ?? 0,
    constructionZones,
    constructionSeverity: smoothstep(constructionZones / 4),
    unprotectedLeftTurns,
    unprotectedTurnShare,
  };
}

export function buildFeatures(input: BuildFeaturesInput): RouteFeatures {
  const {
    route,
    segments,
    stepSpeedsMph,
    departureTime,
    departureLocalMinutes,
    conditions,
  } = input;
  const distanceMeters = Math.max(0, finiteOr(route.distanceMeters));
  const liveSeconds = Math.max(0, finiteOr(route.durationSeconds));
  const staticSeconds = Math.max(0, finiteOr(route.staticDurationSeconds));

  const speedStats = computeSpeedStats(route, stepSpeedsMph);
  const { highwayShare } = computeHighwayShare(route.steps, stepSpeedsMph);
  const maneuvers = computeManeuverComplexity(route.steps, distanceMeters);
  // Without a no-traffic baseline there is no measurable delay, so a ratio of
  // exactly 1 (no delay) is the only defensible assumption.
  const trafficRatio = staticSeconds > 0 ? liveSeconds / staticSeconds : 1;
  const delayRatio = Math.max(0, trafficRatio - 1);
  const merge = computeMergeBurden(route.steps, distanceMeters, trafficRatio);
  const turnCluster = computeTurnClustering(route.steps, distanceMeters);
  const segmentAgg: SegmentAggregateResult =
    input.segmentScores !== undefined
      ? aggregateSegmentScores(input.segmentScores)
      : aggregateSegmentScores(segments);

  let leftTurnCount = 0;
  for (const step of route.steps) {
    const m = step.maneuver ?? "";
    if (m.includes("LEFT") && m.startsWith("TURN")) leftTurnCount++;
  }

  const distanceMiles = distanceMeters / METERS_PER_MILE;
  // Prefer traffic-aware duration for length/effort; fall back to static.
  const durationSeconds = liveSeconds > 0 ? liveSeconds : staticSeconds;
  const durationHours = durationSeconds / 3600;
  const longestHighwaySegmentMiles = longestHighwayRunMiles(route, stepSpeedsMph);
  const urbanShare = 1 - highwayShare;
  const stepsPerMile = distanceMiles > 0 ? route.steps.length / distanceMiles : 0;
  const turnDensity = distanceMiles > 0 ? maneuvers.weightedCount / distanceMiles : 0;

  const trafficVariance = computeTrafficVariance(segments, delayRatio);

  return {
    ...speedStats,
    durationMinutes: durationSeconds / 60,
    durationHours,
    distanceMiles,
    stepCount: route.steps.length,
    turnDensity,
    leftTurnCount,
    rampCount: merge.rampCount,
    mergeCount: merge.mergeCount,
    interchangeDensity: merge.interchangeDensity,
    exponentialSpacing: merge.exponentialSpacing,
    mergeClusterCount: merge.mergeClusterCount,
    weaveCount: merge.weaveCount,
    weaveSectionScore: merge.weaveSectionScore,
    mergeBurdenSubscore: merge.subscore,
    trafficRatio,
    trafficVariance,
    nighttimeShare: computeNighttimeShare(
      segments,
      route.bounds,
      departureLocalMinutes,
      departureTime
    ),
    urbanShare,
    highwayShare,
    longestHighwaySegmentMiles,
    monotonyScore: computeMonotony(highwayShare, longestHighwaySegmentMiles, durationHours),
    decisionPointDensity: computeDecisionPointDensity(segments),
    segmentP90Difficulty: segmentAgg.p90,
    segmentMaxDifficulty: segmentAgg.max,
    segmentMeanDifficulty: segmentAgg.mean,
    segmentAggregated: segmentAgg.aggregated,
    laneChangeUrgency: computeLaneChangeUrgency(segments),
    turnClusterCount: turnCluster.turnClusterCount,
    closeTurnPairs: turnCluster.closeTurnPairs,
    turnSpacingPressure: turnCluster.turnSpacingPressure,
    turnClusterSubscore: turnCluster.subscore,
    sharpTurnCount: turnCluster.sharpTurnCount,
    maneuversPer10Mi: maneuvers.maneuversPer10Mi,
    stepsPerMile,
    delayRatio,
    ...deriveConditionFeatures(conditions),
  };
}


export function buildFeaturesFromRoute(
  route: ParsedRoute,
  options: {
    stepSpeedsMph?: Map<number, number>;
    departureTime?: string;
    departureLocalMinutes?: number;
    conditions?: RouteConditions;
  } = {}
): {
  segments: RouteSegment[];
  segmentScores: number[];
  features: RouteFeatures;
} {
  const segments = segmentRoute(route, options.stepSpeedsMph);
  const segmentScores = segments.map(scoreSegmentLocal);
  const features = buildFeatures({
    route,
    segments,
    segmentScores,
    stepSpeedsMph: options.stepSpeedsMph,
    departureTime: options.departureTime,
    departureLocalMinutes: options.departureLocalMinutes,
    conditions: options.conditions,
  });
  return { segments, segmentScores, features };
}
