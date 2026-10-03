// The model-backed skills (W7): place-card, discover, allergy-card and mimo on the
// configured models (GMI by default), with the response cache, in-flight
// de-duplication and the daily cost kill switch.

import { join } from 'node:path';
import type { AllergyCardRequest, DiscoverRequest, PlaceCardRequest } from '@ryoko/contracts';
import type { Config } from '../config.ts';
import { cacheKey, ResponseCache, type CacheSource } from '../cache.ts';
import { Budget } from '../llm/budget.ts';
import { createLlm, type Llm } from '../llm/registry.ts';
import { generateTyped, type GenerationStats } from '../llm/typed.ts';
import { ALLERGY_CARD_PROMPT_VERSION, allergyCardModelOutput, allergyCardSystem, allergyCardUser, finalizeAllergyCard } from './allergy-card.ts';
import { languageInfo } from './context.ts';
import { DISCOVER_PROMPT_VERSION, DiscoverModelOutput, discoverSystem, discoverUser, finalizeDiscover, geohash } from './discover.ts';
import { createExaSearch, type WebSearch } from './mimo/exa.ts';
import { MimoSessions, type MimoRunStats } from './mimo/session.ts';
import { finalizePlaceCard, normalizePlaceCard, PLACE_CARD_PROMPT_VERSION, PlaceCardModelOutput, placeCardSystem, placeCardUser } from './place-card.ts';
import type { Skills } from './types.ts';

/** What one JSON skill call did, for logs and evals. */
export interface SkillCallStats {
  skill: 'placeCard' | 'discover' | 'allergyCard';
  source: CacheSource;
  generation?: GenerationStats;
}

export interface ModelSkillsOptions {
  llm?: Llm;
  cache?: ResponseCache;
  budget?: Budget;
  search?: WebSearch | null;
  log?: (line: string) => void;
  onSkillStats?: (stats: SkillCallStats) => void;
  onMimoStats?: (stats: MimoRunStats) => void;
}

export interface ModelSkills extends Skills {
  readonly cache: ResponseCache;
  readonly budget: Budget;
  readonly mimoSessions: MimoSessions;
}

const norm = (text: string) => text.trim().toLowerCase().replace(/\s+/g, ' ');

/** Place id, or the name with coordinates rounded to 4 decimals; the city when there's no place (design §7.4). */
export function placeKey(request: PlaceCardRequest): string {
  const { place } = request.situation;
  if (!place) return `city:${request.situation.countryCode}:${norm(request.situation.city)}:${norm(request.situation.district ?? '')}`;
  return place.id ?? `${norm(place.name)}@${place.coordinate.lat.toFixed(4)},${place.coordinate.lon.toFixed(4)}`;
}

export function createModelSkills(config: Config, options: ModelSkillsOptions = {}): ModelSkills {
  const llm = options.llm ?? createLlm(config);
  const cache = options.cache ?? new ResponseCache({ file: config.cacheDir ? join(config.cacheDir, 'responses.json') : null });
  const budget = options.budget ?? new Budget({ limitUsd: config.dailyBudgetUsd, file: config.cacheDir ? join(config.cacheDir, 'budget.json') : null });
  const exaKey = config.env.EXA_API_KEY?.trim();
  const search = options.search !== undefined ? options.search : exaKey ? createExaSearch(exaKey) : null;
  const log = options.log ?? (config.logRequests ? (line: string) => console.log(line) : () => {});
  const timeoutMs = config.timeouts.skillMs;

  const onMimoStats = (stats: MimoRunStats) => {
    log(`Mimo ${stats.runId}: ${stats.stopReason}, ${stats.turns} turn(s), tools [${stats.toolCalls.join(', ')}], ${stats.phrases.phrases} phrase(s), ${stats.latencyMs} ms, $${stats.costUsd.toFixed(5)}`);
    options.onMimoStats?.(stats);
  };
  const mimoSessions = new MimoSessions({ llm, budget, search, timeoutMs: config.timeouts.mimoMs, onRunStats: onMimoStats });

  /** A cached JSON skill: cache hit, or join the running generation, or generate. */
  async function cached<T>(skill: SkillCallStats['skill'], key: string, generate: (stats: (s: GenerationStats) => void) => Promise<T>): Promise<T> {
    let generation: GenerationStats | undefined;
    const { value, source } = await cache.getOrCreate(key, () => generate((s) => (generation = s)));
    const stats: SkillCallStats = { skill, source, ...(generation ? { generation } : {}) };
    if (generation) {
      const dropped = generation.dropped.length > 0 ? `, dropped ${generation.dropped.length}` : '';
      log(`${skill}: ${generation.model}, ${generation.attempts} attempt(s)${dropped}, ${generation.latencyMs} ms, $${generation.costUsd.toFixed(5)}`);
    }
    options.onSkillStats?.(stats);
    return value;
  }

  return {
    name: `model:${config.model}`,
    cache,
    budget,
    mimoSessions,

    async placeCard(request: PlaceCardRequest) {
      const { key: modelKey } = await llm.forSkill('placeCard');
      const key = cacheKey(['place-card', PLACE_CARD_PROMPT_VERSION, modelKey, placeKey(request), request.situation.hourBucket, request.profile.version, request.situation.localLanguage]);
      return cached('placeCard', key, (stats) =>
        generateTyped({
          llm,
          budget,
          skill: 'placeCard',
          label: 'place card',
          schema: PlaceCardModelOutput,
          system: placeCardSystem(languageInfo(request.situation.localLanguage), languageInfo(request.profile.homeLanguage)),
          user: placeCardUser(request),
          maxTokens: 1200,
          timeoutMs,
          normalize: normalizePlaceCard,
          finalize: (output) => finalizePlaceCard(request, output),
          stats,
        }),
      );
    },

    async discover(request: DiscoverRequest) {
      const { key: modelKey } = await llm.forSkill('discover');
      const { center } = request.area;
      const key = cacheKey([
        'discover',
        DISCOVER_PROMPT_VERSION,
        modelKey,
        geohash(center.lat, center.lon, 6),
        request.area.radiusMeters,
        request.situation.hourBucket,
        request.profile.version,
        request.situation.localLanguage,
      ]);
      return cached('discover', key, (stats) =>
        generateTyped({
          llm,
          budget,
          skill: 'discover',
          label: 'list of places',
          schema: DiscoverModelOutput,
          system: discoverSystem(languageInfo(request.situation.localLanguage), languageInfo(request.profile.homeLanguage)),
          user: discoverUser(request),
          maxTokens: 1500,
          timeoutMs,
          finalize: (output) => finalizeDiscover(request, output),
          stats,
        }),
      );
    },

    async allergyCard(request: AllergyCardRequest) {
      const { key: modelKey } = await llm.forSkill('allergyCard');
      const pairs = request.allergies.map((a) => [norm(a.label), a.severity]);
      const key = cacheKey(['allergy-card', ALLERGY_CARD_PROMPT_VERSION, modelKey, request.language, request.homeLanguage, pairs]);
      return cached('allergyCard', key, (stats) =>
        generateTyped({
          llm,
          budget,
          skill: 'allergyCard',
          label: 'allergy card',
          schema: allergyCardModelOutput(request.allergies.length),
          system: allergyCardSystem(languageInfo(request.language), languageInfo(request.homeLanguage)),
          user: allergyCardUser(request),
          maxTokens: 1200,
          timeoutMs,
          finalize: (output) => finalizeAllergyCard(request, output),
          stats,
        }),
      );
    },

    mimo: (request, ctx) => mimoSessions.prepare(request, ctx),
  };
}
