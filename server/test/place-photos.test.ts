// Place photos (POST /v1/place-photos): Foursquare matching, the photo url, the
// cache key, the service's cache, limits and fallbacks, and the route.
// Foursquare is always mocked here. Run: pnpm --dir server test

import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Value } from 'typebox/value';
import { ErrorEnvelope, PlacePhotosResponse, type PlacePhotoQuery, type PlacePhotosRequest } from '@ryoko/contracts';
import { createApp } from '../src/app.ts';
import { configFromEnv, describeConfig, type Config } from '../src/config.ts';
import { EXAMPLES_DIR } from '../src/fixtures.ts';
import { Budget } from '../src/llm/budget.ts';
import {
  createFoursquareSearch,
  FOURSQUARE_SEARCH_COST_USD,
  FoursquareError,
  nameScore,
  normalizeName,
  parseResults,
  photoUrl,
  pickMatch,
  type FoursquarePlace,
  type FoursquareSearch,
  type SearchQuery,
} from '../src/photos/foursquare.ts';
import { createPlacePhotoService, NO_PHOTO_TTL_MS, PHOTO_TTL_MS, photoCacheKey, placePhotosFromConfig, type PlacePhotosStats } from '../src/photos/service.ts';

const TOKEN = `test-token-${Math.random().toString(36).slice(2)}`;
const DAY = 24 * 3600_000;

function testConfig(env: Record<string, string> = {}): Config {
  return configFromEnv({ APP_TOKEN: TOKEN, MODEL: 'faux', FAUX_PACE: '0', LOG_REQUESTS: '0', CACHE_DIR: 'off', ...env });
}

function call(app: ReturnType<typeof createApp>['app'], body: unknown, headers: Record<string, string> = {}): Promise<Response> {
  return Promise.resolve(
    app.request('/v1/place-photos', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}`, 'X-Install-Id': 'install-test', ...headers },
      body: typeof body === 'string' ? body : JSON.stringify(body),
    }),
  );
}

const place = (name: string, distance: number, photos = 1): FoursquarePlace => ({
  name,
  distance,
  photos: Array.from({ length: photos }, (_, i) => ({ prefix: 'https://fastly.4sqi.net/img/general/', suffix: `/${normalizeName(name)}-${i}.jpg`, width: 1440, height: 1920 })),
});

const query = (key: string, name: string, extra: Partial<PlacePhotoQuery> = {}): PlacePhotoQuery => ({
  key,
  name,
  coordinate: { lat: 35.6889, lon: 139.7006 },
  ...extra,
});

/** A mocked Foursquare: answers from `results` by query name, and records every call. */
function mockSearch(results: Record<string, FoursquarePlace[] | Error>, options: { delayMs?: number } = {}) {
  const calls: SearchQuery[] = [];
  let running = 0;
  let maxRunning = 0;
  const search: FoursquareSearch = async (q) => {
    calls.push(q);
    running += 1;
    maxRunning = Math.max(maxRunning, running);
    try {
      if (options.delayMs) await new Promise((resolve) => setTimeout(resolve, options.delayMs));
      const answer = results[q.name] ?? [];
      if (answer instanceof Error) throw answer;
      return structuredClone(answer);
    } finally {
      running -= 1;
    }
  };
  return { search, calls, maxRunning: () => maxRunning };
}

describe('matching a Foursquare result to a place', () => {
  test('names compare without case, spaces or punctuation', () => {
    assert.equal(nameScore('Omoide Yokocho', 'omoide-yokocho'), 3);
    assert.equal(nameScore("BECK'S COFFEE SHOP", 'Becks Coffee Shop'), 3);
    assert.equal(nameScore('ＢＥＡＭＳ', 'beams'), 3, 'full-width letters are the same letters');
  });

  test('either name may contain the other', () => {
    assert.equal(nameScore('BEAMS', 'BEAMS NEWS'), 2);
    assert.equal(nameScore('BEAMS NEWS Shinjuku', 'BEAMS NEWS'), 2);
    assert.equal(nameScore('思い出横丁', '新宿 思い出横丁'), 2);
  });

  test("a mixed-script name matches on its Latin part when that's long enough", () => {
    assert.equal(nameScore("BECK'S COFFEE SHOP Shinjuku South exit", "BECK'S COFFEE SHOP 新宿南口店"), 1);
    assert.equal(nameScore('U by SPICK&SPAN 新宿ルミネ店', 'U by SPICK&SPAN ルミネ新宿'), 1);
    // A shared place word in the other script is not a match.
    assert.equal(nameScore('BEAMS 新宿', 'LUMINE 新宿'), 0);
    // Two all-Latin names never match on a part.
    assert.equal(nameScore('Coffee Shop', 'Coffee Shopping Mall Tokyo'), 2);
    assert.equal(nameScore('Blue Bottle Coffee', 'Starbucks Coffee'), 0);
  });

  test('very short names never match by containment', () => {
    assert.equal(nameScore('A', 'A Bathing Ape'), 0);
    assert.equal(nameScore('!!', 'Anything'), 0);
  });

  test('the best name wins, then the nearest', () => {
    const exactFar = place('BEAMS', 120);
    const containsNear = place('BEAMS NEWS', 10);
    assert.equal(pickMatch([containsNear, exactFar], 'BEAMS'), exactFar);
    const near = place('BEAMS', 30);
    assert.equal(pickMatch([exactFar, near], 'BEAMS'), near, 'a tie goes to the nearer');
    assert.equal(pickMatch([place('Ichiran', 20)], 'Menya Kaze', '麺屋 風'), null);
  });

  test('the local name may match instead of the name', () => {
    const yoshimoto = place('ルミネtheよしもと', 40);
    assert.equal(pickMatch([place('LUMINE EST', 10), yoshimoto], 'Lumine the Yoshimoto'), null);
    assert.equal(pickMatch([place('LUMINE EST', 10), yoshimoto], 'Lumine the Yoshimoto', 'ルミネtheよしもと'), yoshimoto);
  });

  test("Foursquare's results are read defensively", () => {
    const parsed = parseResults(
      {
        results: [
          { name: 'Omoide Yokocho', distance: 12, photos: [{ prefix: 'https://a/', suffix: '/x.jpg', width: 800, height: 600 }, { prefix: 1 }] },
          { name: 'No distance', latitude: 35.6889, longitude: 139.7016 },
          { name: '' },
          null,
        ],
      },
      { name: 'q', lat: 35.6889, lon: 139.7006 },
    );
    assert.equal(parsed.length, 2);
    assert.deepEqual(parsed[0], { name: 'Omoide Yokocho', distance: 12, photos: [{ prefix: 'https://a/', suffix: '/x.jpg', width: 800, height: 600 }] });
    assert.ok(Math.abs(parsed[1]!.distance - 90) < 2, 'distance from the coordinates when Foursquare leaves it out');
    assert.deepEqual(parseResults({ message: 'nope' }, { name: 'q', lat: 0, lon: 0 }), []);
  });
});

describe('the photo url', () => {
  test('960 px on the longer side, keeping the aspect', () => {
    const url = photoUrl({ prefix: 'https://fastly.4sqi.net/img/general/', suffix: '/123_abc.jpg', width: 1440, height: 1920 });
    assert.deepEqual(url, { url: 'https://fastly.4sqi.net/img/general/720x960/123_abc.jpg', width: 720, height: 960 });
    const wide = photoUrl({ prefix: 'https://p/', suffix: '/w.jpg', width: 4032, height: 3024 });
    assert.equal(wide?.url, 'https://p/960x720/w.jpg');
  });

  test('original when the photo is small or its size is unknown, and https only', () => {
    assert.deepEqual(photoUrl({ prefix: 'https://p/', suffix: '/s.jpg', width: 800, height: 600 }), { url: 'https://p/original/s.jpg', width: 800, height: 600 });
    assert.deepEqual(photoUrl({ prefix: 'https://p/', suffix: '/u.jpg' }), { url: 'https://p/original/u.jpg' });
    assert.equal(photoUrl({ prefix: 'http://p/', suffix: '/h.jpg' }), null);
    assert.equal(photoUrl({ prefix: 'not a url', suffix: '' }), null);
  });
});

describe('the cache key', () => {
  const at = (lat: number, lon: number) => ({ lat, lon });
  test('normalized name plus the coordinate to about 10 m', () => {
    const key = photoCacheKey({ name: 'Omoide Yokocho', coordinate: at(35.69301, 139.69951) });
    assert.equal(photoCacheKey({ name: '  omoide-YOKOCHO ', coordinate: at(35.69304, 139.69949) }), key);
    assert.notEqual(photoCacheKey({ name: 'Omoide Yokocho', coordinate: at(35.6932, 139.6995) }), key, 'about 20 m away is another key');
    assert.notEqual(photoCacheKey({ name: 'Omoide Yokocho 2', coordinate: at(35.69301, 139.69951) }), key);
    assert.equal(photoCacheKey({ name: 'x', coordinate: at(-0.00001, 0) }), photoCacheKey({ name: 'x', coordinate: at(0.00001, 0) }), '-0 rounds like 0');
    assert.notEqual(photoCacheKey({ name: '!!', coordinate: at(0, 0) }), photoCacheKey({ name: '??', coordinate: at(0, 0) }), 'a name with no letters still has a key');
  });
});

describe('the Foursquare client', () => {
  const KEY = 'fsq-test-key-abcdefghijklmnopqrstuvwxyz0123456789';

  test('one search with the place, 150 m, 3 results and the photos field', async () => {
    const requests: { url: string; headers: Record<string, string> }[] = [];
    const search = createFoursquareSearch({
      apiKey: KEY,
      fetch: async (input, init) => {
        requests.push({ url: String(input), headers: init?.headers as Record<string, string> });
        return Response.json({ results: [{ name: 'BEAMS', distance: 30, photos: [] }] });
      },
    });
    const results = await search({ name: 'BEAMS', lat: 35.6889, lon: 139.7006 });
    assert.deepEqual(results, [{ name: 'BEAMS', distance: 30, photos: [] }]);
    const url = new URL(requests[0]!.url);
    assert.equal(url.origin + url.pathname, 'https://places-api.foursquare.com/places/search');
    assert.equal(url.searchParams.get('ll'), '35.688900,139.700600');
    assert.equal(url.searchParams.get('query'), 'BEAMS');
    assert.equal(url.searchParams.get('radius'), '150');
    assert.equal(url.searchParams.get('limit'), '3');
    assert.ok(url.searchParams.get('fields')?.split(',').includes('photos'));
    assert.equal(requests[0]!.headers.Authorization, `Bearer ${KEY}`);
    assert.equal(requests[0]!.headers['X-Places-Api-Version'], '2025-06-17');
    assert.ok(!requests[0]!.url.includes(KEY), 'the key is never in the url');
  });

  test("an HTTP error is a FoursquareError without the key, and 429 means the account (credits)", async () => {
    const search = createFoursquareSearch({
      apiKey: KEY,
      fetch: async () => Response.json({ message: `Your account has no API credits remaining. key ${KEY}` }, { status: 429 }),
    });
    await assert.rejects(search({ name: 'x', lat: 0, lon: 0 }), (err: unknown) => {
      assert.ok(err instanceof FoursquareError);
      assert.equal(err.status, 429);
      assert.equal(err.isAccountProblem, true);
      assert.match(err.message, /no API credits/);
      assert.ok(!err.message.includes(KEY));
      return true;
    });
    assert.equal(new FoursquareError(500, '').isAccountProblem, false);
  });
});

describe('the place-photos service', () => {
  const omoide = query('omoide', 'Omoide Yokocho', { localName: '思い出横丁', coordinate: { lat: 35.693, lon: 139.6995 } });
  const beams = query('beams', 'BEAMS');
  const kaze = query('kaze', 'Menya Kaze');

  test('a search per place on a miss; every answer, "no photo" included, is cached', async () => {
    const mock = mockSearch({ 'Omoide Yokocho': [place('思い出横丁', 15)], BEAMS: [place('BEAMS NEWS', 33)], 'Menya Kaze': [] });
    const stats: PlacePhotosStats[] = [];
    const service = createPlacePhotoService({ search: mock.search, onStats: (s) => stats.push(s) });
    const first = await service({ places: [omoide, beams, kaze] });
    assert.ok(Value.Check(PlacePhotosResponse, first));
    assert.deepEqual(first.photos.map((p) => p.key), ['omoide', 'beams', 'kaze']);
    assert.match(first.photos[0]!.url!, /^https:\/\/fastly\.4sqi\.net\/img\/general\/720x960\//);
    assert.deepEqual([first.photos[0]!.width, first.photos[0]!.height], [720, 960]);
    assert.ok(first.photos[1]!.url);
    assert.equal(first.photos[2]!.url, undefined);
    assert.equal(mock.calls.length, 3);
    assert.deepEqual(stats[0], { places: 3, cached: 0, shared: 0, searches: 3, found: 2, errors: 0, late: 0, skipped: 0 });

    const again = await service({ places: [kaze, beams, omoide] });
    assert.equal(mock.calls.length, 3, 'all from the cache');
    assert.deepEqual(again.photos.map((p) => p.key), ['kaze', 'beams', 'omoide']);
    assert.equal(again.photos[2]!.url, first.photos[0]!.url);
    assert.equal(stats[1]!.cached, 3);
  });

  test('the cache key ignores the app key: the same place under another key is a hit', async () => {
    const mock = mockSearch({ BEAMS: [place('BEAMS', 20)] });
    const service = createPlacePhotoService({ search: mock.search });
    await service({ places: [beams] });
    const other = await service({ places: [{ ...beams, key: 'I-another-key', name: 'beams' }] });
    assert.equal(mock.calls.length, 1);
    assert.equal(other.photos[0]!.key, 'I-another-key');
    assert.ok(other.photos[0]!.url);
  });

  test('a photo is kept 30 days, "no photo" 7 days', async () => {
    let now = 1_000_000;
    const mock = mockSearch({ BEAMS: [place('BEAMS', 20)], 'Menya Kaze': [] });
    const service = createPlacePhotoService({ search: mock.search, now: () => now });
    await service({ places: [beams, kaze] });
    now += NO_PHOTO_TTL_MS - 1000;
    await service({ places: [beams, kaze] });
    assert.equal(mock.calls.length, 2);
    now += 2000;
    await service({ places: [beams, kaze] });
    assert.deepEqual(mock.calls.slice(2).map((c) => c.name), ['Menya Kaze'], '"no photo" expired after 7 days');
    now = 1_000_000 + PHOTO_TTL_MS + 1000;
    await service({ places: [beams] });
    assert.equal(mock.calls.at(-1)?.name, 'BEAMS', 'a photo expires after 30 days');
  });

  test('errors are never cached', async () => {
    const results: Record<string, FoursquarePlace[] | Error> = { BEAMS: new Error('socket hang up') };
    const mock = mockSearch(results);
    const lines: string[] = [];
    const service = createPlacePhotoService({ search: mock.search, log: (line) => lines.push(line) });
    const failed = await service({ places: [beams] });
    assert.deepEqual(failed.photos, [{ key: 'beams' }]);
    assert.match(lines[0]!, /1 error\(s\) \(socket hang up\)/);
    results.BEAMS = [place('BEAMS', 20)];
    const ok = await service({ places: [beams] });
    assert.equal(mock.calls.length, 2);
    assert.ok(ok.photos[0]!.url);
  });

  test('the same place asked for at once is searched once', async () => {
    const mock = mockSearch({ BEAMS: [place('BEAMS', 20)] }, { delayMs: 30 });
    const stats: PlacePhotosStats[] = [];
    const service = createPlacePhotoService({ search: mock.search, onStats: (s) => stats.push(s) });
    const [a, b] = await Promise.all([service({ places: [beams] }), service({ places: [{ ...beams, key: 'beams-2' }] })]);
    assert.equal(mock.calls.length, 1);
    assert.ok(a.photos[0]!.url && a.photos[0]!.url === b.photos[0]!.url);
    assert.deepEqual(stats.map((s) => [s.searches, s.shared]).sort(), [[0, 1], [1, 0]]);
  });

  test('duplicate keys in one request get one answer', async () => {
    const mock = mockSearch({ BEAMS: [place('BEAMS', 20)] });
    const service = createPlacePhotoService({ search: mock.search });
    const response = await service({ places: [beams, beams, kaze] });
    assert.deepEqual(response.photos.map((p) => p.key), ['beams', 'kaze']);
  });

  test('at most 4 searches at once', async () => {
    const mock = mockSearch({}, { delayMs: 15 });
    const service = createPlacePhotoService({ search: mock.search });
    const places = Array.from({ length: 12 }, (_, i) => query(`p${i}`, `Place ${i}`));
    await service({ places });
    assert.equal(mock.calls.length, 12);
    assert.equal(mock.maxRunning(), 4);
  });

  test('each search adds its cost to the daily budget; once spent, no more searches', async () => {
    const budget = new Budget({ limitUsd: FOURSQUARE_SEARCH_COST_USD * 2, file: null });
    const mock = mockSearch({ BEAMS: [place('BEAMS', 20)] });
    const stats: PlacePhotosStats[] = [];
    const service = createPlacePhotoService({ search: mock.search, budget, onStats: (s) => stats.push(s), concurrency: 1 });
    await service({ places: [beams, kaze] });
    assert.ok(Math.abs(budget.spentTodayUsd - FOURSQUARE_SEARCH_COST_USD * 2) < 1e-9);
    const over = await service({ places: [omoide] });
    assert.equal(mock.calls.length, 2);
    assert.deepEqual(over.photos, [{ key: 'omoide' }]);
    assert.equal(stats[1]!.skipped, 1);
    // Cached answers are still served.
    assert.ok((await service({ places: [beams] })).photos[0]!.url);
  });

  test('when Foursquare refuses the account (no credits), searches pause, then resume', async () => {
    let now = 0;
    const results: Record<string, FoursquarePlace[] | Error> = { BEAMS: new FoursquareError(429, 'Your account has no API credits remaining.') };
    const mock = mockSearch(results);
    const lines: string[] = [];
    const service = createPlacePhotoService({ search: mock.search, now: () => now, pauseMs: 60_000, log: (line) => lines.push(line), concurrency: 1 });
    await service({ places: [beams, kaze] });
    assert.equal(mock.calls.length, 1, 'the second place is skipped once the first is refused');
    assert.ok(lines.some((line) => /HTTP 429.*no Foursquare calls for 1 min/.test(line)));
    await service({ places: [beams, kaze, omoide] });
    assert.equal(mock.calls.length, 1, 'paused');
    assert.match(lines.at(-1)!, /3 skipped \(paused\)/);
    now += 61_000;
    results.BEAMS = [place('BEAMS', 20)];
    const resumed = await service({ places: [beams] });
    assert.equal(mock.calls.length, 2);
    assert.ok(resumed.photos[0]!.url);
  });

  test('a request answers by its deadline; a late search still lands in the cache', async () => {
    const mock = mockSearch({ BEAMS: [place('BEAMS', 20)] }, { delayMs: 80 });
    const stats: PlacePhotosStats[] = [];
    const service = createPlacePhotoService({ search: mock.search, requestDeadlineMs: 20, onStats: (s) => stats.push(s) });
    const late = await service({ places: [beams] });
    assert.deepEqual(late.photos, [{ key: 'beams' }]);
    assert.equal(stats[0]!.late, 1);
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.ok((await service({ places: [beams] })).photos[0]!.url);
    assert.equal(mock.calls.length, 1);
  });

  test('with no key, or in faux mode, nothing is searched and no place has a url', async () => {
    const envs: Record<string, string>[] = [{ MODEL: 'gmi' }, { MODEL: 'faux', FOURSQUARE_API_KEY: 'set-but-faux' }];
    for (const env of envs) {
      const lines: string[] = [];
      const service = placePhotosFromConfig(testConfig(env), { log: (line) => lines.push(line) });
      const response = await service({ places: [omoide, beams, omoide] });
      assert.deepEqual(response.photos, [{ key: 'omoide' }, { key: 'beams' }]);
      assert.match(lines[0]!, env.MODEL === 'faux' ? /off \(MODEL=faux\)/ : /off \(no FOURSQUARE_API_KEY\)/);
    }
  });
});

describe('POST /v1/place-photos', () => {
  const example = JSON.parse(readFileSync(join(EXAMPLES_DIR, 'place-photos.request.json'), 'utf8')) as PlacePhotosRequest;

  test('with no FOURSQUARE_API_KEY: 200, every place with no url', async () => {
    const { app } = createApp(testConfig({ MODEL: 'gmi' }));
    const res = await call(app, example);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.ok(Value.Check(PlacePhotosResponse, body));
    assert.deepEqual(body, { photos: example.places.map((p) => ({ key: p.key })) });
  });

  test('in faux mode: 200, no urls', async () => {
    const { app } = createApp(testConfig());
    const body = await (await call(app, example)).json();
    assert.ok(body.photos.every((p: { url?: string }) => p.url === undefined));
  });

  test('answers from the service, checked against the contract', async () => {
    const mock = mockSearch({ 'Omoide Yokocho': [place('思い出横丁', 15)] });
    const { app } = createApp(testConfig(), { placePhotos: createPlacePhotoService({ search: mock.search }) });
    const body = await (await call(app, example)).json();
    assert.ok(Value.Check(PlacePhotosResponse, body));
    assert.ok(body.photos[0]!.url);
    assert.equal(body.photos[1]!.url, undefined);
  });

  test('refuses requests that break the contract', async () => {
    const { app } = createApp(testConfig());
    const base = example.places[0]!;
    const bad: unknown[] = [
      { places: [] },
      { places: Array.from({ length: 26 }, (_, i) => ({ ...base, key: `k${i}` })) },
      { places: [{ ...base, key: 'k'.repeat(121) }] },
      { places: [{ ...base, coordinate: { lat: 91, lon: 0 } }] },
      { places: [{ key: 'k', name: 'n' }] },
      { places: [{ ...base, extra: true }] },
      'not json',
    ];
    for (const body of bad) {
      const res = await call(app, body);
      assert.equal(res.status, 400, JSON.stringify(body).slice(0, 60));
      const envelope = await res.json();
      assert.ok(Value.Check(ErrorEnvelope, envelope));
      assert.equal(envelope.error.code, 'invalid_request');
    }
    const unauthorized = await app.request('/v1/place-photos', { method: 'POST', body: JSON.stringify(example) });
    assert.equal(unauthorized.status, 401);
  });

  test('has its own rate-limit bucket, so thumbnails never use up the place cards', async () => {
    const { app } = createApp(testConfig({ RATE_LIMIT_PER_MINUTE: '2' }));
    const card = JSON.parse(readFileSync(join(EXAMPLES_DIR, 'place-card.request.json'), 'utf8'));
    const placeCard = () =>
      app.request('/v1/place-card', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}`, 'X-Install-Id': 'install-test' }, body: JSON.stringify(card) });
    for (let i = 0; i < 2; i++) assert.equal((await call(app, example)).status, 200);
    assert.equal((await call(app, example)).status, 429);
    assert.equal((await placeCard()).status, 200, 'place cards still answer');
  });

  test('the config summary says whether photos are on, never the key', () => {
    const key = 'fsq-secret-value-0123456789abcdef';
    const config = testConfig({ MODEL: 'gmi', FOURSQUARE_API_KEY: key });
    assert.equal(config.placePhotos.configured, true);
    const text = describeConfig(config);
    assert.match(text, /place photos on \(Foursquare\)/);
    assert.ok(!text.includes(key));
    assert.match(describeConfig(testConfig({ MODEL: 'gmi' })), /place photos off \(no FOURSQUARE_API_KEY\)/);
  });
});
