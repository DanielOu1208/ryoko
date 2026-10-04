// POST /v1/place-photos: a photo url per place, or none (design §4.7, §7).
//
// - Off (no FOURSQUARE_API_KEY, or MODEL=faux): every place gets no url and
//   nothing is called, so the app falls back to Look Around silently.
// - Per place: the cache first (normalized name plus the coordinate to 4
//   decimals, about 10 m). A photo is kept 30 days, "no photo" 7 days, errors
//   never. On a miss, one Foursquare search (./foursquare.ts).
// - At most 4 searches at once; places already being looked up are joined,
//   not searched again.
// - Each search adds its estimated cost to the daily budget. Once the day's
//   budget is spent, only cached answers are served.
// - When Foursquare refuses the key or the account (401, 402, 403, 429: no
//   credits, say), no search is made for 5 minutes.
// - A request answers within about 12 s: a place still being looked up then
//   gets no url, and its search lands in the cache for next time.
// - One log line per request: places, cache hits, searches, photos found.

import { join } from 'node:path';
import type { PlacePhoto, PlacePhotoQuery, PlacePhotosRequest, PlacePhotosResponse } from '@ryoko/contracts';
import { cacheKey, ResponseCache } from '../cache.ts';
import type { Config } from '../config.ts';
import type { Budget } from '../llm/budget.ts';
import {
  createFoursquareSearch,
  FOURSQUARE_SEARCH_COST_USD,
  FoursquareError,
  normalizeName,
  photoUrl,
  pickMatch,
  type FoursquarePlace,
  type FoursquareSearch,
  type PhotoUrl,
} from './foursquare.ts';

export type PlacePhotos = (request: PlacePhotosRequest) => Promise<PlacePhotosResponse>;

/** Bump when the photo url's size or the matching changes, so old answers aren't reused. */
export const PHOTO_CACHE_VERSION = 1;
export const PHOTO_TTL_MS = 30 * 24 * 3600_000;
export const NO_PHOTO_TTL_MS = 7 * 24 * 3600_000;
const DAY_MS = 24 * 3600_000;

/** What the cache holds per place. */
interface CachedAnswer {
  photo: PhotoUrl | null;
  checkedAt: number;
}

/** How one place was answered. */
type Source = 'cache' | 'shared' | 'searched' | 'skipped' | 'error' | 'late';

export interface PlacePhotosStats {
  places: number;
  cached: number;
  shared: number;
  searches: number;
  found: number;
  errors: number;
  late: number;
  skipped: number;
}

export interface PlacePhotosOptions {
  /** null turns the service off; `offReason` says why in the log. */
  search: FoursquareSearch | null;
  offReason?: string;
  cache?: ResponseCache;
  budget?: Budget | null;
  /** Searches at once. */
  concurrency?: number;
  /** How long Foursquare calls stop after it refuses the key or the account. */
  pauseMs?: number;
  /** How long one request waits for its places. */
  requestDeadlineMs?: number;
  now?: () => number;
  log?: (line: string) => void;
  onStats?: (stats: PlacePhotosStats) => void;
}

/** The cache key: normalized name and the coordinate rounded to 4 decimals (about 10 m). */
export function photoCacheKey(place: Pick<PlacePhotoQuery, 'name' | 'coordinate'>): string {
  const name = normalizeName(place.name) || place.name.trim().toLowerCase();
  const round = (value: number) => (Math.round(value * 1e4) / 1e4 + 0).toFixed(4); // + 0 turns -0 into 0
  return cacheKey(['place-photo', PHOTO_CACHE_VERSION, name, round(place.coordinate.lat), round(place.coordinate.lon)]);
}

/** At most `limit` tasks at once; the rest wait in order. */
class Limiter {
  private running = 0;
  private readonly waiting: (() => void)[] = [];
  private readonly limit: number;
  constructor(limit: number) {
    this.limit = limit;
  }

  async run<T>(task: () => Promise<T>): Promise<T> {
    if (this.running >= this.limit) await new Promise<void>((resolve) => this.waiting.push(resolve));
    else this.running += 1;
    try {
      return await task();
    } finally {
      const next = this.waiting.shift();
      if (next) next();
      else this.running -= 1;
    }
  }
}

/** Thrown inside a limiter slot when a search must not be made after all. */
class Skipped extends Error {}

export function createPlacePhotoService(options: PlacePhotosOptions): PlacePhotos {
  const log = options.log ?? (() => {});
  const now = options.now ?? Date.now;
  const search = options.search;

  if (!search) {
    const reason = options.offReason ?? 'off';
    return async (request) => {
      const photos = distinct(request.places).map((place) => ({ key: place.key }));
      log(`place-photos: ${photos.length} place(s), off (${reason})`);
      options.onStats?.({ places: photos.length, cached: 0, shared: 0, searches: 0, found: 0, errors: 0, late: 0, skipped: photos.length });
      return { photos };
    };
  }

  const cache = options.cache ?? new ResponseCache({ file: null, maxEntries: 5000, ttlMs: PHOTO_TTL_MS + DAY_MS, now });
  const budget = options.budget ?? null;
  const limiter = new Limiter(options.concurrency ?? 4);
  const pauseMs = options.pauseMs ?? 5 * 60_000;
  const deadlineMs = options.requestDeadlineMs ?? 12_000;
  const inFlight = new Map<string, Promise<PhotoUrl | null>>();
  let pausedUntil = 0;

  const isFresh = (answer: CachedAnswer | undefined): answer is CachedAnswer =>
    !!answer && now() - answer.checkedAt < (answer.photo ? PHOTO_TTL_MS : NO_PHOTO_TTL_MS);
  const overBudget = () => !!budget && budget.spentTodayUsd >= budget.limitUsd;
  const canSearch = () => now() >= pausedUntil && !overBudget();

  /** Stops searches for a while after Foursquare refuses the key or the account. */
  function pause(err: FoursquareError): void {
    if (now() < pausedUntil) return;
    pausedUntil = now() + pauseMs;
    log(`place-photos: ${err.message}; no Foursquare calls for ${Math.round(pauseMs / 60_000)} min`);
  }

  /** One search, inside a limiter slot. Throws on errors (never cached) and Skipped. */
  async function searchFor(place: PlacePhotoQuery): Promise<PhotoUrl | null> {
    if (!canSearch()) throw new Skipped();
    let results: FoursquarePlace[];
    try {
      results = await search!({ name: place.name, lat: place.coordinate.lat, lon: place.coordinate.lon });
    } catch (err) {
      // Before the slot passes to the next search, so that one doesn't go out too.
      if (err instanceof FoursquareError && err.isAccountProblem) pause(err);
      throw err;
    }
    budget?.add(FOURSQUARE_SEARCH_COST_USD);
    const match = pickMatch(results, place.name, place.localName);
    for (const photo of match?.photos ?? []) {
      const url = photoUrl(photo);
      if (url) return url;
    }
    return null;
  }

  async function lookUp(place: PlacePhotoQuery): Promise<{ photo: PhotoUrl | null; source: Source; error?: string }> {
    const key = photoCacheKey(place);
    const cached = cache.get<CachedAnswer>(key);
    if (isFresh(cached)) return { photo: cached.photo, source: 'cache' };
    const running = inFlight.get(key);
    if (running) return { photo: await running.catch(() => null), source: 'shared' };
    if (!canSearch()) return { photo: null, source: 'skipped' };

    const lookup = limiter.run(() => searchFor(place));
    inFlight.set(key, lookup);
    try {
      const photo = await lookup;
      cache.set(key, { photo, checkedAt: now() } satisfies CachedAnswer);
      return { photo, source: 'searched' };
    } catch (err) {
      if (err instanceof Skipped) return { photo: null, source: 'skipped' };
      return { photo: null, source: 'error', error: describe(err) };
    } finally {
      inFlight.delete(key);
    }
  }

  return async (request) => {
    const places = distinct(request.places);
    let timer: ReturnType<typeof setTimeout> | undefined;
    const deadline = new Promise<'late'>((resolve) => {
      timer = setTimeout(() => resolve('late'), deadlineMs);
    });
    try {
      const answers = await Promise.all(
        places.map(async (place) => {
          // A late place keeps its lookup running, so the answer still reaches the cache.
          const answer = await Promise.race([lookUp(place), deadline]);
          return answer === 'late' ? { photo: null, source: 'late' as Source } : answer;
        }),
      );
      const photos: PlacePhoto[] = places.map((place, index) => ({ key: place.key, ...(answers[index]!.photo ?? {}) }));
      const count = (source: Source) => answers.filter((a) => a.source === source).length;
      const stats: PlacePhotosStats = {
        places: places.length,
        cached: count('cache'),
        shared: count('shared'),
        // Searches this request made itself; a late place's search may still be running.
        searches: count('searched') + count('error'),
        found: photos.filter((p) => p.url).length,
        errors: count('error'),
        late: count('late'),
        skipped: count('skipped'),
      };
      const firstError = answers.find((a): a is typeof a & { error: string } => 'error' in a && typeof a.error === 'string')?.error;
      log(statsLine(stats, now() < pausedUntil, overBudget(), firstError));
      options.onStats?.(stats);
      return { photos };
    } finally {
      clearTimeout(timer);
    }
  };
}

/** The places with their first-seen keys, in order. */
function distinct(places: readonly PlacePhotoQuery[]): PlacePhotoQuery[] {
  const seen = new Set<string>();
  return places.filter((place) => !seen.has(place.key) && !!seen.add(place.key));
}

function describe(err: unknown): string {
  if (err instanceof Error && (err.name === 'TimeoutError' || err.name === 'AbortError')) return 'timed out';
  if (err instanceof FoursquareError) return err.message;
  return err instanceof Error ? err.message.slice(0, 160) : 'unknown error';
}

function statsLine(stats: PlacePhotosStats, paused: boolean, overBudget: boolean, firstError?: string): string {
  const parts = [`${stats.cached} cached`];
  if (stats.shared) parts.push(`${stats.shared} shared`);
  parts.push(`${stats.searches} Foursquare call(s)`, `${stats.found} photo(s)`);
  if (stats.errors) parts.push(`${stats.errors} error(s)${firstError ? ` (${firstError})` : ''}`);
  if (stats.late) parts.push(`${stats.late} late`);
  if (stats.skipped) parts.push(`${stats.skipped} skipped${paused ? ' (paused)' : overBudget ? ' (over budget)' : ''}`);
  return `place-photos: ${stats.places} place(s), ${parts.join(', ')}`;
}

/** The service for this config: Foursquare when FOURSQUARE_API_KEY is set and MODEL isn't faux. */
export function placePhotosFromConfig(config: Config, options: { budget?: Budget | null; log?: (line: string) => void } = {}): PlacePhotos {
  const apiKey = config.env.FOURSQUARE_API_KEY?.trim();
  const log = options.log ?? (config.logRequests ? (line: string) => console.log(line) : () => {});
  if (config.model === 'faux') return createPlacePhotoService({ search: null, offReason: 'MODEL=faux', log });
  if (!apiKey) return createPlacePhotoService({ search: null, offReason: 'no FOURSQUARE_API_KEY', log });
  const cache = new ResponseCache({
    file: config.cacheDir ? join(config.cacheDir, 'place-photos.json') : null,
    maxEntries: 5000,
    ttlMs: PHOTO_TTL_MS + DAY_MS,
  });
  return createPlacePhotoService({ search: createFoursquareSearch({ apiKey }), cache, budget: options.budget ?? null, log });
}
