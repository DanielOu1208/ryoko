import { Type, type Static } from 'typebox';
import { StringEnum, Strict } from './helpers.ts';
import { CategorySlug, CountryCode, LanguageTag, LocalDateTime } from './common.ts';

// Design §8.3 (after core). POST /v1/trip-events, with X-Install-Id.
// What the traveller did on the trip, for Mimo's trip memory (Tiger Data). The
// app sends them in small batches and never waits on the answer. A server
// without Tiger (or in fixture mode) accepts them and stores nothing.

export const TRIP_EVENT_KINDS = ['place_confirmed', 'phrase_shown', 'phrase_spoken', 'typed_translation'] as const;
export const TripEventKind = StringEnum(TRIP_EVENT_KINDS, {
  description: 'place_confirmed: "I\'m here" at a place; phrase_shown / phrase_spoken: a phrase opened in Show mode or played aloud; typed_translation: a typed turn in Translate',
});
export type TripEventKind = Static<typeof TripEventKind>;

export const TripEventPlace = Strict({
  name: Type.String({ minLength: 1, maxLength: 120 }),
  localName: Type.Optional(Type.String({ minLength: 1, maxLength: 120 })),
  category: Type.Optional(CategorySlug),
});
export type TripEventPlace = Static<typeof TripEventPlace>;

export const TripEvent = Strict({
  kind: TripEventKind,
  /** Local time with offset when it happened. */
  at: LocalDateTime,
  text: Type.String({
    minLength: 1,
    maxLength: 300,
    description: 'The phrase in local script, what was typed, or the place name (place_confirmed)',
  }),
  meaning: Type.Optional(
    Type.String({ minLength: 1, maxLength: 300, description: "The other side: a phrase's meaning in the home language, or a typed text's translation" }),
  ),
  /** The language of `text`. */
  language: Type.Optional(LanguageTag),
  /** The place it happened at, when there was one. */
  place: Type.Optional(TripEventPlace),
  city: Type.Optional(Type.String({ minLength: 1, maxLength: 80 })),
  countryCode: Type.Optional(CountryCode),
});
export type TripEvent = Static<typeof TripEvent>;

export const TRIP_EVENTS_MAX = 20;

export const TripEventsRequest = Strict({
  events: Type.Array(TripEvent, { minItems: 1, maxItems: TRIP_EVENTS_MAX }),
});
export type TripEventsRequest = Static<typeof TripEventsRequest>;

export const TripEventsResponse = Strict({
  stored: Type.Integer({ minimum: 0, maximum: TRIP_EVENTS_MAX, description: 'How many were stored: 0 when trip memory is off, and repeats are skipped' }),
});
export type TripEventsResponse = Static<typeof TripEventsResponse>;
