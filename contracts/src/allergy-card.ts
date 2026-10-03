import { Type, type Static } from 'typebox';
import { Strict } from './helpers.ts';
import { LanguageTag } from './common.ts';
import { AllergenId, CustomAllergy, Severity } from './profile.ts';

// Design §4.5 and §7.6. POST /v1/allergy-card, free-text allergens only.
// Chip allergens use contracts/tables/allergy-templates.json and never call the server.

export const AllergyCardRequest = Strict({
  language: LanguageTag,
  homeLanguage: LanguageTag,
  allergies: Type.Array(CustomAllergy, { minItems: 1, maxItems: 10 }),
});
export type AllergyCardRequest = Static<typeof AllergyCardRequest>;

export const AllergyCardItem = Strict({
  allergenId: AllergenId,
  local: Type.String({ minLength: 1, maxLength: 300 }),
  home: Type.String({ minLength: 1, maxLength: 300 }),
  severity: Severity,
});
export type AllergyCardItem = Static<typeof AllergyCardItem>;

export const AllergyCardResponse = Strict({
  language: LanguageTag,
  title: Type.String({ minLength: 1, maxLength: 60, description: 'Card title in the local language' }),
  items: Type.Array(AllergyCardItem, { minItems: 1, maxItems: 10 }),
  requestLocal: Type.String({ minLength: 1, maxLength: 200, description: 'Asks whether the dish contains these, local language' }),
  requestHome: Type.String({ minLength: 1, maxLength: 200 }),
  romanization: Type.Optional(Type.String({ minLength: 1, maxLength: 300, description: 'Romanization of requestLocal' })),
  reviewed: Type.Boolean({ description: 'Always false for generated cards' }),
});
export type AllergyCardResponse = Static<typeof AllergyCardResponse>;
