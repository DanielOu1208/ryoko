// The discover skill (design §6.5, §7.5): 5–8 real places for an area, each with a
// one-line why (≤ 60 characters), a category and an optional best time. One result
// feeds the Map sheet's Mimo picks and the Hidden gems layer. The device resolves
// each name with MapKit and drops misses, so names must be the ones on maps. The
// prompt trades "hidden" for "certainly real": an invented name either vanishes
// or, worse, lands on a different place with a similar name.
//
// Grounding (design #54): when the request carries `nearby`, the real places
// MapKit knows around the area, the model picks from that list and may add at
// most MAX_UNLISTED_PICKS well-known places of its own. The server holds it to
// that: unlisted picks beyond the allowance are dropped, and too few left means
// the usual one retry. Without `nearby` the skill works as before.

import { createHash } from 'node:crypto';
import { Type, type Static } from 'typebox';
import { Value } from 'typebox/value';
import { CATEGORY_SLUGS, CategorySlug, DiscoverResponse, Strict, type DiscoverPlace, type DiscoverRequest, type NearbyPlace } from '@ryoko/contracts';
import type { Finalized } from '../llm/typed.ts';
import { describeErrors } from '../validate.ts';
import { ABOUT_ME_RULE, inLocalScript, languageInfo, mostlyInScript, PERSONA, promptProfile, promptSituation, type LanguageInfo } from './context.ts';

/** Bump when the prompt or checks change, so cached picks regenerate. dc-4: grounded in `nearby`. dc-5: no allergen filter; the aboutMe rule. */
export const DISCOVER_PROMPT_VERSION = 'dc-5';

/** The contract's floor: fewer good picks than this means a retry. */
export const MIN_DISCOVER_PLACES = 5;
/** The contract's ceiling: extra good picks are left out. */
export const MAX_DISCOVER_PLACES = 8;
/** Picks from outside the nearby list, when the list has at least 5 places (design #54). */
export const MAX_UNLISTED_PICKS = 2;

/** Looser than the contract: an over-long line drops that place instead of failing the reply. */
export const DiscoverModelOutput = Strict({
  places: Type.Array(
    Strict({
      name: Type.String({ minLength: 1, maxLength: 120, description: 'The name exactly as it appears on maps' }),
      localName: Type.String({ minLength: 1, maxLength: 120, description: 'Name in local script' }),
      why: Type.String({ minLength: 1, maxLength: 120, description: 'One line in the home language, at most 50 characters' }),
      category: CategorySlug,
      bestTime: Type.Optional(Type.String({ minLength: 1, maxLength: 60, description: 'Short label in the home language, at most 24 characters' })),
    }),
    { minItems: 3, maxItems: 10 },
  ),
});
export type DiscoverModelOutput = Static<typeof DiscoverModelOutput>;

// --- the nearby list (grounding) ---

/** Case-, space- and punctuation-insensitive form of a name, for matching and de-duplication. */
const normalizeName = (name: string) => name.normalize('NFKC').toLowerCase().replace(/[\s\p{P}]+/gu, '');

/** Containment counts only when the shorter name has at least this many characters, so a stray "Ca" matches nothing. */
const MIN_CONTAINED_NAME = 3;

/** The request's nearby places, nearest first, one per name (the nearest wins). Empty when there are none. */
export function nearbyPlaces(request: DiscoverRequest): NearbyPlace[] {
  const seen = new Set<string>();
  return [...(request.nearby ?? [])]
    .sort((a, b) => a.distanceMeters - b.distanceMeters)
    .filter((place) => {
      const key = normalizeName(place.name);
      if (!key || seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

/** Picks allowed from outside the list: MAX_UNLISTED_PICKS, or enough to reach 5 when the list is shorter. */
export function unlistedAllowance(nearby: readonly NearbyPlace[]): number {
  return Math.max(MAX_UNLISTED_PICKS, MIN_DISCOVER_PLACES - nearby.length);
}

/** A short stable hash of the sorted nearby names, for the cache key; "none" without a list. */
export function nearbyKey(request: DiscoverRequest): string {
  const names = nearbyPlaces(request).map((place) => normalizeName(place.name));
  if (names.length === 0) return 'none';
  return createHash('sha256').update(JSON.stringify(names.sort()), 'utf8').digest('hex').slice(0, 16);
}

function namesMatch(a: string, b: string): boolean {
  if (!a || !b) return false;
  if (a === b) return true;
  const [shorter, longer] = a.length <= b.length ? [a, b] : [b, a];
  return shorter.length >= MIN_CONTAINED_NAME && longer.includes(shorter);
}

/**
 * True when a pick is one of the nearby places: its name or local name matches a
 * listed name or local name, ignoring case, spaces and punctuation, or one of the
 * two contains the other.
 */
export function onNearbyList(pick: { name: string; localName?: string }, nearby: readonly NearbyPlace[]): boolean {
  const picked = [pick.name, pick.localName].flatMap((name) => (name ? [normalizeName(name)] : []));
  return nearby.some((place) => {
    const listed = [place.name, place.localName].flatMap((name) => (name ? [normalizeName(name)] : []));
    return picked.some((a) => listed.some((b) => namesMatch(a, b)));
  });
}

// --- the prompt ---

/** What the system prompt needs to know about the nearby list. */
export interface DiscoverGrounding {
  /** Places on the list, after de-duplication. */
  listed: number;
  /** Picks allowed from outside the list (unlistedAllowance). */
  allowance: number;
}

/** The grounding for this request, or null when it has no nearby places (the prompt then works from memory). */
export function discoverGrounding(request: DiscoverRequest): DiscoverGrounding | null {
  const nearby = nearbyPlaces(request);
  return nearby.length > 0 ? { listed: nearby.length, allowance: unlistedAllowance(nearby) } : null;
}

const localScript = (local: LanguageInfo) => `${local.name}${local.script === 'latin' ? '' : ' script'}`;

/** Without a nearby list: names from memory, certainly real. */
function memoryRules(local: LanguageInfo): string[] {
  return [
    "Every place must really exist today under exactly that name, within about the given radius of the area centre. Pick only established places (open for years) that you are certain of and that are listed on Apple Maps and Google Maps. Never make up or guess a name, and never combine a brand with a building or district into a name you haven't seen. If you can't think of enough lesser-known places you are sure of, use well-known ones instead: a real, famous place is always better than an invented one. The phone looks each name up on the map and drops any it can't find.",
    'Name the place itself: not an event, a festival, a counter or stall inside a department store, mall or station, or a single dish.',
    `"name": the name exactly as it appears on maps, in English or the common romanized form. "localName": the name in ${localScript(local)}, as written on the place's own sign.`,
    "Prefer places that suit the time of day and day of week (open and pleasant then), the traveller's personality (quiet or lively, save or splurge, early bird or night owl) and their diet. Among places you are sure of, prefer the lesser-known ones.",
  ];
}

/** With a nearby list: pick from it, add at most `allowance` well-known places. */
function groundedRules(local: LanguageInfo, grounding: DiscoverGrounding): string[] {
  const { allowance } = grounding;
  const rules = [
    '"nearby" in the request lists the real places the map knows around the area, nearest first. Pick your 5–8 places from it. Copy each "name" exactly as it is written there, letter for letter: never translate, shorten or extend it.',
    `"localName": the listed place's "localName" when it has one, copied exactly. Otherwise the name in ${localScript(local)}, as written on the place's own sign.`,
    "Among the listed places, choose the ones a local would point a friend to: independent and local spots over chains and big brands, hidden gems over the obvious. Prefer places that suit the time of day and day of week (open and pleasant then), the traveller's personality (quiet or lively, save or splurge, early bird or night owl) and their diet.",
    `You may add at most ${allowance} ${allowance === 1 ? "place that isn't" : "places that aren't"} on the list, and only well-known, established places you are certain exist today under exactly that name, within the given radius of the area centre. Inventing or guessing a place is far worse than a short list: if you aren't certain, don't add it. The phone looks each name up on the map and drops any it can't find.`,
  ];
  if (grounding.listed < MIN_DISCOVER_PLACES) {
    rules.push('The list is short: use every listed place that suits the traveller, then fill up to 5 with well-known places you are certain of within the radius. Never an invented one.');
  }
  rules.push('Pick places, not events, festivals, counters or stalls inside a department store, mall or station, or single dishes.');
  return rules;
}

export function discoverSystem(local: LanguageInfo, home: LanguageInfo, grounding: DiscoverGrounding | null = null): string {
  const rules = [
    ...(grounding ? groundedRules(local, grounding) : memoryRules(local)),
    "Allergies and diet are hard limits: never pick a place whose point is food or drink the traveller can't have.",
    `"why": one line in ${home.name}, at most 50 characters, specific (what to do or try there). No exclamation marks. Don't mention the traveller's allergies or diet in it; just don't pick places that conflict with them.`,
    `"category": one of ${CATEGORY_SLUGS.join(', ')}.`,
    `"bestTime": optional, a short label in ${home.name}, at most 24 characters, e.g. "Afternoons".`,
    'Mix categories, with at most 3 places to eat or drink.',
    ABOUT_ME_RULE,
  ];
  return `${PERSONA}

Task: suggest 5–8 places near the area in the request that this traveller would enjoy around the local time given. These are your picks: special spots a local would recommend, not the obvious tourist list.

Rules:
${rules.map((rule) => `- ${rule}`).join('\n')}`;
}

export function discoverUser(request: DiscoverRequest): string {
  const { area } = request;
  const nearby = nearbyPlaces(request);
  return JSON.stringify({
    area: { city: area.city, district: area.district, center: area.center, radiusMeters: area.radiusMeters },
    situation: promptSituation(request.situation),
    traveller: promptProfile(request.profile, 'discover'),
    nearby: nearby.length > 0 ? nearby.map(({ name, localName, category, distanceMeters }) => ({ name, localName, category, distanceMeters })) : undefined,
  });
}

// --- checks ---

export function finalizeDiscover(request: DiscoverRequest, output: DiscoverModelOutput): Finalized<DiscoverResponse> {
  const local = languageInfo(request.situation.localLanguage);
  const home = languageInfo(request.profile.homeLanguage);
  const nearby = nearbyPlaces(request);
  const allowance = unlistedAllowance(nearby);
  const dropped: string[] = [];
  const seen = new Set<string>();
  const places: DiscoverPlace[] = [];
  let unlisted = 0;
  let unlistedDropped = 0;

  output.places.forEach((place, index) => {
    const problems: string[] = [];
    const why = place.why.trim();
    const bestTime = place.bestTime?.trim();
    if (why.length > 60) problems.push(`"why" is ${why.length} characters (at most 60)`);
    if (!mostlyInScript(why, home)) problems.push(`"why" isn't in ${home.name}`);
    if (!inLocalScript(place.localName, local)) problems.push(`"localName" isn't in ${local.name}`);
    const key = normalizeName(place.name);
    if (seen.has(key)) problems.push('it repeats another place');
    if (problems.length > 0) {
      dropped.push(`places[${index}] (${place.name}): ${problems.join('; ')}`);
      return;
    }
    if (places.length >= MAX_DISCOVER_PLACES) return;
    if (nearby.length > 0 && !onNearbyList(place, nearby)) {
      if (unlisted >= allowance) {
        unlistedDropped++;
        dropped.push(`places[${index}] (${place.name}): it isn't on the "nearby" list, and ${allowance} places from outside the list are already picked`);
        return;
      }
      unlisted++;
    }
    seen.add(key);
    const item: DiscoverPlace = { name: place.name.trim(), localName: place.localName.trim(), why, category: place.category };
    if (bestTime && bestTime.length <= 24) item.bestTime = bestTime;
    places.push(item);
  });

  if (places.length < MIN_DISCOVER_PLACES) {
    const issues = [...dropped];
    if (unlistedDropped > 0) issues.push(`Pick from the "nearby" list, copying each name exactly: at most ${allowance} places that aren't on it.`);
    issues.push(`Give at least ${MIN_DISCOVER_PLACES} places that pass these rules (${places.length} did).`);
    return { ok: false, issues };
  }
  const response: DiscoverResponse = { places };
  if (!Value.Check(DiscoverResponse, response)) return { ok: false, issues: [describeErrors(DiscoverResponse, response)] };
  return { ok: true, value: response, dropped };
}

// --- geohash, for the cache key (design §6.5: geohash-6 area) ---

const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';

export function geohash(lat: number, lon: number, precision = 6): string {
  let latRange: [number, number] = [-90, 90];
  let lonRange: [number, number] = [-180, 180];
  let hash = '';
  let bits = 0;
  let value = 0;
  let even = true;
  while (hash.length < precision) {
    const range = even ? lonRange : latRange;
    const coordinate = even ? lon : lat;
    const mid = (range[0] + range[1]) / 2;
    value <<= 1;
    if (coordinate >= mid) {
      value |= 1;
      range[0] = mid;
    } else {
      range[1] = mid;
    }
    if (even) lonRange = range;
    else latRange = range;
    even = !even;
    if (++bits === 5) {
      hash += BASE32[value];
      bits = 0;
      value = 0;
    }
  }
  return hash;
}
