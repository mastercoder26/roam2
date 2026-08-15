/**
 * Minimal in-memory sliding-window rate limiter for the public route-analysis
 * endpoints, which proxy metered Google APIs. Bounds a single Node process
 * only — a multi-instance deployment needs a shared store (e.g. Redis).
 */

export interface RateLimiterOptions {
  windowMs: number;
  maxRequests: number;
}

export interface RateLimitResult {
  allowed: boolean;
  /** Seconds the caller should wait before retrying. 0 when allowed. */
  retryAfterSeconds: number;
}

export interface RateLimiter {
  check(key: string, now?: number): RateLimitResult;
}

/**
 * Creates a rate limiter keyed by an arbitrary string (typically client IP).
 * Uses a sliding window log per key.
 *
 * Pruning a key's own timestamps on its own check is not enough: a key that
 * is never seen again keeps its entry forever, so a stream of distinct client
 * addresses would grow the map without bound. A sweep runs at most once per
 * window and drops every key whose hits have all expired, keeping memory
 * proportional to the active caller count rather than to the number of
 * addresses ever seen.
 */
export function createRateLimiter(options: RateLimiterOptions): RateLimiter {
  if (options.windowMs <= 0 || options.maxRequests <= 0) {
    throw new Error("Rate limiter windowMs and maxRequests must be positive");
  }

  const hitsByKey = new Map<string, number[]>();
  let lastSweptAt = Number.NEGATIVE_INFINITY;

  function sweepExpiredKeys(now: number): void {
    if (now - lastSweptAt < options.windowMs) return;
    lastSweptAt = now;

    for (const [key, timestamps] of hitsByKey) {
      const newest = timestamps[timestamps.length - 1];
      if (newest === undefined || now - newest >= options.windowMs) {
        hitsByKey.delete(key);
      }
    }
  }

  function check(key: string, now: number = Date.now()): RateLimitResult {
    sweepExpiredKeys(now);
    const recent = (hitsByKey.get(key) ?? []).filter(
      (timestamp) => now - timestamp < options.windowMs
    );

    if (recent.length >= options.maxRequests) {
      hitsByKey.set(key, recent);
      const retryAfterMs = options.windowMs - (now - recent[0]);
      return {
        allowed: false,
        retryAfterSeconds: Math.max(1, Math.ceil(retryAfterMs / 1000)),
      };
    }

    recent.push(now);
    hitsByKey.set(key, recent);
    return { allowed: true, retryAfterSeconds: 0 };
  }

  return { check };
}
