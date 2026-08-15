import { describe, expect, it } from "vitest";
import { assessScoreEvidence } from "../certainty.js";

describe("score evidence coverage", () => {
  it("describes complete verified inputs without claiming predictive validation", () => {
    const evidence = assessScoreEvidence({
      hasValidatedGeometry: true,
      trafficTimingAvailable: true,
      speedLimitCoverage: 1,
      weatherAvailable: true,
      roadAvailable: true,
      turnControlsAvailable: true,
    });

    expect(evidence.inputCoverage).toBe(1);
    expect(evidence.level).toBe("wellSupported");
    expect(evidence.predictiveValidation).toBe("notValidated");
    expect(evidence.missingSignals).toEqual([]);
    expect("predictionInterval" in evidence).toBe(false);
  });

  it("names unavailable live signals without turning coverage into a prediction interval", () => {
    const complete = assessScoreEvidence({
      hasValidatedGeometry: true,
      trafficTimingAvailable: true,
      speedLimitCoverage: 1,
      weatherAvailable: true,
      roadAvailable: true,
      turnControlsAvailable: true,
    });
    const partial = assessScoreEvidence({
      hasValidatedGeometry: true,
      trafficTimingAvailable: true,
      speedLimitCoverage: 0,
      weatherAvailable: false,
      roadAvailable: false,
      turnControlsAvailable: false,
    });

    expect(partial.level).toBe("limited");
    expect(partial.inputCoverage).toBeLessThan(complete.inputCoverage);
    expect(partial.missingSignals).toEqual(
      expect.arrayContaining(["speedLimits", "weather", "roadMetadata", "turnControls"])
    );
  });

  it("uses the documented partial threshold for a mixed set of verified inputs", () => {
    const evidence = assessScoreEvidence({
      hasValidatedGeometry: true,
      trafficTimingAvailable: true,
      speedLimitCoverage: 0,
      weatherAvailable: true,
      roadAvailable: false,
      turnControlsAvailable: false,
    });

    expect(evidence.inputCoverage).toBe(0.6);
    expect(evidence.level).toBe("partial");
  });

  it("treats posted-speed coverage as a fractional verified input", () => {
    const halfCovered = assessScoreEvidence({
      hasValidatedGeometry: true,
      trafficTimingAvailable: true,
      speedLimitCoverage: 0.5,
      weatherAvailable: true,
      roadAvailable: true,
      turnControlsAvailable: true,
    });
    const fullCovered = assessScoreEvidence({
      hasValidatedGeometry: true,
      trafficTimingAvailable: true,
      speedLimitCoverage: 1,
      weatherAvailable: true,
      roadAvailable: true,
      turnControlsAvailable: true,
    });

    expect(halfCovered.inputCoverage).toBeLessThan(fullCovered.inputCoverage);
    expect(halfCovered.verifiedSignals).toContain("speedLimits");
  });

  it("clamps malformed provider coverage rather than overstating evidence", () => {
    const tooHigh = assessScoreEvidence({
      hasValidatedGeometry: false,
      trafficTimingAvailable: false,
      speedLimitCoverage: 4,
      weatherAvailable: false,
      roadAvailable: false,
      turnControlsAvailable: false,
    });
    const tooLow = assessScoreEvidence({
      hasValidatedGeometry: false,
      trafficTimingAvailable: false,
      speedLimitCoverage: Number.NaN,
      weatherAvailable: false,
      roadAvailable: false,
      turnControlsAvailable: false,
    });

    expect(tooHigh.signalCoverage.speedLimits).toBe(1);
    expect(tooHigh.inputCoverage).toBe(0.15);
    expect(tooLow.signalCoverage.speedLimits).toBe(0);
    expect(tooLow.inputCoverage).toBe(0);
  });
});
