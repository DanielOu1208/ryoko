// Mimo's web search, backed by Exa (design §6.4, decision 44):
// POST https://api.exa.ai/search with the key in `x-api-key`. A few results come
// back as short text for the model, and their titles and URLs become the
// `web_search` tool_end's `details.sources`.

import type { WebSource } from '@ryoko/contracts';

export const EXA_SEARCH_URL = 'https://api.exa.ai/search';

export interface SearchResult {
  title: string;
  url: string;
  text: string;
}

export interface SearchResponse {
  results: SearchResult[];
  /** What Exa says the search cost, in US dollars (0 if it didn't say). */
  costUsd: number;
}

export type WebSearch = (query: string, signal?: AbortSignal) => Promise<SearchResponse>;

interface ExaResult {
  title?: unknown;
  url?: unknown;
  text?: unknown;
  highlights?: unknown;
}

const clip = (text: string, max: number) => (text.length <= max ? text : `${text.slice(0, max - 1).trimEnd()}…`);

export function createExaSearch(apiKey: string, options: { fetch?: typeof fetch; numResults?: number; timeoutMs?: number } = {}): WebSearch {
  const doFetch = options.fetch ?? fetch;
  return async (query, signal) => {
    const timeout = AbortSignal.timeout(options.timeoutMs ?? 8000);
    const response = await doFetch(EXA_SEARCH_URL, {
      method: 'POST',
      headers: { 'x-api-key': apiKey, 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({
        query,
        type: 'auto',
        numResults: options.numResults ?? 4,
        contents: { text: { maxCharacters: 900 } },
      }),
      signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
    });
    if (!response.ok) {
      // The body may echo the request; keep only the status.
      throw new Error(`Exa search failed with HTTP ${response.status}.`);
    }
    const body = (await response.json()) as { results?: ExaResult[]; costDollars?: { total?: unknown } };
    const results: SearchResult[] = [];
    for (const item of body.results ?? []) {
      let parsed: URL;
      try {
        parsed = new URL(typeof item.url === 'string' ? item.url : '');
      } catch {
        continue;
      }
      if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') continue;
      const url = parsed.href;
      const title = typeof item.title === 'string' && item.title.trim() ? item.title.trim() : parsed.hostname;
      const text = typeof item.text === 'string' ? item.text.replace(/\s+/g, ' ').trim() : '';
      results.push({ title: clip(title, 200), url, text });
    }
    const cost = typeof body.costDollars?.total === 'number' ? body.costDollars.total : 0;
    return { results, costUsd: cost };
  };
}

/** The sources for tool_end: title and URL, at most 8 (the contract's limit). */
export function sourcesOf(results: SearchResult[]): WebSource[] {
  return results.slice(0, 8).map((r) => ({ title: r.title, url: r.url }));
}

/** What the model reads: numbered results with a short excerpt each. */
export function resultsForModel(query: string, results: SearchResult[]): string {
  if (results.length === 0) return `No results for "${query}". Say you couldn't find it rather than guessing.`;
  const lines = results.map((r, i) => `${i + 1}. ${r.title} (${new URL(r.url).hostname})\n${clip(r.text, 500) || '(no excerpt)'}`);
  return `Results for "${query}":\n\n${lines.join('\n\n')}\n\nAnswer briefly from these. The app shows the sources, so don't paste URLs.`;
}
