// Trip memory and saved chats (Tiger Data, design §8.3), offline: the store is
// faked, the model is pi-ai's faux provider. The live database is checked by hand
// (resource/implementation-tracking.md, A1).

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createModels } from '@earendil-works/pi-ai/models';
import { fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall, getSystemMessageText, type AssistantMessage, type FauxResponseStep, type SystemMessage, type TranscriptContext } from '@earendil-works/pi-ai';
import { Value } from 'typebox/value';
import { SseEvent, TripEventsResponse, type MimoMessageRequest, type Situation, type TripEvent, type TripEventsRequest } from '@ryoko/contracts';
import { createApp } from '../src/app.ts';
import { ResponseCache } from '../src/cache.ts';
import { configFromEnv } from '../src/config.ts';
import { EXAMPLES_DIR } from '../src/fixtures.ts';
import { Budget } from '../src/llm/budget.ts';
import { staticLlm } from '../src/llm/registry.ts';
import { tripMemorySection } from '../src/memory/section.ts';
import { embeddingText, type MemoryKind, type Recall, type RecalledEvent, type SavedSession, type StoredEvent, type TripMemory, type SessionStore } from '../src/memory/tiger.ts';
import type { Tiger } from '../src/memory/index.ts';
import { createModelSkills, type ModelSkills } from '../src/skills/model.ts';
import type { SseSink } from '../src/sse.ts';

const TOKEN = 'test-token-memory';
const example = <T>(file: string): T => JSON.parse(readFileSync(join(EXAMPLES_DIR, file), 'utf8')) as T;
const tokyo: Situation = { ...example<Situation>('situation.tokyo-ramen.json'), localTime: '2026-10-05T20:10:00+09:00' };
const mimoRequest: MimoMessageRequest = { ...example<MimoMessageRequest>('mimo-message.request.json'), situation: tokyo, nearby: [], message: 'What did I order at the ramen place?' };
const tripEvents = example<TripEventsRequest>('trip-events.request.json');

const event = (changes: Partial<RecalledEvent>): RecalledEvent => ({
  kind: 'phrase_shown',
  time: new Date('2026-10-05T10:48:00Z'),
  localTime: '2026-10-05T19:48:00+09:00',
  text: '麺かためでお願いします。',
  meaning: 'Firm noodles, please.',
  placeName: 'Menya Shono',
  category: 'ramen',
  city: 'Tokyo',
  ...changes,
});

/** A Tiger stand-in that records what it's asked. */
type SearchFilter = { kind?: MemoryKind; days?: number; limit?: number };

function fakeTiger(
  options: {
    recall?: (installId: string, message: string | null) => Promise<Recall>;
    search?: (query: string, filter: SearchFilter) => Promise<RecalledEvent[]>;
    saved?: Map<string, SavedSession & { installId: string | null }>;
  } = {},
) {
  const stored: { installId: string; events: readonly (TripEvent | StoredEvent)[] }[] = [];
  const searches: { installId: string; query: string; filter: SearchFilter }[] = [];
  const recalls: { installId: string; message: string | null }[] = [];
  const saved = options.saved ?? new Map<string, SavedSession & { installId: string | null }>();
  const trips = {
    async store(installId: string, events: readonly (TripEvent | StoredEvent)[]) {
      stored.push({ installId, events });
      return events.length;
    },
    async search(installId: string, query: string, filter: SearchFilter = {}) {
      searches.push({ installId, query, filter });
      return options.search ? options.search(query, filter) : [event({})];
    },
    async recall(installId: string, message: string | null) {
      recalls.push({ installId, message });
      return options.recall ? options.recall(installId, message) : { recent: [event({})], similar: [] };
    },
  };
  const sessions = {
    async load(sessionId: string, installId: string | null) {
      const hit = saved.get(sessionId);
      return hit && hit.installId === installId ? { modelKey: hit.modelKey, messages: hit.messages } : null;
    },
    async save(sessionId: string, installId: string | null, session: SavedSession) {
      saved.set(sessionId, { ...structuredClone(session), installId });
    },
  };
  const tiger = { trips: trips as unknown as TripMemory, sessions: sessions as unknown as SessionStore, ready: Promise.resolve(true) } satisfies Tiger;
  return { tiger, stored, recalls, searches, saved };
}

function harness(tiger: Tiger | null, env: Record<string, string> = {}) {
  const faux = fauxProvider({ provider: 'faux-test', models: [{ id: 'faux-1' }], tokenSize: { min: 1, max: 2 } });
  const models = createModels();
  models.setProvider(faux.provider);
  const contexts: TranscriptContext[] = [];
  const skills = createModelSkills(configFromEnv({ APP_TOKEN: TOKEN, MODEL: 'faux', LOG_REQUESTS: '0', CACHE_DIR: 'off', ...env }), {
    llm: staticLlm(models, () => faux.getModel()),
    budget: new Budget({ limitUsd: 5, file: null }),
    cache: new ResponseCache({ file: null }),
    search: null,
    guides: null,
    tiger,
    log: () => {},
  });
  const script = (...replies: (string | AssistantMessage)[]) =>
    faux.setResponses(
      replies.map((reply): FauxResponseStep => (context) => {
        contexts.push(context);
        if (typeof reply !== 'string') return reply;
        return reply === 'ERROR' ? fauxAssistantMessage([], { stopReason: 'error', errorMessage: 'upstream 500' }) : fauxAssistantMessage(reply);
      }),
    );
  return { skills, contexts, script, faux };
}

function sink(): SseSink & { events: SseEvent[] } {
  const events: SseEvent[] = [];
  const abort = new AbortController();
  return {
    events,
    send(e) {
      assert.ok(Value.Check(SseEvent, e));
      events.push(e);
      return true;
    },
    comment: () => true,
    signal: abort.signal,
    closed: false,
  };
}

let runs = 0;
async function ask(skills: ModelSkills, request: MimoMessageRequest, installId: string | null, sessionId = 'chat-1') {
  const out = sink();
  const run = await skills.mimo(request, { installId, clientVersion: null, signal: out.signal, sessionId, runId: `run_${++runs}` });
  return { stopReason: await run(out), events: out.events };
}

const systemText = (context: TranscriptContext) => {
  const first = context.messages[0];
  return first && first.role === 'system' ? getSystemMessageText(first) : '';
};
const toolNames = (context: TranscriptContext) => ((context.messages[0] as SystemMessage).toolsAdded ?? []).map((tool) => tool.name);
const toolResults = (context: TranscriptContext) =>
  context.messages.flatMap((m) => (m.role === 'toolResult' ? [m.content.map((c) => ('text' in c ? c.text : '')).join('')] : []));
const live: Situation = { ...tokyo, mode: 'live' };
const userTexts = (context: TranscriptContext) =>
  context.messages.flatMap((m) => (m.role === 'user' ? [typeof m.content === 'string' ? m.content : m.content.map((c) => ('text' in c ? c.text : '')).join('')] : []));

describe('trip memory section', () => {
  test('times are relative to the traveller\'s local now', () => {
    const section = tripMemorySection(
      {
        recent: [
          event({ time: new Date('2026-10-05T10:58:00Z'), localTime: '2026-10-05T19:58:00+09:00' }),
          event({ kind: 'place_confirmed', text: 'Senso-ji', meaning: null, placeName: 'Senso-ji', category: 'temple_shrine', time: new Date('2026-10-05T03:30:00Z'), localTime: '2026-10-05T12:30:00+09:00' }),
        ],
        similar: [
          event({ time: new Date('2026-10-04T10:42:00Z'), localTime: '2026-10-04T19:42:00+09:00' }),
          event({ city: 'Shanghai', time: new Date('2026-10-02T11:42:00Z'), localTime: '2026-10-02T19:42:00+08:00' }),
        ],
      },
      tokyo,
    );
    assert.ok(section);
    assert.match(section, /^<trip_memory>\nLatest on this trip, newest first:/);
    assert.match(section, /"when":"12 min ago","did":"showed a phrase","text":"麺かためでお願いします。","meaning":"Firm noodles, please.","at":"Menya Shono \(ramen\)"/);
    assert.match(section, /"when":"today 12:30","did":"was at","text":"Senso-ji","category":"temple_shrine"/);
    assert.match(section, /Earlier moments like this message:\n.*"when":"yesterday 19:42"/);
    assert.match(section, /"when":"3 days ago, 19:42".*"city":"Shanghai"/);
    assert.doesNotMatch(section, /"city":"Tokyo"/, 'the current city goes without saying');
    assert.match(section, /<\/trip_memory>$/);
  });

  test('nothing to remember is no section', () => {
    assert.equal(tripMemorySection({ recent: [], similar: [] }, tokyo), null);
  });

  test('events are embedded with their kind, place and both sides', () => {
    const [confirmed, shown, typed] = tripEvents.events;
    assert.equal(embeddingText(confirmed!), 'Was at Menya Shono (ramen), Tokyo');
    assert.equal(embeddingText(shown!), 'Showed a phrase at Menya Shono (ramen), Tokyo: 麺かためでお願いします。 = Firm noodles, please.');
    assert.equal(embeddingText(typed!), 'Typed in Translate in Tokyo: Is there a quiet bar nearby? = 近くに静かなバーはありますか？');
  });
});

describe('Mimo with trip memory', () => {
  test('the section is in the prompt, looked up by install id and message', async () => {
    const fake = fakeTiger();
    const h = harness(fake.tiger);
    h.script('You asked for firm noodles.');
    const { stopReason } = await ask(h.skills, mimoRequest, 'install-a');
    assert.equal(stopReason, 'stop');
    assert.deepEqual(fake.recalls, [{ installId: 'install-a', message: mimoRequest.message }]);
    assert.match(systemText(h.contexts[0]!), /<trip_memory>[\s\S]*Firm noodles, please\.[\s\S]*<\/trip_memory>/);
    assert.match(systemText(h.contexts[0]!), /trip_memory, when present, is what the traveller did earlier on this trip/);
  });

  test('the section is replaced each message, and dropped when there is nothing', async () => {
    let calls = 0;
    const fake = fakeTiger({ recall: async () => (++calls === 1 ? { recent: [event({})], similar: [] } : { recent: [], similar: [] }) });
    const h = harness(fake.tiger);
    h.script('First.', 'Second.');
    await ask(h.skills, mimoRequest, 'install-a');
    await ask(h.skills, { ...mimoRequest, message: 'Anything else?' }, 'install-a');
    assert.match(systemText(h.contexts[0]!), /<trip_memory>/);
    assert.doesNotMatch(systemText(h.contexts[1]!), /<trip_memory>/);
  });

  test('no install id, no lookup; a failed lookup still answers', async () => {
    const quiet = fakeTiger();
    const h1 = harness(quiet.tiger);
    h1.script('Hello.');
    await ask(h1.skills, mimoRequest, null);
    assert.equal(quiet.recalls.length, 0);
    assert.doesNotMatch(systemText(h1.contexts[0]!), /<trip_memory>/);

    const broken = fakeTiger({ recall: async () => Promise.reject(new Error('connection refused')) });
    const h2 = harness(broken.tiger);
    h2.script('Hello anyway.');
    const { stopReason, events } = await ask(h2.skills, mimoRequest, 'install-a');
    assert.equal(stopReason, 'stop');
    assert.equal(events.some((e) => e.type === 'text'), true);
    assert.doesNotMatch(systemText(h2.contexts[0]!), /<trip_memory>/);
  });

  test('a slow lookup is skipped after its time limit', { timeout: 5000 }, async () => {
    const slow = fakeTiger({ recall: () => new Promise((resolve) => setTimeout(() => resolve({ recent: [event({})], similar: [] }), 3000)) });
    const h = harness(slow.tiger);
    h.script('Quick answer.');
    const started = performance.now();
    await ask(h.skills, mimoRequest, 'install-a');
    assert.ok(performance.now() - started < 2500, 'waited for the slow lookup');
    assert.doesNotMatch(systemText(h.contexts[0]!), /<trip_memory>/);
  });
});

describe('saved chats', () => {
  test('a good run is saved without its system message, and a new server picks the chat up', async () => {
    const saved = new Map<string, SavedSession & { installId: string | null }>();
    const first = harness(fakeTiger({ saved }).tiger);
    first.script('Firm noodles, I think.');
    await ask(first.skills, mimoRequest, 'install-a', 'chat-9');
    await new Promise((resolve) => setImmediate(resolve));
    const chat = saved.get('chat-9');
    assert.ok(chat, 'the chat was saved');
    assert.equal(chat.installId, 'install-a');
    assert.deepEqual(
      chat.messages.map((m) => (m as { role: string }).role),
      ['user', 'assistant'],
    );

    // A restart: a fresh server, the same store.
    const second = harness(fakeTiger({ saved }).tiger);
    second.script('Yes, the same shop.');
    await ask(second.skills, { ...mimoRequest, message: 'Was that the same shop?' }, 'install-a', 'chat-9');
    assert.deepEqual(userTexts(second.contexts[0]!), [mimoRequest.message, 'Was that the same shop?']);
    assert.match(systemText(second.contexts[0]!), /You chat with the traveller/, 'the current prompt leads the restored chat');
    assert.equal(saved.get('chat-9')!.messages.length, 4);
  });

  test('another install never gets the chat; a failed run is not saved', async () => {
    const saved = new Map<string, SavedSession & { installId: string | null }>();
    const first = harness(fakeTiger({ saved }).tiger);
    first.script('Mine.');
    await ask(first.skills, mimoRequest, 'install-a', 'chat-x');
    await new Promise((resolve) => setImmediate(resolve));

    const other = harness(fakeTiger({ saved }).tiger);
    other.script('Fresh.');
    await ask(other.skills, { ...mimoRequest, message: 'Hi' }, 'install-b', 'chat-x');
    assert.deepEqual(userTexts(other.contexts[0]!), ['Hi']);

    const failing = harness(fakeTiger({ saved }).tiger);
    failing.script('ERROR');
    await assert.rejects(ask(failing.skills, mimoRequest, 'install-a', 'chat-y'));
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(saved.has('chat-y'), false);
  });
});

describe('POST /v1/trip-events', () => {
  const post = (app: ReturnType<typeof createApp>['app'], body: unknown, installId: string | null = 'install-a') =>
    app.request('/v1/trip-events', {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json', ...(installId ? { 'X-Install-Id': installId } : {}) },
      body: JSON.stringify(body),
    });

  test('fixture mode accepts events and stores none', async () => {
    const { app } = createApp(configFromEnv({ APP_TOKEN: TOKEN, MODEL: 'faux', FAUX_PACE: '0', LOG_REQUESTS: '0', CACHE_DIR: 'off' }));
    const res = await post(app, tripEvents);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { stored: 0 });
  });

  test('with Tiger, events are stored under the install id; without one, nothing is', async () => {
    const fake = fakeTiger();
    const { skills } = harness(fake.tiger);
    const { app } = createApp(configFromEnv({ APP_TOKEN: TOKEN, MODEL: 'faux', LOG_REQUESTS: '0', CACHE_DIR: 'off' }), { skills });
    const res = await post(app, tripEvents);
    const body = await res.json();
    assert.ok(Value.Check(TripEventsResponse, body));
    assert.deepEqual(body, { stored: 3 });
    assert.equal(fake.stored[0]?.installId, 'install-a');
    assert.deepEqual(fake.stored[0]?.events, tripEvents.events);

    assert.deepEqual(await (await post(app, tripEvents, null)).json(), { stored: 0 });
    assert.equal(fake.stored.length, 1);
  });

  test('a bad event is a 400', async () => {
    const { app } = createApp(configFromEnv({ APP_TOKEN: TOKEN, MODEL: 'faux', FAUX_PACE: '0', LOG_REQUESTS: '0', CACHE_DIR: 'off' }));
    const bad = { events: [{ ...tripEvents.events[0], kind: 'ate_lunch' }] };
    assert.equal((await post(app, bad)).status, 400);
    assert.equal((await post(app, { events: [] })).status, 400);
  });
});

describe('Mimo memory tools', () => {
  test('with Tiger, Mimo is offered recall_trip and remember; without, neither', async () => {
    const withTiger = harness(fakeTiger().tiger);
    withTiger.script('Hi.');
    await ask(withTiger.skills, mimoRequest, 'install-a');
    assert.deepEqual(toolNames(withTiger.contexts[0]!).filter((n) => n === 'recall_trip' || n === 'remember'), ['recall_trip', 'remember']);

    const without = harness(null);
    without.script('Hi.');
    await ask(without.skills, mimoRequest, 'install-a');
    assert.equal(toolNames(without.contexts[0]!).some((n) => n === 'recall_trip' || n === 'remember'), false);
  });

  test('remember in the same reply as the answer saves the note and ends the run there', async () => {
    const fake = fakeTiger();
    const h = harness(fake.tiger);
    h.script(fauxAssistantMessage([fauxText("Noted, I'll keep that in mind."), fauxToolCall('remember', { note: "Doesn't like spicy food" }, { id: 'r1' })], { stopReason: 'toolUse' }));
    const { stopReason, events } = await ask(h.skills, { ...mimoRequest, situation: live, message: "I can't do spicy food." }, 'install-a');
    assert.equal(stopReason, 'stop');
    assert.equal(h.faux.state.callCount, 1, 'no second turn just to say nothing');
    assert.equal(events.some((e) => e.type === 'tool_start'), false, 'the app gets no event for it');
    const note = fake.stored[0]?.events[0];
    assert.equal(fake.stored[0]?.installId, 'install-a');
    assert.deepEqual(note, { kind: 'told_mimo', at: live.localTime, text: "Doesn't like spicy food", place: { name: 'Menya Kaze', localName: '麺屋 風', category: 'ramen' }, city: 'Tokyo', countryCode: 'JP' });
  });

  test('remember on its own gets the answer on the next turn; in a preview it keeps no place', async () => {
    const fake = fakeTiger();
    const h = harness(fake.tiger);
    h.script(fauxAssistantMessage([fauxToolCall('remember', { note: 'Wants a quiet bar tonight' }, { id: 'r2' })], { stopReason: 'toolUse' }), 'Golden Gai has a few quiet ones.');
    const { stopReason } = await ask(h.skills, { ...mimoRequest, message: 'I want somewhere quiet tonight.' }, 'install-a');
    assert.equal(stopReason, 'stop');
    assert.equal(h.faux.state.callCount, 2);
    const note = fake.stored[0]?.events[0];
    assert.equal(note?.place, undefined, "a previewed place is somewhere they aren't");
    assert.equal(note?.city, 'Tokyo');
  });

  test('remember without an install id saves nothing', async () => {
    const fake = fakeTiger();
    const h = harness(fake.tiger);
    h.script(fauxAssistantMessage([fauxText('Sure.'), fauxToolCall('remember', { note: 'Likes tea' }, { id: 'r3' })], { stopReason: 'toolUse' }));
    await ask(h.skills, mimoRequest, null);
    assert.equal(fake.stored.length, 0);
  });

  test("recall_trip searches with Mimo's query and filters and hands back the moments", async () => {
    const fake = fakeTiger();
    const h = harness(fake.tiger);
    h.script(
      fauxAssistantMessage([fauxToolCall('recall_trip', { query: 'phrase about noodles', kind: 'phrase_shown', days: 3 }, { id: 'q1' })], { stopReason: 'toolUse' }),
      'You asked for firm noodles.',
    );
    const { stopReason } = await ask(h.skills, mimoRequest, 'install-a');
    assert.equal(stopReason, 'stop');
    assert.deepEqual(fake.searches, [{ installId: 'install-a', query: 'phrase about noodles', filter: { kind: 'phrase_shown', days: 3, limit: 8 } }]);
    assert.match(toolResults(h.contexts[1]!).join('\n'), /"did":"showed a phrase","text":"麺かためでお願いします。","meaning":"Firm noodles, please."/);
  });

  test('independent tools run in parallel', async () => {
    const order: string[] = [];
    const fake = fakeTiger({
      search: async (query) => {
        order.push(`start ${query}`);
        await new Promise((resolve) => setTimeout(resolve, 30));
        order.push(`end ${query}`);
        return [];
      },
    });
    const h = harness(fake.tiger);
    h.script(fauxAssistantMessage([fauxToolCall('recall_trip', { query: 'a' }, { id: 'p1' }), fauxToolCall('recall_trip', { query: 'b' }, { id: 'p2' })], { stopReason: 'toolUse' }), 'Nothing yet.');
    await ask(h.skills, mimoRequest, 'install-a');
    assert.deepEqual(order.slice(0, 2).sort(), ['start a', 'start b'], `ran one after the other: ${order.join(', ')}`);
  });

  test('past the tool budget, lookups are refused and Mimo answers with what it has', async () => {
    // Budget: 55% of a 1 s limit. The first lookup takes 0.6 s, so the second is refused.
    const fake = fakeTiger({ search: () => new Promise((resolve) => setTimeout(() => resolve([]), 600)) });
    const h = harness(fake.tiger, { MIMO_TIMEOUT_MS: '1000' });
    h.script(
      fauxAssistantMessage([fauxToolCall('recall_trip', { query: 'first' }, { id: 't1' })], { stopReason: 'toolUse' }),
      fauxAssistantMessage([fauxToolCall('recall_trip', { query: 'second' }, { id: 't2' })], { stopReason: 'toolUse' }),
      'Here is what I have.',
    );
    const { stopReason } = await ask(h.skills, mimoRequest, 'install-a');
    assert.equal(stopReason, 'tool_limit');
    assert.equal(fake.searches.length, 1);
    assert.match(toolResults(h.contexts[2]!).join('\n'), /Out of time to look things up/);
  });
});
