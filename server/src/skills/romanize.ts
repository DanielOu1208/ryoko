// Chinese romanization (design §7.9): pinyin from pinyin-pro on the server, with
// tone sandhi on (一杯 → yì bēi, 不要 → bú yào). Japanese romaji comes from the
// model; Latin-script languages have none.

import { pinyin } from 'pinyin-pro';
import type { LanguageInfo } from './context.ts';

const PUNCTUATION: Record<string, string> = {
  '，': ',', '。': '.', '？': '?', '！': '!', '、': ',', '：': ':', '；': ';',
  '（': '(', '）': ')', '“': '"', '”': '"', '‘': "'", '’': "'", '《': '"', '》': '"', '～': '~', '「': '"', '」': '"',
};
/** Attach to the next word: no space after. */
const OPENING = new Set(['（', '“', '‘', '《', '「', '(', '[']);
/** Attach to the previous word: no space before. */
const CLOSING = new Set(['，', '。', '？', '！', '、', '：', '；', '）', '”', '’', '》', '」', ',', '.', '?', '!', ':', ';', ')', ']', '…', '～']);
const SENTENCE_END = new Set(['。', '？', '！', '.', '?', '!']);

/** Splits pinyin-pro's non-Chinese runs into words, numbers and single punctuation marks. */
function pieces(token: string): string[] {
  return token.match(/\p{L}[\p{L}\p{N}'’-]*|\p{N}+(?:[.,]\p{N}+)*|\S/gu) ?? [];
}

/** Pinyin with tone marks, syllables spaced, CJK punctuation as ASCII, sentences capitalized. */
export function toPinyin(text: string): string {
  const tokens = (pinyin(text, { toneSandhi: true, type: 'array', nonZh: 'consecutive' }) as string[]).flatMap(pieces);
  let out = '';
  let capitalizeNext = true;
  let glueNext = true;
  for (const piece of tokens) {
    const isWord = /^\p{L}/u.test(piece);
    const text = isWord && capitalizeNext ? piece[0]!.toUpperCase() + piece.slice(1) : (PUNCTUATION[piece] ?? piece);
    if (isWord || /^\p{N}/u.test(piece)) capitalizeNext = false;
    out += glueNext || CLOSING.has(piece) ? text : ` ${text}`;
    glueNext = OPENING.has(piece);
    if (SENTENCE_END.has(piece)) capitalizeNext = true;
  }
  return out.trim();
}

/**
 * The romanization a phrase should carry: pinyin for Chinese (the model's is
 * ignored), the model's romaji for Japanese and other non-Latin scripts, and
 * null for Latin-script languages.
 */
export function romanizationFor(local: string, info: LanguageInfo, fromModel: string | null | undefined): string | null {
  if (info.romanization === 'pinyin') return toPinyin(local).slice(0, 300) || null;
  if (info.romanization === 'none') return null;
  const text = fromModel?.trim();
  return text ? (text[0]!.toUpperCase() + text.slice(1)).slice(0, 300) : null;
}
