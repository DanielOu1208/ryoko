// The response cache (design §6.4): an LRU of about 500 entries, persisted to a
// gitignored JSON file so a restart keeps it warm, with in-flight de-duplication.
//
// - Later callers for a key that's being generated wait on the same promise.
// - The generation never sees a client's abort signal, so one client leaving
//   never cancels it for the others (the result still lands in the cache).
// - Errors and invalid output are never cached: a failed generation is dropped,
//   and the next caller starts a fresh one.
// - getOrCreateCancellable (Translate) is the exception to the second rule: its
//   generation stops once every caller waiting on it has left.

import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

interface Entry {
  value: unknown;
  storedAt: number;
}

interface CacheFile {
  version: 1;
  entries: [string, Entry][];
}

export interface CacheOptions {
  /** JSON file to persist to, or null for memory only. */
  file: string | null;
  maxEntries?: number;
  /** Entries older than this are ignored (keys carry the hour bucket, so this is a backstop). */
  ttlMs?: number;
  /** Debounce for writes to the file. */
  writeDelayMs?: number;
  now?: () => number;
}

/** How a value was obtained: generated now, from the cache, or by joining a generation already running. */
export type CacheSource = 'generated' | 'cache' | 'shared';

/** A generation that stops when its last waiter leaves (getOrCreateCancellable). */
interface CancellableRun<T> {
  promise: Promise<T>;
  controller: AbortController;
  waiters: number;
}

/** `promise`, or `signal`'s reason as soon as it aborts. */
function untilAborted<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(signal.reason);
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(signal.reason);
    signal.addEventListener('abort', onAbort, { once: true });
    promise.then(
      (value) => {
        signal.removeEventListener('abort', onAbort);
        resolve(value);
      },
      (err) => {
        signal.removeEventListener('abort', onAbort);
        reject(err);
      },
    );
  });
}

/** A cache key from its parts: sha-256 of their JSON, so keys stay short and opaque. */
export function cacheKey(parts: readonly unknown[]): string {
  return createHash('sha256').update(JSON.stringify(parts), 'utf8').digest('hex');
}

export class ResponseCache {
  private readonly entries = new Map<string, Entry>();
  private readonly inFlight = new Map<string, Promise<unknown>>();
  private readonly cancellable = new Map<string, CancellableRun<unknown>>();
  private readonly file: string | null;
  private readonly maxEntries: number;
  private readonly ttlMs: number;
  private readonly writeDelayMs: number;
  private readonly now: () => number;
  private writeTimer: ReturnType<typeof setTimeout> | undefined;
  private dirty = false;

  constructor(options: CacheOptions) {
    this.file = options.file;
    this.maxEntries = options.maxEntries ?? 500;
    this.ttlMs = options.ttlMs ?? 7 * 24 * 3600_000;
    this.writeDelayMs = options.writeDelayMs ?? 1000;
    this.now = options.now ?? Date.now;
    this.load();
    if (this.file) process.once('exit', () => this.flush());
  }

  get size(): number {
    return this.entries.size;
  }

  /** A copy of the cached value, or undefined. A hit becomes the most recently used. */
  get<T>(key: string): T | undefined {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    if (this.now() - entry.storedAt > this.ttlMs) {
      this.entries.delete(key);
      this.markDirty();
      return undefined;
    }
    this.entries.delete(key);
    this.entries.set(key, entry);
    return structuredClone(entry.value) as T;
  }

  set(key: string, value: unknown): void {
    this.entries.delete(key);
    this.entries.set(key, { value: structuredClone(value), storedAt: this.now() });
    while (this.entries.size > this.maxEntries) {
      const oldest = this.entries.keys().next().value as string;
      this.entries.delete(oldest);
    }
    this.markDirty();
  }

  /**
   * The cached value, or the one being generated, or a new generation. `create`
   * must throw on errors and invalid output, so they're never stored.
   */
  async getOrCreate<T>(key: string, create: () => Promise<T>): Promise<{ value: T; source: CacheSource }> {
    const cached = this.get<T>(key);
    if (cached !== undefined) return { value: cached, source: 'cache' };
    const running = this.inFlight.get(key) as Promise<T> | undefined;
    if (running) return { value: structuredClone(await running), source: 'shared' };

    const generation = (async () => create())();
    this.inFlight.set(key, generation);
    try {
      const value = await generation;
      this.set(key, value);
      return { value: structuredClone(value), source: 'generated' };
    } finally {
      this.inFlight.delete(key);
    }
  }

  /**
   * Like getOrCreate, for work that's worth stopping when nobody wants it any
   * more (Translate's typed text: a stale request is cancelled as you keep
   * typing). The generation gets its own signal, which aborts only when every
   * caller waiting on it has gone, so one client leaving still never cancels a
   * result someone else is waiting for. A caller whose `signal` aborts gets its
   * abort reason thrown at once.
   */
  async getOrCreateCancellable<T>(
    key: string,
    create: (signal: AbortSignal) => Promise<T>,
    signal: AbortSignal,
  ): Promise<{ value: T; source: CacheSource }> {
    const cached = this.get<T>(key);
    if (cached !== undefined) return { value: cached, source: 'cache' };
    if (signal.aborted) throw signal.reason;

    let run = this.cancellable.get(key) as CancellableRun<T> | undefined;
    let source: CacheSource = 'shared';
    if (!run) {
      source = 'generated';
      const controller = new AbortController();
      const promise = (async () => create(controller.signal))();
      const fresh: CancellableRun<T> = { promise, controller, waiters: 0 };
      run = fresh;
      this.cancellable.set(key, fresh);
      // Registered before any waiter's handler, so the value is cached before they return.
      promise.then(
        (value) => {
          if (!controller.signal.aborted) this.set(key, value);
        },
        () => {},
      ).finally(() => {
        if (this.cancellable.get(key) === fresh) this.cancellable.delete(key);
      });
    }

    const current = run;
    current.waiters += 1;
    try {
      const value = await untilAborted(current.promise, signal);
      return { value: structuredClone(value), source };
    } finally {
      current.waiters -= 1;
      if (current.waiters === 0 && signal.aborted) {
        current.controller.abort(signal.reason);
        if (this.cancellable.get(key) === current) this.cancellable.delete(key);
      }
    }
  }

  /** Writes pending changes now. */
  flush(): void {
    clearTimeout(this.writeTimer);
    this.writeTimer = undefined;
    if (!this.file || !this.dirty) return;
    this.dirty = false;
    try {
      mkdirSync(dirname(this.file), { recursive: true });
      const body: CacheFile = { version: 1, entries: [...this.entries] };
      const tmp = `${this.file}.tmp`;
      writeFileSync(tmp, JSON.stringify(body));
      renameSync(tmp, this.file);
    } catch (err) {
      console.error('Cache write failed:', (err as Error).message);
    }
  }

  private markDirty(): void {
    if (!this.file) return;
    this.dirty = true;
    if (this.writeTimer) return;
    this.writeTimer = setTimeout(() => this.flush(), this.writeDelayMs);
    this.writeTimer.unref();
  }

  private load(): void {
    if (!this.file) return;
    let parsed: CacheFile;
    try {
      parsed = JSON.parse(readFileSync(this.file, 'utf8')) as CacheFile;
    } catch {
      return; // no file yet, or unreadable: start cold
    }
    if (parsed?.version !== 1 || !Array.isArray(parsed.entries)) return;
    const now = this.now();
    for (const item of parsed.entries.slice(-this.maxEntries)) {
      if (!Array.isArray(item) || typeof item[0] !== 'string') continue;
      const entry = item[1];
      if (!entry || typeof entry.storedAt !== 'number' || now - entry.storedAt > this.ttlMs) continue;
      this.entries.set(item[0], entry);
    }
  }
}
