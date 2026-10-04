// What Mimo is doing now and what it did lately, for the dashboard (/admin).
// The routes open one entry per skill call or Mimo message. A Mimo entry fills in
// as the run goes: its thinking and tool arguments (which the app never sees),
// then the stream the app gets (text, phrases, tools, done). JSON skill calls get
// their cache source and cost through an AsyncLocalStorage set around the call.

import { AsyncLocalStorage } from 'node:async_hooks';
import type { Situation, SseEvent } from '@ryoko/contracts';
import type { SkillName } from '../config.ts';
import type { MimoRunEvent, MimoRunStats } from '../skills/mimo/session.ts';
import type { SkillCallStats } from '../skills/model.ts';

export type ActivityKind = SkillName;

/** Where a request is about, in a few words: the place, else the district and city. */
export function whereTitle(situation: Situation): string {
  const area = situation.district ? `${situation.district}, ${situation.city}` : situation.city;
  return situation.place ? `${situation.place.name}, ${situation.district ?? situation.city}` : area;
}

export interface ActivityStep {
  id: string;
  name: string;
  state: 'running' | 'done' | 'failed';
  /** What the model asked for: the search query, the places it named. */
  input?: string;
  /** What came back. */
  result?: string;
}

export interface Activity {
  id: string;
  kind: ActivityKind;
  /** The message (Mimo), or what the call is about (a place, a phrase). */
  title: string;
  sessionId?: string;
  state: 'running' | 'done' | 'failed';
  /** Mimo, while running: waiting on the model, writing, or in a tool. */
  phase?: 'thinking' | 'writing' | 'tool';
  startedAt: number;
  endedAt?: number;
  model: string;
  /** cache, generated or shared (JSON skills), or the stop reason (Mimo). */
  result?: string;
  error?: string;
  costUsd?: number;
  firstTextMs?: number;
  turns?: number;
  steps: ActivityStep[];
  text: string;
  thinking: string;
  phrases: { local: string; romanization: string | null; gloss: string }[];
}

const KEEP = 40;
const MAX_TEXT = 6000;

/** Keeps the end of a growing text: the live view wants the latest part. */
const append = (text: string, delta: string) => {
  const next = text + delta;
  return next.length > MAX_TEXT ? `…${next.slice(-MAX_TEXT)}` : next;
};
const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`;
const clip = (text: string, max = 160) => (text.length > max ? `${text.slice(0, max - 1)}…` : text);

/** A tool call's arguments in a line: the query, or the places' names. */
function describeArgs(args: unknown): string {
  const a = (args ?? {}) as { query?: unknown; places?: { name?: unknown }[] };
  if (typeof a.query === 'string') return `“${a.query}”`;
  if (Array.isArray(a.places)) return a.places.map((p) => String(p?.name ?? '?')).join(', ');
  return clip(JSON.stringify(args ?? {}));
}

export class ActivityLog {
  /** Newest first. */
  private readonly items: Activity[] = [];
  private readonly current = new AsyncLocalStorage<Activity>();
  private seq = 0;

  list(): readonly Activity[] {
    return this.items;
  }

  open(kind: ActivityKind, title: string, model: string, extra: { id?: string; sessionId?: string } = {}): Activity {
    const item: Activity = {
      id: extra.id ?? `act_${++this.seq}`,
      kind,
      title: clip(title.replace(/\s+/g, ' ').trim(), 300),
      ...(extra.sessionId ? { sessionId: extra.sessionId } : {}),
      state: 'running',
      ...(kind === 'mimo' ? { phase: 'thinking' as const } : {}),
      startedAt: Date.now(),
      model,
      steps: [],
      text: '',
      thinking: '',
      phrases: [],
    };
    this.items.unshift(item);
    // Drop the oldest finished entries; a running one stays until it ends.
    for (let i = this.items.length - 1; i >= 0 && this.items.length > KEEP; i--) {
      if (this.items[i]!.state !== 'running') this.items.splice(i, 1);
    }
    return item;
  }

  /** Ends an entry once; later calls are ignored. */
  close(item: Activity, state: 'done' | 'failed', error?: string): void {
    if (item.state !== 'running') return;
    item.state = state;
    item.endedAt = Date.now();
    delete item.phase;
    if (error) item.error = error;
    for (const step of item.steps) if (step.state === 'running') step.state = 'failed';
  }

  /** Runs one JSON skill call as an entry. */
  async track<T>(kind: ActivityKind, title: string, model: string, work: () => Promise<T>): Promise<T> {
    const item = this.open(kind, title, model);
    try {
      const value = await this.current.run(item, work);
      this.close(item, 'done');
      return value;
    } catch (err) {
      this.close(item, 'failed', (err as Error).message);
      throw err;
    }
  }

  /** A JSON skill's stats, from inside its track() call. */
  skillStats(stats: SkillCallStats): void {
    const item = this.current.getStore();
    if (!item) return;
    item.result = stats.source;
    if (stats.generation) {
      item.model = stats.generation.model;
      item.costUsd = stats.generation.costUsd;
    }
  }

  /** One event of Mimo's stream, as the app gets it. */
  mimoEvent(item: Activity, event: SseEvent): void {
    switch (event.type) {
      case 'text':
        item.text = append(item.text, event.delta);
        item.firstTextMs ??= Date.now() - item.startedAt;
        if (item.state === 'running') item.phase = 'writing';
        break;
      case 'phrase':
        item.phrases.push({ local: event.phrase.local, romanization: event.phrase.romanization, gloss: event.phrase.gloss });
        break;
      case 'tool_start':
        this.step(item, event.id, event.name).state = 'running';
        if (item.state === 'running') item.phase = 'tool';
        break;
      case 'tool_end': {
        const step = this.step(item, event.id, event.name);
        step.state = event.ok ? 'done' : 'failed';
        if (event.ok && event.name === 'show_places') {
          // Only when it differs from what the model asked for (the tool drops places it can't use).
          const shown = event.details.places.map((p) => p.name).join(', ');
          if (shown !== step.input) step.result = `shown: ${shown || 'none'}`;
        }
        if (event.ok && event.name === 'web_search') step.result = `${plural(event.details.sources.length, 'source')}: ${clip(event.details.sources.map((s) => s.title).join(' · '), 240)}`;
        if (item.state === 'running') item.phase = 'thinking';
        break;
      }
      case 'done':
        item.result = event.stopReason;
        this.close(item, 'done');
        break;
      case 'error':
        this.close(item, 'failed', event.message);
        break;
      default:
        break;
    }
  }

  /** Mimo's thinking and tool arguments, which the app never sees. */
  mimoRunEvent(runId: string, event: MimoRunEvent): void {
    const item = this.find(runId);
    if (!item) return;
    if (event.type === 'model') {
      item.model = event.key; // per run: a chat can change model
    } else if (event.type === 'thinking') {
      item.thinking = append(item.thinking, event.delta);
      if (item.state === 'running') item.phase = 'thinking';
    } else {
      this.step(item, event.id, event.name).input = describeArgs(event.args);
    }
  }

  mimoStats(stats: MimoRunStats): void {
    const item = this.find(stats.runId);
    if (!item) return;
    item.model = stats.model;
    item.costUsd = stats.costUsd;
    item.turns = stats.turns;
  }

  private find(id: string): Activity | undefined {
    return this.items.find((item) => item.id === id);
  }

  private step(item: Activity, id: string, name: string): ActivityStep {
    let step = item.steps.find((s) => s.id === id);
    if (!step) {
      step = { id, name, state: 'running' };
      item.steps.push(step);
    }
    return step;
  }
}
