import type { RouteFeatures } from "./features.js";
import type { ScoreEvidence, ScoreUncertainty } from "../types.js";

/**
 * Coerce a possibly-dirty number to a usable one. Scoring inputs come from
 * third-party APIs, and a stray `NaN` or `Infinity` poisons any arithmetic
 * chain it touches, so we neutralize it at the boundary.
 */
export function finiteOr(value: number, fallback = 0): number {
  return Number.isFinite(value) ? value : fallback;
}

/** Exact statute mile, shared so distance-derived metrics agree across features and demands. */
export const METERS_PER_MILE = 1_609.344;

/** Hermite smoothstep: x² × (3 - 2x), clamped to [0, 1]. */
export function smoothstep(x: number): number {
  const t = Math.max(0, Math.min(1, finiteOr(x)));
  return t * t * (3 - 2 * t);
}

/** Clamp an arbitrary number onto the product's 0–10 difficulty scale. */
export function clampScore(score: number): number {
  return Math.max(0, Math.min(10, finiteOr(score)));
}

export function scoreToLabel(score: number): string {
  // A non-finite score must not fall through to "Very Hard": every `<`
  // comparison against NaN is false, so guard before the ladder.
  const value = clampScore(score);
  if (value < 2) return "Very Easy";
  if (value < 4) return "Easy";
  if (value < 6) return "Moderate";
  if (value < 8) return "Hard";
  return "Very Hard";
}

const GRACE_HOURS = 0.25;
const MAX_EFFORT_HOURS = 4;

export function computeSustainedEffortFromHours(durationHours: number): {
  durationHours: number;
  subscore: number;
} {
  const hours = Math.max(0, finiteOr(durationHours));
  const effectiveHours = Math.max(0, hours - GRACE_HOURS);
  return {
    durationHours: hours,
    subscore: smoothstep(effectiveHours / MAX_EFFORT_HOURS),
  };
}

/**
 * Width of the displayed band, in score points. Coarse by design: it
 * communicates how thin the inputs are, not a validated prediction interval
 * (see `assessScoreEvidence`).
 */
const UNCERTAINTY_SPREAD = {
  /** Baseline width applied to every route. */
  base: 0.35,
  /** Clustered interchanges make segment aggregation more sensitive to sampling. */
  mergeClusters: 0.15,
  /** Long trips accumulate more unmodelled condition drift. */
  longDrive: 0.1,
  /** A handful of steps gives the segment model very little to average over. */
  sparseSteps: 0.2,
  /** Tightly spaced merges amplify small geometry differences. */
  tightMergeSpacing: 0.1,
  /** Ceiling on the residual-driven term so one outlier cannot dominate. */
  maxResidual: 0.5,
} as const;

const UNCERTAINTY_THRESHOLDS = {
  mergeClusterCount: 2,
  durationHours: 3,
  stepCount: 5,
  exponentialSpacing: 2,
} as const;

/** Confidence is a monotone restatement of spread, floored/capped for display. */
const CONFIDENCE_BOUNDS = { min: 0.35, max: 0.95 } as const;

export function estimateUncertainty(
  features: RouteFeatures,
  evidence: ScoreEvidence,
  residualMagnitude = 0
): ScoreUncertainty {
  let spread = UNCERTAINTY_SPREAD.base;
  if (features.mergeClusterCount >= UNCERTAINTY_THRESHOLDS.mergeClusterCount) {
    spread += UNCERTAINTY_SPREAD.mergeClusters;
  }
  if (features.durationHours >= UNCERTAINTY_THRESHOLDS.durationHours) {
    spread += UNCERTAINTY_SPREAD.longDrive;
  }
  if (features.stepCount < UNCERTAINTY_THRESHOLDS.stepCount) {
    spread += UNCERTAINTY_SPREAD.sparseSteps;
  }
  if (features.exponentialSpacing > UNCERTAINTY_THRESHOLDS.exponentialSpacing) {
    spread += UNCERTAINTY_SPREAD.tightMergeSpacing;
  }
  spread += Math.min(
    UNCERTAINTY_SPREAD.maxResidual,
    Math.max(0, finiteOr(residualMagnitude) * 0.2)
  );

  const confidence = Math.max(
    CONFIDENCE_BOUNDS.min,
    Math.min(CONFIDENCE_BOUNDS.max, 1 - spread / 2)
  );
  return { low: 0, high: 0, confidence, spread, evidence };
}

export function applyUncertaintyBand(
  score: number,
  uncertainty: ScoreUncertainty
): ScoreUncertainty {
  const centre = clampScore(score);
  const half = Math.max(0, finiteOr(uncertainty.spread)) / 2;
  // Clamping each edge to the 0–10 scale can pull an edge past the score
  // itself only if the score were out of range, which `clampScore` prevents.
  return {
    ...uncertainty,
    low: Math.max(0, Math.round((centre - half) * 10) / 10),
    high: Math.min(10, Math.round((centre + half) * 10) / 10),
  };
}

const CALIBRATION_KNOTS = [
  { x: 0, y: 0 },
  { x: 1.5, y: 1.1 },
  { x: 3, y: 2.5 },
  { x: 4.5, y: 3.8 },
  { x: 6, y: 5.0 },
  { x: 7.5, y: 6.3 },
  { x: 9, y: 7.8 },
  { x: 10, y: 9.0 },
] as const;

/**
 * Maps the heuristic workload to the product's 0–10 difficulty scale.
 * Compresses the upper half so ordinary dense-city trips and traffic delays
 * don't read as "Very Hard" — 8-10 is reserved for routes with several
 * severe, corroborated burdens.
 */
export function calibrateScore(score: number): number {
  const knots = CALIBRATION_KNOTS;
  const first = knots[0];
  const last = knots[knots.length - 1];
  // `clampScore` also neutralizes a non-finite workload; without it the loop
  // below would match no interval and leak NaN straight to the client.
  const x = clampScore(score);
  if (x <= first.x) return first.y;
  if (x >= last.x) return last.y;

  for (let i = 0; i < knots.length - 1; i++) {
    const a = knots[i];
    const b = knots[i + 1];
    if (x > b.x) continue;
    const t = (x - a.x) / (b.x - a.x);
    return a.y + t * (b.y - a.y);
  }

  // Unreachable: the clamp above guarantees x lies inside the knot span.
  return last.y;
}

export function getCalibrator(): {
  transform: (score: number) => number;
  modelVersion: string;
} {
  return { transform: calibrateScore, modelVersion: "hybrid-v6" };
}
