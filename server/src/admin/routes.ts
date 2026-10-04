// The dashboard: GET /admin (one page) and a small JSON API under /admin/api, for
// this Mac only. Anything forwarded (Funnel) is a 404, the Host must be loopback
// (so DNS rebinding can't reach it), and writes need the X-Ryoko-Admin header,
// which a cross-site form or a no-cors fetch can't send. It never sends a key's value.

import { readFileSync } from 'node:fs';
import type { IncomingMessage } from 'node:http';
import { Hono, type MiddlewareHandler } from 'hono';
import { ConfigError, PROVIDER_DEFAULTS, THINKING_LEVELS } from '../config.ts';
import { ApiError } from '../errors.ts';
import { GMI_MODEL_IDS } from '../llm/registry.ts';
import { isLoopback, type AppEnv } from '../middleware/client.ts';
import type { SessionLocks } from '../sessions.ts';
import { RUNTIME_SETTINGS, type Runtime } from './runtime.ts';

const PAGE = readFileSync(new URL('./page.html', import.meta.url), 'utf8');

const LOCAL_HOSTS = new Set(['127.0.0.1', 'localhost', '[::1]']);
const FORWARDED_HEADERS = ['x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto', 'forwarded'];
/** Provider and service keys: the dashboard shows whether each is set, never its value. */
const KEYS = ['GMI_API_KEY', 'GEMINI_API_KEY', 'EXA_API_KEY', 'SONIOX_API_KEY'];

function localOnly(): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const peer = (c.env as { incoming?: IncomingMessage } | undefined)?.incoming?.socket?.remoteAddress;
    const local =
      (!peer || isLoopback(peer)) && LOCAL_HOSTS.has(new URL(c.req.url).hostname) && !FORWARDED_HEADERS.some((name) => c.req.header(name));
    if (!local) throw new ApiError('invalid_request', `No such endpoint: ${c.req.method} ${c.req.path}`, { status: 404 });
    if (c.req.method !== 'GET' && c.req.header('x-ryoko-admin') !== '1') {
      throw new ApiError('invalid_request', 'Dashboard changes need the X-Ryoko-Admin: 1 header.', { status: 403 });
    }
    c.header('Cache-Control', 'no-store');
    await next();
  };
}

type Block = { type?: string; text?: string; name?: string; arguments?: unknown };

/** One transcript message as plain text: thinking and images left out, long tool results cut. */
function describeMessage(message: unknown): { role: string; text: string } {
  const m = message as { role?: string; content?: string | Block[]; sections?: Record<string, string | null>; toolName?: string; errorMessage?: string };
  const role = m.role ?? 'unknown';
  const parts: string[] = [];
  if (typeof m.content === 'string') parts.push(m.content);
  else if (Array.isArray(m.content)) {
    for (const block of m.content) {
      if (block.type === 'text' && block.text) parts.push(block.text);
      else if (block.type === 'toolCall') parts.push(`→ ${block.name}(${JSON.stringify(block.arguments ?? {})})`);
    }
  }
  if (m.sections) for (const [name, text] of Object.entries(m.sections)) if (text) parts.push(`[${name}]\n${text}`);
  if (m.errorMessage) parts.push(`(error: ${m.errorMessage})`);
  let text = parts.join('\n\n');
  if (role === 'toolResult') text = `${m.toolName ?? 'tool'} returned:\n${text.length > 3000 ? `${text.slice(0, 3000)}…` : text}`;
  return { role, text };
}

export function adminRoutes(runtime: Runtime, sessions: SessionLocks): Hono<AppEnv> {
  const admin = new Hono<AppEnv>();
  admin.use(localOnly());

  const status = () => {
    const { config } = runtime;
    return {
      server: { pid: process.pid, node: process.version, port: config.port, startedAt: runtime.startedAt, now: Date.now() },
      model: config.model,
      /** Each skill's default model as {provider, modelId, reasoning}; a Mimo chat can use another (see its activity). */
      models: config.models,
      keys: Object.fromEntries(KEYS.map((name) => [name, runtime.hasKey(name)])),
      budget: runtime.budget ? { spentUsd: runtime.budget.spentTodayUsd, limitUsd: runtime.budget.limitUsd } : null,
      cache: runtime.cache ? { entries: runtime.cache.size, onDisk: config.cacheDir !== null } : null,
      limits: { rateLimitPerMinute: config.rateLimitPerMinute, timeouts: config.timeouts, faux: config.faux },
      mimo: { sessions: runtime.mimoSessions?.summaries() ?? [], running: sessions.running },
      settings: runtime.settings(),
      overrides: runtime.overrides,
      choices: {
        models: ['gmi', ...GMI_MODEL_IDS.map((id) => `gmi:${id}`), 'google', `google:${PROVIDER_DEFAULTS.google.modelId}`],
        reasoning: THINKING_LEVELS,
      },
      activity: runtime.activity.list(),
    };
  };

  /** Runs a settings change; a bad value is a 400 with the config's own message. */
  const change = (apply: () => boolean) => {
    try {
      return { rebuilt: apply(), status: status() };
    } catch (err) {
      if (err instanceof ConfigError) throw new ApiError('invalid_request', err.message);
      throw err;
    }
  };

  admin.get('/', (c) => c.html(PAGE));
  admin.get('/api/status', (c) => c.json(status()));

  admin.get('/api/sessions/:id', (c) => {
    const id = c.req.param('id');
    const mimo = runtime.mimoSessions;
    if (!mimo?.summaries().some((s) => s.id === id)) throw new ApiError('invalid_request', `No Mimo session ${id}.`, { status: 404 });
    return c.json({ id, messages: mimo.transcript(id).map(describeMessage) });
  });

  admin.post('/api/settings', async (c) => {
    const body = await c.req.json().catch(() => null);
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
      throw new ApiError('invalid_request', `Send a JSON object of settings: ${RUNTIME_SETTINGS.join(', ')}.`);
    }
    return c.json(change(() => runtime.apply(body as Record<string, unknown>)));
  });
  admin.post('/api/settings/reset', (c) => c.json(change(() => runtime.reset())));

  admin.post('/api/cache/clear', (c) => {
    runtime.cache?.clear();
    return c.json(status());
  });
  admin.post('/api/budget/reset', (c) => {
    runtime.budget?.resetToday();
    return c.json(status());
  });
  admin.post('/api/sessions/clear', (c) => {
    runtime.mimoSessions?.clear();
    return c.json(status());
  });

  return admin;
}
