// The allergy-card skill (design §4.5, §7.6), for free-text allergens only: chip
// allergens use the reviewed templates on the device and never reach the server.
// The card keeps the template wording per severity, says it isn't reviewed
// (`reviewed: false`), and the severity always comes from the request, never the model.

import { Type, type Static } from 'typebox';
import { Value } from 'typebox/value';
import { AllergyCardResponse, Strict, type AllergyCardRequest } from '@ryoko/contracts';
import type { Finalized } from '../llm/typed.ts';
import { describeErrors } from '../validate.ts';
import { inLocalScript, languageInfo, mostlyInScript, type LanguageInfo } from './context.ts';
import { romanizationFor } from './romanize.ts';

export const ALLERGY_CARD_PROMPT_VERSION = 'ac-1';

/** The wording per severity (design §4.5). X is the allergen. */
export const SEVERITY_WORDING = {
  mild: 'Please avoid X if possible.',
  serious: 'I must not eat X, including X oil or sauces containing X.',
  life_threatening: 'Even a trace of X can be life-threatening; please check every ingredient and use clean utensils.',
} as const;

/** One line per allergen, in request order; the count is fixed by the request. */
export function allergyCardModelOutput(count: number) {
  return Strict({
    title: Type.String({ minLength: 1, maxLength: 60, description: 'Short card title in the local language' }),
    items: Type.Array(
      Strict({
        local: Type.String({ minLength: 1, maxLength: 300, description: 'The line in the local language' }),
        home: Type.String({ minLength: 1, maxLength: 300, description: 'The same line in the home language' }),
      }),
      { minItems: count, maxItems: count },
    ),
    requestLocal: Type.String({ minLength: 1, maxLength: 200, description: 'Asks whether the dish contains these allergens, local language' }),
    requestHome: Type.String({ minLength: 1, maxLength: 200, description: 'The same question in the home language' }),
    romanization: Type.Optional(Type.String({ minLength: 1, maxLength: 300 })),
  });
}
export type AllergyCardModelOutput = Static<ReturnType<typeof allergyCardModelOutput>>;

export function allergyCardSystem(local: LanguageInfo, home: LanguageInfo): string {
  const romanization =
    local.romanization === 'model'
      ? `"romanization": the ${local.script === 'japanese' ? 'Hepburn romaji (with macrons)' : 'standard romanization'} of "requestLocal".`
      : '"romanization": leave it out.';
  return `You write allergy cards that a traveller shows to restaurant staff. This is safety text: be exact, plain and polite. No exclamation marks, no emoji.

Task: a card in ${local.name} for the allergens in the request, with ${home.name} underneath.
- "items": one per allergen, in the same order as the request. Write the line for its severity, with X replaced by the allergen:
  - mild: "${SEVERITY_WORDING.mild}"
  - serious: "${SEVERITY_WORDING.serious}" Mention X oil only if such an oil exists; otherwise "including sauces or dishes containing X".
  - life_threatening: "${SEVERITY_WORDING.life_threatening}"
  "local" is that line in natural ${local.name} as a native speaker would write it on a card, using the everyday local word for the allergen. "home" is the same line in ${home.name}, naming the allergen in the traveller's own words.
- "title": a short card title in ${local.name}, such as "About my allergies".
- "requestLocal": one short question in ${local.name} asking whether the dish contains these allergens. "requestHome": the same question in ${home.name}.
- ${romanization}`;
}

export function allergyCardUser(request: AllergyCardRequest): string {
  return JSON.stringify({
    localLanguage: request.language,
    homeLanguage: request.homeLanguage,
    allergies: request.allergies.map((a) => ({ allergen: a.label, severity: a.severity })),
  });
}

/** The first word of a label (at least 3 letters), lowercased: "Kiwi fruit" → "kiwi". */
function labelStem(label: string): string {
  const word = label.trim().split(/\s+/).find((w) => w.length >= 3) ?? label.trim();
  return word.toLowerCase().replace(/(?:es|s)$/, '');
}

export function finalizeAllergyCard(request: AllergyCardRequest, output: AllergyCardModelOutput): Finalized<AllergyCardResponse> {
  const local = languageInfo(request.language);
  const home = languageInfo(request.homeLanguage);
  const issues: string[] = [];
  if (!inLocalScript(output.title, local)) issues.push(`"title" isn't in ${local.name}`);
  if (!inLocalScript(output.requestLocal, local)) issues.push(`"requestLocal" isn't in ${local.name}`);
  if (!mostlyInScript(output.requestHome, home)) issues.push(`"requestHome" isn't in ${home.name}`);
  output.items.forEach((item, index) => {
    const allergy = request.allergies[index];
    if (!allergy) return;
    if (!inLocalScript(item.local, local)) issues.push(`items[${index}].local isn't in ${local.name}`);
    if (!mostlyInScript(item.home, home)) issues.push(`items[${index}].home isn't in ${home.name}`);
    // The home line must name this allergen: catches a reordered or merged list.
    if (home.script === 'latin' && !item.home.toLowerCase().includes(labelStem(allergy.label))) {
      issues.push(`items[${index}].home doesn't name "${allergy.label}"`);
    }
  });
  if (issues.length > 0) return { ok: false, issues };

  const response: AllergyCardResponse = {
    language: request.language,
    title: output.title.trim(),
    items: output.items.map((item, index) => ({
      allergenId: 'custom' as const,
      local: item.local.trim(),
      home: item.home.trim(),
      severity: request.allergies[index]!.severity,
    })),
    requestLocal: output.requestLocal.trim(),
    requestHome: output.requestHome.trim(),
    reviewed: false,
  };
  const romanization = romanizationFor(response.requestLocal, local, output.romanization);
  if (romanization) response.romanization = romanization;
  if (!Value.Check(AllergyCardResponse, response)) return { ok: false, issues: [describeErrors(AllergyCardResponse, response)] };
  return { ok: true, value: response, dropped: [] };
}
