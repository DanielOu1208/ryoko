// Mimo's tools (design §6.4). Mimo names places and the device locates them, so
// show_places carries names and a why, never coordinates. web_search is Exa;
// search_guides is the travel guides in Snowflake Cortex Search (design §8.4).

import type { AgentTool } from '@earendil-works/pi-agent-core';
import { Type } from 'typebox';
import { Strict, type ShowPlacesDetails, type WebSearchDetails } from '@ryoko/contracts';
import { guideSourcesOf, guidesForModel, type GuideSearch } from '../../guides/snowflake.ts';
import type { Budget } from '../../llm/budget.ts';
import { resultsForModel, sourcesOf, type WebSearch } from './exa.ts';

/** The contract's ShowPlacesParams (contracts/src/tools.ts), with descriptions for the model. */
export const ShowPlacesToolParams = Strict({
  places: Type.Array(
    Strict({
      name: Type.String({ minLength: 1, maxLength: 120, description: 'Name as it appears on maps, in English or the common romanized form' }),
      localName: Type.Optional(Type.String({ minLength: 1, maxLength: 120, description: 'Name in local script' })),
      why: Type.String({ minLength: 1, maxLength: 80, description: 'Why it suits the traveller, home language, at most 60 characters' }),
      order: Type.Optional(Type.Integer({ minimum: 1, maximum: 5, description: 'Stop number, only when planning' })),
      when: Type.Optional(Type.String({ pattern: '^([01]\\d|2[0-3]):[0-5]\\d$', description: 'Suggested local start time, HH:mm 24-hour, only when planning' })),
    }),
    { minItems: 1, maxItems: 5 },
  ),
});

export const WebSearchToolParams = Strict({
  query: Type.String({ minLength: 1, maxLength: 200, description: 'What to look up, including the city' }),
});

export const SearchGuidesToolParams = Strict({
  query: Type.String({ minLength: 1, maxLength: 200, description: 'The question in plain English, including the city or country' }),
});

export const TOOL_LABELS = {
  show_places: 'Finding places…',
  web_search: 'Searching the web…',
  search_guides: 'Reading travel guides…',
} as const;
export type MimoToolName = keyof typeof TOOL_LABELS;
export const isMimoTool = (name: string): name is MimoToolName => name in TOOL_LABELS;

const clip = (text: string, max: number) => {
  const trimmed = text.trim();
  if (trimmed.length <= max) return trimmed;
  const cut = trimmed.slice(0, max - 1);
  const space = cut.lastIndexOf(' ');
  return `${(space > max * 0.6 ? cut.slice(0, space) : cut).trimEnd()}…`;
};

/** `9:30` → `09:30`; anything else that isn't HH:mm is dropped. */
function clock(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const match = /^(\d{1,2}):(\d{2})$/.exec(value.trim());
  if (!match) return undefined;
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  if (hour > 23 || minute > 59) return undefined;
  return `${String(hour).padStart(2, '0')}:${match[2]}`;
}

/**
 * Small fixes before validation, so one long why or a sloppy time doesn't cost
 * Mimo a turn: trims, clips why to the contract's 80 characters, keeps 5 places,
 * drops unknown fields and bad order/when values.
 */
export function prepareShowPlaces(args: unknown): unknown {
  const places = (args as { places?: unknown })?.places;
  if (!Array.isArray(places)) return args;
  return {
    places: places.slice(0, 5).map((raw) => {
      const place = (raw ?? {}) as Record<string, unknown>;
      const out: Record<string, unknown> = {
        name: typeof place.name === 'string' ? clip(place.name, 120) : place.name,
        why: typeof place.why === 'string' ? clip(place.why, 80) : place.why,
      };
      if (typeof place.localName === 'string' && place.localName.trim()) out.localName = clip(place.localName, 120);
      const order = Number(place.order);
      if (Number.isInteger(order) && order >= 1 && order <= 5) out.order = order;
      const when = clock(place.when);
      if (when) out.when = when;
      return out;
    }),
  };
}

export function showPlacesTool(): AgentTool<typeof ShowPlacesToolParams, ShowPlacesDetails> {
  return {
    name: 'show_places',
    label: TOOL_LABELS.show_places,
    description:
      'Show specific places to the traveller as cards on the map. Call it once with every place you suggest (or every stop of a plan). The phone finds each place by name, so use real names.',
    parameters: ShowPlacesToolParams,
    prepareArguments: (args) => prepareShowPlaces(args) as never,
    execute: async (_id, params) => {
      const names = params.places.map((p) => p.name).join(', ');
      return {
        content: [{ type: 'text', text: `Shown on the map: ${names}. Now write one or two short sentences without repeating the list.` }],
        details: { places: params.places },
      };
    },
  };
}

export function webSearchTool(search: WebSearch, budget: Budget): AgentTool<typeof WebSearchToolParams, WebSearchDetails> {
  return {
    name: 'web_search',
    label: TOOL_LABELS.web_search,
    description: 'Search the web for current facts: opening hours, events, closures, prices, news. Returns short excerpts; the app shows the sources.',
    parameters: WebSearchToolParams,
    prepareArguments: (args) => {
      const query = (args as { query?: unknown })?.query;
      return (typeof query === 'string' ? { query: clip(query, 200) } : args) as never;
    },
    execute: async (_id, params, signal) => {
      const { results, costUsd } = await search(params.query, signal);
      budget.add(costUsd);
      return {
        content: [{ type: 'text', text: resultsForModel(params.query, results) }],
        details: { sources: sourcesOf(results) },
      };
    },
  };
}

/** What the model reads from the guides: numbered excerpts with where they come from. */
export function guideResultsForModel(query: string, hits: Parameters<typeof guidesForModel>[0]): string {
  if (hits.length === 0) return `The travel guides have nothing on "${query}". Answer from what you know, or use web_search if it's about something current.`;
  const lines = guidesForModel(hits, 700).map((g) => `${g.n}. ${g.from}\n${g.text}`);
  return `From the travel guides for "${query}":\n\n${lines.join('\n\n')}\n\nAnswer briefly in your own words from these. The app shows the sources, so don't paste URLs or name Wikivoyage.`;
}

/**
 * Culture, etiquette and how things work, from the travel guides. `countryCode`
 * reads the current situation's country, so a session that moves city searches
 * the right guides.
 */
export function searchGuidesTool(search: GuideSearch, countryCode: () => string | undefined): AgentTool<typeof SearchGuidesToolParams, WebSearchDetails> {
  return {
    name: 'search_guides',
    label: TOOL_LABELS.search_guides,
    description:
      'Look up customs, etiquette, tipping, paying, what and how to order, local food, and how things work here, in curated travel guides for this country. Returns short excerpts; the app shows the sources.',
    parameters: SearchGuidesToolParams,
    prepareArguments: (args) => {
      const query = (args as { query?: unknown })?.query;
      return (typeof query === 'string' ? { query: clip(query, 200) } : args) as never;
    },
    execute: async (_id, params, signal) => {
      const hits = await search(params.query, { countryCode: countryCode() }, { limit: 3, signal });
      return {
        content: [{ type: 'text', text: guideResultsForModel(params.query, hits) }],
        details: { sources: guideSourcesOf(hits) },
      };
    },
  };
}
