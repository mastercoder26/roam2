import type { LatLng } from "../types.js";

/**
 * Distance-indexed geometry for one valid encoded polyline. Consumers can use
 * this to keep route-progress calculations on the same geometric basis as the
 * overview polyline that clients render and match against.
 */
export interface PolylineGeometry {
  points: LatLng[];
  cumulativeMeters: number[];
  totalMeters: number;
}

/** A closest point projected onto a `PolylineGeometry`. */
export interface PolylineProjection {
  distanceMeters: number;
  distanceAlongMeters: number;
  fraction: number;
}

/** Decode a Google encoded polyline into lat/lng points. */
export function decodePolyline(encoded: string): LatLng[] {
  const points: LatLng[] = [];
  let index = 0;
  let lat = 0;
  let lng = 0;

  while (index < encoded.length) {
    let shift = 0;
    let result = 0;
    let byte: number;

    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);

    lat += result & 1 ? ~(result >> 1) : result >> 1;

    shift = 0;
    result = 0;

    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);

    lng += result & 1 ? ~(result >> 1) : result >> 1;

    points.push({ lat: lat / 1e5, lng: lng / 1e5 });
  }

  return points;
}

function haversineMeters(a: LatLng, b: LatLng): number {
  const R = 6371000;
  const dLat = ((b.lat - a.lat) * Math.PI) / 180;
  const dLng = ((b.lng - a.lng) * Math.PI) / 180;
  const lat1 = (a.lat * Math.PI) / 180;
  const lat2 = (b.lat * Math.PI) / 180;
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

function isValidLatLng(point: LatLng): boolean {
  return (
    Number.isFinite(point.lat) &&
    Number.isFinite(point.lng) &&
    point.lat >= -90 &&
    point.lat <= 90 &&
    point.lng >= -180 &&
    point.lng <= 180
  );
}

function normalizedLongitudeDelta(degrees: number): number {
  const wrapped = degrees % 360;
  if (wrapped > 180) return wrapped - 360;
  if (wrapped < -180) return wrapped + 360;
  return wrapped;
}

/**
 * Builds a usable distance index for an overview or step polyline. Invalid,
 * degenerate, and one-point payloads return `undefined` so callers omit
 * location-specific claims instead of falling back to a different distance basis.
 */
export function buildPolylineGeometry(
  encoded: string | undefined | null
): PolylineGeometry | undefined {
  if (!encoded) return undefined;

  const points = decodePolyline(encoded);
  if (points.length < 2 || !points.every(isValidLatLng)) return undefined;

  const cumulativeMeters = [0];
  let totalMeters = 0;
  for (let index = 1; index < points.length; index++) {
    const distance = haversineMeters(points[index - 1], points[index]);
    if (!Number.isFinite(distance) || distance < 0) return undefined;
    totalMeters += distance;
    cumulativeMeters.push(totalMeters);
  }

  // A few meters of geometry are not enough to resolve a reliable route
  // position, and zero-length points cannot support a progress fraction.
  if (!Number.isFinite(totalMeters) || totalMeters < 5) return undefined;

  return { points, cumulativeMeters, totalMeters };
}

/**
 * Finds the closest position on a geometry using a local equirectangular
 * projection. The result is suitable for short-distance route matching and
 * returns progress on the *overview geometry*, never on provider step meters.
 */
export function projectPointOntoPolyline(
  point: LatLng,
  geometry: PolylineGeometry,
  minimumDistanceAlongMeters = 0
): PolylineProjection | undefined {
  if (!isValidLatLng(point)) return undefined;

  const earthRadiusMeters = 6_371_000;
  const radians = Math.PI / 180;
  const referenceLatitude = point.lat * radians;
  let closest: PolylineProjection | undefined;

  for (let index = 1; index < geometry.points.length; index++) {
    const segmentStartDistance = geometry.cumulativeMeters[index - 1];
    const segmentEndDistance = geometry.cumulativeMeters[index];
    if (segmentEndDistance < minimumDistanceAlongMeters) continue;

    const start = geometry.points[index - 1];
    const end = geometry.points[index];
    const project = (coordinate: LatLng) => {
      const longitudeDelta =
        normalizedLongitudeDelta(coordinate.lng - point.lng) * radians;
      return {
        x: longitudeDelta * earthRadiusMeters * Math.cos(referenceLatitude),
        y: (coordinate.lat - point.lat) * radians * earthRadiusMeters,
      };
    };

    const a = project(start);
    const b = project(end);
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const lengthSquared = dx * dx + dy * dy;
    if (lengthSquared <= 0) continue;

    const unconstrainedProgress = Math.min(
      1,
      Math.max(0, -(a.x * dx + a.y * dy) / lengthSquared)
    );
    const segmentLength = segmentEndDistance - segmentStartDistance;
    const minimumProgress =
      segmentLength > 0
        ? Math.min(
            1,
            Math.max(
              0,
              (minimumDistanceAlongMeters - segmentStartDistance) / segmentLength
            )
          )
        : 1;
    const progress = Math.max(unconstrainedProgress, minimumProgress);
    const distanceAlongMeters = segmentStartDistance + segmentLength * progress;
    const distanceMeters = Math.hypot(a.x + progress * dx, a.y + progress * dy);
    const candidate: PolylineProjection = {
      distanceMeters,
      distanceAlongMeters,
      fraction: distanceAlongMeters / geometry.totalMeters,
    };

    if (!closest || candidate.distanceMeters < closest.distanceMeters) {
      closest = candidate;
    }
  }

  return closest;
}

/** Sample evenly spaced points along a polyline (default ~80 points). */
export function samplePolylinePoints(
  encoded: string,
  targetCount = 80
): LatLng[] {
  const decoded = decodePolyline(encoded);
  if (decoded.length === 0) return [];
  if (decoded.length === 1) return decoded;
  if (decoded.length <= targetCount) return decoded;

  const cumulative: number[] = [0];
  for (let i = 1; i < decoded.length; i++) {
    cumulative.push(cumulative[i - 1] + haversineMeters(decoded[i - 1], decoded[i]));
  }

  const total = cumulative[cumulative.length - 1];
  if (total === 0) return [decoded[0]];

  const samples: LatLng[] = [];
  const step = total / (targetCount - 1);

  for (let s = 0; s < targetCount; s++) {
    const target = s === targetCount - 1 ? total : s * step;
    let seg = 0;
    while (seg < cumulative.length - 1 && cumulative[seg + 1] < target) {
      seg++;
    }

    const segStart = cumulative[seg];
    const segEnd = cumulative[seg + 1];
    const t =
      segEnd === segStart ? 0 : (target - segStart) / (segEnd - segStart);

    const a = decoded[seg];
    const b = decoded[Math.min(seg + 1, decoded.length - 1)];
    samples.push({
      lat: a.lat + t * (b.lat - a.lat),
      lng: a.lng + t * (b.lng - a.lng),
    });
  }

  return samples;
}

/** Parse protobuf duration strings like "5309s" into seconds. */
export function parseDurationSeconds(value: string | undefined | null): number {
  if (!value) return 0;
  const match = value.match(/^(\d+(?:\.\d+)?)s$/);
  if (!match) return 0;
  return Math.round(parseFloat(match[1]));
}
