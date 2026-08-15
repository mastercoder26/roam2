import { config } from "dotenv";
import { resolve } from "node:path";
import express from "express";
import type { NextFunction, Request, Response } from "express";
import {
  handleDepartureComparison,
  handleDifficulty,
} from "./src/handlers/difficulty.js";
import { createRequestId, logInternalFailure, logRateLimited } from "./src/errors.js";
import { createRateLimiter } from "./src/utils/rateLimiter.js";
import {
  handleDeleteAccount,
  handleMe,
} from "./src/handlers/auth.js";
import { handleGetProfile, handleUpdateProfile } from "./src/handlers/profile.js";
import { checkDatabase, isDatabaseConfigured } from "./src/db/pool.js";
import { fileURLToPath } from "node:url";
import { requireAuth, requireVerifiedIdentity } from "./src/auth/middleware.js";
import {
  handleDeleteDrive,
  handleDeleteSavedRoute,
  handleGetDrive,
  handleGetDriveStats,
  handleGetDrives,
  handleGetSavedRoutes,
  handleUpsertDrives,
  handleUpsertSavedRoute,
} from "./src/handlers/drives.js";

// `server.ts` lives in `backend/`, alongside the local environment files.
config({ path: resolve(import.meta.dirname, ".env.local") });
config({ path: resolve(import.meta.dirname, ".env") });

// Fail loudly (but not fatally — see the per-request 503 fallback in the
// handlers) so a missing key is obvious at boot instead of on first request.
if (!process.env.GOOGLE_MAPS_API_KEY) {
  console.error(
    "GOOGLE_MAPS_API_KEY is not configured. Route analysis requests will fail until it is set in backend/.env.local."
  );
}

if (!isDatabaseConfigured()) {
  console.error(
    "DATABASE_URL is not configured. Account and profile requests will return 503 until it is set."
  );
}

if (!process.env.CLERK_SECRET_KEY) {
  console.error(
    "CLERK_SECRET_KEY is not configured. Account and profile requests will return 503 until it is set."
  );
}

function getAllowedOrigins(): string[] {
  const raw = process.env.ALLOWED_ORIGINS ?? "*";
  if (raw === "*") return ["*"];
  return raw.split(",").map((o) => o.trim()).filter(Boolean);
}

function getRateLimitConfig(): { windowMs: number; maxRequests: number } {
  const windowMs = Number(process.env.RATE_LIMIT_WINDOW_MS ?? 60_000);
  const maxRequests = Number(process.env.RATE_LIMIT_MAX_REQUESTS ?? 30);
  return {
    windowMs: Number.isFinite(windowMs) && windowMs > 0 ? windowMs : 60_000,
    maxRequests: Number.isFinite(maxRequests) && maxRequests > 0 ? maxRequests : 30,
  };
}

export const app = express();

// Cloud Run terminates the connection at Google's front end, so the raw
// socket address is the proxy's, identical for every caller. Trusting exactly
// one hop lets the rate limiter below use the real client address without
// letting a client spoof `X-Forwarded-For` to dodge the limit.
app.set("trust proxy", 1);

const port = Number(process.env.PORT ?? 3000);
const allowedOrigins = getAllowedOrigins();
const rateLimiter = createRateLimiter(getRateLimitConfig());
const authRateLimiter = createRateLimiter({ windowMs: 15 * 60_000, maxRequests: 10 });

app.use(express.json());

app.use((req, res, next) => {
  const origin = req.headers.origin ?? "";

  if (allowedOrigins.includes("*")) {
    res.setHeader("Access-Control-Allow-Origin", "*");
  } else if (origin && allowedOrigins.includes(origin)) {
    res.setHeader("Access-Control-Allow-Origin", origin);
  }

  res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");

  if (req.method === "OPTIONS") {
    res.status(204).end();
    return;
  }

  next();
});

/**
 * Both routes below proxy to metered upstream APIs (Google Routes/Roads).
 * Rate limiting prefers the verified Clerk subject so one account can't
 * multiply its budget by rotating addresses, falling back to `req.ip`
 * (trusted proxy address, see above).
 */
function rateLimit(endpoint: string) {
  return (req: Request, res: Response, next: NextFunction) => {
    const key = req.clerkUserId ?? req.ip ?? req.socket.remoteAddress ?? "unknown";
    const result = rateLimiter.check(key);

    if (!result.allowed) {
      const requestId = createRequestId();
      logRateLimited(requestId, { endpoint });
      res.setHeader("Retry-After", String(result.retryAfterSeconds));
      res.status(429).json({
        error: "Too many requests. Please slow down and try again shortly.",
        code: "RATE_LIMITED",
        requestId,
      });
      return;
    }

    next();
  };
}

function asyncHandler(handler: (req: Request, res: Response) => Promise<void>) {
  return (req: Request, res: Response, next: NextFunction) => {
    void handler(req, res).catch(next);
  };
}

function authRateLimit(req: Request, res: Response, next: NextFunction): void {
  const key = req.ip ?? req.socket.remoteAddress ?? "unknown";
  const result = authRateLimiter.check(key);
  if (!result.allowed) {
    const requestId = createRequestId();
    logRateLimited(requestId, { endpoint: "auth" });
    res.setHeader("Retry-After", String(result.retryAfterSeconds));
    res.status(429).json({
      error: "Too many requests. Please try again later.",
      code: "RATE_LIMITED",
      requestId,
    });
    return;
  }
  next();
}

app.get("/health", async (_req, res) => {
  const database = await checkDatabase();
  res.status(200).json({
    status: database === "up" ? "ok" : "degraded",
    database,
    version: process.env.npm_package_version ?? "1.0.0",
  });
});

/**
 * Route analysis proxies metered Google APIs, so it's gated on a signed-in
 * account. The limiter runs on both sides of the identity check: first by
 * address (bounds how much token verification a flood can force), then by
 * `req.clerkUserId` (bounds each account regardless of address rotation).
 *
 * Uses `requireVerifiedIdentity`, not `requireAuth` — see the note on that
 * middleware for why this keeps the deployment free of a database dependency.
 */
app.post(
  "/api/route/difficulty",
  rateLimit("difficulty"),
  requireVerifiedIdentity,
  rateLimit("difficulty"),
  asyncHandler(handleDifficulty)
);

app.post(
  "/api/route/departure-comparison",
  rateLimit("departure-comparison"),
  requireVerifiedIdentity,
  rateLimit("departure-comparison"),
  asyncHandler(handleDepartureComparison)
);

app.get("/api/auth/me", authRateLimit, requireAuth, asyncHandler(handleMe));
app.get("/api/profile", requireAuth, asyncHandler(handleGetProfile));
app.put("/api/profile", requireAuth, asyncHandler(handleUpdateProfile));
app.delete("/api/account", requireAuth, asyncHandler(handleDeleteAccount));
app.get("/api/drives", requireAuth, asyncHandler(handleGetDrives));
app.post("/api/drives", requireAuth, asyncHandler(handleUpsertDrives));
app.get("/api/drives/stats", requireAuth, asyncHandler(handleGetDriveStats));
app.get("/api/drives/:id", requireAuth, asyncHandler(handleGetDrive));
app.delete("/api/drives/:id", requireAuth, asyncHandler(handleDeleteDrive));
app.get("/api/saved-routes", requireAuth, asyncHandler(handleGetSavedRoutes));
app.post("/api/saved-routes", requireAuth, asyncHandler(handleUpsertSavedRoute));
app.delete("/api/saved-routes/:id", requireAuth, asyncHandler(handleDeleteSavedRoute));

app.use((error: unknown, _req: Request, res: Response, next: NextFunction) => {
  if (res.headersSent) {
    next(error);
    return;
  }
  const requestId = createRequestId();
  if (error instanceof SyntaxError) {
    res.status(400).json({ error: "Request body is invalid JSON.", code: "VALIDATION_ERROR", requestId });
    return;
  }
  logInternalFailure(requestId, { endpoint: "unknown" }, error);
  res.status(500).json({ error: "An unexpected error occurred.", code: "INTERNAL_ERROR", requestId });
});

export function startServer() {
  const server = app.listen(port, () => {
    console.log(`Roam API listening on http://localhost:${port}`);
  });

  server.on("error", (error: NodeJS.ErrnoException) => {
    if (error.code === "EADDRINUSE") {
      console.error(
        `Port ${port} is already in use. Stop the existing Roam API, or start this one with PORT=3001 npm run dev.`,
      );
    } else {
      console.error("Roam API failed to start:", error);
    }

    process.exitCode = 1;
  });
  return server;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  startServer();
}
