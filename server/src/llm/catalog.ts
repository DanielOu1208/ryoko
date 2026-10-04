// The models Mimo's picker offers (design §4.9, §6.3): GMI Cloud's
// OpenAI-compatible models and Gemini through pi-ai's built-in google provider.
// The app sends its pick with each message (`model`, `effort`). The server runs
// only the models listed here plus the configured default, so a client can't
// ask for an arbitrary, costly model. A model is offered only when its
// provider's key is set; its thinking levels come from its pi-ai definition.

import { getSupportedThinkingLevels } from '@earendil-works/pi-ai/models';
import { MIMO_EFFORTS, type MimoEffort, type MimoMessageRequest, type MimoModel, type MimoModelsResponse } from '@ryoko/contracts';
import type { ModelProvider, ModelSpec } from '../config.ts';
import { ApiError } from '../errors.ts';
import type { Llm } from './registry.ts';

export interface CatalogModel {
  provider: ModelProvider;
  modelId: string;
  /** What the picker shows. */
  name: string;
  /** The level a pick starts at. The configured default model starts at its configured level instead. */
  defaultEffort: MimoEffort;
}

/**
 * GMI models were probed on 2026-10-04 for tool calls and each reasoning_effort
 * (GLM-5.3 put a tool tag in its text and Grok 4.6 took 20–28 s, so they're
 * left out). Gemini can't turn thinking off, so its lowest level is the default.
 */
export const MIMO_CATALOG: readonly CatalogModel[] = [
  { provider: 'gmi', modelId: 'deepseek-ai/DeepSeek-V4.1-Flash', name: 'DeepSeek V4.1 Flash', defaultEffort: 'off' },
  { provider: 'gmi', modelId: 'Qwen/Qwen3.8-Flash', name: 'Qwen3.8 Flash', defaultEffort: 'off' },
  { provider: 'gmi', modelId: 'openai/gpt-6.1-sol', name: 'GPT-6.1 Sol', defaultEffort: 'low' },
  { provider: 'gmi', modelId: 'openai/gpt-6-luna', name: 'GPT-6 Luna', defaultEffort: 'off' },
  { provider: 'gmi', modelId: 'moonshotai/kimi-k3', name: 'Kimi K3', defaultEffort: 'off' },
  { provider: 'google', modelId: 'gemini-3.8-flash', name: 'Gemini 3.8 Flash', defaultEffort: 'low' },
  { provider: 'google', modelId: 'gemini-3.5-flash-lite', name: 'Gemini 3.5 Flash-Lite', defaultEffort: 'minimal' },
];

export const PROVIDER_NAMES: Record<ModelProvider, string> = {
  gmi: 'GMI Cloud',
  google: 'Google Gemini',
};

/** The id the app sends back: `gmi:openai/gpt-6.1-sol`. */
export function catalogId(model: { provider: ModelProvider; modelId: string }): string {
  return `${model.provider}:${model.modelId}`;
}

const effortRank = (effort: MimoEffort) => MIMO_EFFORTS.indexOf(effort);

/** The level in `efforts` nearest to `effort`, the next one up on a tie (as pi-ai clamps). */
export function nearestEffort(effort: MimoEffort, efforts: readonly MimoEffort[]): MimoEffort {
  const rank = effortRank(effort);
  let best = efforts[0] ?? effort;
  for (const candidate of efforts) {
    const distance = Math.abs(effortRank(candidate) - rank);
    const bestDistance = Math.abs(effortRank(best) - rank);
    if (distance < bestDistance || (distance === bestDistance && effortRank(candidate) > effortRank(best))) best = candidate;
  }
  return best;
}

/**
 * What the picker offers: the configured default first, then the catalog's
 * models whose provider has a key. The default is always listed, even when
 * pi-ai doesn't know it (then with only its configured level).
 */
export async function mimoModels(llm: Llm, defaultSpec: ModelSpec): Promise<MimoModelsResponse> {
  const defaultId = catalogId(defaultSpec);
  const listed = MIMO_CATALOG.find((m) => catalogId(m) === defaultId);
  const entries: CatalogModel[] = [
    listed ?? { provider: defaultSpec.provider, modelId: defaultSpec.modelId, name: defaultSpec.modelId.split('/').pop() ?? defaultSpec.modelId, defaultEffort: defaultSpec.reasoning },
    ...MIMO_CATALOG.filter((m) => catalogId(m) !== defaultId),
  ];
  const models: MimoModel[] = [];
  for (const entry of entries) {
    const id = catalogId(entry);
    const isDefault = id === defaultId;
    if (!isDefault && !llm.hasProvider(entry.provider)) continue;
    const definition = await llm.lookup(entry.provider, entry.modelId);
    if (!definition && !isDefault) continue;
    const defaultEffort = isDefault ? defaultSpec.reasoning : entry.defaultEffort;
    const supported = definition ? getSupportedThinkingLevels(definition).filter((level): level is MimoEffort => (MIMO_EFFORTS as readonly string[]).includes(level)) : [];
    const efforts = MIMO_EFFORTS.filter((effort) => supported.includes(effort) || effort === defaultEffort);
    models.push({ id, name: entry.name, provider: entry.provider, providerName: PROVIDER_NAMES[entry.provider], efforts, defaultEffort });
  }
  return { defaultModel: defaultId, models };
}

/**
 * The model and level for one message. No `model` and no `effort` is the
 * configured default. A model the picker doesn't offer is refused (400); a
 * level the model doesn't take moves to the nearest one it does.
 */
export async function mimoSpec(request: Pick<MimoMessageRequest, 'model' | 'effort'>, llm: Llm, defaultSpec: ModelSpec): Promise<ModelSpec> {
  if (!request.model && !request.effort) return defaultSpec;
  const { defaultModel, models } = await mimoModels(llm, defaultSpec);
  const id = request.model ?? defaultModel;
  const offered = models.find((m) => m.id === id);
  if (!offered) {
    throw new ApiError('invalid_request', "That model isn't available on this server now. Pick another one.", { status: 400 });
  }
  const effort = request.effort ? nearestEffort(request.effort, offered.efforts) : offered.defaultEffort;
  return { provider: offered.provider, modelId: id.slice(offered.provider.length + 1), reasoning: effort };
}
