import type { DriverContext } from "../types.js";
import type { RouteFeatures } from "./features.js";
import { smoothstep, computeSustainedEffortFromHours } from "./helpers.js";

export interface FatigueResult {
  durationMinutes: number;
  circadianPenalty: number;
  continuousPenalty: number;
  D_fatigue: number;
  D_interaction: number;
}

/** Shared divisor for fatigueNorm / fatigueSubscore. */
export const FATIGUE_NORM_DIVISOR = 1.8;

/** Circadian + prior continuous driving (duration handled via durationPoints). */
export const FATIGUE_COEFFICIENTS = {
  a1: 0.28,
  a2: 0.4,
  a3: 0.32,
} as const;

/**
 * Trip-length burden independent of road complexity (0–1).
 */
export function durationBurden(hours: number): number {
  if (hours <= 0.2) return 0;
  return Math.min(
    1,
    smoothstep((hours - 0.2) / 3.3) * 0.8 + smoothstep((hours - 3.5) / 6) * 0.2
  );
}

/**
 * Primary duration contribution on the 0–10 scale.
 * Short hop ~0, 2h ~1.2, 4h ~2.8, 8h ~4.0.
 */
export function durationPoints(hours: number): number {
  return 2.8 * smoothstep(hours / 4.5) + 1.2 * smoothstep((hours - 4) / 6);
}

/**
 * Prefer the driver's local clock supplied by the client. The Date fallback is
 * only for older clients and intentionally uses UTC so server locale never
 * changes the result.
 */
function circadianPenalty(
  departureTime?: Date,
  departureLocalMinutes?: number
): number {
  const hour =
    typeof departureLocalMinutes === "number" &&
    Number.isInteger(departureLocalMinutes) &&
    departureLocalMinutes >= 0 &&
    departureLocalMinutes < 24 * 60
      ? Math.floor(departureLocalMinutes / 60)
      : departureTime?.getUTCHours();
  if (hour === undefined || !Number.isFinite(hour)) return 0;
  if (hour >= 0 && hour < 6) return 1.0;
  if (hour >= 22) return 0.85;
  if (hour >= 15 && hour < 18) return 0.35;
  if (hour >= 6 && hour < 8) return 0.4;
  return 0.1;
}

/** `priorMinutes` = minutes already driven before this trip starts. */
function continuousDrivePenalty(priorMinutes: number): number {
  return smoothstep(Math.log1p(Math.max(0, priorMinutes) / 30) / Math.log1p(4));
}

export function computeFatigue(
  features: RouteFeatures,
  ctx: DriverContext
): FatigueResult {
  const durationMinutes = features.durationHours * 60;
  const circadian = circadianPenalty(
    ctx.departureTime,
    ctx.departureLocalMinutes
  );
  const continuous = continuousDrivePenalty(ctx.continuousDriveMinutes);

  // Duration is mostly handled by durationPoints; keep a light log term here.
  const D_fatigue =
    FATIGUE_COEFFICIENTS.a1 * Math.log1p(durationMinutes / 40) +
    FATIGUE_COEFFICIENTS.a2 * circadian +
    FATIGUE_COEFFICIENTS.a3 * continuous;

  const loadFactor = smoothstep((continuous + circadian * 0.7) / 1.6);

  let D_interaction = 0;
  D_interaction += loadFactor * features.monotonyScore * 0.35;
  D_interaction += loadFactor * features.nighttimeShare * 0.35;
  D_interaction +=
    loadFactor * features.mergeBurdenSubscore * features.weaveSectionScore * 0.4;
  D_interaction += loadFactor * features.weatherSeverity * 0.4;
  D_interaction += features.nighttimeShare * features.weatherSeverity * 0.3;
  D_interaction +=
    features.nighttimeShare *
    smoothstep(features.maneuversPer10Mi / 10) *
    0.25;

  return {
    durationMinutes,
    circadianPenalty: circadian,
    continuousPenalty: continuous,
    D_fatigue,
    D_interaction,
  };
}

export function computeRawScore(
  D_route: number,
  D_base: number,
  fatigue: FatigueResult,
  features: RouteFeatures
): number {
  const fatigueNorm = smoothstep(fatigue.D_fatigue / FATIGUE_NORM_DIVISOR);
  const interactionNorm = smoothstep(fatigue.D_interaction * 2);
  const sustained = computeSustainedEffortFromHours(features.durationHours).subscore;

  // Structure from segments + base; timing is secondary.
  let workload =
    0.42 * D_route +
    0.28 * D_base +
    0.08 * fatigueNorm +
    0.07 * interactionNorm +
    0.08 * sustained;

  if (
    features.highwayShare >= 0.65 &&
    D_route < 0.32 &&
    features.durationHours < 0.75
  ) {
    workload -= 0.07;
  }

  if (features.highwayShare < 0.25 && features.maneuversPer10Mi >= 8) {
    const density = smoothstep((features.maneuversPer10Mi - 8) / 20);
    workload += 0.08 + density * 0.08;
  }

  if (features.stepsPerMile >= 3.5) {
    workload += 0.03;
  }

  let complexityBump = 0;
  if (features.mergeClusterCount >= 2 || features.weaveCount >= 1) {
    complexityBump += 0.05 + features.segmentP90Difficulty * 0.1;
  }
  complexityBump += features.exponentialSpacing * 0.012;
  if (features.turnClusterCount >= 1) {
    complexityBump += 0.05 + features.segmentP90Difficulty * 0.1;
  }
  if (features.closeTurnPairs >= 3) {
    complexityBump += 0.03 + smoothstep(features.turnSpacingPressure) * 0.035;
  }
  complexityBump += smoothstep(features.decisionPointDensity / 5) * 0.05;
  complexityBump += features.laneChangeUrgency * 0.04;
  workload += Math.min(0.2, complexityBump);

  if (features.monotonyScore > 0.25 && features.durationHours >= 1) {
    workload +=
      features.monotonyScore *
      smoothstep((features.durationHours - 0.5) / 2.5) *
      0.06;
  }

  let points = workload * 10;
  points += durationPoints(features.durationHours);

  // Unprotected lefts — primary turn-quality signal beyond base T.
  points += smoothstep(features.unprotectedLeftTurns / 4) * 1.0;
  points += features.unprotectedTurnShare * 0.4;
  points += smoothstep(features.leftTurnCount / 12) * 0.1;

  // Live weather (not also in D_base).
  if (features.weatherSeverity > 0.05) {
    const highSpeedExposure =
      features.fractionAbove45Mph * 0.5 + features.fractionAbove60Mph * 0.5;
    const weatherPoints =
      features.weatherSeverity *
      (1.5 + 0.7 * highSpeedExposure + 0.5 * features.nighttimeShare);
    points += Math.min(2.6, weatherPoints);
    points += features.icyRisk * 0.5 + features.snowRisk * 0.4;
  }

  // Live road context (not also in D_base).
  points += features.roadSizeScore * smoothstep(features.urbanShare) * 0.5;
  points += smoothstep(features.unpavedShare / 0.3) * 0.4;
  points += features.constructionSeverity * 0.8;

  // Traffic delay — primary traffic signal (C in D_base is a light residual).
  const trafficPoints = Math.min(
    2.6,
    smoothstep(features.delayRatio / 0.32) * 2.1 +
      smoothstep(features.trafficVariance) * 0.25
  );
  return Math.min(10, Math.max(0, points + trafficPoints));
}

export function fatigueSubscore(fatigue: FatigueResult): number {
  return smoothstep(fatigue.D_fatigue / FATIGUE_NORM_DIVISOR);
}
