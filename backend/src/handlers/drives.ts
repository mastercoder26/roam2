import type { Request, Response } from "express";
import { z } from "zod";
import type { AuthenticatedUser } from "../auth/middleware.js";
import {
  aggregateDriveStats,
  deleteSavedRoute,
  getDrive,
  listDrives,
  listSavedRoutes,
  softDeleteDrive,
  upsertDrives,
  upsertSavedRoute,
} from "../db/repositories/drives.js";
import type { DriveRecord, SavedRouteRecord } from "../db/types.js";
import {
  createRequestId,
  DatabaseOperationError,
  DatabaseUnavailableError,
  logDatabaseFailure,
  logInternalFailure,
  RequestValidationError,
} from "../errors.js";

const MAX_PAYLOAD_BYTES = 1_000_000;
const isoDateSchema = z.string().datetime({ offset: true });
const payloadSchema = z.record(z.unknown()).superRefine((payload, context) => {
  const encoded = JSON.stringify(payload);
  if (Buffer.byteLength(encoded, "utf8") > MAX_PAYLOAD_BYTES) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "payload must be at most 1 MB" });
  }
});

const driveInputSchema = z.object({
  id: z.string().uuid(),
  startedAt: isoDateSchema,
  durationSeconds: z.number().finite().nonnegative(),
  distanceMeters: z.number().finite().nonnegative(),
  score: z.number().finite().int(),
  topSpeedMetersPerSecond: z.number().finite().nonnegative(),
  eventCount: z.number().finite().int().nonnegative().default(0),
  recordingTimeZoneIdentifier: z.string().max(128).nullable().optional(),
  payload: payloadSchema,
}).strict();

const drivesBodySchema = z.object({
  drives: z.array(driveInputSchema).max(100),
}).strict();

const savedRouteInputSchema = z.object({
  id: z.string().uuid(),
  label: z.string().trim().min(1).max(200),
  payload: payloadSchema,
}).strict();

const listQuerySchema = z.object({
  limit: z.coerce.number().int().min(1).max(200).default(50),
  before: isoDateSchema.optional(),
  /// Paired with `before` to make the page boundary unambiguous when several
  /// drives share a start timestamp. Optional so older cursors still work.
  beforeId: z.string().uuid().optional(),
}).strict();

function validationMessage(error: z.ZodError): string {
  const issue = error.issues[0];
  if (issue.code === z.ZodIssueCode.unrecognized_keys) {
    return `Request body contains unrecognized field: ${issue.keys[0]}`;
  }
  return issue.message;
}

function parse<TSchema extends z.ZodTypeAny>(schema: TSchema, value: unknown): z.output<TSchema> {
  const result = schema.safeParse(value);
  if (result.success) return result.data;
  throw new RequestValidationError(validationMessage(result.error));
}

function userId(req: Request): string {
  return (req.user as AuthenticatedUser).id;
}

function parseId(req: Request): string {
  return parse(z.string().uuid(), req.params.id);
}

function publicDrive(drive: DriveRecord) {
  return {
    id: drive.id,
    startedAt: drive.startedAt.toISOString(),
    durationSeconds: drive.durationSeconds,
    distanceMeters: drive.distanceMeters,
    score: drive.score,
    topSpeedMetersPerSecond: drive.topSpeedMetersPerSecond,
    eventCount: drive.eventCount,
    recordingTimeZoneIdentifier: drive.recordingTimeZoneIdentifier,
    payload: { ...drive.payload },
    createdAt: drive.createdAt.toISOString(),
    updatedAt: drive.updatedAt.toISOString(),
  };
}

function publicSavedRoute(route: SavedRouteRecord) {
  return {
    id: route.id,
    label: route.label,
    payload: { ...route.payload },
    createdAt: route.createdAt.toISOString(),
    updatedAt: route.updatedAt.toISOString(),
  };
}

function sendNotFound(res: Response, requestId: string, message: string): void {
  res.status(404).json({ error: message, code: "NOT_FOUND", requestId });
}

function sendError(res: Response, requestId: string, error: unknown, endpoint: string): void {
  if (error instanceof RequestValidationError) {
    res.status(400).json({ error: error.message, code: "VALIDATION_ERROR", requestId });
    return;
  }
  if (error instanceof DatabaseUnavailableError || error instanceof DatabaseOperationError) {
    logDatabaseFailure(requestId, { endpoint }, error);
    res.status(503).json({
      error: "Account services are temporarily unavailable. Please try again shortly.",
      code: "SERVICE_UNAVAILABLE",
      requestId,
    });
    return;
  }
  logInternalFailure(requestId, { endpoint }, error);
  res.status(500).json({ error: "An unexpected error occurred.", code: "INTERNAL_ERROR", requestId });
}

export function validateDriveInput(body: unknown): z.output<typeof driveInputSchema> {
  return parse(driveInputSchema, body);
}

export function validateDrivesBody(body: unknown): z.output<typeof drivesBodySchema> {
  return parse(drivesBodySchema, body);
}

export function validateSavedRouteInput(body: unknown): z.output<typeof savedRouteInputSchema> {
  return parse(savedRouteInputSchema, body);
}

export async function handleGetDrives(req: Request, res: Response): Promise<void> {
  const requestId = createRequestId();
  try {
    const query = parse(listQuerySchema, req.query);
    const drives = await listDrives(userId(req), {
      limit: query.limit,
      before: query.before ? new Date(query.before) : undefined,
      beforeId: query.beforeId,
    });
    const last = drives[drives.length - 1];
    res.status(200).json({
      drives: drives.map(publicDrive),
      nextCursor: last ? last.startedAt.toISOString() : null,
      nextCursorId: last ? last.id : null,
    });
  } catch (error) {
    sendError(res, requestId, error, "drives-list");
  }
}

export async function handleGetDrive(req: Request, res: Response): Promise<void> {
  const requestId = createRequestId();
  try {
    const drive = await getDrive(userId(req), parseId(req));
    if (!drive) {
      sendNotFound(res, requestId, "Drive not found.");
      return;
    }
    res.status(200).json({ drive: publicDrive(drive) });
  } catch (error) {
    sendError(res, requestId, error, "drive-get");
  }
}

export async function handleUpsertDrives(req: Request, res: Response): Promise<void> {
  const requestId = createRequestId();
  try {
    const input = parse(drivesBodySchema, req.body);
    const drives = await upsertDrives(userId(req), input.drives.map((drive) => ({
      ...drive,
      startedAt: new Date(drive.startedAt),
      eventCount: drive.eventCount ?? 0,
      recordingTimeZoneIdentifier: drive.recordingTimeZoneIdentifier ?? null,
    })));
    res.status(200).json({ drives: drives.map(publicDrive) });
  } catch (error) {
    sendError(res, requestId, error, "drives-upsert");
  }
}

export async function handleDeleteDrive(req: Request, res: Response): Promise<void> {
  const requestId = createRequestId();
  try {
    const deleted = await softDeleteDrive(userId(req), parseId(req));
    if (!deleted) {
      sendNotFound(res, requestId, "Drive not found.");
      return;
    }
    res.status(204).end();
  } catch (error) {
    sendError(res, requestId, error, "drive-delete");
  }
}

export async function handleGetDriveStats(req: Request, res: Response): Promise<void> {
  const requestId = createRequestId();
  try {
    res.status(200).json(await aggregateDriveStats(userId(req)));
  } catch (error) {
    sendError(res, requestId, error, "drives-stats");
  }
}

export async function handleGetSavedRoutes(req: Request, res: Response): Promise<void> {
  const requestId = createRequestId();
  try {
    const routes = await listSavedRoutes(userId(req));
    res.status(200).json({ routes: routes.map(publicSavedRoute) });
  } catch (error) {
    sendError(res, requestId, error, "saved-routes-list");
  }
}

export async function handleUpsertSavedRoute(req: Request, res: Response): Promise<void> {
  const requestId = createRequestId();
  try {
    const input = parse(savedRouteInputSchema, req.body);
    const route = await upsertSavedRoute(userId(req), input);
    if (!route) {
      sendNotFound(res, requestId, "Saved route not found.");
      return;
    }
    res.status(200).json({ route: publicSavedRoute(route) });
  } catch (error) {
    sendError(res, requestId, error, "saved-routes-upsert");
  }
}

export async function handleDeleteSavedRoute(req: Request, res: Response): Promise<void> {
  const requestId = createRequestId();
  try {
    const deleted = await deleteSavedRoute(userId(req), parseId(req));
    if (!deleted) {
      sendNotFound(res, requestId, "Saved route not found.");
      return;
    }
    res.status(204).end();
  } catch (error) {
    sendError(res, requestId, error, "saved-routes-delete");
  }
}
