// The one interface every skill set implements. MODEL=faux uses skills/faux.ts;
// W7 adds the model-backed skills in this folder and returns them from createSkills().

import type {
  AllergyCardRequest,
  AllergyCardResponse,
  DiscoverRequest,
  DiscoverResponse,
  MimoMessageRequest,
  MimoModelsResponse,
  PlaceCardRequest,
  PlaceCardResponse,
  StopReason,
  TranslateRequest,
  TranslateResponse,
} from '@ryoko/contracts';
import type { SseSink } from '../sse.ts';

export interface SkillContext {
  /** X-Install-Id, if the client sent one. Memory is keyed by it (after core). */
  installId: string | null;
  clientVersion: string | null;
  /**
   * Aborted when this request's client disconnects. A cached or shared generation
   * must not be cancelled by one client leaving (design §6.4), so JSON skills may ignore it.
   */
  signal: AbortSignal;
}

export interface MimoContext extends SkillContext {
  sessionId: string;
  /** Fresh per message. The route has already sent `start` with it. */
  runId: string;
}

/**
 * Streams one Mimo reply. It sends only content events (text, phrase, tool_start, tool_end)
 * and returns why it stopped; the route sends `start` before it and `done` after it.
 * Throwing ends the stream with an `error` event. Stop promptly when `sink.signal` aborts.
 */
export type MimoRun = (sink: SseSink) => Promise<StopReason>;

export interface Skills {
  /** For logs, e.g. 'faux'. */
  readonly name: string;
  placeCard(request: PlaceCardRequest, ctx: SkillContext): Promise<PlaceCardResponse>;
  discover(request: DiscoverRequest, ctx: SkillContext): Promise<DiscoverResponse>;
  allergyCard(request: AllergyCardRequest, ctx: SkillContext): Promise<AllergyCardResponse>;
  /**
   * Typed or edited text in Translate (tier 2). Unlike the other JSON skills it
   * stops when `ctx.signal` aborts and no other caller is waiting for the same
   * text: Translate cancels a stale request every time you keep typing.
   */
  translate(request: TranslateRequest, ctx: SkillContext): Promise<TranslateResponse>;
  /**
   * Prepares a Mimo run. Throw an ApiError here, before any byte is streamed,
   * to answer with a JSON error envelope instead of a stream.
   */
  mimo(request: MimoMessageRequest, ctx: MimoContext): Promise<MimoRun>;
  /** The models and thinking levels Mimo's picker offers (GET /v1/mimo-models). */
  mimoModels(): Promise<MimoModelsResponse>;
}
