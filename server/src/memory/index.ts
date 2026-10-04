// Trip memory and durable Mimo chats on Tiger Data (design §8.3). One pool per
// database URL for the whole process: the dashboard rebuilds the skills when
// settings change, and that must not open a new pool each time.

import { createGeminiEmbed } from './embed.ts';
import { createTigerPool, migrate, SessionStore, tigerConfigFrom, TripMemory } from './tiger.ts';

export { tripMemorySection } from './section.ts';
export type { Recall, RecalledEvent, SavedSession } from './tiger.ts';
export { SessionStore, TripMemory } from './tiger.ts';

export interface Tiger {
  trips: TripMemory;
  sessions: SessionStore;
  /** False when the tables couldn't be set up: every call then fails fast. */
  ready: Promise<boolean>;
}

const shared = new Map<string, Tiger>();

/** Tiger from TIGER_DATABASE_URL (embeddings from GEMINI_API_KEY), or null when it isn't set. */
export function sharedTiger(env: Readonly<Record<string, string | undefined>>, log: (line: string) => void = console.log): Tiger | null {
  const config = tigerConfigFrom(env);
  if (!config) return null;
  const geminiKey = env.GEMINI_API_KEY?.trim() || null;
  const key = `${config.url}|${geminiKey ?? ''}`;
  const existing = shared.get(key);
  if (existing) return existing;

  const pool = createTigerPool(config);
  const started = performance.now();
  const ready = migrate(pool).then(
    () => {
      log(`Tiger: trip memory ready (${Math.round(performance.now() - started)} ms)${geminiKey ? '' : ', without embeddings (no GEMINI_API_KEY)'}`);
      return true;
    },
    (err: Error) => {
      console.error(`Tiger: setup failed, trip memory off: ${err.message}`);
      return false;
    },
  );
  const tiger: Tiger = {
    trips: new TripMemory(pool, geminiKey ? createGeminiEmbed(geminiKey) : null, ready),
    sessions: new SessionStore(pool, ready),
    ready,
  };
  shared.set(key, tiger);
  return tiger;
}
