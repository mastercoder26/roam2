import type {
  ParsedRoute,
  RouteDemand,
  RouteDemandCoverageRange,
  RouteDemandId,
  RouteDemandMetrics,
  RouteStep,
} from "../types.js";
import type { RouteConditions } from "../enrichment/types.js";
import { METERS_PER_MILE } from "./helpers.js";
import { impliedStepSpeedMph } from "./signals.js";
import {
  buildPolylineGeometry,
  projectPointOntoPolyline,
  type PolylineGeometry,
} from "../utils/polyline.js";
import {
  estimateSolarWindow,
  isNightLocalMinute,
  resolveDepartureLocalMinutes,
  secondsUntilSolarBoundary,
  type RouteFeatures,
  type SolarWindow,
} from "./features.js";

interface DemandDetails {
  metrics?: RouteDemandMetrics;
  coverageRanges?: RouteDemandCoverageRange[];
}

interface RouteStepSpan {
  step: RouteStep;
  startSeconds: number;
  durationSeconds: number;
  speedMph: number;
  /** Present only when the step was verified against overview geometry. */
  coverageRange?: RouteDemandCoverageRange;
}

interface VerifiedRouteGeometry {
  overview: PolylineGeometry;
  stepRangesByIndex: Map<number, RouteDemandCoverageRange>;
}

const MAX_GEOMETRY_OFFSET_METERS = 75;
const STEP_BOUNDARY_TOLERANCE_METERS = 120;

function clamp01(value: number): number {
  return Math.max(0, Math.min(1, value));
}

function roundedIntensity(value: number): number {
  return Math.round(clamp01(value) * 100) / 100;
}

function levelFor(intensity: number): RouteDemand["level"] {
  if (intensity >= 0.67) return "high";
  if (intensity >= 0.34) return "moderate";
  return "low";
}

function demand(
  id: RouteDemandId,
  title: string,
  intensity: number,
  evidence: string,
  available: boolean,
  details: DemandDetails = {}
): RouteDemand {
  const normalized = available ? roundedIntensity(intensity) : 0;
  const metrics = sanitizedMetrics(details.metrics);
  const coverageRanges =
    details.coverageRanges === undefined
      ? undefined
      : normalizeCoverageRanges(details.coverageRanges);
  return {
    id,
    title,
    intensity: normalized,
    level: levelFor(normalized),
    evidence,
    available,
    ...(metrics ? { metrics } : {}),
    ...(coverageRanges !== undefined ? { coverageRanges } : {}),
  };
}

/** Keep the public payload factual even if an upstream source is malformed. */
function sanitizedMetrics(
  metrics: RouteDemandMetrics | undefined
): RouteDemandMetrics | undefined {
  if (!metrics) return undefined;
  const entries = Object.entries(metrics).filter(
    ([, value]) => Number.isFinite(value)
  );
  return entries.length > 0 ? Object.fromEntries(entries) : undefined;
}

function normalizeCoverageRanges(
  ranges: RouteDemandCoverageRange[]
): RouteDemandCoverageRange[] {
  const normalized = ranges
    .map((range) => ({
      startFraction: clamp01(range.startFraction),
      endFraction: clamp01(range.endFraction),
    }))
    .filter((range) => range.endFraction > range.startFraction)
    .sort((lhs, rhs) => lhs.startFraction - rhs.startFraction);

  const merged: RouteDemandCoverageRange[] = [];
  for (const range of normalized) {
    const previous = merged[merged.length - 1];
    if (previous && range.startFraction <= previous.endFraction + 0.000_001) {
      previous.endFraction = Math.max(previous.endFraction, range.endFraction);
    } else {
      merged.push({ ...range });
    }
  }

  // Stable, compact payloads keep tests and clients from depending on tiny
  // floating-point differences in decoded route geometry.
  return merged.map((range) => ({
    startFraction: Math.round(range.startFraction * 100_000) / 100_000,
    endFraction: Math.round(range.endFraction * 100_000) / 100_000,
  }));
}

function estimatedStepDurationSeconds(step: RouteStep): number {
  if (step.staticDurationSeconds > 0) return step.staticDurationSeconds;
  // This is only a fallback for timeline placement; a route with missing step
  // durations still has a verified step distance from the routing provider.
  return Math.max(1, step.distanceMeters / 15);
}

function sampledGeometryPoints(points: { lat: number; lng: number }[]): {
  lat: number;
  lng: number;
}[] {
  const limit = 32;
  if (points.length <= limit) return points;
  const step = (points.length - 1) / (limit - 1);
  return Array.from({ length: limit }, (_, index) =>
    points[Math.round(index * step)]
  );
}

/**
 * Verifies every positive-distance step against the route overview polyline
 * and records its progress in *overview-polyline geometric distance*. If even
 * one step cannot be mapped safely, callers omit structural coverage rather
 * than mixing step-meter fractions with client-side overview geometry.
 */
function verifiedRouteGeometry(route: ParsedRoute): VerifiedRouteGeometry | undefined {
  const overview = buildPolylineGeometry(route.polyline);
  if (!overview) return undefined;

  const positiveSteps = route.steps
    .map((step, index) => ({ step, index }))
    .filter(({ step }) => step.distanceMeters > 0);
  if (positiveSteps.length === 0) return undefined;

  const stepRangesByIndex = new Map<number, RouteDemandCoverageRange>();
  let previousEndMeters = 0;

  for (const { step, index } of positiveSteps) {
    const geometry = buildPolylineGeometry(step.polyline);
    if (!geometry) return undefined;

    const minimumProgress = Math.max(
      0,
      previousEndMeters - STEP_BOUNDARY_TOLERANCE_METERS
    );
    const projections = sampledGeometryPoints(geometry.points).map((point) =>
      projectPointOntoPolyline(point, overview, minimumProgress)
    );
    if (
      projections.some(
        (projection) =>
          !projection || projection.distanceMeters > MAX_GEOMETRY_OFFSET_METERS
      )
    ) {
      return undefined;
    }

    const start = projections[0]!;
    const end = projections[projections.length - 1]!;
    if (
      start.distanceAlongMeters > previousEndMeters + STEP_BOUNDARY_TOLERANCE_METERS ||
      end.distanceAlongMeters <= start.distanceAlongMeters ||
      end.distanceAlongMeters < previousEndMeters - STEP_BOUNDARY_TOLERANCE_METERS
    ) {
      return undefined;
    }

    // The step should advance along the same overview geometry. A point that
    // jumps backward materially would make a progress fraction ambiguous at a
    // loop or crossing, so omit all structural ranges for that route.
    let furthestProgress = start.distanceAlongMeters;
    for (const projection of projections) {
      const value = projection!;
      if (value.distanceAlongMeters + STEP_BOUNDARY_TOLERANCE_METERS < furthestProgress) {
        return undefined;
      }
      furthestProgress = Math.max(furthestProgress, value.distanceAlongMeters);
    }

    const mappedLength = end.distanceAlongMeters - start.distanceAlongMeters;
    if (
      mappedLength < Math.max(5, geometry.totalMeters * 0.25) ||
      mappedLength > Math.max(200, geometry.totalMeters * 3)
    ) {
      return undefined;
    }

    stepRangesByIndex.set(index, {
      startFraction: start.fraction,
      endFraction: end.fraction,
    });
    previousEndMeters = end.distanceAlongMeters;
  }

  if (
    previousEndMeters < overview.totalMeters - STEP_BOUNDARY_TOLERANCE_METERS ||
    stepRangesByIndex.get(positiveSteps[0].index)!.startFraction * overview.totalMeters >
      STEP_BOUNDARY_TOLERANCE_METERS
  ) {
    return undefined;
  }

  return { overview, stepRangesByIndex };
}

/**
 * Build a route timeline from provider steps. Timing and factual metrics keep
 * their provider-step source, while optional coverage ranges use only the
 * separately verified overview-polyline geometry.
 */
function routeStepSpans(
  route: ParsedRoute,
  stepSpeedsMph?: Map<number, number>,
  coverage?: VerifiedRouteGeometry
): RouteStepSpan[] {
  const positiveSteps = route.steps
    .map((step, index) => ({ step, index }))
    .filter(({ step }) => step.distanceMeters > 0);
  const totalMeters = positiveSteps.reduce(
    (sum, { step }) => sum + step.distanceMeters,
    0
  );
  if (totalMeters <= 0) return [];

  const trafficScale =
    route.durationSeconds > 0 && route.staticDurationSeconds > 0
      ? route.durationSeconds / route.staticDurationSeconds
      : 1;
  let cumulativeSeconds = 0;

  return positiveSteps.map(({ step, index }) => {
    const durationSeconds = estimatedStepDurationSeconds(step) * trafficScale;
    const suppliedSpeed = stepSpeedsMph?.get(index);
    const speedMph =
      suppliedSpeed !== undefined && Number.isFinite(suppliedSpeed)
        ? suppliedSpeed
        : impliedStepSpeedMph(step);
    const span: RouteStepSpan = {
      step,
      startSeconds: cumulativeSeconds,
      durationSeconds,
      speedMph,
      coverageRange: coverage?.stepRangesByIndex.get(index),
    };
    cumulativeSeconds += durationSeconds;
    return span;
  });
}

function hasVerifiedCoverage(spans: RouteStepSpan[]): boolean {
  return spans.length > 0 && spans.every((span) => span.coverageRange !== undefined);
}

function rangesForSpans(
  spans: RouteStepSpan[],
  predicate: (span: RouteStepSpan) => boolean
): RouteDemandCoverageRange[] | undefined {
  if (!hasVerifiedCoverage(spans)) return undefined;
  return normalizeCoverageRanges(
    spans
      .filter(predicate)
      .map((span) => span.coverageRange!)
  );
}

/**
 * A maneuver belongs near its routing-instruction boundary, not across an
 * entire (sometimes multi-mile) step. `collectMergeEvents` and turn-cluster
 * scoring both place the instruction at the end of its step, so use the same
 * convention here and retain only a small distance window around it.
 */
function rangesNearInstructionBoundaries(
  spans: RouteStepSpan[],
  predicate: (span: RouteStepSpan) => boolean,
  radiusMeters: number,
  overviewGeometry: PolylineGeometry | undefined
): RouteDemandCoverageRange[] | undefined {
  if (!overviewGeometry || !hasVerifiedCoverage(spans)) return undefined;
  const radiusFraction = radiusMeters / overviewGeometry.totalMeters;
  return normalizeCoverageRanges(
    spans
      .filter(predicate)
      .map((span) => ({
        startFraction: span.coverageRange!.endFraction - radiusFraction,
        endFraction: span.coverageRange!.endFraction + radiusFraction,
      }))
  );
}

function rangeShare(ranges: RouteDemandCoverageRange[]): number {
  return ranges.reduce(
    (sum, range) => sum + range.endFraction - range.startFraction,
    0
  );
}

function longestContiguousMeters(
  spans: RouteStepSpan[],
  predicate: (span: RouteStepSpan) => boolean
): number {
  let current = 0;
  let longest = 0;
  for (const span of spans) {
    if (predicate(span)) {
      current += span.step.distanceMeters;
      longest = Math.max(longest, current);
    } else {
      current = 0;
    }
  }
  return longest;
}

/**
 * Translate the locally scheduled after-dark window into validated overview
 * polyline fractions. Within a provider step we assume uniform progress; no
 * geometry or unsupported road attribution is invented.
 *
 * The window must be the *same* `SolarWindow` that produced
 * `features.nighttimeShare`. This used to be a hard-coded 8 PM–6 AM clock
 * check while the intensity beside it came from estimated sunrise/sunset, so
 * a summer evening drive could report 0% after-dark next to highlighted
 * after-dark geometry on the map.
 */
function afterDarkCoverageRanges(
  spans: RouteStepSpan[],
  departureLocalMinutes: number,
  solar: SolarWindow
): RouteDemandCoverageRange[] | undefined {
  if (!hasVerifiedCoverage(spans)) return undefined;
  const ranges: RouteDemandCoverageRange[] = [];

  for (const span of spans) {
    const coverage = span.coverageRange!;
    if (span.durationSeconds <= 0 || coverage.endFraction <= coverage.startFraction) {
      continue;
    }

    let elapsedInSpan = 0;
    while (elapsedInSpan < span.durationSeconds - 0.001) {
      const localMinutes =
        departureLocalMinutes + (span.startSeconds + elapsedInSpan) / 60;
      const remaining = span.durationSeconds - elapsedInSpan;
      const intervalSeconds = Math.min(
        remaining,
        secondsUntilSolarBoundary(localMinutes, solar)
      );
      if (isNightLocalMinute(localMinutes, solar)) {
        const distanceFraction = coverage.endFraction - coverage.startFraction;
        ranges.push({
          startFraction:
            coverage.startFraction +
            distanceFraction * (elapsedInSpan / span.durationSeconds),
          endFraction:
            coverage.startFraction +
            distanceFraction *
              ((elapsedInSpan + intervalSeconds) / span.durationSeconds),
        });
      }
      elapsedInSpan += intervalSeconds;
    }
  }

  return normalizeCoverageRanges(ranges);
}

function percent(value: number): string {
  return `${Math.round(clamp01(value) * 100)}%`;
}

function whole(value: number): string {
  return Math.round(value).toLocaleString("en-US");
}

function plural(count: number, singular: string, pluralForm = `${singular}s`): string {
  return `${whole(count)} ${Math.abs(count - 1) < 0.01 ? singular : pluralForm}`;
}

function hasRouteSteps(route: ParsedRoute): boolean {
  return route.steps.some((step) => step.distanceMeters > 0);
}

function intersectionInstructionCount(route: ParsedRoute): number {
  return route.steps.filter((step) => {
    const maneuver = step.maneuver ?? "";
    return (
      maneuver.startsWith("TURN_") ||
      maneuver.startsWith("FORK_") ||
      maneuver.startsWith("ROUNDABOUT_") ||
      maneuver.startsWith("UTURN_")
    );
  }).length;
}

function afterDarkDemand(
  route: ParsedRoute,
  features: RouteFeatures,
  spans: RouteStepSpan[],
  coverage: VerifiedRouteGeometry | undefined,
  departureLocalMinutes?: number,
  departureTime?: string
): RouteDemand {
  const localMinutes = resolveDepartureLocalMinutes(
    departureLocalMinutes,
    departureTime
  );
  if (localMinutes === undefined) {
    return demand(
      "afterDark",
      "After-dark driving",
      0,
      "Set a departure time to measure after-dark driving.",
      false
    );
  }

  // Same window the scored `nighttimeShare` was measured against, so the
  // number, the metrics, and the highlighted geometry cannot disagree.
  const solar = estimateSolarWindow(
    route.bounds,
    departureTime,
    localMinutes
  );
  const intensity = features.nighttimeShare;
  const expectedDurationSeconds =
    route.durationSeconds > 0
      ? route.durationSeconds
      : route.staticDurationSeconds;
  const coverageRanges = afterDarkCoverageRanges(spans, localMinutes, solar);
  const metrics: RouteDemandMetrics = {
    departureLocalMinutes: localMinutes,
    nighttimeShare: intensity,
    nighttimeDurationSeconds: expectedDurationSeconds * intensity,
    nightMiles: features.distanceMiles * intensity,
    expectedDurationSeconds,
    nighttimeCoverageFraction: intensity,
    sunriseLocalMinutes: solar.sunriseLocalMinutes,
    sunsetLocalMinutes: solar.sunsetLocalMinutes,
    ...(coverageRanges && coverage
      ? {
          overviewGeometryMeters: coverage.overview.totalMeters,
          verifiedOverviewNighttimeFraction: rangeShare(coverageRanges),
        }
      : {}),
  };

  const window = describeDarkWindow(solar);
  if (intensity <= 0.01) {
    return demand(
      "afterDark",
      "After-dark driving",
      intensity,
      `The scheduled departure keeps this drive outside ${window}.`,
      true,
      { metrics, coverageRanges }
    );
  }

  const period =
    intensity >= 0.99
      ? "The full drive"
      : `About ${percent(intensity)} of the drive`;
  return demand(
    "afterDark",
    "After-dark driving",
    intensity,
    `${period} falls ${window}.`,
    true,
    { metrics, coverageRanges }
  );
}

function formatLocalClock(localMinutes: number): string {
  const totalMinutes = Math.round(localMinutes) % (24 * 60);
  const hour24 = Math.floor(totalMinutes / 60);
  const minute = totalMinutes % 60;
  const hour12 = hour24 % 12 === 0 ? 12 : hour24 % 12;
  return `${hour12}:${String(minute).padStart(2, "0")} ${hour24 < 12 ? "AM" : "PM"}`;
}

/**
 * Name the window honestly. When solar position could not be estimated the
 * demand must not imply a computed sunset it never had.
 */
function describeDarkWindow(solar: SolarWindow): string {
  if (solar.usesClockFallback) {
    return "in the 8 PM–6 AM window used when sunset cannot be estimated";
  }
  return `after dark (about ${formatLocalClock(solar.sunsetLocalMinutes)} to ${formatLocalClock(solar.sunriseLocalMinutes)} locally)`;
}

function fastRoadsDemand(
  route: ParsedRoute,
  features: RouteFeatures,
  spans: RouteStepSpan[]
): RouteDemand {
  const available = hasRouteSteps(route);
  if (!available) {
    return demand(
      "fastRoads",
      "Fast roads",
      0,
      "Route speed information was unavailable.",
      false
    );
  }

  const intensity =
    features.fractionAbove45Mph * 0.55 + features.fractionAbove60Mph * 0.45;
  const coverageRanges = rangesForSpans(
    spans,
    (span) => span.speedMph >= 45
  );
  const estimated45PlusDistanceMeters = spans
    .filter((span) => span.speedMph >= 45)
    .reduce((sum, span) => sum + span.step.distanceMeters, 0);
  const estimated60PlusDistanceMeters = spans
    .filter((span) => span.speedMph >= 60)
    .reduce((sum, span) => sum + span.step.distanceMeters, 0);
  const estimated55PlusDistanceMeters = spans
    .filter((span) => span.speedMph >= 55)
    .reduce((sum, span) => sum + span.step.distanceMeters, 0);
  const estimated65PlusDistanceMeters = spans
    .filter((span) => span.speedMph >= 65)
    .reduce((sum, span) => sum + span.step.distanceMeters, 0);
  const metrics: RouteDemandMetrics = {
    estimatedMilesAt45: estimated45PlusDistanceMeters / METERS_PER_MILE,
    estimatedMilesAt55: estimated55PlusDistanceMeters / METERS_PER_MILE,
    estimatedMilesAt60: estimated60PlusDistanceMeters / METERS_PER_MILE,
    estimatedMilesAt65: estimated65PlusDistanceMeters / METERS_PER_MILE,
    estimated45PlusDistanceMeters,
    estimated55PlusDistanceMeters,
    estimated60PlusDistanceMeters,
    estimated65PlusDistanceMeters,
    estimated45PlusShare: features.fractionAbove45Mph,
    estimated60PlusShare: features.fractionAbove60Mph,
    meanEstimatedSpeedMph: features.meanSpeedMph,
    maxEstimatedSpeedMph: features.maxSpeedMph,
    longestEstimated45PlusRunMeters: longestContiguousMeters(
      spans,
      (span) => span.speedMph >= 45
    ),
  };
  if (features.fractionAbove45Mph <= 0.01) {
    return demand(
      "fastRoads",
      "Fast roads",
      intensity,
      "No route segments are estimated at 45 mph or faster.",
      true,
      { metrics, coverageRanges }
    );
  }

  const sixtyPlus =
    features.fractionAbove60Mph > 0.01
      ? `, including ${percent(features.fractionAbove60Mph)} at 60+ mph`
      : "";
  return demand(
    "fastRoads",
    "Fast roads",
    intensity,
    `${percent(features.fractionAbove45Mph)} of the route is estimated at 45+ mph${sixtyPlus}.`,
    true,
    { metrics, coverageRanges }
  );
}

function mergesDemand(
  route: ParsedRoute,
  features: RouteFeatures,
  spans: RouteStepSpan[],
  coverage: VerifiedRouteGeometry | undefined
): RouteDemand {
  const available = hasRouteSteps(route);
  if (!available) {
    return demand(
      "merges",
      "Merges and ramps",
      0,
      "Route maneuver information was unavailable.",
      false
    );
  }

  const transitions = features.mergeCount + features.rampCount;
  const intensity =
    features.mergeBurdenSubscore * 0.55 +
    Math.min(1, transitions / 4) * 0.25 +
    Math.min(1, features.weaveCount / 3) * 0.12 +
    Math.min(1, features.mergeClusterCount / 2) * 0.08;
  const coverageRanges = rangesNearInstructionBoundaries(
    spans,
    (span) => {
      const maneuver = span.step.maneuver ?? "";
      return (
        maneuver === "MERGE" ||
        maneuver === "RAMP_LEFT" ||
        maneuver === "RAMP_RIGHT"
      );
    },
    250,
    coverage?.overview
  );
  const metrics: RouteDemandMetrics = {
    mergeInstructionCount: features.mergeCount,
    rampInstructionCount: features.rampCount,
    mergeTransitionCount: transitions,
    weaveSectionCount: features.weaveCount,
    mergeClusterCount: features.mergeClusterCount,
    transitionDensityPerMile: features.interchangeDensity,
    ...(coverageRanges ? { coverageFraction: rangeShare(coverageRanges) } : {}),
  };

  if (transitions === 0) {
    return demand(
      "merges",
      "Merges and ramps",
      intensity,
      "No ramps or merges were detected in the route instructions.",
      true,
      { metrics, coverageRanges }
    );
  }

  const clusterDetail =
    features.mergeClusterCount > 0
      ? `, including ${plural(features.mergeClusterCount, "tight cluster")}`
      : "";
  const weaveDetail =
    features.weaveCount > 0
      ? ` and ${plural(features.weaveCount, "weave section")}`
      : "";
  return demand(
    "merges",
    "Merges and ramps",
    intensity,
    `${plural(transitions, "ramp or merge transition", "ramps or merge transitions")} appear in the route instructions${clusterDetail}${weaveDetail}.`,
    true,
    { metrics, coverageRanges }
  );
}

function complexIntersectionsDemand(
  route: ParsedRoute,
  features: RouteFeatures,
  conditions: RouteConditions | undefined,
  spans: RouteStepSpan[],
  coverage: VerifiedRouteGeometry | undefined
): RouteDemand {
  const available = hasRouteSteps(route);
  if (!available) {
    return demand(
      "complexIntersections",
      "Complex intersections",
      0,
      "Route maneuver information was unavailable.",
      false
    );
  }

  const intersections = intersectionInstructionCount(route);
  const structuralIntensity = Math.max(
    features.turnClusterSubscore,
    clamp01(features.maneuversPer10Mi / 12),
    clamp01(features.decisionPointDensity / 8)
  );
  const turns = conditions?.turns;
  const verifiedIntersectionControls = Boolean(
    turns?.available && conditions?.sources.includes("osm-overpass")
  );
  const protectedTurnIntensity = verifiedIntersectionControls && turns
    ? turns.unprotectedTurnShare * 0.25 +
      clamp01(turns.unprotectedLeftTurns / 6) * 0.2
    : 0;
  const intensity = Math.max(structuralIntensity, protectedTurnIntensity);
  const coverageRanges = rangesNearInstructionBoundaries(
    spans,
    (span) => {
      const maneuver = span.step.maneuver ?? "";
      return (
        maneuver.startsWith("TURN_") ||
        maneuver.startsWith("FORK_") ||
        maneuver.startsWith("ROUNDABOUT_") ||
        maneuver.startsWith("UTURN_")
      );
    },
    150,
    coverage?.overview
  );
  const metrics: RouteDemandMetrics = {
    intersectionInstructionCount: intersections,
    turnClusterCount: features.turnClusterCount,
    closeTurnPairCount: features.closeTurnPairs,
    sharpTurnInstructionCount: features.sharpTurnCount,
    decisionPointsPerMile: features.decisionPointDensity,
    ...(coverageRanges ? { coverageFraction: rangeShare(coverageRanges) } : {}),
    ...(verifiedIntersectionControls && turns
      ? {
          unprotectedLeftTurnCount: turns.unprotectedLeftTurns,
          protectedLeftTurnCount: turns.protectedLeftTurns,
          unprotectedLeftTurnShare: turns.unprotectedTurnShare,
        }
      : {}),
  };

  if (intersections === 0) {
    return demand(
      "complexIntersections",
      "Complex intersections",
      intensity,
      "No turn, fork, roundabout, or U-turn instructions were detected.",
      true,
      { metrics, coverageRanges }
    );
  }

  const clusterDetail =
    features.turnClusterCount > 0
      ? ` ${plural(features.turnClusterCount, "turn cluster")} contains closely spaced decisions.`
      : "";
  const unprotectedDetail =
    verifiedIntersectionControls && turns && turns.unprotectedLeftTurns > 0
      ? ` ${plural(turns.unprotectedLeftTurns, "unprotected left turn")} was identified from available intersection data.`
      : "";
  return demand(
    "complexIntersections",
    "Complex intersections",
    intensity,
    `${plural(intersections, "turn, fork, roundabout, or U-turn instruction", "turn, fork, roundabout, or U-turn instructions")} appear on this route.${clusterDetail}${unprotectedDetail}`,
    true,
    { metrics, coverageRanges }
  );
}

function weatherVisibilityDemand(conditions?: RouteConditions): RouteDemand {
  const weather = conditions?.weather;
  const available = Boolean(
    weather?.available && conditions?.sources.includes("open-meteo")
  );
  if (!available || !weather) {
    return demand(
      "weatherVisibility",
      "Weather and visibility",
      0,
      "Live weather and visibility data were unavailable, so they are not included.",
      false
    );
  }

  const intensity = Math.max(
    weather.severity,
    weather.lowVisibilityRisk,
    weather.windSeverity * 0.75,
    weather.snowRisk,
    weather.icyRisk
  );
  // Open-Meteo currently returns an aggregate across sampled ETA points. Keep
  // its factual scalar values, but omit coverageRanges rather than claiming
  // which exact distance fraction has rain, fog, or reduced visibility.
  const metrics: RouteDemandMetrics = {
    weatherSeverity: weather.severity,
    precipitationIntensity: weather.precipIntensity,
    snowRisk: weather.snowRisk,
    windSeverity: weather.windSeverity,
    lowVisibilityRisk: weather.lowVisibilityRisk,
    icyRisk: weather.icyRisk,
    visibilityMiles: weather.visibilityMiles,
    windGustMph: weather.windGustMph,
    temperatureF: weather.temperatureF,
  };
  const details = [weather.condition];
  if (weather.visibilityMiles > 0 && weather.visibilityMiles < 10) {
    details.push(`${weather.visibilityMiles.toFixed(1)} mi visibility`);
  }
  if (weather.windGustMph >= 25) {
    details.push(`${whole(weather.windGustMph)} mph gusts`);
  }
  return demand(
    "weatherVisibility",
    "Weather and visibility",
    intensity,
    `Live route weather: ${details.join("; ")}.`,
    true,
    { metrics }
  );
}

function sustainedDriveDemand(
  route: ParsedRoute,
  features: RouteFeatures,
  coverage: VerifiedRouteGeometry | undefined
): RouteDemand {
  const available = route.durationSeconds > 0 || route.staticDurationSeconds > 0;
  if (!available) {
    return demand(
      "sustainedDrive",
      "Sustained drive",
      0,
      "Route duration was unavailable.",
      false
    );
  }

  const intensity = clamp01((features.durationMinutes - 10) / 170);
  const expectedDurationSeconds =
    route.durationSeconds > 0
      ? route.durationSeconds
      : route.staticDurationSeconds;
  const metrics: RouteDemandMetrics = {
    expectedDurationSeconds,
    expectedDurationMinutes: expectedDurationSeconds / 60,
    routeDistanceMeters: route.distanceMeters,
    staticDurationSeconds: route.staticDurationSeconds,
    trafficDelaySeconds: Math.max(
      0,
      route.durationSeconds - route.staticDurationSeconds
    ),
  };
  return demand(
    "sustainedDrive",
    "Sustained drive",
    intensity,
    `Expected drive time is about ${whole(features.durationMinutes)} minutes.`,
    true,
    {
      metrics,
      // Duration is a whole-trip demand. The range is structural rather than
      // a claim that every moment is equally tiring.
      coverageRanges: coverage
        ? [{ startFraction: 0, endFraction: 1 }]
        : undefined,
    }
  );
}

function trafficDemand(route: ParsedRoute, features: RouteFeatures): RouteDemand {
  const available =
    route.durationSeconds > 0 && route.staticDurationSeconds > 0;
  if (!available) {
    return demand(
      "traffic",
      "Traffic",
      0,
      "Traffic-aware route timing was unavailable.",
      false
    );
  }

  const delaySeconds = Math.max(
    0,
    route.durationSeconds - route.staticDurationSeconds
  );
  const intensity = Math.max(
    clamp01(features.delayRatio / 0.45),
    clamp01(features.trafficVariance * 0.65)
  );
  const metrics: RouteDemandMetrics = {
    trafficDelaySeconds: delaySeconds,
    trafficDelayMinutes: delaySeconds / 60,
    trafficDelayFraction: features.delayRatio,
    trafficAwareDurationSeconds: route.durationSeconds,
    staticDurationSeconds: route.staticDurationSeconds,
    trafficRatio: features.trafficRatio,
  };
  if (delaySeconds < 60) {
    return demand(
      "traffic",
      "Traffic",
      intensity,
      "Traffic-aware timing is close to the route's no-traffic estimate.",
      true,
      { metrics }
    );
  }

  return demand(
    "traffic",
    "Traffic",
    intensity,
    `Traffic-aware timing is ${whole(delaySeconds / 60)} minutes (${percent(features.delayRatio)}) longer than the no-traffic estimate.`,
    true,
    { metrics }
  );
}

function roadConditionsDemand(conditions?: RouteConditions): RouteDemand {
  const road = conditions?.road;
  const osmRoadDataAvailable = Boolean(
    road?.available && conditions?.sources.includes("osm-overpass")
  );
  const routeWarningsSupportConstruction = Boolean(
    conditions?.sources.includes("google-route-warnings") &&
      road &&
      road.constructionZones > 0
  );
  const available = osmRoadDataAvailable || routeWarningsSupportConstruction;
  if (!available || !road) {
    return demand(
      "roadConditions",
      "Road conditions",
      0,
      "Road-surface and construction data were unavailable, so they are not included.",
      false
    );
  }

  const intensity = Math.max(
    road.roadSizeScore,
    road.narrowRoadShare,
    road.unpavedShare,
    clamp01(road.constructionZones / 4)
  );
  const metrics: RouteDemandMetrics = {
    constructionZoneCount: road.constructionZones,
    ...(osmRoadDataAvailable
      ? {
          roadSizeScore: road.roadSizeScore,
          averageLaneCount: road.avgLanes,
          narrowRoadShare: road.narrowRoadShare,
          majorRoadShare: road.majorRoadShare,
          unpavedRoadShare: road.unpavedShare,
          verifiedRoadSampleCount: Object.values(road.classCounts).reduce(
            (sum, count) => sum + count,
            0
          ),
        }
      : {}),
  };

  if (!osmRoadDataAvailable && routeWarningsSupportConstruction) {
    return demand(
      "roadConditions",
      "Road conditions",
      intensity,
      "The route provider reports construction or roadwork along this route.",
      true,
      { metrics }
    );
  }

  const details: string[] = [];
  if (road.constructionZones > 0) {
    details.push(`${plural(road.constructionZones, "reported construction zone")}`);
  }
  if (road.narrowRoadShare > 0.05) {
    details.push(`${percent(road.narrowRoadShare)} on smaller roads`);
  }
  if (road.unpavedShare > 0.05) {
    details.push(`${percent(road.unpavedShare)} unpaved`);
  }
  if (details.length === 0) {
    details.push("no notable narrow-road, unpaved, or construction exposure detected");
  }
  return demand(
    "roadConditions",
    "Road conditions",
    intensity,
    `Road data shows ${details.join("; ")}.`,
    true,
    { metrics }
  );
}

export interface BuildRouteDemandsOptions {
  departureTime?: string;
  departureLocalMinutes?: number;
  conditions?: RouteConditions;
  /** Posted/implied per-step speeds used by the scorer, when available. */
  stepSpeedsMph?: Map<number, number>;
}

/**
 * Build all demand categories in a fixed order so mobile clients can decode a
 * complete, stable readiness input even when live enrichment is unavailable.
 */
export function buildRouteDemands(
  route: ParsedRoute,
  features: RouteFeatures,
  options: BuildRouteDemandsOptions = {}
): RouteDemand[] {
  const coverage = verifiedRouteGeometry(route);
  const spans = routeStepSpans(route, options.stepSpeedsMph, coverage);
  return [
    afterDarkDemand(
      route,
      features,
      spans,
      coverage,
      options.departureLocalMinutes,
      options.departureTime
    ),
    fastRoadsDemand(route, features, spans),
    mergesDemand(route, features, spans, coverage),
    complexIntersectionsDemand(route, features, options.conditions, spans, coverage),
    weatherVisibilityDemand(options.conditions),
    sustainedDriveDemand(route, features, coverage),
    trafficDemand(route, features),
    roadConditionsDemand(options.conditions),
  ];
}
