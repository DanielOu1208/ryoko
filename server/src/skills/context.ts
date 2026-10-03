// What the skills tell the model about the traveller and the moment (design §5, §6.4):
// a compacted profile (null and empty fields dropped, so the model can't cite
// them), the explicit allowedBasis list, and the time facts derived from the
// situation's local time only (the server never uses its own clock for this).

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Basis, LangCodeTable, Profile, Situation } from '@ryoko/contracts';
import { CONTRACTS_DIR } from '../fixtures.ts';

/** Calm local friend (design §6.1). Shared by every skill. */
export const PERSONA =
  "You are Mimo, a calm local friend who lives where the traveller is right now. Warm, brief, first person. No exclamation marks, no emoji. Never call yourself an AI, an assistant or a bot.";

/** Drops null, empty strings, empty arrays and empty objects, recursively. */
export function compact(value: unknown): unknown {
  if (Array.isArray(value)) {
    const items = value.map(compact).filter((item) => item !== undefined);
    return items.length > 0 ? items : undefined;
  }
  if (value !== null && typeof value === 'object') {
    const entries = Object.entries(value).flatMap(([key, item]) => {
      const kept = compact(item);
      return kept === undefined ? [] : [[key, kept] as const];
    });
    return entries.length > 0 ? Object.fromEntries(entries) : undefined;
  }
  if (value === null || value === '' || value === undefined) return undefined;
  return value;
}

export type ProfileUse = 'place-card' | 'discover' | 'mimo';

/**
 * The profile as the model sees it. Never the version hash. Early bird / night owl
 * is a discovery hint only, never a "because…" input (design §5), so the place
 * card doesn't see it. The home base matters only to Mimo, and only by name.
 */
export function promptProfile(profile: Profile, use: ProfileUse): Record<string, unknown> {
  const { version: _version, homeBase, personality, ...rest } = profile;
  const view: Record<string, unknown> = { ...rest };
  if (personality) view.personality = use === 'place-card' ? { ...personality, rhythm: null } : personality;
  if (use === 'mimo' && homeBase) view.homeBase = { name: homeBase.name, localName: homeBase.localName };
  // A slider at 2 means "as usual": nothing to say about it.
  if (profile.taste) view.taste = { sweetness: profile.taste.sweetness === 2 ? null : profile.taste.sweetness, spice: profile.taste.spice === 2 ? null : profile.taste.spice };
  return (compact(view) as Record<string, unknown> | undefined) ?? {};
}

const filled = (value: unknown) => compact(value) !== undefined;

/**
 * The basis values a "because…" line or tip may cite: only inputs that are actually
 * filled in (design §5). `memory` comes after core. Early bird / night owl alone
 * doesn't count as personality: it's never a "because…" input.
 */
export function allowedBasis(profile: Profile, _situation: Situation): Basis[] {
  // The situation always names a place: a point of interest, or in city-only mode the city itself.
  const basis: Basis[] = ['place', 'localTime'];
  const personality = profile.personality;
  if (personality && (personality.food || personality.budget || personality.vibe)) basis.push('personality');
  if (profile.nationality) basis.push('nationality');
  if (filled(profile.diet) || filled(profile.dietNotes)) basis.push('diet');
  if (filled(profile.allergies)) basis.push('allergy');
  if (filled(profile.favourites)) basis.push('favourites');
  const taste = profile.taste;
  if (taste && ((taste.sweetness !== null && taste.sweetness !== 2) || (taste.spice !== null && taste.spice !== 2))) basis.push('taste');
  return basis;
}

const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'] as const;

export interface TimeFacts {
  /** `2026-10-05` */
  date: string;
  /** `15:00` */
  clock: string;
  weekday: (typeof WEEKDAYS)[number];
  partOfDay: 'early morning' | 'morning' | 'midday' | 'afternoon' | 'evening' | 'late night';
}

/** Weekday and part of day from the situation's local time string (its wall clock, not ours). */
export function timeFacts(situation: Situation): TimeFacts {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(situation.localTime);
  if (!match) throw new Error(`Unparseable localTime: ${situation.localTime}`);
  const [, y, mo, d, h, mi] = match as unknown as [string, string, string, string, string, string];
  const hour = Number(h);
  const weekday = WEEKDAYS[new Date(Date.UTC(Number(y), Number(mo) - 1, Number(d))).getUTCDay()] ?? 'Monday';
  const partOfDay: TimeFacts['partOfDay'] =
    hour >= 5 && hour < 8 ? 'early morning' : hour < 11 && hour >= 8 ? 'morning' : hour >= 11 && hour < 14 ? 'midday' : hour >= 14 && hour < 17 ? 'afternoon' : hour >= 17 && hour < 21 ? 'evening' : 'late night';
  return { date: `${y}-${mo}-${d}`, clock: `${h}:${mi}`, weekday, partOfDay };
}

/** The situation as the model sees it: the place, the area and the local moment. */
export function promptSituation(situation: Situation): Record<string, unknown> {
  const time = timeFacts(situation);
  const place = situation.place
    ? (compact({ name: situation.place.name, localName: situation.place.localName, category: situation.place.category, address: situation.place.address }) as Record<string, unknown>)
    : null;
  return compact({
    place,
    city: situation.city,
    district: situation.district,
    countryCode: situation.countryCode,
    localLanguage: situation.localLanguage,
    localTime: `${time.weekday} ${time.date} ${time.clock} (${time.partOfDay})`,
    timeZone: situation.timeZone,
    previewing: situation.mode === 'preview' ? true : undefined,
  }) as Record<string, unknown>;
}

// --- languages (design §7.9) ---

export type Script = 'han' | 'japanese' | 'hangul' | 'latin' | 'other';

export interface LanguageInfo {
  tag: string;
  /** English name, e.g. "Simplified Chinese". */
  name: string;
  script: Script;
  /** pinyin: the server fills it with pinyin-pro. model: the model writes it (romaji). none: Latin script, null. */
  romanization: 'pinyin' | 'model' | 'none';
}

const langTable = JSON.parse(readFileSync(join(CONTRACTS_DIR, 'tables', 'langcodes.json'), 'utf8')) as LangCodeTable;
const displayNames = new Intl.DisplayNames(['en'], { type: 'language' });

const SCRIPT_BY_PRIMARY: Record<string, Script> = { zh: 'han', ja: 'japanese', ko: 'hangul' };
const NON_LATIN_PRIMARY = new Set(['ar', 'he', 'ru', 'uk', 'el', 'th', 'hi', 'bn', 'ka', 'hy', 'fa', 'ta', 'te', 'km', 'lo', 'my', 'am', 'bg', 'sr', 'mn']);

export function languageInfo(tag: string): LanguageInfo {
  const primary = tag.split('-')[0]?.toLowerCase() ?? tag;
  const row = langTable.languages.find((l) => l.tag === tag) ?? langTable.languages.find((l) => l.tag.split('-')[0] === primary);
  const script: Script = SCRIPT_BY_PRIMARY[primary] ?? (NON_LATIN_PRIMARY.has(primary) ? 'other' : 'latin');
  let name: string;
  try {
    name = row && row.tag === tag ? row.displayName : (displayNames.of(tag) ?? tag);
  } catch {
    name = tag;
  }
  const romanization = script === 'han' ? 'pinyin' : script === 'latin' ? 'none' : 'model';
  return { tag, name, script, romanization };
}

const HAN = /\p{Script=Han}/u;
const JAPANESE = /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}]/u;
const HANGUL = /\p{Script=Hangul}/u;
const LATIN_LETTER = /[A-Za-zＡ-Ｚａ-ｚ]/;
const CJK_ANY = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;

/** True when the text is written in the language's script (at least one character of it). */
export function inLocalScript(text: string, info: LanguageInfo): boolean {
  switch (info.script) {
    case 'han':
      return HAN.test(text);
    case 'japanese':
      return JAPANESE.test(text);
    case 'hangul':
      return HANGUL.test(text);
    case 'latin':
      return LATIN_LETTER.test(text) && !CJK_ANY.test(text);
    default:
      return text.trim().length > 0;
  }
}

export const hasLatinLetters = (text: string) => LATIN_LETTER.test(text);

/**
 * True when the text is mostly in the language's script: home-language tips may
 * quote a local word, but must be written in the home language.
 */
export function mostlyInScript(text: string, info: LanguageInfo): boolean {
  if (info.script !== 'latin') return inLocalScript(text, info);
  const latin = text.match(/[A-Za-z]/g)?.length ?? 0;
  const cjk = text.match(/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/gu)?.length ?? 0;
  return latin > 0 && latin >= cjk * 2;
}
export const hasCjk = (text: string) => CJK_ANY.test(text);

/** Words in a Latin-script line, or a CJK line's characters divided by 2.5 (about a word each). */
export function wordCount(text: string): number {
  const words = text.trim().split(/\s+/).filter(Boolean);
  if (words.length > 1 || !hasCjk(text)) return words.length;
  return Math.ceil(text.replace(/\s/g, '').length / 2.5);
}
