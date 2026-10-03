// Bearer APP_TOKEN on every /v1 route, compared in constant time (design §6.4).

import { createHash, timingSafeEqual } from 'node:crypto';
import type { MiddlewareHandler } from 'hono';
import { ApiError } from '../errors.ts';

const digest = (value: string) => createHash('sha256').update(value, 'utf8').digest();

/** Constant-time string comparison. Hashing first hides the expected length too. */
export function tokensMatch(provided: string, expected: string): boolean {
  return timingSafeEqual(digest(provided), digest(expected));
}

export function bearerAuth(appToken: string): MiddlewareHandler {
  return async (c, next) => {
    const header = c.req.header('authorization') ?? '';
    const match = /^Bearer[ \t]+(\S+)[ \t]*$/i.exec(header);
    const challenge = { 'WWW-Authenticate': 'Bearer' };
    if (!match) {
      throw new ApiError('unauthorized', 'Missing bearer token.', { headers: challenge });
    }
    if (!tokensMatch(match[1] as string, appToken)) {
      throw new ApiError('unauthorized', "The app token isn't valid.", { headers: challenge });
    }
    await next();
  };
}
