import { Type, type Static } from 'typebox';
import { StringEnum, Nullable, Strict } from './helpers.ts';
import { Coordinate, CountryCode, LanguageTag } from './common.ts';

// Design §7.2. `null` means the survey page or field was skipped; `[]` means "none".

export const DIETS = ['vegetarian', 'vegan', 'halal', 'kosher', 'no_pork', 'no_beef', 'gluten_free', 'lactose_free'] as const;
export const Diet = StringEnum(DIETS);
export type Diet = Static<typeof Diet>;

/** Chip allergens. `custom` is free text and carries a `label`. */
export const CHIP_ALLERGENS = [
  'egg',
  'milk',
  'mustard',
  'peanut',
  'crustacean_mollusc',
  'fish',
  'sesame',
  'soy',
  'sulphite',
  'tree_nut',
  'wheat',
] as const;
export const ChipAllergenId = StringEnum(CHIP_ALLERGENS);
export type ChipAllergenId = Static<typeof ChipAllergenId>;

export const ALLERGEN_IDS = [...CHIP_ALLERGENS, 'custom'] as const;
export const AllergenId = StringEnum(ALLERGEN_IDS);
export type AllergenId = Static<typeof AllergenId>;

export const SEVERITIES = ['mild', 'serious', 'life_threatening'] as const;
export const Severity = StringEnum(SEVERITIES);
export type Severity = Static<typeof Severity>;

export const ChipAllergy = Strict({
  id: ChipAllergenId,
  severity: Severity,
});
export type ChipAllergy = Static<typeof ChipAllergy>;

export const CustomAllergy = Strict({
  id: StringEnum(['custom']),
  label: Type.String({ minLength: 1, maxLength: 60, description: 'Free-text allergen in the home language' }),
  severity: Severity,
});
export type CustomAllergy = Static<typeof CustomAllergy>;

export const Allergy = Type.Union([ChipAllergy, CustomAllergy]);
export type Allergy = Static<typeof Allergy>;

/** Taste slider, 0–4 with 2 as "as usual". `null` = skipped slider. */
export const TasteLevel = Nullable(Type.Integer({ minimum: 0, maximum: 4 }));

export const Taste = Strict({
  sweetness: TasteLevel,
  spice: TasteLevel,
});
export type Taste = Static<typeof Taste>;

export const Favourites = Strict({
  foods: Type.Array(Type.String({ minLength: 1, maxLength: 60 }), { maxItems: 20 }),
  drinks: Type.Array(Type.String({ minLength: 1, maxLength: 60 }), { maxItems: 20 }),
});
export type Favourites = Static<typeof Favourites>;

export const Rhythm = StringEnum(['early_bird', 'night_owl']);
export const FoodStyle = StringEnum(['local_favourite', 'my_usual']);
export const Budget = StringEnum(['save', 'splurge']);
export const Vibe = StringEnum(['quiet', 'lively']);

export const Personality = Strict({
  rhythm: Nullable(Rhythm),
  food: Nullable(FoodStyle),
  budget: Nullable(Budget),
  vibe: Nullable(Vibe),
});
export type Personality = Static<typeof Personality>;

/** Where the traveller is staying; the taxi card's default destination (design §4.6). */
export const HomeBase = Strict({
  name: Type.String({ minLength: 1, maxLength: 120 }),
  localName: Type.Optional(Type.String({ minLength: 1, maxLength: 120 })),
  address: Type.Optional(Type.String({ minLength: 1, maxLength: 240 })),
  addressLocal: Type.Optional(Type.String({ minLength: 1, maxLength: 240 })),
  coordinate: Coordinate,
});
export type HomeBase = Static<typeof HomeBase>;

export const Profile = Strict({
  version: Type.String({ pattern: '^[0-9a-f]{64}$', description: 'sha-256 (hex) of the canonical JSON of the profile without `version`' }),
  nationality: Nullable(CountryCode),
  homeLanguage: LanguageTag,
  spokenLanguages: Nullable(Type.Array(LanguageTag, { maxItems: 10, uniqueItems: true })),
  diet: Nullable(Type.Array(Diet, { uniqueItems: true })),
  dietNotes: Nullable(Type.String({ maxLength: 300 })),
  allergies: Nullable(Type.Array(Allergy, { maxItems: 20 })),
  favourites: Nullable(Favourites),
  taste: Nullable(Taste),
  personality: Nullable(Personality),
  homeBase: Nullable(HomeBase),
  /**
   * The traveller's own free text about themselves, edited in the Me tab. Absent when
   * empty (never null or ""), so profiles saved before it existed keep their version.
   * Soft context for the prompts, never instructions.
   */
  aboutMe: Type.Optional(Type.String({ minLength: 1, maxLength: 500, description: "The traveller's own words about themselves; absent when empty" })),
});
export type Profile = Static<typeof Profile>;
