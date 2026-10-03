import { Type, type Static } from 'typebox';
import { StringEnum, Strict } from './helpers.ts';

/** BCP-47 tag, e.g. `en`, `ja`, `zh-Hans`, `zh-Hant`. */
export const LanguageTag = Type.String({
  pattern: '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$',
  description: 'BCP-47 language tag, e.g. en, ja, zh-Hans',
});
export type LanguageTag = Static<typeof LanguageTag>;

/** Languages Ryoko has tables for (contracts/tables/langcodes.json). zh-Hant is best-effort. */
export const SUPPORTED_LANGUAGES = ['zh-Hans', 'ja', 'en', 'zh-Hant'] as const;
export const SupportedLanguage = StringEnum(SUPPORTED_LANGUAGES);
export type SupportedLanguage = Static<typeof SupportedLanguage>;

/** ISO 3166-1 alpha-2. */
export const CountryCode = Type.String({ pattern: '^[A-Z]{2}$', description: 'ISO 3166-1 alpha-2 country code' });
export type CountryCode = Static<typeof CountryCode>;

export const Coordinate = Strict({
  lat: Type.Number({ minimum: -90, maximum: 90 }),
  lon: Type.Number({ minimum: -180, maximum: 180 }),
});
export type Coordinate = Static<typeof Coordinate>;

/** Local wall-clock time of the situation, always with its UTC offset (design §4.2, §7.1). */
export const LocalDateTime = Type.String({
  format: 'date-time',
  pattern: '^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}(:\\d{2}(\\.\\d+)?)?(Z|[+-]\\d{2}:\\d{2})$',
  description: 'ISO 8601 local time with offset, e.g. 2026-10-05T15:00:00+08:00',
});

/** A server timestamp (UTC or with offset). */
export const Timestamp = Type.String({ format: 'date-time' });

/** 24-hour local clock time, e.g. `14:30`. */
export const ClockTime = Type.String({ pattern: '^([01]\\d|2[0-3]):[0-5]\\d$', description: '24-hour local time, HH:mm' });

/** Place category slugs (contracts/tables/categories.json). */
export const CATEGORY_SLUGS = [
  'cafe',
  'tea',
  'restaurant',
  'ramen',
  'bar',
  'bakery',
  'convenience_store',
  'museum',
  'park',
  'temple_shrine',
  'shopping',
  'transit',
  'hotel',
  'other',
] as const;
export const CategorySlug = StringEnum(CATEGORY_SLUGS, { description: 'Category slug from contracts/tables/categories.json' });
export type CategorySlug = Static<typeof CategorySlug>;

/** Which personalization input a "because…" line or tip rests on (design §5, §7.3). */
export const BASIS_VALUES = [
  'place',
  'localTime',
  'personality',
  'nationality',
  'diet',
  'allergy',
  'favourites',
  'taste',
  'memory',
] as const;
export const Basis = StringEnum(BASIS_VALUES);
export type Basis = Static<typeof Basis>;

export const BasisList = Type.Array(Basis, { minItems: 1, maxItems: 2, uniqueItems: true });
