import { Type, type Static } from 'typebox';
import { Nullable, Strict } from './helpers.ts';
import { BasisList, LanguageTag } from './common.ts';

// Design §7.3. One Phrase type for Now's cards, place sheets, Mimo's blocks and Show mode.

const phraseFields = {
  id: Type.String({ minLength: 1, maxLength: 64 }),
  lang: LanguageTag,
  local: Type.String({ minLength: 1, maxLength: 200, description: 'The phrase in local script' }),
  romanization: Nullable(Type.String({ minLength: 1, maxLength: 300, description: 'Pinyin or romaji; null for Latin-script languages' })),
  gloss: Type.String({ minLength: 1, maxLength: 200, description: 'Meaning in the home language' }),
};

export const Phrase = Strict({
  ...phraseFields,
  because: Type.Optional(Type.String({ minLength: 1, maxLength: 80, description: 'About 8–10 words, in the home language' })),
  basis: Type.Optional(BasisList),
});
export type Phrase = Static<typeof Phrase>;

/** A place-card phrase: `because` and `basis` are required (design §7.4). */
export const CardPhrase = Strict({
  ...phraseFields,
  because: Type.String({ minLength: 1, maxLength: 80, description: 'About 8–10 words, in the home language' }),
  basis: BasisList,
});
export type CardPhrase = Static<typeof CardPhrase>;
