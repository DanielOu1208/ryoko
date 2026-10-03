import { Type, type Static } from 'typebox';
import { Strict } from './helpers.ts';
import { CategorySlug, Coordinate } from './common.ts';
import { Profile } from './profile.ts';
import { Situation } from './situation.ts';

// Design §6.5 and §7.5. POST /v1/discover

export const DiscoverArea = Strict({
  center: Coordinate,
  radiusMeters: Type.Integer({ minimum: 100, maximum: 5000, default: 1500 }),
  city: Type.String({ minLength: 1, maxLength: 80 }),
  district: Type.Optional(Type.String({ minLength: 1, maxLength: 80 })),
});
export type DiscoverArea = Static<typeof DiscoverArea>;

export const DiscoverRequest = Strict({
  area: DiscoverArea,
  profile: Profile,
  situation: Situation,
});
export type DiscoverRequest = Static<typeof DiscoverRequest>;

export const DiscoverPlace = Strict({
  name: Type.String({ minLength: 1, maxLength: 120 }),
  localName: Type.String({ minLength: 1, maxLength: 120 }),
  why: Type.String({ minLength: 1, maxLength: 60, description: 'One line, home language' }),
  category: CategorySlug,
  bestTime: Type.Optional(Type.String({ minLength: 1, maxLength: 24, description: 'Short display text in the home language, e.g. "Mornings"' })),
});
export type DiscoverPlace = Static<typeof DiscoverPlace>;

export const DiscoverResponse = Strict({
  places: Type.Array(DiscoverPlace, { minItems: 5, maxItems: 8 }),
});
export type DiscoverResponse = Static<typeof DiscoverResponse>;
