// In-memory rate limits: about 60 requests a minute per install id and per IP (design §6.4).
// Token buckets: each key holds up to `perMinute` tokens and refills continuously.
// A request needs a token from every one of its keys.

import type { MiddlewareHandler } from 'hono';
import { ApiError } from '../errors.ts';
import type { AppEnv } from './client.ts';

interface Bucket {
  tokens: number;
  updatedAt: number;
}

export class RateLimiter {
  private readonly buckets = new Map<string, Bucket>();
  private readonly capacity: number;
  private readonly refillPerMs: number;
  private lastSweep = 0;

  constructor(perMinute: number) {
    this.capacity = perMinute;
    this.refillPerMs = perMinute / 60_000;
  }

  /** Takes one token from every key, or none. Returns seconds to wait when limited. */
  take(keys: string[], now = Date.now()): { ok: true } | { ok: false; retryAfterSeconds: number } {
    this.sweep(now);
    const buckets = keys.map((key) => this.refill(key, now));
    const empty = buckets.filter((b) => b.tokens < 1);
    if (empty.length > 0) {
      const waitMs = Math.max(...empty.map((b) => (1 - b.tokens) / this.refillPerMs));
      return { ok: false, retryAfterSeconds: Math.max(1, Math.ceil(waitMs / 1000)) };
    }
    for (const bucket of buckets) bucket.tokens -= 1;
    return { ok: true };
  }

  get size(): number {
    return this.buckets.size;
  }

  private refill(key: string, now: number): Bucket {
    let bucket = this.buckets.get(key);
    if (!bucket) {
      bucket = { tokens: this.capacity, updatedAt: now };
      this.buckets.set(key, bucket);
      return bucket;
    }
    bucket.tokens = Math.min(this.capacity, bucket.tokens + (now - bucket.updatedAt) * this.refillPerMs);
    bucket.updatedAt = now;
    return bucket;
  }

  /** Drops buckets that have refilled completely, at most once a minute. */
  private sweep(now: number): void {
    if (now - this.lastSweep < 60_000) return;
    this.lastSweep = now;
    for (const [key, bucket] of this.buckets) {
      if (bucket.tokens + (now - bucket.updatedAt) * this.refillPerMs >= this.capacity) this.buckets.delete(key);
    }
  }
}

export function rateLimit(limiter: RateLimiter): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const keys = [`ip:${c.get('clientIp')}`];
    const installId = c.get('installId');
    if (installId) keys.push(`install:${installId}`);
    const result = limiter.take(keys);
    if (!result.ok) {
      throw new ApiError('rate_limited', `Too many requests. Try again in ${result.retryAfterSeconds} s.`, {
        headers: { 'Retry-After': String(result.retryAfterSeconds) },
      });
    }
    await next();
  };
}
