import { Type, type Static } from 'typebox';
import { StringEnum, Nullable, Strict } from './helpers.ts';
import { CategorySlug, LanguageTag } from './common.ts';
import { CHIP_ALLERGENS } from './profile.ts';

// Shapes of the shared tables in contracts/tables/. The app bundles them; the server reads them.

// --- langcodes.json (design §7.9) ---

export const LangCodeRow = Strict({
  tag: LanguageTag,
  status: StringEnum(['supported', 'best_effort']),
  displayName: Type.String({ minLength: 1, description: 'English name' }),
  nativeName: Type.String({ minLength: 1 }),
  soniox: Type.String({ minLength: 1, description: 'Soniox language code' }),
  locale: Type.String({ minLength: 1, description: 'Locale identifier for geocoding, e.g. zh_Hans_CN' }),
  romanization: StringEnum(['pinyin', 'romaji', 'none']),
  romanizationSource: StringEnum(['pinyin-pro', 'model', 'none'], { description: 'pinyin-pro runs on the server' }),
  voice: Nullable(Type.String({ minLength: 1, description: 'Tier 2 voice id' })),
  regions: Type.Array(Type.String({ pattern: '^[A-Z]{2}$' }), { description: 'Region codes that map to this language (CLDR likely subtags)' }),
  notes: Type.Optional(Type.String()),
});
export type LangCodeRow = Static<typeof LangCodeRow>;

export const LangCodeTable = Strict({
  languages: Type.Array(LangCodeRow, { minItems: 1 }),
});
export type LangCodeTable = Static<typeof LangCodeTable>;

// --- categories.json ---

export const CategoryRow = Strict({
  slug: CategorySlug,
  displayName: Type.String({ minLength: 1, maxLength: 40 }),
  sfSymbol: Type.String({ minLength: 1 }),
  starters: Type.Array(Type.String({ minLength: 1, maxLength: 60 }), { minItems: 2, maxItems: 3 }),
});
export type CategoryRow = Static<typeof CategoryRow>;

export const CategoryTable = Strict({
  categories: Type.Array(CategoryRow, { minItems: 1 }),
});
export type CategoryTable = Static<typeof CategoryTable>;

// --- allergy-templates.json (design §4.5, §4.6) ---

export const TemplateLine = Strict({
  local: Type.String({ minLength: 1 }),
  home: Type.String({ minLength: 1, description: 'The same line in the home language (en)' }),
});
export type TemplateLine = Static<typeof TemplateLine>;

export const AllergenTemplate = Strict({
  name: Type.String({ minLength: 1, description: 'Allergen name, local language' }),
  nameHome: Type.String({ minLength: 1 }),
  mild: TemplateLine,
  serious: TemplateLine,
  life_threatening: TemplateLine,
});
export type AllergenTemplate = Static<typeof AllergenTemplate>;

const allergenTemplateMap = Strict(
  Object.fromEntries(CHIP_ALLERGENS.map((id) => [id, AllergenTemplate])) as Record<(typeof CHIP_ALLERGENS)[number], typeof AllergenTemplate>,
);

export const SeverityLabels = Strict({
  mild: TemplateLine,
  serious: TemplateLine,
  life_threatening: TemplateLine,
});

export const AllergyLanguageTemplates = Strict({
  reviewed: Type.Boolean({ description: 'False until a native speaker has checked every line' }),
  reviewedBy: Nullable(Type.String()),
  title: TemplateLine,
  request: TemplateLine,
  requestRomanization: Type.String({ minLength: 1 }),
  severityLabels: SeverityLabels,
  allergens: allergenTemplateMap,
});
export type AllergyLanguageTemplates = Static<typeof AllergyLanguageTemplates>;

export const TaxiPhrase = Strict({
  local: Type.String({ minLength: 1 }),
  romanization: Type.String({ minLength: 1 }),
  gloss: Type.String({ minLength: 1 }),
  reviewed: Type.Boolean(),
});
export type TaxiPhrase = Static<typeof TaxiPhrase>;

export const AllergyTemplateTable = Strict({
  homeLanguage: StringEnum(['en']),
  note: Type.String(),
  languages: Strict({
    'zh-Hans': AllergyLanguageTemplates,
    ja: AllergyLanguageTemplates,
  }),
  taxiPhrases: Strict({
    'zh-Hans': TaxiPhrase,
    ja: TaxiPhrase,
    'zh-Hant': TaxiPhrase,
  }),
});
export type AllergyTemplateTable = Static<typeof AllergyTemplateTable>;
