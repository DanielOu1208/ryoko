// Server config from server/.env plus the process environment.
// The process environment wins, so `MODEL=faux node src/index.ts` overrides the file.
// Secret values are never logged: describeConfig() prints only what's safe.

import { existsSync, readFileSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
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

/** The model-backed skills, each with its own model (design §6.3). */
export const SKILL_NAMES = ['placeCard', 'discover', 'allergyCard', 'mimo', 'translate'] as const;
export type SkillName = (typeof SKILL_NAMES)[number];

/** The env var that overrides one skill's model, as `provider:modelId` (or just `provider`). */
export const SKILL_MODEL_ENV: Record<SkillName, string> = {
  placeCard: 'MODEL_PLACE_CARD',
  discover: 'MODEL_DISCOVER',
  allergyCard: 'MODEL_ALLERGY_CARD',
  mimo: 'MODEL_MIMO',
  translate: 'MODEL_TRANSLATE',
};

/** Providers the server can register. `gmi` is a custom OpenAI-compatible provider; `google` is pi-ai's built-in (tier 2). */
export const MODEL_PROVIDERS = ['gmi', 'google'] as const;
export type ModelProvider = (typeof MODEL_PROVIDERS)[number];

export const THINKING_LEVELS = ['off', 'minimal', 'low', 'medium', 'high'] as const;
export type ThinkingSetting = (typeof THINKING_LEVELS)[number];

/** Default model per provider, used when the setting names only the provider. */
export const PROVIDER_DEFAULTS: Record<ModelProvider, { modelEnv: string; modelId: string; reasoning: ThinkingSetting }> = {
  // DeepSeek V4.1 Flash with thinking off (D3 spike).
  gmi: { modelEnv: 'GMI_MODEL', modelId: 'deepseek-ai/DeepSeek-V4.1-Flash', reasoning: 'off' },
  // Gemini 3.8 Flash can't turn thinking off; low is its cheapest level (design §6.3).
  google: { modelEnv: 'GEMINI_MODEL', modelId: 'gemini-3.8-flash', reasoning: 'low' },
};

/** One skill's model: `{provider, modelId, reasoning}` (design §6.3). The base URL comes from the provider's env (GMI_BASE_URL). */
export interface ModelSpec {
  provider: ModelProvider;
  modelId: string;
  reasoning: ThinkingSetting;
}

export interface Config {
  port: number;
  /** Bearer token for /v1/*. Secret: never log it. */
  appToken: string;
  /** `faux` serves contracts/ fixtures; anything else is the default model, `provider[:modelId]` (W7). */
  model: string;
  /** The model per skill, or null when `model` is `faux`. */
  models: Record<SkillName, ModelSpec> | null;
  faux: FauxConfig;
  /** Requests per minute, per install id and per client IP. */
  rateLimitPerMinute: number;
  /** Max request body in bytes. */
  bodyLimitBytes: number;
  /** Seconds between `: ping` comments on SSE streams. */
  ssePingSeconds: number;
  /** One access-log line per request. */
  logRequests: boolean;
  /** Where the response cache and the budget ledger persist (gitignored server/.cache). null keeps them in memory only (`CACHE_DIR=off`). */
  cacheDir: string | null;
  /** Daily model spend in US dollars before every model call answers 503 budget_exceeded. */
  dailyBudgetUsd: number;
  /** Time limits for model work, in milliseconds. */
  timeouts: { skillMs: number; mimoMs: number; translateMs: number };
  /** Short-lived Soniox keys for the app (POST /v1/soniox-key, design §6.4). The key itself stays in `env`. */
  soniox: SonioxKeyConfig;
  /** The raw merged environment, for W7 skills (provider keys etc.). Secret: never log it. */
  env: Readonly<Record<string, string | undefined>>;
}

export interface SonioxKeyConfig {
  /** Whether SONIOX_API_KEY is set. The value is never copied out of `env`. */
  configured: boolean;
  /** Keys one install (and one IP) may mint per minute: one per listening session. */
  perMinute: number;
  /** How long a minted key can be used to open a session. */
  expiresInSeconds: number;
  /** The longest session a minted key allows; Soniox drops the connection after it. */
  maxSessionSeconds: number;
}

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConfigError';
  }
}

export const DEFAULT_ENV_FILE = fileURLToPath(new URL('../.env', import.meta.url));
export const DEFAULT_CACHE_DIR = fileURLToPath(new URL('../.cache', import.meta.url));

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

/** Parses `provider`, or `provider:modelId`. The model id may itself contain slashes. */
export function parseModelSetting(raw: string, name: string, env: Record<string, string | undefined>): Omit<ModelSpec, 'reasoning'> {
  const text = raw.trim();
  const colon = text.indexOf(':');
  const provider = (colon === -1 ? text : text.slice(0, colon)).trim().toLowerCase();
  if (!(MODEL_PROVIDERS as readonly string[]).includes(provider)) {
    throw new ConfigError(`${name}=${text} names an unknown provider. Use one of: faux (MODEL only), ${MODEL_PROVIDERS.join(', ')}; optionally followed by :modelId.`);
  }
  const defaults = PROVIDER_DEFAULTS[provider as ModelProvider];
  const modelId = (colon === -1 ? '' : text.slice(colon + 1).trim()) || env[defaults.modelEnv]?.trim() || defaults.modelId;
  return { provider: provider as ModelProvider, modelId };
}

function reasoningFrom(env: Record<string, string | undefined>, name: string, fallback: ThinkingSetting): ThinkingSetting {
  const raw = env[name]?.trim().toLowerCase();
  if (!raw) return fallback;
  if (!(THINKING_LEVELS as readonly string[]).includes(raw)) {
    throw new ConfigError(`${name} must be one of ${THINKING_LEVELS.join(', ')}.`);
  }
  return raw as ThinkingSetting;
}

/**
 * The model per skill: `MODEL_<SKILL>` if set, else MODEL. Reasoning comes from
 * `MODEL_<SKILL>_REASONING`, else the provider's default (off for GMI).
 */
export function modelsFromEnv(model: string, env: Record<string, string | undefined>): Record<SkillName, ModelSpec> | null {
  if (model === 'faux') return null;
  const fallback = parseModelSetting(model, 'MODEL', env);
  const specs = {} as Record<SkillName, ModelSpec>;
  for (const skill of SKILL_NAMES) {
    const name = SKILL_MODEL_ENV[skill];
    const raw = env[name]?.trim();
    const base = raw ? parseModelSetting(raw, name, env) : fallback;
    specs[skill] = { ...base, reasoning: reasoningFrom(env, `${name}_REASONING`, PROVIDER_DEFAULTS[base.provider].reasoning) };
  }
  return specs;
}

function cacheDirFrom(env: Record<string, string | undefined>): string | null {
  const raw = env.CACHE_DIR?.trim();
  if (!raw) return DEFAULT_CACHE_DIR;
  if (raw === 'off') return null;
  return isAbsolute(raw) ? raw : resolve(raw);
}

/** Builds the config from an environment map. Throws ConfigError with a clear message. */
export function configFromEnv(env: Record<string, string | undefined>): Config {
  const appToken = env.APP_TOKEN?.trim() ?? '';
  if (!appToken) {
    throw new ConfigError('APP_TOKEN is missing. Set it in server/.env (copy server/.env.example; e.g. `openssl rand -hex 32`).');
  }
  const model = env.MODEL?.trim() || 'gmi';
  return {
    port: intFrom(env, 'PORT', DEFAULT_PORT, 0, 65535),
    appToken,
    model,
    models: modelsFromEnv(model, env),
    faux: {
      pace: numberFrom(env, 'FAUX_PACE', 1, 0, 10),
      latencyMs: intFrom(env, 'FAUX_LATENCY_MS', 0, 0, 30_000),
    },
    rateLimitPerMinute: intFrom(env, 'RATE_LIMIT_PER_MINUTE', 60, 1, 100_000),
    bodyLimitBytes: 64 * 1024,
    ssePingSeconds: numberFrom(env, 'SSE_PING_SECONDS', 15, 0.01, 3600),
    logRequests: env.LOG_REQUESTS !== '0',
    cacheDir: cacheDirFrom(env),
    dailyBudgetUsd: numberFrom(env, 'DAILY_BUDGET_USD', 15, 0, 10_000),
    timeouts: {
      skillMs: intFrom(env, 'SKILL_TIMEOUT_MS', 25_000, 100, 120_000),
      mimoMs: intFrom(env, 'MIMO_TIMEOUT_MS', 28_000, 100, 120_000),
      translateMs: intFrom(env, 'TRANSLATE_TIMEOUT_MS', 12_000, 100, 120_000),
    },
    soniox: {
      configured: Boolean(env.SONIOX_API_KEY?.trim()),
      perMinute: intFrom(env, 'SONIOX_KEYS_PER_MINUTE', 10, 1, 1000),
      expiresInSeconds: intFrom(env, 'SONIOX_KEY_TTL_SECONDS', 60, 10, 3600),
      maxSessionSeconds: intFrom(env, 'SONIOX_MAX_SESSION_SECONDS', 3600, 60, 18_000),
    },
    env: Object.freeze({ ...env }),
  };
}

/** server/.env merged under process.env (process.env wins). */
export function loadConfig(envFile = process.env.RYOKO_ENV_FILE || DEFAULT_ENV_FILE): Config {
  return configFromEnv({ ...readEnvFile(envFile), ...process.env });
}

/** `gmi:deepseek-ai/DeepSeek-V4.1-Flash` (plus `@low` when reasoning is on). */
export function describeModel(spec: ModelSpec): string {
  return `${spec.provider}:${spec.modelId}${spec.reasoning === 'off' ? '' : `@${spec.reasoning}`}`;
}

/** A one-line summary with no secret values. */
export function describeConfig(config: Config): string {
  const pace = config.model === 'faux' ? `, pace ${config.faux.pace}` : '';
  let models = '';
  if (config.models) {
    const specs = Object.entries(config.models).map(([skill, spec]) => [skill, describeModel(spec)] as const);
    const distinct = new Set(specs.map(([, text]) => text));
    models = distinct.size === 1 ? ` (${specs[0]?.[1]})` : ` (${specs.map(([skill, text]) => `${skill}=${text}`).join(', ')})`;
    models += `, budget $${config.dailyBudgetUsd}/day, cache ${config.cacheDir ? 'on disk' : 'in memory'}`;
  }
  const soniox = config.soniox.configured ? `Soniox keys on (${config.soniox.perMinute}/min)` : 'Soniox keys off (no SONIOX_API_KEY)';
  return `MODEL=${config.model}${models}${pace}, rate limit ${config.rateLimitPerMinute}/min, body limit ${config.bodyLimitBytes / 1024} KB, ${soniox}, APP_TOKEN set`;
}
