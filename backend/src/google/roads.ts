import { z } from "zod";
import type { ParsedRoute, SpeedLimitPoint } from "../types.js";
import { samplePolylinePoints } from "../utils/polyline.js";
import { impliedStepSpeedMph, speedLimitToMph } from "../scoring/signals.js";

const SNAP_URL = "https://roads.googleapis.com/v1/snapToRoads";
const SPEED_LIMITS_URL = "https://roads.googleapis.com/v1/speedLimits";

const CHUNK_SIZE = 100;
const CHUNK_OVERLAP = 10;
const TARGET_SAMPLE_COUNT = 80;
/** Bounds a single Roads API call so a slow upstream cannot hang the request. */
const FETCH_TIMEOUT_MS = 8000;

// Never trust the shape of an upstream response. A malformed `speedLimit`
// (for example a string instead of a number) must not silently poison
// scoring with NaN arithmetic — it is safer to drop the batch and degrade to
// implied speeds than to accept unvalidated data.
const errorEnvelope = z.object({
  message: z.string().optional(),
  code: z.number().optional(),
}).partial().optional();

const snapResponseSchema = z.object({
  snappedPoints: z.array(z.object({
    placeId: z.string(),
    originalIndex: z.number().int().nonnegative().optional(),
  }).passthrough()).optional(),
  error: errorEnvelope,
}).passthrough();

const speedLimitsResponseSchema = z.object({
  speedLimits: z.array(z.object({
    placeId: z.string(),
    speedLimit: z.number().finite().positive().optional(),
    units: z.string().optional(),
  }).passthrough()).optional(),
  error: errorEnvelope,
}).passthrough();

type SnappedPoint = z.infer<typeof snapResponseSchema>["snappedPoints"] extends
  (infer T)[] | undefined ? T : never;
type SpeedLimitEntry = z.infer<typeof speedLimitsResponseSchema>["speedLimits"] extends
  (infer T)[] | undefined ? T : never;

interface PointChunk<T> {
  points: T[];
  startIndex: number;
}

function chunkPoints<T>(points: T[], size: number, overlap: number): PointChunk<T>[] {
  if (points.length <= size) return [{ points, startIndex: 0 }];

  const chunks: PointChunk<T>[] = [];
  let start = 0;

  while (start < points.length) {
    const end = Math.min(start + size, points.length);
    chunks.push({ points: points.slice(start, end), startIndex: start });
    if (end >= points.length) break;
    start = end - overlap;
  }

  return chunks;
}

/**
 * Runs one Roads API call under a bounded timeout, validating the response
 * shape before any field is trusted. Every failure mode — network error,
 * timeout, non-2xx status, unparsable body, or a payload that doesn't match
 * the expected schema — normalizes to `RoadsAccessError` so callers have a
 * single, gracefully-degradable failure path instead of a raw exception.
 */
async function fetchRoadsApi<T extends z.ZodTypeAny>(
  url: string,
  schema: T,
  label: string
): Promise<z.infer<T>> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

  try {
    const response = await fetch(url, { signal: controller.signal });

    let raw: unknown;
    try {
      raw = await response.json();
    } catch {
      throw new RoadsAccessError(`${label} returned a non-JSON response`);
    }

    const parsed = schema.safeParse(raw);

    if (!response.ok) {
      const message = parsed.success
        ? (parsed.data as { error?: { message?: string } }).error?.message
        : undefined;
      throw new RoadsAccessError(message ?? `${label} error: ${response.status}`);
    }

    if (!parsed.success) {
      throw new RoadsAccessError(`${label} returned an unexpected payload`);
    }

    return parsed.data;
  } catch (error) {
    if (error instanceof RoadsAccessError) throw error;
    // Never surface the raw error (it may echo request details); a fetch
    // failure or abort is enough information for the graceful-degradation path.
    throw new RoadsAccessError(`${label} request failed`);
  } finally {
    clearTimeout(timer);
  }
}

async function snapToRoads(
  points: { lat: number; lng: number }[],
  apiKey: string
): Promise<SnappedPoint[]> {
  const path = points.map((p) => `${p.lat},${p.lng}`).join("|");
  const url = `${SNAP_URL}?interpolate=true&path=${encodeURIComponent(path)}&key=${apiKey}`;

  const data = await fetchRoadsApi(url, snapResponseSchema, "snapToRoads");
  return data.snappedPoints ?? [];
}

async function fetchSpeedLimits(
  placeIds: string[],
  apiKey: string
): Promise<SpeedLimitEntry[]> {
  const results: SpeedLimitEntry[] = [];

  for (let i = 0; i < placeIds.length; i += 100) {
    const batch = placeIds.slice(i, i + 100);
    const params = batch.map((id) => `placeId=${encodeURIComponent(id)}`).join("&");
    const url = `${SPEED_LIMITS_URL}?${params}&key=${apiKey}`;

    const data = await fetchRoadsApi(url, speedLimitsResponseSchema, "speedLimits");
    results.push(...(data.speedLimits ?? []));
  }

  return results;
}

export class RoadsAccessError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RoadsAccessError";
  }
}

export async function getSpeedLimitsForRoute(
  route: ParsedRoute,
  apiKey: string
): Promise<SpeedLimitPoint[]> {
  const sampled = samplePolylinePoints(route.polyline, TARGET_SAMPLE_COUNT);
  if (sampled.length === 0) return [];

  const chunks = chunkPoints(sampled, CHUNK_SIZE, CHUNK_OVERLAP);
  const allSnapped: Array<SnappedPoint & { sampleIndex: number }> = [];

  for (const chunk of chunks) {
    const snapped = await snapToRoads(chunk.points, apiKey);
    for (const point of snapped) {
      // Interpolated points lack a stable original index. Ignoring them is more
      // conservative than assigning their limit to an arbitrary route step.
      if (point.originalIndex === undefined) continue;
      allSnapped.push({
        ...point,
        sampleIndex: chunk.startIndex + point.originalIndex,
      });
    }
  }

  const uniquePlaceIds = [...new Set(allSnapped.map((p) => p.placeId))];
  if (uniquePlaceIds.length === 0) return [];

  const limits = await fetchSpeedLimits(uniquePlaceIds, apiKey);

  const limitByPlace = new Map(limits.map((entry) => [entry.placeId, entry]));
  return allSnapped.flatMap((point) => {
    const limit = limitByPlace.get(point.placeId);
    if (!limit?.speedLimit) return [];
    return [{
      placeId: point.placeId,
      speedLimit: limit.speedLimit,
      speedLimitUnit: limit.units === "KPH" ? "KPH" : "MPH" as const,
      sampleIndex: point.sampleIndex,
      sampleCount: sampled.length,
    }];
  });
}

/** Map per-step implied or posted speeds in mph for scoring. */
export function buildStepSpeedMap(route: ParsedRoute): Map<number, number> {
  const map = new Map<number, number>();
  route.steps.forEach((step, index) => {
    map.set(index, impliedStepSpeedMph(step));
  });
  return map;
}

export interface SpeedLimitEnrichment {
  stepSpeedsMph: Map<number, number>;
  /**
   * Distance-weighted share of route steps with at least one positioned posted
   * speed limit. Inferred speeds do not contribute to this provenance value.
   */
  postedSpeedLimitCoverage: number;
  source: "posted" | "mixed" | "implied";
}

/**
 * Merge posted limits only into the step that contains each sampled route point.
 * This avoids incorrectly applying a route-wide average (for example, a freeway
 * speed limit) to residential approach streets.
 */
export function enrichStepSpeeds(
  route: ParsedRoute,
  speedLimits: SpeedLimitPoint[]
): SpeedLimitEnrichment {
  const stepSpeeds = buildStepSpeedMap(route);

  if (speedLimits.length === 0) {
    return { stepSpeedsMph: stepSpeeds, postedSpeedLimitCoverage: 0, source: "implied" };
  }

  const totalDistance = route.steps.reduce((sum, step) => sum + Math.max(0, step.distanceMeters), 0);
  if (totalDistance <= 0) {
    return { stepSpeedsMph: stepSpeeds, postedSpeedLimitCoverage: 0, source: "implied" };
  }

  const limitsByStep = new Map<number, number[]>();
  for (const limit of speedLimits) {
    if (limit.speedLimit === undefined || limit.sampleIndex === undefined) continue;
    const sampleCount = limit.sampleCount ?? 0;
    if (sampleCount < 2) continue;
    const position = (limit.sampleIndex / (sampleCount - 1)) * totalDistance;
    let cumulative = 0;
    for (let index = 0; index < route.steps.length; index++) {
      cumulative += Math.max(0, route.steps[index].distanceMeters);
      if (position <= cumulative || index === route.steps.length - 1) {
        const speeds = limitsByStep.get(index) ?? [];
        speeds.push(speedLimitToMph(limit.speedLimit, limit.speedLimitUnit));
        limitsByStep.set(index, speeds);
        break;
      }
    }
  }

  for (const [index, postedSpeeds] of limitsByStep) {
    const postedAverage = postedSpeeds.reduce((sum, speed) => sum + speed, 0) / postedSpeeds.length;
    const implied = impliedStepSpeedMph(route.steps[index]);
    stepSpeeds.set(index, implied > 0 ? postedAverage * 0.8 + implied * 0.2 : postedAverage);
  }

  const coveredDistance = [...limitsByStep.keys()].reduce(
    (sum, index) => sum + Math.max(0, route.steps[index]?.distanceMeters ?? 0),
    0
  );
  const postedSpeedLimitCoverage = Math.max(0, Math.min(1, coveredDistance / totalDistance));

  return {
    stepSpeedsMph: stepSpeeds,
    postedSpeedLimitCoverage,
    source: postedSpeedLimitCoverage >= 0.999
      ? "posted"
      : postedSpeedLimitCoverage > 0
        ? "mixed"
        : "implied",
  };
}

/** For callers that only need blended speeds; use `enrichStepSpeeds` to keep provenance. */
export function applySpeedLimitsToSteps(
  route: ParsedRoute,
  speedLimits: SpeedLimitPoint[]
): Map<number, number> {
  return enrichStepSpeeds(route, speedLimits).stepSpeedsMph;
}

export async function enrichRouteWithSpeedLimits(
  route: ParsedRoute,
  apiKey: string
): Promise<SpeedLimitEnrichment> {
  try {
    const limits = await getSpeedLimitsForRoute(route, apiKey);
    return enrichStepSpeeds(route, limits);
  } catch (error) {
    if (error instanceof RoadsAccessError) {
      return enrichStepSpeeds(route, []);
    }
    throw error;
  }
}
