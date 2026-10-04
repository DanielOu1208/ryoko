// Mimo's model picker (design §4.9, §6.3): the catalog GET /v1/mimo-models
// lists, how a message's pick becomes a model, and a chat changing model.

import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createModels } from '@earendil-works/pi-ai/models';
import { fauxAssistantMessage, fauxProvider, type Model, type SimpleStreamOptions, type TranscriptContext } from '@earendil-works/pi-ai';
import { Value } from 'typebox/value';
import { MimoModelsResponse, SseEvent, type MimoMessageRequest, type Situation } from '@ryoko/contracts';
import { createApp } from '../src/app.ts';
import { ResponseCache } from '../src/cache.ts';
import { configFromEnv, type Config } from '../src/config.ts';
import { ApiError } from '../src/errors.ts';
import { EXAMPLES_DIR } from '../src/fixtures.ts';
import { Budget } from '../src/llm/budget.ts';
import { MIMO_CATALOG, mimoModels, mimoSpec, nearestEffort } from '../src/llm/catalog.ts';
import { createLlm, staticLlm } from '../src/llm/registry.ts';
import { MimoSessions, type MimoRunStats } from '../src/skills/mimo/session.ts';
import { createModelSkills } from '../src/skills/model.ts';
import type { SseSink } from '../src/sse.ts';

const TOKEN = 'test-token-mimo-models';
const example = <T>(file: string): T => JSON.parse(readFileSync(join(EXAMPLES_DIR, file), 'utf8')) as T;
const shanghai = example<Situation>('situation.shanghai-cafe.json');
const mimoRequest: MimoMessageRequest = { ...example<MimoMessageRequest>('mimo-message.request.json'), situation: shanghai, nearby: [] };

/** GMI as the default with fake keys: nothing here calls a provider. */
function gmiConfig(env: Record<string, string> = {}): Config {
  return configFromEnv({ APP_TOKEN: TOKEN, MODEL: 'gmi', GMI_API_KEY: 'test-gmi-key', MODEL_MIMO_REASONING: 'high', LOG_REQUESTS: '0', CACHE_DIR: 'off', ...env });
}

async function rejectsWith(promise: Promise<unknown>, code: string, status: number): Promise<void> {
  await assert.rejects(promise, (err: unknown) => {
    assert.ok(err instanceof ApiError, `expected an ApiError, got ${err}`);
    assert.equal(err.code, code);
    assert.equal(err.status, status);
    return true;
  });
}

describe('the Mimo model catalog', () => {
  test('lists the configured default first, then the GMI models, each with the levels it takes', async () => {
    const config = gmiConfig();
    const listing = await mimoModels(createLlm(config), config.models!.mimo);
    assert.ok(Value.Check(MimoModelsResponse, listing));
    assert.equal(listing.defaultModel, 'gmi:deepseek-ai/DeepSeek-V4.1-Flash');
    assert.deepEqual(
      listing.models.map((m) => [m.id, m.efforts.join(' '), m.defaultEffort]),
      [
        // The default starts at its configured level (MODEL_MIMO_REASONING).
        ['gmi:deepseek-ai/DeepSeek-V4.1-Flash', 'off minimal low medium high', 'high'],
        ['gmi:Qwen/Qwen3.8-Flash', 'off minimal low medium high', 'off'],
        ['gmi:openai/gpt-6.1-sol', 'low medium high', 'low'],
        ['gmi:openai/gpt-6-luna', 'off low medium high', 'off'],
        ['gmi:moonshotai/kimi-k3', 'off minimal low medium high', 'off'],
      ],
    );
    assert.ok(listing.models.every((m) => m.providerName === 'GMI Cloud'));
  });

  test('offers Gemini Flash and Flash-Lite once GEMINI_API_KEY is set; neither turns thinking off', async () => {
    const config = gmiConfig({ GEMINI_API_KEY: 'test-gemini-key' });
    const listing = await mimoModels(createLlm(config), config.models!.mimo);
    const google = listing.models.filter((m) => m.provider === 'google');
    assert.deepEqual(
      google.map((m) => [m.id, m.name, m.efforts.join(' '), m.defaultEffort, m.providerName]),
      [
        ['google:gemini-3.8-flash', 'Gemini 3.8 Flash', 'low medium high', 'low', 'Google Gemini'],
        ['google:gemini-3.5-flash-lite', 'Gemini 3.5 Flash-Lite', 'minimal low medium high', 'minimal', 'Google Gemini'],
      ],
    );
  });

  test('a default outside the catalog is still listed, by the last part of its id', async () => {
    const config = gmiConfig({ GMI_MODEL: 'zai-org/GLM-5.3', MODEL_MIMO_REASONING: 'off' });
    const listing = await mimoModels(createLlm(config), config.models!.mimo);
    assert.equal(listing.defaultModel, 'gmi:zai-org/GLM-5.3');
    assert.deepEqual(listing.models[0], {
      id: 'gmi:zai-org/GLM-5.3',
      name: 'GLM-5.3',
      provider: 'gmi',
      providerName: 'GMI Cloud',
      efforts: ['off', 'minimal', 'low', 'medium', 'high'],
      defaultEffort: 'off',
    });
    assert.ok(listing.models.some((m) => m.id === 'gmi:deepseek-ai/DeepSeek-V4.1-Flash'));
  });

  test('every GMI model in the catalog has a known price, so the budget counts it', async () => {
    const llm = createLlm(gmiConfig());
    for (const entry of MIMO_CATALOG.filter((m) => m.provider === 'gmi')) {
      const model = await llm.lookup('gmi', entry.modelId);
      assert.ok(model, entry.modelId);
      assert.notEqual(model.cost.input, 1, `${entry.modelId} has the unknown-model guess`);
    }
  });
});

describe("a message's model pick", () => {
  const config = gmiConfig();
  const llm = createLlm(config);
  const fallback = config.models!.mimo;

  test('no model and no level is the configured default', async () => {
    assert.deepEqual(await mimoSpec({}, llm, fallback), fallback);
  });

  test('a listed model runs at the level asked for, or its own default', async () => {
    assert.deepEqual(await mimoSpec({ model: 'gmi:openai/gpt-6.1-sol', effort: 'high' }, llm, fallback), { provider: 'gmi', modelId: 'openai/gpt-6.1-sol', reasoning: 'high' });
    assert.deepEqual(await mimoSpec({ model: 'gmi:Qwen/Qwen3.8-Flash' }, llm, fallback), { provider: 'gmi', modelId: 'Qwen/Qwen3.8-Flash', reasoning: 'off' });
  });

  test('a level alone changes the default model’s level', async () => {
    assert.deepEqual(await mimoSpec({ effort: 'low' }, llm, fallback), { ...fallback, reasoning: 'low' });
  });

  test('a level the model doesn’t take moves to the nearest one it does', async () => {
    assert.deepEqual(await mimoSpec({ model: 'gmi:openai/gpt-6.1-sol', effort: 'off' }, llm, fallback), { provider: 'gmi', modelId: 'openai/gpt-6.1-sol', reasoning: 'low' });
    assert.equal(nearestEffort('minimal', ['off', 'low', 'medium', 'high']), 'low');
    assert.equal(nearestEffort('high', ['minimal', 'low']), 'low');
  });

  test('a model the picker doesn’t offer is refused, Gemini included while it has no key', async () => {
    await rejectsWith(mimoSpec({ model: 'gmi:x-ai/grok-9' }, llm, fallback), 'invalid_request', 400);
    await rejectsWith(mimoSpec({ model: 'google:gemini-3.8-flash' }, llm, fallback), 'invalid_request', 400);
  });
});

describe('GET /v1/mimo-models', () => {
  const call = (app: ReturnType<typeof createApp>['app'], token: string | null = TOKEN) =>
    app.request('/v1/mimo-models', { headers: token ? { Authorization: `Bearer ${token}` } : {} });

  test('fixtures answer with the example list; the token is required', async () => {
    const { app } = createApp(configFromEnv({ APP_TOKEN: TOKEN, MODEL: 'faux', FAUX_PACE: '0', LOG_REQUESTS: '0', CACHE_DIR: 'off' }));
    const res = await call(app);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), example('mimo-models.response.json'));
    assert.equal((await call(app, null)).status, 401);
  });

  test('the model skills answer with the catalog, and refuse a message on a model they don’t offer', async () => {
    const config = gmiConfig();
    const skills = createModelSkills(config, { budget: new Budget({ limitUsd: 5, file: null }), cache: new ResponseCache({ file: null }), search: null, log: () => {} });
    const { app } = createApp(config, { skills });
    const res = await call(app);
    assert.equal(res.status, 200);
    const listing = (await res.json()) as MimoModelsResponse;
    assert.equal(listing.models.length, 5);

    const sent = await app.request('/v1/sessions/s-pick/messages', {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...mimoRequest, model: 'gmi:x-ai/grok-9' }),
    });
    assert.equal(sent.status, 400);
    assert.equal(((await sent.json()) as { error: { code: string } }).error.code, 'invalid_request');
  });
});

describe('a chat that changes model', () => {
  test('runs the next message on the new model, with the history so far', async () => {
    const faux = fauxProvider({ provider: 'gmi', models: [{ id: 'faux-a' }, { id: 'faux-b' }], tokenSize: { min: 1, max: 2 } });
    const models = createModels();
    models.setProvider(faux.provider);
    const llm = staticLlm(models, () => faux.getModel('faux-a') as Model<string>);
    const asked: { model: string; reasoning: SimpleStreamOptions['reasoning']; context: TranscriptContext }[] = [];
    const reply = (text: string) => (context: TranscriptContext, options: SimpleStreamOptions | undefined, _state: unknown, model: Model<string>) => {
      asked.push({ model: model.id, reasoning: options?.reasoning, context: structuredClone(context) });
      return fauxAssistantMessage(text);
    };
    faux.setResponses([reply('Try the corner café.'), reply('It opens at eight.')]);

    const stats: MimoRunStats[] = [];
    const sessions = new MimoSessions({
      llm,
      budget: new Budget({ limitUsd: 5, file: null }),
      search: null,
      timeoutMs: 5000,
      pickModel: (request) => llm.forSpec({ provider: 'gmi', modelId: request.model ?? 'faux-a', reasoning: request.effort ?? 'off' }),
      onRunStats: (s) => stats.push(s),
    });
    const sink = (): SseSink => {
      const abort = new AbortController();
      return {
        send: (event) => {
          assert.ok(Value.Check(SseEvent, event));
          return true;
        },
        comment: () => true,
        signal: abort.signal,
        closed: false,
      };
    };
    const ctx = (runId: string) => ({ installId: null, clientVersion: null, signal: new AbortController().signal, sessionId: 's-switch', runId });

    await (await sessions.prepare({ ...mimoRequest, message: 'Where for coffee?' }, ctx('run_1')))(sink());
    await (await sessions.prepare({ ...mimoRequest, message: 'When does it open?', model: 'faux-b', effort: 'low' }, ctx('run_2')))(sink());

    assert.deepEqual(asked.map((a) => [a.model, a.reasoning]), [['faux-a', undefined], ['faux-b', 'low']]);
    const second = JSON.stringify(asked[1]?.context.messages);
    assert.match(second, /Where for coffee\?/);
    assert.match(second, /Try the corner café\./);
    assert.deepEqual(stats.map((s) => s.model), ['gmi:faux-a', 'gmi:faux-b@low']);
    assert.equal(sessions.size, 1);
  });
});
