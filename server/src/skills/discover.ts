// The discover skill (design §6.5, §7.5): 5–8 real places for an area, each with a
// one-line why (≤ 60 characters), a category and an optional best time. One result
// feeds the Map sheet's Mimo picks and the Hidden gems layer. The device resolves
// each name with MapKit and drops misses, so names must be the ones on maps. The
// prompt trades "hidden" for "certainly real": an invented name either vanishes
// or, worse, lands on a different place with a similar name.

import { Type, type Static } from 'typebox';
import { Value } from 'typebox/value';
import { CATEGORY_SLUGS, CategorySlug, DiscoverResponse, Strict, type DiscoverPlace, type DiscoverRequest } from '@ryoko/contracts';
import type { Finalized } from '../llm/typed.ts';
import { describeErrors } from '../validate.ts';
import { inLocalScript, languageInfo, mostlyInScript, PERSONA, promptProfile, promptSituation, type LanguageInfo } from './context.ts';
import { hazardsFor, unsafeMention } from './safety.ts';

export const DISCOVER_PROMPT_VERSION = 'dc-3';

/** Looser than the contract: an over-long line drops that place instead of failing the reply. */
export const DiscoverModelOutput = Strict({
  places: Type.Array(
    Strict({
      name: Type.String({ minLength: 1, maxLength: 120, description: 'Name as it appears on maps: English or the common romanized form' }),
      localName: Type.String({ minLength: 1, maxLength: 120, description: 'Name in local script' }),
      why: Type.String({ minLength: 1, maxLength: 120, description: 'One line in the home language, at most 50 characters' }),
      category: CategorySlug,
      bestTime: Type.Optional(Type.String({ minLength: 1, maxLength: 60, description: 'Short label in the home language, at most 24 characters' })),
    }),
    { minItems: 3, maxItems: 10 },
  ),
});
export type DiscoverModelOutput = Static<typeof DiscoverModelOutput>;

export function discoverSystem(local: LanguageInfo, home: LanguageInfo): string {
  return `${PERSONA}

Task: suggest 5–8 places near the area in the request that this traveller would enjoy around the local time given. These are your picks: special spots a local would recommend, not the obvious tourist list.

Rules:
- Every place must really exist today under exactly that name, within about the given radius of the area centre. Pick only established places (open for years) that you are certain of and that are listed on Apple Maps and Google Maps. Never make up or guess a name, and never combine a brand with a building or district into a name you haven't seen. If you can't think of enough lesser-known places you are sure of, use well-known ones instead: a real, famous place is always better than an invented one. The phone looks each name up on the map and drops any it can't find.
- Name the place itself: not an event, a festival, a counter or stall inside a department store, mall or station, or a single dish.
- "name": the name exactly as it appears on maps, in English or the common romanized form. "localName": the name in ${local.name}${local.script === 'latin' ? '' : ' script'}, as written on the place's own sign.
- Prefer places that suit the time of day and day of week (open and pleasant then), the traveller's personality (quiet or lively, save or splurge, early bird or night owl) and their diet. Among places you are sure of, prefer the lesser-known ones.
- Allergies and diet are hard limits: never pick a place whose point is food or drink the traveller can't have.
- "why": one line in ${home.name}, at most 50 characters, specific (what to do or try there). No exclamation marks. Don't mention the traveller's allergies or diet in it; just don't pick places that conflict with them.
- "category": one of ${CATEGORY_SLUGS.join(', ')}.
- "bestTime": optional, a short label in ${home.name}, at most 24 characters, e.g. "Afternoons".
- Mix categories, with at most 3 places to eat or drink.`;
}

export function discoverUser(request: DiscoverRequest): string {
  const { area } = request;
  return JSON.stringify({
    area: { city: area.city, district: area.district, center: area.center, radiusMeters: area.radiusMeters },
    situation: promptSituation(request.situation),
    traveller: promptProfile(request.profile, 'discover'),
  });
}

const normalizeName = (name: string) => name.toLowerCase().replace(/[\s\p{P}]+/gu, '');

export function finalizeDiscover(request: DiscoverRequest, output: DiscoverModelOutput): Finalized<DiscoverResponse> {
  const local = languageInfo(request.situation.localLanguage);
  const home = languageInfo(request.profile.homeLanguage);
  const hazards = hazardsFor(request.profile);
  const dropped: string[] = [];
  const seen = new Set<string>();
  const places: DiscoverPlace[] = [];

  output.places.forEach((place, index) => {
    const problems: string[] = [];
    const why = place.why.trim();
    const bestTime = place.bestTime?.trim();
    if (why.length > 60) problems.push(`"why" is ${why.length} characters (at most 60)`);
    if (!mostlyInScript(why, home)) problems.push(`"why" isn't in ${home.name}`);
    if (!inLocalScript(place.localName, local)) problems.push(`"localName" isn't in ${local.name}`);
    const hazard = unsafeMention([place.name, why], hazards);
    if (hazard) problems.push(`it's about ${hazard}, which the traveller must avoid`);
    const key = normalizeName(place.name);
    if (seen.has(key)) problems.push('it repeats another place');
    if (problems.length > 0) {
      dropped.push(`places[${index}] (${place.name}): ${problems.join('; ')}`);
      return;
    }
    seen.add(key);
    if (places.length >= 8) return;
    const item: DiscoverPlace = { name: place.name.trim(), localName: place.localName.trim(), why, category: place.category };
    if (bestTime && bestTime.length <= 24) item.bestTime = bestTime;
    places.push(item);
  });

  if (places.length < 5) {
    return { ok: false, issues: [...dropped, `Give at least 5 places that pass these rules (${places.length} did).`] };
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
