// Travel guides from Wikivoyage (design §8.4): the pages for the demo cities and
// their countries' etiquette, split into section-sized chunks for the Snowflake
// `GUIDES` table. Wikivoyage text is CC BY-SA 4.0, so every chunk keeps its
// article URL (with the section anchor) and the licence, and cited tips link back.

import { createHash } from 'node:crypto';

export const WIKIVOYAGE_API = 'https://en.wikivoyage.org/w/api.php';
export const WIKIVOYAGE_LICENSE = 'CC BY-SA 4.0';
export const WIKIVOYAGE_ATTRIBUTION = 'Wikivoyage contributors';
/** Wikimedia asks for a descriptive User-Agent with a way to reach the operator. */
export const USER_AGENT = 'RyokoGuideLoader/0.1 (StormHack 2026; https://github.com/DanielOu1208/ryoko)';

export interface GuidePage {
  title: string;
  countryCode: string;
  /** The city the page is about; null for country pages and travel topics. */
  city: string | null;
  /** Top-level sections to keep (lowercase). Absent keeps every section except SKIPPED_SECTIONS. */
  sections?: readonly string[];
}

/** Lists of hotels and transport timetables help nobody standing in a shop. */
export const SKIPPED_SECTIONS = ['sleep', 'get in', 'go next', 'see also', 'references', 'external links'];

/** What Ryoko loads: the demo cities (Tokyo/Shinjuku, Shanghai/Jing'an), their countries' customs, and their food. */
export const GUIDE_PAGES: readonly GuidePage[] = [
  { title: 'Tokyo', countryCode: 'JP', city: 'Tokyo', sections: ['overview', 'understand', 'talk', 'get around', 'eat', 'drink', 'buy', 'stay safe', 'cope', 'respect'] },
  { title: 'Tokyo/Shinjuku', countryCode: 'JP', city: 'Tokyo' },
  { title: 'Japan', countryCode: 'JP', city: null, sections: ['talk', 'get around', 'buy', 'eat', 'drink', 'stay safe', 'stay healthy', 'respect', 'cope', 'connect'] },
  { title: 'Japanese cuisine', countryCode: 'JP', city: null },
  { title: 'Shanghai', countryCode: 'CN', city: 'Shanghai', sections: ['overview', 'understand', 'talk', 'get around', 'eat', 'drink', 'buy', 'stay safe', 'cope', 'respect'] },
  { title: "Shanghai/Jing'an", countryCode: 'CN', city: 'Shanghai' },
  { title: 'China', countryCode: 'CN', city: null, sections: ['talk', 'get around', 'buy', 'eat', 'drink', 'stay safe', 'stay healthy', 'respect', 'cope', 'connect'] },
  { title: 'Chinese cuisine', countryCode: 'CN', city: null },
];

export interface GuideChunk {
  id: string;
  pageTitle: string;
  /** "Eat › Budget", or "Overview" for the text before the first heading. */
  section: string;
  /** The top-level section, lowercase: the Cortex Search attribute for filtering. */
  topic: string;
  countryCode: string;
  city: string | null;
  body: string;
  url: string;
  revisionId: number;
}

export interface FetchedPage {
  title: string;
  url: string;
  revisionId: number;
  extract: string;
}

/** The plain-text extract of one page, with `== Heading ==` lines. */
export async function fetchPage(title: string, fetchImpl: typeof fetch = fetch): Promise<FetchedPage> {
  const params = new URLSearchParams({
    action: 'query',
    prop: 'extracts|revisions|info',
    rvprop: 'ids',
    inprop: 'url',
    explaintext: '1',
    exsectionformat: 'wiki',
    redirects: '1',
    format: 'json',
    formatversion: '2',
    titles: title,
  });
  const response = await fetchImpl(`${WIKIVOYAGE_API}?${params}`, { headers: { 'User-Agent': USER_AGENT, Accept: 'application/json' } });
  if (!response.ok) throw new Error(`Wikivoyage answered HTTP ${response.status} for ${title}.`);
  const body = (await response.json()) as { query?: { pages?: { title: string; missing?: boolean; fullurl?: string; extract?: string; revisions?: { revid: number }[] }[] } };
  const page = body.query?.pages?.[0];
  if (!page || page.missing || !page.extract || !page.fullurl) throw new Error(`Wikivoyage has no page called ${title}.`);
  return { title: page.title, url: page.fullurl, revisionId: page.revisions?.[0]?.revid ?? 0, extract: page.extract };
}

/** MediaWiki's section anchor: spaces become underscores. */
export function sectionAnchor(heading: string): string {
  return encodeURIComponent(heading.replace(/ /g, '_')).replace(/%2F/g, '/');
}

interface Section {
  path: string[];
  text: string[];
}

/** Splits an extract at its headings: `== Eat ==` opens "Eat", `=== Budget ===` opens "Eat › Budget". */
export function splitSections(extract: string): Section[] {
  const sections: Section[] = [{ path: ['Overview'], text: [] }];
  const path: string[] = [];
  for (const line of extract.split('\n')) {
    const heading = /^(={2,6})\s*(.+?)\s*\1\s*$/.exec(line);
    if (heading) {
      const level = heading[1]!.length - 2;
      path.length = level;
      path[level] = heading[2]!;
      sections.push({ path: [...path].filter(Boolean), text: [] });
    } else {
      sections.at(-1)!.text.push(line);
    }
  }
  return sections;
}

/** Paragraphs joined up to about `maxChars`; a longer paragraph is cut at sentence ends. */
export function packParagraphs(text: string, maxChars: number): string[] {
  const paragraphs = text
    .split(/\n\s*\n|\n/)
    .map((p) => p.replace(/\s+/g, ' ').trim())
    .filter((p) => p.length > 0);
  const pieces: string[] = [];
  for (const paragraph of paragraphs) {
    if (paragraph.length <= maxChars) {
      pieces.push(paragraph);
      continue;
    }
    let current = '';
    for (const sentence of paragraph.split(/(?<=[.!?])\s+/)) {
      if (current && current.length + sentence.length + 1 > maxChars) {
        pieces.push(current);
        current = '';
      }
      current = current ? `${current} ${sentence}` : sentence;
    }
    if (current) pieces.push(current);
  }
  const chunks: string[] = [];
  let current = '';
  for (const piece of pieces) {
    if (current && current.length + piece.length + 1 > maxChars) {
      chunks.push(current);
      current = '';
    }
    current = current ? `${current}\n${piece}` : piece;
  }
  if (current) chunks.push(current);
  return chunks;
}

/** One page's chunks, at most `maxChars` of text each, prefixed with where they come from so search can match the place. */
export function chunkPage(page: GuidePage, fetched: FetchedPage, maxChars = 1200): GuideChunk[] {
  const chunks: GuideChunk[] = [];
  for (const section of splitSections(fetched.extract)) {
    const topic = section.path[0]!.toLowerCase();
    if (page.sections ? !page.sections.includes(topic) : SKIPPED_SECTIONS.includes(topic)) continue;
    const text = section.text.join('\n').trim();
    if (text.length < 80) continue; // a heading with a line under it says nothing useful
    const name = section.path.join(' › ');
    const anchor = section.path[0] === 'Overview' ? '' : `#${sectionAnchor(section.path.at(-1)!)}`;
    packParagraphs(text, maxChars).forEach((body, index) => {
      if (body.length < 80) return;
      chunks.push({
        id: createHash('sha256').update(`${fetched.title}|${name}|${index}`).digest('hex').slice(0, 16),
        pageTitle: fetched.title,
        section: name,
        topic,
        countryCode: page.countryCode,
        city: page.city,
        body: `${fetched.title} — ${name}: ${body}`,
        url: `${fetched.url}${anchor}`,
        revisionId: fetched.revisionId,
      });
    });
  }
  return chunks;
}
