import { afterEach, describe, expect, it, vi } from "vitest";
import {
  applySpeedLimitsToSteps,
  buildStepSpeedMap,
  enrichRouteWithSpeedLimits,
  enrichStepSpeeds,
  getSpeedLimitsForRoute,
} from "../roads.js";
import type { ParsedRoute } from "../../types.js";

afterEach(() => {
  vi.unstubAllGlobals();
});

const twoStepRoute: ParsedRoute = {
  distanceMeters: 3_218.68,
  durationSeconds: 180,
  staticDurationSeconds: 180,
  polyline: "",
  bounds: {
    southwest: { lat: 0, lng: 0 },
    northeast: { lat: 1, lng: 1 },
  },
  steps: [
    { distanceMeters: 1_609.34, staticDurationSeconds: 120, maneuver: "DEPART" },
    { distanceMeters: 1_609.34, staticDurationSeconds: 60, maneuver: "STRAIGHT" },
  ],
};

const routeWithGeometry: ParsedRoute = {
  distanceMeters: 3_218.68,
  durationSeconds: 180,
  staticDurationSeconds: 180,
  // Classic Google encoded-polyline sample; decodes to 3 real points.
  polyline: "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
  bounds: {
    southwest: { lat: 0, lng: 0 },
    northeast: { lat: 1, lng: 1 },
  },
  steps: [
    { distanceMeters: 1_609.34, staticDurationSeconds: 120, maneuver: "DEPART" },
    { distanceMeters: 1_609.34, staticDurationSeconds: 60, maneuver: "STRAIGHT" },
  ],
};

describe("Roads API upstream failure handling", () => {
  it("degrades to implied speeds instead of throwing when the network request fails", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("network down")));

    const baseline = buildStepSpeedMap(routeWithGeometry);
    const enrichment = await enrichRouteWithSpeedLimits(routeWithGeometry, "test-key");

    expect(enrichment.source).toBe("implied");
    expect(enrichment.postedSpeedLimitCoverage).toBe(0);
    expect(enrichment.stepSpeedsMph).toEqual(baseline);
  });

  it("degrades to implied speeds instead of throwing when the response body is not JSON", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(new Response("not json", { status: 200 }))
    );

    const enrichment = await enrichRouteWithSpeedLimits(routeWithGeometry, "test-key");
    expect(enrichment.source).toBe("implied");
  });

  it("degrades to implied speeds instead of throwing on a non-2xx status", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ error: { message: "quota exceeded" } }), { status: 429 })
      )
    );

    const enrichment = await enrichRouteWithSpeedLimits(routeWithGeometry, "test-key");
    expect(enrichment.source).toBe("implied");
  });

  it("rejects an upstream payload with the wrong field types instead of poisoning scoring with NaN", async () => {
    const snapResponse = new Response(JSON.stringify({
      snappedPoints: [{ placeId: "p1", originalIndex: 0 }],
    }), { status: 200 });
    // speedLimit as a string must be rejected — coercing it downstream would
    // silently corrupt scoring with NaN instead of degrading gracefully.
    const malformedSpeedLimitsResponse = new Response(JSON.stringify({
      speedLimits: [{ placeId: "p1", speedLimit: "25" }],
    }), { status: 200 });

    const fetchMock = vi.fn()
      .mockResolvedValueOnce(snapResponse)
      .mockResolvedValueOnce(malformedSpeedLimitsResponse);
    vi.stubGlobal("fetch", fetchMock);

    await expect(getSpeedLimitsForRoute(routeWithGeometry, "test-key")).rejects.toThrow(
      "speedLimits returned an unexpected payload"
    );

    const enrichment = await enrichRouteWithSpeedLimits(routeWithGeometry, "test-key");
    expect(enrichment.source).toBe("implied");
    expect(Number.isNaN(enrichment.stepSpeedsMph.get(0))).toBe(false);
  });

  it("accepts a well-formed payload and reports posted coverage", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        snappedPoints: [{ placeId: "p1", originalIndex: 0 }],
      }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        speedLimits: [{ placeId: "p1", speedLimit: 45, units: "MPH" }],
      }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    const limits = await getSpeedLimitsForRoute(routeWithGeometry, "test-key");
    expect(limits).toEqual([{
      placeId: "p1",
      speedLimit: 45,
      speedLimitUnit: "MPH",
      sampleIndex: 0,
      sampleCount: 3,
    }]);
  });
});

describe("speed-limit step assignment", () => {
  it("keeps posted limits local to their sampled route step", () => {
    const speeds = applySpeedLimitsToSteps(twoStepRoute, [
      { placeId: "local", speedLimit: 25, speedLimitUnit: "MPH", sampleIndex: 0, sampleCount: 4 },
      { placeId: "freeway", speedLimit: 70, speedLimitUnit: "MPH", sampleIndex: 3, sampleCount: 4 },
    ]);

    expect(speeds.get(0)).toBeCloseTo(26, 1);
    expect(speeds.get(1)).toBeCloseTo(68, 1);
  });

  it("falls back to per-step implied speeds when positional coverage is absent", () => {
    const baseline = buildStepSpeedMap(twoStepRoute);
    const speeds = applySpeedLimitsToSteps(twoStepRoute, [
      { placeId: "unknown-position", speedLimit: 70, speedLimitUnit: "MPH" },
    ]);

    expect(speeds.get(0)).toBe(baseline.get(0));
    expect(speeds.get(1)).toBe(baseline.get(1));
  });

  it("reports the distance-weighted portion backed by posted speed limits", () => {
    const enrichment = enrichStepSpeeds(twoStepRoute, [
      { placeId: "local", speedLimit: 25, speedLimitUnit: "MPH", sampleIndex: 0, sampleCount: 4 },
    ]);

    expect(enrichment.postedSpeedLimitCoverage).toBeCloseTo(0.5);
    expect(enrichment.source).toBe("mixed");
    expect(enrichment.stepSpeedsMph.get(0)).toBeCloseTo(26, 1);
  });
});
