import { Type, type Static } from 'typebox';
import { Strict } from './helpers.ts';
import { LanguageTag } from './common.ts';
import { Situation } from './situation.ts';

// Design §4.8 and §6.4 (tier 2). POST /v1/translate
// Typed text and edited turns in Translate. Speech never comes here: Soniox
// translates it. The situation lets the wording fit the place (少糖 at a tea shop).

/** Longest text Type mode sends, in characters. */
export const TRANSLATE_MAX_CHARS = 500;

export const TranslateRequest = Strict({
  text: Type.String({ minLength: 1, maxLength: TRANSLATE_MAX_CHARS, description: 'What you typed, in your language' }),
  from: LanguageTag,
  to: LanguageTag,
  situation: Type.Optional(Situation),
});
export type TranslateRequest = Static<typeof TranslateRequest>;

export const TranslateResponse = Strict({
  translation: Type.String({ minLength: 1, maxLength: 1500, description: 'The text in the `to` language' }),
});
export type TranslateResponse = Static<typeof TranslateResponse>;
