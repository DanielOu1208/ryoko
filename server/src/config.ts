// Server config from server/.env plus the process environment.
// The process environment wins, so `MODEL=faux node src/index.ts` overrides the file.
// Secret values are never logged: describeConfig() prints only what's safe.

import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parseEnv } from 'node:util';

/** The server listens on loopback only (design §6.4). Funnel forwards to it. */
export const HOST = '127.0.0.1';
export const DEFAULT_PORT = 8792;

export interface FauxConfig {
  /** Multiplies the scripted Mimo pacing. 1 is realistic, 0 replays instantly. */
  pace: number;
  /** Extra delay before each faux JSON response, to exercise loading states. */
  latencyMs: number;
}

export interface Config {
  port: number;
  /** Bearer token for /v1/*. Secret: never log it. */
  appToken: string;
  /** `faux` serves contracts/ fixtures; anything else is a model provider (W7). */
  model: string;
  faux: FauxConfig;
  /** Requests per minute, per install id and per client IP. */
  rateLimitPerMinute: number;
  /** Max request body in bytes. */
  bodyLimitBytes: number;
  /** Seconds between `: ping` comments on SSE streams. */
  ssePingSeconds: number;
  /** One access-log line per request. */
  logRequests: boolean;
  /** The raw merged environment, for W7 skills (provider keys etc.). Secret: never log it. */
  env: Readonly<Record<string, string | undefined>>;
}

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConfigError';
  }
}

export const DEFAULT_ENV_FILE = fileURLToPath(new URL('../.env', import.meta.url));

/** Reads an env file if it exists. Values are returned, never printed. */
export function readEnvFile(path: string): Record<string, string> {
  if (!existsSync(path)) return {};
  return parseEnv(readFileSync(path, 'utf8')) as Record<string, string>;
}

function intFrom(env: Record<string, string | undefined>, name: string, fallback: number, min: number, max: number): number {
  const raw = env[name]?.trim();
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new ConfigError(`${name} must be an integer from ${min} to ${max}.`);
  }
  return value;
}

function numberFrom(env: Record<string, string | undefined>, name: string, fallback: number, min: number, max: number): number {
  const raw = env[name]?.trim();
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < min || value > max) {
    throw new ConfigError(`${name} must be a number from ${min} to ${max}.`);
  }
  return value;
}

/** Builds the config from an environment map. Throws ConfigError with a clear message. */
export function configFromEnv(env: Record<string, string | undefined>): Config {
  const appToken = env.APP_TOKEN?.trim() ?? '';
  if (!appToken) {
    throw new ConfigError('APP_TOKEN is missing. Set it in server/.env (copy server/.env.example; e.g. `openssl rand -hex 32`).');
  }
  return {
    port: intFrom(env, 'PORT', DEFAULT_PORT, 0, 65535),
    appToken,
    model: env.MODEL?.trim() || 'gmi',
    faux: {
      pace: numberFrom(env, 'FAUX_PACE', 1, 0, 10),
      latencyMs: intFrom(env, 'FAUX_LATENCY_MS', 0, 0, 30_000),
    },
    rateLimitPerMinute: intFrom(env, 'RATE_LIMIT_PER_MINUTE', 60, 1, 100_000),
    bodyLimitBytes: 64 * 1024,
    ssePingSeconds: numberFrom(env, 'SSE_PING_SECONDS', 15, 0.01, 3600),
    logRequests: env.LOG_REQUESTS !== '0',
    env: Object.freeze({ ...env }),
  };
}

/** server/.env merged under process.env (process.env wins). */
export function loadConfig(envFile = process.env.RYOKO_ENV_FILE || DEFAULT_ENV_FILE): Config {
  return configFromEnv({ ...readEnvFile(envFile), ...process.env });
}

/** A one-line summary with no secret values. */
export function describeConfig(config: Config): string {
  const pace = config.model === 'faux' ? `, pace ${config.faux.pace}` : '';
  return `MODEL=${config.model}${pace}, rate limit ${config.rateLimitPerMinute}/min, body limit ${config.bodyLimitBytes / 1024} KB, APP_TOKEN set`;
}
