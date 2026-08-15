import { verifyToken } from "@clerk/backend";
import type { NextFunction, Request, Response } from "express";
import {
  DatabaseOperationError,
  DatabaseUnavailableError,
  createRequestId,
} from "../errors.js";
import { findOrCreateByClerkId } from "../db/repositories/users.js";
import { AuthConfigurationError } from "./errors.js";

export interface AuthenticatedUser {
  id: string;
  email: string;
  clerkUserId?: string;
}

declare module "express-serve-static-core" {
  interface Request {
    user?: AuthenticatedUser;
    /// Set by `requireVerifiedIdentity` only. It is a verified Clerk subject,
    /// not a local user row, so it must not be used as a database key.
    clerkUserId?: string;
  }
}

interface ClerkClaims {
  sub?: unknown;
  email?: unknown;
  email_address?: unknown;
  name?: unknown;
  first_name?: unknown;
  last_name?: unknown;
}

function respond(
  res: Response,
  status: 401 | 503,
  code: "UNAUTHORIZED" | "SERVICE_UNAVAILABLE",
  error: string,
): void {
  res.status(status).json({ error, code, requestId: createRequestId() });
}

function serviceUnavailable(res: Response): void {
  respond(
    res,
    503,
    "SERVICE_UNAVAILABLE",
    "Account services are temporarily unavailable. Please try again shortly.",
  );
}

function stringClaim(claim: unknown): string | null {
  return typeof claim === "string" && claim.trim() ? claim.trim() : null;
}

function displayNameFromClaims(claims: ClerkClaims): string | null {
  const fullName = stringClaim(claims.name);
  if (fullName) return fullName;
  const firstName = stringClaim(claims.first_name);
  const lastName = stringClaim(claims.last_name);
  return [firstName, lastName].filter(Boolean).join(" ") || null;
}

async function authenticate(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    assertAuthConfigured();
  } catch (error) {
    if (error instanceof AuthConfigurationError) {
      serviceUnavailable(res);
      return;
    }
    next(error);
    return;
  }

  const secretKey = process.env.CLERK_SECRET_KEY?.trim();
  if (!secretKey) {
    serviceUnavailable(res);
    return;
  }

  const token = req.header("authorization")?.match(/^Bearer\s+([^\s]+)$/i)?.[1];
  if (!token) {
    respond(res, 401, "UNAUTHORIZED", "Authentication is required.");
    return;
  }

  let claims: ClerkClaims;
  try {
    claims = await verifyToken(token, { secretKey }) as ClerkClaims;
  } catch {
    respond(res, 401, "UNAUTHORIZED", "Authentication token is invalid.");
    return;
  }

  const clerkUserId = stringClaim(claims.sub);
  if (!clerkUserId) {
    respond(res, 401, "UNAUTHORIZED", "Authentication token is invalid.");
    return;
  }

  try {
    const user = await findOrCreateByClerkId({
      clerkUserId,
      email: stringClaim(claims.email) ?? stringClaim(claims.email_address),
      displayName: displayNameFromClaims(claims),
    });
    req.user = { id: user.id, email: user.email, clerkUserId };
    next();
  } catch (error) {
    if (error instanceof DatabaseUnavailableError || error instanceof DatabaseOperationError) {
      serviceUnavailable(res);
      return;
    }
    next(error);
  }
}

export function requireAuth(req: Request, res: Response, next: NextFunction): void {
  void authenticate(req, res, next);
}

/**
 * Proves the caller is a signed-in Roam account and stops there. Route
 * analysis proxies metered Google APIs and can't be open to anonymous
 * callers, but it doesn't need a user row — `requireAuth` provisions one and
 * would force a Postgres connection onto this otherwise stateless deployment.
 * This checks the Clerk token only, so the route-analysis deployment needs
 * `CLERK_SECRET_KEY` and no database.
 */
async function verifyIdentity(req: Request, res: Response, next: NextFunction): Promise<void> {
  const secretKey = process.env.CLERK_SECRET_KEY?.trim();
  if (!secretKey) {
    serviceUnavailable(res);
    return;
  }

  const token = req.header("authorization")?.match(/^Bearer\s+([^\s]+)$/i)?.[1];
  if (!token) {
    respond(res, 401, "UNAUTHORIZED", "Sign in to analyze routes.");
    return;
  }

  let claims: ClerkClaims;
  try {
    claims = await verifyToken(token, { secretKey }) as ClerkClaims;
  } catch {
    respond(res, 401, "UNAUTHORIZED", "Authentication token is invalid.");
    return;
  }

  const clerkUserId = stringClaim(claims.sub);
  if (!clerkUserId) {
    respond(res, 401, "UNAUTHORIZED", "Authentication token is invalid.");
    return;
  }

  req.clerkUserId = clerkUserId;
  next();
}

export function requireVerifiedIdentity(req: Request, res: Response, next: NextFunction): void {
  void verifyIdentity(req, res, next);
}

export function assertAuthConfigured(): void {
  if (!process.env.DATABASE_URL?.trim() || !process.env.CLERK_SECRET_KEY?.trim()) {
    throw new AuthConfigurationError("Clerk authentication is not configured.");
  }
}
