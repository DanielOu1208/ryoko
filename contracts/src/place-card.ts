import { Type, type Static } from 'typebox';
import { Strict } from './helpers.ts';
import { BasisList, LanguageTag, Timestamp } from './common.ts';
import { WebSource } from './tools.ts';
import { CardPhrase } from './phrase.ts';
import { Profile } from './profile.ts';
import { Situation } from './situation.ts';

// Design §7.4. POST /v1/place-card

export const PlaceCardRequest = Strict({
  profile: Profile,
  situation: Situation,
});
export type PlaceCardRequest = Static<typeof PlaceCardRequest>;

export const Tip = Strict({
  text: Type.String({ minLength: 1, maxLength: 200, description: 'In the home language' }),
  basis: BasisList,
  /** The travel guide the tip rests on (design §8.4), linked for attribution. Absent when it rests on none. */
  source: Type.Optional(WebSource),
});
export type Tip = Static<typeof Tip>;

export const PlaceCardResponse = Strict({
  language: LanguageTag,
  phrases: Type.Array(CardPhrase, { minItems: 2, maxItems: 3 }),
  tips: Type.Array(Tip, { minItems: 1, maxItems: 2 }),
  placeNameLocal: Type.Optional(Type.String({ minLength: 1, maxLength: 120 })),
  addressLocal: Type.Optional(Type.String({ minLength: 1, maxLength: 240 })),
  generatedAt: Timestamp,
});
export type PlaceCardResponse = Static<typeof PlaceCardResponse>;
