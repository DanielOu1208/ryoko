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

/** One example request/response pair, e.g. place-card.tokyo.{request,response}.json. */
export interface Fixture<Res> {
  /** '' for the default pair (`place-card.response.json`), otherwise the infix (`tokyo`). */
  variant: string;
  /** The local language this pair is for, from its request. */
  language: string | null;
  response: Res;
}

export type TranscriptItem = { kind: 'event'; event: SseEvent } | { kind: 'comment'; text: string };

export interface FixtureSet {
  placeCard: Fixture<PlaceCardResponse>[];
  discover: Fixture<DiscoverResponse>[];
  allergyCard: Fixture<AllergyCardResponse>[];
  mimo: TranscriptItem[];
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

export function loadFixtures(dir = EXAMPLES_DIR): FixtureSet {
  return {
    placeCard: loadPairs(dir, 'place-card', PlaceCardRequest, PlaceCardResponse, (r) => r.situation.localLanguage),
    discover: loadPairs(dir, 'discover', DiscoverRequest, DiscoverResponse, (r) => r.situation.localLanguage),
    allergyCard: loadPairs(dir, 'allergy-card', AllergyCardRequest, AllergyCardResponse, (r) => r.language),
    mimo: parseTranscript(readFileSync(join(dir, 'mimo.sse.txt'), 'utf8')),
  };
}

/**
 * The fixture for a language: an exact tag match (ja → Tokyo, zh-Hans → Shanghai),
 * then the same primary language (zh-Hant → zh-Hans), then the default pair.
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
