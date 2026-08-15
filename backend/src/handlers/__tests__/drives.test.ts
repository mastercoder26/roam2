import type { Request, Response } from "express";
import { afterEach, describe, expect, it } from "vitest";
import { DatabaseOperationError } from "../../errors.js";
import { setPoolForTests, type QueryResult } from "../../db/pool.js";
import { handleGetDrive, handleGetDrives, handleDeleteDrive } from "../drives.js";

const userId = "00000000-0000-0000-0000-000000000001";
const driveId = "00000000-0000-0000-0000-000000000002";

function responseDouble() {
  const response = {
    statusCode: 200,
    jsonBody: undefined as unknown,
    status(code: number) {
      response.statusCode = code;
      return response;
    },
    json(body: unknown) {
      response.jsonBody = body;
      return response;
    },
    end() {
      return response;
    },
  };
  return response;
}

function request(overrides: Partial<Request> = {}): Request {
  return {
    body: {},
    params: {},
    query: {},
    user: { id: userId, email: "driver@example.com" },
    ...overrides,
  } as Request;
}

afterEach(() => {
  setPoolForTests(null);
  delete process.env.DATABASE_URL;
});

describe("drive handlers", () => {
  it("returns a paginated drive list and cursor", async () => {
    process.env.DATABASE_URL = "postgres://test";
    setPoolForTests({
      query: async <Row extends Record<string, unknown>>(): Promise<QueryResult<Row>> => ({
        rows: [{
          id: driveId,
          user_id: userId,
          started_at: new Date("2026-01-02T03:04:05.000Z"),
          duration_seconds: 120,
          distance_meters: 1500,
          score: 92,
          top_speed_meters_per_second: 20,
          event_count: 3,
          recording_time_zone_identifier: null,
          payload: { id: driveId },
          created_at: new Date("2026-01-02T03:05:05.000Z"),
          updated_at: new Date("2026-01-02T03:05:05.000Z"),
        }] as unknown as Row[],
        rowCount: 1,
      }),
      connect: async () => { throw new Error("not used"); },
      on: () => { throw new Error("not used"); },
    });
    const response = responseDouble();

    await handleGetDrives(request({ query: { limit: "1" } }), response as unknown as Response);

    expect(response.statusCode).toBe(200);
    expect(response.jsonBody).toMatchObject({
      drives: [{ id: driveId, startedAt: "2026-01-02T03:04:05.000Z" }],
      nextCursor: "2026-01-02T03:04:05.000Z",
    });
  });

  it("returns 404 for a drive owned by another user", async () => {
    process.env.DATABASE_URL = "postgres://test";
    setPoolForTests({
      query: async <Row extends Record<string, unknown>>(): Promise<QueryResult<Row>> => ({ rows: [], rowCount: 0 }),
      connect: async () => { throw new Error("not used"); },
      on: () => { throw new Error("not used"); },
    });
    const response = responseDouble();

    await handleGetDrive(request({ params: { id: driveId } }), response as unknown as Response);

    expect(response.statusCode).toBe(404);
    expect(response.jsonBody).toEqual({ error: "Drive not found.", code: "NOT_FOUND", requestId: expect.any(String) });
  });

  it("returns 404 rather than deleting another user's drive", async () => {
    process.env.DATABASE_URL = "postgres://test";
    setPoolForTests({
      query: async <Row extends Record<string, unknown>>(): Promise<QueryResult<Row>> => ({ rows: [], rowCount: 0 }),
      connect: async () => { throw new Error("not used"); },
      on: () => { throw new Error("not used"); },
    });
    const response = responseDouble();

    await handleDeleteDrive(request({ params: { id: driveId } }), response as unknown as Response);

    expect(response.statusCode).toBe(404);
  });

  it("rejects an invalid uuid with 400", async () => {
    const response = responseDouble();
    await handleGetDrive(request({ params: { id: "not-a-uuid" } }), response as unknown as Response);
    expect(response.statusCode).toBe(400);
    expect(response.jsonBody).toMatchObject({ code: "VALIDATION_ERROR", requestId: expect.any(String) });
  });

  it("maps database failures to 503", async () => {
    process.env.DATABASE_URL = "postgres://test";
    setPoolForTests({
      query: async <Row extends Record<string, unknown>>(): Promise<QueryResult<Row>> => { throw new DatabaseOperationError(new Error("database down")); },
      connect: async () => { throw new Error("not used"); },
      on: () => { throw new Error("not used"); },
    });
    const response = responseDouble();

    await handleGetDrives(request(), response as unknown as Response);

    expect(response.statusCode).toBe(503);
    expect(response.jsonBody).toMatchObject({ code: "SERVICE_UNAVAILABLE", requestId: expect.any(String) });
  });
});
