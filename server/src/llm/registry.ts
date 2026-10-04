// The model registry behind the skills (design §6.3): one pi-ai `Models` collection
// with the providers the config names, plus each skill's model and request options.
//
// GMI Cloud has no built-in pi-ai provider, so it's registered here as an
// OpenAI-compatible one (the D3 spike's shape): reasoning on in the model
// definition with `thinkingLevelMap.off = 'none'`, then requested with thinking
// off, so pi sends `reasoning_effort: "none"`.
//
// Keys are read from the server config (server/.env merged with the process
// environment), never from process.env alone, and never logged.

import { createModels, createProvider, type MutableModels } from '@earendil-works/pi-ai/models';
import { openAICompletionsApi } from '@earendil-works/pi-ai/api/openai-completions.lazy';
import { envApiKeyAuth, type Api, type Model, type SimpleStreamOptions, type ThinkingLevel, type Usage } from '@earendil-works/pi-ai';
import { describeModel, type Config, type ModelProvider, type ModelSpec, type SkillName } from '../config.ts';
import { ApiError } from '../errors.ts';

export const GMI_BASE_URL = 'https://api.gmi-serving.com/v1';

/**
 * Per-million-token prices, from GMI's model list (spike D3; the rest from
 * /v1/models on 2026-10-04, below the long-prompt tier). Unknown models get a
 * deliberately high guess so the budget errs safe.
 */
const GMI_PRICES: Record<string, Model<'openai-completions'>['cost']> = {
  'deepseek-ai/DeepSeek-V4.1-Flash': { input: 0.3, output: 1.2, cacheRead: 0.006, cacheWrite: 0 },
  'Qwen/Qwen3.8-Flash': { input: 0.16, output: 0.47, cacheRead: 0.016, cacheWrite: 0.2 },
  'openai/gpt-6.1-sol': { input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5 },
  'openai/gpt-6-luna': { input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125 },
};
/** The GMI models with known prices: the dashboard suggests these. */
export const GMI_MODEL_IDS = Object.keys(GMI_PRICES);
const UNKNOWN_PRICE = { input: 1, output: 4, cacheRead: 0, cacheWrite: 0 };

/**
 * The `reasoning_effort` values each GMI model takes, as pi-ai thinking maps
 * (null: refused with a 400 in the 2026-10-04 probe). Thinking off is sent as
 * "none"; the rest pass through. GPT-6.1 Sol takes only low, medium and high.
 */
const GMI_THINKING: Record<string, Model<'openai-completions'>['thinkingLevelMap']> = {
  'openai/gpt-6.1-sol': { off: null, minimal: null },
  'openai/gpt-6-luna': { off: 'none', minimal: null },
};
const DEFAULT_GMI_THINKING = { off: 'none' } as const;

/** The env var holding each provider's key. */
export const PROVIDER_KEY_ENV: Record<ModelProvider, string> = {
  gmi: 'GMI_API_KEY',
  google: 'GEMINI_API_KEY',
};

export function gmiModel(id: string, baseUrl = GMI_BASE_URL): Model<'openai-completions'> {
  return {
    id,
    name: id.split('/').pop() ?? id,
    api: 'openai-completions',
    provider: 'gmi',
    baseUrl,
    reasoning: true,
    // Thinking off is sent as reasoning_effort "none" (DeepSeek V4.1 Flash and Qwen3.8 Flash accept it).
    thinkingLevelMap: GMI_THINKING[id] ?? DEFAULT_GMI_THINKING,
    input: ['text'],
    cost: GMI_PRICES[id] ?? UNKNOWN_PRICE,
    contextWindow: 1_048_575,
    maxTokens: 8192,
    compat: {
      supportsDeveloperRole: false, // the system prompt goes as `system`
      supportsStore: false,
      maxTokensField: 'max_tokens',
    },
  };
}

/**
 * Extra output tokens when thinking is on: the model's reasoning counts
 * against max_tokens, so without room for it a reply is cut short (stopReason
 * `length`). DeepSeek V4.1 Flash on GMI used about 300–1,000 reasoning tokens
 * at any level in the reasoning-level probe.
 */
export const REASONING_HEADROOM_TOKENS = 4096;

/** A skill's output budget plus room for thinking when its reasoning is on. */
export function outputBudget(maxTokens: number, options: SimpleStreamOptions): number {
  return options.reasoning ? maxTokens + REASONING_HEADROOM_TOKENS : maxTokens;
}

/** What a skill needs to call its model. */
export interface SkillModel {
  model: Model<Api>;
  /** Stable id for cache keys and logs, with the thinking level when it's on, e.g. `gmi:deepseek-ai/DeepSeek-V4.1-Flash@low`. */
  key: string;
  /** Options for every request: reasoning, low retry delays. Add maxTokens and signal per call. */
  options: SimpleStreamOptions;
}

export interface Llm {
  readonly models: MutableModels;
  /** The model for a skill. Throws ApiError model_error (503) when its provider isn't configured. */
  forSkill(skill: SkillName): Promise<SkillModel>;
  /** Any model the server knows, e.g. one picked in the app (Mimo's model picker). Throws like forSkill. */
  forSpec(spec: ModelSpec): Promise<SkillModel>;
  /** Whether a provider's key is set. */
  hasProvider(provider: ModelProvider): boolean;
  /** The pi-ai definition of a model, registering its provider first; undefined if unknown. */
  lookup(provider: ModelProvider, modelId: string): Promise<Model<Api> | undefined>;
}

/** Request options shared by every call: rate limits surface as errors fast instead of hanging (design §6.4). */
export const BASE_REQUEST_OPTIONS: SimpleStreamOptions = {
  maxRetries: 1,
  maxRetryDelayMs: 1500,
};

/**
 * A provider's error text, safe to send to the app: the innermost message of a
 * JSON error body, long token-like runs (keys, request ids) masked, kept short.
 */
export function providerErrorText(message: string | undefined): string {
  const text = innermostMessage(message ?? 'unknown error').replace(/\s+/g, ' ').replace(/[A-Za-z0-9_\-]{24,}/g, '…').trim();
  return text.length <= 160 ? text : `${text.slice(0, 159)}…`;
}

/**
 * Gemini's errors arrive as JSON inside JSON (`{"error":{"message":"{\n \"error\":
 * {\"code\": 503, \"message\": \"This model is currently experiencing high
 * demand…\"}}"}}`): unwrap `error.message` while it parses.
 */
function innermostMessage(text: string): string {
  for (let depth = 0; depth < 3; depth++) {
    try {
      const inner = (JSON.parse(text) as { error?: { message?: unknown } } | null)?.error?.message;
      if (typeof inner !== 'string' || !inner.trim()) break;
      text = inner;
    } catch {
      break;
    }
  }
  return text;
}

/** Cost in US dollars of one response. Uses the provider's figure, else the model's prices (the faux test provider reports 0). */
export function costOf(model: Pick<Model<Api>, 'cost'>, usage: Usage | undefined): number {
  if (!usage) return 0;
  if (usage.cost?.total > 0) return usage.cost.total;
  const rates = model.cost;
  return (rates.input * usage.input + rates.output * usage.output + rates.cacheRead * usage.cacheRead + rates.cacheWrite * usage.cacheWrite) / 1_000_000;
}

function unavailable(provider: ModelProvider): ApiError {
  return new ApiError('model_error', `The ${provider} model isn't configured: set ${PROVIDER_KEY_ENV[provider]} in server/.env, or run with MODEL=faux for fixtures.`, {
    status: 503,
    retryable: false,
  });
}

/**
 * Registers the providers the config uses. Google (tier 2) is imported lazily, only
 * when a skill names it, so its SDK isn't loaded otherwise.
 */
export function createLlm(config: Config): Llm {
  const specs = config.models;
  if (!specs) throw new Error('createLlm needs model specs (MODEL is faux).');
  const env = config.env;
  const models = createModels({
    authContext: {
      env: async (name: string) => env[name]?.trim() || undefined,
      fileExists: async () => false,
    },
  });

  const gmiIds = [...new Set([...Object.keys(GMI_PRICES), ...Object.values(specs).filter((s) => s.provider === 'gmi').map((s) => s.modelId)])];
  const baseUrl = env.GMI_BASE_URL?.trim() || GMI_BASE_URL;
  models.setProvider(
    createProvider({
      id: 'gmi',
      name: 'GMI Cloud',
      baseUrl,
      auth: { apiKey: envApiKeyAuth('GMI Cloud API key', [PROVIDER_KEY_ENV.gmi]) },
      models: gmiIds.map((id) => gmiModel(id, baseUrl)),
      api: openAICompletionsApi(),
    }),
  );

  let googleReady: Promise<void> | null = null;
  const ensureProvider = async (provider: ModelProvider) => {
    if (provider !== 'google') return;
    googleReady ??= import('@earendil-works/pi-ai/providers/google').then(({ googleProvider }) => models.setProvider(googleProvider()));
    await googleReady;
  };

  const hasProvider = (provider: ModelProvider) => Boolean(env[PROVIDER_KEY_ENV[provider]]?.trim());

  async function build(spec: ModelSpec, unknownHint: string): Promise<SkillModel> {
    if (!hasProvider(spec.provider)) throw unavailable(spec.provider);
    await ensureProvider(spec.provider);
    const model = models.getModel(spec.provider, spec.modelId);
    if (!model) {
      throw new ApiError('model_error', `${describeModel(spec)} isn't a model the server knows. ${unknownHint}`, { status: 503, retryable: false });
    }
    return {
      model,
      // With the thinking level, so changing it regenerates cached results.
      key: describeModel(spec),
      options: { ...BASE_REQUEST_OPTIONS, ...(spec.reasoning === 'off' ? {} : { reasoning: spec.reasoning as ThinkingLevel }) },
    };
  }

  return {
    models,
    forSkill: (skill) => build(specs[skill], `Check ${skill}'s model setting in server/.env.`),
    forSpec: (spec) => build(spec, 'Pick another model.'),
    hasProvider,
    async lookup(provider, modelId) {
      await ensureProvider(provider);
      return models.getModel(provider, modelId);
    },
  };
}

/**
 * An Llm over a ready-made Models collection: tests use pi-ai's faux provider
 * through this. A spec names a model in `models` by provider and id; its
 * thinking level goes into the key and the options as it does for real.
 */
export function staticLlm(models: MutableModels, pick: (skill: SkillName) => Model<Api>): Llm {
  const skillModel = (model: Model<Api>, reasoning: ModelSpec['reasoning'] = 'off'): SkillModel => ({
    model,
    key: `${model.provider}:${model.id}${reasoning === 'off' ? '' : `@${reasoning}`}`,
    options: { ...BASE_REQUEST_OPTIONS, ...(reasoning === 'off' ? {} : { reasoning: reasoning as ThinkingLevel }) },
  });
  return {
    models,
    async forSkill(skill) {
      return skillModel(pick(skill));
    },
    async forSpec(spec) {
      const model = models.getModel(spec.provider, spec.modelId);
      if (!model) throw new ApiError('model_error', `${describeModel(spec)} isn't a model the server knows.`, { status: 503, retryable: false });
      return skillModel(model, spec.reasoning);
    },
    hasProvider: () => true,
    async lookup(provider, modelId) {
      return models.getModel(provider, modelId);
    },
  };
}
