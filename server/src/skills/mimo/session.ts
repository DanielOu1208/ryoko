// The mimo skill (design §4.9, §6.4): one pi-agent-core Agent per chat session,
// kept in memory (and in Tiger when it's set up, design §8.3, so a chat survives
// a restart), with the guardrails pi doesn't have built in:
// - at most 5 model turns and 4 tool calls per message (finishTurn, beforeToolCall);
//   independent tools run in parallel, and past 55% of the time limit no more lookups, so a slow
//   chain of tools answers with what it has instead of timing out
// - an answer that only also called remember ends there, without a second turn
// - a time limit (25–30 s), and abort when the client disconnects
// - thinking events dropped, low retry delays (the request options)
// - the profile and situation sections replaced before each message, with the
//   traveller's trip memory when there is one (time-limited, skipped on failure)
// Each message runs on the model the app picked (or the configured default); a
// chat that changes model keeps its history. The route holds the per-session
// lock, so a session never runs twice at once.

import { Agent, type AgentEvent, type AgentMessage, type AgentTool } from '@earendil-works/pi-agent-core';
import type { AssistantMessage, SystemMessage } from '@earendil-works/pi-ai';
import type { MimoMessageRequest, SseEvent, StopReason } from '@ryoko/contracts';
import { ApiError, clampMessage } from '../../errors.ts';
import type { Budget } from '../../llm/budget.ts';
import { costOf, outputBudget, providerErrorText, type Llm, type SkillModel } from '../../llm/registry.ts';
import type { SseSink } from '../../sse.ts';
import { languageInfo } from '../context.ts';
import type { MimoContext, MimoRun } from '../types.ts';
import type { WebSearch } from './exa.ts';
import { PhraseStream, type PhraseStreamStats } from './phrase-stream.ts';
import { MIMO_SYSTEM, mimoSections } from './prompt.ts';
import { isMimoTool, recallTripTool, rememberTool, searchGuidesTool, showPlacesTool, TOOL_LABELS, webSearchTool, type MemoryContext, type MemoryTools } from './tools.ts';
import type { GuideSearch } from '../../guides/snowflake.ts';
import { tripMemorySection, type Recall, type SavedSession } from '../../memory/index.ts';

export const MIMO_LIMITS = {
  maxTurns: 5,
  /** The prompt asks for at most three; one spare, so a stray remember doesn't cut an answer short. */
  maxToolCalls: 4,
  /**
   * After this share of the time limit a run gets no more lookups (remember still
   * runs) and answers with what it has: about 15 s of the default 28 s, 33 s of the
   * dev server's 60 s with thinking on.
   */
  toolBudgetShare: 0.55,
  maxTokens: 1200,
  /** Sessions idle longer than this are forgotten. */
  idleMs: 6 * 3600_000,
  maxSessions: 500,
  /** How long a message waits for trip memory (an embedding and two queries) before going without. */
  memoryMs: 1500,
  /** How long the first message to a chat the server doesn't hold waits for it to load from Tiger. */
  loadMs: 1500,
} as const;

export interface MimoRunStats {
  sessionId: string;
  runId: string;
  model: string;
  stopReason: StopReason | 'error' | 'timeout';
  turns: number;
  toolCalls: string[];
  latencyMs: number;
  firstTextMs: number | null;
  costUsd: number;
  phrases: PhraseStreamStats;
  /** Events that failed the contract check and weren't sent. */
  rejectedEvents: number;
  /** Trip memory in the prompt: recent and similar events, or null when there was none or it was skipped. */
  memory: { recent: number; similar: number; ms: number } | null;
}

/** What a run does that the app never sees (thinking, tool arguments), for the dashboard. */
export type MimoRunEvent =
  | { type: 'model'; key: string }
  | { type: 'thinking'; delta: string }
  | { type: 'tool_call'; id: string; name: string; args: unknown };

export interface MimoDeps {
  llm: Llm;
  budget: Budget;
  /** Exa search, or null when EXA_API_KEY isn't set (web_search is then not offered). */
  search: WebSearch | null;
  /** The travel guides in Snowflake, or null when SNOWFLAKE_* isn't set (search_guides is then not offered). */
  guides?: GuideSearch | null;
  timeoutMs: number;
  /** The traveller's trip memory (Tiger, design §8.3), or null when it isn't set up. */
  tripMemory?: ({ recall(installId: string, message: string | null, signal?: AbortSignal): Promise<Recall> } & MemoryTools) | null;
  /** Overrides the tool budget (MIMO_LIMITS.toolBudgetShare of timeoutMs). */
  toolBudgetMs?: number;
  /** Where chats are kept across restarts (Tiger), or null to keep them in memory only. */
  sessionStore?: {
    load(sessionId: string, installId: string | null): Promise<SavedSession | null>;
    save(sessionId: string, installId: string | null, session: SavedSession): Promise<void>;
  } | null;
  /** The model for one message: the app's pick (design §4.9). Defaults to the mimo skill's configured model. */
  pickModel?: (request: MimoMessageRequest) => Promise<SkillModel>;
  onRunStats?: (stats: MimoRunStats) => void;
  onRunEvent?: (runId: string, event: MimoRunEvent) => void;
}

interface Session {
  agent: Agent;
  /** The model the next turn runs on. */
  skillModel: SkillModel;
  modelKey: string;
  lastUsed: number;
  /** The latest message's country, for search_guides. */
  countryCode?: string;
  /** The latest message's install id and situation, for remember and recall_trip. */
  memory: MemoryContext;
}

type RunState = {
  turns: number;
  /** Names of the tool calls allowed to run. */
  toolCalls: string[];
  toolLimit: boolean;
  turnLimit: boolean;
};

/** Rejects after `ms`; the work itself carries on and its result is ignored. */
function withTimeout<T>(work: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const limit = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out after ${ms} ms`)), ms);
  });
  return Promise.race([work, limit]).finally(() => clearTimeout(timer));
}

function lastAssistant(messages: readonly unknown[]): AssistantMessage | undefined {
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i] as { role?: string };
    if (message.role === 'assistant') return message as AssistantMessage;
  }
  return undefined;
}

export class MimoSessions {
  private readonly sessions = new Map<string, Session>();
  private readonly deps: MimoDeps;

  constructor(deps: MimoDeps) {
    this.deps = deps;
  }

  get size(): number {
    return this.sessions.size;
  }

  /** Every session, most recently used first (for the dashboard). */
  summaries(): { id: string; model: string; lastUsed: number; messages: number; running: boolean }[] {
    return [...this.sessions]
      .map(([id, session]) => ({
        id,
        model: session.modelKey,
        lastUsed: session.lastUsed,
        messages: session.agent.state.messages.length,
        running: session.agent.state.isStreaming,
      }))
      .reverse();
  }

  /** Forgets every session. A run already going finishes on its own agent; the route's lock still holds it. */
  clear(): void {
    this.sessions.clear();
  }

  /** The transcript of a session (for tests and debugging). */
  transcript(sessionId: string) {
    return this.sessions.get(sessionId)?.agent.state.messages ?? [];
  }

  /** Throws before any byte is streamed (budget, missing key); otherwise returns the run. */
  async prepare(request: MimoMessageRequest, ctx: MimoContext): Promise<MimoRun> {
    this.deps.budget.assertAvailable();
    const skillModel = await (this.deps.pickModel?.(request) ?? this.deps.llm.forSkill('mimo'));
    const saved = this.sessions.has(ctx.sessionId) ? null : await this.load(ctx);
    const session = this.session(ctx.sessionId, skillModel, saved);
    return (sink) => this.run(session, skillModel, request, ctx, sink);
  }

  /** A chat this server doesn't hold (after a restart, or evicted), from Tiger. Slow or failed means a fresh chat. */
  private async load(ctx: MimoContext): Promise<unknown[] | null> {
    const store = this.deps.sessionStore;
    if (!store) return null;
    try {
      const saved = await withTimeout(store.load(ctx.sessionId, ctx.installId), MIMO_LIMITS.loadMs);
      return saved?.messages.length ? saved.messages : null;
    } catch (err) {
      console.error(`Mimo ${ctx.sessionId}: starting fresh, couldn't load the chat from Tiger: ${(err as Error).message}`);
      return null;
    }
  }

  /** Saves the chat after a good run, without the leading system message (rebuilt from the current prompt on load). */
  private save(session: Session, ctx: MimoContext): void {
    const store = this.deps.sessionStore;
    if (!store) return;
    const saved: SavedSession = { modelKey: session.modelKey, messages: session.agent.state.messages.slice(1) };
    store.save(ctx.sessionId, ctx.installId, saved).catch((err: Error) => console.error(`Mimo ${ctx.sessionId}: couldn't save the chat to Tiger: ${err.message}`));
  }

  /** Trip memory for this message, within MIMO_LIMITS.memoryMs. Without an install id there's nothing to look up. */
  private async recall(request: MimoMessageRequest, ctx: MimoContext): Promise<{ section: string | null; stats: MimoRunStats['memory'] }> {
    const trips = this.deps.tripMemory;
    if (!trips || !ctx.installId) return { section: null, stats: null };
    const started = performance.now();
    try {
      const recall = await withTimeout(trips.recall(ctx.installId, request.message, ctx.signal), MIMO_LIMITS.memoryMs);
      const ms = Math.round(performance.now() - started);
      return { section: tripMemorySection(recall, request.situation), stats: { recent: recall.recent.length, similar: recall.similar.length, ms } };
    } catch (err) {
      console.error(`Mimo ${ctx.runId}: answering without trip memory: ${(err as Error).message}`);
      return { section: null, stats: null };
    }
  }

  private session(sessionId: string, skillModel: SkillModel, saved: unknown[] | null = null): Session {
    const now = Date.now();
    let session = this.sessions.get(sessionId);
    if (session && session.modelKey !== skillModel.key) {
      // Another model (or level) picked mid-chat: the next turn runs on it, with
      // the history so far. pi-ai converts the earlier turns for the new provider.
      session.agent.state.model = skillModel.model;
      session.skillModel = skillModel;
      session.modelKey = skillModel.key;
    }
    if (!session) {
      session = this.createSession(skillModel, now, saved);
      this.sessions.set(sessionId, session);
      this.evict(now);
    }
    session.lastUsed = now;
    // Most recently used last.
    this.sessions.delete(sessionId);
    this.sessions.set(sessionId, session);
    return session;
  }

  private evict(now: number): void {
    for (const [id, session] of this.sessions) {
      const tooMany = this.sessions.size > MIMO_LIMITS.maxSessions;
      if (!tooMany && now - session.lastUsed < MIMO_LIMITS.idleMs) continue;
      if (session.agent.state.isStreaming) continue;
      this.sessions.delete(id);
    }
  }

  private createSession(skillModel: SkillModel, now: number, saved: unknown[] | null): Session {
    const tools: AgentTool<any>[] = [showPlacesTool()];
    // The guides search in the country of the session's latest message.
    if (this.deps.guides) tools.push(searchGuidesTool(this.deps.guides, () => session.countryCode));
    if (this.deps.search) tools.push(webSearchTool(this.deps.search, this.deps.budget));
    if (this.deps.tripMemory) {
      tools.push(recallTripTool(this.deps.tripMemory, () => session.memory));
      tools.push(rememberTool(this.deps.tripMemory, () => session.memory));
    }
    const { llm } = this.deps;
    const session: Session = {
      // Reads the session's current model options, so a switch applies to the next turn.
      agent: new Agent({
        // A saved chat has no system message: pi puts the current prompt and tools in front.
        initialState: { systemPrompt: MIMO_SYSTEM, model: skillModel.model, thinkingLevel: 'off', tools, ...(saved ? { messages: saved as AgentMessage[] } : {}) },
        streamFn: (model, context, options) =>
          llm.models.streamSimple(model, context, { ...options, ...session.skillModel.options, maxTokens: outputBudget(MIMO_LIMITS.maxTokens, session.skillModel.options) }),
        // Lookups that don't depend on each other (guides and web) run at once.
        toolExecution: 'parallel',
      }),
      skillModel,
      modelKey: skillModel.key,
      lastUsed: now,
      memory: { installId: null, situation: null },
    };
    return session;
  }

  /** Replaces the profile/situation/nearby/subject sections of the leading system message. */
  private setSections(agent: Agent, request: MimoMessageRequest, tripMemory: string | null): void {
    const messages = agent.state.messages;
    const lead = messages[0] as SystemMessage | undefined;
    if (!lead || lead.role !== 'system') throw new Error('Mimo session has no leading system message.');
    const sections = Object.fromEntries(Object.entries(mimoSections(request, tripMemory)).filter((entry): entry is [string, string] => entry[1] !== null));
    agent.state.messages = [{ ...lead, sections }, ...messages.slice(1)];
  }

  private async run(session: Session, skillModel: SkillModel, request: MimoMessageRequest, ctx: MimoContext, sink: SseSink): Promise<StopReason> {
    const { agent } = session;
    session.countryCode = request.situation.countryCode;
    session.memory = { installId: ctx.installId, situation: request.situation };
    const started = performance.now();
    const toolBudgetMs = this.deps.toolBudgetMs ?? Math.round(this.deps.timeoutMs * MIMO_LIMITS.toolBudgetShare);
    this.deps.onRunEvent?.(ctx.runId, { type: 'model', key: skillModel.key });
    const state: RunState = { turns: 0, toolCalls: [], toolLimit: false, turnLimit: false };
    let firstTextMs: number | null = null;
    let costUsd = 0;
    let rejectedEvents = 0;
    let timedOut = false;
    let memory: MimoRunStats['memory'] = null;

    const send = (event: SseEvent) => {
      try {
        sink.send(event);
      } catch (err) {
        rejectedEvents++;
        console.error(`Mimo ${ctx.runId}: dropped an event that failed the contract check:`, (err as Error).message);
      }
    };
    const language = languageInfo(request.situation.localLanguage);
    const phrases = new PhraseStream({
      language,
      idPrefix: `mimo-${ctx.runId}`,
      onText: (delta) => {
        firstTextMs ??= Math.round(performance.now() - started);
        send({ type: 'text', delta });
      },
      onPhrase: (phrase) => send({ type: 'phrase', phrase }),
    });

    agent.finishTurn = ({ message }) => {
      if (message.stopReason === 'error' || message.stopReason === 'aborted') return;
      state.turns++;
      const calls = message.content.filter((block) => block.type === 'toolCall');
      const answered = message.content.some((block) => block.type === 'text' && block.text.trim().length > 0);
      // An answer that also saved a note is done: no second turn just to say nothing.
      if (calls.length > 0 && answered && calls.every((call) => call.name === 'remember')) return { action: 'end' };
      const wantsMore = calls.length > 0;
      if (wantsMore && state.turns >= MIMO_LIMITS.maxTurns) {
        state.turnLimit = true;
        return { action: 'end' };
      }
      return undefined;
    };
    agent.beforeToolCall = async ({ toolCall }) => {
      if (state.toolCalls.length >= MIMO_LIMITS.maxToolCalls) {
        state.toolLimit = true;
        return { block: true, reason: 'No more tool calls for this message. Answer now with what you have.' };
      }
      if (toolCall.name !== 'remember' && performance.now() - started > toolBudgetMs) {
        state.toolLimit = true;
        return { block: true, reason: 'Out of time to look things up. Answer now with what you have.' };
      }
      state.toolCalls.push(toolCall.name);
      return undefined;
    };

    const unsubscribe = agent.subscribe((event: AgentEvent) => {
      switch (event.type) {
        case 'message_update': {
          const update = event.assistantMessageEvent;
          // Only answer text is streamed; thinking goes to the dashboard alone.
          if (update.type === 'text_delta') phrases.push(update.delta);
          else if (update.type === 'thinking_delta') this.deps.onRunEvent?.(ctx.runId, { type: 'thinking', delta: update.delta });
          break;
        }
        case 'message_end': {
          if (event.message.role !== 'assistant') break;
          const cost = costOf(skillModel.model, (event.message as AssistantMessage).usage);
          costUsd += cost;
          this.deps.budget.add(cost);
          break;
        }
        case 'tool_execution_start':
          this.deps.onRunEvent?.(ctx.runId, { type: 'tool_call', id: event.toolCallId, name: event.toolName, args: event.args });
          phrases.toolBoundary();
          if (isMimoTool(event.toolName)) send({ type: 'tool_start', id: event.toolCallId, name: event.toolName, label: TOOL_LABELS[event.toolName] });
          break;
        case 'tool_execution_end': {
          if (!isMimoTool(event.toolName)) break;
          const ok = !event.isError;
          const details = event.result?.details;
          if (event.toolName === 'show_places') {
            send({ type: 'tool_end', id: event.toolCallId, name: 'show_places', ok, details: { places: ok && details?.places ? details.places : [] } });
          } else {
            send({ type: 'tool_end', id: event.toolCallId, name: event.toolName, ok, details: { sources: ok && details?.sources ? details.sources : [] } });
          }
          break;
        }
        default:
          break;
      }
    });

    const mark = agent.state.messages.length;
    const onClientGone = () => agent.abort();
    sink.signal.addEventListener('abort', onClientGone, { once: true });
    const timer = setTimeout(() => {
      timedOut = true;
      agent.abort();
    }, this.deps.timeoutMs);

    let outcome: StopReason | 'error' | 'timeout' = 'stop';
    try {
      const recalled = await this.recall(request, ctx);
      memory = recalled.stats;
      this.setSections(agent, request, recalled.section);
      if (sink.signal.aborted) {
        outcome = 'aborted';
        return 'aborted';
      }
      await agent.prompt(request.message);
      phrases.end();

      const last = lastAssistant(agent.state.messages.slice(mark));
      if (sink.signal.aborted) outcome = 'aborted';
      else if (timedOut) outcome = 'timeout';
      else if (last?.stopReason === 'error') outcome = 'error';
      else if (last?.stopReason === 'aborted') outcome = 'aborted';
      else if (state.turnLimit) outcome = 'turn_limit';
      else if (state.toolLimit) outcome = 'tool_limit';
      else if (last?.stopReason === 'length') outcome = 'length';
      else outcome = 'stop';

      if (outcome === 'timeout' || outcome === 'error' || outcome === 'aborted') {
        // Keep the transcript clean for the next message: forget this exchange.
        agent.state.messages = agent.state.messages.slice(0, mark);
      } else {
        this.save(session, ctx);
      }
      if (outcome === 'timeout') throw new ApiError('timeout', 'Mimo took too long to answer. Try again.');
      if (outcome === 'error') {
        throw new ApiError('model_error', clampMessage(`Mimo couldn't answer: ${providerErrorText(last?.errorMessage)}`));
      }
      return outcome;
    } catch (err) {
      if (!(err instanceof ApiError)) {
        outcome = 'error';
        if (!agent.state.isStreaming) agent.state.messages = agent.state.messages.slice(0, mark);
      }
      throw err;
    } finally {
      clearTimeout(timer);
      sink.signal.removeEventListener('abort', onClientGone);
      unsubscribe();
      agent.finishTurn = undefined;
      agent.beforeToolCall = undefined;
      session.lastUsed = Date.now();
      this.deps.onRunStats?.({
        sessionId: ctx.sessionId,
        runId: ctx.runId,
        model: skillModel.key,
        stopReason: outcome,
        turns: state.turns,
        toolCalls: state.toolCalls,
        latencyMs: Math.round(performance.now() - started),
        firstTextMs,
        costUsd,
        phrases: phrases.stats,
        rejectedEvents,
        memory,
      });
    }
  }
}
