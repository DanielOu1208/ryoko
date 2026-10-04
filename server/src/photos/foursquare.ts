// Place photos from the Foursquare Places API (POST /v1/place-photos).
//
// One Place Search per place: `ll` = the place's coordinate, `query` = its
// name, 150 m, 3 results, with the Premium `photos` field (billed from the
// first call, about $18.75 per 1,000). The service in ./service.ts caches the
// answers, so most places cost one call ever.
//
// The key goes in the Authorization header only. It's never logged or put in
// an error message; Foursquare's own error text goes through
// providerErrorText, which masks anything token-like.

import { providerErrorText } from '../llm/registry.ts';

export const FOURSQUARE_SEARCH_URL = 'https://places-api.foursquare.com/places/search';
export const FOURSQUARE_API_VERSION = '2025-06-17';
/** Estimated cost of one search with the Premium photos field, in US dollars. */
export const FOURSQUARE_SEARCH_COST_USD = 0.01875;
export const SEARCH_RADIUS_METERS = 150;
export const SEARCH_LIMIT = 3;
const SEARCH_FIELDS = 'fsq_place_id,name,latitude,longitude,distance,photos';

/**
 * The longer side of the photo we ask for, in pixels. One url serves the 56 pt
 * list thumbnail (168 px at 3x) and the place card's 150 pt header (about
 * 1,100 × 450 px at 3x, aspect fill), so it's big enough for the header but
 * far smaller than Foursquare's originals (often 1,440 × 1,920 or more).
 */
export const PHOTO_MAX_SIDE = 960;

export interface FoursquarePhoto {
  prefix: string;
  suffix: string;
  width?: number;
  height?: number;
}

export interface FoursquarePlace {
  name: string;
  /** Metres from the search point. */
  distance: number;
  photos: FoursquarePhoto[];
}

export interface SearchQuery {
  name: string;
  lat: number;
  lon: number;
}

/** One Place Search. Throws FoursquareError for an HTTP error, or the fetch's own error (timeout, network). */
export type FoursquareSearch = (query: SearchQuery) => Promise<FoursquarePlace[]>;

export class FoursquareError extends Error {
  readonly status: number;
  constructor(status: number, detail: string) {
    super(`Foursquare answered HTTP ${status}${detail ? `: ${detail}` : ''}`);
    this.name = 'FoursquareError';
    this.status = status;
  }

  /** The key, the account or its credits: every call will fail the same way for a while. */
  get isAccountProblem(): boolean {
    return this.status === 401 || this.status === 402 || this.status === 403 || this.status === 429;
  }
}

export interface FoursquareSearchOptions {
  apiKey: string;
  /** Defaults to the global fetch. Tests inject their own. */
  fetch?: typeof fetch;
  /** Per call. */
  timeoutMs?: number;
}

export function searchUrl(query: SearchQuery): string {
  const params = new URLSearchParams({
    ll: `${query.lat.toFixed(6)},${query.lon.toFixed(6)}`,
    query: query.name,
    radius: String(SEARCH_RADIUS_METERS),
    limit: String(SEARCH_LIMIT),
    fields: SEARCH_FIELDS,
  });
  return `${FOURSQUARE_SEARCH_URL}?${params}`;
}

const finite = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value);

/** Metres between two coordinates (haversine), for a result without `distance`. */
export function metresBetween(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const rad = Math.PI / 180;
  const dLat = (lat2 - lat1) * rad;
  const dLon = (lon2 - lon1) * rad;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.min(1, Math.sqrt(a)));
}

/** The results we can use, from Foursquare's JSON. Anything malformed is skipped. */
export function parseResults(body: unknown, query: SearchQuery): FoursquarePlace[] {
  const results = (body as { results?: unknown } | null)?.results;
  if (!Array.isArray(results)) return [];
  const places: FoursquarePlace[] = [];
  for (const item of results as Record<string, unknown>[]) {
    if (!item || typeof item.name !== 'string' || !item.name.trim()) continue;
    let distance = finite(item.distance) ? item.distance : Number.NaN;
    if (Number.isNaN(distance) && finite(item.latitude) && finite(item.longitude)) {
      distance = metresBetween(query.lat, query.lon, item.latitude, item.longitude);
    }
    const photos: FoursquarePhoto[] = [];
    for (const photo of Array.isArray(item.photos) ? (item.photos as Record<string, unknown>[]) : []) {
      if (!photo || typeof photo.prefix !== 'string' || typeof photo.suffix !== 'string') continue;
      photos.push({
        prefix: photo.prefix,
        suffix: photo.suffix,
        ...(finite(photo.width) && photo.width > 0 ? { width: Math.round(photo.width) } : {}),
        ...(finite(photo.height) && photo.height > 0 ? { height: Math.round(photo.height) } : {}),
      });
    }
    places.push({ name: item.name.trim(), distance: Number.isNaN(distance) ? Number.POSITIVE_INFINITY : distance, photos });
  }
  return places;
}

export interface PhotoUrl {
  url: string;
  width?: number;
  height?: number;
}

/**
 * The photo's url at PHOTO_MAX_SIDE on its longer side, keeping its aspect
 * (Foursquare's `WxH` size scales when it matches the photo's aspect), or
 * `original` when it's already that small or its size is unknown. null unless
 * it's an https url.
 */
export function photoUrl(photo: FoursquarePhoto, maxSide = PHOTO_MAX_SIDE): PhotoUrl | null {
  let size = 'original';
  let width = photo.width;
  let height = photo.height;
  if (width && height && Math.max(width, height) > maxSide) {
    const scale = maxSide / Math.max(width, height);
    width = Math.max(1, Math.round(width * scale));
    height = Math.max(1, Math.round(height * scale));
    size = `${width}x${height}`;
  }
  let url: URL;
  try {
    url = new URL(`${photo.prefix}${size}${photo.suffix}`);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:') return null;
  // href percent-encodes anything outside ASCII, so it's a valid URI.
  return { url: url.href, ...(width ? { width } : {}), ...(height ? { height } : {}) };
}

/** Foursquare's error text from `{message}`, masked, without the rest of the body. */
function errorDetail(body: unknown): string {
  const message = (body as { message?: unknown } | null)?.message;
  return typeof message === 'string' ? providerErrorText(message).slice(0, 160) : '';
}

export function createFoursquareSearch(options: FoursquareSearchOptions): FoursquareSearch {
  const doFetch = options.fetch ?? fetch;
  const timeoutMs = options.timeoutMs ?? 5000;
  return async (query) => {
    const response = await doFetch(searchUrl(query), {
      headers: {
        Authorization: `Bearer ${options.apiKey}`,
        'X-Places-Api-Version': FOURSQUARE_API_VERSION,
        accept: 'application/json',
      },
      signal: AbortSignal.timeout(timeoutMs),
    });
    let body: unknown = null;
    try {
      body = await response.json();
    } catch {
      // not JSON: handled below
    }
    if (!response.ok) throw new FoursquareError(response.status, errorDetail(body));
    return parseResults(body, query);
  };
}

// MARK: - Matching

/** Case-, space- and punctuation-insensitive: NFKC, lower case, letters and digits only. */
export function normalizeName(name: string): string {
  return name.normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
}

/** The Latin letters and digits only ("BECK'S COFFEE SHOP 新宿南口店" → "beckscoffeeshop"). */
function latinPart(normalized: string): string {
  return normalized.replace(/[^a-z0-9]+/g, '');
}

/** Shorter normalized names than this never match by containment: too many places contain them. */
const MIN_CONTAINED = 2;
/** The Latin part of a mixed-script name must be at least this long to match on its own. */
const MIN_LATIN_PART = 4;

/**
 * How well a Foursquare name matches one of ours: 3 the same, 2 one contains
 * the other, 1 their Latin parts do (a mixed-script name, as Japanese
 * listings often are: "BECK'S COFFEE SHOP Shinjuku South exit" and "BECK'S
 * COFFEE SHOP 新宿南口店"), 0 no match.
 */
export function nameScore(ours: string, theirs: string): number {
  const a = normalizeName(ours);
  const b = normalizeName(theirs);
  if (!a || !b) return 0;
  if (a === b) return 3;
  const [shorter, longer] = a.length <= b.length ? [a, b] : [b, a];
  if (shorter.length >= MIN_CONTAINED && longer.includes(shorter)) return 2;
  const la = latinPart(a);
  const lb = latinPart(b);
  // Only when one side is mixed script: two all-Latin names were compared above.
  if ((la !== a || lb !== b) && la.length >= MIN_LATIN_PART && lb.length >= MIN_LATIN_PART && (la.includes(lb) || lb.includes(la))) return 1;
  return 0;
}

/**
 * The result that is this place: the best name match (ours or our local
 * name), then the nearest. null when no name matches.
 */
export function pickMatch(results: readonly FoursquarePlace[], name: string, localName?: string): FoursquarePlace | null {
  let best: { place: FoursquarePlace; score: number } | null = null;
  for (const place of results) {
    const score = Math.max(nameScore(name, place.name), localName ? nameScore(localName, place.name) : 0);
    if (score === 0) continue;
    if (!best || score > best.score || (score === best.score && place.distance < best.place.distance)) best = { place, score };
  }
  return best?.place ?? null;
}
