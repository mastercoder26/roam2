import { describe, expect, it } from "vitest";
import {
  ROUTE_DEMAND_IDS,
  type ParsedRoute,
  type RouteDemand,
} from "../../types.js";
import { neutralConditions, type RouteConditions } from "../../enrichment/types.js";
import { scoreRoute } from "../index.js";
import { highwayRoute } from "./fixtures/highway-route.js";
import { longDriveRoute } from "./fixtures/long-drive-route.js";
import { mergeClusterRoute } from "./fixtures/merge-cluster-route.js";
import { trafficHeavyRoute, trafficLightRoute } from "./fixtures/traffic-route.js";
import { urbanRoute } from "./fixtures/urban-route.js";

function routeDemand(
  result: ReturnType<typeof scoreRoute>,
  id: RouteDemand["id"]
): RouteDemand {
  const demand = result.routeDemands.find((item) => item.id === id);
  if (!demand) throw new Error(`Missing ${id} demand`);
  return demand;
}

function encodePolyline(points: Array<{ lat: number; lng: number }>): string {
  const encodeValue = (input: number): string => {
    let value = input < 0 ? ~(input << 1) : input << 1;
    let encoded = "";
    while (value >= 0x20) {
      encoded += String.fromCharCode((0x20 | (value & 0x1f)) + 63);
      value >>= 5;
    }
    return encoded + String.fromCharCode(value + 63);
  };

  let previousLatitude = 0;
  let previousLongitude = 0;
  return points.reduce((encoded, point) => {
    const latitude = Math.round(point.lat * 100_000);
    const longitude = Math.round(point.lng * 100_000);
    const next =
      encoded +
      encodeValue(latitude - previousLatitude) +
      encodeValue(longitude - previousLongitude);
    previousLatitude = latitude;
    previousLongitude = longitude;
    return next;
  }, "");
}

/**
 * The provider step meters are deliberately very different from its overview
 * geometry. A valid coverage range must still follow the overview geometry,
 * not the provider-meter ratios used by scoring metrics.
 */
function geometryBackedRoute(): ParsedRoute {
  const points = [
    { lat: 0, lng: 0 },
    { lat: 0, lng: 0.01 },
    { lat: 0, lng: 0.02 },
    { lat: 0, lng: 0.03 },
  ];
  const stepPolyline = (start: number, end: number) =>
    encodePolyline(points.slice(start, end + 1));

  return {
    distanceMeters: 10_200,
    durationSeconds: 90,
    staticDurationSeconds: 90,
    polyline: encodePolyline(points),
    bounds: {
      southwest: points[0],
      northeast: points[3],
    },
    steps: [
      {
        distanceMeters: 100,
        staticDurationSeconds: 30,
        maneuver: "DEPART",
        navigationInstruction: "Head east",
        polyline: stepPolyline(0, 1),
      },
      {
        distanceMeters: 10_000,
        staticDurationSeconds: 30,
        maneuver: "MERGE",
        navigationInstruction: "Merge onto Route 1",
        polyline: stepPolyline(1, 2),
      },
      {
        distanceMeters: 100,
        staticDurationSeconds: 30,
        maneuver: "TURN_LEFT",
        navigationInstruction: "Turn left onto Main Street",
        polyline: stepPolyline(2, 3),
      },
    ],
  };
}

describe("route demands", () => {
  it("always returns the complete, stable demand list", () => {
    const result = scoreRoute(highwayRoute);

    expect(result.routeDemands.map((item) => item.id)).toEqual(ROUTE_DEMAND_IDS);
    for (const item of result.routeDemands) {
      expect(item.intensity).toBeGreaterThanOrEqual(0);
      expect(item.intensity).toBeLessThanOrEqual(1);
      expect(["low", "moderate", "high"]).toContain(item.level);
      expect(item.evidence.length).toBeGreaterThan(0);
    }
  });

  it("uses the client-local clock instead of the timestamp's UTC hour", () => {
    const daytime = scoreRoute(longDriveRoute, {
      departureTime: "2026-06-06T03:00:00.000Z",
      departureLocalMinutes: 13 * 60,
    });
    const nighttime = scoreRoute(longDriveRoute, {
      departureTime: "2026-06-06T03:00:00.000Z",
      departureLocalMinutes: 22 * 60,
    });

    expect(routeDemand(daytime, "afterDark").intensity).toBe(0);
    expect(routeDemand(nighttime, "afterDark")).toMatchObject({
      available: true,
      intensity: 1,
      level: "high",
    });
    expect(nighttime.breakdown.fatigue).toBeGreaterThan(
      daytime.breakdown.fatigue
    );
  });

  it("tracks a route's progress into the after-dark window", () => {
    const result = scoreRoute(longDriveRoute, {
      departureLocalMinutes: 19 * 60 + 30,
    });

    const afterDark = routeDemand(result, "afterDark");
    expect(afterDark.intensity).toBeCloseTo(0.83, 2);
    expect(afterDark.metrics).toMatchObject({
      nightMiles: expect.any(Number),
      expectedDurationSeconds: longDriveRoute.durationSeconds,
      departureLocalMinutes: 19 * 60 + 30,
    });
    expect(afterDark.metrics?.nightMiles).toBeGreaterThan(200);
    // This fixture intentionally lacks valid route/step geometry. The server
    // must omit structural ranges rather than substitute provider step meters.
    expect(afterDark.coverageRanges).toBeUndefined();
  });

  it("makes fast-road, merge, and intersection demands factual", () => {
    const highway = scoreRoute(highwayRoute);
    const mergeCluster = scoreRoute(mergeClusterRoute);
    const urban = scoreRoute(urbanRoute);

    expect(routeDemand(highway, "fastRoads")).toMatchObject({
      available: true,
      level: "high",
    });
    expect(routeDemand(highway, "fastRoads").metrics).toMatchObject({
      estimatedMilesAt45: expect.any(Number),
      estimatedMilesAt55: expect.any(Number),
      estimatedMilesAt60: expect.any(Number),
      estimatedMilesAt65: expect.any(Number),
    });
    expect(
      routeDemand(highway, "fastRoads").metrics?.estimatedMilesAt45
    ).toBeGreaterThan(90);
    expect(routeDemand(highway, "fastRoads").coverageRanges).toBeUndefined();
    expect(routeDemand(mergeCluster, "merges").intensity).toBeGreaterThan(0.4);
    expect(routeDemand(mergeCluster, "merges").evidence).toContain("merge");
    expect(routeDemand(mergeCluster, "merges").metrics?.mergeTransitionCount).toBe(6);
    expect(routeDemand(mergeCluster, "merges").coverageRanges).toBeUndefined();
    expect(routeDemand(mergeCluster, "merges").metrics?.coverageFraction).toBeUndefined();
    expect(routeDemand(urban, "complexIntersections").intensity).toBeGreaterThan(
      0.6
    );
    expect(
      routeDemand(urban, "complexIntersections").metrics
        ?.intersectionInstructionCount
    ).toBeGreaterThan(0);
    expect(routeDemand(urban, "complexIntersections").coverageRanges).toBeUndefined();
  });

  it("uses the same per-step speeds as scoring for fast-road evidence", () => {
    const slowStepSpeeds = new Map(
      highwayRoute.steps.map((_step, index) => [index, 25])
    );
    const result = scoreRoute(highwayRoute, {
      stepSpeedsMph: slowStepSpeeds,
    });
    const fastRoads = routeDemand(result, "fastRoads");

    expect(fastRoads.metrics).toMatchObject({
      estimatedMilesAt45: 0,
      estimatedMilesAt55: 0,
      estimatedMilesAt60: 0,
      estimatedMilesAt65: 0,
    });
    expect(fastRoads.coverageRanges).toBeUndefined();
  });

  it("emits factual duration and traffic metrics without inventing section coverage", () => {
    const result = scoreRoute(trafficHeavyRoute);
    const sustained = routeDemand(result, "sustainedDrive");
    const traffic = routeDemand(result, "traffic");

    expect(sustained.metrics).toMatchObject({
      expectedDurationMinutes: trafficHeavyRoute.durationSeconds / 60,
      routeDistanceMeters: trafficHeavyRoute.distanceMeters,
    });
    expect(sustained.coverageRanges).toBeUndefined();
    expect(traffic.metrics).toMatchObject({
      trafficDelaySeconds:
        trafficHeavyRoute.durationSeconds - trafficHeavyRoute.staticDurationSeconds,
      trafficAwareDurationSeconds: trafficHeavyRoute.durationSeconds,
    });
    // Traffic is currently route-level ETA data; it has no verified
    // step-specific delay locations.
    expect(traffic.coverageRanges).toBeUndefined();
  });

  it("keeps unsupported weather and road data unavailable", () => {
    const result = scoreRoute(highwayRoute, {
      conditions: neutralConditions(),
    });

    expect(routeDemand(result, "weatherVisibility")).toMatchObject({
      available: false,
      intensity: 0,
    });
    expect(routeDemand(result, "roadConditions")).toMatchObject({
      available: false,
      intensity: 0,
    });
  });

  it("requires a successful source before exposing weather or road conditions", () => {
    const base = neutralConditions();
    const unverified: RouteConditions = {
      ...base,
      weather: {
        ...base.weather,
        available: true,
        condition: "Rain",
        severity: 0.9,
      },
      road: {
        ...base.road,
        available: true,
        constructionZones: 3,
      },
      sources: [],
    };
    const result = scoreRoute(highwayRoute, { conditions: unverified });

    expect(routeDemand(result, "weatherVisibility").available).toBe(false);
    expect(routeDemand(result, "roadConditions").available).toBe(false);
  });

  it("uses only available weather and road sources in their demands", () => {
    const base = neutralConditions();
    const conditions: RouteConditions = {
      ...base,
      weather: {
        ...base.weather,
        available: true,
        condition: "Rain",
        severity: 0.8,
        lowVisibilityRisk: 0.6,
        visibilityMiles: 2.5,
      },
      road: {
        ...base.road,
        available: true,
        constructionZones: 2,
        narrowRoadShare: 0.25,
      },
      sources: ["open-meteo", "osm-overpass"],
    };
    const result = scoreRoute(highwayRoute, { conditions });

    expect(routeDemand(result, "weatherVisibility")).toMatchObject({
      available: true,
      level: "high",
    });
    expect(routeDemand(result, "weatherVisibility").evidence).toContain("Rain");
    expect(routeDemand(result, "weatherVisibility").metrics).toMatchObject({
      weatherSeverity: 0.8,
      lowVisibilityRisk: 0.6,
      visibilityMiles: 2.5,
    });
    expect(
      routeDemand(result, "weatherVisibility").coverageRanges
    ).toBeUndefined();
    expect(routeDemand(result, "roadConditions")).toMatchObject({
      available: true,
      level: "moderate",
    });
    expect(routeDemand(result, "roadConditions").metrics).toMatchObject({
      constructionZoneCount: 2,
      narrowRoadShare: 0.25,
    });
    expect(routeDemand(result, "roadConditions").coverageRanges).toBeUndefined();
  });

  it("reports traffic from traffic-aware duration without inventing road data", () => {
    const light = scoreRoute(trafficLightRoute);
    const heavy = scoreRoute(trafficHeavyRoute);

    expect(routeDemand(heavy, "traffic").intensity).toBeGreaterThan(
      routeDemand(light, "traffic").intensity
    );
    expect(routeDemand(heavy, "traffic").evidence).toContain("longer");
    expect(routeDemand(heavy, "roadConditions").available).toBe(false);
  });

  it("bases structural coverage on validated overview-polyline geometry", () => {
    const result = scoreRoute(geometryBackedRoute(), {
      departureLocalMinutes: 19 * 60 + 59,
    });
    const fastRoads = routeDemand(result, "fastRoads");
    const merges = routeDemand(result, "merges");
    const intersections = routeDemand(result, "complexIntersections");
    const afterDark = routeDemand(result, "afterDark");
    const sustained = routeDemand(result, "sustainedDrive");

    // Step two accounts for ~98% of provider meters, but exactly one third of
    // the validated overview geometry. The emitted fast-road range must use
    // the latter basis so it matches the route polyline decoded on iOS.
    expect(fastRoads.coverageRanges).toEqual([
      { startFraction: 0.33333, endFraction: 0.66667 },
    ]);
    expect(merges.coverageRanges?.[0]?.startFraction).toBeCloseTo(0.59, 2);
    expect(merges.coverageRanges?.[0]?.endFraction).toBeCloseTo(0.74, 2);
    expect(intersections.coverageRanges?.[0]?.startFraction).toBeCloseTo(0.955, 2);
    expect(afterDark.coverageRanges).toEqual([
      { startFraction: 0.66667, endFraction: 1 },
    ]);
    expect(sustained.coverageRanges).toEqual([
      { startFraction: 0, endFraction: 1 },
    ]);
  });

  it("omits all structural ranges when overview geometry cannot map every step", () => {
    const route = geometryBackedRoute();
    route.steps[1] = { ...route.steps[1], polyline: undefined };
    const result = scoreRoute(route, { departureLocalMinutes: 20 * 60 });

    for (const id of [
      "afterDark",
      "fastRoads",
      "merges",
      "complexIntersections",
      "sustainedDrive",
    ] as const) {
      expect(routeDemand(result, id).coverageRanges).toBeUndefined();
    }
  });

  it("omits structural ranges when the full overview polyline is invalid", () => {
    const route = geometryBackedRoute();
    route.polyline = "encoded_highway_polyline";
    const result = scoreRoute(route, { departureLocalMinutes: 20 * 60 });

    for (const id of [
      "afterDark",
      "fastRoads",
      "merges",
      "complexIntersections",
      "sustainedDrive",
    ] as const) {
      expect(routeDemand(result, id).coverageRanges).toBeUndefined();
    }
  });

  it("keeps structural coverage ranges ordered and bounded", () => {
    const result = scoreRoute(mergeClusterRoute, {
      departureLocalMinutes: 22 * 60,
    });

    for (const demand of result.routeDemands) {
      for (const range of demand.coverageRanges ?? []) {
        expect(range.startFraction).toBeGreaterThanOrEqual(0);
        expect(range.endFraction).toBeLessThanOrEqual(1);
        expect(range.endFraction).toBeGreaterThan(range.startFraction);
      }
      const ranges = demand.coverageRanges ?? [];
      for (let index = 1; index < ranges.length; index++) {
        expect(ranges[index].startFraction).toBeGreaterThanOrEqual(
          ranges[index - 1].endFraction
        );
      }
    }
  });
});
