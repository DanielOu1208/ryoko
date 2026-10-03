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
  'allergy-card.request.json': C.AllergyCardRequest,
  'allergy-card.response.json': C.AllergyCardResponse,
  'mimo-message.request.json': C.MimoMessageRequest,
  'error.invalid-request.response.json': C.ErrorEnvelope,
  'error.session-busy.response.json': C.ErrorEnvelope,
};
/** Examples that must be rejected. */
const INVALID_EXAMPLES: Record<string, TSchema> = {
  'error.invalid-request.request.json': C.PlaceCardRequest,
};

test('every example file is covered by this test', () => {
  const files = readdirSync(join(root, 'examples')).filter((f) => f.endsWith('.json'));
  const covered = new Set([...Object.keys(EXAMPLES), ...Object.keys(INVALID_EXAMPLES)]);
  assert.deepEqual(files.filter((f) => !covered.has(f)), []);
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

test('mimo.sse.txt follows the §7.7 wire format and every event matches the union', () => {
  const raw = read('examples/mimo.sse.txt');
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
});
