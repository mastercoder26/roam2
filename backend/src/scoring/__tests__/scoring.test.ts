import { describe, expect, it } from "vitest";
import {
  scoreRoute,
  scoreRoutes,
  scoreToLabel,
  aggregateSegmentScores,
} from "../index.js";
import { getCalibrator } from "../helpers.js";
import { highwayRoute } from "./fixtures/highway-route.js";
import { urbanRoute } from "./fixtures/urban-route.js";
import {
  trafficHeavyRoute,
  trafficLightRoute,
} from "./fixtures/traffic-route.js";
import { longDriveRoute } from "./fixtures/long-drive-route.js";
import {
  mergeClusterRoute,
  smoothHighwayEquivalent,
} from "./fixtures/merge-cluster-route.js";
import { exchangeHeavyRoute } from "./fixtures/exchange-heavy-route.js";
import {
  turnClusterRoute,
  spacedTurnRoute,
  singleMergeRoute,
} from "./fixtures/turn-cluster-route.js";
import { computeTurnClustering, computeHighwayShare, computeManeuverComplexity } from "../signals.js";
import { smoothstep } from "../helpers.js";
import { aggregateMeanOnly, scoreSegmentLocal, segmentRoute } from "../segments.js";
import { buildFeaturesFromRoute } from "../features.js";
import { FACTOR_WEIGHTS } from "../explain.js";
import { BASE_SCORE_WEIGHTS } from "../baseScore.js";

describe("smoothstep", () => {
  it("clamps below 0 and above 1", () => {
    expect(smoothstep(-1)).toBe(0);
    expect(smoothstep(2)).toBe(1);
  });

  it("returns 0.5 at midpoint", () => {
    expect(smoothstep(0.5)).toBeCloseTo(0.5);
  });
});

describe("labels", () => {
  it("maps score boundaries correctly", () => {
    expect(scoreToLabel(1.9)).toBe("Very Easy");
    expect(scoreToLabel(2)).toBe("Easy");
    expect(scoreToLabel(3.9)).toBe("Easy");
    expect(scoreToLabel(4)).toBe("Moderate");
    expect(scoreToLabel(5.9)).toBe("Moderate");
    expect(scoreToLabel(6)).toBe("Hard");
    expect(scoreToLabel(7.9)).toBe("Hard");
    expect(scoreToLabel(8)).toBe("Very Hard");
  });
});

describe("highway route scoring", () => {
  it("scores ~85 min highway corridor as easy to moderate (2–4.5)", () => {
    const result = scoreRoute(highwayRoute);
    expect(result.score).toBeGreaterThanOrEqual(2);
    expect(result.score).toBeLessThanOrEqual(4.5);
    expect(result.label).toMatch(/Very Easy|Easy|Moderate/);
    expect(result.reasons).toContain("Mostly highway");
  });

  it("detects high highway share", () => {
    const { highwayShare } = computeHighwayShare(highwayRoute.steps);
    expect(highwayShare).toBeGreaterThanOrEqual(0.65);
  });
});

describe("score evidence provenance", () => {
  it("reports traffic timing only when the route provider tagged it as traffic-aware", () => {
    const withoutTrafficTiming = scoreRoute({
      ...highwayRoute,
      trafficTimingAvailable: false,
    });
    const withTrafficTiming = scoreRoute({
      ...highwayRoute,
      trafficTimingAvailable: true,
    });

    expect(withoutTrafficTiming.uncertainty.evidence.signalCoverage.trafficTiming).toBe(0);
    expect(withTrafficTiming.uncertainty.evidence.signalCoverage.trafficTiming).toBe(1);
  });
});

describe("after-dark timing", () => {
  const chicagoCorridor = {
    ...highwayRoute,
    bounds: {
      southwest: { lat: 41.78, lng: -87.72 },
      northeast: { lat: 41.9, lng: -87.55 },
    },
  };

  it("uses seasonal daylight rather than a fixed clock window", () => {
    const winter = buildFeaturesFromRoute(chicagoCorridor, {
      departureTime: "2026-01-15T00:30:00.000Z",
      departureLocalMinutes: 18 * 60 + 30,
    }).features;
    const summer = buildFeaturesFromRoute(chicagoCorridor, {
      departureTime: "2026-07-15T23:30:00.000Z",
      departureLocalMinutes: 18 * 60 + 30,
    }).features;

    expect(winter.nighttimeShare).toBeGreaterThan(0.95);
    expect(summer.nighttimeShare).toBeLessThan(0.05);
  });
});

describe("urban route scoring", () => {
  it("scores a dense urban grid as hard without defaulting to very hard", () => {
    const result = scoreRoute(urbanRoute);
    expect(result.score).toBeGreaterThanOrEqual(6);
    expect(result.score).toBeLessThan(8);
    expect(result.label).toBe("Hard");
    expect(result.reasons.some((r) => r.includes("turn"))).toBe(true);
  });

  it("has high maneuver density", () => {
    const { maneuversPer10Mi } = computeManeuverComplexity(
      urbanRoute.steps,
      urbanRoute.distanceMeters
    );
    expect(maneuversPer10Mi).toBeGreaterThanOrEqual(8);
  });
});

describe("score calibration", () => {
  it("compresses upper heuristic scores so very hard remains exceptional", () => {
    const calibrator = getCalibrator();
    expect(calibrator.transform(8.7)).toBeLessThan(8);
    expect(calibrator.transform(10)).toBe(9);
    expect(calibrator.modelVersion).toBe("hybrid-v6");
  });
});

describe("traffic scoring", () => {
  it("adds 0.5–4 points for heavy traffic vs light", () => {
    const light = scoreRoute(trafficLightRoute);
    const heavy = scoreRoute(trafficHeavyRoute);
    const delta = heavy.score - light.score;
    expect(delta).toBeGreaterThanOrEqual(0.5);
    expect(delta).toBeLessThanOrEqual(4);
    expect(heavy.reasons.some((r) => r.toLowerCase().includes("traffic"))).toBe(
      true
    );
  });

  it("computes delay ratio for heavy traffic", () => {
    const { features } = buildFeaturesFromRoute(trafficHeavyRoute);
    expect(features.delayRatio).toBeGreaterThanOrEqual(0.25);
  });
});

describe("long drive fatigue", () => {
  it("scores 3hr+ trip higher than short highway trip", () => {
    const short = scoreRoute(highwayRoute);
    const long = scoreRoute(longDriveRoute);
    expect(long.score).toBeGreaterThan(short.score);
    expect(long.reasons.some((r) => r.toLowerCase().includes("long"))).toBe(true);
  });

  it("bumps score for late-night departure vs midday on long trip", () => {
    const midday = scoreRoute(longDriveRoute, {
      departureTime: "2026-06-06T14:00:00.000Z",
    });
    const lateNight = scoreRoute(longDriveRoute, {
      departureTime: "2026-06-06T03:00:00.000Z",
    });
    expect(lateNight.score).toBeGreaterThan(midday.score);
    expect(lateNight.breakdown.fatigue).toBeGreaterThan(midday.breakdown.fatigue);
  });

  it("bumps score when already driving continuously beforehand", () => {
    // continuousDriveMinutes = minutes already driven before this trip.
    const fresh = scoreRoute(longDriveRoute, { continuousDriveMinutes: 0 });
    const alreadyDriving = scoreRoute(longDriveRoute, {
      continuousDriveMinutes: 180,
    });
    expect(alreadyDriving.score).toBeGreaterThan(fresh.score);
  });
});

describe("merge cluster aggregation", () => {
  it("P90/max aggregation scores cluster route higher than smooth equivalent", () => {
    const cluster = scoreRoute(mergeClusterRoute);
    const smooth = scoreRoute(smoothHighwayEquivalent);
    expect(cluster.score - smooth.score).toBeGreaterThanOrEqual(1.5);
  });

  it("P90 aggregation exceeds mean-only on cluster fixture", () => {
    const segments = segmentRoute(mergeClusterRoute);
    const scores = segments.map(scoreSegmentLocal);
    const p90Agg = aggregateSegmentScores(scores).aggregated;
    const meanOnly = aggregateMeanOnly(scores);
    expect(p90Agg).toBeGreaterThan(meanOnly);
  });

  it("detects merge clusters in reasons", () => {
    const result = scoreRoute(mergeClusterRoute);
    expect(
      result.reasons.some(
        (r) =>
          r.toLowerCase().includes("merge") ||
          r.toLowerCase().includes("interchange") ||
          r.toLowerCase().includes("cluster")
      )
    ).toBe(true);
  });
});

describe("turn cluster scoring", () => {
  it("detects close turn pairs in cluster fixture", () => {
    const { closeTurnPairs, turnClusterCount } = computeTurnClustering(
      turnClusterRoute.steps,
      turnClusterRoute.distanceMeters
    );
    expect(closeTurnPairs).toBeGreaterThanOrEqual(3);
    expect(turnClusterCount).toBeGreaterThanOrEqual(1);
  });

  it("scores turn cluster route higher than spaced equivalent", () => {
    const cluster = scoreRoute(turnClusterRoute);
    const spaced = scoreRoute(spacedTurnRoute);
    expect(cluster.score - spaced.score).toBeGreaterThanOrEqual(1.5);
  });

  it("includes turn clustering in reasons", () => {
    const result = scoreRoute(turnClusterRoute);
    expect(
      result.reasons.some(
        (r) =>
          r.toLowerCase().includes("close together") ||
          r.toLowerCase().includes("back-to-back")
      )
    ).toBe(true);
  });
});

describe("merge cluster threshold", () => {
  it("does not label single merge as clustered interchanges", () => {
    const result = scoreRoute(singleMergeRoute);
    expect(
      result.reasons.some((r) => r.toLowerCase().includes("clustered interchange"))
    ).toBe(false);
  });
});

describe("urban route reasons", () => {
  it("includes specific difficulty reasons beyond generic many turns", () => {
    const result = scoreRoute(urbanRoute);
    const specific = result.reasons.filter(
      (r) =>
        r.includes("close together") ||
        r.includes("Back-to-back") ||
        r.includes("Sharp turns") ||
        r.includes("Urban grid") ||
        r.includes("left turns") ||
        r.includes("decision")
    );
    expect(specific.length).toBeGreaterThanOrEqual(1);
  });
});

describe("exchange-heavy routes", () => {
  it("scores exchange-heavy route at least 2 pts above smooth highway equivalent", () => {
    const exchange = scoreRoute(exchangeHeavyRoute);
    const smooth = scoreRoute(smoothHighwayEquivalent);
    expect(exchange.score - smooth.score).toBeGreaterThanOrEqual(2);
  });
});

describe("alternate route ranking", () => {
  it("sorts alternates easiest-first with scoreDelta", () => {
    const urban = scoreRoute(urbanRoute);
    const highway = scoreRoute(highwayRoute);

    const routes =
      urban.score > highway.score
        ? [urbanRoute, highwayRoute]
        : [highwayRoute, urbanRoute];

    const { primary, alternates } = scoreRoutes(routes);

    expect(alternates.length).toBe(1);
    expect(alternates[0].score).toBeLessThanOrEqual(primary.score);
    expect(alternates[0].scoreDelta).toBe(
      Math.round((alternates[0].score - primary.score) * 10) / 10
    );
  });
});

describe("response shape", () => {
  it("includes all required fields with extended breakdown", () => {
    const result = scoreRoute(highwayRoute);
    expect(result).toMatchObject({
      score: expect.any(Number),
      label: expect.any(String),
      reasons: expect.any(Array),
      breakdown: {
        speed: expect.any(Number),
        merges: expect.any(Number),
        turns: expect.any(Number),
        traffic: expect.any(Number),
        length: expect.any(Number),
        fatigue: expect.any(Number),
        highway: expect.any(Number),
        maneuvers: expect.any(Number),
        navDensity: expect.any(Number),
        effort: expect.any(Number),
      },
      contributions: expect.any(Array),
      uncertainty: {
        low: expect.any(Number),
        high: expect.any(Number),
        confidence: expect.any(Number),
        spread: expect.any(Number),
      },
      hotspots: expect.any(Array),
      modelVersion: expect.any(String),
      distanceMeters: expect.any(Number),
      durationSeconds: expect.any(Number),
      staticDurationSeconds: expect.any(Number),
      trafficDelaySeconds: expect.any(Number),
      polyline: expect.any(String),
      bounds: {
        southwest: { lat: expect.any(Number), lng: expect.any(Number) },
        northeast: { lat: expect.any(Number), lng: expect.any(Number) },
      },
    });
  });
});

const short10min = {
  ...highwayRoute,
  distanceMeters: 19_312,
  durationSeconds: 600,
  staticDurationSeconds: 600,
  steps: [
    {
      distanceMeters: 18_000,
      staticDurationSeconds: 560,
      maneuver: "DEPART",
      navigationInstruction: "Head north on I-95",
    },
    {
      distanceMeters: 1_312,
      staticDurationSeconds: 40,
      maneuver: "RAMP_RIGHT",
      navigationInstruction: "Take exit",
    },
  ],
};

const threeHour = {
  ...highwayRoute,
  distanceMeters: 337_962,
  durationSeconds: 10_800,
  staticDurationSeconds: 10_800,
  steps: [
    {
      distanceMeters: 320_000,
      staticDurationSeconds: 10_200,
      maneuver: "DEPART",
      navigationInstruction: "Head north on I-95",
    },
    {
      distanceMeters: 12_000,
      staticDurationSeconds: 400,
      maneuver: "STRAIGHT",
      navigationInstruction: "Continue on I-95",
    },
    {
      distanceMeters: 5_962,
      staticDurationSeconds: 200,
      maneuver: "RAMP_RIGHT",
      navigationInstruction: "Take exit",
    },
  ],
};

describe("duration separation", () => {
  it("scores long drives much higher than short hops on similar roads", () => {
    const short = scoreRoute(short10min);
    const medium = scoreRoute(highwayRoute);
    const long = scoreRoute(threeHour);

    expect(short.score).toBeLessThan(3.5);
    expect(long.score).toBeGreaterThan(short.score + 2);
    expect(long.score).toBeGreaterThan(medium.score);
    expect(medium.score).toBeGreaterThan(short.score);
    expect(long.score).toBeLessThan(7.5);
  });
});

describe("explanation weights", () => {
  it("keeps the structural factor weights identical to the scoring weights", () => {
    // These weights rank the reasons shown to the user. A copy drifts: this
    // caught `traffic` sitting at 0.20 against a real weight of 0.14.
    expect(FACTOR_WEIGHTS.speed).toBe(BASE_SCORE_WEIGHTS.S);
    expect(FACTOR_WEIGHTS.merges).toBe(BASE_SCORE_WEIGHTS.M);
    expect(FACTOR_WEIGHTS.turns).toBe(BASE_SCORE_WEIGHTS.T);
    expect(FACTOR_WEIGHTS.traffic).toBe(BASE_SCORE_WEIGHTS.C);
    expect(FACTOR_WEIGHTS.length).toBe(BASE_SCORE_WEIGHTS.L);
  });
});
