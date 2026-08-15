/** Live conditions gathered from external sources (weather, OpenStreetMap). All fields degrade gracefully when a source is unavailable. */

export interface WeatherConditions {
  available: boolean;
  /** Human-readable dominant condition along the route, e.g. "Rain", "Snow", "Clear". */
  condition: string;
  /** 0–1 combined severity of weather along the route at drive time. */
  severity: number;
  /** 0–1 rain intensity. */
  precipIntensity: number;
  /** 0–1 snow intensity. */
  snowRisk: number;
  /** 0–1 wind-gust severity. */
  windSeverity: number;
  /** 0–1 reduced-visibility severity (fog, heavy precip). */
  lowVisibilityRisk: number;
  /** 0–1 risk of icy surfaces (near/below freezing with precipitation). */
  icyRisk: number;
  temperatureF: number;
  windGustMph: number;
  visibilityMiles: number;
}

export interface RoadConditions {
  available: boolean;
  /** Average number of lanes across sampled road segments. */
  avgLanes: number;
  /** Share of route samples on narrow/small roads (residential, service, single-lane). */
  narrowRoadShare: number;
  /** Share of route samples on major roads (motorway/trunk/primary). */
  majorRoadShare: number;
  /** Share of route samples on unpaved/gravel surfaces. */
  unpavedShare: number;
  /** 0–1: how much the route runs on small/narrow roads (higher = harder). */
  roadSizeScore: number;
  /** Distinct construction zones detected along the route. */
  constructionZones: number;
  /** Dominant OSM road class along the route, e.g. "motorway", "residential". */
  dominantRoadClass: string;
  /** Sampled-road-class histogram, e.g. { motorway: 12, residential: 3 }. */
  classCounts: Record<string, number>;
}

export interface TurnExposure {
  available: boolean;
  /** Left turns without a traffic signal or stop control at the intersection. */
  unprotectedLeftTurns: number;
  /** Left turns protected by a signal/stop. */
  protectedLeftTurns: number;
  /** 0–1 share of left turns that are unprotected. */
  unprotectedTurnShare: number;
}

export interface RouteConditions {
  weather: WeatherConditions;
  road: RoadConditions;
  turns: TurnExposure;
  /** Sources that successfully contributed data, e.g. ["open-meteo", "osm-overpass"]. */
  sources: string[];
}

export function neutralWeather(): WeatherConditions {
  return {
    available: false,
    condition: "Unknown",
    severity: 0,
    precipIntensity: 0,
    snowRisk: 0,
    windSeverity: 0,
    lowVisibilityRisk: 0,
    icyRisk: 0,
    temperatureF: 0,
    windGustMph: 0,
    visibilityMiles: 0,
  };
}

export function neutralRoad(): RoadConditions {
  return {
    available: false,
    avgLanes: 0,
    narrowRoadShare: 0,
    majorRoadShare: 0,
    unpavedShare: 0,
    roadSizeScore: 0,
    constructionZones: 0,
    dominantRoadClass: "unknown",
    classCounts: {},
  };
}

export function neutralTurns(): TurnExposure {
  return {
    available: false,
    unprotectedLeftTurns: 0,
    protectedLeftTurns: 0,
    unprotectedTurnShare: 0,
  };
}

export function neutralConditions(): RouteConditions {
  return {
    weather: neutralWeather(),
    road: neutralRoad(),
    turns: neutralTurns(),
    sources: [],
  };
}
