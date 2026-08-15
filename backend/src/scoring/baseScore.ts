import type { RouteFeatures } from "./features.js";
import { smoothstep } from "./helpers.js";

export interface BaseScoreComponents {
  S: number;
  M: number;
  T: number;
  C: number;
  L: number;
  /** Road context: road size/class, surface, construction (0–1). */
  R: number;
  /** Weather severity at drive time (0–1). */
  W: number;
  D_base: number;
}

/**
 * Structural base weights. Weather (W) and road (R) are computed for
 * explainability but applied only as additive points in computeRawScore
 * to avoid double-counting.
 */
export const BASE_SCORE_WEIGHTS = {
  S: 0.24,
  M: 0.26,
  T: 0.22,
  C: 0.14,
  L: 0.14,
} as const;

export function computeSpeedComponent(features: RouteFeatures): number {
  const localRoadBurden = smoothstep((1 - features.highwayShare) * 1.2);
  const highSpeedShare =
    features.fractionAbove45Mph * 0.4 + features.fractionAbove60Mph * 0.6;
  const speedIntensity = smoothstep(features.meanSpeedMph / 70);
  const monotonyBump = features.monotonyScore * 0.2;
  return Math.min(
    1,
    localRoadBurden * 0.5 +
      highSpeedShare * 0.25 +
      speedIntensity * 0.15 +
      monotonyBump
  );
}

/**
 * Turn difficulty is dominated by *which* turns a route has, not how many.
 * Unprotected left turns are the hardest single maneuver.
 */
export function computeTurnComponent(features: RouteFeatures): number {
  const unprotectedLefts = smoothstep(features.unprotectedLeftTurns / 3.5);
  const leftTurns = smoothstep(features.leftTurnCount / 6);
  const sharpTurns = smoothstep(features.sharpTurnCount / 3);
  const turnCluster = features.turnClusterSubscore;
  const decisionDensity = smoothstep(features.decisionPointDensity / 4);
  const maneuverIntensity = smoothstep(features.maneuversPer10Mi / 7);
  const navDensity = smoothstep(features.stepsPerMile / 1.2);
  return Math.min(
    1,
    unprotectedLefts * 0.28 +
      leftTurns * 0.1 +
      sharpTurns * 0.14 +
      turnCluster * 0.2 +
      decisionDensity * 0.12 +
      maneuverIntensity * 0.1 +
      navDensity * 0.06
  );
}

export function computeTrafficComponent(features: RouteFeatures): number {
  const delay = smoothstep(features.delayRatio / 0.3);
  const variance = smoothstep(features.trafficVariance);
  return Math.min(1, delay * 0.75 + variance * 0.25);
}

export function computeLengthComponent(features: RouteFeatures): number {
  const duration =
    smoothstep(features.durationHours / 3) * 0.7 +
    smoothstep((features.durationHours - 2.5) / 5.5) * 0.3;
  const highwayRun = smoothstep(features.longestHighwaySegmentMiles / 50);
  const monotony = features.monotonyScore;
  return Math.min(1, duration * 0.55 + highwayRun * 0.2 + monotony * 0.25);
}

export function computeRoadComponent(features: RouteFeatures): number {
  return Math.min(
    1,
    features.roadSizeScore * 0.5 +
      smoothstep(features.unpavedShare / 0.3) * 0.2 +
      features.constructionSeverity * 0.3
  );
}

export function computeWeatherComponent(features: RouteFeatures): number {
  const highSpeedExposure =
    features.fractionAbove45Mph * 0.5 + features.fractionAbove60Mph * 0.5;
  return Math.min(
    1,
    features.weatherSeverity * (0.8 + 0.35 * highSpeedExposure)
  );
}

export function computeBaseScore(features: RouteFeatures): BaseScoreComponents {
  const S = computeSpeedComponent(features);
  const M = features.mergeBurdenSubscore;
  const T = computeTurnComponent(features);
  const C = computeTrafficComponent(features);
  const L = computeLengthComponent(features);
  const R = computeRoadComponent(features);
  const W = computeWeatherComponent(features);

  // Structural only — live weather/road/traffic punch lives in computeRawScore.
  const D_base = Math.min(
    1,
    BASE_SCORE_WEIGHTS.S * S +
      BASE_SCORE_WEIGHTS.M * M +
      BASE_SCORE_WEIGHTS.T * T +
      BASE_SCORE_WEIGHTS.C * C +
      BASE_SCORE_WEIGHTS.L * L
  );

  return { S, M, T, C, L, R, W, D_base };
}
