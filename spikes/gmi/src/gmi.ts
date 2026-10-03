// GMI provider registration for pi-ai 1.0.1. Reusable shape for server/.
import { createModels, createProvider } from '@earendil-works/pi-ai/models';
import { openAICompletionsApi } from '@earendil-works/pi-ai/api/openai-completions.lazy';
import { envApiKeyAuth, type Model } from '@earendil-works/pi-ai';

export const GMI_BASE_URL = 'https://api.gmi-serving.com/v1';

// Per-model settings found by probing (see out/probe-thinking.jsonl):
// - all three candidates think by default and stream `reasoning_content`
// - DeepSeek V4.1 Flash and Qwen3.8 Flash accept `reasoning_effort: "none"` (no reasoning tokens)
// - GLM-5.3-Flash rejects `thinking:{type:"disabled"}` and `reasoning_effort:"none"`; lowest is "low"
function gmiModel(id: string, name: string, inPerM: number, outPerM: number, offValue: string | null): Model<'openai-completions'> {
  return {
    id,
    name,
    api: 'openai-completions',
    provider: 'gmi',
    baseUrl: GMI_BASE_URL,
    reasoning: true,
    // `off` -> sent as reasoning_effort when the caller asks for no reasoning.
    thinkingLevelMap: offValue ? { off: offValue } : { off: null },
    input: ['text'],
    cost: { input: inPerM, output: outPerM, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 1_048_575,
    maxTokens: 8192,
    compat: {
      supportsDeveloperRole: false, // send the system prompt as `system`
      supportsStore: false,
      maxTokensField: 'max_tokens',
    },
  };
}

export const GMI_MODELS = [
  gmiModel('deepseek-ai/DeepSeek-V4.1-Flash', 'DeepSeek V4.1 Flash', 0.3, 1.2, 'none'),
  gmiModel('Qwen/Qwen3.8-Flash', 'Qwen3.8 Flash', 0.16, 0.47, 'none'),
  gmiModel('zai-org/GLM-5.3-Flash', 'GLM-5.3 Flash', 0.15, 0.5, 'low'),
];

export function gmiModels() {
  const models = createModels();
  models.setProvider(
    createProvider({
      id: 'gmi',
      name: 'GMI Cloud',
      baseUrl: GMI_BASE_URL,
      auth: { apiKey: envApiKeyAuth('GMI Cloud API key', ['GMI_API_KEY']) },
      models: GMI_MODELS,
      api: openAICompletionsApi(),
    }),
  );
  return models;
}

export const SHORT = (id: string) => id.split('/')[1];
