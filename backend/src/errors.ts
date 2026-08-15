import { randomUUID } from "node:crypto";

export type PublicErrorCode =
  | "INVALID_REQUEST"
  | "ROUTE_UNAVAILABLE"
  | "RATE_LIMITED"
  | "VALIDATION_ERROR"
  | "UNAUTHORIZED"
  | "TOKEN_EXPIRED"
  | "EMAIL_TAKEN"
  | "SERVICE_UNAVAILABLE"
  | "INTERNAL_ERROR";

export function isDatabaseConfigured(): boolean {
  return Boolean(process.env.DATABASE_URL?.trim());
}

export class RequestValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RequestValidationError";
  }
}

export class RouteProviderError extends Error {
  readonly provider = "google-routes";

  constructor(readonly providerStatus?: number) {
    super("Routes provider returned invalid data");
    this.name = "RouteProviderError";
  }
}

export class DatabaseUnavailableError extends Error {
  constructor(message = "Database is unavailable", options?: ErrorOptions) {
    super(message);
    this.name = "DatabaseUnavailableError";
    if (options?.cause !== undefined) this.cause = options.cause;
  }
}

export class DatabaseOperationError extends DatabaseUnavailableError {
  constructor(readonly originalError: unknown) {
    super("Database operation failed");
    this.name = "DatabaseOperationError";
  }
}

export function createRequestId(): string {
  return randomUUID();
}

export function logRouteFailure(
  requestId: string,
  context: { endpoint: string; candidateIndex?: number },
  error: unknown
): void {
  const providerError = error instanceof RouteProviderError ? error : undefined;
  console.error(JSON.stringify({
    event: "route_analysis_failed",
    requestId,
    endpoint: context.endpoint,
    ...(context.candidateIndex === undefined ? {} : { candidateIndex: context.candidateIndex }),
    errorClass: error instanceof Error ? error.name : "UnknownError",
    ...(providerError ? {
      provider: providerError.provider,
      providerStatus: providerError.providerStatus ?? null,
    } : {}),
  }));
}

export function logRateLimited(
  requestId: string,
  context: { endpoint: string }
): void {
  console.error(JSON.stringify({
    event: "rate_limited",
    requestId,
    endpoint: context.endpoint,
  }));
}

export function logDatabaseFailure(
  requestId: string,
  context: { endpoint: string },
  error: unknown
): void {
  console.error(JSON.stringify({
    event: "database_request_failed",
    requestId,
    endpoint: context.endpoint,
    errorClass: error instanceof Error ? error.name : "UnknownError",
  }));
}

export function logInternalFailure(
  requestId: string,
  context: { endpoint: string },
  error: unknown
): void {
  console.error(JSON.stringify({
    event: "request_failed",
    requestId,
    endpoint: context.endpoint,
    errorClass: error instanceof Error ? error.name : "UnknownError",
  }));
}

export function publicFailure(
  error: unknown
): { status: number; code: PublicErrorCode; message: string } {
  if (error instanceof RequestValidationError) {
    return { status: 400, code: "INVALID_REQUEST", message: error.message };
  }

  return {
    status: 503,
    code: "ROUTE_UNAVAILABLE",
    message: "Route analysis is temporarily unavailable.",
  };
}
