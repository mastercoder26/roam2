import type { ParsedRoute } from "../types.js";
import { samplePolylinePoints } from "../utils/polyline.js";
import { neutralWeather, type WeatherConditions } from "./types.js";

const OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast";
const FETCH_TIMEOUT_MS = 5000;
const SAMPLE_POINTS = 6;

interface HourlyBlock {
  time: string[];
  temperature_2m?: number[];
  precipitation?: number[];
  snowfall?: number[];
  weather_code?: number[];
  visibility?: number[];
  wind_gusts_10m?: number[];
}

interface OpenMeteoResult {
  latitude: number;
  longitude: number;
  hourly?: HourlyBlock;
}

function clamp01(v: number): number {
  // `Math.max(0, Math.min(1, NaN))` is `NaN`, not a clamped value — guard
  // non-finite input before the clamp, since a missing provider field turns
  // into NaN here and would poison `severity`.
  return Number.isFinite(v) ? Math.max(0, Math.min(1, v)) : 0;
}

function conditionFromCode(code: number): string {
  if (code === 0) return "Clear";
  if (code <= 2) return "Partly cloudy";
  if (code === 3) return "Overcast";
  if (code === 45 || code === 48) return "Fog";
  if (code >= 51 && code <= 57) return "Drizzle";
  if (code === 66 || code === 67) return "Freezing rain";
  if ((code >= 61 && code <= 65) || (code >= 80 && code <= 82)) return "Rain";
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return "Snow";
  if (code >= 95) return "Thunderstorm";
  return "Mixed";
}

/** Rank used to pick the "dominant" (worst) condition label along the route. */
function conditionRank(condition: string): number {
  const order = [
    "Clear",
    "Partly cloudy",
    "Overcast",
    "Mixed",
    "Drizzle",
    "Fog",
    "Rain",
    "Thunderstorm",
    "Snow",
    "Freezing rain",
  ];
  const idx = order.indexOf(condition);
  return idx === -1 ? 0 : idx;
}

interface PointWeather {
  severity: number;
  precipIntensity: number;
  snowRisk: number;
  windSeverity: number;
  lowVisibilityRisk: number;
  icyRisk: number;
  temperatureF: number;
  windGustMph: number;
  visibilityMiles: number;
  condition: string;
}

function evaluateHour(hourly: HourlyBlock, idx: number): PointWeather | null {
  if (idx < 0 || idx >= hourly.time.length) return null;

  const tempF = hourly.temperature_2m?.[idx] ?? 60;
  const precipMm = hourly.precipitation?.[idx] ?? 0;
  const snowCm = hourly.snowfall?.[idx] ?? 0;
  const code = hourly.weather_code?.[idx] ?? 0;
  const visibilityM = hourly.visibility?.[idx] ?? 20000;
  const gustMph = (hourly.wind_gusts_10m?.[idx] ?? 0) * 0.621371;

  const precipIntensity = clamp01(precipMm / 8);
  const snowRisk = clamp01(snowCm / 2);
  const windSeverity = clamp01((gustMph - 25) / 30);
  const lowVisibilityRisk = clamp01((2000 - visibilityM) / 1800);
  const freezing = tempF <= 34;
  const icyRisk = freezing && (precipMm > 0.05 || snowCm > 0.05) ? 0.9 : 0;
  const thunder = code >= 95 ? 0.6 : 0;
  const fogCode = code === 45 || code === 48 ? 0.4 : 0;

  const severity = clamp01(
    precipIntensity * 0.8 +
      snowRisk * 1.0 +
      windSeverity * 0.5 +
      Math.max(lowVisibilityRisk * 0.7, fogCode) +
      icyRisk +
      thunder
  );

  return {
    severity,
    precipIntensity,
    snowRisk,
    windSeverity,
    lowVisibilityRisk: Math.max(lowVisibilityRisk, fogCode),
    icyRisk,
    temperatureF: tempF,
    windGustMph: gustMph,
    visibilityMiles: visibilityM / 1609.34,
    condition: conditionFromCode(code),
  };
}

/**
 * Fetch weather along the route at estimated arrival times for sampled points
 * using the Open-Meteo forecast API (no key required).
 */
export async function fetchRouteWeather(
  route: ParsedRoute,
  departureTime?: string
): Promise<WeatherConditions> {
  const points = samplePolylinePoints(route.polyline, SAMPLE_POINTS);
  if (points.length === 0) return neutralWeather();

  const departure = departureTime ? new Date(departureTime) : new Date();
  if (Number.isNaN(departure.getTime())) return neutralWeather();

  const hoursAhead = Math.max(
    0,
    (departure.getTime() - Date.now()) / 3_600_000
  );
  // Open-Meteo free forecast is ~16 days; request enough coverage for the ETA.
  const forecastDays = Math.min(16, Math.max(3, Math.ceil(hoursAhead / 24) + 1));
  // Beyond forecast horizon, don't invent conditions.
  if (hoursAhead > 16 * 24) return neutralWeather();

  const latitudes = points.map((p) => p.lat.toFixed(4)).join(",");
  const longitudes = points.map((p) => p.lng.toFixed(4)).join(",");
  const url =
    `${OPEN_METEO_URL}?latitude=${latitudes}&longitude=${longitudes}` +
    `&hourly=temperature_2m,precipitation,snowfall,weather_code,visibility,wind_gusts_10m` +
    `&forecast_days=${forecastDays}&timezone=UTC&temperature_unit=fahrenheit`;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

  let results: OpenMeteoResult[];
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) return neutralWeather();
    const data = (await response.json()) as OpenMeteoResult | OpenMeteoResult[];
    results = Array.isArray(data) ? data : [data];
  } catch {
    return neutralWeather();
  } finally {
    clearTimeout(timer);
  }

  const evaluated: PointWeather[] = [];
  results.forEach((result, i) => {
    const hourly = result.hourly;
    if (!hourly || hourly.time.length === 0) return;

    // ETA at this point assuming uniform progress along the route.
    const fraction = points.length > 1 ? i / (points.length - 1) : 0;
    const etaMs = departure.getTime() + fraction * route.durationSeconds * 1000;
    const firstHourMs = new Date(`${hourly.time[0]}:00Z`).getTime();
    if (Number.isNaN(firstHourMs)) return;
    const idx = Math.round((etaMs - firstHourMs) / 3_600_000);
    // Skip points whose ETA falls outside the forecast window.
    if (idx < 0 || idx >= hourly.time.length) return;

    const pw = evaluateHour(hourly, idx);
    if (pw) evaluated.push(pw);
  });

  if (evaluated.length === 0) return neutralWeather();

  const mean = (sel: (p: PointWeather) => number) =>
    evaluated.reduce((a, p) => a + sel(p), 0) / evaluated.length;
  const max = (sel: (p: PointWeather) => number) =>
    Math.max(...evaluated.map(sel));

  const worst = evaluated.reduce((a, b) =>
    conditionRank(b.condition) > conditionRank(a.condition) ? b : a
  );

  return {
    available: true,
    condition: worst.condition,
    severity: clamp01(max((p) => p.severity) * 0.6 + mean((p) => p.severity) * 0.4),
    precipIntensity: max((p) => p.precipIntensity),
    snowRisk: max((p) => p.snowRisk),
    windSeverity: max((p) => p.windSeverity),
    lowVisibilityRisk: max((p) => p.lowVisibilityRisk),
    icyRisk: max((p) => p.icyRisk),
    temperatureF: Math.round(mean((p) => p.temperatureF)),
    windGustMph: Math.round(max((p) => p.windGustMph)),
    visibilityMiles: Math.round(Math.min(...evaluated.map((p) => p.visibilityMiles)) * 10) / 10,
  };
}
