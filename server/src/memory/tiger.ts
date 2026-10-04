// Tiger Data (design §8.3): Tiger Cloud Postgres with TimescaleDB and pgvector.
// - trip_events: a hypertable of what the traveller did (POST /v1/trip-events),
//   each with a Gemini embedding, read back as Mimo's <trip_memory>.
// - mimo_sessions: Mimo chats, pi's messages verbatim in jsonb, so a chat
//   survives a server restart.
// Every call fails fast and callers carry on without memory. Never log the URL.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import type { TripEvent, TripEventKind } from '@ryoko/contracts';
import { EMBEDDING_DIMS, vectorLiteral, type Embed } from './embed.ts';

/** Tiger Cloud's certificates are signed by Timescale's own root (ca.timescale.com, valid to Oct 2027): pin it. */
const CA_FILE = fileURLToPath(new URL('../../certs/timescale-ca.pem', import.meta.url));

export interface TigerConfig {
  /** postgres://… Secret: never log it. */
  url: string;
  ca: string;
}

/** From TIGER_DATABASE_URL, or null when it isn't set. */
export function tigerConfigFrom(env: Readonly<Record<string, string | undefined>>): TigerConfig | null {
  const raw = env.TIGER_DATABASE_URL?.trim();
  if (!raw || !/^postgres(ql)?:\/\//.test(raw)) return null;
  const url = new URL(raw);
  // TLS comes from `ssl` below; pg would read sslmode=require as "verify against the system roots".
  url.searchParams.delete('sslmode');
  return { url: url.toString(), ca: readFileSync(CA_FILE, 'utf8') };
}

export function createTigerPool(config: TigerConfig): pg.Pool {
  const pool = new pg.Pool({
    connectionString: config.url,
    ssl: { ca: config.ca },
    max: 4,
    idleTimeoutMillis: 60_000,
    connectionTimeoutMillis: 5000,
    statement_timeout: 4000,
    query_timeout: 5000,
  });
  // An idle client losing its connection must not crash the server.
  pool.on('error', (err) => console.error('Tiger: idle connection error:', err.message));
  return pool;
}

/** Creates the tables once; safe to run on every start, from more than one server at a time. */
export async function migrate(pool: pg.Pool): Promise<void> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT pg_advisory_xact_lock(hashtext('ryoko-migrate'))");
    await client.query('CREATE EXTENSION IF NOT EXISTS vector');
    await client.query(`
      CREATE TABLE IF NOT EXISTS trip_events (
        time timestamptz NOT NULL,
        install_id text NOT NULL,
        kind text NOT NULL,
        text text NOT NULL,
        meaning text,
        language text,
        place_name text,
        place_local_name text,
        category text,
        city text,
        country_code text,
        local_time text,
        embedding vector(${EMBEDDING_DIMS})
      )`);
    await client.query("SELECT create_hypertable('trip_events', by_range('time', INTERVAL '7 days'), if_not_exists => TRUE)");
    await client.query('CREATE INDEX IF NOT EXISTS trip_events_install_time ON trip_events (install_id, time DESC)');
    await client.query(`
      CREATE TABLE IF NOT EXISTS mimo_sessions (
        id text PRIMARY KEY,
        install_id text,
        model_key text NOT NULL,
        message_count integer NOT NULL,
        messages jsonb NOT NULL,
        updated_at timestamptz NOT NULL DEFAULT now()
      )`);
    await client.query('COMMIT');
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

/** One remembered event, as Mimo's prompt shows it. */
export interface RecalledEvent {
  kind: TripEventKind;
  /** When it happened (UTC). */
  time: Date;
  /** The device's local time then, e.g. 2026-10-05T19:42:00+09:00. */
  localTime: string | null;
  text: string;
  meaning: string | null;
  placeName: string | null;
  category: string | null;
  city: string | null;
  /** Cosine distance to the message, for the similar ones. */
  distance?: number;
}

export interface Recall {
  recent: RecalledEvent[];
  /** Older events close to the message, not already in `recent`. */
  similar: RecalledEvent[];
}

export const RECALL = {
  recent: 6,
  similar: 4,
  /** Cosine distance: related events measured 0.33–0.39, unrelated 0.45+. */
  maxDistance: 0.4,
  /** Only this trip: events older than this are forgotten. */
  days: 30,
  /** The same event again within this window is a repeat, not a new memory. */
  repeatMinutes: 10,
} as const;

/** The text an event is embedded as: kind, place and both sides, so a question in either language finds it. */
export function embeddingText(event: TripEvent): string {
  const place = event.place ? `${event.place.name}${event.place.category ? ` (${event.place.category})` : ''}` : null;
  const city = event.city ? `, ${event.city}` : '';
  if (event.kind === 'place_confirmed') return `Was at ${place ?? event.text}${city}`;
  const where = place ? ` at ${place}${city}` : event.city ? ` in ${event.city}` : '';
  const lead: Record<Exclude<TripEventKind, 'place_confirmed'>, string> = {
    phrase_shown: 'Showed a phrase',
    phrase_spoken: 'Said a phrase',
    typed_translation: 'Typed in Translate',
  };
  return `${lead[event.kind]}${where}: ${event.meaning ? `${event.text} = ${event.meaning}` : event.text}`;
}

/** When it happened: the device's time, unless it's unreadable or in the future (a wrong clock). */
function eventTime(at: string, now: number): Date {
  const parsed = Date.parse(at);
  return Number.isNaN(parsed) || parsed > now + 5 * 60_000 ? new Date(now) : new Date(parsed);
}

type Row = {
  kind: TripEventKind;
  time: Date;
  local_time: string | null;
  text: string;
  meaning: string | null;
  place_name: string | null;
  category: string | null;
  city: string | null;
  distance?: number;
};

const recalled = (row: Row): RecalledEvent => ({
  kind: row.kind,
  time: row.time,
  localTime: row.local_time,
  text: row.text,
  meaning: row.meaning,
  placeName: row.place_name,
  category: row.category,
  city: row.city,
  ...(row.distance !== undefined ? { distance: Number(row.distance) } : {}),
});

const COLUMNS = 'kind, time, local_time, text, meaning, place_name, category, city';

/** Waits for the tables; throws when they couldn't be set up, so callers skip memory. */
async function whenReady(ready: Promise<boolean>): Promise<void> {
  if (!(await ready)) throw new Error('Tiger is unavailable.');
}

export class TripMemory {
  private readonly pool: pg.Pool;
  private readonly embed: Embed | null;
  private readonly ready: Promise<boolean>;

  constructor(pool: pg.Pool, embed: Embed | null, ready: Promise<boolean> = Promise.resolve(true)) {
    this.pool = pool;
    this.embed = embed;
    this.ready = ready;
  }

  /** Stores a batch, skipping repeats. Without embeddings (no key, or Gemini failed) events are still kept for "recent". */
  async store(installId: string, events: readonly TripEvent[], now = Date.now()): Promise<number> {
    await whenReady(this.ready);
    const seen = new Set<string>();
    const unique = events.filter((event) => {
      const key = JSON.stringify([event.kind, event.text, event.place?.name ?? null]);
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
    let vectors: (number[] | null)[] = unique.map(() => null);
    if (this.embed) {
      try {
        vectors = await this.embed(unique.map(embeddingText), 'RETRIEVAL_DOCUMENT');
      } catch (err) {
        console.error(`Tiger: storing ${unique.length} event(s) without embeddings:`, (err as Error).message);
      }
    }
    const rows = unique.map((event, i) => ({
      time: eventTime(event.at, now).toISOString(),
      kind: event.kind,
      text: event.text,
      meaning: event.meaning ?? null,
      language: event.language ?? null,
      place_name: event.place?.name ?? null,
      place_local_name: event.place?.localName ?? null,
      category: event.place?.category ?? null,
      city: event.city ?? null,
      country_code: event.countryCode ?? null,
      local_time: event.at,
      embedding: vectors[i] ? vectorLiteral(vectors[i]) : null,
    }));
    const result = await this.pool.query(
      `INSERT INTO trip_events (time, install_id, kind, text, meaning, language, place_name, place_local_name, category, city, country_code, local_time, embedding)
       SELECT e."time", $1, e.kind, e."text", e.meaning, e.language, e.place_name, e.place_local_name, e.category, e.city, e.country_code, e.local_time, e.embedding::vector
       FROM jsonb_to_recordset($2::jsonb) AS e("time" timestamptz, kind text, "text" text, meaning text, language text, place_name text,
            place_local_name text, category text, city text, country_code text, local_time text, embedding text)
       WHERE NOT EXISTS (
         SELECT 1 FROM trip_events t
         WHERE t.install_id = $1 AND t.kind = e.kind AND t."text" = e."text" AND t.place_name IS NOT DISTINCT FROM e.place_name
           AND t."time" BETWEEN e."time" - make_interval(mins => $3) AND e."time" + make_interval(mins => $3)
       )`,
      [installId, JSON.stringify(rows), RECALL.repeatMinutes],
    );
    return result.rowCount ?? 0;
  }

  /**
   * The latest events and, when there's a message, the older ones most like it.
   * The query embedding and the recent rows are fetched at the same time.
   */
  async recall(installId: string, message: string | null, signal?: AbortSignal): Promise<Recall> {
    await whenReady(this.ready);
    const recentQuery = this.pool.query<Row>(
      `SELECT ${COLUMNS} FROM trip_events
       WHERE install_id = $1 AND time > now() - make_interval(days => $2)
       ORDER BY time DESC LIMIT $3`,
      [installId, RECALL.days, RECALL.recent],
    );
    const queryVector = message && this.embed ? this.embed([message], 'RETRIEVAL_QUERY', signal).then((v) => v[0] ?? null) : Promise.resolve(null);
    const [recentResult, vector] = await Promise.all([recentQuery, queryVector.catch(() => null)]);
    const recent = recentResult.rows.map(recalled);
    if (!vector) return { recent, similar: [] };

    const similarResult = await this.pool.query<Row>(
      `SELECT ${COLUMNS}, embedding <=> $2::vector AS distance FROM trip_events
       WHERE install_id = $1 AND embedding IS NOT NULL AND time > now() - make_interval(days => $3)
       ORDER BY embedding <=> $2::vector LIMIT $4`,
      [installId, vectorLiteral(vector), RECALL.days, RECALL.recent + RECALL.similar],
    );
    const inRecent = new Set(recentResult.rows.map((row) => `${row.time.getTime()}|${row.kind}|${row.text}`));
    const similar = similarResult.rows
      .filter((row) => Number(row.distance) <= RECALL.maxDistance && !inRecent.has(`${row.time.getTime()}|${row.kind}|${row.text}`))
      .slice(0, RECALL.similar)
      .map(recalled);
    return { recent, similar };
  }
}

/** A saved chat: its model and pi's messages after the leading system message. */
export interface SavedSession {
  modelKey: string;
  messages: unknown[];
}

/** Mimo chats in Postgres. A chat is only ever read back by the install that wrote it. */
export class SessionStore {
  private readonly pool: pg.Pool;
  private readonly ready: Promise<boolean>;

  constructor(pool: pg.Pool, ready: Promise<boolean> = Promise.resolve(true)) {
    this.pool = pool;
    this.ready = ready;
  }

  async load(sessionId: string, installId: string | null): Promise<SavedSession | null> {
    await whenReady(this.ready);
    const result = await this.pool.query<{ model_key: string; messages: unknown[] }>(
      `SELECT model_key, messages FROM mimo_sessions
       WHERE id = $1 AND install_id IS NOT DISTINCT FROM $2 AND updated_at > now() - interval '7 days'`,
      [sessionId, installId],
    );
    const row = result.rows[0];
    return row && Array.isArray(row.messages) ? { modelKey: row.model_key, messages: row.messages } : null;
  }

  /** Upserts; a slower, older save never overwrites a newer one (transcripts only grow). */
  async save(sessionId: string, installId: string | null, session: SavedSession): Promise<void> {
    // Serialized now: the next message may change the transcript while this waits.
    const messages = JSON.stringify(session.messages);
    await whenReady(this.ready);
    await this.pool.query(
      `INSERT INTO mimo_sessions (id, install_id, model_key, message_count, messages, updated_at)
       VALUES ($1, $2, $3, $4, $5::jsonb, now())
       ON CONFLICT (id) DO UPDATE SET model_key = EXCLUDED.model_key, message_count = EXCLUDED.message_count,
         messages = EXCLUDED.messages, updated_at = now()
       WHERE mimo_sessions.message_count <= EXCLUDED.message_count AND mimo_sessions.install_id IS NOT DISTINCT FROM EXCLUDED.install_id`,
      [sessionId, installId, session.modelKey, session.messages.length, messages],
    );
  }
}
