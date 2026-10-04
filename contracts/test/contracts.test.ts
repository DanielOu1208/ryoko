// Validates every example and table against its schema, and the SSE transcript
// line by line against the event union. Run: pnpm contracts:test

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Value } from 'typebox/value';
import type { TSchema } from 'typebox';
// Imported by package name (self-reference through "exports"), the way the server will.
import * as C from '@ryoko/contracts';
import { SCHEMAS, jsonSchemaDocument } from '../scripts/schemas.ts';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (rel: string) => readFileSync(join(root, rel), 'utf8');
const readJson = (rel: string): unknown => JSON.parse(read(rel));

function assertValid(schema: TSchema, value: unknown, label: string) {
  const errors = [...Value.Errors(schema, value)].map((e) => `${e.instancePath || '/'} ${e.message}`);
  assert.equal(Value.Check(schema, value), true, `${label} is invalid:\n  ${errors.slice(0, 10).join('\n  ')}`);
}

// Every example file and the schema it must satisfy.
const EXAMPLES: Record<string, TSchema> = {
  'profile.seed.json': C.Profile,
  'situation.shanghai-cafe.json': C.Situation,
  'situation.tokyo-ramen.json': C.Situation,
  'place-card.request.json': C.PlaceCardRequest,
  'place-card.response.json': C.PlaceCardResponse,
  'place-card.tokyo.request.json': C.PlaceCardRequest,
  'place-card.tokyo.response.json': C.PlaceCardResponse,
  'discover.request.json': C.DiscoverRequest,
  'discover.response.json': C.DiscoverResponse,
  'discover.tokyo.request.json': C.DiscoverRequest,
  'discover.tokyo.response.json': C.DiscoverResponse,
  'allergy-card.request.json': C.AllergyCardRequest,
  'allergy-card.response.json': C.AllergyCardResponse,
  'allergy-card.zh-hans.request.json': C.AllergyCardRequest,
  'allergy-card.zh-hans.response.json': C.AllergyCardResponse,
  'translate.request.json': C.TranslateRequest,
  'translate.response.json': C.TranslateResponse,
  'translate.tokyo.request.json': C.TranslateRequest,
  'translate.tokyo.response.json': C.TranslateResponse,
  'soniox-key.response.json': C.SonioxKeyResponse,
  'mimo-message.request.json': C.MimoMessageRequest,
  'error.invalid-request.response.json': C.ErrorEnvelope,
  'error.session-busy.response.json': C.ErrorEnvelope,
};
/** Examples that must be rejected. */
const INVALID_EXAMPLES: Record<string, TSchema> = {
  'error.invalid-request.request.json': C.PlaceCardRequest,
};
/** Mimo stream transcripts, each for one local language (the server picks one by situation.localLanguage). */
const TRANSCRIPTS: Record<string, string> = {
  'mimo.sse.txt': 'ja',
  'mimo.zh-hans.sse.txt': 'zh-Hans',
};

test('every example file is covered by this test', () => {
  const files = readdirSync(join(root, 'examples'));
  const covered = new Set([...Object.keys(EXAMPLES), ...Object.keys(INVALID_EXAMPLES), ...Object.keys(TRANSCRIPTS)]);
  assert.deepEqual(files.filter((f) => !covered.has(f)), []);
  for (const file of Object.keys(TRANSCRIPTS)) assert.match(file, /^mimo(\.[a-z0-9-]+)?\.sse\.txt$/, `${file}: transcript name`);
});

for (const [file, schema] of Object.entries(EXAMPLES)) {
  test(`example ${file} matches its schema`, () => assertValid(schema, readJson(`examples/${file}`), file));
}

for (const [file, schema] of Object.entries(INVALID_EXAMPLES)) {
  test(`example ${file} is rejected`, () => assert.equal(Value.Check(schema, readJson(`examples/${file}`)), false));
}

test('seed profile matches design §10 and its version is the canonical hash', () => {
  const p = readJson('examples/profile.seed.json') as C.Profile;
  assert.equal(p.version, C.profileVersion(p as unknown as Record<string, unknown>));
  assert.equal(p.nationality, 'CA');
  assert.equal(p.homeLanguage, 'en');
  assert.deepEqual(p.allergies, [{ id: 'peanut', severity: 'serious' }]);
  assert.equal(p.taste?.sweetness, 1);
  assert.equal(p.personality?.food, 'local_favourite');
  assert.equal(p.personality?.budget, 'save');
  assert.equal(p.personality?.vibe, 'quiet');
  assert.ok(p.homeBase?.name.includes('placeholder'), 'home base must stay marked as a placeholder');
  assert.equal('aboutMe' in p, false, 'the seed has no about me (design §10)');
});

test('aboutMe is optional: absent when empty, and leaving it out keeps the version', () => {
  const seed = readJson('examples/profile.seed.json') as C.Profile;
  const aboutMe = "I'm a chemistry teacher who loves jazz bars and café hopping.";
  const withAboutMe = { ...seed, aboutMe };
  // Parity anchor for the device's CanonicalJSON: the same profile must hash the same there.
  const version = C.profileVersion(withAboutMe as unknown as Record<string, unknown>);
  assert.equal(version, '315173f8b3d39fd32c90b06d8ab9a70b49590d47286124185b6963edd0457af1');
  assertValid(C.Profile, { ...withAboutMe, version }, 'a profile with aboutMe');
  const { version: _version, ...rest } = withAboutMe;
  assert.ok(C.canonicalJson(rest).startsWith(`{"aboutMe":${JSON.stringify(aboutMe)},"allergies":`), 'aboutMe sorts first');
  // Absent (or undefined) is left out of the canonical JSON, so older profiles keep their version.
  assert.equal(C.profileVersion({ ...seed, aboutMe: undefined }), seed.version);
  for (const bad of ['', null, 'a'.repeat(501)]) assert.equal(Value.Check(C.Profile, { ...seed, aboutMe: bad }), false, `aboutMe ${JSON.stringify(bad)?.slice(0, 20)} is rejected`);
  assertValid(C.Profile, { ...seed, aboutMe: 'a'.repeat(500) }, 'aboutMe at 500 characters');
});

/** An endpoint's variant example files, e.g. `discover.request.json` and `discover.tokyo.request.json`. */
const variantsOf = (endpoint: string, suffix: '.request.json' | '.response.json') =>
  Object.keys(EXAMPLES).filter((f) => f.startsWith(`${endpoint}.`) && f.endsWith(suffix));
const requestFor = (responseFile: string) => responseFile.replace(/\.response\.json$/, '.request.json');

test('each variant pair is for one local language, and no two variants share it', () => {
  for (const file of variantsOf('place-card', '.response.json')) {
    const request = readJson(`examples/${requestFor(file)}`) as C.PlaceCardRequest;
    assert.equal((readJson(`examples/${file}`) as C.PlaceCardResponse).language, request.situation.localLanguage, file);
  }
  for (const file of variantsOf('allergy-card', '.response.json')) {
    const request = readJson(`examples/${requestFor(file)}`) as C.AllergyCardRequest;
    assert.equal((readJson(`examples/${file}`) as C.AllergyCardResponse).language, request.language, file);
  }
  // The faux server picks a variant by language (server/src/fixtures.ts pickFixture).
  const discover = variantsOf('discover', '.request.json').map((f) => (readJson(`examples/${f}`) as C.DiscoverRequest).situation.localLanguage);
  const allergy = variantsOf('allergy-card', '.request.json').map((f) => (readJson(`examples/${f}`) as C.AllergyCardRequest).language);
  assert.deepEqual(discover.sort(), ['ja', 'zh-Hans']);
  assert.deepEqual(allergy.sort(), ['ja', 'zh-Hans']);
});

test('translate examples: one per target language, in its script, with the situation for its place', () => {
  const targets = variantsOf('translate', '.request.json').map((f) => (readJson(`examples/${f}`) as C.TranslateRequest).to);
  assert.deepEqual(targets.sort(), ['ja', 'zh-Hans'], 'the faux server picks a translate example by `to`');
  for (const file of variantsOf('translate', '.request.json')) {
    const request = readJson(`examples/${file}`) as C.TranslateRequest;
    const response = readJson(`examples/${requestFor(file).replace('.request.json', '.response.json')}`) as C.TranslateResponse;
    assert.equal(request.situation?.localLanguage, request.to, `${file}: typed text goes to the place's language`);
    assert.match(response.translation, /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/u, `${file}: translation in local script`);
    if (request.to.startsWith('zh')) assert.doesNotMatch(response.translation, /[A-Za-z]/, `${file}: Latin letters in Chinese`);
  }
  // Text longer than Type mode allows is refused.
  const long = { ...(readJson('examples/translate.request.json') as C.TranslateRequest), text: 'a'.repeat(C.TRANSLATE_MAX_CHARS + 1) };
  assert.equal(Value.Check(C.TranslateRequest, long), false);
  const { situation: _situation, ...noSituation } = readJson('examples/translate.request.json') as C.TranslateRequest;
  assertValid(C.TranslateRequest, noSituation, 'a translate request without a situation (a pair picked by hand)');
});

test('the soniox-key example is a placeholder, never a real key', () => {
  const key = readJson('examples/soniox-key.response.json') as C.SonioxKeyResponse;
  assert.match(key.apiKey, /^fixture-/, 'the example key must stay an obvious placeholder');
});

test('allergy-card examples are unreviewed and their Chinese has no Latin letters', () => {
  for (const file of variantsOf('allergy-card', '.response.json')) {
    const card = readJson(`examples/${file}`) as C.AllergyCardResponse;
    assert.equal(card.reviewed, false, `${file}: generated cards are never reviewed`);
    assert.ok(card.romanization, `${file}: CJK request needs romanization`);
    if (card.language.startsWith('zh')) {
      for (const text of [card.title, card.requestLocal, ...card.items.map((i) => i.local)]) {
        assert.doesNotMatch(text, /[A-Za-z]/, `${file}: Latin letters in ${text}`);
      }
    }
  }
});

test('place-card examples follow the server checks (§7.4)', () => {
  for (const file of ['place-card.response.json', 'place-card.tokyo.response.json']) {
    const card = readJson(`examples/${file}`) as C.PlaceCardResponse;
    for (const ph of card.phrases) {
      assert.equal(ph.lang, card.language);
      assert.ok(ph.because.split(/\s+/).length <= 10, `${ph.id}: because is too long`);
      if (ph.lang.startsWith('zh')) assert.doesNotMatch(ph.local, /[A-Za-z]/, `${ph.id}: Latin letters in Chinese text`);
      assert.ok(ph.romanization, `${ph.id}: CJK phrase needs romanization`);
    }
  }
});

test('tables match their schemas', () => {
  assertValid(C.LangCodeTable, readJson('tables/langcodes.json'), 'langcodes.json');
  assertValid(C.CategoryTable, readJson('tables/categories.json'), 'categories.json');
  assertValid(C.AllergyTemplateTable, readJson('tables/allergy-templates.json'), 'allergy-templates.json');
});

test('language table covers zh-Hans, ja, en, and zh-Hant as best-effort', () => {
  const t = readJson('tables/langcodes.json') as C.LangCodeTable;
  const byTag = new Map(t.languages.map((l) => [l.tag, l]));
  assert.deepEqual([...byTag.keys()].sort(), ['en', 'ja', 'zh-Hans', 'zh-Hant']);
  assert.equal(byTag.get('zh-Hans')?.locale, 'zh_Hans_CN');
  assert.equal(byTag.get('zh-Hans')?.romanizationSource, 'pinyin-pro');
  assert.equal(byTag.get('ja')?.romanizationSource, 'model');
  assert.equal(byTag.get('zh-Hant')?.status, 'best_effort');
});

test('category table has every slug exactly once', () => {
  const t = readJson('tables/categories.json') as C.CategoryTable;
  assert.deepEqual(t.categories.map((c) => c.slug).sort(), [...C.CATEGORY_SLUGS].sort());
  for (const c of t.categories) for (const s of c.starters) assert.doesNotMatch(s, /!/, `${c.slug}: no exclamation marks`);
});

test('allergy templates are unreviewed, complete, and hold the fixed taxi phrases', () => {
  const t = readJson('tables/allergy-templates.json') as C.AllergyTemplateTable;
  for (const [lang, block] of Object.entries(t.languages)) {
    assert.equal(block.reviewed, false, `${lang} must stay unreviewed until a native speaker checks it`);
    assert.deepEqual(Object.keys(block.allergens).sort(), [...C.CHIP_ALLERGENS].sort());
    for (const [id, a] of Object.entries(block.allergens)) {
      for (const sev of C.SEVERITIES) {
        const line = a[sev];
        if (lang.startsWith('zh')) assert.doesNotMatch(line.local, /[A-Za-z]/, `${lang}/${id}/${sev}`);
        assert.match(line.home, /^[A-Z].*\.$/, `${lang}/${id}/${sev}: home line is a sentence`);
      }
    }
  }
  assert.equal(t.taxiPhrases['zh-Hans'].local, '请带我去这里');
  assert.equal(t.taxiPhrases.ja.local, 'こちらまでお願いします');
  assert.equal(t.taxiPhrases['zh-Hant'].local, '請帶我去這裡');
});

test('emitted JSON Schema files are in sync with the TypeBox sources', () => {
  const files = readdirSync(join(root, 'json-schema')).filter((f) => f.endsWith('.schema.json'));
  assert.deepEqual(files.sort(), Object.keys(SCHEMAS).map((n) => `${n}.schema.json`).sort(), 'run pnpm contracts:emit');
  for (const [name, schema] of Object.entries(SCHEMAS)) {
    assert.deepEqual(readJson(`json-schema/${name}.schema.json`), jsonSchemaDocument(name, schema), `${name} is stale: run pnpm contracts:emit`);
  }
});

test('enums are flat string enums: no const anywhere', () => {
  const walk = (node: unknown, path: string) => {
    if (Array.isArray(node)) return node.forEach((n, i) => walk(n, `${path}/${i}`));
    if (node && typeof node === 'object') {
      const o = node as Record<string, unknown>;
      assert.ok(!('const' in o), `const at ${path}`);
      if ('enum' in o) assert.equal(o.type, 'string', `enum without type string at ${path}`);
      for (const [k, v] of Object.entries(o)) walk(v, `${path}/${k}`);
    }
  };
  for (const [name, schema] of Object.entries(SCHEMAS)) walk(JSON.parse(JSON.stringify(schema)), name);
});

for (const [file, language] of Object.entries(TRANSCRIPTS)) {
  test(`${file} follows the §7.7 wire format and every event matches the union`, () => {
    const raw = read(`examples/${file}`);
    assert.ok(raw.endsWith('\n\n'), 'stream ends with a blank line');
    const lines = raw.split('\n');
    // Every non-blank line is a comment or a single data line, and is followed by a blank line.
    const events: C.SseEvent[] = [];
    let firstComment: string | undefined;
    for (let i = 0; i < lines.length - 1; i++) {
      const line = lines[i]!;
      if (line === '') continue;
      assert.equal(lines[i + 1], '', `line ${i + 1} must be followed by a blank line`);
      if (line.startsWith(':')) {
        if (events.length === 0 && firstComment === undefined) firstComment = line;
        continue;
      }
      assert.ok(line.startsWith('data: '), `line ${i + 1} is neither a comment nor data: ${line.slice(0, 40)}`);
      const event = JSON.parse(line.slice('data: '.length));
      assertValid(C.SseEvent, event, `line ${i + 1}`);
      events.push(event as C.SseEvent);
    }
    assert.ok(firstComment && Buffer.byteLength(firstComment) > 512, 'padding comment of more than 512 bytes comes first');
    assert.equal(events[0]?.type, 'start');
    assert.equal(events.at(-1)?.type, 'done');
    assert.ok(events.some((e) => e.type === 'phrase'), 'has a phrase event');
    const starts = events.filter((e) => e.type === 'tool_start');
    const ends = events.filter((e) => e.type === 'tool_end');
    assert.deepEqual(starts.map((e) => e.id), ends.map((e) => e.id), 'every tool_start has a tool_end');
    const shown = ends.find((e) => e.name === 'show_places');
    assert.ok(shown && shown.name === 'show_places' && shown.details.places.length === 3, 'show_places returns 3 places');
    const phrases = events.flatMap((e) => (e.type === 'phrase' ? [e.phrase] : []));
    assert.equal(new Set(phrases.map((p) => p.id)).size, phrases.length, 'phrase ids are unique');
    for (const p of phrases) {
      assert.equal(p.lang, language, `${p.id}: every phrase is in the transcript's language`);
      assert.ok(p.romanization, `${p.id}: CJK phrase needs romanization`);
      if (p.lang.startsWith('zh')) assert.doesNotMatch(p.local, /[A-Za-z]/, `${p.id}: Latin letters in Chinese text`);
    }
  });
}
