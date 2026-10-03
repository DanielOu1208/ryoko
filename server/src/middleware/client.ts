// Reads X-Install-Id, X-Client-Version and the client IP into the context (design §7).

import type { IncomingMessage } from 'node:http';
import type { Context, MiddlewareHandler } from 'hono';
import { ApiError } from '../errors.ts';

export interface ClientInfo {
  /** Anonymous install id (a UUID from the app). Null if the client didn't send one. */
  installId: string | null;
  clientVersion: string | null;
  /** The caller's IP: Funnel's X-Forwarded-For when the peer is local, else the socket peer. */
  clientIp: string;
}

export type AppEnv = { Variables: ClientInfo };

const INSTALL_ID = /^[A-Za-z0-9._-]{1,64}$/;

function isLoopback(address: string): boolean {
  return address === '::1' || address.startsWith('127.') || address.startsWith('::ffff:127.');
}

/**
 * The server listens on 127.0.0.1 only, so every peer is local. Tailscale Funnel connects
 * from loopback and adds X-Forwarded-For; its last entry is the one Funnel appended,
 * so a client can't spoof it by sending its own header.
 */
export function clientIp(c: Context): string {
  const incoming = (c.env as { incoming?: IncomingMessage } | undefined)?.incoming;
  const peer = incoming?.socket?.remoteAddress ?? 'unknown';
  if (peer === 'unknown' || isLoopback(peer)) {
    const forwarded = c.req.header('x-forwarded-for')?.split(',').at(-1)?.trim();
    if (forwarded) return forwarded;
  }
  return peer;
}

export function clientInfo(): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const installId = c.req.header('x-install-id')?.trim() || null;
    if (installId !== null && !INSTALL_ID.test(installId)) {
      throw new ApiError('invalid_request', 'X-Install-Id must be 1–64 letters, digits, dots, dashes or underscores.');
    }
    const version = c.req.header('x-client-version')?.replace(/[^\x20-\x7e]/g, '').trim().slice(0, 64) || null;
    c.set('installId', installId);
    c.set('clientVersion', version);
    c.set('clientIp', clientIp(c));
    await next();
  };
}
