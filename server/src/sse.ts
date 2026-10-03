// SSE per design §7.7, reusable by any streaming skill.
//
// - Headers: text/event-stream, Cache-Control: no-cache, X-Accel-Buffering: no.
// - The first chunk is a comment of more than 512 bytes, enqueued at once so the
//   headers and the padding flush together (URLSession holds back the first bytes).
// - Each event is exactly one `data: {json}` line plus a blank line. No `event:` lines.
// - `: ping` every 15 s.
// - When the client goes away the sink's signal aborts, so the run can stop work.

import type { Context } from 'hono';
import { Value } from 'typebox/value';
import { SseEvent } from '@ryoko/contracts';
import { ApiError, toApiError } from './errors.ts';

export const SSE_HEADERS = {
  'Content-Type': 'text/event-stream; charset=utf-8',
  'Cache-Control': 'no-cache',
  'X-Accel-Buffering': 'no',
} as const;

/** Comfortably over URLSession's 512-byte threshold. */
export const SSE_PADDING_BYTES = 1024;
export const SSE_PING_MS = 15_000;

/** What a streaming skill writes to. */
export interface SseSink {
  /** Writes one event. Returns false once the stream is closed. Throws ApiError if the event breaks the contract. */
  send(event: SseEvent): boolean;
  /** Writes a `: text` comment. Returns false once the stream is closed. */
  comment(text: string): boolean;
  /** Aborted when the client disconnects. Pass it to model calls and timers. */
  readonly signal: AbortSignal;
  readonly closed: boolean;
}

export type SseCloseReason = 'finished' | 'client_closed';

export interface SseOptions {
  pingMs?: number;
  paddingBytes?: number;
  /** Check every event against the SseEvent union before writing it (default true). */
  validate?: boolean;
  /**
   * Called exactly once, when the stream ends for any reason. After a client
   * disconnect the run may still be going, so don't release per-run resources
   * (such as a session lock) here: release them when `run` settles.
   */
  onClose?: (reason: SseCloseReason) => void;
  /** Receives errors thrown by the run (after they've been turned into an `error` event). */
  onError?: (err: unknown) => void;
}

/**
 * Code points JSON.stringify leaves raw that some line readers treat as line
 * breaks: Swift's `AsyncLineSequence` (URLSession `bytes.lines`) splits on NEL,
 * LS and PS, which would cut a `data:` line in pieces and drop the event.
 */
const UNICODE_LINE_BREAKS = /[\u0085\u2028\u2029]/g;

const escapeUnicodeLineBreaks = (json: string): string =>
  json.replace(UNICODE_LINE_BREAKS, (ch) => `\\u${ch.charCodeAt(0).toString(16).padStart(4, '0')}`);

export function formatSseEvent(event: SseEvent): string {
  // Outside strings JSON.stringify emits no whitespace, so these can only sit
  // inside a string, where the \uXXXX escape decodes to the same text.
  return `data: ${escapeUnicodeLineBreaks(JSON.stringify(event))}\n\n`;
}

export function formatSseComment(text: string): string {
  // A comment must stay on one line, for every line reader.
  return `: ${text.replace(/[\r\n\u0085\u2028\u2029]+/g, ' ')}\n\n`;
}

export function paddingComment(bytes = SSE_PADDING_BYTES): string {
  return formatSseComment('.'.repeat(Math.max(bytes, 513)));
}

/**
 * Answers the request with an SSE stream and runs `run` against it.
 * If `run` throws, the error becomes an `error` event (code, message, retryable) and the stream ends.
 *
 * `run` is always called exactly once, even when the client has already gone
 * (its sink is then closed and its signal aborted), so cleanup in `run`'s
 * `finally` always happens. Its promise settling is the only "the run has
 * stopped" signal: the stream can close earlier.
 */
export function sseResponse(c: Context, run: (sink: SseSink) => Promise<void>, options: SseOptions = {}): Response {
  const encoder = new TextEncoder();
  const abort = new AbortController();
  const validate = options.validate ?? true;
  const clientSignal = c.req.raw.signal;
  let controller!: ReadableStreamDefaultController<Uint8Array>;
  let closed = false;
  let ping: ReturnType<typeof setInterval> | undefined;

  const finish = (reason: SseCloseReason) => {
    if (closed) return;
    closed = true;
    clearInterval(ping);
    clientSignal.removeEventListener('abort', onClientAbort);
    if (reason === 'client_closed') {
      abort.abort(new DOMException('The client closed the stream.', 'AbortError'));
    } else {
      try {
        controller.close();
      } catch {
        // already closed or errored
      }
    }
    options.onClose?.(reason);
  };
  const onClientAbort = () => finish('client_closed');

  const write = (text: string): boolean => {
    if (closed) return false;
    try {
      controller.enqueue(encoder.encode(text));
      return true;
    } catch {
      finish('client_closed');
      return false;
    }
  };

  const sink: SseSink = {
    send(event) {
      if (closed) return false;
      if (validate && !Value.Check(SseEvent, event)) {
        const first = Value.Errors(SseEvent, event)[0];
        throw new ApiError('invalid_model_output', `The server produced an invalid stream event${first ? ` (${first.instancePath || '/'} ${first.message})` : ''}.`);
      }
      return write(formatSseEvent(event));
    },
    comment: (text) => write(formatSseComment(text)),
    signal: abort.signal,
    get closed() {
      return closed;
    },
  };

  const stream = new ReadableStream<Uint8Array>({
    start(ctrl) {
      controller = ctrl;
      write(paddingComment(options.paddingBytes));
      ping = setInterval(() => write(formatSseComment('ping')), options.pingMs ?? SSE_PING_MS);
      if (clientSignal.aborted) finish('client_closed');
      else clientSignal.addEventListener('abort', onClientAbort, { once: true });
      // Start the run after start() returns, so the padding is readable first.
      // It starts even if the client is already gone (see above).
      queueMicrotask(() => {
        run(sink)
          .catch((err: unknown) => {
            if (closed) return;
            const apiError = toApiError(err);
            options.onError?.(err);
            write(formatSseEvent({ type: 'error', ...apiError.toBody() }));
          })
          .finally(() => finish('finished'));
      });
    },
    cancel() {
      finish('client_closed');
    },
  });

  return c.body(stream, 200, { ...SSE_HEADERS });
}

/** A sleep that rejects with the signal's reason when it aborts. */
export function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) return Promise.reject(signal.reason);
  if (ms <= 0) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const onAbort = () => {
      clearTimeout(timer);
      reject(signal?.reason);
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}
