import { describe, expect, it } from "vitest";
import {
  buildPolylineGeometry,
  decodePolyline,
  projectPointOntoPolyline,
  samplePolylinePoints,
} from "../polyline.js";

describe("polyline utilities", () => {
  it("decodes a known encoded polyline", () => {
    const points = decodePolyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@");
    expect(points.length).toBeGreaterThan(1);
    expect(points[0]).toHaveProperty("lat");
    expect(points[0]).toHaveProperty("lng");
  });

  it("samples evenly spaced points up to target count", () => {
    const encoded = "_p~iF~ps|U_ulLnnqC_mqNvxq`@";
    const decoded = decodePolyline(encoded);
    const sampled = samplePolylinePoints(encoded, 10);
    expect(sampled.length).toBe(Math.min(decoded.length, 10));
    expect(sampled.length).toBeGreaterThan(0);
  });

  it("builds validated geometry and projects progress onto it", () => {
    const encoded = "_p~iF~ps|U_ulLnnqC_mqNvxq`@";
    const geometry = buildPolylineGeometry(encoded);
    expect(geometry).toBeDefined();
    expect(geometry!.totalMeters).toBeGreaterThan(0);

    const middle = geometry!.points[1];
    const projection = projectPointOntoPolyline(middle, geometry!);
    expect(projection?.distanceMeters).toBeCloseTo(0, 3);
    expect(projection?.fraction).toBeCloseTo(
      geometry!.cumulativeMeters[1] / geometry!.totalMeters,
      5
    );

    expect(buildPolylineGeometry("encoded_highway_polyline")).toBeUndefined();
  });
});
