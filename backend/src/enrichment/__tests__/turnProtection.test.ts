import { describe, expect, it } from "vitest";
import { determineTurnProtection } from "../turnProtection.js";

describe("turn protection confidence", () => {
  const turn = { lat: 0, lng: 0 };
  const signalAt = (lat: number, lon: number) => ({
    lat,
    lon,
    tags: { highway: "traffic_signals" },
  });

  it("marks routes without left turns as available with no exposure", () => {
    expect(determineTurnProtection([], [], true)).toMatchObject({
      available: true,
      protectedLeftTurns: 0,
      unprotectedLeftTurns: 0,
    });
  });

  it("stays unknown when the corridor is not mapped", () => {
    // Absence of a signal in unmapped data is not evidence of an unprotected
    // turn, so nothing may be inferred either way.
    expect(determineTurnProtection([turn], [], false)).toMatchObject({
      available: false,
      protectedLeftTurns: 0,
      unprotectedLeftTurns: 0,
    });
  });

  it("counts a turn with a nearby signal as protected", () => {
    expect(determineTurnProtection([turn], [signalAt(0, 0)], true)).toEqual({
      available: true,
      protectedLeftTurns: 1,
      unprotectedLeftTurns: 0,
      unprotectedTurnShare: 0,
    });
  });

  it("counts a turn in mapped territory with no signal as unprotected", () => {
    // The regression this file exists for: this case used to be unrepresentable,
    // so `unprotectedLeftTurns` was structurally always 0 and every consumer of
    // it scored a dimension that could never fire.
    expect(determineTurnProtection([turn], [], true)).toEqual({
      available: true,
      protectedLeftTurns: 0,
      unprotectedLeftTurns: 1,
      unprotectedTurnShare: 1,
    });
  });

  it("does not accept stop controls or distant signals as protection", () => {
    for (const nodes of [
      [{ lat: 0, lon: 0, tags: { highway: "stop" } }],
      [signalAt(0, 0.001)],
    ]) {
      expect(determineTurnProtection([turn], nodes, true)).toMatchObject({
        available: true,
        protectedLeftTurns: 0,
        unprotectedLeftTurns: 1,
      });
    }
  });

  it("treats several signals at one turn as protected, not ambiguous", () => {
    expect(determineTurnProtection([turn], [signalAt(0, 0), signalAt(0, 0.0001)], true))
      .toMatchObject({ available: true, protectedLeftTurns: 1, unprotectedLeftTurns: 0 });
  });

  it("reports a mixed route as a partial share", () => {
    const turns = [turn, { lat: 0, lng: 0.01 }, { lat: 0, lng: 0.02 }];
    expect(determineTurnProtection(turns, [signalAt(0, 0)], true)).toEqual({
      available: true,
      protectedLeftTurns: 1,
      unprotectedLeftTurns: 2,
      unprotectedTurnShare: 2 / 3,
    });
  });
});
