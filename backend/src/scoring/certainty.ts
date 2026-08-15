import type {
  ScoreEvidence,
  ScoreEvidenceLevel,
  ScoreEvidenceSignal,
} from "../types.js";

export interface ScoreEvidenceInput {
  hasValidatedGeometry: boolean;
  trafficTimingAvailable: boolean;
  /** Distance-weighted fraction of the route with a posted speed limit. */
  speedLimitCoverage: number;
  weatherAvailable: boolean;
  roadAvailable: boolean;
  turnControlsAvailable: boolean;
}

const SIGNAL_WEIGHTS: ReadonlyArray<{
  signal: ScoreEvidenceSignal;
  coverage: (input: ScoreEvidenceInput) => number;
  weight: number;
}> = [
  { signal: "routeGeometry", coverage: (input) => Number(input.hasValidatedGeometry), weight: 0.25 },
  { signal: "trafficTiming", coverage: (input) => Number(input.trafficTimingAvailable), weight: 0.20 },
  { signal: "speedLimits", coverage: (input) => input.speedLimitCoverage, weight: 0.15 },
  { signal: "weather", coverage: (input) => Number(input.weatherAvailable), weight: 0.15 },
  { signal: "roadMetadata", coverage: (input) => Number(input.roadAvailable), weight: 0.15 },
  { signal: "turnControls", coverage: (input) => Number(input.turnControlsAvailable), weight: 0.10 },
];

function clampUnit(value: number): number {
  return Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : 0;
}

function roundCoverage(value: number): number {
  return Math.round(value * 100) / 100;
}

function levelFor(coverage: number): ScoreEvidenceLevel {
  if (coverage >= 0.85) return "wellSupported";
  if (coverage >= 0.60) return "partial";
  return "limited";
}

/**
 * Reports which route inputs were verified for a single estimate. This
 * measures data completeness, not the probability that a score or driver
 * outcome is correct — there's no prediction interval until we have a
 * held-out labeled dataset and a versioned validation artifact.
 */
export function assessScoreEvidence(input: ScoreEvidenceInput): ScoreEvidence {
  const signalCoverage = Object.fromEntries(
    SIGNAL_WEIGHTS.map(({ signal, coverage }) => [signal, roundCoverage(clampUnit(coverage(input)))])
  ) as ScoreEvidence["signalCoverage"];

  const inputCoverage = roundCoverage(
    SIGNAL_WEIGHTS.reduce(
      (total, { signal, weight }) => total + signalCoverage[signal] * weight,
      0
    )
  );

  const verifiedSignals = SIGNAL_WEIGHTS
    .map(({ signal }) => signal)
    .filter((signal) => signalCoverage[signal] > 0);
  const missingSignals = SIGNAL_WEIGHTS
    .map(({ signal }) => signal)
    .filter((signal) => signalCoverage[signal] === 0);

  return {
    schemaVersion: "evidence-v1",
    inputCoverage,
    level: levelFor(inputCoverage),
    predictiveValidation: "notValidated",
    signalCoverage,
    verifiedSignals,
    missingSignals,
  };
}
