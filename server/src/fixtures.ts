// Loads the hand-written examples from contracts/examples for MODEL=faux.
// Everything is checked against its schema at startup, so a drifting fixture
// fails the boot instead of a request.

import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { TSchema, Static } from 'typebox';
import { Value } from 'typebox/value';
import {
  AllergyCardRequest,
  AllergyCardResponse,
  DiscoverRequest,
  DiscoverResponse,
  PlaceCardRequest,
  PlaceCardResponse,
  SseEvent,
} from '@ryoko/contracts';

export const CONTRACTS_DIR = dirname(fileURLToPath(import.meta.resolve('@ryoko/contracts/package.json')));
export const EXAMPLES_DIR = join(CONTRACTS_DIR, 'examples');

/**
 * One example for one local language: a request/response pair such as
 * place-card.tokyo.{request,response}.json, or a Mimo transcript such as mimo.zh-hans.sse.txt.
 */
export interface Fixture<Res> {
  /** '' for the default (`place-card.response.json`, `mimo.sse.txt`), otherwise the infix (`tokyo`). */
  variant: string;
  /** The local language this example is for: from its request, or a transcript's phrases. */
  language: string | null;
  response: Res;
}

export type TranscriptItem = { kind: 'event'; event: SseEvent } | { kind: 'comment'; text: string };

export interface FixtureSet {
  placeCard: Fixture<PlaceCardResponse>[];
  discover: Fixture<DiscoverResponse>[];
  allergyCard: Fixture<AllergyCardResponse>[];
  mimo: Fixture<TranscriptItem[]>[];
}

export class FixtureError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'FixtureError';
  }
}

function readJson(dir: string, file: string): unknown {
  try {
    return JSON.parse(readFileSync(join(dir, file), 'utf8'));
  } catch (err) {
    throw new FixtureError(`contracts/examples/${file} isn't readable JSON: ${(err as Error).message}`);
  }
}

function assertSchema(schema: TSchema, value: unknown, file: string): void {
  if (Value.Check(schema, value)) return;
  const first = Value.Errors(schema, value)[0];
  throw new FixtureError(`contracts/examples/${file} doesn't match its schema: ${first?.instancePath || '/'} ${first?.message ?? ''}`);
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Finds every `<endpoint>[.<variant>].response.json` and its matching request. */
function loadPairs<Req extends TSchema, Res extends TSchema>(
  dir: string,
  endpoint: string,
  requestSchema: Req,
  responseSchema: Res,
  languageOf: (request: Static<Req>) => string,
): Fixture<Static<Res>>[] {
  const pattern = new RegExp(`^${escapeRegExp(endpoint)}(?:\\.([a-z0-9-]+))?\\.response\\.json$`);
  const files = readdirSync(dir).sort();
  const fixtures: Fixture<Static<Res>>[] = [];
  for (const file of files) {
    const match = pattern.exec(file);
    if (!match) continue;
    const variant = match[1] ?? '';
    const response = readJson(dir, file);
    assertSchema(responseSchema, response, file);
    const requestFile = file.replace(/\.response\.json$/, '.request.json');
    let language: string | null = null;
    if (files.includes(requestFile)) {
      const request = readJson(dir, requestFile);
      assertSchema(requestSchema, request, requestFile);
      language = languageOf(request as Static<Req>);
    }
    fixtures.push({ variant, language, response: response as Static<Res> });
  }
  if (fixtures.length === 0) throw new FixtureError(`No ${endpoint} example found in contracts/examples.`);
  return fixtures;
}

/** Parses an SSE transcript in §7.7 wire format. Throws on anything else. */
export function parseTranscript(text: string, file = 'mimo.sse.txt'): TranscriptItem[] {
  const items: TranscriptItem[] = [];
  text.split('\n').forEach((raw, index) => {
    const line = raw.replace(/\r$/, '');
    if (line === '') return;
    const where = `contracts/examples/${file}:${index + 1}`;
    if (line.startsWith(':')) {
      items.push({ kind: 'comment', text: line.slice(1).trimStart() });
    } else if (line.startsWith('data: ')) {
      let event: unknown;
      try {
        event = JSON.parse(line.slice('data: '.length));
      } catch (err) {
        throw new FixtureError(`${where} isn't JSON: ${(err as Error).message}`);
      }
      if (!Value.Check(SseEvent, event)) throw new FixtureError(`${where} isn't a valid SSE event.`);
      items.push({ kind: 'event', event });
    } else {
      throw new FixtureError(`${where} is neither a data line nor a comment.`);
    }
  });
  if (!items.some((i) => i.kind === 'event' && i.event.type === 'done')) {
    throw new FixtureError(`contracts/examples/${file} has no done event.`);
  }
  return items;
}

/** The one language of a transcript's phrase events, or null if it has none. Mixed languages throw. */
function transcriptLanguage(items: TranscriptItem[], file: string): string | null {
  const languages = new Set(items.flatMap((i) => (i.kind === 'event' && i.event.type === 'phrase' ? [i.event.phrase.lang] : [])));
  if (languages.size > 1) throw new FixtureError(`contracts/examples/${file} mixes phrase languages: ${[...languages].join(', ')}.`);
  return [...languages][0] ?? null;
}

/** Finds every `mimo[.<variant>].sse.txt`, e.g. mimo.sse.txt (ja) and mimo.zh-hans.sse.txt. */
function loadTranscripts(dir: string): Fixture<TranscriptItem[]>[] {
  const pattern = /^mimo(?:\.([a-z0-9-]+))?\.sse\.txt$/;
  const fixtures: Fixture<TranscriptItem[]>[] = [];
  for (const file of readdirSync(dir).sort()) {
    const match = pattern.exec(file);
    if (!match) continue;
    const items = parseTranscript(readFileSync(join(dir, file), 'utf8'), file);
    fixtures.push({ variant: match[1] ?? '', language: transcriptLanguage(items, file), response: items });
  }
  if (fixtures.length === 0) throw new FixtureError('No mimo.sse.txt transcript found in contracts/examples.');
  return fixtures;
}

export function loadFixtures(dir = EXAMPLES_DIR): FixtureSet {
  return {
    placeCard: loadPairs(dir, 'place-card', PlaceCardRequest, PlaceCardResponse, (r) => r.situation.localLanguage),
    discover: loadPairs(dir, 'discover', DiscoverRequest, DiscoverResponse, (r) => r.situation.localLanguage),
    allergyCard: loadPairs(dir, 'allergy-card', AllergyCardRequest, AllergyCardResponse, (r) => r.language),
    mimo: loadTranscripts(dir),
  };
}

/**
 * The fixture for a language: an exact tag match (ja → the Tokyo variant, zh-Hans → the
 * zh-Hans or Shanghai one), then the same primary subtag (ja-JP → ja, zh-Hant → zh-Hans),
 * then the default (the file with no variant infix).
 * FixtureRyokoAPI in ios/Ryoko/App/Core/ follows the same rule; keep the two in step.
 */
export function pickFixture<Res>(fixtures: Fixture<Res>[], language: string): Fixture<Res> {
  const primary = (tag: string) => tag.split('-')[0]?.toLowerCase();
  return (
    fixtures.find((f) => f.language === language) ??
    fixtures.find((f) => f.language !== null && primary(f.language) === primary(language)) ??
    fixtures.find((f) => f.variant === '') ??
    (fixtures[0] as Fixture<Res>)
  );
}
