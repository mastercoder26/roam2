import { z } from "zod";
import { RouteProviderError } from "../errors.js";
import type { Bounds, LatLng, ParsedRoute, RouteEndpoint, RouteStep } from "../types.js";
import { buildPolylineGeometry, parseDurationSeconds } from "../utils/polyline.js";

const ROUTES_URL = "https://routes.googleapis.com/directions/v2:computeRoutes";
/** Bounds the primary route call so a slow or hung upstream fails fast instead of stalling the request. */
const FETCH_TIMEOUT_MS = 10_000;

const FIELD_MASK = [
  "routes.duration",
  "routes.staticDuration",
  "routes.distanceMeters",
  "routes.polyline.encodedPolyline",
  "routes.routeLabels",
  "routes.warnings",
  "routes.legs.steps.distanceMeters",
  "routes.legs.steps.staticDuration",
  "routes.legs.steps.navigationInstruction",
  "routes.legs.steps.polyline.encodedPolyline",
  "routes.viewport",
].join(",");

interface ComputeRoutesParams {
  origin: RouteEndpoint;
  destination: RouteEndpoint;
  departureTime?: string;
  includeAlternates?: boolean;
  apiKey: string;
}

const protobufDuration = z.string()
  .regex(/^\d+(?:\.\d+)?s$/)
  .refine((value) => parseDurationSeconds(value) >= 0);

const positiveProtobufDuration = protobufDuration
  .refine((value) => parseDurationSeconds(value) > 0);

const latLng = z.object({
  latitude: z.number().finite().min(-90).max(90),
  longitude: z.number().finite().min(-180).max(180),
});

const routeStep = z.object({
  distanceMeters: z.number().finite().nonnegative(),
  staticDuration: protobufDuration,
  navigationInstruction: z.object({
    maneuver: z.string().optional(),
    instructions: z.string().optional(),
  }).optional(),
  polyline: z.object({ encodedPolyline: z.string().min(1) }).optional(),
});

const googleRoute = z.object({
  duration: positiveProtobufDuration,
  staticDuration: positiveProtobufDuration,
  distanceMeters: z.number().finite().positive(),
  polyline: z.object({ encodedPolyline: z.string().min(1) }),
  routeLabels: z.array(z.string()).optional(),
  warnings: z.array(z.string()).optional(),
  legs: z.array(z.object({ steps: z.array(routeStep).min(1) })).min(1),
  viewport: z.object({ low: latLng, high: latLng }),
}).superRefine((route, ctx) => {
  if (!buildPolylineGeometry(route.polyline.encodedPolyline)) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Invalid overview polyline" });
  }

  const steps = route.legs.flatMap((leg) => leg.steps);
  if (!steps.some((step) => step.distanceMeters > 0)) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Route must contain a usable step" });
  }
});

const computeRoutesResponse = z.object({
  routes: z.array(googleRoute).min(1),
});

type GoogleRoute = z.infer<typeof googleRoute>;

function waypoint(endpoint: RouteEndpoint): Record<string, unknown> {
  if (typeof endpoint === "string") {
    return { address: endpoint };
  }
  return {
    location: {
      latLng: {
        latitude: endpoint.latitude,
        longitude: endpoint.longitude,
      },
    },
  };
}

function toLatLng(point: { latitude: number; longitude: number }): LatLng {
  return { lat: point.latitude, lng: point.longitude };
}

function parseBounds(route: GoogleRoute): Bounds {
  return {
    southwest: toLatLng(route.viewport.low),
    northeast: toLatLng(route.viewport.high),
  };
}

function parseSteps(route: GoogleRoute): RouteStep[] {
  return route.legs.flatMap((leg) => leg.steps.map((step) => ({
    distanceMeters: step.distanceMeters,
    staticDurationSeconds: parseDurationSeconds(step.staticDuration),
    maneuver: step.navigationInstruction?.maneuver,
    navigationInstruction: step.navigationInstruction?.instructions,
    polyline: step.polyline?.encodedPolyline,
  })));
}

function parseRoute(route: GoogleRoute): ParsedRoute {
  return {
    distanceMeters: route.distanceMeters,
    durationSeconds: parseDurationSeconds(route.duration),
    staticDurationSeconds: parseDurationSeconds(route.staticDuration),
    // computeRoutes always requests TRAFFIC_AWARE_OPTIMAL. Persist that fact
    // instead of later inferring live timing coverage from two durations.
    trafficTimingAvailable: true,
    polyline: route.polyline.encodedPolyline,
    bounds: parseBounds(route),
    steps: parseSteps(route),
    routeLabels: route.routeLabels,
    warnings: route.warnings,
  };
}

export async function computeRoutes(
  params: ComputeRoutesParams
): Promise<ParsedRoute[]> {
  const body: Record<string, unknown> = {
    origin: waypoint(params.origin),
    destination: waypoint(params.destination),
    travelMode: "DRIVE",
    routingPreference: "TRAFFIC_AWARE_OPTIMAL",
    computeAlternativeRoutes: params.includeAlternates ?? false,
    units: "IMPERIAL",
  };

  if (params.departureTime) {
    body.departureTime = params.departureTime;
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

  let response: Response;
  try {
    response = await fetch(ROUTES_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": params.apiKey,
        "X-Goog-FieldMask": FIELD_MASK,
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } catch {
    // Covers network failures and the abort fired by the timeout above.
    clearTimeout(timer);
    throw new RouteProviderError();
  }

  clearTimeout(timer);

  if (!response.ok) {
    throw new RouteProviderError(response.status);
  }

  let data: unknown;
  try {
    data = await response.json();
  } catch {
    throw new RouteProviderError(response.status);
  }

  const parsed = computeRoutesResponse.safeParse(data);
  if (!parsed.success) {
    throw new RouteProviderError(response.status);
  }

  return parsed.data.routes.map(parseRoute);
}
