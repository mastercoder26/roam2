import type { Request, Response } from "express";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { findOrCreateByClerkIdMock, verifyTokenMock } = vi.hoisted(() => ({
  findOrCreateByClerkIdMock: vi.fn(),
  verifyTokenMock: vi.fn(),
}));

vi.mock("@clerk/backend", () => ({ verifyToken: verifyTokenMock }));
vi.mock("../../db/repositories/users.js", () => ({
  findOrCreateByClerkId: findOrCreateByClerkIdMock,
}));

import { requireAuth, requireVerifiedIdentity } from "../middleware.js";

const localUser = {
  id: "00000000-0000-0000-0000-000000000001",
  clerkUserId: "user_clerk_123",
  email: "driver@example.com",
  displayName: "Driver",
  createdAt: new Date("2026-01-01T00:00:00.000Z"),
  updatedAt: new Date("2026-01-01T00:00:00.000Z"),
  emailVerifiedAt: null,
  deletedAt: null,
};

function requestWithToken(token?: string): Request {
  return {
    header: vi.fn(() => token ? `Bearer ${token}` : undefined),
  } as unknown as Request;
}

function responseDouble() {
  const response = {
    statusCode: 200,
    body: undefined as unknown,
    status(code: number) {
      response.statusCode = code;
      return response;
    },
    json(body: unknown) {
      response.body = body;
      return response;
    },
  };
  return response as unknown as Response & { statusCode: number; body: unknown };
}

async function settle(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

describe("Clerk authentication middleware", () => {
  const previousDatabaseUrl = process.env.DATABASE_URL;
  const previousClerkSecret = process.env.CLERK_SECRET_KEY;

  beforeEach(() => {
    process.env.DATABASE_URL = "postgres://localhost/roam";
    process.env.CLERK_SECRET_KEY = "test-clerk-secret";
    findOrCreateByClerkIdMock.mockResolvedValue(localUser);
    verifyTokenMock.mockResolvedValue({
      sub: "user_clerk_123",
      email: "driver@example.com",
      name: "Driver",
    });
  });

  afterEach(() => {
    vi.clearAllMocks();
    if (previousDatabaseUrl === undefined) delete process.env.DATABASE_URL;
    else process.env.DATABASE_URL = previousDatabaseUrl;
    if (previousClerkSecret === undefined) delete process.env.CLERK_SECRET_KEY;
    else process.env.CLERK_SECRET_KEY = previousClerkSecret;
  });

  it("verifies a valid token and resolves the local user", async () => {
    const request = requestWithToken("valid-token");
    const response = responseDouble();
    const next = vi.fn();

    requireAuth(request, response, next);
    await settle();

    expect(verifyTokenMock).toHaveBeenCalledWith("valid-token", { secretKey: "test-clerk-secret" });
    expect(findOrCreateByClerkIdMock).toHaveBeenCalledWith({
      clerkUserId: "user_clerk_123",
      email: "driver@example.com",
      displayName: "Driver",
    });
    expect(request.user).toEqual({
      id: localUser.id,
      email: localUser.email,
      clerkUserId: localUser.clerkUserId,
    });
    expect(next).toHaveBeenCalledOnce();
    expect(response.statusCode).toBe(200);
  });

  it.each(["invalid", "expired"])("returns 401 for an %s token", async (reason) => {
    verifyTokenMock.mockRejectedValueOnce(new Error(reason));
    const response = responseDouble();

    requireAuth(requestWithToken(`${reason}-token`), response, vi.fn());
    await settle();

    expect(response.statusCode).toBe(401);
    expect(response.body).toEqual({
      error: "Authentication token is invalid.",
      code: "UNAUTHORIZED",
      requestId: expect.any(String),
    });
  });

  it("returns 401 when the authorization header is missing", async () => {
    const response = responseDouble();
    const next = vi.fn();

    requireAuth(requestWithToken(), response, next);
    await settle();

    expect(response.statusCode).toBe(401);
    expect(response.body).toEqual({
      error: "Authentication is required.",
      code: "UNAUTHORIZED",
      requestId: expect.any(String),
    });
    expect(verifyTokenMock).not.toHaveBeenCalled();
    expect(next).not.toHaveBeenCalled();
  });

  it("returns 503 when CLERK_SECRET_KEY is missing", async () => {
    delete process.env.CLERK_SECRET_KEY;
    const response = responseDouble();

    requireAuth(requestWithToken("valid-token"), response, vi.fn());
    await settle();

    expect(response.statusCode).toBe(503);
    expect(response.body).toEqual({
      error: "Account services are temporarily unavailable. Please try again shortly.",
      code: "SERVICE_UNAVAILABLE",
      requestId: expect.any(String),
    });
    expect(verifyTokenMock).not.toHaveBeenCalled();
  });

  it("provisions one local identity when two requests arrive concurrently", async () => {
    const requests = [requestWithToken("valid-token"), requestWithToken("valid-token")];
    const responses = [responseDouble(), responseDouble()];
    const next = vi.fn();

    requireAuth(requests[0], responses[0], next);
    requireAuth(requests[1], responses[1], next);
    await settle();

    expect(findOrCreateByClerkIdMock).toHaveBeenCalledTimes(2);
    expect(requests[0].user?.id).toBe(localUser.id);
    expect(requests[1].user?.id).toBe(localUser.id);
    expect(next).toHaveBeenCalledTimes(2);
  });
});

describe("requireVerifiedIdentity", () => {
  const previousDatabaseUrl = process.env.DATABASE_URL;
  const previousClerkSecret = process.env.CLERK_SECRET_KEY;

  beforeEach(() => {
    process.env.CLERK_SECRET_KEY = "test-clerk-secret";
    verifyTokenMock.mockResolvedValue({ sub: "user_clerk_123" });
  });

  afterEach(() => {
    vi.clearAllMocks();
    if (previousDatabaseUrl === undefined) delete process.env.DATABASE_URL;
    else process.env.DATABASE_URL = previousDatabaseUrl;
    if (previousClerkSecret === undefined) delete process.env.CLERK_SECRET_KEY;
    else process.env.CLERK_SECRET_KEY = previousClerkSecret;
  });

  it("admits a signed-in account without touching the database", async () => {
    // The route deployment has no DATABASE_URL at all. Authenticating must
    // still succeed, or route analysis could not run there.
    delete process.env.DATABASE_URL;
    const request = requestWithToken("valid-token");
    const response = responseDouble();
    const next = vi.fn();

    requireVerifiedIdentity(request, response, next);
    await settle();

    expect(next).toHaveBeenCalledTimes(1);
    expect(request.clerkUserId).toBe("user_clerk_123");
    expect(findOrCreateByClerkIdMock).not.toHaveBeenCalled();
  });

  it("rejects an anonymous caller before any upstream work", async () => {
    const request = requestWithToken(undefined);
    const response = responseDouble();
    const next = vi.fn();

    requireVerifiedIdentity(request, response, next);
    await settle();

    expect(next).not.toHaveBeenCalled();
    expect(response.statusCode).toBe(401);
    expect(verifyTokenMock).not.toHaveBeenCalled();
  });

  it("rejects an invalid token", async () => {
    verifyTokenMock.mockRejectedValue(new Error("bad token"));
    const request = requestWithToken("forged-token");
    const response = responseDouble();
    const next = vi.fn();

    requireVerifiedIdentity(request, response, next);
    await settle();

    expect(next).not.toHaveBeenCalled();
    expect(response.statusCode).toBe(401);
    expect(request.clerkUserId).toBeUndefined();
  });

  it("reports 503 when the deployment has no Clerk secret", async () => {
    delete process.env.CLERK_SECRET_KEY;
    const request = requestWithToken("valid-token");
    const response = responseDouble();
    const next = vi.fn();

    requireVerifiedIdentity(request, response, next);
    await settle();

    expect(next).not.toHaveBeenCalled();
    expect(response.statusCode).toBe(503);
  });
});
