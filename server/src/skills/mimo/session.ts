// The mimo skill (design §4.9, §6.4): one pi-agent-core Agent per chat session,
// kept in memory, with the guardrails pi doesn't have built in:
// - at most 4 model turns and 3 tool calls per message (finishTurn, beforeToolCall)
// - a time limit (25–30 s), and abort when the client disconnects
// - thinking events dropped, low retry delays (the request options)
// - the profile and situation sections replaced before each message
// The route holds the per-session lock, so a session never runs twice at once.

import { Agent, type AgentEvent, type AgentTool } from '@earendil-works/pi-agent-core';
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
import { isMimoTool, searchGuidesTool, showPlacesTool, TOOL_LABELS, webSearchTool } from './tools.ts';
import type { GuideSearch } from '../../guides/snowflake.ts';

export const MIMO_LIMITS = {
  maxTurns: 4,
  maxToolCalls: 3,
  maxTokens: 1200,
  /** Sessions idle longer than this are forgotten. */
  idleMs: 6 * 3600_000,
  maxSessions: 500,
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
}

export interface MimoDeps {
  llm: Llm;
  budget: Budget;
  /** Exa search, or null when EXA_API_KEY isn't set (web_search is then not offered). */
  search: WebSearch | null;
  /** The travel guides in Snowflake, or null when SNOWFLAKE_* isn't set (search_guides is then not offered). */
  guides?: GuideSearch | null;
  timeoutMs: number;
  onRunStats?: (stats: MimoRunStats) => void;
}

interface Session {
  agent: Agent;
  modelKey: string;
  lastUsed: number;
  /** The latest message's country, for search_guides. */
  countryCode?: string;
}

type RunState = {
  turns: number;
  /** Names of the tool calls allowed to run. */
  toolCalls: string[];
  toolLimit: boolean;
  turnLimit: boolean;
};

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

  /** The transcript of a session (for tests and debugging). */
  transcript(sessionId: string) {
    return this.sessions.get(sessionId)?.agent.state.messages ?? [];
  }

  /** Throws before any byte is streamed (budget, missing key); otherwise returns the run. */
  async prepare(request: MimoMessageRequest, ctx: MimoContext): Promise<MimoRun> {
    this.deps.budget.assertAvailable();
    const skillModel = await this.deps.llm.forSkill('mimo');
    const session = this.session(ctx.sessionId, skillModel);
    return (sink) => this.run(session, skillModel, request, ctx, sink);
  }

  private session(sessionId: string, skillModel: SkillModel): Session {
    const now = Date.now();
    let session = this.sessions.get(sessionId);
    if (session && session.modelKey !== skillModel.key) session = undefined; // never switch a session's model
    if (!session) {
      const created: Session = { agent: undefined as unknown as Agent, modelKey: skillModel.key, lastUsed: now };
      created.agent = this.createAgent(skillModel, () => created.countryCode);
      session = created;
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

  private createAgent(skillModel: SkillModel, countryCode: () => string | undefined): Agent {
    const tools: AgentTool<any>[] = [showPlacesTool()];
    if (this.deps.guides) tools.push(searchGuidesTool(this.deps.guides, countryCode));
    if (this.deps.search) tools.push(webSearchTool(this.deps.search, this.deps.budget));
    const { llm } = this.deps;
    return new Agent({
      initialState: { systemPrompt: MIMO_SYSTEM, model: skillModel.model, thinkingLevel: 'off', tools },
      streamFn: (model, context, options) => llm.models.streamSimple(model, context, { ...options, ...skillModel.options, maxTokens: outputBudget(MIMO_LIMITS.maxTokens, skillModel.options) }),
      toolExecution: 'sequential',
    });
  }

  /** Replaces the profile/situation/nearby/subject sections of the leading system message. */
  private setSections(agent: Agent, request: MimoMessageRequest): void {
    const messages = agent.state.messages;
    const lead = messages[0] as SystemMessage | undefined;
    if (!lead || lead.role !== 'system') throw new Error('Mimo session has no leading system message.');
    const sections = Object.fromEntries(Object.entries(mimoSections(request)).filter((entry): entry is [string, string] => entry[1] !== null));
    agent.state.messages = [{ ...lead, sections }, ...messages.slice(1)];
  }

  private async run(session: Session, skillModel: SkillModel, request: MimoMessageRequest, ctx: MimoContext, sink: SseSink): Promise<StopReason> {
    const { agent } = session;
    session.countryCode = request.situation.countryCode;
    const started = performance.now();
    const state: RunState = { turns: 0, toolCalls: [], toolLimit: false, turnLimit: false };
    let firstTextMs: number | null = null;
    let costUsd = 0;
    let rejectedEvents = 0;
    let timedOut = false;

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
      const wantsMore = message.content.some((block) => block.type === 'toolCall');
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
      state.toolCalls.push(toolCall.name);
      return undefined;
    };

    const unsubscribe = agent.subscribe((event: AgentEvent) => {
      switch (event.type) {
        case 'message_update': {
          const update = event.assistantMessageEvent;
          // Only answer text is streamed; thinking events are dropped.
          if (update.type === 'text_delta') phrases.push(update.delta);
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
      this.setSections(agent, request);
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
      });
    }
  }
}
