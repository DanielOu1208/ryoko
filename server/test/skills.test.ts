// W7: the model-backed skills, offline. Model calls go through pi-ai's faux
// provider (scripted responses), web search through a stub. Run: pnpm --dir server test

import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createModels } from '@earendil-works/pi-ai/models';
import { fauxAssistantMessage, fauxProvider, fauxText, fauxThinking, fauxToolCall, getSystemMessageText, type AssistantMessage, type FauxResponseStep, type TranscriptContext } from '@earendil-works/pi-ai';
import { Value } from 'typebox/value';
import {
  AllergyCardResponse,
  DiscoverResponse,
  PlaceCardResponse,
  profileVersion,
  SseEvent,
  type AllergyCardRequest,
  type DiscoverRequest,
  type MimoMessageRequest,
  type NearbyPlace,
  type Phrase,
  type PlaceCardRequest,
  type Profile,
  type Situation,
} from '@ryoko/contracts';
import { createApp } from '../src/app.ts';
import { cacheKey, ResponseCache } from '../src/cache.ts';
import { configFromEnv, modelsFromEnv, ConfigError, type Config } from '../src/config.ts';
import { ApiError } from '../src/errors.ts';
import { EXAMPLES_DIR } from '../src/fixtures.ts';
import { Budget } from '../src/llm/budget.ts';
import { costOf, createLlm, providerErrorText, staticLlm } from '../src/llm/registry.ts';
import { generateTyped, parseJsonObject } from '../src/llm/typed.ts';
import { allergyCardModelOutput, finalizeAllergyCard } from '../src/skills/allergy-card.ts';
import { ABOUT_ME_RULE, allowedBasis, languageInfo, promptProfile, timeFacts } from '../src/skills/context.ts';
import {
  DISCOVER_PROMPT_VERSION,
  discoverGrounding,
  type DiscoverModelOutput,
  discoverSystem,
  discoverUser,
  finalizeDiscover,
  geohash,
  nearbyKey,
  nearbyPlaces,
  onNearbyList,
} from '../src/skills/discover.ts';
import type { SearchResponse } from '../src/skills/mimo/exa.ts';
import { PhraseStream } from '../src/skills/mimo/phrase-stream.ts';
import { MIMO_SYSTEM, mimoSections } from '../src/skills/mimo/prompt.ts';
import { prepareShowPlaces } from '../src/skills/mimo/tools.ts';
import { createModelSkills, discoverKey, placeKey, type ModelSkills } from '../src/skills/model.ts';
import { finalizePlaceCard, placeCardSystem, placeCardUser, type PlaceCardModelOutput } from '../src/skills/place-card.ts';
import { toPinyin } from '../src/skills/romanize.ts';
import { hazardsFor, unsafeMention } from '../src/skills/safety.ts';
import type { MimoRun } from '../src/skills/types.ts';
import type { SseSink } from '../src/sse.ts';

const TOKEN = 'test-token-skills';
const example = <T>(file: string): T => JSON.parse(readFileSync(join(EXAMPLES_DIR, file), 'utf8')) as T;
const seed = example<Profile>('profile.seed.json');
const shanghai = example<Situation>('situation.shanghai-cafe.json');
const tokyo = example<Situation>('situation.tokyo-ramen.json');
const placeCardRequest: PlaceCardRequest = { profile: seed, situation: shanghai };
const mimoRequest: MimoMessageRequest = { ...example<MimoMessageRequest>('mimo-message.request.json'), situation: shanghai, nearby: [] };
const discoverExample = example<DiscoverRequest>('discover.request.json');
/** The example without its nearby list: names from memory, as before grounding. */
const { nearby: _exampleNearby, ...discoverFromMemory } = discoverExample;

function withProfile(changes: Partial<Profile>): Profile {
  const next = { ...seed, ...changes };
  return { ...next, version: profileVersion(next) };
}

function testConfig(env: Record<string, string> = {}): Config {
  return configFromEnv({ APP_TOKEN: TOKEN, MODEL: 'faux', LOG_REQUESTS: '0', CACHE_DIR: 'off', ...env });
}

/** pi-ai's faux provider behind the skills, plus helpers to script it. */
function harness(options: { env?: Record<string, string>; search?: (query: string, signal?: AbortSignal) => Promise<SearchResponse>; budget?: Budget; cache?: ResponseCache } = {}) {
  const faux = fauxProvider({ provider: 'faux-test', models: [{ id: 'faux-1', cost: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0 } }], tokenSize: { min: 1, max: 2 } });
  const models = createModels();
  models.setProvider(faux.provider);
  const llm = staticLlm(models, () => faux.getModel());
  const budget = options.budget ?? new Budget({ limitUsd: 5, file: null });
  const contexts: TranscriptContext[] = [];
  const skills = createModelSkills(testConfig(options.env), {
    llm,
    budget,
    cache: options.cache ?? new ResponseCache({ file: null }),
    search: options.search ?? null,
    log: () => {},
  });
  /** Scripts the next responses; each records the context it was asked with. */
  const script = (...steps: (AssistantMessage | ((context: TranscriptContext, signal?: AbortSignal) => AssistantMessage | Promise<AssistantMessage>))[]) =>
    faux.setResponses(
      steps.map((step): FauxResponseStep => (context, streamOptions) => {
        contexts.push(context);
        return typeof step === 'function' ? step(context, streamOptions?.signal) : step;
      }),
    );
  return { faux, llm, skills, budget, contexts, script };
}

const json = (value: unknown) => fauxAssistantMessage(JSON.stringify(value));

function systemText(context: TranscriptContext): string {
  const first = context.messages[0];
  return first && first.role === 'system' ? getSystemMessageText(first) : '';
}

function lastUserText(context: TranscriptContext): string {
  const users = context.messages.filter((m) => m.role === 'user');
  const last = users[users.length - 1];
  if (!last || last.role !== 'user') return '';
  return typeof last.content === 'string' ? last.content : last.content.map((c) => (c.type === 'text' ? c.text : '')).join('');
}

const goodCard: PlaceCardModelOutput = {
  phrases: [
    { local: '一杯招牌拿铁，少糖。', romanization: 'wrong pinyin', gloss: 'One house latte, less sugar.', because: 'You like it less sweet', basis: ['taste'] },
    { local: '我对花生过敏。这个里面有花生吗？', romanization: null, gloss: "I'm allergic to peanuts. Is there peanut in this?", because: 'Your peanut allergy is serious', basis: ['allergy'] },
  ],
  tips: [{ text: 'No tipping here, unlike Canada.', basis: ['nationality'] }],
};

async function rejectsWith(promise: Promise<unknown>, code: string): Promise<ApiError> {
  try {
    await promise;
  } catch (err) {
    assert.ok(err instanceof ApiError, `expected an ApiError, got ${String(err)}`);
    assert.equal(err.code, code, err.message);
    return err;
  }
  assert.fail(`expected ${code}`);
}

// --- config (W7.1) ---

describe('per-skill model config', () => {
  test('defaults to GMI DeepSeek V4.1 Flash with thinking off for every skill', () => {
    const specs = modelsFromEnv('gmi', {});
    assert.ok(specs);
    for (const spec of Object.values(specs)) assert.deepEqual(spec, { provider: 'gmi', modelId: 'deepseek-ai/DeepSeek-V4.1-Flash', reasoning: 'off' });
  });

  test('GMI_MODEL, provider:modelId overrides per skill, and reasoning per skill', () => {
    const specs = modelsFromEnv('gmi', {
      GMI_MODEL: 'Qwen/Qwen3.8-Flash',
      MODEL_MIMO: 'gmi:deepseek-ai/DeepSeek-V4.1-Flash',
      MODEL_DISCOVER: 'google',
      MODEL_DISCOVER_REASONING: 'minimal',
    });
    assert.ok(specs);
    assert.equal(specs.placeCard.modelId, 'Qwen/Qwen3.8-Flash');
    assert.equal(specs.mimo.modelId, 'deepseek-ai/DeepSeek-V4.1-Flash');
    assert.deepEqual(specs.discover, { provider: 'google', modelId: 'gemini-3.8-flash', reasoning: 'minimal' });
  });

  test('the registry resolves GMI and (lazily) Google models, and a missing key is a 503 model_error', async () => {
    const llm = createLlm(configFromEnv({ APP_TOKEN: 'x', CACHE_DIR: 'off', GMI_API_KEY: 'test-key', GEMINI_API_KEY: 'test-key', MODEL_DISCOVER: 'google' }));
    const gmi = await llm.forSkill('placeCard');
    assert.equal(gmi.key, 'gmi:deepseek-ai/DeepSeek-V4.1-Flash');
    assert.deepEqual(gmi.model.thinkingLevelMap, { off: 'none' });
    assert.equal(gmi.options.reasoning, undefined); // thinking off
    const google = await llm.forSkill('discover');
    assert.equal(google.key, 'google:gemini-3.8-flash@low'); // the thinking level is part of the cache key
    assert.equal(google.options.reasoning, 'low');
    const keyless = createLlm(configFromEnv({ APP_TOKEN: 'x', CACHE_DIR: 'off' }));
    const error = await rejectsWith(keyless.forSkill('mimo'), 'model_error');
    assert.equal(error.status, 503);
  });

  test('MODEL=faux has no model specs; unknown providers fail at startup', () => {
    assert.equal(modelsFromEnv('faux', {}), null);
    assert.throws(() => configFromEnv({ APP_TOKEN: 'x', MODEL_MIMO: 'openai:gpt' }), ConfigError);
    assert.throws(() => configFromEnv({ APP_TOKEN: 'x', MODEL_MIMO_REASONING: 'lots' }), ConfigError);
  });
});

// --- context, checks, romanization ---

describe('prompt context', () => {
  test('allowedBasis lists only filled-in inputs', () => {
    assert.deepEqual(allowedBasis(seed, shanghai), ['place', 'localTime', 'personality', 'nationality', 'allergy', 'favourites', 'taste']);
    assert.equal(allowedBasis(seed, { ...shanghai, place: null }).includes('place'), true); // the city is the place
    const bare = withProfile({ nationality: null, allergies: [], favourites: { foods: [], drinks: [] }, taste: { sweetness: 2, spice: null }, personality: { rhythm: 'night_owl', food: null, budget: null, vibe: null }, diet: null, dietNotes: '' });
    assert.deepEqual(allowedBasis(bare, shanghai), ['place', 'localTime']);
  });

  test('the compacted profile drops the version, nulls and empties, and night owl for the place card', () => {
    const profile = withProfile({ personality: { rhythm: 'night_owl', food: 'local_favourite', budget: null, vibe: null } });
    const view = promptProfile(profile, 'place-card');
    assert.equal('version' in view, false);
    assert.equal('diet' in view, false);
    assert.equal('dietNotes' in view, false);
    assert.equal('homeBase' in view, false);
    assert.deepEqual(view.personality, { food: 'local_favourite' });
    assert.deepEqual(view.favourites, { drinks: ['fruit tea'] });
    assert.deepEqual((promptProfile(profile, 'discover').personality as Record<string, unknown>).rhythm, 'night_owl');
  });

  test('aboutMe reaches Mimo, the place card and discover only when there is text, trimmed and last', () => {
    const profile = withProfile({ aboutMe: '  Chemistry teacher, loves jazz bars.\n' });
    for (const use of ['mimo', 'place-card', 'discover'] as const) {
      assert.equal('aboutMe' in promptProfile(seed, use), false, `${use}: absent when the profile has none`);
      assert.equal('aboutMe' in promptProfile(withProfile({ aboutMe: '   ' }), use), false, `${use}: whitespace only`);
      const view = promptProfile(profile, use);
      assert.equal(view.aboutMe, 'Chemistry teacher, loves jazz bars.', use);
      assert.equal(Object.keys(view).at(-1), 'aboutMe', `${use}: the traveller's own words come last`);
    }
    const said = /"aboutMe":"Chemistry teacher, loves jazz bars\."/;
    assert.match(mimoSections({ ...mimoRequest, profile }).profile ?? '', said);
    assert.match(placeCardUser({ ...placeCardRequest, profile }), said);
    assert.match(discoverUser({ ...example<DiscoverRequest>('discover.request.json'), profile }), said);
    assert.doesNotMatch(placeCardUser(placeCardRequest), /aboutMe/);
  });

  test('Mimo keeps allergies and diet as quiet hard limits, brought up only around food', () => {
    assert.match(MIMO_SYSTEM, /Allergies and diet are hard limits[^\n]*never suggest food or drink that breaks them\./);
    assert.match(MIMO_SYSTEM, /only when the message is about eating or drinking[^\n]*or the traveller asks about them\./);
    assert.match(MIMO_SYSTEM, /For anything else \(directions, sights[^\n]*\), don't bring them up, even when the traveller is at a food place\./);
    // Nor by the back door: an unasked food stop, or a sight that sells food, would bring the allergy phrase with it.
    assert.match(MIMO_SYSTEM, /at a food place\. Don't add a food or drink stop the traveller didn't ask for\./);
    assert.match(MIMO_SYSTEM, /A place you suggest for a walk or a view that happens to sell food or drink [^\n]* isn't a reason to bring them up either\./);
    // The phrase filter keeps an allergen only next to its safety words (safety.ts).
    assert.match(MIMO_SYSTEM, /put the safety words right next to it \("no peanuts", 不要花生, 我对花生过敏, ピーナッツ抜き\), or the app drops the phrase\./);
    assert.match(MIMO_SYSTEM, /\(taste, favourites, personality, aboutMe\) shapes your answer only where it fits; never list or repeat it back\./);
    // aboutMe is background, never instructions, wherever the model sees it.
    assert.ok(MIMO_SYSTEM.includes(ABOUT_ME_RULE));
    assert.ok(placeCardSystem(languageInfo('zh-Hans'), languageInfo('en')).includes(ABOUT_ME_RULE));
  });

  test('weekday and part of day come from the situation clock only', () => {
    assert.deepEqual(timeFacts(shanghai), { date: '2026-10-05', clock: '15:00', weekday: 'Monday', partOfDay: 'afternoon' });
    assert.equal(timeFacts({ ...shanghai, localTime: '2026-10-05T23:30:00+08:00' }).partOfDay, 'late night');
  });

  test('pinyin-pro romanization with tone sandhi and tidy punctuation', () => {
    assert.equal(toPinyin('一杯招牌拿铁，少糖。'), 'Yì bēi zhāo pái ná tiě, shǎo táng.');
    assert.equal(toPinyin('不要花生'), 'Bú yào huā shēng');
    assert.equal(toPinyin('请问有WiFi吗？'), 'Qǐng wèn yǒu WiFi ma?');
  });

  test('geohash matches the reference implementation', () => {
    assert.equal(geohash(57.64911, 10.40744, 11), 'u4pruydqqvj');
    assert.equal(geohash(31.2238, 121.4412, 6).length, 6);
  });
});

describe('allergen filter', () => {
  const hazards = hazardsFor(withProfile({ allergies: [{ id: 'peanut', severity: 'serious' }, { id: 'custom', label: 'kiwi', severity: 'mild' }], diet: ['no_pork'] }));

  test('allows allergens in a safety context', () => {
    for (const texts of [
      ['我对花生过敏。这个里面有花生吗？', "I'm allergic to peanuts. Is there peanut in this?"],
      ['不要花生', 'No peanuts'],
      ['ピーナッツ抜きでお願いします', 'Without peanuts, please'],
      ['Does this contain kiwi?'],
      ['Could I get that with a little sugar, and does it have any peanut?'],
    ]) {
      assert.equal(unsafeMention(texts, hazards), null, texts.join(' / '));
    }
  });

  test('flags suggestions that contain them', () => {
    assert.equal(unsafeMention(['一份花生酱拌面', 'One peanut sauce noodles'], hazards), 'peanut');
    assert.equal(unsafeMention(['Try the kiwi smoothie here'], hazards), 'kiwi');
    assert.equal(unsafeMention(['Can I get the peanut noodles?'], hazards), 'peanut');
    assert.equal(unsafeMention(['叉烧饭一份', 'One char siu rice'], hazards), 'no_pork');
    assert.equal(unsafeMention(['一杯少糖拿铁'], hazardsFor(seed)), null);
  });

  test('a cue elsewhere in the item does not exempt an order (regression)', () => {
    // A negation or question about something else used to exempt the whole item.
    assert.equal(unsafeMention(['我要一杯花生奶茶，不要冰', 'A peanut milk tea, no ice please'], hazards), 'peanut');
    assert.equal(unsafeMention(['有花生酱面吗？'], hazards), 'peanut');
    assert.equal(unsafeMention(['ピーナッツラテをください。氷なしで'], hazards), 'peanut');
    assert.equal(unsafeMention(['不要冰，花生奶茶'], hazards), 'peanut');
    assert.equal(unsafeMention(['No ice, and a peanut latte please'], hazards), 'peanut');
    assert.equal(unsafeMention(['Do you have peanut noodles?'], hazards), 'peanut');
    assert.equal(unsafeMention(['Is there a peanut noodle dish?'], hazards), 'peanut');
    assert.equal(unsafeMention(['有没有花生酱面？'], hazards), 'peanut');
    assert.equal(unsafeMention(['ピーナッツが入っているラテをください'], hazards), 'peanut');
  });

  test('a cue covers the mention it governs and the rest of its list', () => {
    const several = hazardsFor(withProfile({ allergies: [{ id: 'peanut', severity: 'serious' }, { id: 'sesame', severity: 'serious' }, { id: 'egg', severity: 'mild' }, { id: 'milk', severity: 'mild' }] }));
    for (const texts of [
      ['No peanuts or sesame, please'],
      ['我对花生和芝麻过敏'],
      ['卵と乳製品は食べられません'],
      ['ピーナッツは入っていますか？'],
      ['请不要放任何花生'],
      ['这道菜加了花生酱吗？'],
      ['Is it peanut-free?'],
      ['I have a peanut allergy'],
      // Seen in the evals on the real model.
      ['ピーナッツは使っていますか', 'Do you use peanuts?'],
      ['这个里面有花生和芝麻吗？我对这两个都过敏。', 'Does this have peanuts or sesame? I am allergic to both.'],
      ['我对花生和芝麻严重过敏，这些菜里有吗', 'I have severe peanut and sesame allergies, do these dishes contain them?'],
      ['I have a peanut allergy. Does anything here contain peanuts?', 'Tell staff about your peanut allergy and ask about peanuts'],
      ['ピーナッツに重度のアレルギーがあります'],
      ['Does this have any peanuts in it?', 'Ask whether the item contains peanuts.'],
      ['Do you have any fruit teas, and none with peanuts?', 'Asking about fruit teas and whether any contain peanuts.'],
    ]) {
      assert.equal(unsafeMention(texts, several), null, texts.join(' / '));
    }
    assert.equal(unsafeMention(['我对芝麻过敏，来一份花生糖'], several), 'peanut');
    assert.equal(unsafeMention(['Ask about the peanut noodles'], several), 'peanut');
  });
});

describe('place-card checks', () => {
  test('a good card gets pinyin from pinyin-pro, ids, the device local name and passes the contract', () => {
    const result = finalizePlaceCard(placeCardRequest, structuredClone(goodCard), new Date('2026-10-03T12:00:00Z'));
    assert.ok(result.ok);
    assert.ok(Value.Check(PlaceCardResponse, result.value));
    assert.equal(result.value.phrases[0]?.romanization, 'Yì bēi zhāo pái ná tiě, shǎo táng.');
    assert.equal(result.value.placeNameLocal, '梧桐咖啡');
    assert.equal(result.value.language, 'zh-Hans');
    assert.match(result.value.phrases[0]?.id ?? '', /^pc-[0-9a-f]{10}-1$/);
  });

  test('drops phrases with a basis outside allowedBasis, a long because, Latin in Chinese, a field name or an allergen', () => {
    const extra = [
      { local: '我要一杯奶茶', romanization: null, gloss: 'A milk tea', because: 'Remembering your last order', basis: ['memory'] },
      { local: '我要一杯拿铁', romanization: null, gloss: 'A latte', because: 'one two three four five six seven eight nine ten eleven twelve thirteen', basis: ['place'] },
      { local: '一杯latte', romanization: null, gloss: 'A latte', because: 'Coffee time', basis: ['place'] },
      { local: '招牌咖啡', romanization: null, gloss: 'House coffee', because: 'Fits local_favourite', basis: ['personality'] },
      { local: '一份花生酥', romanization: null, gloss: 'A peanut brittle', because: 'Popular snack here', basis: ['place'] },
      { local: '有爵士乐吗', romanization: null, gloss: 'Is there jazz?', because: 'Your aboutMe mentions jazz', basis: ['place'] },
    ] as PlaceCardModelOutput['phrases'];
    const result = finalizePlaceCard(placeCardRequest, { ...structuredClone(goodCard), phrases: [...goodCard.phrases, ...extra] });
    assert.ok(result.ok);
    assert.equal(result.value.phrases.length, 2);
    assert.equal(result.dropped.length, 6);
    assert.match(result.dropped.join('\n'), /"memory" isn't in allowedBasis/);
    assert.match(result.dropped.join('\n'), /more than 8 words/);
    assert.match(result.dropped.join('\n'), /Latin letters/);
    assert.equal(result.dropped.filter((line) => /field name/.test(line)).length, 2, 'local_favourite and aboutMe');
    assert.match(result.dropped.join('\n'), /peanut/);
  });

  test('too few good phrases asks for a retry with the problems listed', () => {
    const result = finalizePlaceCard(placeCardRequest, { ...structuredClone(goodCard), phrases: [goodCard.phrases[0]!, { ...goodCard.phrases[1]!, basis: ['diet'] }] });
    assert.equal(result.ok, false);
    assert.ok(!result.ok && result.issues.some((i) => i.includes('"diet" isn\'t in allowedBasis')));
  });

  test('Japanese keeps the model romaji; English has none', () => {
    const ja = finalizePlaceCard(
      { profile: seed, situation: tokyo },
      {
        phrases: [
          { local: '食券はどこで買いますか', romanization: 'Shokken wa doko de kaimasu ka', gloss: 'Where do I buy a ticket?', because: 'Ticket machine shops are common here', basis: ['place'] },
          { local: 'おすすめは何ですか', romanization: 'Osusume wa nan desu ka', gloss: 'What do you recommend?', because: 'You like the local favourite', basis: ['personality'] },
        ],
        tips: [{ text: 'Buy a ticket at the machine first.', basis: ['place'] }],
      },
    );
    assert.ok(ja.ok);
    assert.equal(ja.value.phrases[0]?.romanization, 'Shokken wa doko de kaimasu ka');
    assert.equal(languageInfo('en').romanization, 'none');
  });
});

// --- typed output (W7.2) ---

describe('typed output', () => {
  test('parses JSON inside code fences or with stray text', () => {
    assert.deepEqual(parseJsonObject('```json\n{"a":1}\n```'), { a: 1 });
    assert.deepEqual(parseJsonObject('Here you go: {"a":{"b":2}} hope it helps'), { a: { b: 2 } });
  });

  test('a valid first reply is accepted; the schema is in the prompt', async () => {
    const h = harness();
    h.script(fauxAssistantMessage('```json\n' + JSON.stringify(goodCard) + '\n```'));
    const card = await h.skills.placeCard(placeCardRequest, { installId: null, clientVersion: null, signal: new AbortController().signal });
    assert.ok(Value.Check(PlaceCardResponse, card));
    assert.equal(h.faux.state.callCount, 1);
    assert.match(systemText(h.contexts[0]!), /must match this JSON Schema/);
    assert.match(lastUserText(h.contexts[0]!), /"allowedBasis"/);
    assert.doesNotMatch(lastUserText(h.contexts[0]!), /"version"|"homeBase"/);
  });

  test('an invalid reply is retried once with the problems listed', async () => {
    const h = harness();
    h.script(fauxAssistantMessage('{"phrases": "nope"}'), json(goodCard));
    const card = await h.skills.placeCard(placeCardRequest, { installId: null, clientVersion: null, signal: new AbortController().signal });
    assert.equal(card.phrases.length, 2);
    assert.equal(h.faux.state.callCount, 2);
    assert.match(lastUserText(h.contexts[1]!), /That reply had problems/);
  });

  test('two invalid replies are 502 invalid_model_output, and nothing is cached', async () => {
    const h = harness();
    h.script(fauxAssistantMessage('not json'), fauxAssistantMessage('still not json'), json(goodCard));
    const error = await rejectsWith(h.skills.placeCard(placeCardRequest, { installId: null, clientVersion: null, signal: new AbortController().signal }), 'invalid_model_output');
    assert.equal(error.status, 502);
    assert.equal(h.skills.cache.size, 0);
    // The next request generates again (errors are never cached).
    await h.skills.placeCard(placeCardRequest, { installId: null, clientVersion: null, signal: new AbortController().signal });
    assert.equal(h.faux.state.callCount, 3);
  });

  test('a provider error is model_error; running out of time is timeout', async () => {
    const h = harness({ env: { SKILL_TIMEOUT_MS: '150' } });
    h.script(fauxAssistantMessage([], { stopReason: 'error', errorMessage: 'upstream 500' }));
    await rejectsWith(h.skills.discover(example<DiscoverRequest>('discover.request.json'), { installId: null, clientVersion: null, signal: new AbortController().signal }), 'model_error');
    h.script(async (_context, signal) => {
      await new Promise((resolve) => {
        const timer = setTimeout(resolve, 2000);
        signal?.addEventListener('abort', () => (clearTimeout(timer), resolve(undefined)), { once: true });
      });
      return json(goodCard);
    });
    const error = await rejectsWith(h.skills.placeCard(placeCardRequest, { installId: null, clientVersion: null, signal: new AbortController().signal }), 'timeout');
    assert.equal(error.status, 504);
  });

  test('generateTyped records cost into the budget from the model prices', async () => {
    const h = harness();
    h.script(json(goodCard));
    await h.skills.placeCard(placeCardRequest, { installId: null, clientVersion: null, signal: new AbortController().signal });
    assert.ok(h.budget.spentTodayUsd > 0);
    assert.equal(costOf({ cost: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0 } }, { input: 1_000_000, output: 500_000, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }), 2);
  });

  test('generateTyped is usable on its own', async () => {
    const h = harness();
    h.script(fauxAssistantMessage('{"title":"アレルギーについて","items":[{"local":"そばを食べられません。","home":"I must not eat buckwheat."}],"requestLocal":"そばは入っていますか？","requestHome":"Does this contain buckwheat?","romanization":"Soba wa haitte imasu ka?"}'));
    const request = example<AllergyCardRequest>('allergy-card.request.json');
    const card = await generateTyped({
      llm: h.llm,
      budget: h.budget,
      skill: 'allergyCard',
      label: 'allergy card',
      schema: allergyCardModelOutput(1),
      system: 'test',
      user: 'test',
      maxTokens: 100,
      timeoutMs: 5000,
      finalize: (output) => finalizeAllergyCard(request, output),
    });
    assert.ok(Value.Check(AllergyCardResponse, card));
    assert.equal(card.reviewed, false);
    assert.equal(card.items[0]?.severity, 'life_threatening');
    assert.equal(card.romanization, 'Soba wa haitte imasu ka?');
  });
});

// --- discover and allergy card ---

describe('discover and allergy-card skills', () => {
  const places = [
    { name: "Jing'an Park", localName: '静安公园', category: 'park', why: 'Old plane trees and shady benches', bestTime: 'Afternoons' },
    { name: 'Yuyuan Road', localName: '愚园路', category: 'shopping', why: 'Leafy street of small shops' },
    { name: 'Fengsheng Li', localName: '丰盛里', category: 'shopping', why: 'Restored lane with tea stalls' },
    { name: 'Changde Apartment', localName: '常德公寓', category: 'other', why: "Eileen Chang's old building" },
    { name: 'Shanghai Natural History Museum', localName: '上海自然博物馆', category: 'museum', why: 'Big, cool and quiet on weekdays' },
    { name: 'Peanut Noodle House', localName: '花生面馆', category: 'restaurant', why: 'Famous peanut sauce noodles' },
    { name: "Jing'an Park", localName: '静安公园', category: 'park', why: 'Duplicate' },
    { name: 'Too Long', localName: '太长', category: 'other', why: 'x'.repeat(70) },
  ];

  test('discover without a nearby list drops duplicates, allergen places and long lines, and passes the contract', async () => {
    const h = harness();
    h.script(json({ places }));
    const result = await h.skills.discover(discoverFromMemory, { installId: null, clientVersion: null, signal: new AbortController().signal });
    assert.ok(Value.Check(DiscoverResponse, result));
    assert.deepEqual(result.places.map((p) => p.name), ["Jing'an Park", 'Yuyuan Road', 'Fengsheng Li', 'Changde Apartment', 'Shanghai Natural History Museum']);
  });

  test('allergy-card keeps the request severity, sets reviewed false and fills pinyin for Chinese', async () => {
    const h = harness();
    h.script(json({ title: '关于我的过敏', items: [{ local: '我不能吃猕猴桃。', home: 'I must not eat kiwi.' }], requestLocal: '这道菜有猕猴桃吗？', requestHome: 'Does this dish contain kiwi?' }));
    const card = await h.skills.allergyCard(example<AllergyCardRequest>('allergy-card.zh-hans.request.json'), { installId: null, clientVersion: null, signal: new AbortController().signal });
    assert.ok(Value.Check(AllergyCardResponse, card));
    assert.equal(card.items[0]?.severity, 'serious');
    assert.equal(card.items[0]?.allergenId, 'custom');
    assert.equal(card.reviewed, false);
    assert.equal(card.romanization, 'Zhè dào cài yǒu mí hóu táo ma?');
  });

  test('allergy-card retries when the home line names a different allergen', async () => {
    const h = harness();
    h.script(
      json({ title: '关于我的过敏', items: [{ local: '我不能吃芒果。', home: 'I must not eat mango.' }], requestLocal: '有芒果吗？', requestHome: 'Is there mango?' }),
      json({ title: '关于我的过敏', items: [{ local: '我不能吃猕猴桃。', home: 'I must not eat kiwi.' }], requestLocal: '有猕猴桃吗？', requestHome: 'Is there kiwi?' }),
    );
    const card = await h.skills.allergyCard(example<AllergyCardRequest>('allergy-card.zh-hans.request.json'), { installId: null, clientVersion: null, signal: new AbortController().signal });
    assert.equal(card.items[0]?.home, 'I must not eat kiwi.');
    assert.equal(h.faux.state.callCount, 2);
  });
});

// --- discover grounded in the nearby places (design #54) ---

describe('discover grounded in nearby places', () => {
  const ctx = () => ({ installId: null, clientVersion: null, signal: new AbortController().signal });
  /** One pick per place on the example's nearby list (Wutong Coffee, Jing'an Temple, Jing'an Park, Wujiang Road, Fuxing Park). */
  const listed = [
    { name: 'Wutong Coffee', localName: '梧桐咖啡', category: 'cafe', why: 'A quiet latte under the plane trees' },
    { name: "Jing'an Temple", localName: '静安寺', category: 'temple_shrine', why: 'Golden halls in the middle of the city' },
    { name: "Jing'an Park", localName: '静安公园', category: 'park', why: 'Shady benches and old plane trees' },
    { name: 'Wujiang Road snack street', localName: '吴江路小吃街', category: 'restaurant', why: 'Pan-fried buns and quick local snacks' },
    { name: 'Fuxing Park', localName: '复兴公园', category: 'park', why: 'Locals dancing and playing cards' },
  ];
  const unlisted = [
    { name: 'Yuyuan Road', localName: '愚园路', category: 'shopping', why: 'Leafy street of small shops' },
    { name: 'Changde Apartment', localName: '常德公寓', category: 'other', why: "Eileen Chang's old building" },
    { name: 'Fengsheng Li', localName: '丰盛里', category: 'shopping', why: 'Restored lane with tea stalls' },
    { name: 'Shanghai Natural History Museum', localName: '上海自然博物馆', category: 'museum', why: 'Big, cool and quiet on weekdays' },
  ];
  type Pick = (typeof listed)[number];
  const output = (picks: Pick[]) => ({ places: picks }) as DiscoverModelOutput;

  test('the prompt carries the nearby names and the pick-from-the-list rules', () => {
    const grounding = discoverGrounding(discoverExample);
    assert.deepEqual(grounding, { listed: 5, allowance: 2 });
    const system = discoverSystem(languageInfo('zh-Hans'), languageInfo('en'), grounding);
    assert.match(system, /Pick your 5–8 places from it/);
    assert.match(system, /at most 2 places that aren't on the list/);
    assert.match(system, /independent and local spots over chains/);
    assert.match(system, /Inventing or guessing a place is far worse than a short list/);
    assert.doesNotMatch(system, /The list is short/);
    const user = JSON.parse(discoverUser(discoverExample)) as { nearby: { name: string; localName?: string }[] };
    assert.deepEqual(user.nearby.map((p) => p.name), ['Wutong Coffee', "Jing'an Temple", "Jing'an Park", 'Wujiang Road snack street', 'Fuxing Park']);
    assert.equal(user.nearby[1]?.localName, '静安寺');
  });

  test('without nearby places (absent or empty) the prompt has no nearby section', () => {
    for (const request of [discoverFromMemory, { ...discoverExample, nearby: [] }]) {
      assert.equal(discoverGrounding(request), null);
      assert.doesNotMatch(discoverSystem(languageInfo('zh-Hans'), languageInfo('en'), discoverGrounding(request)), /nearby|on the list/);
      assert.doesNotMatch(discoverUser(request), /nearby/);
    }
  });

  test('the model sees the list nearest first, once per name; a short list may be filled up', async () => {
    const nearby: NearbyPlace[] = [
      { name: 'Fuxing Park', localName: '复兴公园', category: 'park', distanceMeters: 1450 },
      { name: 'Wutong Coffee', localName: '梧桐咖啡', category: 'cafe', distanceMeters: 40 },
      { name: 'wutong  coffee', category: 'cafe', distanceMeters: 900 },
    ];
    const request = { ...discoverExample, nearby };
    assert.deepEqual(nearbyPlaces(request).map((p) => p.distanceMeters), [40, 1450]);
    const grounding = discoverGrounding(request);
    assert.deepEqual(grounding, { listed: 2, allowance: 3 });
    assert.match(discoverSystem(languageInfo('zh-Hans'), languageInfo('en'), grounding), /at most 3 places that aren't on the list[\s\S]*The list is short/);

    const h = harness();
    h.script(json(output([listed[0]!, listed[4]!, ...unlisted.slice(0, 3)])));
    const result = await h.skills.discover(request, ctx());
    assert.equal(result.places.length, 5);
    assert.match(systemText(h.contexts[0]!), /Pick your 5–8 places from it/);
    assert.match(lastUserText(h.contexts[0]!), /"nearby":\[\{"name":"Wutong Coffee"/);
  });

  test('a pick matches the list ignoring case, spaces and punctuation, or by containment either way', () => {
    const nearby = nearbyPlaces(discoverExample);
    assert.ok(onNearbyList({ name: 'JING’AN  park' }, nearby));
    assert.ok(onNearbyList({ name: 'Wutong Coffee Roasters' }, nearby), 'the pick contains the listed name');
    assert.ok(onNearbyList({ name: 'Fuxing' }, nearby), 'the listed name contains the pick');
    assert.ok(onNearbyList({ name: 'Jingan Temple Shanghai', localName: '静安寺' }, nearby));
    assert.ok(onNearbyList({ name: 'Old Temple', localName: '静安寺' }, nearby), 'the local name matches');
    assert.ok(!onNearbyList({ name: 'Yuyuan Road', localName: '愚园路' }, nearby));
    assert.ok(!onNearbyList({ name: 'Fu' }, nearby), 'too short to count as contained');
  });

  test('more than 2 unlisted picks: the extras beyond 2 are dropped', () => {
    const picks = [listed[1]!, { ...listed[2]!, name: "JING'AN  PARK" }, unlisted[0]!, { ...listed[0]!, name: 'Wutong Coffee Roasters' }, unlisted[1]!, unlisted[2]!, listed[4]!, unlisted[3]!];
    const result = finalizeDiscover(discoverExample, output(picks));
    assert.ok(result.ok);
    assert.deepEqual(result.value.places.map((p) => p.name), ["Jing'an Temple", "JING'AN  PARK", 'Yuyuan Road', 'Wutong Coffee Roasters', 'Changde Apartment', 'Fuxing Park']);
    assert.equal(result.dropped.length, 2);
    assert.match(result.dropped[0]!, /Fengsheng Li.*isn't on the "nearby" list/);
    assert.match(result.dropped[1]!, /Shanghai Natural History Museum/);
    // Without a nearby list nothing counts as unlisted.
    const fromMemory = finalizeDiscover(discoverFromMemory, output(picks));
    assert.ok(fromMemory.ok);
    assert.equal(fromMemory.value.places.length, 8);
  });

  test('fewer than 5 left after dropping the extras is one retry with the problems listed', async () => {
    const h = harness();
    h.script(json(output([listed[0]!, listed[1]!, ...unlisted])), json(output(listed)));
    const result = await h.skills.discover(discoverExample, ctx());
    assert.deepEqual(result.places.map((p) => p.name), listed.map((p) => p.name));
    assert.equal(h.faux.state.callCount, 2);
    const retry = lastUserText(h.contexts[1]!);
    assert.match(retry, /That reply had problems/);
    assert.match(retry, /Pick from the "nearby" list, copying each name exactly: at most 2 places that aren't on it/);
    assert.match(retry, /at least 5 places that pass these rules \(4 did\)/);
  });

  test('two ungrounded replies are 502 invalid_model_output', async () => {
    const h = harness();
    h.script(json(output([listed[0]!, ...unlisted])), json(output([listed[1]!, ...unlisted])));
    await rejectsWith(h.skills.discover(discoverExample, ctx()), 'invalid_model_output');
    assert.equal(h.skills.cache.size, 0);
  });

  test('the cache key changes with the nearby names, not their order; the old prompt version is retired', async () => {
    const reordered = { ...discoverExample, nearby: [...discoverExample.nearby!].reverse() };
    const changed = { ...discoverExample, nearby: [...discoverExample.nearby!.slice(0, 4), { name: 'Yuyuan Road', localName: '愚园路', category: 'shopping' as const, distanceMeters: 800 }] };
    assert.equal(nearbyKey(discoverFromMemory), 'none');
    assert.equal(nearbyKey({ ...discoverExample, nearby: [] }), 'none');
    assert.match(nearbyKey(discoverExample), /^[0-9a-f]{16}$/);
    assert.equal(discoverKey(reordered, 'm'), discoverKey(discoverExample, 'm'));
    assert.notEqual(discoverKey(changed, 'm'), discoverKey(discoverExample, 'm'));
    assert.notEqual(discoverKey(discoverFromMemory, 'm'), discoverKey(discoverExample, 'm'));
    assert.notEqual(DISCOVER_PROMPT_VERSION, 'dc-3');

    const h = harness();
    h.script(json(output(listed)), json(output(listed)));
    await h.skills.discover(discoverExample, ctx());
    await h.skills.discover(reordered, ctx());
    assert.equal(h.faux.state.callCount, 1);
    await h.skills.discover({ ...changed, nearby: [...changed.nearby, discoverExample.nearby![4]!] }, ctx());
    assert.equal(h.faux.state.callCount, 2);
  });

  test('concurrent discover calls for the same area and list share one generation', async () => {
    const h = harness();
    h.script(async () => {
      await new Promise((resolve) => setTimeout(resolve, 20));
      return json(output(listed));
    });
    const [a, b] = await Promise.all([h.skills.discover(discoverExample, ctx()), h.skills.discover({ ...discoverExample, nearby: [...discoverExample.nearby!].reverse() }, ctx())]);
    assert.deepEqual(a, b);
    assert.equal(h.faux.state.callCount, 1);
  });
});

// --- cache and budget (W7.8) ---

describe('response cache', () => {
  test('concurrent callers share one generation; later callers hit the cache', async () => {
    const h = harness();
    h.script(json(goodCard), json(goodCard));
    const ctx = { installId: null, clientVersion: null, signal: new AbortController().signal };
    const [a, b] = await Promise.all([h.skills.placeCard(placeCardRequest, ctx), h.skills.placeCard(placeCardRequest, ctx)]);
    assert.deepEqual(a, b);
    await h.skills.placeCard(placeCardRequest, ctx);
    assert.equal(h.faux.state.callCount, 1);
    // A different hour bucket is a different key.
    await h.skills.placeCard({ ...placeCardRequest, situation: { ...shanghai, hourBucket: '2026-10-05T16', localTime: '2026-10-05T16:00:00+08:00' } }, ctx);
    assert.equal(h.faux.state.callCount, 2);
  });

  test('one client leaving never cancels a shared generation', async () => {
    const h = harness();
    h.script(async () => {
      await new Promise((resolve) => setTimeout(resolve, 30));
      return json(goodCard);
    });
    const leaver = new AbortController();
    const first = h.skills.placeCard(placeCardRequest, { installId: null, clientVersion: null, signal: leaver.signal });
    leaver.abort();
    const card = await first;
    assert.equal(card.phrases.length, 2);
    assert.equal(h.skills.cache.size, 1);
  });

  test('the place key uses the id, else the name and coordinates to 4 decimals, else the city', () => {
    assert.equal(placeKey(placeCardRequest), 'fixture-shanghai-wutong-coffee');
    const { id: _id, ...noId } = shanghai.place!;
    assert.equal(placeKey({ ...placeCardRequest, situation: { ...shanghai, place: { ...noId, coordinate: { lat: 31.223812, lon: 121.44116 } } } }), 'wutong coffee@31.2238,121.4412');
    assert.equal(placeKey({ ...placeCardRequest, situation: { ...shanghai, place: null } }), "city:CN:shanghai:jing'an");
  });

  test('LRU eviction, errors never stored, and persistence to a file', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'ryoko-cache-'));
    try {
      const file = join(dir, 'responses.json');
      const cache = new ResponseCache({ file, maxEntries: 2, writeDelayMs: 5 });
      await cache.getOrCreate('a', async () => 1);
      await cache.getOrCreate('b', async () => 2);
      cache.get('a'); // a is now the most recently used
      await cache.getOrCreate('c', async () => 3);
      assert.equal(cache.get('b'), undefined);
      await assert.rejects(cache.getOrCreate('d', async () => Promise.reject(new Error('boom'))));
      assert.equal(cache.get('d'), undefined);
      cache.flush();
      const reloaded = new ResponseCache({ file, maxEntries: 2 });
      assert.equal(reloaded.get('a'), 1);
      assert.equal(reloaded.get('c'), 3);
      assert.equal(reloaded.size, 2);
      assert.equal(cacheKey(['x', 1]).length, 64);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('daily cost kill switch', () => {
  test('over the limit is 503 budget_exceeded until the next local day; the ledger persists', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ryoko-budget-'));
    try {
      let now = new Date(2026, 9, 3, 12);
      const file = join(dir, 'budget.json');
      const budget = new Budget({ limitUsd: 0.01, file, now: () => now });
      budget.assertAvailable();
      budget.add(0.011);
      assert.throws(() => budget.assertAvailable(), (err: unknown) => err instanceof ApiError && err.code === 'budget_exceeded' && err.status === 503);
      assert.equal(new Budget({ limitUsd: 0.01, file, now: () => now }).spentTodayUsd, 0.011);
      now = new Date(2026, 9, 4, 0, 1);
      budget.assertAvailable();
      assert.equal(budget.spentTodayUsd, 0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('a skill over budget answers 503 budget_exceeded without calling the model', async () => {
    const budget = new Budget({ limitUsd: 0.001, file: null });
    budget.add(1);
    const h = harness({ budget });
    h.script(json(goodCard));
    const { app } = createApp(testConfig(), { skills: h.skills });
    const res = await app.request('/v1/place-card', {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(placeCardRequest),
    });
    assert.equal(res.status, 503);
    assert.equal((await res.json()).error.code, 'budget_exceeded');
    const mimo = await app.request('/v1/sessions/b1/messages', {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(mimoRequest),
    });
    assert.equal(mimo.status, 503);
    assert.equal(h.faux.state.callCount, 0);
  });
});

// --- the phrase-tag transformer (W7.7) ---

type Out = { text: string } | { phrase: Phrase };

function transform(chunks: string[], options: { lang?: string; tool?: number[]; hazards?: Profile } = {}) {
  const out: Out[] = [];
  const stream = new PhraseStream({
    language: languageInfo(options.lang ?? 'zh-Hans'),
    idPrefix: 'mimo-run_t',
    hazards: options.hazards ? hazardsFor(options.hazards) : [],
    onText: (delta) => out.push({ text: delta }),
    onPhrase: (phrase) => out.push({ phrase }),
  });
  chunks.forEach((chunk, index) => {
    if (options.tool?.includes(index)) stream.toolBoundary();
    stream.push(chunk);
  });
  stream.end();
  return { out, stats: stream.stats, text: out.flatMap((o) => ('text' in o ? [o.text] : [])).join('') };
}

/** Splits text into pieces of `size` characters, to cut tags across deltas. */
const pieces = (text: string, size: number) => Array.from({ length: Math.ceil(text.length / size) }, (_, i) => text.slice(i * size, i * size + size));

describe('phrase-tag stream transformer', () => {
  const reply = 'Ask for it less sweet:\n<phrase lang="zh-Hans" local="少糖，谢谢" gloss="Less sugar, please" romanization="shao tang"/>\nThey will understand.';

  test('buffers tags split across deltas and emits text and phrase events in order, with pinyin', () => {
    for (const size of [1, 3, 7, 1000]) {
      const { out } = transform(pieces(reply, size));
      const kinds = out.map((o) => ('phrase' in o ? 'phrase' : 'text'));
      assert.equal(kinds.indexOf('phrase'), kinds.lastIndexOf('phrase'), `size ${size}`);
      const phrase = out.find((o): o is { phrase: Phrase } => 'phrase' in o)!.phrase;
      assert.deepEqual(phrase, { id: 'mimo-run_t-1', lang: 'zh-Hans', local: '少糖，谢谢', romanization: 'Shǎo táng, xiè xiè', gloss: 'Less sugar, please' });
      const before = out.slice(0, kinds.indexOf('phrase')).map((o) => ('text' in o ? o.text : '')).join('');
      const after = out.slice(kinds.indexOf('phrase') + 1).map((o) => ('text' in o ? o.text : '')).join('');
      assert.equal(before, 'Ask for it less sweet:');
      assert.equal(after, 'They will understand.');
    }
  });

  test('Japanese keeps the model romaji; entities are decoded', () => {
    const { out } = transform(['<phrase lang="ja" local="おすすめは？" gloss="What do you &quot;recommend&quot;?" romanization="Osusume wa?"/>'], { lang: 'ja' });
    assert.deepEqual(out, [{ phrase: { id: 'mimo-run_t-1', lang: 'ja', local: 'おすすめは？', romanization: 'Osusume wa?', gloss: 'What do you "recommend"?' } }]);
  });

  test('a malformed tag passes through as text; an unterminated one is flushed as text at the end', () => {
    const malformed = transform(['Try: <phrase lang="zh-Hans" local="你好"/> ok']);
    assert.equal(malformed.text, 'Try: <phrase lang="zh-Hans" local="你好"/> ok');
    assert.equal(malformed.stats.malformed, 1);
    const open = transform(['Say ', '<phrase lang="zh-Hans" local="你好" gl']);
    assert.equal(open.text, 'Say <phrase lang="zh-Hans" local="你好" gl');
    assert.equal(open.stats.malformed, 1);
  });

  test('wrapper tags are dropped and the paired form is accepted', () => {
    const { out, text } = transform(pieces('Here:\n<phrases>\n<phrase local="少冰" gloss="Less ice"></phrase>\n</phrases>\nDone.', 4));
    assert.equal(out.filter((o) => 'phrase' in o).length, 1);
    assert.doesNotMatch(text, /phrase/);
  });

  test('a separator goes between text before and after a tool call', () => {
    assert.equal(transform(['Let me look.', 'Found three.'], { tool: [1] }).text, 'Let me look.\n\nFound three.');
    assert.equal(transform(['Let me look.\n', 'Found three.'], { tool: [1] }).text, 'Let me look.\nFound three.');
    assert.equal(transform(['Found three.'], { tool: [0] }).text, 'Found three.');
  });

  test('drops phrases that suggest an allergen, keeps safety phrases, and caps at 4', () => {
    const tags = [
      '<phrase local="一份花生酱拌面" gloss="Peanut sauce noodles"/>',
      '<phrase local="我对花生过敏" gloss="I am allergic to peanuts"/>',
      ...['一', '二', '三', '四', '五'].map((n) => `<phrase local="${n}杯" gloss="${n} cups"/>`),
    ];
    const { out, stats } = transform([tags.join('\n')], { hazards: seed });
    const phrases = out.flatMap((o) => ('phrase' in o ? [o.phrase.local] : []));
    assert.deepEqual(phrases, ['我对花生过敏', '一杯', '二杯', '三杯']);
    assert.equal(stats.dropped, 3);
  });

  test('a phrase in the wrong script becomes plain words; stray local script is counted', () => {
    const { out, stats } = transform(['<phrase local="hello" gloss="hello"/> and 你好 outside']);
    assert.equal(out.some((o) => 'phrase' in o), false);
    assert.equal(stats.malformed, 1);
    assert.equal(stats.strayLocalScript, 1);
  });
});

// --- the mimo skill (W7.6) ---

interface Collected {
  events: SseEvent[];
  sink: SseSink;
  abort: AbortController;
}

function collector(): Collected {
  const events: SseEvent[] = [];
  const abort = new AbortController();
  const sink: SseSink = {
    send(event) {
      assert.ok(Value.Check(SseEvent, event), `invalid event ${JSON.stringify(event)}`);
      if (abort.signal.aborted) return false;
      events.push(event);
      return true;
    },
    comment: () => !abort.signal.aborted,
    signal: abort.signal,
    get closed() {
      return abort.signal.aborted;
    },
  };
  return { events, sink, abort };
}

let runCounter = 0;
async function runMimo(skills: ModelSkills, request: MimoMessageRequest, sessionId = 's1', collected = collector()) {
  const run: MimoRun = await skills.mimo(request, { installId: null, clientVersion: null, signal: collected.abort.signal, sessionId, runId: `run_${++runCounter}` });
  const stopReason = await run(collected.sink);
  return { stopReason, events: collected.events };
}

const textOf = (events: SseEvent[]) => events.flatMap((e) => (e.type === 'text' ? [e.delta] : [])).join('');
const places = { places: [{ name: "Jing'an Park", localName: '静安公园', why: 'Shady benches, calm in the afternoon' }] };

describe('mimo skill', () => {
  test('show_places: tool events with details, phrases, and a separator around the tool call', async () => {
    const h = harness();
    h.script(
      fauxAssistantMessage([fauxText('There are a couple of calm spots near you.'), fauxToolCall('show_places', places, { id: 'call_1' })], { stopReason: 'toolUse' }),
      fauxAssistantMessage('Both are a short walk.\n<phrase lang="zh-Hans" local="请问洗手间在哪里？" gloss="Where is the washroom?"/>'),
    );
    const { stopReason, events } = await runMimo(h.skills, mimoRequest);
    assert.equal(stopReason, 'stop');
    const types = events.map((e) => e.type);
    assert.deepEqual([...new Set(types)], ['text', 'tool_start', 'tool_end', 'phrase']);
    const start = events.find((e) => e.type === 'tool_start');
    assert.deepEqual(start, { type: 'tool_start', id: 'call_1', name: 'show_places', label: 'Finding places…' });
    const end = events.find((e) => e.type === 'tool_end');
    assert.deepEqual(end, { type: 'tool_end', id: 'call_1', name: 'show_places', ok: true, details: places });
    assert.equal(textOf(events), 'There are a couple of calm spots near you.\n\nBoth are a short walk.');
    const phrase = events.find((e) => e.type === 'phrase');
    assert.equal(phrase?.type === 'phrase' && phrase.phrase.romanization, 'Qǐng wèn xǐ shǒu jiān zài nǎ lǐ?');
    // The transcript keeps the raw tag.
    assert.match(JSON.stringify(h.skills.mimoSessions.transcript('s1')), /<phrase lang/);
  });

  test('sloppy show_places arguments are fixed before validation', () => {
    const fixed = prepareShowPlaces({ places: [{ name: ' A ', why: 'w'.repeat(100), when: '9:30', order: '2', extra: true }, ...Array.from({ length: 6 }, (_, i) => ({ name: `P${i}`, why: 'ok', when: 'evening' }))] }) as { places: Record<string, unknown>[] };
    assert.equal(fixed.places.length, 5);
    assert.deepEqual(Object.keys(fixed.places[0]!).sort(), ['name', 'order', 'when', 'why']);
    assert.equal(fixed.places[0]!.when, '09:30');
    assert.equal(fixed.places[0]!.order, 2);
    assert.ok((fixed.places[0]!.why as string).length <= 80);
    assert.equal('when' in fixed.places[1]!, false);
  });

  test('web_search: Exa sources in tool_end, short text for the model, cost in the budget', async () => {
    const queries: string[] = [];
    const h = harness({
      search: async (query) => {
        queries.push(query);
        return { results: [{ title: 'Museum hours', url: 'https://example.org/hours', text: 'Closed on Mondays.' }], costUsd: 0.005 };
      },
    });
    h.script(
      fauxAssistantMessage([fauxToolCall('web_search', { query: 'Shanghai Natural History Museum Monday hours' }, { id: 'call_s' })], { stopReason: 'toolUse' }),
      fauxAssistantMessage('It is closed on Mondays.'),
    );
    const { events } = await runMimo(h.skills, { ...mimoRequest, message: 'Is the museum open on Mondays?' });
    assert.deepEqual(queries, ['Shanghai Natural History Museum Monday hours']);
    const end = events.find((e) => e.type === 'tool_end');
    assert.deepEqual(end, { type: 'tool_end', id: 'call_s', name: 'web_search', ok: true, details: { sources: [{ title: 'Museum hours', url: 'https://example.org/hours' }] } });
    const toolResult = h.contexts[1]!.messages.find((m) => m.role === 'toolResult');
    assert.match(JSON.stringify(toolResult), /Closed on Mondays/);
    assert.ok(h.budget.spentTodayUsd >= 0.005);
  });

  test('a failed search ends its tool with ok false and empty sources', async () => {
    const h = harness({ search: async () => Promise.reject(new Error('Exa search failed with HTTP 500.')) });
    h.script(fauxAssistantMessage([fauxToolCall('web_search', { query: 'x' }, { id: 'call_f' })], { stopReason: 'toolUse' }), fauxAssistantMessage('I could not check that.'));
    const { events } = await runMimo(h.skills, mimoRequest);
    assert.deepEqual(events.find((e) => e.type === 'tool_end'), { type: 'tool_end', id: 'call_f', name: 'web_search', ok: false, details: { sources: [] } });
  });

  test('thinking is never streamed', async () => {
    const h = harness();
    h.script(fauxAssistantMessage([fauxThinking('secret plan'), fauxText('Hello there.')]));
    const { events } = await runMimo(h.skills, mimoRequest);
    assert.equal(textOf(events), 'Hello there.');
    assert.doesNotMatch(JSON.stringify(events), /secret/);
  });

  test('at most 3 tool calls: the 4th is blocked and the run ends with tool_limit', async () => {
    const h = harness();
    const call = (i: number) => fauxToolCall('show_places', places, { id: `call_${i}` });
    h.script(fauxAssistantMessage([call(1), call(2), call(3), call(4)], { stopReason: 'toolUse' }), fauxAssistantMessage('Here you go.'));
    const { stopReason, events } = await runMimo(h.skills, mimoRequest);
    assert.equal(stopReason, 'tool_limit');
    const ends = events.filter((e) => e.type === 'tool_end');
    assert.deepEqual(ends.map((e) => e.type === 'tool_end' && e.ok), [true, true, true, false]);
  });

  test('at most 4 turns: a 4th turn that still wants tools ends with turn_limit', async () => {
    const h = harness();
    h.script(...[1, 2, 3, 4, 5].map((i) => fauxAssistantMessage([fauxToolCall(i === 4 ? 'web_search' : 'show_places', i === 4 ? { query: 'q' } : places, { id: `c${i}` })], { stopReason: 'toolUse' })));
    const { stopReason } = await runMimo(h.skills, mimoRequest);
    assert.equal(stopReason, 'turn_limit');
    assert.equal(h.faux.state.callCount, 4);
  });

  test('the time limit aborts the run with a timeout error and forgets the exchange', async () => {
    const h = harness({ env: { MIMO_TIMEOUT_MS: '150' } });
    h.script(async (_context, signal) => {
      await new Promise((resolve) => {
        const timer = setTimeout(resolve, 3000);
        signal?.addEventListener('abort', () => (clearTimeout(timer), resolve(undefined)), { once: true });
      });
      return fauxAssistantMessage('too late');
    });
    const started = performance.now();
    await rejectsWith(runMimo(h.skills, mimoRequest, 'slow'), 'timeout');
    assert.ok(performance.now() - started < 2000);
    assert.equal(h.skills.mimoSessions.transcript('slow').length, 1); // only the system message
  });

  test('a client disconnect aborts the run', async () => {
    const h = harness();
    const collected = collector();
    h.script(async (_context, signal) => {
      collected.abort.abort(); // the client goes away mid-request
      if (!signal?.aborted) await new Promise((resolve) => signal?.addEventListener('abort', resolve, { once: true }));
      return fauxAssistantMessage('never sent');
    });
    const { stopReason } = await runMimo(h.skills, mimoRequest, 'gone', collected);
    assert.equal(stopReason, 'aborted');
  });

  test('a model error is model_error, and the session still works afterwards', async () => {
    const h = harness();
    h.script(fauxAssistantMessage([], { stopReason: 'error', errorMessage: 'rate limited' }), fauxAssistantMessage('Back again.'));
    await rejectsWith(runMimo(h.skills, mimoRequest, 'flaky'), 'model_error');
    const { events } = await runMimo(h.skills, mimoRequest, 'flaky');
    assert.equal(textOf(events), 'Back again.');
    const users = h.contexts[1]!.messages.filter((m) => m.role === 'user');
    assert.equal(users.length, 1); // the failed exchange was forgotten
  });

  test('the profile and situation sections are replaced per message, not appended', async () => {
    const h = harness();
    h.script(fauxAssistantMessage('First.'), fauxAssistantMessage('Second.'));
    await runMimo(h.skills, mimoRequest, 'sections');
    await runMimo(h.skills, { ...mimoRequest, situation: tokyo, nearby: [{ name: 'Menya Kaze', localName: '麺屋 風', category: 'ramen', distanceMeters: 0 }] }, 'sections');
    const second = systemText(h.contexts[1]!);
    assert.equal(second.match(/<situation>/g)?.length, 1);
    assert.equal(second.match(/<profile>/g)?.length, 1);
    assert.match(second, /Tokyo/);
    assert.doesNotMatch(second, /Shanghai/);
    assert.match(second, /<nearby>/);
    assert.equal(h.contexts[1]!.messages.filter((m) => m.role === 'system').length, 1);
    // The earlier exchange is still there.
    assert.equal(h.contexts[1]!.messages.filter((m) => m.role === 'user').length, 2);
  });

  test('over HTTP: start, text, phrase, done on the SSE stream', async () => {
    const h = harness();
    h.script(fauxAssistantMessage('Say this:\n<phrase lang="zh-Hans" local="谢谢" gloss="Thank you"/>'));
    const { app } = createApp(testConfig(), { skills: h.skills });
    const res = await app.request('/v1/sessions/http-1/messages', {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(mimoRequest),
    });
    assert.equal(res.status, 200);
    const body = await res.text();
    const events = body
      .split('\n\n')
      .filter((block) => block.startsWith('data: '))
      .map((block) => JSON.parse(block.slice(6)) as SseEvent);
    assert.deepEqual(events.map((e) => e.type).filter((type, i, all) => type !== all[i - 1]), ['start', 'text', 'phrase', 'done']);
    assert.ok(events.every((e) => Value.Check(SseEvent, e)));
  });
});

describe('provider errors', () => {
  test('key-like strings are masked before an error reaches the app', () => {
    assert.equal(providerErrorText('401 Incorrect API key provided: sk-abcdefghijklmnopqrstuvwxyz0123'), '401 Incorrect API key provided: …');
    assert.equal(providerErrorText(undefined), 'unknown error');
  });
});
