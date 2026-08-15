import type { Request, Response } from "express";
import { describe, expect, it, vi } from "vitest";
import {
  analyzeDepartureComparisonRequest,
  handleDifficulty,
  handleDepartureComparison,
  type RouteAnalysisDependencies,
  validateDepartureComparisonRequest,
  validateDifficultyRequest,
} from "../difficulty.js";
import { neutralConditions } from "../../enrichment/index.js";
import { scoreRoutes } from "../../scoring/index.js";
import { urbanRoute } from "../../scoring/__tests__/fixtures/urban-route.js";

describe("difficulty request validation", () => {
  it("accepts bounded GPS endpoints for an automatically analyzed drive", () => {
    const origin = { latitude: 30.2672, longitude: -97.7431 };
    const destination = { latitude: 30.3072, longitude: -97.7031 };

    expect(validateDifficultyRequest({ origin, destination })).toMatchObject({
      origin,
      destination,
    });
  });

  it("rejects invalid GPS endpoints before route work begins", () => {
    expect(() => validateDifficultyRequest({
      origin: { latitude: 91, longitude: -97.7431 },
      destination: { latitude: 30.3072, longitude: -97.7031 },
    })).toThrow();
  });

  it("accepts a client-local departure clock", () => {
    expect(
      validateDifficultyRequest({
        origin: "A",
        destination: "B",
        departureLocalMinutes: 22 * 60 + 15,
      })
    ).toMatchObject({ departureLocalMinutes: 1335 });
  });

  it("rejects an invalid client-local departure clock", () => {
    expect(() =>
      validateDifficultyRequest({
        origin: "A",
        destination: "B",
        departureLocalMinutes: 24 * 60,
      })
    ).toThrow("departureLocalMinutes must be an integer between 0 and 1439");
  });

  it("rejects malformed and unrecognized route inputs", () => {
    const valid = {
      origin: "A",
      destination: "B",
      departureTime: "2026-07-18T18:30:00-05:00",
      departureLocalMinutes: 18 * 60 + 30,
      includeAlternates: true,
      continuousDriveMinutes: 90.5,
    };

    expect(validateDifficultyRequest(valid)).toEqual(valid);
    expect(() =>
      validateDifficultyRequest({ ...valid, departureTime: "later tonight" })
    ).toThrow("departureTime must be a valid ISO-8601 timestamp");
    expect(() =>
      validateDifficultyRequest({ ...valid, includeAlternates: "yes" })
    ).toThrow("includeAlternates must be a boolean");
    expect(() =>
      validateDifficultyRequest({ ...valid, continuousDriveMinutes: -1 })
    ).toThrow("continuousDriveMinutes must be between 0 and 1440");
    expect(() =>
      validateDifficultyRequest({ ...valid, continuousDriveMinutes: 1440.1 })
    ).toThrow("continuousDriveMinutes must be between 0 and 1440");
    expect(() =>
      validateDifficultyRequest({ ...valid, origin: "x".repeat(513) })
    ).toThrow("origin must be at most 512 characters");
    expect(() =>
      validateDifficultyRequest({ ...valid, unexpected: true })
    ).toThrow("Request body contains unrecognized field: unexpected");
  });
});

describe("departure comparison request validation", () => {
  const validCandidate = {
    id: "selected",
    departureTime: "2026-07-18T18:30:00-05:00",
    departureLocalMinutes: 18 * 60 + 30,
  };

  it("accepts one to three unique ISO-8601 candidates", () => {
    expect(
      validateDepartureComparisonRequest({
        origin: " A ",
        destination: " B ",
        candidates: [
          validCandidate,
          {
            id: "later",
            departureTime: "2026-07-18T19:30:00-05:00",
            departureLocalMinutes: 19 * 60 + 30,
          },
        ],
      })
    ).toEqual({
      origin: "A",
      destination: "B",
      candidates: [validCandidate, {
        id: "later",
        departureTime: "2026-07-18T19:30:00-05:00",
        departureLocalMinutes: 19 * 60 + 30,
      }],
    });
  });

  it("rejects malformed candidates before any route work begins", () => {
    const base = { origin: "A", destination: "B" };

    expect(() =>
      validateDepartureComparisonRequest({ ...base, candidates: [] })
    ).toThrow("candidates must contain between 1 and 3 items");
    expect(() =>
      validateDepartureComparisonRequest({
        ...base,
        candidates: [validCandidate, { ...validCandidate, id: "two" }, { ...validCandidate, id: "three" }, { ...validCandidate, id: "four" }],
      })
    ).toThrow("candidates must contain between 1 and 3 items");
    expect(() =>
      validateDepartureComparisonRequest({
        ...base,
        candidates: [validCandidate, { ...validCandidate }],
      })
    ).toThrow("candidate ids must be unique");
    expect(() =>
      validateDepartureComparisonRequest({
        ...base,
        candidates: [{ ...validCandidate, departureTime: "later tonight" }],
      })
    ).toThrow("departureTime must be a valid ISO-8601 timestamp");
    expect(() =>
      validateDepartureComparisonRequest({
        ...base,
        candidates: [{ ...validCandidate, departureLocalMinutes: 1440 }],
      })
    ).toThrow("departureLocalMinutes must be an integer between 0 and 1439");
  });
});

describe("departure comparison HTTP validation", () => {
  it("returns 400 for invalid candidate counts instead of reporting a server failure", async () => {
    const previousAPIKey = process.env.GOOGLE_MAPS_API_KEY;
    process.env.GOOGLE_MAPS_API_KEY = "test-key";
    const response = {
      status: vi.fn(),
      json: vi.fn(),
    };
    response.status.mockReturnValue(response);

    try {
      await handleDepartureComparison(
        {
          body: { origin: "A", destination: "B", candidates: [] },
        } as Request,
        response as unknown as Response
      );

      expect(response.status).toHaveBeenCalledWith(400);
      expect(response.json).toHaveBeenCalledWith({
        error: "candidates must contain between 1 and 3 items",
        code: "INVALID_REQUEST",
        requestId: expect.any(String),
      });
    } finally {
      if (previousAPIKey === undefined) {
        delete process.env.GOOGLE_MAPS_API_KEY;
      } else {
        process.env.GOOGLE_MAPS_API_KEY = previousAPIKey;
      }
    }
  });

  it("does not expose missing configuration details", async () => {
    const previousAPIKey = process.env.GOOGLE_MAPS_API_KEY;
    delete process.env.GOOGLE_MAPS_API_KEY;
    const response = {
      status: vi.fn(),
      json: vi.fn(),
    };
    response.status.mockReturnValue(response);

    try {
      await handleDifficulty(
        { body: { origin: "A", destination: "B" } } as Request,
        response as unknown as Response
      );

      expect(response.status).toHaveBeenCalledWith(503);
      expect(response.json).toHaveBeenCalledWith({
        error: "Route analysis is temporarily unavailable.",
        code: "ROUTE_UNAVAILABLE",
        requestId: expect.any(String),
      });
    } finally {
      if (previousAPIKey === undefined) {
        delete process.env.GOOGLE_MAPS_API_KEY;
      } else {
        process.env.GOOGLE_MAPS_API_KEY = previousAPIKey;
      }
    }
  });

  it("validates requests before checking backend configuration", async () => {
    const previousAPIKey = process.env.GOOGLE_MAPS_API_KEY;
    delete process.env.GOOGLE_MAPS_API_KEY;
    const response = {
      status: vi.fn(),
      json: vi.fn(),
    };
    response.status.mockReturnValue(response);

    try {
      await handleDifficulty(
        { body: { origin: "A", destination: "B", unexpected: true } } as Request,
        response as unknown as Response
      );

      expect(response.status).toHaveBeenCalledWith(400);
      expect(response.json).toHaveBeenCalledWith({
        error: "Request body contains unrecognized field: unexpected",
        code: "INVALID_REQUEST",
        requestId: expect.any(String),
      });
    } finally {
      if (previousAPIKey === undefined) {
        delete process.env.GOOGLE_MAPS_API_KEY;
      } else {
        process.env.GOOGLE_MAPS_API_KEY = previousAPIKey;
      }
    }
  });
});

function makeDependencies(
  computeRoutes: RouteAnalysisDependencies["computeRoutes"]
): RouteAnalysisDependencies {
  return {
    computeRoutes,
    enrichRouteWithSpeedLimits: async () => ({
      stepSpeedsMph: new Map(),
      postedSpeedLimitCoverage: 0,
      source: "implied" as const,
    }),
    enrichRoute: async () => neutralConditions(),
    neutralConditions,
    scoreRoutes,
  };
}

describe("departure comparison analysis", () => {
  const request = {
    origin: "Start",
    destination: "Finish",
    candidates: [
      {
        id: "earlier",
        departureTime: "2026-07-18T17:30:00-05:00",
        departureLocalMinutes: 17 * 60 + 30,
      },
      {
        id: "selected",
        departureTime: "2026-07-18T18:30:00-05:00",
        departureLocalMinutes: 18 * 60 + 30,
      },
      {
        id: "later",
        departureTime: "2026-07-18T19:30:00-05:00",
        departureLocalMinutes: 19 * 60 + 30,
      },
    ],
  };

  it("propagates each candidate time and never requests alternates", async () => {
    const calls: Array<Parameters<RouteAnalysisDependencies["computeRoutes"]>[0]> = [];
    const conditionsTimes: string[] = [];
    const scoredLocalMinutes: number[] = [];
    const dependencies = makeDependencies(async (params) => {
      calls.push(params);
      return [urbanRoute];
    });
    dependencies.enrichRoute = async (_route, options) => {
      conditionsTimes.push(options?.departureTime ?? "");
      return neutralConditions();
    };
    dependencies.scoreRoutes = (routes, optionsList) => {
      scoredLocalMinutes.push(optionsList?.[0]?.departureLocalMinutes ?? -1);
      return scoreRoutes(routes, optionsList);
    };

    const response = await analyzeDepartureComparisonRequest(
      request,
      "test-key",
      dependencies
    );

    expect(calls).toHaveLength(3);
    expect(calls.map((call) => call.departureTime)).toEqual(
      request.candidates.map((candidate) => candidate.departureTime)
    );
    expect(calls.every((call) => call.includeAlternates === false)).toBe(true);
    expect(conditionsTimes).toEqual(
      expect.arrayContaining(request.candidates.map((candidate) => candidate.departureTime))
    );
    expect(scoredLocalMinutes).toEqual(
      expect.arrayContaining(request.candidates.map((candidate) => candidate.departureLocalMinutes))
    );
    expect(response.candidates.map((candidate) => candidate.id)).toEqual(
      request.candidates.map((candidate) => candidate.id)
    );
    expect(response.candidates.every((candidate) => candidate.route !== undefined)).toBe(true);
    expect(response.candidates.every((candidate) => !("alternateRoutes" in candidate))).toBe(true);
  });

  it("keeps successful windows when one candidate is unavailable", async () => {
    const dependencies = makeDependencies(async (params) => {
      if (params.departureTime === request.candidates[1].departureTime) {
        throw new Error("Routes provider timed out");
      }
      return [urbanRoute];
    });

    const response = await analyzeDepartureComparisonRequest(
      request,
      "test-key",
      dependencies
    );

    expect(response.candidates).toHaveLength(3);
    expect(response.candidates[0].route).toBeDefined();
    expect(response.candidates[1]).toEqual({
      ...request.candidates[1],
      error: {
        message: "Route analysis is temporarily unavailable.",
        code: "ROUTE_UNAVAILABLE",
        requestId: expect.any(String),
      },
    });
    expect(response.candidates[2].route).toBeDefined();
  });

  it("keeps a route result when live enrichment is unavailable", async () => {
    const dependencies = makeDependencies(async () => [urbanRoute]);
    dependencies.enrichRoute = async () => neutralConditions();

    const response = await analyzeDepartureComparisonRequest(
      { ...request, candidates: [request.candidates[0]] },
      "test-key",
      dependencies
    );

    const route = response.candidates[0].route;
    expect(route).toBeDefined();
    expect(route?.conditions?.weather.available).toBe(false);
    expect(
      route?.routeDemands.find((demand) => demand.id === "weatherVisibility")
        ?.available
    ).toBe(false);
    expect(response.candidates[0].error).toBeUndefined();
  });
});
