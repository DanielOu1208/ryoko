// Provider-agnostic typed output (design §6.3): the JSON Schema goes in the
// prompt, the server parses the reply, checks it with TypeBox Value.Check and
// the skill's own checks, and asks once more with the problems listed. A second
// miss is 502 invalid_model_output. No provider JSON modes.

import type { AssistantMessage, Context, Message } from '@earendil-works/pi-ai';
import type { Static, TSchema } from 'typebox';
import { Value } from 'typebox/value';
import { ApiError, clampMessage } from '../errors.ts';
import { describeErrors } from '../validate.ts';
import type { Budget } from './budget.ts';
import { costOf, providerErrorText, type Llm } from './registry.ts';
import type { SkillName } from '../config.ts';

/** A skill's verdict on schema-valid output: accept (maybe after dropping bad items), or retry with these problems. */
export type Finalized<R> = { ok: true; value: R; dropped: string[] } | { ok: false; issues: string[] };

/** What happened during one generation, for logs and evals. */
export interface GenerationStats {
  model: string;
  attempts: number;
  latencyMs: number;
  costUsd: number;
  /** Problems with the first reply that triggered the retry. */
  firstIssues: string[];
  /** Items the checks removed from the accepted reply. */
  dropped: string[];
}

export interface TypedRequest<S extends TSchema, R> {
  llm: Llm;
  budget: Budget;
  skill: SkillName;
  /** For messages, e.g. "place card". */
  label: string;
  /** What the model sees as the output shape. Unknown properties are stripped before the check. */
  schema: S;
  system: string;
  user: string;
  maxTokens: number;
  timeoutMs: number;
  /** Shape fixes before the schema check (e.g. a missing nullable field). Must not throw. */
  normalize?: (value: unknown) => unknown;
  /** Semantic checks on schema-valid output. */
  finalize: (output: Static<S>) => Finalized<R>;
  stats?: (stats: GenerationStats) => void;
}

/** The instructions that close every typed prompt. */
export function schemaInstructions(schema: TSchema): string {
  return [
    'Output: one JSON object and nothing else. No Markdown, no code fences, no text before or after it.',
    'It must match this JSON Schema:',
    JSON.stringify(schema),
  ].join('\n');
}

/** The reply's JSON object: tolerates code fences and stray text around one object. */
export function parseJsonObject(text: string): unknown {
  const trimmed = text.trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
  try {
    return JSON.parse(trimmed);
  } catch {
    const start = trimmed.indexOf('{');
    const end = trimmed.lastIndexOf('}');
    if (start === -1 || end <= start) throw new Error('no JSON object in the reply');
    return JSON.parse(trimmed.slice(start, end + 1));
  }
}

export function replyText(message: AssistantMessage): string {
  return message.content.flatMap((block) => (block.type === 'text' ? [block.text] : [])).join('');
}

function schemaIssues(schema: TSchema, value: unknown): string[] {
  return [describeErrors(schema, value, 5)];
}

/** Checks one reply. Returns the accepted value or the problems to send back. */
function check<S extends TSchema, R>(request: TypedRequest<S, R>, message: AssistantMessage): Finalized<R> {
  if (message.stopReason === 'length') return { ok: false, issues: ['The reply was cut off at the token limit. Keep it shorter.'] };
  let parsed: unknown;
  try {
    parsed = parseJsonObject(replyText(message));
  } catch (err) {
    return { ok: false, issues: [`The reply wasn't one valid JSON object (${(err as Error).message}).`] };
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return { ok: false, issues: ['The reply must be a JSON object.'] };
  let value = request.normalize ? request.normalize(parsed) : parsed;
  value = Value.Clean(request.schema, value);
  if (!Value.Check(request.schema, value)) return { ok: false, issues: schemaIssues(request.schema, value) };
  return request.finalize(value as Static<S>);
}

/**
 * Generates typed output. Never sees a client's abort signal: the generation may be
 * shared through the cache, so only its own timeout stops it.
 */
export async function generateTyped<S extends TSchema, R>(request: TypedRequest<S, R>): Promise<R> {
  request.budget.assertAvailable();
  const { model, key, options } = await request.llm.forSkill(request.skill);
  const started = performance.now();
  const timeout = AbortSignal.timeout(request.timeoutMs);
  const messages: Message[] = [{ role: 'user', content: request.user, timestamp: Date.now() }];
  const context: Context = { systemPrompt: `${request.system}\n\n${schemaInstructions(request.schema)}`, messages };
  const stats: GenerationStats = { model: key, attempts: 0, latencyMs: 0, costUsd: 0, firstIssues: [], dropped: [] };
  const report = () => {
    stats.latencyMs = Math.round(performance.now() - started);
    request.stats?.(stats);
  };

  let issues: string[] = [];
  for (let attempt = 1; attempt <= 2; attempt++) {
    stats.attempts = attempt;
    const message = await request.llm.models.completeSimple(model, context, { ...options, maxTokens: request.maxTokens, signal: timeout });
    const cost = costOf(model, message.usage);
    stats.costUsd += cost;
    request.budget.add(cost);

    if (message.stopReason === 'aborted' || (message.stopReason === 'error' && timeout.aborted)) {
      report();
      throw new ApiError('timeout', `The ${request.label} took too long to generate. Try again.`);
    }
    if (message.stopReason === 'error') {
      report();
      throw new ApiError('model_error', clampMessage(`The model couldn't write the ${request.label}: ${providerErrorText(message.errorMessage)}`));
    }

    const result = check(request, message);
    if (result.ok) {
      stats.dropped = result.dropped;
      report();
      return result.value;
    }
    issues = result.issues;
    if (attempt === 1) {
      stats.firstIssues = issues;
      messages.push(message, {
        role: 'user',
        content: `That reply had problems:\n- ${issues.join('\n- ')}\nReply again with only the corrected JSON object.`,
        timestamp: Date.now(),
      });
    }
  }
  report();
  throw new ApiError('invalid_model_output', clampMessage(`The model's ${request.label} didn't pass its checks twice: ${issues.join('; ')}`));
}
