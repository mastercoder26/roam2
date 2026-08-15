import type { Request, Response } from "express";
import { z } from "zod";
import {
  createRequestId,
  logRouteFailure,
  publicFailure,
  RequestValidationError,
} from "../errors.js";
import { computeRoutes } from "../google/routes.js";
import { enrichRouteWithSpeedLimits } from "../google/roads.js";
import { enrichRoute, neutralConditions } from "../enrichment/index.js";
import { scoreRoutes } from "../scoring/index.js";
import type {
  DepartureComparisonRequest,
  DepartureComparisonResponse,
  DifficultyRequest,
  DifficultyResponse,
} from "../types.js";

const MAX_ENRICHED_ROUTES = 3;
const MAX_ADDRESS_LENGTH = 512;
const MAX_CANDIDATE_ID_LENGTH = 128;
const MAX_CONTINUOUS_DRIVE_MINUTES = 1_440;

const ISO_TIMESTAMP = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,9})?)?(Z|[+-]\d{2}:\d{2})$/;

const routeAnalysisDependencies = {
  computeRoutes,
  enrichRouteWithSpeedLimits,
  enrichRoute,
  neutralConditions,
  scoreRoutes,
};

/** Injectable only so the route pipeline can be verified without network calls. */
export type RouteAnalysisDependencies = typeof routeAnalysisDependencies;

function isValidIsoTimestamp(value: string): boolean {
  const match = value.match(ISO_TIMESTAMP);
  if (!match || Number.isNaN(Date.parse(value))) return false;

  const [, yearText, monthText, dayText, hourText, minuteText, secondText, zone] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = secondText === undefined ? 0 : Number(secondText);

  if (
    month < 1 || month > 12 ||
    day < 1 || day > new Date(Date.UTC(year, month, 0)).getUTCDate() ||
    hour > 23 || minute > 59 || second > 59
  ) {
    return false;
  }

  if (zone !== "Z") {
    const [offsetHours, offsetMinutes] = zone.slice(1).split(":").map(Number);
    if (offsetHours > 23 || offsetMinutes > 59) return false;
  }

  return true;
}

const addressSchema = (field: "origin" | "destination") => z.string({
  invalid_type_error: `${field} is required and must be a string`,
}).trim()
  .min(1, `${field} is required and must be a string`)
  .max(MAX_ADDRESS_LENGTH, `${field} must be at most ${MAX_ADDRESS_LENGTH} characters`);

const coordinateEndpointSchema = (field: "origin" | "destination") => z.object({
  latitude: z.number({
    invalid_type_error: `${field} latitude must be a number between -90 and 90`,
  }).finite(`${field} latitude must be a number between -90 and 90`)
    .min(-90, `${field} latitude must be between -90 and 90`)
    .max(90, `${field} latitude must be between -90 and 90`),
  longitude: z.number({
    invalid_type_error: `${field} longitude must be a number between -180 and 180`,
  }).finite(`${field} longitude must be a number between -180 and 180`)
    .min(-180, `${field} longitude must be between -180 and 180`)
    .max(180, `${field} longitude must be between -180 and 180`),
}).strict();

const routeEndpointSchema = (field: "origin" | "destination") => z.union([
  addressSchema(field),
  coordinateEndpointSchema(field),
]);

const departureLocalMinutesSchema = z.number({
  invalid_type_error: "departureLocalMinutes must be an integer between 0 and 1439",
}).int("departureLocalMinutes must be an integer between 0 and 1439")
  .min(0, "departureLocalMinutes must be an integer between 0 and 1439")
  .max(1_439, "departureLocalMinutes must be an integer between 0 and 1439");

const departureTimeSchema = z.string({
  invalid_type_error: "departureTime must be a valid ISO-8601 timestamp",
}).refine(isValidIsoTimestamp, "departureTime must be a valid ISO-8601 timestamp");

const difficultyRequestSchema = z.object({
  origin: routeEndpointSchema("origin"),
  destination: routeEndpointSchema("destination"),
  departureTime: departureTimeSchema.optional(),
  departureLocalMinutes: departureLocalMinutesSchema.optional(),
  includeAlternates: z.boolean({
    invalid_type_error: "includeAlternates must be a boolean",
  }).optional().default(false),
  continuousDriveMinutes: z.number({
    invalid_type_error: "continuousDriveMinutes must be between 0 and 1440",
  }).finite("continuousDriveMinutes must be between 0 and 1440")
    .min(0, "continuousDriveMinutes must be between 0 and 1440")
    .max(MAX_CONTINUOUS_DRIVE_MINUTES, "continuousDriveMinutes must be between 0 and 1440")
    .optional(),
}, {
  invalid_type_error: "Request body must be a JSON object",
}).strict();

const departureCandidateSchema = z.object({
  id: z.string({
    invalid_type_error: "candidate id is required and must be a string",
  }).trim().min(1, "candidate id is required and must be a string")
    .max(MAX_CANDIDATE_ID_LENGTH, `candidate id must be at most ${MAX_CANDIDATE_ID_LENGTH} characters`),
  departureTime: departureTimeSchema,
  departureLocalMinutes: departureLocalMinutesSchema,
}).strict();

const departureComparisonRequestSchema = z.object({
  origin: addressSchema("origin"),
  destination: addressSchema("destination"),
  candidates: z.array(departureCandidateSchema)
    .min(1, "candidates must contain between 1 and 3 items")
    .max(3, "candidates must contain between 1 and 3 items"),
}, {
  invalid_type_error: "Request body must be a JSON object",
}).strict().superRefine((request, context) => {
  const ids = new Set<string>();
  for (const candidate of request.candidates) {
    if (ids.has(candidate.id)) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: "candidate ids must be unique" });
      return;
    }
    ids.add(candidate.id);
  }
});

function validationMessage(error: z.ZodError): string {
  const issue = error.issues[0];
  if (issue.code === z.ZodIssueCode.unrecognized_keys) {
    const path = issue.path.length > 0 ? `${issue.path.join(".")}.` : "";
    return `Request body contains unrecognized field: ${path}${issue.keys[0]}`;
  }
  return issue.message;
}

function parseRequest<T>(schema: z.ZodType<T>, body: unknown): T {
  const parsed = schema.safeParse(body);
  if (parsed.success) return parsed.data;
  throw new RequestValidationError(validationMessage(parsed.error));
}

export function validateDifficultyRequest(body: unknown): DifficultyRequest {
  return parseRequest(difficultyRequestSchema, body);
}

export function validateDepartureComparisonRequest(
  body: unknown
): DepartureComparisonRequest {
  return parseRequest(departureComparisonRequestSchema, body);
}

/** The common routing, enrichment, and scoring pipeline — the only place that combines provider data into a scored route. */
export async function analyzeDifficultyRequest(
  request: DifficultyRequest,
  apiKey: string,
  dependencies: RouteAnalysisDependencies = routeAnalysisDependencies
): Promise<DifficultyResponse> {
  const routes = await dependencies.computeRoutes({
    origin: request.origin,
    destination: request.destination,
    departureTime: request.departureTime,
    includeAlternates: request.includeAlternates,
    apiKey,
  });

  const [speedEnrichments, conditionsList] = await Promise.all([
    Promise.all(routes.map((route) => dependencies.enrichRouteWithSpeedLimits(route, apiKey))),
    Promise.all(
      routes.map((route, index) =>
        index < MAX_ENRICHED_ROUTES
          ? dependencies.enrichRoute(route, { departureTime: request.departureTime })
          : Promise.resolve(dependencies.neutralConditions())
      )
    ),
  ]);

  const scoreOptions = routes.map((_route, index) => ({
    stepSpeedsMph: speedEnrichments[index].stepSpeedsMph,
    speedLimitCoverage: speedEnrichments[index].postedSpeedLimitCoverage,
    departureTime: request.departureTime,
    departureLocalMinutes: request.departureLocalMinutes,
    continuousDriveMinutes: request.continuousDriveMinutes,
    conditions: conditionsList[index],
  }));

  const { primary, alternates } = dependencies.scoreRoutes(routes, scoreOptions);
  return { primaryRoute: primary, alternateRoutes: alternates };
}

/**
 * Scores each requested time independently. A provider or analysis failure is
 * useful unavailable data for that one time, not a failure of the request.
 */
export async function analyzeDepartureComparisonRequest(
  request: DepartureComparisonRequest,
  apiKey: string,
  dependencies: RouteAnalysisDependencies = routeAnalysisDependencies,
  requestId = createRequestId()
): Promise<DepartureComparisonResponse> {
  const candidates = await Promise.all(
    request.candidates.map(async (candidate, candidateIndex) => {
      try {
        const response = await analyzeDifficultyRequest(
          {
            origin: request.origin,
            destination: request.destination,
            departureTime: candidate.departureTime,
            departureLocalMinutes: candidate.departureLocalMinutes,
            includeAlternates: false,
          },
          apiKey,
          dependencies
        );

        return { ...candidate, route: response.primaryRoute };
      } catch (error) {
        logRouteFailure(requestId, {
          endpoint: "departure-comparison",
          candidateIndex,
        }, error);
        const failure = publicFailure(error);
        return {
          ...candidate,
          error: {
            message: failure.message,
            code: failure.code as "INVALID_REQUEST" | "ROUTE_UNAVAILABLE" | "RATE_LIMITED",
            requestId,
          },
        };
      }
    })
  );

  return { candidates };
}

function respondWithFailure(
  res: Response,
  requestId: string,
  error: unknown
): void {
  const failure = publicFailure(error);
  res.status(failure.status).json({
    error: failure.message,
    code: failure.code,
    requestId,
  });
}

export async function handleDifficulty(
  req: Request,
  res: Response
): Promise<void> {
  const requestId = createRequestId();
  let request: DifficultyRequest;
  try {
    request = validateDifficultyRequest(req.body);
  } catch (error) {
    logRouteFailure(requestId, { endpoint: "difficulty" }, error);
    respondWithFailure(res, requestId, error);
    return;
  }

  const apiKey = process.env.GOOGLE_MAPS_API_KEY;
  if (!apiKey) {
    logRouteFailure(requestId, { endpoint: "difficulty" }, new Error("MissingConfiguration"));
    respondWithFailure(res, requestId, new Error("MissingConfiguration"));
    return;
  }

  try {
    const { primaryRoute: primary, alternateRoutes: alternates } =
      await analyzeDifficultyRequest(request, apiKey);

    res.status(200).json({
      primaryRoute: primary,
      alternateRoutes: alternates,
    });
  } catch (error) {
    logRouteFailure(requestId, { endpoint: "difficulty" }, error);
    respondWithFailure(res, requestId, error);
  }
}

export async function handleDepartureComparison(
  req: Request,
  res: Response
): Promise<void> {
  const requestId = createRequestId();
  let request: DepartureComparisonRequest;
  try {
    request = validateDepartureComparisonRequest(req.body);
  } catch (error) {
    logRouteFailure(requestId, { endpoint: "departure-comparison" }, error);
    respondWithFailure(res, requestId, error);
    return;
  }

  const apiKey = process.env.GOOGLE_MAPS_API_KEY;
  if (!apiKey) {
    logRouteFailure(requestId, { endpoint: "departure-comparison" }, new Error("MissingConfiguration"));
    respondWithFailure(res, requestId, new Error("MissingConfiguration"));
    return;
  }

  try {
    const response = await analyzeDepartureComparisonRequest(request, apiKey, undefined, requestId);
    res.status(200).json(response);
  } catch (error) {
    logRouteFailure(requestId, { endpoint: "departure-comparison" }, error);
    respondWithFailure(res, requestId, error);
  }
}
