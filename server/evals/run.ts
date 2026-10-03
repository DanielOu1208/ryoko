// Evals (design §6.4, W7.9): canned situations through every skill on the REAL
// model from server/.env (GMI by default). It costs real money, a few cents a run.
//
//   node evals/run.ts                       # every case once
//   RUNS=3 node evals/run.ts                # place-card and Mimo cases 3 times each
//   ONLY=placeCard,mimo node evals/run.ts   # some skills only
//
// It reports, per skill: schema validity (against the contracts), basis validity,
// the allergen filter, retries, items the server checks dropped, latency p50/max
// and cost. A JSON report goes to server/.cache/evals/ (gitignored).

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
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
  type PlaceCardRequest,
  type Profile,
  type Situation,
} from '@ryoko/contracts';
import { ResponseCache } from '../src/cache.ts';
import { DEFAULT_CACHE_DIR, describeConfig, loadConfig } from '../src/config.ts';
import { ApiError } from '../src/errors.ts';
import { EXAMPLES_DIR } from '../src/fixtures.ts';
import type { GenerationStats } from '../src/llm/typed.ts';
import { allowedBasis, hasLatinLetters, inLocalScript, languageInfo, wordCount } from '../src/skills/context.ts';
import type { MimoRunStats } from '../src/skills/mimo/session.ts';
import { createModelSkills, type SkillCallStats } from '../src/skills/model.ts';
import { MAX_BECAUSE_WORDS } from '../src/skills/place-card.ts';
import { hazardsFor, unsafeMention } from '../src/skills/safety.ts';
import type { SseSink } from '../src/sse.ts';

const RUNS = Math.max(1, Number(process.env.RUNS ?? 1));
const ONLY = new Set((process.env.ONLY ?? '').split(',').map((s) => s.trim()).filter(Boolean));
const wanted = (skill: string) => ONLY.size === 0 || ONLY.has(skill);

const example = <T>(file: string): T => JSON.parse(readFileSync(join(EXAMPLES_DIR, file), 'utf8')) as T;
const seed = example<Profile>('profile.seed.json');

function profile(changes: Partial<Profile>): Profile {
  const next = { ...seed, ...changes };
  return { ...next, version: profileVersion(next) };
}

function situation(base: Omit<Situation, 'hourBucket'>): Situation {
  return { ...base, hourBucket: base.localTime.slice(0, 13) };
}

// --- canned situations (design §6.4) ---

const heytea = (localTime: string): Situation =>
  situation({
    mode: 'preview',
    localTime,
    timeZone: 'Asia/Shanghai',
    place: { name: 'Heytea', localName: '喜茶', category: 'tea', address: "Nanjing West Road, Jing'an, Shanghai", coordinate: { lat: 31.2235, lon: 121.4453 } },
    city: 'Shanghai',
    district: "Jing'an",
    countryCode: 'CN',
    localLanguage: 'zh-Hans',
  });

const tokyoRamen = situation({
  mode: 'preview',
  localTime: '2026-10-06T20:00:00+09:00',
  timeZone: 'Asia/Tokyo',
  place: { name: 'Fuunji', localName: '風雲児', category: 'ramen', address: '2-14-3 Yoyogi, Shibuya, Tokyo', coordinate: { lat: 35.6866, lon: 139.6985 } },
  city: 'Tokyo',
  district: 'Shinjuku',
  countryCode: 'JP',
  localLanguage: 'ja',
});

const sichuan = situation({
  mode: 'preview',
  localTime: '2026-10-05T19:00:00+08:00',
  timeZone: 'Asia/Shanghai',
  place: { name: 'Yuxin Sichuan Restaurant', localName: '渝信川菜', category: 'restaurant', coordinate: { lat: 31.2304, lon: 121.4737 } },
  city: 'Shanghai',
  district: 'Huangpu',
  countryCode: 'CN',
  localLanguage: 'zh-Hans',
});

const unknownPoi = situation({
  mode: 'live',
  localTime: '2026-10-05T12:30:00+08:00',
  timeZone: 'Asia/Shanghai',
  place: { name: 'Lane 1048 Shop', category: 'other', coordinate: { lat: 31.2201, lon: 121.4489 } },
  city: 'Shanghai',
  district: 'Xuhui',
  countryCode: 'CN',
  localLanguage: 'zh-Hans',
});

const cityOnly = situation({
  mode: 'preview',
  localTime: '2026-10-05T10:00:00+08:00',
  timeZone: 'Asia/Shanghai',
  place: null,
  city: 'Shanghai',
  countryCode: 'CN',
  localLanguage: 'zh-Hans',
});

const vancouver = situation({
  mode: 'live',
  localTime: '2026-10-04T09:00:00-07:00',
  timeZone: 'America/Vancouver',
  place: { name: 'Revolver Coffee', category: 'cafe', address: '325 Cambie St, Vancouver', coordinate: { lat: 49.2834, lon: -123.1094 } },
  city: 'Vancouver',
  district: 'Gastown',
  countryCode: 'CA',
  localLanguage: 'en',
});

const peanutStrict = profile({ allergies: [{ id: 'peanut', severity: 'life_threatening' }, { id: 'sesame', severity: 'serious' }] });

const placeCardCases: { name: string; request: PlaceCardRequest }[] = [
  { name: 'heytea 15:00', request: { profile: seed, situation: heytea('2026-10-05T15:00:00+08:00') } },
  { name: 'heytea 08:00', request: { profile: seed, situation: heytea('2026-10-05T08:00:00+08:00') } },
  { name: 'tokyo ramen 20:00', request: { profile: seed, situation: tokyoRamen } },
  { name: 'peanut + sesame, sichuan 19:00', request: { profile: peanutStrict, situation: sichuan } },
  { name: 'unknown poi', request: { profile: seed, situation: unknownPoi } },
  { name: 'city only', request: { profile: seed, situation: cityOnly } },
  { name: 'english to english', request: { profile: seed, situation: vancouver } },
];

const discoverCases: { name: string; request: DiscoverRequest }[] = [
  { name: 'shinjuku 20:00', request: { ...example<DiscoverRequest>('discover.tokyo.request.json') } },
  { name: "jing'an 15:00", request: { ...example<DiscoverRequest>('discover.request.json') } },
];

const allergyCases: { name: string; request: AllergyCardRequest }[] = [
  { name: 'buckwheat (ja)', request: example<AllergyCardRequest>('allergy-card.request.json') },
  { name: 'kiwi (zh-Hans)', request: example<AllergyCardRequest>('allergy-card.zh-hans.request.json') },
];

const shanghaiCafe = example<Situation>('situation.shanghai-cafe.json');
const mimoBase = example<MimoMessageRequest>('mimo-message.request.json');
const mimoCases: { name: string; expectTool?: 'show_places' | 'web_search'; expectPhrases?: boolean; request: MimoMessageRequest }[] = [
  {
    name: 'quiet place nearby (show_places)',
    expectTool: 'show_places',
    request: { ...mimoBase, message: 'Somewhere quiet nearby where I can sit for an hour?', situation: shanghaiCafe, nearby: [{ name: 'Wutong Coffee', localName: '梧桐咖啡', category: 'cafe', distanceMeters: 0 }] },
  },
  {
    name: 'ordering + somewhere quiet after (tokyo)',
    expectTool: 'show_places',
    request: mimoBase,
  },
  {
    name: 'opening hours (web_search)',
    expectTool: 'web_search',
    request: { ...mimoBase, message: 'Can you look up whether the Shanghai Natural History Museum is open on Mondays?', situation: shanghaiCafe, nearby: [] },
  },
  {
    name: 'less sweet, less ice (phrases)',
    expectPhrases: true,
    request: { ...mimoBase, message: 'How do I ask for my drink less sweet and with less ice?', situation: heytea('2026-10-05T15:00:00+08:00'), nearby: [] },
  },
  {
    name: 'plan my evening (ordered stops)',
    expectTool: 'show_places',
    request: { ...mimoBase, message: 'Plan my evening around here, a few stops.', situation: { ...tokyoRamen, localTime: '2026-10-06T18:00:00+09:00', hourBucket: '2026-10-06T18' } },
  },
];

// --- running ---

interface Row {
  skill: string;
  case: string;
  ok: boolean;
  error?: string;
  schemaValid: boolean;
  basisValid: boolean | null;
  allergenOk: boolean;
  checks: string[];
  attempts: number;
  dropped: string[];
  firstIssues: string[];
  latencyMs: number;
  costUsd: number;
  extra?: Record<string, unknown>;
}

const config = loadConfig();
if (!config.models) {
  console.error('MODEL is faux: evals need a real model. Set MODEL=gmi (or unset it).');
  process.exit(1);
}
/** The stats callbacks write here (an object, so TypeScript doesn't narrow it away). */
const seen: { generation?: GenerationStats; mimo?: MimoRunStats } = {};
const lastMimo = (): MimoRunStats | undefined => seen.mimo;
const skills = createModelSkills(
  { ...config, cacheDir: DEFAULT_CACHE_DIR },
  {
    cache: new ResponseCache({ file: null, maxEntries: 0 }), // never cache: every run generates
    log: () => {},
    onSkillStats: (s: SkillCallStats) => (seen.generation = s.generation),
    onMimoStats: (s) => (seen.mimo = s),
  },
);
console.log(`Evals on ${describeConfig(config)}. Spent today before this run: $${skills.budget.spentTodayUsd.toFixed(4)}\n`);

const rows: Row[] = [];
const ctx = () => ({ installId: 'evals', clientVersion: 'evals', signal: new AbortController().signal });

async function timed<T>(fn: () => Promise<T>): Promise<{ value?: T; error?: string; ms: number }> {
  const started = performance.now();
  delete seen.generation;
  try {
    const value = await fn();
    return { value, ms: Math.round(performance.now() - started) };
  } catch (err) {
    const message = err instanceof ApiError ? `${err.code}: ${err.message}` : String(err);
    return { error: message, ms: Math.round(performance.now() - started) };
  }
}

function genFields(ms: number): Pick<Row, 'attempts' | 'dropped' | 'firstIssues' | 'latencyMs' | 'costUsd'> {
  return {
    attempts: seen.generation?.attempts ?? 0,
    dropped: seen.generation?.dropped ?? [],
    firstIssues: seen.generation?.firstIssues ?? [],
    latencyMs: ms,
    costUsd: seen.generation?.costUsd ?? 0,
  };
}

if (wanted('placeCard')) {
  for (const c of placeCardCases) {
    for (let run = 0; run < RUNS; run++) {
      const r = await timed(() => skills.placeCard(c.request, ctx()));
      const card = r.value;
      const local = languageInfo(c.request.situation.localLanguage);
      const allowed = allowedBasis(c.request.profile, c.request.situation);
      const hazards = hazardsFor(c.request.profile);
      const checks: string[] = [];
      let basisValid: boolean | null = null;
      let allergenOk = true;
      if (card) {
        basisValid = [...card.phrases, ...card.tips].every((item) => (item.basis ?? []).every((b) => allowed.includes(b)));
        for (const p of card.phrases) {
          if (unsafeMention([p.local, p.gloss], hazards)) allergenOk = false;
          if (wordCount(p.because) > MAX_BECAUSE_WORDS) checks.push(`because too long: ${p.because}`);
          if (local.script === 'han' && hasLatinLetters(p.local)) checks.push(`latin in zh: ${p.local}`);
          if (!inLocalScript(p.local, local)) checks.push(`wrong script: ${p.local}`);
          if (local.romanization !== 'none' && !p.romanization) checks.push(`no romanization: ${p.local}`);
        }
        for (const t of card.tips) if (unsafeMention([t.text], hazards)) allergenOk = false;
      }
      rows.push({
        skill: 'placeCard',
        case: c.name,
        ok: Boolean(card),
        ...(r.error ? { error: r.error } : {}),
        schemaValid: Boolean(card && Value.Check(PlaceCardResponse, card)),
        basisValid,
        allergenOk,
        checks,
        ...genFields(r.ms),
        extra: card ? { phrases: card.phrases.map((p) => `${p.local} | ${p.romanization ?? ''} | ${p.gloss} | ${p.because} [${p.basis.join(',')}]`), tips: card.tips.map((t) => t.text), placeNameLocal: card.placeNameLocal } : {},
      });
      console.log(`placeCard  ${c.name.padEnd(34)} ${card ? 'ok ' : 'ERR'} ${r.ms} ms ${r.error ?? ''}`);
    }
  }
}

if (wanted('discover')) {
  for (const c of discoverCases) {
    const r = await timed(() => skills.discover(c.request, ctx()));
    const result = r.value;
    const local = languageInfo(c.request.situation.localLanguage);
    const hazards = hazardsFor(c.request.profile);
    const checks: string[] = [];
    let allergenOk = true;
    for (const p of result?.places ?? []) {
      if (p.why.length > 60) checks.push(`why > 60: ${p.why}`);
      if (!inLocalScript(p.localName, local)) checks.push(`localName script: ${p.localName}`);
      if (unsafeMention([p.name, p.why], hazards)) allergenOk = false;
    }
    rows.push({
      skill: 'discover',
      case: c.name,
      ok: Boolean(result),
      ...(r.error ? { error: r.error } : {}),
      schemaValid: Boolean(result && Value.Check(DiscoverResponse, result)),
      basisValid: null,
      allergenOk,
      checks,
      ...genFields(r.ms),
      extra: result ? { places: result.places.map((p) => `${p.name} / ${p.localName} [${p.category}] ${p.why}${p.bestTime ? ` (${p.bestTime})` : ''}`) } : {},
    });
    console.log(`discover   ${c.name.padEnd(34)} ${result ? 'ok ' : 'ERR'} ${r.ms} ms ${r.error ?? ''}`);
  }
}

if (wanted('allergyCard')) {
  for (const c of allergyCases) {
    const r = await timed(() => skills.allergyCard(c.request, ctx()));
    const card = r.value;
    const checks: string[] = [];
    if (card) {
      if (card.reviewed !== false) checks.push('reviewed is not false');
      card.items.forEach((item, i) => {
        if (item.severity !== c.request.allergies[i]?.severity) checks.push(`severity changed at ${i}`);
      });
      if (!card.romanization) checks.push('no romanization');
    }
    rows.push({
      skill: 'allergyCard',
      case: c.name,
      ok: Boolean(card),
      ...(r.error ? { error: r.error } : {}),
      schemaValid: Boolean(card && Value.Check(AllergyCardResponse, card)),
      basisValid: null,
      allergenOk: true,
      checks,
      ...genFields(r.ms),
      extra: card ? { title: card.title, items: card.items.map((i) => `${i.local} | ${i.home}`), request: `${card.requestLocal} | ${card.romanization ?? ''} | ${card.requestHome}` } : {},
    });
    console.log(`allergyCard ${c.name.padEnd(33)} ${card ? 'ok ' : 'ERR'} ${r.ms} ms ${r.error ?? ''}`);
  }
}

if (wanted('mimo')) {
  for (const [index, c] of mimoCases.flatMap((c) => Array.from({ length: RUNS }, () => c)).entries()) {
    const events: SseEvent[] = [];
    let invalid = 0;
    const abort = new AbortController();
    const sink: SseSink = {
      send(event) {
        if (!Value.Check(SseEvent, event)) invalid++;
        events.push(event);
        return true;
      },
      comment: () => true,
      signal: abort.signal,
      closed: false,
    };
    delete seen.mimo;
    const started = performance.now();
    let error: string | undefined;
    let stopReason: string | undefined;
    try {
      const run = await skills.mimo(c.request, { ...ctx(), sessionId: `evals-${Date.now()}-${index}`, runId: `run_eval${index}` });
      stopReason = await run(sink);
    } catch (err) {
      error = err instanceof ApiError ? `${err.code}: ${err.message}` : String(err);
    }
    const ms = Math.round(performance.now() - started);
    // The reply as a reader sees it: phrase blocks and tool calls marked in place.
    const text = events
      .flatMap((e) => (e.type === 'text' ? [e.delta] : e.type === 'phrase' ? [' [phrase] '] : e.type === 'tool_start' ? [` [${e.name}] `] : []))
      .join('');
    const phrases = events.flatMap((e) => (e.type === 'phrase' ? [e.phrase] : []));
    const tools = events.flatMap((e) => (e.type === 'tool_end' ? [e] : []));
    const hazards = hazardsFor(c.request.profile);
    const checks: string[] = [];
    if (invalid > 0) checks.push(`${invalid} invalid events`);
    if (c.expectTool && !tools.some((t) => t.name === c.expectTool && t.ok)) checks.push(`expected ${c.expectTool}`);
    if (c.expectTool === 'web_search' && !tools.some((t) => t.name === 'web_search' && t.details && 'sources' in t.details && t.details.sources.length > 0)) checks.push('no sources');
    if (c.expectPhrases && phrases.length === 0) checks.push('expected phrase events');
    if ((lastMimo()?.phrases.strayLocalScript ?? 0) > 0) checks.push(`local script outside tags (${lastMimo()?.phrases.strayLocalScript} chunks)`);
    if (/<\/?phrase/.test(text)) checks.push('raw phrase tag in text');
    const zhPhrasesOk = phrases.every((p) => !p.lang.startsWith('zh') || Boolean(p.romanization));
    if (!zhPhrasesOk) checks.push('zh phrase without pinyin');
    rows.push({
      skill: 'mimo',
      case: c.name,
      ok: !error,
      ...(error ? { error } : {}),
      schemaValid: invalid === 0 && events.length > 0,
      basisValid: null,
      allergenOk: phrases.every((p) => !unsafeMention([p.local, p.gloss], hazards)),
      checks,
      attempts: lastMimo()?.turns ?? 0,
      dropped: [],
      firstIssues: [],
      latencyMs: ms,
      costUsd: lastMimo()?.costUsd ?? 0,
      extra: {
        stopReason,
        firstTextMs: lastMimo()?.firstTextMs,
        tools: lastMimo()?.toolCalls,
        text,
        phrases: phrases.map((p) => `${p.local} | ${p.romanization ?? ''} | ${p.gloss}`),
        toolEnds: tools.map((t) => t.details),
      },
    });
    console.log(`mimo       ${c.name.padEnd(34)} ${error ? 'ERR' : 'ok '} ${ms} ms ${error ?? stopReason}`);
  }
}

// --- report ---

const pct = (n: number, d: number) => (d === 0 ? '  -  ' : `${Math.round((100 * n) / d)}%`.padStart(5));
const p50 = (xs: number[]) => {
  const s = [...xs].sort((a, b) => a - b);
  return s.length === 0 ? 0 : (s[Math.floor((s.length - 1) / 2)] ?? 0);
};

console.log('\nskill        n   ok  schema  basis  allergen  checks  retried  dropped  p50 ms  max ms   cost $');
for (const skill of ['placeCard', 'discover', 'allergyCard', 'mimo']) {
  const r = rows.filter((row) => row.skill === skill);
  if (r.length === 0) continue;
  const basisRows = r.filter((row) => row.basisValid !== null);
  const line = [
    skill.padEnd(11),
    String(r.length).padStart(2),
    pct(r.filter((x) => x.ok).length, r.length),
    pct(r.filter((x) => x.schemaValid).length, r.length).padStart(7),
    pct(basisRows.filter((x) => x.basisValid).length, basisRows.length).padStart(6),
    pct(r.filter((x) => x.allergenOk).length, r.length).padStart(9),
    String(r.reduce((n, x) => n + x.checks.length, 0)).padStart(7),
    String(r.filter((x) => x.firstIssues.length > 0).length).padStart(8),
    String(r.reduce((n, x) => n + x.dropped.length, 0)).padStart(8),
    String(p50(r.map((x) => x.latencyMs))).padStart(7),
    String(Math.max(...r.map((x) => x.latencyMs))).padStart(7),
    r.reduce((n, x) => n + x.costUsd, 0).toFixed(4).padStart(8),
  ];
  console.log(line.join(' '));
}
const failures = rows.filter((row) => !row.ok || row.checks.length > 0 || !row.allergenOk || row.basisValid === false);
for (const row of failures) console.log(`\n! ${row.skill} / ${row.case}: ${row.error ?? ''} ${row.checks.join('; ')}`);
for (const row of rows.filter((x) => x.dropped.length > 0 || x.firstIssues.length > 0)) {
  const retry = row.firstIssues.length > 0 ? `retried after [${row.firstIssues.join(' | ')}]` : 'no retry';
  console.log(`\n~ ${row.skill} / ${row.case}: ${retry}; dropped [${row.dropped.join(' | ')}]`);
}

const dir = join(DEFAULT_CACHE_DIR, 'evals');
mkdirSync(dir, { recursive: true });
const file = join(dir, `evals-${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
writeFileSync(file, JSON.stringify({ config: describeConfig(config), runs: RUNS, rows }, null, 2));
console.log(`\nSpent today: $${skills.budget.spentTodayUsd.toFixed(4)}. Report: ${file}`);
