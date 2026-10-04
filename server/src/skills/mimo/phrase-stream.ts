// The phrase-tag stream transformer (design §6.2). Mimo writes every sayable
// phrase as `<phrase lang="…" local="…" gloss="…" romanization="…"/>` on its own
// line; this turns the model's text deltas into ordered `text` and `phrase` events.
//
// - Text from `<phrase` to `/>` is buffered, even when a delta splits it.
// - Romanization: pinyin-pro for Chinese, the model's romaji for Japanese.
// - A tag that can't be parsed is passed through as text; one still open when
//   the run ends is flushed as text then. Wrappers the model sometimes adds
//   (`<phrases>…</phrases>`, a stray `</phrase>`) are dropped.
// - Phrases past the per-reply cap are dropped.
// - When text comes both before and after a tool call, a blank line separates them.
// - Whitespace next to phrase blocks and at the very start and end is trimmed.
// The agent's transcript keeps the raw tags, so Mimo sees its earlier phrases.

import type { Phrase } from '@ryoko/contracts';
import { hasLatinLetters, inLocalScript, type LanguageInfo } from '../context.ts';
import { romanizationFor } from '../romanize.ts';

const OPEN = '<phrase';
const CLOSE_PAIR = '</phrase>';
/** Any of our markup: `<phrase`, `<phrases`, `</phrase>`, `</phrases>`. */
const MARKUP = /<\/?phrase/;
const MARKUP_PREFIXES = ['<phrase', '</phrases>'];

export interface PhraseStreamOptions {
  /** The active situation's local language: every phrase is in it. */
  language: LanguageInfo;
  /** Phrase ids are `${idPrefix}-1`, `-2`, … */
  idPrefix: string;
  /** At most this many phrase events per reply (design §6.2: about 4). */
  maxPhrases?: number;
  /** A tag longer than this without its end is treated as text. */
  maxTagLength?: number;
  onText(delta: string): void;
  onPhrase(phrase: Phrase): void;
}

export interface PhraseStreamStats {
  phrases: number;
  /** Tags passed through as text: unparseable, unterminated or in the wrong script. */
  malformed: number;
  /** Phrases dropped by the per-reply cap. */
  dropped: number;
  /** Each dropped phrase, with its text, for the server log: `over the cap: 一杯… / One cup…`. */
  droppedPhrases: string[];
  /** Text pieces outside tags that contain local script (the prompt forbids it). */
  strayLocalScript: number;
}

const ENTITIES: Record<string, string> = { '&quot;': '"', '&#34;': '"', '&apos;': "'", '&#39;': "'", '&lt;': '<', '&gt;': '>', '&amp;': '&' };
const decode = (text: string) => text.replace(/&(?:quot|apos|lt|gt|amp|#34|#39);/g, (entity) => ENTITIES[entity] ?? entity);

/** Attributes of an opening tag: double, single or curly quotes. */
export function parseAttributes(tag: string): Record<string, string> {
  const attributes: Record<string, string> = {};
  for (const match of tag.matchAll(/([A-Za-z_][\w-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|“([^”]*)”)/g)) {
    const name = match[1]!.toLowerCase();
    attributes[name] = decode((match[2] ?? match[3] ?? match[4] ?? '').trim());
  }
  return attributes;
}

/** How many characters at the end of `text` could be the start of our markup. */
function partialMarkupLength(text: string): number {
  const longest = Math.max(...MARKUP_PREFIXES.map((p) => p.length)) - 1;
  for (let n = Math.min(longest, text.length); n > 0; n--) {
    const end = text.slice(-n);
    if (MARKUP_PREFIXES.some((prefix) => prefix.startsWith(end))) return n;
  }
  return 0;
}

export class PhraseStream {
  private buffer = '';
  private count = 0;
  private lastKind: 'none' | 'text' | 'phrase' = 'none';
  /** Whitespace at the end of the last text, held until more text follows. */
  private pendingSpace = '';
  private boundary = false;
  readonly stats: PhraseStreamStats = { phrases: 0, malformed: 0, dropped: 0, droppedPhrases: [], strayLocalScript: 0 };
  private readonly options: Required<PhraseStreamOptions>;

  constructor(options: PhraseStreamOptions) {
    this.options = { maxPhrases: 4, maxTagLength: 800, ...options };
  }

  /** Feeds one text delta from the model. */
  push(delta: string): void {
    this.buffer += delta;
    this.drain(false);
  }

  /**
   * A tool call starts: whatever is buffered is final (a tag can't span a tool
   * call), and the next text gets a separator.
   */
  toolBoundary(): void {
    this.drain(true);
    this.boundary = true;
  }

  /** The run is over: flushes anything still buffered, an unterminated tag as text. */
  end(): void {
    this.drain(true);
    this.pendingSpace = '';
  }

  private drain(final: boolean): void {
    for (;;) {
      const match = MARKUP.exec(this.buffer);
      if (!match) {
        const hold = final ? 0 : partialMarkupLength(this.buffer);
        this.text(this.buffer.slice(0, this.buffer.length - hold));
        this.buffer = this.buffer.slice(this.buffer.length - hold);
        return;
      }
      this.text(this.buffer.slice(0, match.index));
      this.buffer = this.buffer.slice(match.index);

      const closing = this.buffer.startsWith('</');
      const nameEnd = closing ? 8 : OPEN.length; // after `</phrase` or `<phrase`
      const next = this.buffer.charAt(nameEnd);
      if (next === '' && !final) return; // wait for the next character
      if (next === 's' && !final && this.buffer.length < nameEnd + 2) return; // `<phrases` or `<phrasebook`?
      const wrapper = next === 's' && /^<\/?phrases[\s>]/.test(this.buffer.slice(0, nameEnd + 2));
      if (closing || wrapper) {
        // `</phrase>`, `<phrases>`, `</phrases>`: wrappers around tags, never content.
        const gt = this.buffer.indexOf('>');
        if (gt === -1 && !final && this.buffer.length <= 40) return;
        if (gt !== -1 && gt <= 40 && (closing ? /^<\/phrases?\s*>/ : /^<phrases\b[^>]*>/).test(this.buffer.slice(0, gt + 1))) {
          this.buffer = this.buffer.slice(gt + 1);
          continue;
        }
        this.text(this.buffer.slice(0, 2));
        this.buffer = this.buffer.slice(2);
        continue;
      }
      if (next !== '' && !/[\s/>]/.test(next)) {
        // `<phrasebook`: not our tag
        this.text(OPEN);
        this.buffer = this.buffer.slice(OPEN.length);
        continue;
      }

      const end = this.findTagEnd();
      if (end === -1) {
        if (!final && this.buffer.length <= this.options.maxTagLength) return; // wait for the rest
        // Unterminated: at the end of the run, or far too long to be a tag.
        this.stats.malformed++;
        if (final) {
          this.text(this.buffer);
          this.buffer = '';
          return;
        }
        this.text(OPEN);
        this.buffer = this.buffer.slice(OPEN.length);
        continue;
      }
      const tag = this.buffer.slice(0, end);
      this.buffer = this.buffer.slice(end);
      this.tag(tag);
    }
  }

  /** End index (exclusive) of the tag at the start of the buffer, or -1 if it isn't complete yet. */
  private findTagEnd(): number {
    const gt = this.buffer.indexOf('>', OPEN.length);
    if (gt === -1) return -1;
    if (this.buffer[gt - 1] === '/') return gt + 1;
    // `<phrase …>…</phrase>`: accept the paired form too.
    const close = this.buffer.indexOf(CLOSE_PAIR, gt);
    if (close !== -1) return close + CLOSE_PAIR.length;
    // An opening tag with no close yet: wait, unless another tag has started.
    return MARKUP.test(this.buffer.slice(gt)) ? gt + 1 : -1;
  }

  private tag(raw: string): void {
    const openEnd = raw.indexOf('>') + 1;
    const attributes = parseAttributes(raw.slice(0, openEnd));
    const inner = raw.endsWith(CLOSE_PAIR) ? raw.slice(openEnd, -CLOSE_PAIR.length).trim() : '';
    const local = attributes.local || inner;
    const gloss = attributes.gloss ?? '';
    const language = this.options.language;
    if (!local || !gloss) {
      this.stats.malformed++;
      this.text(raw);
      return;
    }
    if (local.length > 200 || gloss.length > 200 || !inLocalScript(local, language) || (language.script === 'han' && hasLatinLetters(local))) {
      // Parsed but unusable as a phrase block: keep the words, as text.
      this.stats.malformed++;
      this.text(`${local} (${gloss})`);
      return;
    }
    if (this.count >= this.options.maxPhrases) {
      this.stats.dropped++;
      this.stats.droppedPhrases.push(`over the cap: ${local} / ${gloss}`);
      return;
    }
    this.count++;
    this.stats.phrases++;
    this.boundary = false; // a phrase block stands on its own line anyway
    this.pendingSpace = '';
    this.lastKind = 'phrase';
    this.options.onPhrase({
      id: `${this.options.idPrefix}-${this.count}`,
      lang: language.tag,
      local,
      romanization: romanizationFor(local, language, attributes.romanization),
      gloss,
    });
  }

  private text(chunk: string): void {
    // No leading whitespace at the start of the reply or right after a phrase block.
    const text = this.lastKind === 'text' ? chunk : chunk.replace(/^\s+/, '');
    if (!text) return;
    const trailing = /\s*$/.exec(text)?.[0] ?? '';
    let body = text.slice(0, text.length - trailing.length);
    if (!body) {
      this.pendingSpace += trailing;
      return;
    }
    let lead = this.pendingSpace;
    if (this.boundary) {
      this.boundary = false;
      const leading = /^\s*/.exec(body)?.[0] ?? '';
      if (this.lastKind === 'text' && !`${lead}${leading}`.includes('\n')) {
        lead = '\n\n';
        body = body.slice(leading.length);
      }
    }
    this.pendingSpace = trailing;
    if (this.options.language.script !== 'latin' && inLocalScript(body, this.options.language)) this.stats.strayLocalScript++;
    this.lastKind = 'text';
    this.options.onText(lead + body);
  }
}
