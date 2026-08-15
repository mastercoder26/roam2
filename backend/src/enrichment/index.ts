import type { ParsedRoute } from "../types.js";
import { fetchOsmRouteData } from "./osm.js";
import { fetchRouteWeather } from "./weather.js";
import {
  neutralConditions,
  neutralRoad,
  neutralTurns,
  neutralWeather,
  type RouteConditions,
} from "./types.js";

export type { RouteConditions } from "./types.js";
export { neutralConditions } from "./types.js";

const CONSTRUCTION_KEYWORDS = ["construction", "road work", "roadwork", "lane closure"];

function warningsMentionConstruction(warnings?: string[]): boolean {
  if (!warnings) return false;
  return warnings.some((w) =>
    CONSTRUCTION_KEYWORDS.some((kw) => w.toLowerCase().includes(kw))
  );
}

/**
 * Gather live conditions (weather, road metadata, turn protection, construction)
 * for a route. Every source is best-effort; failures degrade to neutral data so
 * scoring always succeeds.
 */
export async function enrichRoute(
  route: ParsedRoute,
  options: { departureTime?: string } = {}
): Promise<RouteConditions> {
  if (process.env.DISABLE_ENRICHMENT === "1") {
    return neutralConditions();
  }

  const [weatherResult, osmResult] = await Promise.allSettled([
    fetchRouteWeather(route, options.departureTime),
    fetchOsmRouteData(route),
  ]);

  const weather =
    weatherResult.status === "fulfilled" ? weatherResult.value : neutralWeather();
  const osm =
    osmResult.status === "fulfilled"
      ? osmResult.value
      : { road: neutralRoad(), turns: neutralTurns(), available: false };

  const road = { ...osm.road };
  if (warningsMentionConstruction(route.warnings)) {
    road.constructionZones = Math.max(1, road.constructionZones + 1);
  }

  const sources: string[] = [];
  if (weather.available) sources.push("open-meteo");
  if (osm.available) sources.push("osm-overpass");
  if (route.warnings && route.warnings.length > 0) sources.push("google-route-warnings");

  return { weather, road, turns: osm.turns, sources };
}
