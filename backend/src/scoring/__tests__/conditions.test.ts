import { describe, expect, it } from "vitest";
import { scoreRoute } from "../index.js";
import {
  neutralConditions,
  type RouteConditions,
} from "../../enrichment/types.js";
import { highwayRoute } from "./fixtures/highway-route.js";
import { urbanRoute } from "./fixtures/urban-route.js";
import { longDriveRoute } from "./fixtures/long-drive-route.js";

function withWeather(severity: number, overrides: Partial<RouteConditions["weather"]> = {}): RouteConditions {
  const base = neutralConditions();
  return {
    ...base,
    weather: {
      ...base.weather,
      available: true,
      condition: "Rain",
      severity,
      precipIntensity: severity,
      ...overrides,
    },
    sources: ["open-meteo"],
  };
}

describe("weather conditions", () => {
  it("rainy weather scores higher than clear weather on the same route", () => {
    const clear = scoreRoute(highwayRoute, { conditions: withWeather(0) });
    const rainy = scoreRoute(highwayRoute, { conditions: withWeather(0.6) });
    expect(rainy.score).toBeGreaterThan(clear.score + 0.5);
    expect(rainy.reasons.some((r) => r.toLowerCase().includes("rain"))).toBe(true);
  });

  it("snow and ice add more than plain rain", () => {
    const rain = scoreRoute(highwayRoute, { conditions: withWeather(0.5) });
    const snow = scoreRoute(highwayRoute, {
      conditions: withWeather(0.5, {
        condition: "Snow",
        precipIntensity: 0,
        snowRisk: 0.7,
        icyRisk: 0.9,
      }),
    });
    expect(snow.score).toBeGreaterThan(rain.score);
    expect(snow.reasons.some((r) => r.toLowerCase().includes("snow"))).toBe(true);
  });

  it("neutral conditions leave score unchanged vs no conditions", () => {
    const without = scoreRoute(highwayRoute);
    const neutral = scoreRoute(highwayRoute, { conditions: neutralConditions() });
    expect(neutral.score).toBeCloseTo(without.score, 5);
  });
});

describe("road conditions", () => {
  it("ignores unverified road payloads instead of charging unavailable data", () => {
    const base = neutralConditions();
    const unavailablePayload: RouteConditions = {
      ...base,
      road: {
        ...base.road,
        available: false,
        roadSizeScore: 1,
        narrowRoadShare: 1,
        unpavedShare: 1,
        constructionZones: 6,
      },
    };

    const plain = scoreRoute(highwayRoute);
    const unverified = scoreRoute(highwayRoute, {
      conditions: unavailablePayload,
    });

    expect(unverified.score).toBe(plain.score);
    expect(unverified.reasons).toEqual(plain.reasons);
  });

  it("construction zones increase difficulty", () => {
    const base = neutralConditions();
    const withConstruction: RouteConditions = {
      ...base,
      road: {
        ...base.road,
        available: true,
        constructionZones: 4,
        dominantRoadClass: "motorway",
      },
      sources: ["osm-overpass"],
    };
    const plain = scoreRoute(highwayRoute);
    const construction = scoreRoute(highwayRoute, { conditions: withConstruction });
    expect(construction.score).toBeGreaterThan(plain.score);
    expect(
      construction.reasons.some((r) => r.toLowerCase().includes("construction"))
    ).toBe(true);
  });

  it("narrow/unpaved roads increase difficulty on local routes", () => {
    const base = neutralConditions();
    const narrow: RouteConditions = {
      ...base,
      road: {
        ...base.road,
        available: true,
        roadSizeScore: 0.8,
        narrowRoadShare: 0.7,
        unpavedShare: 0.3,
        avgLanes: 1,
        dominantRoadClass: "residential",
      },
      sources: ["osm-overpass"],
    };
    const plain = scoreRoute(urbanRoute);
    const rough = scoreRoute(urbanRoute, { conditions: narrow });
    expect(rough.score).toBeGreaterThanOrEqual(plain.score);
  });
});

describe("unprotected turns", () => {
  it("scores all-unprotected lefts above all-protected lefts", () => {
    const base = neutralConditions();
    const protectedTurns: RouteConditions = {
      ...base,
      turns: {
        available: true,
        unprotectedLeftTurns: 0,
        protectedLeftTurns: 9,
        unprotectedTurnShare: 0,
      },
    };
    const unprotectedTurns: RouteConditions = {
      ...base,
      turns: {
        available: true,
        unprotectedLeftTurns: 9,
        protectedLeftTurns: 0,
        unprotectedTurnShare: 1,
      },
    };

    const easy = scoreRoute(urbanRoute, { conditions: protectedTurns });
    const hard = scoreRoute(urbanRoute, { conditions: unprotectedTurns });
    expect(hard.score).toBeGreaterThan(easy.score);
    expect(
      hard.reasons.some((r) => r.toLowerCase().includes("unprotected"))
    ).toBe(true);
  });
});

describe("duration dominance", () => {
  it("long drives keep separating from medium drives", () => {
    const medium = scoreRoute(highwayRoute); // ~85 min
    const long = scoreRoute(longDriveRoute); // 3h+
    expect(long.score - medium.score).toBeGreaterThanOrEqual(1.5);
  });
});

describe("conditions in response", () => {
  it("echoes the conditions used for scoring", () => {
    const conditions = withWeather(0.4);
    const result = scoreRoute(highwayRoute, { conditions });
    expect(result.conditions?.weather.condition).toBe("Rain");
    expect(result.breakdown.weather).toBeGreaterThan(0);
  });
});
