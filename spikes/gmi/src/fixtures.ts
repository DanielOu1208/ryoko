import { Type, StringEnum, type Static } from '@earendil-works/pi-ai';

export const profile = {
  version: 'spike-1',
  nationality: 'CA',
  homeLanguage: 'en',
  spokenLanguages: ['en'],
  diet: [] as string[],
  dietNotes: '',
  allergies: [{ id: 'peanut', severity: 'serious' }],
  favourites: null,
  taste: { sweetness: 1, spice: null },
  personality: { rhythm: null, food: 'local_favourite', budget: 'save', vibe: 'quiet' },
  homeBase: null,
};

// Basis values allowed for this profile (filled-in fields only).
export const ALLOWED_BASIS = new Set(['place', 'localTime', 'personality', 'nationality', 'allergy', 'taste']);

export const heytea = {
  mode: 'preview',
  localTime: '2026-10-10T15:00:00+08:00',
  timeZone: 'Asia/Shanghai',
  hourBucket: '2026-10-10T15',
  place: { id: 'mk-heytea-jingan', name: 'Heytea', localName: '喜茶', category: 'cafe', address: '1601 Nanjing West Rd, Jing\'an', coordinate: { lat: 31.2235, lon: 121.4453 } },
  city: 'Shanghai',
  district: "Jing'an",
  countryCode: 'CN',
  localLanguage: 'zh-Hans',
};
export const heyteaDerived = { weekday: 'Saturday', partOfDay: 'afternoon' };

export const ramen = {
  mode: 'preview',
  localTime: '2026-10-10T20:00:00+09:00',
  timeZone: 'Asia/Tokyo',
  hourBucket: '2026-10-10T20',
  place: { id: 'mk-fuunji', name: 'Fuunji', localName: '風雲児', category: 'ramen', address: '2-14-3 Yoyogi, Shibuya', coordinate: { lat: 35.6866, lon: 139.6985 } },
  city: 'Tokyo',
  district: 'Shinjuku',
  countryCode: 'JP',
  localLanguage: 'ja',
};
export const ramenDerived = { weekday: 'Saturday', partOfDay: 'evening' };

const Basis = Type.Array(
  StringEnum(['place', 'localTime', 'personality', 'nationality', 'diet', 'allergy', 'favourites', 'taste', 'memory']),
  { minItems: 1, maxItems: 2 },
);

// What the model produces for §7.4 (server adds id, lang, generatedAt, pinyin).
export const PlaceCardOutput = Type.Object(
  {
    phrases: Type.Array(
      Type.Object(
        {
          local: Type.String({ minLength: 1, description: 'The phrase in the local language and script.' }),
          romanization: Type.Union([Type.String(), Type.Null()], { description: 'Romaji for Japanese; null for Chinese (server fills pinyin) and Latin-script languages.' }),
          gloss: Type.String({ minLength: 1, description: "Meaning in the user's home language." }),
          because: Type.String({ minLength: 1, description: 'Why this phrase suits the user here and now, about 10 words max.' }),
          basis: Basis,
        },
        { additionalProperties: false },
      ),
      { minItems: 2, maxItems: 3 },
    ),
    tips: Type.Array(
      Type.Object({ text: Type.String({ minLength: 1 }), basis: Basis }, { additionalProperties: false }),
      { minItems: 1, maxItems: 2 },
    ),
    placeNameLocal: Type.Optional(Type.String()),
  },
  { additionalProperties: false },
);
export type PlaceCardOutput = Static<typeof PlaceCardOutput>;

export const PERSONA = `You are Mimo, a calm local friend who lives in the user's current city. Warm, brief, first person. No exclamation marks, no emoji. Never call yourself AI.`;

export function placeCardSystem(lang: string) {
  return `${PERSONA}

Task: write the place card for the place in the situation. It gives the user 2-3 phrases they can say at this exact place right now, and 1-2 short tips.

Rules:
- Every phrase "local" is in ${lang} only, in its native script. ${lang === 'zh-Hans' ? 'Simplified Chinese characters only: no Latin letters, no pinyin, no English, no digits in Latin script inside "local".' : 'Japanese script only in "local"; put romaji in "romanization".'}
- "romanization": ${lang === 'zh-Hans' ? 'always null (the server adds pinyin).' : 'Hepburn romaji of "local".'}
- "gloss" is the meaning in the user's home language.
- "because" says why this phrase fits this user here and now, at most 10 words.
- "basis" lists 1-2 profile or situation fields that the phrase or tip is based on. Allowed values: place, localTime, personality, nationality, diet, allergy, favourites, taste, memory. Only use a value if that field is actually filled in (not null, not empty) in the request. "memory" is never available.${process.env.COMPACT === '1' ? ' If the request has "allowedBasis", use only those values.' : ''}
- Respect allergies strictly: never suggest an item containing an allergen. Mentioning the allergy itself (asking staff to leave it out) is good.
- Respect taste: sweetness and spice are 0-4 where 2 is "as usual".
- Phrases must be short and sayable to staff.
- Tips "text" is in the user's home language (homeLanguage), one sentence each.

Output: a single JSON object, no markdown, no code fences, no text before or after. It must match this JSON Schema:
${JSON.stringify(PlaceCardOutput)}`;
}

// Drop null / empty fields so the model cannot cite them as basis.
export function compactProfile(p: any): any {
  if (Array.isArray(p)) return p.length ? p.map(compactProfile) : undefined;
  if (p && typeof p === 'object') {
    const o: any = {};
    for (const [k, v] of Object.entries(p)) { const c = compactProfile(v); if (c !== undefined && c !== '' && k !== 'version') o[k] = c; }
    return Object.keys(o).length ? o : undefined;
  }
  return p ?? undefined;
}

export function placeCardUser(situation: object, derived: object) {
  if (process.env.COMPACT === '1')
    return JSON.stringify({ profile: compactProfile(profile), situation: { ...situation, ...derived }, allowedBasis: [...ALLOWED_BASIS] });
  return JSON.stringify({ profile, situation: { ...situation, ...derived } });
}

export function mimoSystem(situation: typeof heytea, derived: object) {
  return `${PERSONA}

## Tools
- show_places: whenever you suggest specific places (or plan stops), call show_places once with all of them, so the app can show them on the map. Use real, existing places near the user that you are confident about; give each a local-script name in localName. For a plan, set "order" (1, 2, 3...) and "when" (e.g. "15:30"). At most 5 places. After calling it, reply with one or two short sentences; do not repeat the list in prose.
- web_search: only for facts you are unsure about (opening hours, events). Most questions do not need it.

## Phrases
Whenever you give the user something to say out loud, put each sayable phrase on its own line, exactly like this:
<phrase lang="${situation.localLanguage}" local="…" gloss="…" romanization="…"/>
- "local" is the phrase in ${situation.localLanguage} native script only. "gloss" is the English meaning. "romanization" is optional${situation.localLanguage === 'zh-Hans' ? ' (pinyin; the app can fill it)' : ' (romaji)'}.
- No markdown around the tag, no quotes or bullets before it, nothing else on that line. Do not repeat the phrase in prose.
- Keep your own words outside the tags. At most 4 phrases per reply.${process.env.STRICT_TAGS === '1' ? '\n- Never write ' + situation.localLanguage + ' script anywhere outside a phrase tag, not even a single word or place name. If a word is worth saying, make it its own phrase tag; otherwise refer to it in English.' : ''}

## Profile
${JSON.stringify(profile)}

## Situation
${JSON.stringify({ ...situation, ...derived })}`;
}
