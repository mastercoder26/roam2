import type { LatLng, ParsedRoute } from "../types.js";
import { decodePolyline, samplePolylinePoints } from "../utils/polyline.js";
import {
  neutralRoad,
  neutralTurns,
  type RoadConditions,
  type TurnExposure,
} from "./types.js";
import { determineTurnProtection } from "./turnProtection.js";

const DEFAULT_OVERPASS_URL = "https://overpass-api.de/api/interpreter";
const FETCH_TIMEOUT_MS = 9000;
const ROAD_SAMPLE_POINTS = 24;
const MAX_TURN_POINTS = 25;
const WAY_MATCH_RADIUS_M = 40;

const LEFT_TURN_MANEUVERS = new Set([
  "TURN_LEFT",
  "TURN_SHARP_LEFT",
  "UTURN_LEFT",
]);

/** Per-class narrowness/difficulty prior (0 = wide major road, 1 = tiny lane). */
const CLASS_NARROWNESS: Record<string, number> = {
  motorway: 0,
  motorway_link: 0.1,
  trunk: 0.1,
  trunk_link: 0.15,
  primary: 0.2,
  primary_link: 0.25,
  secondary: 0.3,
  secondary_link: 0.35,
  tertiary: 0.45,
  tertiary_link: 0.5,
  unclassified: 0.6,
  residential: 0.7,
  living_street: 0.9,
  service: 0.9,
  track: 1,
  road: 0.5,
};

const DEFAULT_LANES: Record<string, number> = {
  motorway: 3,
  trunk: 2.5,
  primary: 2,
  secondary: 2,
  tertiary: 1.5,
  unclassified: 1,
  residential: 1,
  living_street: 1,
  service: 1,
  track: 1,
};

const UNPAVED_SURFACES = new Set([
  "unpaved",
  "gravel",
  "dirt",
  "ground",
  "sand",
  "grass",
  "compacted",
  "fine_gravel",
  "earth",
  "mud",
]);

interface OverpassWay {
  type: "way";
  id: number;
  tags?: Record<string, string>;
  geometry?: Array<{ lat: number; lon: number }>;
}

interface OverpassNode {
  type: "node";
  id: number;
  lat: number;
  lon: number;
  tags?: Record<string, string>;
}

interface OverpassResponse {
  elements?: Array<OverpassWay | OverpassNode>;
}

export interface OsmRouteData {
  road: RoadConditions;
  turns: TurnExposure;
  available: boolean;
}

function metersBetween(a: LatLng, b: { lat: number; lng: number }): number {
  const latRad = ((a.lat + b.lat) / 2) * (Math.PI / 180);
  const dLat = (b.lat - a.lat) * 111_320;
  const dLng = (b.lng - a.lng) * 111_320 * Math.cos(latRad);
  return Math.sqrt(dLat * dLat + dLng * dLng);
}

/** Distance from a point to the closest point on a polyline segment. */
function pointToSegmentDistance(
  point: LatLng,
  a: { lat: number; lng: number },
  b: { lat: number; lng: number }
): number {
  const ax = a.lng;
  const ay = a.lat;
  const bx = b.lng;
  const by = b.lat;
  const px = point.lng;
  const py = point.lat;
  const dx = bx - ax;
  const dy = by - ay;
  if (dx === 0 && dy === 0) {
    return metersBetween(point, { lat: ay, lng: ax });
  }
  const t = Math.max(
    0,
    Math.min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy))
  );
  return metersBetween(point, { lat: ay + t * dy, lng: ax + t * dx });
}

function pointToWayDistance(point: LatLng, way: OverpassWay): number {
  const geom = way.geometry;
  if (!geom || geom.length === 0) return Infinity;

  let best = Infinity;
  for (let i = 0; i < geom.length; i++) {
    const g = geom[i];
    const dVertex = metersBetween(point, { lat: g.lat, lng: g.lon });
    if (dVertex < best) best = dVertex;
    if (i > 0) {
      const prev = geom[i - 1];
      const dSeg = pointToSegmentDistance(
        point,
        { lat: prev.lat, lng: prev.lon },
        { lat: g.lat, lng: g.lon }
      );
      if (dSeg < best) best = dSeg;
    }
  }
  return best;
}

/** Locations where the driver makes a left turn (start of the turn step). */
export function extractLeftTurnPoints(route: ParsedRoute): LatLng[] {
  const points: LatLng[] = [];
  for (const step of route.steps) {
    if (!step.maneuver || !LEFT_TURN_MANEUVERS.has(step.maneuver)) continue;
    if (!step.polyline) continue;
    const decoded = decodePolyline(step.polyline);
    if (decoded.length > 0) points.push(decoded[0]);
    if (points.length >= MAX_TURN_POINTS) break;
  }
  return points;
}

/** Only drivable road classes — keeps footways, steps, cycleways out. */
const DRIVABLE_CLASS_REGEX =
  "^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service|track|road|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link|construction)$";

function buildQuery(samples: LatLng[], turnPoints: LatLng[]): string {
  const wayClauses = samples
    .map(
      (p) =>
        `way(around:${WAY_MATCH_RADIUS_M},${p.lat.toFixed(5)},${p.lng.toFixed(5)})["highway"~"${DRIVABLE_CLASS_REGEX}"];`
    )
    .join("\n");
  const nodeClauses = turnPoints
    .map(
      (p) =>
        `node(around:25,${p.lat.toFixed(5)},${p.lng.toFixed(5)})["highway"="traffic_signals"];`
    )
    .join("\n");

  return `[out:json][timeout:8];
(
${wayClauses}
${nodeClauses}
);
out tags geom 400;`;
}

function parseLanes(tags: Record<string, string>, roadClass: string): number {
  const raw = tags.lanes;
  if (raw) {
    const parsed = Number.parseFloat(raw);
    if (Number.isFinite(parsed) && parsed > 0 && parsed < 20) return parsed;
  }
  return DEFAULT_LANES[roadClass] ?? 1.5;
}

function isConstructionWay(tags: Record<string, string>): boolean {
  return (
    tags.highway === "construction" ||
    Boolean(tags.construction) ||
    tags["construction:highway"] !== undefined
  );
}

/**
 * Fetch road metadata (class, lanes, surface, construction) and turn-protection
 * signals from OpenStreetMap via the Overpass API. Best-effort: returns neutral
 * data on any failure.
 */
export async function fetchOsmRouteData(route: ParsedRoute): Promise<OsmRouteData> {
  const samples = samplePolylinePoints(route.polyline, ROAD_SAMPLE_POINTS);
  const turnPoints = extractLeftTurnPoints(route);
  if (samples.length === 0) {
    return { road: neutralRoad(), turns: neutralTurns(), available: false };
  }

  const overpassUrl = process.env.OVERPASS_API_URL ?? DEFAULT_OVERPASS_URL;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

  let elements: Array<OverpassWay | OverpassNode>;
  try {
    const response = await fetch(overpassUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        // overpass-api.de rejects requests without an identifying UA (406)
        "User-Agent": "roam/1.0 (route scoring)",
      },
      body: `data=${encodeURIComponent(buildQuery(samples, turnPoints))}`,
      signal: controller.signal,
    });
    if (!response.ok) {
      return { road: neutralRoad(), turns: neutralTurns(), available: false };
    }
    const data = (await response.json()) as OverpassResponse;
    elements = data.elements ?? [];
  } catch {
    return { road: neutralRoad(), turns: neutralTurns(), available: false };
  } finally {
    clearTimeout(timer);
  }

  const ways = elements.filter((e): e is OverpassWay => e.type === "way");
  const signalNodes = elements.filter(
    (e): e is OverpassNode => e.type === "node"
  );

  // --- Per-sample road classification (nearest way wins) ---
  const classCounts: Record<string, number> = {};
  let matched = 0;
  let narrownessSum = 0;
  let lanesSum = 0;
  let narrowCount = 0;
  let majorCount = 0;
  let unpavedCount = 0;
  const constructionWayIds = new Set<number>();

  for (const sample of samples) {
    let bestWay: OverpassWay | null = null;
    let bestDist = WAY_MATCH_RADIUS_M;

    for (const way of ways) {
      const tags = way.tags ?? {};
      if (!tags.highway) continue;
      const d = pointToWayDistance(sample, way);
      if (d < bestDist) {
        bestDist = d;
        bestWay = way;
      }
      if (d <= WAY_MATCH_RADIUS_M && isConstructionWay(tags)) {
        constructionWayIds.add(way.id);
      }
    }

    if (!bestWay) continue;
    matched++;

    const tags = bestWay.tags ?? {};
    const roadClass = tags.highway ?? "road";
    classCounts[roadClass] = (classCounts[roadClass] ?? 0) + 1;

    let narrowness = CLASS_NARROWNESS[roadClass] ?? 0.5;
    const lanes = parseLanes(tags, roadClass);
    lanesSum += lanes;
    if (lanes <= 1) narrowness = Math.min(1, narrowness + 0.25);
    else if (lanes >= 4) narrowness = Math.max(0, narrowness - 0.15);

    const surface = tags.surface ?? "";
    if (UNPAVED_SURFACES.has(surface)) {
      unpavedCount++;
      narrowness = Math.min(1, narrowness + 0.3);
    }

    narrownessSum += narrowness;
    if (narrowness >= 0.6) narrowCount++;
    if (roadClass === "motorway" || roadClass === "trunk" || roadClass === "primary") {
      majorCount++;
    }
  }

  const road: RoadConditions =
    matched === 0
      ? neutralRoad()
      : {
          available: true,
          avgLanes: Math.round((lanesSum / matched) * 10) / 10,
          narrowRoadShare: Math.round((narrowCount / matched) * 100) / 100,
          majorRoadShare: Math.round((majorCount / matched) * 100) / 100,
          unpavedShare: Math.round((unpavedCount / matched) * 100) / 100,
          roadSizeScore: Math.round((narrownessSum / matched) * 100) / 100,
          constructionZones: constructionWayIds.size,
          dominantRoadClass:
            Object.entries(classCounts).sort((a, b) => b[1] - a[1])[0]?.[0] ??
            "unknown",
          classCounts,
        };

  // `road.available` means Overpass resolved real ways along this corridor, so
  // a turn with no signal nearby is genuinely unsignalized rather than unmapped.
  const turns: TurnExposure = determineTurnProtection(turnPoints, signalNodes, road.available);

  return { road, turns, available: road.available || turns.available };
}
