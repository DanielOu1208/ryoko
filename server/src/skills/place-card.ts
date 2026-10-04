// The place-card skill (design §4.3, §6.4, §7.4): 2–3 phrases for this place at
// this local time, each with a "because…" and a checked basis, plus 1–2 tips.
//
// Server checks on top of the prompt (each failing item is dropped; too few
// left means one retry with the problems listed, then invalid_model_output):
// - basis only names inputs that are filled in (allowedBasis)
// - "because…" is about 10 words at most
// - local text is in the local script, and Chinese local text has no Latin letters
// - the allergen and diet filter, which allows safety mentions
// - Chinese romanization is pinyin-pro's, not the model's

import { createHash } from 'node:crypto';
import { Type, type Static } from 'typebox';
import { BasisList, PlaceCardResponse, Strict, Nullable, type Basis, type CardPhrase, type PlaceCardRequest, type Tip } from '@ryoko/contracts';
import { describeErrors } from '../validate.ts';
import { allowedBasis, hasLatinLetters, inLocalScript, languageInfo, mostlyInScript, PERSONA, promptProfile, promptSituation, wordCount, type LanguageInfo } from './context.ts';
import { romanizationFor } from './romanize.ts';
import { hazardsFor, unsafeMention, type Hazard } from './safety.ts';
import { Value } from 'typebox/value';
import type { Finalized } from '../llm/typed.ts';

/** Bump when the prompt or checks change, so cached cards regenerate. */
export const PLACE_CARD_PROMPT_VERSION = 'pc-4';

/** snake_case or a profile field name in a "because…" line: the model leaking the request's keys. */
const FIELD_NAME = /\b[a-z]+_[a-z_]+\b|\b(?:localTime|allowedBasis|homeLanguage|dietNotes)\b/;

/** "About 10 words" (design §7.4): a little slack before an item is dropped. */
export const MAX_BECAUSE_WORDS = 12;

/** The model's part of the card. Looser counts than the contract, so one bad item is dropped instead of failing the reply. */
export const PlaceCardModelOutput = Strict({
  phrases: Type.Array(
    Strict({
      local: Type.String({ minLength: 1, maxLength: 200, description: 'The phrase in the local language and script' }),
      romanization: Nullable(Type.String({ maxLength: 300, description: 'Romaji for Japanese; null for Chinese (the server adds pinyin) and Latin-script languages' })),
      gloss: Type.String({ minLength: 1, maxLength: 200, description: "Meaning in the traveller's home language" }),
      because: Type.String({ minLength: 1, maxLength: 80, description: 'Why it fits this traveller here and now, at most 8 words, home language' }),
      basis: BasisList,
    }),
    { minItems: 2, maxItems: 4 },
  ),
  tips: Type.Array(
    Strict({
      text: Type.String({ minLength: 1, maxLength: 200, description: 'One or two short sentences in the home language' }),
      basis: BasisList,
    }),
    { minItems: 1, maxItems: 3 },
  ),
  placeNameLocal: Type.Optional(Type.String({ minLength: 1, maxLength: 120, description: "The place's name in local script, only if you know it" })),
});
export type PlaceCardModelOutput = Static<typeof PlaceCardModelOutput>;

export function placeCardSystem(local: LanguageInfo, home: LanguageInfo): string {
  const localRule =
    local.script === 'han'
      ? `Write "local" in ${local.name} characters only: no Latin letters at all (no pinyin, no English words, no brand names in Latin script).`
      : local.script === 'latin'
        ? `Write "local" in ${local.name}.`
        : `Write "local" in ${local.name} only, in its native script.`;
  const romanizationRule =
    local.romanization === 'pinyin'
      ? '"romanization": always null. The server adds pinyin.'
      : local.romanization === 'model'
        ? `"romanization": the ${local.script === 'japanese' ? 'Hepburn romaji (with macrons)' : 'standard romanization'} of "local".`
        : '"romanization": always null.';
  return `${PERSONA}

Task: write the place card for the place in the request. It gives the traveller 2–3 phrases they can say at this exact place at this local time, and 1–2 short tips.

Phrases:
- ${localRule}
- ${romanizationRule}
- "gloss": the meaning in ${home.name}.
- Short, natural and polite, sayable to staff. Specific to this kind of place and this time of day (what you'd actually order or ask here).
- "because": why this phrase fits this traveller here and now, in ${home.name}, at most 8 words, in plain words, e.g. "You like it less sweet". Never write field names or values such as local_favourite or localTime.
- "basis": 1–2 values from allowedBasis, naming the inputs the phrase rests on. Use only values listed in allowedBasis.
- Don't stretch the profile to fit: a phrase can rest on the place or the local time alone. Use a favourite or a taste only where it suits this kind of place.
- Allergies and diet are hard limits: never suggest ordering anything that contains an allergen or breaks the diet. If the traveller has an allergy, one phrase may state it and ask whether a dish contains it.
- When a phrase or tip names an allergen or a food outside the diet, put the safety words right next to it: "no peanuts", "allergic to peanuts", "does it contain peanuts", 不要花生, 我对花生过敏, 这个里面有花生吗, ピーナッツ抜き, ピーナッツアレルギー. Never name one in an order or a recommendation, even alongside another request (not "a peanut milk tea, no ice").
- taste: sweetness and spice are 0–4, where 2 is "as usual"; below 2 means less, above 2 means more.
- personality.food: local_favourite means the place's specialty; my_usual means whatever is closest to their favourites. budget: save means modest choices.

Tips:
- "text": one or two short sentences in ${home.name}, at most 30 words, practical and specific to this place and time. Where it helps, frame it against the norms of the traveller's home country (tipping, payment, etiquette).
- "basis": 1–2 values from allowedBasis.

"placeNameLocal": the place's name in ${local.name} script if you know it with confidence; otherwise leave it out. Never invent an address.`;
}

export function placeCardUser(request: PlaceCardRequest): string {
  return JSON.stringify({
    traveller: promptProfile(request.profile, 'place-card'),
    situation: promptSituation(request.situation),
    allowedBasis: allowedBasis(request.profile, request.situation),
  });
}

/** Every reason a phrase can't stay on the card. */
export function phraseProblems(
  phrase: { local: string; gloss: string; because: string; basis: Basis[] },
  local: LanguageInfo,
  allowed: readonly Basis[],
  hazards: readonly Hazard[],
): string[] {
  const problems: string[] = [];
  const badBasis = phrase.basis.filter((b) => !allowed.includes(b));
  if (badBasis.length > 0) problems.push(`basis ${badBasis.map((b) => `"${b}"`).join(', ')} isn't in allowedBasis`);
  if (wordCount(phrase.because) > MAX_BECAUSE_WORDS) problems.push(`"because" has more than 8 words`);
  if (FIELD_NAME.test(phrase.because)) problems.push(`"because" uses a field name; say it in plain words`);
  if (!inLocalScript(phrase.local, local)) problems.push(`"local" isn't written in ${local.name}`);
  else if (local.script === 'han' && hasLatinLetters(phrase.local)) problems.push('"local" contains Latin letters');
  const hazard = unsafeMention([phrase.local, phrase.gloss], hazards);
  if (hazard) problems.push(`it suggests ${hazard}, which the traveller must avoid`);
  return problems;
}

export function tipProblems(tip: { text: string; basis: Basis[] }, home: LanguageInfo, allowed: readonly Basis[], hazards: readonly Hazard[]): string[] {
  const problems: string[] = [];
  const badBasis = tip.basis.filter((b) => !allowed.includes(b));
  if (badBasis.length > 0) problems.push(`basis ${badBasis.map((b) => `"${b}"`).join(', ')} isn't in allowedBasis`);
  if (!mostlyInScript(tip.text, home)) problems.push(`it isn't written in ${home.name}`);
  const hazard = unsafeMention([tip.text], hazards);
  if (hazard) problems.push(`it suggests ${hazard}, which the traveller must avoid`);
  return problems;
}

function phraseId(request: PlaceCardRequest, index: number, local: string): string {
  const seed = `${request.situation.place?.id ?? request.situation.place?.name ?? request.situation.city}|${request.situation.hourBucket}|${local}`;
  return `pc-${createHash('sha256').update(seed).digest('hex').slice(0, 10)}-${index + 1}`;
}

/** Checks the model's card, drops what fails, and builds the contract response. */
export function finalizePlaceCard(request: PlaceCardRequest, output: PlaceCardModelOutput, now = new Date()): Finalized<PlaceCardResponse> {
  const local = languageInfo(request.situation.localLanguage);
  const home = languageInfo(request.profile.homeLanguage);
  const allowed = allowedBasis(request.profile, request.situation);
  const hazards = hazardsFor(request.profile);
  const dropped: string[] = [];
  const issues: string[] = [];

  const phrases: CardPhrase[] = [];
  output.phrases.forEach((phrase, index) => {
    const problems = phraseProblems(phrase, local, allowed, hazards);
    if (problems.length > 0) {
      const line = `phrases[${index}] (${phrase.local} / ${phrase.gloss}): ${problems.join('; ')}`;
      dropped.push(line);
      issues.push(line);
      return;
    }
    if (phrases.length >= 3) return;
    phrases.push({
      id: '',
      lang: request.situation.localLanguage,
      local: phrase.local.trim(),
      romanization: romanizationFor(phrase.local.trim(), local, phrase.romanization),
      gloss: phrase.gloss.trim(),
      because: phrase.because.trim(),
      basis: phrase.basis,
    });
  });
  phrases.forEach((phrase, index) => (phrase.id = phraseId(request, index, phrase.local)));

  const tips: Tip[] = [];
  output.tips.forEach((tip, index) => {
    const problems = tipProblems(tip, home, allowed, hazards);
    if (problems.length > 0) {
      const line = `tips[${index}]: ${problems.join('; ')}`;
      dropped.push(line);
      issues.push(line);
      return;
    }
    if (tips.length < 2) tips.push({ text: tip.text.trim(), basis: tip.basis });
  });

  if (phrases.length < 2 || tips.length < 1) {
    return { ok: false, issues: [...issues, `Keep at least 2 phrases and 1 tip that pass these rules (allowedBasis is ${JSON.stringify(allowed)}).`] };
  }

  const response: PlaceCardResponse = { language: request.situation.localLanguage, phrases, tips, generatedAt: now.toISOString() };
  // The device's local name comes from MapKit; the model's only if it's in the local script.
  const deviceName = request.situation.place?.localName;
  const modelName = output.placeNameLocal?.trim();
  if (deviceName && local.script !== 'latin' && inLocalScript(deviceName, local)) response.placeNameLocal = deviceName;
  else if (modelName && request.situation.place && local.script !== 'latin' && inLocalScript(modelName, local)) response.placeNameLocal = modelName;

  if (!Value.Check(PlaceCardResponse, response)) return { ok: false, issues: [describeErrors(PlaceCardResponse, response)] };
  return { ok: true, value: response, dropped };
}

/** Fills a missing nullable romanization so the shape check doesn't fail on it alone. */
export function normalizePlaceCard(value: unknown): unknown {
  const card = value as { phrases?: unknown };
  if (Array.isArray(card?.phrases)) {
    for (const phrase of card.phrases) {
      if (phrase && typeof phrase === 'object' && !('romanization' in phrase)) (phrase as Record<string, unknown>).romanization = null;
      if (phrase && typeof phrase === 'object' && (phrase as Record<string, unknown>).romanization === '') (phrase as Record<string, unknown>).romanization = null;
    }
  }
  return value;
}
