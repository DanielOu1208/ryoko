import { Type, type Static } from 'typebox';
import { StringEnum, Strict } from './helpers.ts';
import { CategorySlug } from './common.ts';
import { ErrorCode } from './errors.ts';
import { Phrase } from './phrase.ts';
import { Profile } from './profile.ts';
import { Place, Situation } from './situation.ts';
import { ShownPlace, ToolName, WebSearchDetails } from './tools.ts';

// Design §7.7. POST /v1/sessions/:id/messages, answered with an SSE stream.

export const NearbyPlace = Strict({
  name: Type.String({ minLength: 1, maxLength: 120 }),
  localName: Type.Optional(Type.String({ minLength: 1, maxLength: 120 })),
  category: CategorySlug,
  distanceMeters: Type.Integer({ minimum: 0, maximum: 50000 }),
});
export type NearbyPlace = Static<typeof NearbyPlace>;

export const MimoMessageRequest = Strict({
  clientMessageId: Type.String({ minLength: 1, maxLength: 64 }),
  message: Type.String({ minLength: 1, maxLength: 2000 }),
  profile: Profile,
  situation: Situation,
  nearby: Type.Optional(Type.Array(NearbyPlace, { maxItems: 20 })),
  subjectPlace: Type.Optional(Place),
});
export type MimoMessageRequest = Static<typeof MimoMessageRequest>;

// SSE events. Each is one `data: {json}` line plus a blank line; no `event:` lines.
// Clients ignore event types they don't know.

export const StartEvent = Strict({
  type: StringEnum(['start']),
  sessionId: Type.String({ minLength: 1 }),
  runId: Type.String({ minLength: 1 }),
});
export type StartEvent = Static<typeof StartEvent>;

export const TextEvent = Strict({
  type: StringEnum(['text']),
  delta: Type.String({ minLength: 1 }),
});
export type TextEvent = Static<typeof TextEvent>;

export const PhraseEvent = Strict({
  type: StringEnum(['phrase']),
  phrase: Phrase,
});
export type PhraseEvent = Static<typeof PhraseEvent>;

export const ToolStartEvent = Strict({
  type: StringEnum(['tool_start']),
  id: Type.String({ minLength: 1 }),
  name: ToolName,
  label: Type.String({ minLength: 1, maxLength: 60, description: 'Quiet status line, e.g. "Finding places…"' }),
});
export type ToolStartEvent = Static<typeof ToolStartEvent>;

/** On failure `ok` is false and the list in `details` is empty. */
export const ShowPlacesToolEndEvent = Strict({
  type: StringEnum(['tool_end']),
  id: Type.String({ minLength: 1 }),
  name: StringEnum(['show_places']),
  ok: Type.Boolean(),
  details: Strict({ places: Type.Array(ShownPlace, { maxItems: 5 }) }),
});
export const WebSearchToolEndEvent = Strict({
  type: StringEnum(['tool_end']),
  id: Type.String({ minLength: 1 }),
  name: StringEnum(['web_search']),
  ok: Type.Boolean(),
  details: WebSearchDetails,
});
export const ToolEndEvent = Type.Union([ShowPlacesToolEndEvent, WebSearchToolEndEvent]);
export type ToolEndEvent = Static<typeof ToolEndEvent>;

export const STOP_REASONS = ['stop', 'length', 'turn_limit', 'tool_limit', 'aborted'] as const;
export const StopReason = StringEnum(STOP_REASONS);
export type StopReason = Static<typeof StopReason>;

export const DoneEvent = Strict({
  type: StringEnum(['done']),
  stopReason: StopReason,
});
export type DoneEvent = Static<typeof DoneEvent>;

export const ErrorEvent = Strict({
  type: StringEnum(['error']),
  code: ErrorCode,
  message: Type.String({ minLength: 1, maxLength: 300 }),
  retryable: Type.Boolean(),
});
export type ErrorEvent = Static<typeof ErrorEvent>;

export const SSE_EVENT_TYPES = ['start', 'text', 'phrase', 'tool_start', 'tool_end', 'done', 'error'] as const;
export type SseEventType = (typeof SSE_EVENT_TYPES)[number];

export const SseEvent = Type.Union([
  StartEvent,
  TextEvent,
  PhraseEvent,
  ToolStartEvent,
  ShowPlacesToolEndEvent,
  WebSearchToolEndEvent,
  DoneEvent,
  ErrorEvent,
]);
export type SseEvent = Static<typeof SseEvent>;
