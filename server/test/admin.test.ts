// The dashboard (/admin): local only, settings applied at runtime, Mimo transcripts. Run: pnpm --dir server test

import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createModels } from '@earendil-works/pi-ai/models';
import { fauxAssistantMessage, fauxProvider, fauxThinking, fauxToolCall } from '@earendil-works/pi-ai';
import type { MimoMessageRequest, PlaceCardRequest } from '@ryoko/contracts';
import { createApp } from '../src/app.ts';
import { ResponseCache } from '../src/cache.ts';
import { configFromEnv, type Config } from '../src/config.ts';
import { EXAMPLES_DIR } from '../src/fixtures.ts';
import { Budget } from '../src/llm/budget.ts';
import { staticLlm } from '../src/llm/registry.ts';
import { createModelSkills } from '../src/skills/model.ts';

const TOKEN = 'test-token-admin';
const example = <T>(file: string): T => JSON.parse(readFileSync(join(EXAMPLES_DIR, file), 'utf8')) as T;
const placeCard = example<PlaceCardRequest>('place-card.request.json');
const mimoRequest = example<MimoMessageRequest>('mimo-message.request.json');

function testConfig(env: Record<string, string> = {}): Config {
  return configFromEnv({ APP_TOKEN: TOKEN, MODEL: 'faux', FAUX_PACE: '0', LOG_REQUESTS: '0', CACHE_DIR: 'off', GMI_API_KEY: 'secret-gmi-key', ...env });
}

type App = ReturnType<typeof createApp>['app'];
const WRITE = { 'Content-Type': 'application/json', 'X-Ryoko-Admin': '1' };

const status = async (app: App) => (await app.request('/admin/api/status')).json();
const post = (app: App, path: string, body: unknown = {}, headers: Record<string, string> = WRITE) =>
  app.request(`/admin/api/${path}`, { method: 'POST', headers, body: JSON.stringify(body) });
const v1 = (app: App, path: string, body: unknown) =>
  app.request(path, { method: 'POST', headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

describe('dashboard', () => {
  test('serves the page and a status without any key values', async () => {
    const { app } = createApp(testConfig());
    const page = await app.request('/admin');
    assert.equal(page.status, 200);
    assert.match(await page.text(), /<title>Mimo activity<\/title>/);

    await v1(app, '/v1/place-card', placeCard);
    const res = await app.request('/admin/api/status');
    assert.equal(res.status, 200);
    const text = await res.text();
    assert.ok(!text.includes('secret-gmi-key') && !text.includes(TOKEN), 'no key or token values');
    const s = JSON.parse(text);
    assert.equal(s.model, 'faux');
    assert.equal(s.keys.GMI_API_KEY, true);
    assert.equal(s.keys.EXA_API_KEY, false);
    assert.equal(s.activity.length, 1);
    assert.equal(s.activity[0].kind, 'placeCard');
    assert.equal(s.activity[0].state, 'done');
    assert.equal(s.activity[0].model, 'fixtures');
    assert.match(s.activity[0].title, new RegExp(placeCard.situation.place?.name ?? placeCard.situation.city));
  });

  test('is local only: forwarded (Funnel) and non-loopback hosts get a 404', async () => {
    const { app } = createApp(testConfig());
    assert.equal((await app.request('/admin/api/status', { headers: { 'X-Forwarded-For': '203.0.113.9' } })).status, 404);
    assert.equal((await app.request('http://evil.example/admin/api/status')).status, 404);
    assert.equal((await app.request('http://127.0.0.1:8792/admin/api/status')).status, 200);
  });

  test('changes need the X-Ryoko-Admin header', async () => {
    const { app } = createApp(testConfig());
    const res = await post(app, 'settings', { DAILY_BUDGET_USD: '3' }, { 'Content-Type': 'text/plain' });
    assert.equal(res.status, 403);
    assert.deepEqual((await status(app)).overrides, {});
  });

  test('rejects a bad value with the config message and changes nothing', async () => {
    const { app, runtime } = createApp(testConfig());
    const before = runtime.skills;
    const res = await post(app, 'settings', { FAUX_PACE: '1', FAUX_LATENCY_MS: 'soon' });
    assert.equal(res.status, 400);
    assert.match((await res.json()).error.message, /FAUX_LATENCY_MS must be an integer/);
    assert.equal(runtime.skills, before);
    assert.deepEqual(runtime.overrides, {});

    assert.equal((await post(app, 'settings', { APP_TOKEN: 'x' })).status, 400, 'only the listed settings');
  });

  test('switches MODEL at runtime and back to server/.env', async () => {
    const { app, runtime } = createApp(testConfig());
    assert.equal((await v1(app, '/v1/place-card', placeCard)).status, 200);

    const res = await post(app, 'settings', { MODEL: 'gmi', MODEL_MIMO_REASONING: 'low', DAILY_BUDGET_USD: '3' });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.rebuilt, true);
    assert.equal(body.status.model, 'gmi');
    assert.deepEqual(body.status.models.mimo, { provider: 'gmi', modelId: 'deepseek-ai/DeepSeek-V4.1-Flash', reasoning: 'low' });
    assert.deepEqual(body.status.budget, { spentUsd: 0, limitUsd: 3 });
    assert.ok(runtime.mimoSessions, 'model-backed skills now');

    // Only the budget: the skills (and Mimo's chats) stay.
    const skills = runtime.skills;
    const budgetOnly = await (await post(app, 'settings', { DAILY_BUDGET_USD: '4' })).json();
    assert.equal(budgetOnly.rebuilt, false);
    assert.equal(runtime.skills, skills);
    assert.equal(runtime.budget?.limitUsd, 4);

    const reset = await (await post(app, 'settings/reset')).json();
    assert.equal(reset.status.model, 'faux');
    assert.deepEqual(reset.status.overrides, {});
    assert.equal((await v1(app, '/v1/place-card', placeCard)).status, 200, 'fixtures again');
  });

  test('a failed call shows in the activity with its message', async () => {
    // No GMI key: the call fails before any model call, and the entry says why.
    const { app: noKey } = createApp(testConfig({ GMI_API_KEY: '', MODEL: 'gmi' }));
    assert.equal((await v1(noKey, '/v1/place-card', placeCard)).status, 503);
    const [failed] = (await status(noKey)).activity;
    assert.equal(failed.state, 'failed');
    assert.match(failed.error, /GMI_API_KEY/);
    assert.equal(failed.model, 'gmi:deepseek-ai/DeepSeek-V4.1-Flash');
  });

  test('a Mimo reply in the activity: thinking, tool calls with their arguments, text, cost', async () => {
    const faux = fauxProvider({ provider: 'faux-test', models: [{ id: 'faux-1', cost: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0 } }], tokenSize: { min: 1, max: 2 } });
    const models = createModels();
    models.setProvider(faux.provider);
    const { app, runtime } = createApp(testConfig());
    const skills = createModelSkills(testConfig(), {
      llm: staticLlm(models, () => faux.getModel()),
      budget: new Budget({ limitUsd: 5, file: null }),
      cache: new ResponseCache({ file: null }),
      search: null,
      log: () => {},
      onMimoEvent: (runId, event) => runtime.activity.mimoRunEvent(runId, event),
      onMimoStats: (stats) => runtime.activity.mimoStats(stats),
    });
    runtime.skills = skills;
    const places = { places: [{ name: 'Ichiran Shinjuku', why: 'Open late, solo booths' }] };
    faux.setResponses([
      fauxAssistantMessage([fauxThinking('They want ramen nearby.'), fauxToolCall('show_places', places, { id: 'call_1' })], { stopReason: 'toolUse' }),
      fauxAssistantMessage('Ichiran is a short walk.'),
    ]);
    await (await v1(app, '/v1/sessions/chat-2/messages', mimoRequest)).text();

    const [reply] = (await status(app)).activity;
    assert.equal(reply.kind, 'mimo');
    assert.equal(reply.state, 'done');
    assert.equal(reply.result, 'stop');
    assert.equal(reply.sessionId, 'chat-2');
    assert.equal(reply.title, mimoRequest.message);
    assert.equal(reply.model, 'faux-test:faux-1');
    assert.match(reply.thinking, /They want ramen nearby/);
    assert.deepEqual(reply.steps, [{ id: 'call_1', name: 'show_places', state: 'done', input: 'Ichiran Shinjuku' }]);
    assert.match(reply.text, /Ichiran is a short walk/);
    assert.equal(reply.turns, 2);
    assert.ok(reply.costUsd > 0);
  });

  test('lists Mimo chats, shows a transcript, and forgets them', async () => {
    const faux = fauxProvider({ provider: 'faux-test', models: [{ id: 'faux-1' }], tokenSize: { min: 1, max: 2 } });
    const models = createModels();
    models.setProvider(faux.provider);
    const skills = createModelSkills(testConfig(), {
      llm: staticLlm(models, () => faux.getModel()),
      budget: new Budget({ limitUsd: 5, file: null }),
      cache: new ResponseCache({ file: null }),
      search: null,
      log: () => {},
    });
    faux.setResponses([fauxAssistantMessage('Try the ramen at the counter.')]);
    const { app } = createApp(testConfig(), { skills });
    await (await v1(app, '/v1/sessions/chat-1/messages', mimoRequest)).text();

    const s = await status(app);
    assert.equal(s.mimo.sessions.length, 1);
    assert.equal(s.mimo.sessions[0].id, 'chat-1');
    const transcript = await (await app.request('/admin/api/sessions/chat-1')).json();
    assert.deepEqual(transcript.messages.map((m: { role: string }) => m.role), ['system', 'user', 'assistant']);
    assert.equal(transcript.messages[2].text, 'Try the ramen at the counter.');
    assert.equal((await app.request('/admin/api/sessions/nope')).status, 404);

    await post(app, 'sessions/clear');
    assert.equal((await status(app)).mimo.sessions.length, 0);
  });
});
