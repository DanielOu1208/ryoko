// Server skeleton and fixture mode (W1.4, W1.5). Run: pnpm --dir server test

import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { serve } from '@hono/node-server';
import { Value } from 'typebox/value';
import type { TSchema } from 'typebox';
import {
  AllergyCardResponse,
  DiscoverResponse,
  ErrorEnvelope,
  PlaceCardResponse,
  SseEvent,
  type ErrorCode,
  type MimoMessageRequest,
  type PlaceCardRequest,
} from '@ryoko/contracts';
import { createApp } from '../src/app.ts';
import { ConfigError, configFromEnv, loadConfig, type Config } from '../src/config.ts';
import { ApiError } from '../src/errors.ts';
import { EXAMPLES_DIR, loadFixtures, pickFixture } from '../src/fixtures.ts';
import { createFauxSkills } from '../src/skills/faux.ts';
import type { MimoRun, Skills } from '../src/skills/types.ts';
import { formatSseComment, formatSseEvent, sleep } from '../src/sse.ts';

const TOKEN = `test-token-${Math.random().toString(36).slice(2)}`;
const example = (file: string): unknown => JSON.parse(readFileSync(join(EXAMPLES_DIR, file), 'utf8'));
const placeCardShanghai = example('place-card.request.json') as PlaceCardRequest;
const placeCardTokyo = example('place-card.tokyo.request.json') as PlaceCardRequest;
const discoverRequest = example('discover.request.json');
const allergyRequest = example('allergy-card.request.json');
const mimoRequest = example('mimo-message.request.json') as MimoMessageRequest;

function testConfig(env: Record<string, string> = {}): Config {
  return configFromEnv({ APP_TOKEN: TOKEN, MODEL: 'faux', FAUX_PACE: '0', LOG_REQUESTS: '0', ...env });
}

interface CallOptions {
  method?: string;
  body?: unknown;
  rawBody?: string;
  token?: string | null;
  headers?: Record<string, string>;
}

function call(app: ReturnType<typeof createApp>['app'], path: string, options: CallOptions = {}): Promise<Response> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json', 'X-Install-Id': 'install-test', 'X-Client-Version': '0.1.0', ...options.headers };
  if (options.token !== null) headers.Authorization = `Bearer ${options.token ?? TOKEN}`;
  const body = options.rawBody ?? (options.body === undefined ? undefined : JSON.stringify(options.body));
  return Promise.resolve(app.request(path, { method: options.method ?? (body === undefined ? 'GET' : 'POST'), headers, body }));
}

function assertValid(schema: TSchema, value: unknown, label: string) {
  const errors = Value.Errors(schema, value).map((e) => `${e.instancePath || '/'} ${e.message}`);
  assert.ok(Value.Check(schema, value), `${label} is invalid:\n  ${errors.slice(0, 5).join('\n  ')}`);
}

async function assertError(res: Response, status: number, code: ErrorCode): Promise<{ code: string; message: string; retryable: boolean }> {
  assert.equal(res.status, status);
  assert.match(res.headers.get('content-type') ?? '', /^application\/json/);
  const body = await res.json();
  assertValid(ErrorEnvelope, body, 'error envelope');
  assert.equal(body.error.code, code);
  return body.error;
}

interface ParsedStream {
  events: SseEvent[];
  comments: string[];
}

/** Parses a whole §7.7 stream strictly: every block is exactly one data line or one comment. */
function parseSse(text: string): ParsedStream {
  assert.ok(text.endsWith('\n\n'), 'stream ends with a blank line');
  const events: SseEvent[] = [];
  const comments: string[] = [];
  for (const block of text.slice(0, -2).split('\n\n')) {
    assert.ok(!block.includes('\n'), `one line per block, got ${JSON.stringify(block.slice(0, 80))}`);
    if (block.startsWith(':')) {
      comments.push(block);
      continue;
    }
    assert.ok(block.startsWith('data: '), `data line expected, got ${JSON.stringify(block.slice(0, 80))}`);
    const event: unknown = JSON.parse(block.slice('data: '.length));
    assertValid(SseEvent, event, 'SSE event');
    events.push(event as SseEvent);
  }
  return { events, comments };
}

function deferred<T = void>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

/** Faux skills with a replaceable Mimo run, for stream edge cases. */
function skillsWithMimo(run: MimoRun): Skills {
  const faux = createFauxSkills({ pace: 0, latencyMs: 0 });
  return { ...faux, name: 'test', mimo: async () => run };
}

describe('config', () => {
  test('fails fast with a clear message when APP_TOKEN is missing', () => {
    assert.throws(() => configFromEnv({ MODEL: 'faux' }), (err: unknown) => err instanceof ConfigError && /APP_TOKEN is missing/.test(err.message));
    assert.throws(() => configFromEnv({ APP_TOKEN: '   ' }), ConfigError);
  });

  test('defaults: port 8792, 60/min, 64 KB, 15 s pings', () => {
    const config = configFromEnv({ APP_TOKEN: 'x' });
    assert.equal(config.port, 8792);
    assert.equal(config.rateLimitPerMinute, 60);
    assert.equal(config.bodyLimitBytes, 64 * 1024);
    assert.equal(config.ssePingSeconds, 15);
  });

  test('reads the env file, and the process environment overrides it', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ryoko-env-'));
    const file = join(dir, '.env');
    writeFileSync(file, 'APP_TOKEN=from-file\nMODEL=gmi\nPORT=9999\n');
    const saved = { MODEL: process.env.MODEL, APP_TOKEN: process.env.APP_TOKEN, PORT: process.env.PORT };
    try {
      delete process.env.APP_TOKEN;
      delete process.env.PORT;
      process.env.MODEL = 'faux';
      const config = loadConfig(file);
      assert.equal(config.appToken, 'from-file');
      assert.equal(config.port, 9999);
      assert.equal(config.model, 'faux');
    } finally {
      for (const [key, value] of Object.entries(saved)) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
      }
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('healthz and auth', () => {
  const { app } = createApp(testConfig());

  test('GET /healthz is open', async () => {
    const res = await call(app, '/healthz', { token: null });
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true });
  });

  for (const path of ['/v1/place-card', '/v1/discover', '/v1/allergy-card', '/v1/sessions/s1/messages']) {
    test(`${path} needs the bearer token`, async () => {
      const missing = await call(app, path, { body: {}, token: null });
      await assertError(missing, 401, 'unauthorized');
      assert.equal(missing.headers.get('www-authenticate'), 'Bearer');
      await assertError(await call(app, path, { body: {}, token: `${TOKEN}x` }), 401, 'unauthorized');
      await assertError(await call(app, path, { body: {}, token: TOKEN.slice(0, -1) }), 401, 'unauthorized');
      await assertError(await call(app, path, { body: {}, token: null, headers: { Authorization: TOKEN } }), 401, 'unauthorized');
    });
  }

  test('the scheme is case-insensitive', async () => {
    const res = await call(app, '/v1/place-card', { body: placeCardShanghai, token: null, headers: { Authorization: `bearer ${TOKEN}` } });
    assert.equal(res.status, 200);
  });

  test('unknown routes get the error envelope', async () => {
    await assertError(await call(app, '/v1/nope', { body: {} }), 404, 'invalid_request');
    await assertError(await call(app, '/nope', { token: null }), 404, 'invalid_request');
  });
});

describe('fixture mode (MODEL=faux)', () => {
  const { app } = createApp(testConfig());

  test('place-card returns the zh-Hans example for Shanghai', async () => {
    const res = await call(app, '/v1/place-card', { body: placeCardShanghai });
    assert.equal(res.status, 200);
    const body = await res.json();
    assertValid(PlaceCardResponse, body, 'place-card response');
    assert.equal(body.language, 'zh-Hans');
    assert.ok(Math.abs(Date.parse(body.generatedAt) - Date.now()) < 60_000, 'generatedAt is fresh');
  });

  test('place-card returns the ja example for Tokyo', async () => {
    const res = await call(app, '/v1/place-card', { body: placeCardTokyo });
    assert.equal(res.status, 200);
    const body = await res.json();
    assertValid(PlaceCardResponse, body, 'place-card response');
    assert.equal(body.language, 'ja');
  });

  test('discover and allergy-card return their examples', async () => {
    const discover = await call(app, '/v1/discover', { body: discoverRequest });
    assert.equal(discover.status, 200);
    assertValid(DiscoverResponse, await discover.json(), 'discover response');
    const allergy = await call(app, '/v1/allergy-card', { body: allergyRequest });
    assert.equal(allergy.status, 200);
    const card = await allergy.json();
    assertValid(AllergyCardResponse, card, 'allergy-card response');
    assert.equal(card.reviewed, false);
  });

  test('an invalid body gets invalid_request with the field named', async () => {
    const error = await assertError(await call(app, '/v1/place-card', { body: example('error.invalid-request.request.json') }), 400, 'invalid_request');
    assert.match(error.message, /place-card contract/);
    assert.match(error.message, /profile\.version, profile\.nationality and \d+ more are missing/);
    assert.ok(error.message.length <= 300);
    const one = await assertError(await call(app, '/v1/place-card', { body: { situation: placeCardShanghai.situation } }), 400, 'invalid_request');
    assert.match(one.message, /contract: profile is missing\.$/);
    assert.equal(error.retryable, false);
  });

  test('unknown fields, wrong enums and bad JSON are rejected', async () => {
    const extra = await assertError(await call(app, '/v1/place-card', { body: { ...placeCardShanghai, extra: 1 } }), 400, 'invalid_request');
    assert.match(extra.message, /extra isn't allowed/);
    const badMode = { ...placeCardShanghai, situation: { ...placeCardShanghai.situation, mode: 'later' } };
    const mode = await assertError(await call(app, '/v1/place-card', { body: badMode }), 400, 'invalid_request');
    assert.match(mode.message, /situation\.mode must be one of "live", "preview"/);
    await assertError(await call(app, '/v1/discover', { rawBody: '{"area":' }), 400, 'invalid_request');
    await assertError(await call(app, '/v1/allergy-card', { rawBody: '' }), 400, 'invalid_request');
    await assertError(await call(app, '/v1/sessions/s1/messages', { body: { ...mimoRequest, message: '' } }), 400, 'invalid_request');
  });

  test('bodies over 64 KB get 413 invalid_request', async () => {
    const big = { ...placeCardShanghai, padding: 'x'.repeat(70 * 1024) };
    await assertError(await call(app, '/v1/place-card', { body: big }), 413, 'invalid_request');
  });

  test('a malformed X-Install-Id is rejected; a missing one is fine', async () => {
    await assertError(await call(app, '/v1/place-card', { body: placeCardShanghai, headers: { 'X-Install-Id': 'has spaces' } }), 400, 'invalid_request');
    const res = await app.request('/v1/place-card', {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(placeCardShanghai),
    });
    assert.equal(res.status, 200);
  });

  test('fixtures are picked by local language, with fallbacks', () => {
    const fixtures = loadFixtures();
    assert.equal(pickFixture(fixtures.placeCard, 'ja').response.language, 'ja');
    assert.equal(pickFixture(fixtures.placeCard, 'zh-Hans').response.language, 'zh-Hans');
    assert.equal(pickFixture(fixtures.placeCard, 'zh-Hant').response.language, 'zh-Hans');
    assert.equal(pickFixture(fixtures.placeCard, 'ko').variant, '');
    assert.ok(fixtures.mimo.some((i) => i.kind === 'event' && i.event.type === 'phrase'));
  });
});

describe('rate limit', () => {
  test('60/min per install id and per IP, as rate_limited with Retry-After', async () => {
    const { app } = createApp(testConfig({ RATE_LIMIT_PER_MINUTE: '3' }));
    const from = (ip: string, install: string) => ({ body: placeCardShanghai, headers: { 'X-Forwarded-For': ip, 'X-Install-Id': install } });
    for (let i = 0; i < 3; i++) assert.equal((await call(app, '/v1/place-card', from('10.0.0.1', 'a'))).status, 200);
    const limited = await call(app, '/v1/place-card', from('10.0.0.1', 'a'));
    await assertError(limited, 429, 'rate_limited');
    assert.ok(Number(limited.headers.get('retry-after')) >= 1);
    // Same IP, new install id: the IP bucket is empty.
    await assertError(await call(app, '/v1/place-card', from('10.0.0.1', 'b')), 429, 'rate_limited');
    // Same install id, new IP: the install bucket is empty.
    await assertError(await call(app, '/v1/place-card', from('10.0.0.2', 'a')), 429, 'rate_limited');
    // Both new: fine.
    assert.equal((await call(app, '/v1/place-card', from('10.0.0.3', 'c'))).status, 200);
    // The last X-Forwarded-For entry counts (the one Funnel appends).
    assert.equal((await call(app, '/v1/place-card', from('10.0.0.1, 10.0.0.4', 'd'))).status, 200);
  });

  test('/healthz is not rate limited', async () => {
    const { app } = createApp(testConfig({ RATE_LIMIT_PER_MINUTE: '1' }));
    for (let i = 0; i < 5; i++) assert.equal((await call(app, '/healthz', { token: null })).status, 200);
  });
});

describe('Mimo SSE stream', () => {
  test('replays mimo.sse.txt: headers, padding, the event union, start → done', async () => {
    const { app, sessions } = createApp(testConfig());
    const res = await call(app, '/v1/sessions/7d3e9a10-session/messages', { body: mimoRequest });
    assert.equal(res.status, 200);
    assert.match(res.headers.get('content-type') ?? '', /^text\/event-stream/);
    assert.equal(res.headers.get('cache-control'), 'no-cache');
    assert.equal(res.headers.get('x-accel-buffering'), 'no');

    const text = await res.text();
    assert.ok(!/^event:/m.test(text), 'no event: lines');
    const { events, comments } = parseSse(text);
    assert.ok(text.startsWith(':'), 'the stream opens with a comment');
    assert.ok(Buffer.byteLength(comments[0] ?? '') > 512, 'the padding comment is over 512 bytes');
    assert.ok(comments.includes(': ping'), 'the scripted ping is replayed');

    const first = events[0];
    assert.equal(first?.type, 'start');
    assert.equal(first.type === 'start' && first.sessionId, '7d3e9a10-session');
    const runId = first.type === 'start' ? first.runId : '';
    assert.deepEqual(events.at(-1), { type: 'done', stopReason: 'stop' });
    assert.equal(events.filter((e) => e.type === 'start').length, 1);
    assert.equal(events.filter((e) => e.type === 'done').length, 1);

    const types = events.map((e) => e.type);
    for (const type of ['text', 'phrase', 'tool_start', 'tool_end'] as const) assert.ok(types.includes(type), `has a ${type} event`);
    const phrase = events.find((e) => e.type === 'phrase');
    assert.ok(phrase?.type === 'phrase' && phrase.phrase.id.includes(runId), 'phrase ids carry this run id');
    assert.equal(sessions.isBusy('7d3e9a10-session'), false, 'the session is free after the run');
  });

  test('each run gets a new run id', async () => {
    const { app } = createApp(testConfig());
    const runIds = [];
    for (let i = 0; i < 2; i++) {
      const { events } = parseSse(await (await call(app, '/v1/sessions/s2/messages', { body: mimoRequest })).text());
      const start = events[0];
      runIds.push(start?.type === 'start' ? start.runId : null);
    }
    assert.notEqual(runIds[0], runIds[1]);
  });

  test('a second message to a busy session gets 409 session_busy', async () => {
    const gate = deferred();
    const { app, sessions } = createApp(testConfig(), {
      skills: skillsWithMimo(async (sink) => {
        sink.send({ type: 'text', delta: 'One moment.' });
        await gate.promise;
        return 'stop';
      }),
    });
    const firstRes = await call(app, '/v1/sessions/busy/messages', { body: mimoRequest });
    assert.equal(firstRes.status, 200);
    const busy = await assertError(await call(app, '/v1/sessions/busy/messages', { body: mimoRequest }), 409, 'session_busy');
    assert.equal(busy.retryable, true);
    // Other sessions are unaffected.
    const otherRes = await call(app, '/v1/sessions/other/messages', { body: mimoRequest });
    assert.equal(otherRes.status, 200);
    gate.resolve();
    assert.equal(parseSse(await otherRes.text()).events.at(-1)?.type, 'done');
    const { events } = parseSse(await firstRes.text());
    assert.equal(events.at(-1)?.type, 'done');
    assert.equal(sessions.isBusy('busy'), false);
    assert.equal((await call(app, '/v1/sessions/busy/messages', { body: mimoRequest })).status, 200);
  });

  test('a failing run ends with an error event and no done', async () => {
    const { app, sessions } = createApp(testConfig(), {
      skills: skillsWithMimo(async (sink) => {
        sink.send({ type: 'text', delta: 'Let me check.' });
        throw new ApiError('timeout', 'Mimo took too long to answer.');
      }),
    });
    const { events } = parseSse(await (await call(app, '/v1/sessions/fail/messages', { body: mimoRequest })).text());
    assert.deepEqual(events.map((e) => e.type), ['start', 'text', 'error']);
    assert.deepEqual(events.at(-1), { type: 'error', code: 'timeout', message: 'Mimo took too long to answer.', retryable: true });
    assert.equal(sessions.isBusy('fail'), false);
  });

  test('an event that breaks the contract becomes invalid_model_output', async () => {
    const { app } = createApp(testConfig(), {
      skills: skillsWithMimo(async (sink) => {
        sink.send({ type: 'text', delta: '' }); // delta has minLength 1
        return 'stop';
      }),
    });
    const { events } = parseSse(await (await call(app, '/v1/sessions/bad/messages', { body: mimoRequest })).text());
    const last = events.at(-1);
    assert.equal(last?.type, 'error');
    assert.equal(last?.type === 'error' && last.code, 'invalid_model_output');
  });

  test('sends : ping while a run is quiet', async () => {
    const { app } = createApp(testConfig({ SSE_PING_SECONDS: '0.03' }), {
      skills: skillsWithMimo(async (sink) => {
        await sleep(120, sink.signal);
        return 'stop';
      }),
    });
    const { comments } = parseSse(await (await call(app, '/v1/sessions/quiet/messages', { body: mimoRequest })).text());
    assert.ok(comments.filter((c) => c === ': ping').length >= 2, `pings: ${comments.length - 1}`);
  });

  test('U+0085, U+2028 and U+2029 are escaped, so no line reader splits a data line', async () => {
    const delta = 'a\u2028b\u2029c\u0085d \\\u2028e';
    const line = formatSseEvent({ type: 'text', delta });
    assert.ok(!/[\u0085\u2028\u2029]/.test(line), 'no raw NEL, LS or PS on the wire');
    assert.match(line, /\\u2028/);
    assert.match(line, /\\u2029/);
    assert.match(line, /\\u0085/);
    assert.deepEqual(JSON.parse(line.slice('data: '.length, -2)), { type: 'text', delta }, 'the escapes decode to the same text');
    assert.ok(!/[\u0085\u2028\u2029]/.test(formatSseComment('x\u2028y')), 'comments stay on one line too');

    // End to end, split the way Swift's AsyncLineSequence splits (CR, LF, CRLF, NEL, LS, PS).
    const title = 'Ramen\u2028guide\u2029(updated)\u0085';
    const { app } = createApp(testConfig(), {
      skills: skillsWithMimo(async (sink) => {
        sink.send({ type: 'text', delta });
        sink.send({ type: 'tool_end', id: 't1', name: 'web_search', ok: true, details: { sources: [{ title, url: 'https://example.com/a' }] } });
        return 'stop';
      }),
    });
    const text = await (await call(app, '/v1/sessions/lines/messages', { body: mimoRequest })).text();
    assert.ok(!/[\u0085\u2028\u2029]/.test(text), 'no raw NEL, LS or PS in the stream');
    const events = text
      .split(/\r\n|[\n\r\u0085\u2028\u2029]/)
      .filter((l) => l.startsWith('data: '))
      .map((l) => JSON.parse(l.slice('data: '.length)) as SseEvent);
    assert.deepEqual(events.map((e) => e.type), ['start', 'text', 'tool_end', 'done']);
    assert.equal(events[1]?.type === 'text' && events[1].delta, delta);
    const end = events[2];
    assert.deepEqual(end?.type === 'tool_end' && end.details, { sources: [{ title, url: 'https://example.com/a' }] });
  });

  test('a client that is gone before the run starts never runs Mimo, and frees the session', async () => {
    let ran = false;
    const { app, sessions } = createApp(testConfig(), {
      skills: skillsWithMimo(async () => {
        ran = true;
        return 'stop';
      }),
    });
    const gone = new AbortController();
    gone.abort();
    const res = await app.request('/v1/sessions/gone/messages', {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json', 'X-Install-Id': 'install-test' },
      body: JSON.stringify(mimoRequest),
      signal: gone.signal,
    });
    assert.equal(res.status, 200);
    await sleep(20);
    assert.equal(ran, false, 'the run was skipped');
    assert.equal(sessions.isBusy('gone'), false, 'the session was released');
  });

  test('a session id with odd characters is rejected', async () => {
    const { app } = createApp(testConfig());
    await assertError(await call(app, `/v1/sessions/${'x'.repeat(65)}/messages`, { body: mimoRequest }), 400, 'invalid_request');
    await assertError(await call(app, '/v1/sessions/a.b/messages', { body: mimoRequest }), 400, 'invalid_request');
  });
});

describe('when MODEL is not faux', () => {
  const { app, sessions } = createApp(testConfig({ MODEL: 'gmi' }));

  test('JSON endpoints answer model_error and say the skills come in W7', async () => {
    for (const [path, body] of [
      ['/v1/place-card', placeCardShanghai],
      ['/v1/discover', discoverRequest],
      ['/v1/allergy-card', allergyRequest],
    ] as const) {
      const error = await assertError(await call(app, path, { body }), 503, 'model_error');
      assert.match(error.message, /W7/);
    }
  });

  test('the Mimo endpoint answers a JSON model_error, not a stream, and frees the session', async () => {
    for (let i = 0; i < 2; i++) await assertError(await call(app, '/v1/sessions/m1/messages', { body: mimoRequest }), 503, 'model_error');
    assert.equal(sessions.isBusy('m1'), false);
  });
});

describe('over a real socket (@hono/node-server)', () => {
  let server: ReturnType<typeof serve>;
  let base = '';
  let ryoko: ReturnType<typeof createApp>;

  /** Set when the hanging run for session `leaver` sees its signal abort. */
  let leaverAborted = false;
  /** Set when that run has returned. */
  let leaverReturned = false;
  /** Lets that run return after its abort, like a model call that takes a moment to stop. */
  const leaverWindDown = deferred();

  before(async () => {
    const faux = createFauxSkills({ pace: 1, latencyMs: 0 });
    // Session `leaver` never finishes on its own: only a client disconnect can end it,
    // and even then it returns only once `leaverWindDown` resolves.
    const hanging: MimoRun = async (sink) => {
      sink.send({ type: 'text', delta: 'Thinking about it.' });
      try {
        await sleep(60_000, sink.signal);
      } catch {
        leaverAborted = sink.signal.aborted;
        await leaverWindDown.promise;
      }
      leaverReturned = true;
      return 'aborted';
    };
    const skills: Skills = { ...faux, mimo: async (request, ctx) => (ctx.sessionId === 'leaver' ? hanging : faux.mimo(request, ctx)) };
    ryoko = createApp(testConfig({ FAUX_PACE: '1' }), { skills });
    server = serve({ fetch: ryoko.app.fetch, hostname: '127.0.0.1', port: 0 });
    await once(server, 'listening');
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  after(async () => {
    if ('closeAllConnections' in server) server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  });

  const post = (path: string, body: unknown, signal?: AbortSignal) =>
    fetch(`${base}${path}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json', 'X-Install-Id': 'socket-test' },
      body: JSON.stringify(body),
      signal,
    });

  test('events arrive incrementally, padding first', async () => {
    const started = performance.now();
    const res = await post('/v1/sessions/live/messages', mimoRequest);
    const reader = res.body!.getReader();
    const decoder = new TextDecoder();
    const arrivals: { at: number; text: string }[] = [];
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      arrivals.push({ at: performance.now() - started, text: decoder.decode(value, { stream: true }) });
    }
    const all = arrivals.map((a) => a.text).join('');
    const { events } = parseSse(all);
    assert.equal(events.at(-1)?.type, 'done');
    assert.ok(arrivals[0]!.text.startsWith(': ') && arrivals[0]!.at < 300, `padding first and fast (${Math.round(arrivals[0]!.at)} ms)`);
    assert.ok(arrivals.length >= 8, `streamed in ${arrivals.length} chunks`);
    const span = arrivals.at(-1)!.at - arrivals[0]!.at;
    assert.ok(span > 1000, `paced over ${Math.round(span)} ms`);
  });

  test('closing the connection aborts the run; the session stays busy until the run returns', async () => {
    const controller = new AbortController();
    const res = await post('/v1/sessions/leaver/messages', mimoRequest, controller.signal);
    const reader = res.body!.getReader();
    let seen = '';
    while (!seen.includes('"type":"text"')) {
      const { done, value } = await reader.read();
      if (done) break;
      seen += new TextDecoder().decode(value);
    }
    assert.ok(ryoko.sessions.isBusy('leaver'), 'busy while streaming');
    assert.equal(leaverAborted, false);
    controller.abort();
    const deadline = Date.now() + 1000;
    while (!leaverAborted && Date.now() < deadline) await sleep(10);
    assert.equal(leaverAborted, true, "the run's signal aborted when the client left");

    // The client is gone but the run hasn't returned: still one run, still locked.
    await sleep(50);
    assert.equal(leaverReturned, false);
    assert.ok(ryoko.sessions.isBusy('leaver'), 'busy until the run returns, not just until the client leaves');
    const second = await post('/v1/sessions/leaver/messages', mimoRequest);
    assert.equal(second.status, 409, 'a second message while the first run winds down');
    assert.equal((await second.json()).error.code, 'session_busy');

    leaverWindDown.resolve();
    const freed = Date.now() + 1000;
    while (ryoko.sessions.isBusy('leaver') && Date.now() < freed) await sleep(10);
    assert.equal(leaverReturned, true);
    assert.equal(ryoko.sessions.isBusy('leaver'), false, 'the session was released once the run returned');
  });

  test('JSON endpoints and auth work over the socket', async () => {
    const res = await post('/v1/place-card', placeCardTokyo);
    assert.equal(res.status, 200);
    assertValid(PlaceCardResponse, await res.json(), 'place-card over the socket');
    const health = await fetch(`${base}/healthz`);
    assert.equal(health.status, 200);
    await health.body?.cancel();
    const denied = await fetch(`${base}/v1/discover`, { method: 'POST', body: '{}' });
    assert.equal(denied.status, 401);
    await denied.body?.cancel();
  });
});
