import { describe, expect, it } from "vitest";
import { scoreRoute } from "../index.js";
import { neutralConditions } from "../../enrichment/types.js";
import { highwayRoute } from "./fixtures/highway-route.js";
import { urbanRoute } from "./fixtures/urban-route.js";
import { longDriveRoute } from "./fixtures/long-drive-route.js";
import {
  mergeClusterRoute,
  smoothHighwayEquivalent,
} from "./fixtures/merge-cluster-route.js";

function adverseConditions() {
  const base = neutralConditions();
  return {
    ...base,
    weather: {
      ...base.weather,
      available: true,
      condition: "Snow",
      severity: 0.9,
      snowRisk: 0.9,
      icyRisk: 0.9,
    },
    road: {
      ...base.road,
      available: true,
      constructionZones: 4,
    },
    sources: ["test"],
  };
}

/**
 * A regression corpus for task-demand ordering. These are intentionally score
 * bands, not a claim that the app predicts crash probability: validating that
 * would require road-specific crash exposure and a held-out outcome dataset.
 */
describe("route-demand calibration matrix", () => {
  it("keeps representative route types in stable, explainable bands", () => {
    const scenarios = [
      {
        name: "short uninterrupted freeway",
        result: scoreRoute(smoothHighwayEquivalent),
        min: 0,
        max: 2,
      },
      {
        name: "long freeway corridor",
        result: scoreRoute(highwayRoute),
        min: 2,
        max: 4,
      },
      {
        name: "freeway merge and weave cluster",
        result: scoreRoute(mergeClusterRoute),
        min: 5,
        max: 7,
      },
      {
        name: "dense urban intersections",
        result: scoreRoute(urbanRoute),
        min: 6,
        max: 8,
      },
      {
        name: "long, fatigued, snowy construction drive",
        result: scoreRoute(longDriveRoute, {
          departureTime: "2026-01-15T05:30:00.000Z",
          departureLocalMinutes: 23 * 60 + 30,
          continuousDriveMinutes: 180,
          conditions: adverseConditions(),
        }),
        min: 8,
        max: 10,
      },
    ];

    for (const scenario of scenarios) {
      expect(scenario.result.score, scenario.name).toBeGreaterThanOrEqual(
        scenario.min
      );
      expect(scenario.result.score, scenario.name).toBeLessThanOrEqual(
        scenario.max);
      expect(scenario.result.uncertainty.low).toBeLessThanOrEqual(
        scenario.result.score);
      expect(scenario.result.uncertainty.high).toBeGreaterThanOrEqual(
        scenario.result.score);
    }

    expect(scenarios[1].result.score).toBeGreaterThan(scenarios[0].result.score);
    expect(scenarios[2].result.score).toBeGreaterThan(scenarios[1].result.score);
    expect(scenarios[3].result.score).toBeGreaterThan(scenarios[1].result.score);
    expect(scenarios[4].result.score).toBeGreaterThan(scenarios[3].result.score);
  });
});
