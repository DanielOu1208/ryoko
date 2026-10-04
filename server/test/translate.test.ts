// Tier 2 Translate endpoints: POST /v1/translate (T2.4) and POST /v1/soniox-key
// (T2.6), offline. The model is pi-ai's faux provider, Soniox is a stub fetch.
// Run: pnpm --dir server test

import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { readFileSync } from 'node:fs';
import type { AddressInfo } from 'node:net';
import { join } from 'node:path';
import { serve } from '@hono/node-server';
import { createModels } from '@earendil-works/pi-ai/models';
import { fauxAssistantMessage, fauxProvider, getSystemMessageText, type AssistantMessage, type FauxResponseStep, type TranscriptContext } from '@earendil-works/pi-ai';
import { Value } from 'typebox/value';
import { ErrorEnvelope, SonioxKeyResponse, TranslateResponse, type Situation, type TranslateRequest } from '@ryoko/contracts';
import { createApp } from '../src/app.ts';
import { ResponseCache } from '../src/cache.ts';
import { configFromEnv, type Config } from '../src/config.ts';
import { ApiError } from '../src/errors.ts';
import { EXAMPLES_DIR } from '../src/fixtures.ts';
import { Budget } from '../src/llm/budget.ts';
import { staticLlm } from '../src/llm/registry.ts';
import { createFauxSkills } from '../src/skills/faux.ts';
import { createModelSkills, type SkillCallStats } from '../src/skills/model.ts';
import { finalizeTranslate, translateUser } from '../src/skills/translate.ts';
import { languageInfo } from '../src/skills/context.ts';
import type { SkillContext, Skills } from '../src/skills/types.ts';
import { createSonioxMinter, SONIOX_TEMPORARY_KEY_URL, temporaryKeyBody, type SonioxMinter } from '../src/soniox.ts';
import { sleep } from '../src/sse.ts';

const TOKEN = `test-token-${Math.random().toString(36).slice(2)}`;
const example = <T>(file: string): T => JSON.parse(readFileSync(join(EXAMPLES_DIR, file), 'utf8')) as T;
const shanghaiRequest = example<TranslateRequest>('translate.request.json');
const tokyoRequest = example<TranslateRequest>('translate.tokyo.request.json');
const shanghai = example<Situation>('situation.shanghai-cafe.json');

function testConfig(env: Record<string, string> = {}): Config {
  return configFromEnv({ APP_TOKEN: TOKEN, MODEL: 'faux', FAUX_PACE: '0', LOG_REQUESTS: '0', CACHE_DIR: 'off', ...env });
}

function call(app: ReturnType<typeof createApp>['app'], path: string, body?: unknown, headers: Record<string, string> = {}): Promise<Response> {
  return Promise.resolve(
    app.request(path, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json', 'X-Install-Id': 'install-translate', ...headers },
      body: JSON.stringify(body ?? {}),
    }),
  );
}

async function errorOf(res: Response, status: number, code: string) {
  assert.equal(res.status, status);
  const body = await res.json();
  assert.ok(Value.Check(ErrorEnvelope, body), 'error envelope');
  assert.equal(body.error.code, code);
  return body.error as { code: string; message: string; retryable: boolean };
}

const ctx = (signal = new AbortController().signal): SkillContext => ({ installId: 'i', clientVersion: 'test', signal });

/** pi-ai's faux provider behind the model skills. */
function harness() {
  const faux = fauxProvider({ provider: 'faux-test', models: [{ id: 'faux-1', cost: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0 } }], tokenSize: { min: 1, max: 2 } });
  const models = createModels();
  models.setProvider(faux.provider);
  const contexts: TranscriptContext[] = [];
  const stats: SkillCallStats[] = [];
  const skills = createModelSkills(testConfig(), {
    llm: staticLlm(models, () => faux.getModel()),
    budget: new Budget({ limitUsd: 5, file: null }),
    cache: new ResponseCache({ file: null }),
    search: null,
    log: () => {},
    onSkillStats: (s) => stats.push(s),
  });
  const script = (...steps: (AssistantMessage | ((context: TranscriptContext, signal?: AbortSignal) => AssistantMessage | Promise<AssistantMessage>))[]) =>
    faux.setResponses(
      steps.map((step): FauxResponseStep => (context, options) => {
        contexts.push(context);
        return typeof step === 'function' ? step(context, options?.signal) : step;
      }),
    );
  return { faux, skills, contexts, stats, script };
}

const reply = (translation: string) => fauxAssistantMessage(JSON.stringify({ translation }));

/** A model reply that only comes once the call is aborted, like a slow model being cancelled. */
const untilAborted = (seen: { aborted: boolean }) => (_context: TranscriptContext, signal?: AbortSignal) =>
  new Promise<AssistantMessage>((resolve) => {
    signal?.addEventListener('abort', () => {
      seen.aborted = true;
      resolve(reply('请给我一杯热的燕麦拿铁，少糖。'));
    });
  });

function lastUser(context: TranscriptContext): string {
  const message = context.messages.findLast((m) => m.role === 'user');
  if (!message || message.role !== 'user') return '';
  return typeof message.content === 'string' ? message.content : message.content.map((c) => (c.type === 'text' ? c.text : '')).join('');
}

// --- POST /v1/translate in fixture mode ---

describe('POST /v1/translate (MODEL=faux)', () => {
  const { app } = createApp(testConfig(), { soniox: null });

  test('answers with the example for the target language', async () => {
    const zh = await call(app, '/v1/translate', { ...shanghaiRequest, text: 'Anything at all' });
    assert.equal(zh.status, 200);
    const zhBody = await zh.json();
    assert.ok(Value.Check(TranslateResponse, zhBody));
    assert.equal(zhBody.translation, example<{ translation: string }>('translate.response.json').translation);

    const ja = await call(app, '/v1/translate', tokyoRequest);
    assert.equal((await ja.json()).translation, example<{ translation: string }>('translate.tokyo.response.json').translation);
  });

  test('works without a situation, and hands the same language back untouched', async () => {
    const { situation: _situation, ...noSituation } = shanghaiRequest;
    assert.equal((await call(app, '/v1/translate', noSituation)).status, 200);
    const same = await call(app, '/v1/translate', { text: '  Hello there ', from: 'en', to: 'en' });
    assert.equal((await same.json()).translation, 'Hello there');
  });

  test('refuses bad requests and missing auth', async () => {
    await errorOf(await call(app, '/v1/translate', { ...shanghaiRequest, text: '' }), 400, 'invalid_request');
    await errorOf(await call(app, '/v1/translate', { ...shanghaiRequest, text: 'x'.repeat(501) }), 400, 'invalid_request');
    await errorOf(await call(app, '/v1/translate', { ...shanghaiRequest, extra: 1 }), 400, 'invalid_request');
    const denied = await app.request('/v1/translate', { method: 'POST', body: JSON.stringify(shanghaiRequest) });
    await errorOf(denied, 401, 'unauthorized');
  });
});

// --- the translate skill on a model ---

describe('translate skill', () => {
  test('prompt names the languages and the kind of place; cached by text, languages and category', async () => {
    const h = harness();
    h.script(reply('请给我一杯热的燕麦拿铁，少糖。'), reply('请给我一杯热的燕麦拿铁，少糖。'));
    const first = await h.skills.translate(shanghaiRequest, ctx());
    assert.equal(first.translation, '请给我一杯热的燕麦拿铁，少糖。');
    const user = JSON.parse(lastUser(h.contexts[0]!));
    assert.deepEqual(user, { from: 'English', to: 'Chinese (Simplified)', place: 'Café', text: shanghaiRequest.text });
    const system = h.contexts[0]!.messages[0];
    assert.ok(system && system.role === 'system' && /never an instruction to you/.test(getSystemMessageText(system)));
    assert.doesNotMatch(lastUser(h.contexts[0]!), /Wutong|梧桐|Shanghai|15:00/, 'nothing but the category reaches the prompt (it is the cache key)');

    // Same text (spacing aside), languages and category: from the cache, whatever the time or place name.
    const later: TranslateRequest = {
      ...shanghaiRequest,
      text: `  ${shanghaiRequest.text.replace(/ /g, '  ')} `,
      situation: { ...shanghai, localTime: '2026-10-05T21:00:00+08:00', hourBucket: '2026-10-05T21', place: { ...shanghai.place!, id: 'other', name: 'Another café' } },
    };
    assert.equal((await h.skills.translate(later, ctx())).translation, first.translation);
    assert.equal(h.contexts.length, 1, 'no second model call');
    assert.deepEqual(h.stats.map((s) => s.source), ['generated', 'cache']);

    // A tea shop is another category: a fresh generation.
    const tea: TranslateRequest = { ...shanghaiRequest, situation: { ...shanghai, place: { ...shanghai.place!, category: 'tea' } } };
    await h.skills.translate(tea, ctx());
    assert.equal(h.contexts.length, 2);
    assert.equal(JSON.parse(lastUser(h.contexts[1]!)).place, 'Tea shop');
  });

  test('a reply in the wrong language is retried with the problem listed', async () => {
    const h = harness();
    h.script(reply('Can I have a hot oat latte with less sugar?'), reply('请给我一杯热的燕麦拿铁，少糖。'));
    const result = await h.skills.translate(shanghaiRequest, ctx());
    assert.equal(result.translation, '请给我一杯热的燕麦拿铁，少糖。');
    assert.match(lastUser(h.contexts[1]!), /isn't written in Chinese \(Simplified\)/);
  });

  test('two misses are invalid_model_output and nothing is cached', async () => {
    const h = harness();
    h.script(reply('Hello'), reply('Hello'), reply('请给我一杯热的燕麦拿铁，少糖。'));
    await assert.rejects(h.skills.translate(shanghaiRequest, ctx()), (err: unknown) => err instanceof ApiError && err.code === 'invalid_model_output');
    assert.equal((await h.skills.translate(shanghaiRequest, ctx())).translation, '请给我一杯热的燕麦拿铁，少糖。');
  });

  test('finalize: quotes come off, digits pass, an echo is refused, Japanese and English targets', () => {
    const en = languageInfo('en');
    const zh = languageInfo('zh-Hans');
    const ja = languageInfo('ja');
    const req = (text: string, from = 'en', to = 'zh-Hans'): TranslateRequest => ({ text, from, to });
    const ok = (r: ReturnType<typeof finalizeTranslate>) => (r.ok ? r.value.translation : `issues: ${r.issues.join('; ')}`);
    assert.equal(ok(finalizeTranslate(req('Less sugar'), en, zh, { translation: '“少糖”' })), '少糖');
    assert.equal(ok(finalizeTranslate(req('Less sugar'), en, ja, { translation: '「甘さ控えめで」' })), '甘さ控えめで');
    assert.equal(ok(finalizeTranslate(req('18'), en, zh, { translation: '18' })), '18');
    assert.match(ok(finalizeTranslate(req('Less sugar'), en, zh, { translation: 'Less sugar' })), /isn't written in Chinese \(Simplified\)/);
    assert.equal(ok(finalizeTranslate(req('少糖', 'zh-Hans', 'en'), zh, en, { translation: 'Less sugar, please.' })), 'Less sugar, please.');
    assert.match(ok(finalizeTranslate(req('少糖', 'zh-Hans', 'en'), zh, en, { translation: '少糖' })), /isn't written in English/);
  });

  test('every non-Latin language Translate offers takes its own script', () => {
    const en = languageInfo('en');
    const samples: Record<string, string> = { gu: 'ઓછી ખાંડ', ur: 'کم چینی', kk: 'Қант аз', mk: 'Малку шеќер', be: 'Менш цукру', pa: 'ਘੱਟ ਖੰਡ', kn: 'ಕಡಿಮೆ ಸಕ್ಕರೆ', ml: 'പഞ്ചസാര കുറച്ച്', mr: 'कमी साखर' };
    for (const [tag, translation] of Object.entries(samples)) {
      const result = finalizeTranslate({ text: 'Less sugar', from: 'en', to: tag }, en, languageInfo(tag), { translation });
      assert.ok(result.ok, `${tag}: ${result.ok ? '' : result.issues.join('; ')}`);
    }
  });

  test('the user message is JSON with only the four fields', () => {
    const user = JSON.parse(translateUser({ text: 'Hi', from: 'en', to: 'ja' }, languageInfo('en'), languageInfo('ja')));
    assert.deepEqual(user, { from: 'English', to: 'Japanese', place: null, text: 'Hi' });
  });
});

describe('translate cancellation', () => {
  test('a client that leaves stops the generation, and nothing is cached', async () => {
    const h = harness();
    const seen = { aborted: false };
    h.script(untilAborted(seen), reply('请给我一杯热的燕麦拿铁，少糖。'));
    const client = new AbortController();
    const pending = h.skills.translate(shanghaiRequest, ctx(client.signal));
    await sleep(20);
    client.abort();
    await assert.rejects(pending, (err: unknown) => err instanceof ApiError && Number(err.status) === 499);
    await sleep(20);
    assert.equal(seen.aborted, true, 'the model call saw the abort');
    // The next request generates afresh.
    assert.equal((await h.skills.translate(shanghaiRequest, ctx())).translation, '请给我一杯热的燕麦拿铁，少糖。');
    assert.equal(h.contexts.length, 2);
  });

  test('one of two callers leaving never cancels the other', async () => {
    const h = harness();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    let sawAbort = false;
    h.script(async (_context, signal) => {
      signal?.addEventListener('abort', () => (sawAbort = true));
      await gate;
      return reply('请给我一杯热的燕麦拿铁，少糖。');
    });
    const leaver = new AbortController();
    const first = h.skills.translate(shanghaiRequest, ctx(leaver.signal));
    await sleep(10);
    const second = h.skills.translate(shanghaiRequest, ctx());
    await sleep(10);
    leaver.abort();
    await assert.rejects(first, (err: unknown) => err instanceof ApiError && Number(err.status) === 499);
    release();
    assert.equal((await second).translation, '请给我一杯热的燕麦拿铁，少糖。');
    assert.equal(sawAbort, false);
    assert.equal(h.contexts.length, 1, 'one generation shared by both');
    // And it was cached for the next caller.
    await h.skills.translate(shanghaiRequest, ctx());
    assert.equal(h.contexts.length, 1);
  });

  test('over a real socket, closing the request aborts the skill', async () => {
    let aborted = false;
    const faux = createFauxSkills({ pace: 0, latencyMs: 0 });
    const skills: Skills = {
      ...faux,
      async translate(_request, skillCtx) {
        try {
          await sleep(60_000, skillCtx.signal);
        } catch {
          aborted = skillCtx.signal.aborted;
        }
        throw new ApiError('timeout', 'stopped');
      },
    };
    const { app } = createApp(testConfig(), { skills, soniox: null });
    const server = serve({ fetch: app.fetch, hostname: '127.0.0.1', port: 0 });
    await once(server, 'listening');
    try {
      const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
      const controller = new AbortController();
      const request = fetch(`${base}/v1/translate`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(shanghaiRequest),
        signal: controller.signal,
      }).catch(() => null);
      await sleep(100);
      controller.abort();
      await request;
      const deadline = Date.now() + 1000;
      while (!aborted && Date.now() < deadline) await sleep(10);
      assert.equal(aborted, true, "the skill's signal aborted when the client left");
    } finally {
      if ('closeAllConnections' in server) server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    }
  });
});

// --- POST /v1/soniox-key ---

const SERVER_KEY = 'server-soniox-key-0123456789abcdef0123456789';
const MINTED_KEY = 'temp:minted-key-abcdef0123456789abcdef0123';

interface FetchCall {
  url: string;
  init: RequestInit;
}

function stubFetch(respond: (call: FetchCall) => Response | Promise<Response>): { fetch: typeof fetch; calls: FetchCall[] } {
  const calls: FetchCall[] = [];
  const fn = (async (input: string | URL | Request, init?: RequestInit) => {
    const entry = { url: String(input), init: init ?? {} };
    calls.push(entry);
    return respond(entry);
  }) as typeof fetch;
  return { fetch: fn, calls };
}

const settings = { expiresInSeconds: 60, maxSessionSeconds: 3600 };

describe('Soniox minter', () => {
  test('asks for a single-use websocket key for 60 s and an hour of audio, with the server key as bearer', async () => {
    const stub = stubFetch(() => Response.json({ api_key: MINTED_KEY, expires_at: '2026-10-05T07:01:00.123456Z' }, { status: 201 }));
    const mint = createSonioxMinter({ apiKey: SERVER_KEY, settings, fetch: stub.fetch });
    const key = await mint(new AbortController().signal);
    assert.deepEqual(key, { apiKey: MINTED_KEY, expiresAt: '2026-10-05T07:01:00.123Z' });
    assert.ok(Value.Check(SonioxKeyResponse, key));
    const [sent] = stub.calls;
    assert.equal(sent?.url, SONIOX_TEMPORARY_KEY_URL);
    assert.equal(new Headers(sent?.init.headers).get('authorization'), `Bearer ${SERVER_KEY}`);
    const body = JSON.parse(String(sent?.init.body));
    assert.deepEqual(body, { usage_type: 'transcribe_websocket', expires_in_seconds: 60, single_use: true, max_session_duration_seconds: 3600 });
    assert.ok(!JSON.stringify(temporaryKeyBody(settings)).includes(SERVER_KEY), 'the body never carries the key');
  });

  test('a missing expiry counts from now', async () => {
    const stub = stubFetch(() => Response.json({ api_key: MINTED_KEY }));
    const mint = createSonioxMinter({ apiKey: SERVER_KEY, settings, fetch: stub.fetch, now: () => new Date('2026-10-05T07:00:00Z') });
    assert.equal((await mint(new AbortController().signal)).expiresAt, '2026-10-05T07:01:00.000Z');
  });

  test('Soniox errors become model_error, without either key in the message', async () => {
    const cases: [Response, number, boolean][] = [
      [Response.json({ error_type: 'unauthenticated', error_message: `Invalid API key ${SERVER_KEY}` }, { status: 401 }), 502, false],
      [Response.json({ error_message: 'Insufficient balance' }, { status: 402 }), 502, false],
      [new Response('<html>bad gateway</html>', { status: 503 }), 502, true],
      [Response.json({ expires_at: '2026-10-05T07:01:00Z' }), 502, true],
    ];
    for (const [response, status, retryable] of cases) {
      const mint = createSonioxMinter({ apiKey: SERVER_KEY, settings, fetch: stubFetch(() => response).fetch });
      await assert.rejects(mint(new AbortController().signal), (err: unknown) => {
        assert.ok(err instanceof ApiError);
        assert.equal(err.code, 'model_error');
        assert.equal(err.status, status);
        assert.equal(err.retryable, retryable);
        assert.ok(!err.message.includes(SERVER_KEY) && !err.message.includes(MINTED_KEY), err.message);
        return true;
      });
    }
  });

  test('unreachable is a retryable model_error; too slow is a timeout', async () => {
    const down = createSonioxMinter({ apiKey: SERVER_KEY, settings, fetch: stubFetch(() => Promise.reject(new TypeError('fetch failed'))).fetch });
    await assert.rejects(down(new AbortController().signal), (err: unknown) => err instanceof ApiError && err.code === 'model_error' && err.retryable);
    const slow = createSonioxMinter({
      apiKey: SERVER_KEY,
      settings,
      timeoutMs: 30,
      fetch: stubFetch(
        ({ init }) =>
          new Promise<Response>((_resolve, reject) => init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))),
      ).fetch,
    });
    await assert.rejects(slow(new AbortController().signal), (err: unknown) => err instanceof ApiError && err.code === 'timeout');
  });
});

describe('POST /v1/soniox-key', () => {
  const minted: SonioxMinter = async () => ({ apiKey: MINTED_KEY, expiresAt: '2026-10-05T07:01:00.000Z' });

  test('returns a key, never cached, and never in the log', async () => {
    const lines: string[] = [];
    const { app } = createApp(testConfig({ LOG_REQUESTS: '1' }), { soniox: minted, log: (line) => lines.push(line) });
    const res = await call(app, '/v1/soniox-key');
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    const body = await res.json();
    assert.deepEqual(body, { apiKey: MINTED_KEY, expiresAt: '2026-10-05T07:01:00.000Z' });
    assert.ok(lines.some((line) => line.startsWith('POST /v1/soniox-key 200')), lines.join('\n'));
    assert.ok(!lines.some((line) => line.includes(MINTED_KEY)), 'the key is never logged');
  });

  test('works in fixture mode too: minting is not a model call', async () => {
    const { app } = createApp(testConfig({ MODEL: 'faux' }), { soniox: minted });
    assert.equal((await call(app, '/v1/soniox-key')).status, 200);
  });

  test('without SONIOX_API_KEY it is a 503 the app can fall back from', async () => {
    const { app } = createApp(testConfig());
    const error = await errorOf(await call(app, '/v1/soniox-key'), 503, 'model_error');
    assert.equal(error.retryable, false);
    assert.match(error.message, /SONIOX_API_KEY/);
  });

  test('needs the app token', async () => {
    const { app } = createApp(testConfig(), { soniox: minted });
    await errorOf(await app.request('/v1/soniox-key', { method: 'POST', body: '{}' }), 401, 'unauthorized');
  });

  test('has its own, tighter rate limit per install and IP', async () => {
    const { app } = createApp(testConfig({ SONIOX_KEYS_PER_MINUTE: '2' }), { soniox: minted });
    assert.equal((await call(app, '/v1/soniox-key')).status, 200);
    assert.equal((await call(app, '/v1/soniox-key')).status, 200);
    const limited = await call(app, '/v1/soniox-key');
    await errorOf(limited, 429, 'rate_limited');
    assert.ok(Number(limited.headers.get('retry-after')) >= 1);
    // Other routes still answer.
    assert.equal((await call(app, '/v1/translate', tokyoRequest)).status, 200);
  });

  test('config reads SONIOX_API_KEY as set or not, and describes it without the value', async () => {
    const { describeConfig } = await import('../src/config.ts');
    const config = testConfig({ SONIOX_API_KEY: SERVER_KEY });
    assert.equal(config.soniox.configured, true);
    assert.deepEqual([config.soniox.expiresInSeconds, config.soniox.maxSessionSeconds, config.soniox.perMinute], [60, 3600, 30]);
    const text = describeConfig(config);
    assert.match(text, /Soniox keys on/);
    assert.ok(!text.includes(SERVER_KEY));
  });
});
