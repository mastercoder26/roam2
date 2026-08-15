import type { Request, Response } from "express";
import { z } from "zod";
import { createRequestId, DatabaseUnavailableError, DatabaseOperationError, logDatabaseFailure, logInternalFailure, RequestValidationError } from "../errors.js";
import { getProfile, updateProfile } from "../db/repositories/profiles.js";
import type { DriverStage, ProfileRecord } from "../db/types.js";
import type { AuthenticatedUser } from "../auth/middleware.js";

const profileSchema = z.object({
  displayName: z.string().trim().min(1).max(80).optional(),
  stage: z.enum(["permit", "provisional", "licensed"]).optional(),
  payload: z.record(z.unknown()).optional(),
}).strict();

function validationMessage(error: z.ZodError): string {
  const issue = error.issues[0];
  if (issue.code === z.ZodIssueCode.unrecognized_keys) {
    return `Request body contains unrecognized field: ${issue.keys[0]}`;
  }
  return issue.message;
}

export function validateProfileUpdate(body: unknown): z.infer<typeof profileSchema> {
  const result = profileSchema.safeParse(body);
  if (result.success) return result.data;
  throw new RequestValidationError(validationMessage(result.error));
}

function publicProfile(profile: ProfileRecord) {
  return {
    displayName: profile.displayName,
    stage: profile.stage,
    payload: { ...profile.payload },
    updatedAt: profile.updatedAt.toISOString(),
  };
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

export async function handleGetProfile(req: Request, res: Response): Promise<void> {
  const requestId = createRequestId();
  try {
    const profile = await getProfile((req.user as AuthenticatedUser).id);
    res.status(200).json({ profile: publicProfile(profile) });
  } catch (error) {
    sendError(res, requestId, error, "profile-get");
  }
}

export async function handleUpdateProfile(req: Request, res: Response): Promise<void> {
  const requestId = createRequestId();
  try {
    const input = validateProfileUpdate(req.body);
    const profile = await updateProfile((req.user as AuthenticatedUser).id, {
      displayName: input.displayName,
      stage: input.stage as DriverStage | undefined,
      payload: input.payload,
    });
    res.status(200).json({ profile: publicProfile(profile) });
  } catch (error) {
    sendError(res, requestId, error, "profile-update");
  }
}
