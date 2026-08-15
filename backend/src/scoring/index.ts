import type {
  AlternateRoute,
  ParsedRoute,
  ScoredRoute,
  ScoringContext,
  ScoringOptions,
} from "../types.js";
import { MODEL_VERSION } from "../types.js";
import { scoreSegmentLocal, aggregateSegmentScores } from "./segments.js";
import { buildFeaturesFromRoute } from "./features.js";
import { buildRouteDemands } from "./demands.js";
import { computeBaseScore } from "./baseScore.js";
import { computeFatigue, computeRawScore } from "./fatigue.js";
import {
  buildBreakdown,
  buildHotspots,
  explainPrediction,
  generateReasons,
} from "./explain.js";
import {
  getCalibrator,
  applyUncertaintyBand,
  clampScore,
  estimateUncertainty,
  finiteOr,
  scoreToLabel,
} from "./helpers.js";
import { assessScoreEvidence } from "./certainty.js";

function hasValidatedRouteGeometry(route: ParsedRoute): boolean {
  return (
    route.polyline.trim().length > 0 &&
    Number.isFinite(route.distanceMeters) &&
    route.distanceMeters > 0 &&
    route.steps.length > 0 &&
    route.steps.some((step) => step.distanceMeters > 0)
  );
}

function evidenceForRoute(route: ParsedRoute, options: ScoringOptions) {
  return options.evidence ?? assessScoreEvidence({
    hasValidatedGeometry: hasValidatedRouteGeometry(route),
    trafficTimingAvailable:
      route.trafficTimingAvailable === true &&
      Number.isFinite(route.durationSeconds) && route.durationSeconds > 0 &&
      Number.isFinite(route.staticDurationSeconds) && route.staticDurationSeconds > 0,
    speedLimitCoverage: options.speedLimitCoverage ?? 0,
    weatherAvailable: options.conditions?.weather.available === true,
    roadAvailable: options.conditions?.road.available === true,
    turnControlsAvailable: options.conditions?.turns.available === true,
  });
}

export function scoreRoute(
  route: ParsedRoute,
  options: ScoringOptions = {}
): ScoredRoute {
  // Minutes already driven before this trip (0 = starting fresh).
  const continuousDriveMinutes = options.continuousDriveMinutes ?? 0;

  const { segments, segmentScores, features } = buildFeaturesFromRoute(route, {
    stepSpeedsMph: options.stepSpeedsMph,
    departureTime: options.departureTime,
    departureLocalMinutes: options.departureLocalMinutes,
    conditions: options.conditions,
  });

  // `buildFeaturesFromRoute` already aggregated these segment scores into
  // `features`; reuse its aggregate rather than re-deriving a second one that
  // could silently drift from the feature vector the rest of the model sees.
  const D_route = features.segmentAggregated;

  const base = computeBaseScore(features);
  const fatigue = computeFatigue(features, {
    departureTime: options.departureTime
      ? new Date(options.departureTime)
      : undefined,
    departureLocalMinutes: options.departureLocalMinutes,
    continuousDriveMinutes,
  });
  const rawScore = computeRawScore(D_route, base.D_base, fatigue, features);

  const uncalibrated = clampScore(rawScore);

  const calibrator = getCalibrator();
  const score = Math.round(clampScore(calibrator.transform(uncalibrated)) * 10) / 10;

  const breakdown = buildBreakdown(base, fatigue, features.durationHours);
  const contributions = explainPrediction(breakdown, features);
  const hotspots = buildHotspots(segments, segmentScores);

  const ctx: ScoringContext = {
    highwayShare: features.highwayShare,
    maneuversPer10Mi: features.maneuversPer10Mi,
    delayRatio: features.delayRatio,
    stepsPerMile: features.stepsPerMile,
    durationHours: features.durationHours,
    breakdown,
  };

  const evidence = evidenceForRoute(route, options);
  const baseUncertainty = estimateUncertainty(features, evidence, 0);
  const uncertainty = applyUncertaintyBand(score, baseUncertainty);

  const reasons = generateReasons(ctx, features, base, fatigue);
  const routeDemands = buildRouteDemands(route, features, {
    departureTime: options.departureTime,
    departureLocalMinutes: options.departureLocalMinutes,
    conditions: options.conditions,
    stepSpeedsMph: options.stepSpeedsMph,
  });

  // A provider that omits either duration must not produce a NaN delay:
  // `Math.max(0, NaN)` is NaN, which would serialize as `null` on the client.
  const trafficDelaySeconds = Math.max(
    0,
    finiteOr(route.durationSeconds) - finiteOr(route.staticDurationSeconds)
  );

  return {
    score,
    uncalibratedScore: Math.round(uncalibrated * 10) / 10,
    label: scoreToLabel(score),
    reasons: reasons.slice(0, 6),
    breakdown,
    contributions,
    uncertainty,
    hotspots,
    routeDemands,
    conditions: options.conditions,
    modelVersion: MODEL_VERSION,
    distanceMeters: route.distanceMeters,
    durationSeconds: route.durationSeconds,
    staticDurationSeconds: route.staticDurationSeconds,
    trafficDelaySeconds,
    polyline: route.polyline,
    bounds: route.bounds,
  };
}

export function scoreRoutes(
  routes: ParsedRoute[],
  optionsList?: ScoringOptions[]
): { primary: ScoredRoute; alternates: AlternateRoute[] } {
  if (routes.length === 0) {
    throw new Error("No routes to score");
  }

  const scored = routes.map((route, i) =>
    scoreRoute(route, optionsList?.[i] ?? {})
  );

  const primary = scored[0];
  const alternates: AlternateRoute[] = scored.slice(1).map((route) => ({
    ...route,
    scoreDelta: Math.round((route.score - primary.score) * 10) / 10,
  }));

  alternates.sort((a, b) => a.score - b.score);

  return { primary, alternates };
}

export { aggregateSegmentScores, scoreToLabel };
