// Snowflake for the travel guides (design §8.4): the SQL API for loading, and
// Cortex Search's REST query for reading. Both authenticate with a programmatic
// access token for the RYOKO_SERVER service user. Never log the token.

import type { WebSource } from '@ryoko/contracts';

export const GUIDE_TABLE = 'GUIDES';
export const GUIDE_SERVICE = 'GUIDE_SEARCH';

export interface SnowflakeConfig {
  /** https://<org>-<account>.snowflakecomputing.com */
  accountUrl: string;
  /** Secret. */
  pat: string;
  role: string;
  warehouse: string;
  database: string;
  schema: string;
}

/** From SNOWFLAKE_* in the environment, or null when the account URL or token is missing. */
export function snowflakeConfigFrom(env: Readonly<Record<string, string | undefined>>): SnowflakeConfig | null {
  const accountUrl = env.SNOWFLAKE_ACCOUNT_URL?.trim().replace(/\/+$/, '');
  const pat = env.SNOWFLAKE_PAT?.trim();
  if (!accountUrl || !pat || !/^https:\/\/[a-z0-9.-]+\.snowflakecomputing\.com$/i.test(accountUrl)) return null;
  return {
    accountUrl,
    pat,
    role: env.SNOWFLAKE_ROLE?.trim() || 'RYOKO_APP',
    warehouse: env.SNOWFLAKE_WAREHOUSE?.trim() || 'RYOKO_WH',
    database: env.SNOWFLAKE_DATABASE?.trim() || 'RYOKO',
    schema: env.SNOWFLAKE_SCHEMA?.trim() || 'GUIDES',
  };
}

function headers(config: SnowflakeConfig): Record<string, string> {
  return {
    Authorization: `Bearer ${config.pat}`,
    'X-Snowflake-Authorization-Token-Type': 'PROGRAMMATIC_ACCESS_TOKEN',
    'Content-Type': 'application/json',
    Accept: 'application/json',
  };
}

export type Binding = { type: 'TEXT' | 'FIXED'; value: string | string[] };

/**
 * Runs one statement through the SQL API and returns its rows. Waits for long
 * statements (the API answers 202 and a handle to poll). Errors keep only
 * Snowflake's message, which never contains the token.
 */
export async function runSql(
  config: SnowflakeConfig,
  statement: string,
  options: { bindings?: Record<string, Binding>; timeoutSeconds?: number; fetch?: typeof fetch } = {},
): Promise<unknown[][]> {
  const doFetch = options.fetch ?? fetch;
  const response = await doFetch(`${config.accountUrl}/api/v2/statements`, {
    method: 'POST',
    headers: headers(config),
    body: JSON.stringify({
      statement,
      timeout: options.timeoutSeconds ?? 120,
      role: config.role,
      warehouse: config.warehouse,
      database: config.database,
      schema: config.schema,
      ...(options.bindings ? { bindings: options.bindings } : {}),
    }),
  });
  let body = (await response.json()) as { data?: unknown[][]; message?: string; statementHandle?: string; statementStatusUrl?: string };
  let status = response.status;
  while (status === 202 && body.statementStatusUrl) {
    await new Promise((resolve) => setTimeout(resolve, 2000));
    const poll = await doFetch(`${config.accountUrl}${body.statementStatusUrl}`, { headers: headers(config) });
    status = poll.status;
    body = (await poll.json()) as typeof body;
  }
  if (status !== 200) throw new Error(`Snowflake answered HTTP ${status}: ${body.message ?? 'no message'}`);
  return body.data ?? [];
}

export interface GuideHit {
  pageTitle: string;
  section: string;
  url: string;
  text: string;
}

export interface GuideFilter {
  /** ISO 3166-1 alpha-2, e.g. JP. */
  countryCode?: string;
}

export type GuideSearch = (query: string, filter: GuideFilter, options?: { limit?: number; signal?: AbortSignal }) => Promise<GuideHit[]>;

/** The text after the "Title — Section: " prefix the loader adds for search. */
function stripPrefix(body: string): string {
  const colon = body.indexOf(': ');
  return colon > 0 && colon < 160 ? body.slice(colon + 2) : body;
}

/**
 * Cortex Search over the guides. Results are cached in memory for an hour (the
 * guides change only when the loader runs). Fails fast: callers treat an error
 * as "no guides" and carry on.
 */
export function createGuideSearch(config: SnowflakeConfig, options: { fetch?: typeof fetch; timeoutMs?: number; service?: string } = {}): GuideSearch {
  const doFetch = options.fetch ?? fetch;
  const service = options.service ?? GUIDE_SERVICE;
  const url = `${config.accountUrl}/api/v2/databases/${config.database}/schemas/${config.schema}/cortex-search-services/${service}:query`;
  const cache = new Map<string, { at: number; hits: GuideHit[] }>();
  const ttlMs = 60 * 60 * 1000;

  return async (query, filter, { limit = 3, signal } = {}) => {
    const key = JSON.stringify([query.trim().toLowerCase().replace(/\s+/g, ' '), filter.countryCode?.toUpperCase() ?? '', limit]);
    const cached = cache.get(key);
    if (cached && Date.now() - cached.at < ttlMs) return cached.hits;

    const timeout = AbortSignal.timeout(options.timeoutMs ?? 3000);
    const response = await doFetch(url, {
      method: 'POST',
      headers: headers(config),
      body: JSON.stringify({
        query,
        columns: ['body', 'page_title', 'section', 'url'],
        limit,
        ...(filter.countryCode ? { filter: { '@eq': { country_code: filter.countryCode.toUpperCase() } } } : {}),
      }),
      signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
    });
    if (!response.ok) throw new Error(`Cortex Search answered HTTP ${response.status}.`);
    const body = (await response.json()) as { results?: Record<string, unknown>[] };
    const hits: GuideHit[] = [];
    for (const row of body.results ?? []) {
      const link = typeof row.url === 'string' ? row.url : '';
      if (!/^https:\/\/[a-z]+\.wikivoyage\.org\//.test(link)) continue;
      hits.push({
        pageTitle: String(row.page_title ?? ''),
        section: String(row.section ?? ''),
        url: link,
        text: stripPrefix(String(row.body ?? '')),
      });
    }
    if (cache.size > 500) cache.delete(cache.keys().next().value!);
    cache.set(key, { at: Date.now(), hits });
    return hits;
  };
}

const clip = (text: string, max: number) => (text.length <= max ? text : `${text.slice(0, max - 1).trimEnd()}…`);

/** A source the app can show and link: "Wikivoyage: Tokyo › Eat". */
export function guideSource(hit: GuideHit): WebSource {
  const where = hit.section && hit.section !== 'Overview' ? `${hit.pageTitle} › ${hit.section.split(' › ')[0]}` : hit.pageTitle;
  return { title: clip(`Wikivoyage: ${where}`, 200), url: hit.url };
}

/** Distinct sources, at most 8 (the contract's limit). */
export function guideSourcesOf(hits: GuideHit[]): WebSource[] {
  const seen = new Set<string>();
  const sources: WebSource[] = [];
  for (const hit of hits) {
    const source = guideSource(hit);
    if (seen.has(source.url)) continue;
    seen.add(source.url);
    sources.push(source);
  }
  return sources.slice(0, 8);
}

/** Numbered excerpts for a prompt, each clipped to `maxChars`. */
export function guidesForModel(hits: GuideHit[], maxChars = 600): { n: number; from: string; text: string }[] {
  return hits.map((hit, index) => ({ n: index + 1, from: guideSource(hit).title, text: clip(hit.text, maxChars) }));
}
