import { Type, type Static } from 'typebox';
import { StringEnum, Nullable, Strict } from './helpers.ts';
import { CategorySlug, Coordinate, CountryCode, LanguageTag, LocalDateTime } from './common.ts';

// Design §7.1. The device owns geography and the clock; the server never uses its own.

/** A place as the device knows it from MapKit. Also used for Mimo's `subjectPlace`. */
export const Place = Strict({
  id: Type.Optional(Type.String({ minLength: 1, description: 'MKMapItem.Identifier raw value; absent when MapKit has none' })),
  name: Type.String({ minLength: 1, maxLength: 120 }),
  localName: Type.Optional(Type.String({ minLength: 1, maxLength: 120 })),
  category: CategorySlug,
  address: Type.Optional(Type.String({ minLength: 1, maxLength: 240 })),
  coordinate: Coordinate,
});
export type Place = Static<typeof Place>;

export const SituationMode = StringEnum(['live', 'preview']);
export type SituationMode = Static<typeof SituationMode>;

export const Situation = Strict({
  mode: SituationMode,
  localTime: LocalDateTime,
  timeZone: Type.String({ minLength: 1, description: 'IANA time zone, e.g. Asia/Shanghai' }),
  hourBucket: Type.String({ pattern: '^\\d{4}-\\d{2}-\\d{2}T\\d{2}$', description: 'Local date and hour, e.g. 2026-10-05T15' }),
  place: Nullable(Place),
  city: Type.String({ minLength: 1, maxLength: 80 }),
  district: Type.Optional(Type.String({ minLength: 1, maxLength: 80 })),
  countryCode: CountryCode,
  localLanguage: LanguageTag,
});
export type Situation = Static<typeof Situation>;
