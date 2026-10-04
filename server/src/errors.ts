// The §7.8 error envelope: every non-2xx JSON response is
// { "error": { "code", "message", "retryable" } }.

import type { Context } from 'hono';
import type { ContentfulStatusCode } from 'hono/utils/http-status';
import type { ErrorBody, ErrorCode, ErrorEnvelope } from '@ryoko/contracts';

/** Default HTTP status and retryability per error code. */
const DEFAULTS: Record<ErrorCode, { status: ContentfulStatusCode; retryable: boolean }> = {
  unauthorized: { status: 401, retryable: false },
  rate_limited: { status: 429, retryable: true },
  session_busy: { status: 409, retryable: true },
  invalid_request: { status: 400, retryable: false },
  invalid_model_output: { status: 502, retryable: true },
  model_error: { status: 502, retryable: true },
  timeout: { status: 504, retryable: true },
  budget_exceeded: { status: 503, retryable: false },
};

const MAX_MESSAGE = 300; // ErrorBody.message maxLength

export interface ApiErrorOptions {
  status?: ContentfulStatusCode;
  retryable?: boolean;
  headers?: Record<string, string>;
  cause?: unknown;
}

/** Throw this anywhere in a route or skill; the app turns it into the envelope (or an SSE `error` event). */
export class ApiError extends Error {
  readonly code: ErrorCode;
  readonly status: ContentfulStatusCode;
  readonly retryable: boolean;
  readonly headers: Record<string, string>;

  constructor(code: ErrorCode, message: string, options: ApiErrorOptions = {}) {
    super(message, { cause: options.cause });
    this.name = 'ApiError';
    this.code = code;
    this.status = options.status ?? DEFAULTS[code].status;
    this.retryable = options.retryable ?? DEFAULTS[code].retryable;
    this.headers = options.headers ?? {};
  }

  toBody(): ErrorBody {
    return { code: this.code, message: clampMessage(this.message), retryable: this.retryable };
  }
}

export function clampMessage(message: string): string {
  const text = message.trim() || 'Something went wrong.';
  return text.length <= MAX_MESSAGE ? text : `${text.slice(0, MAX_MESSAGE - 1)}…`;
}

/**
 * The client went away before the answer (e.g. Translate cancelling a stale
 * request). Nobody reads the response; 499 (nginx's "client closed request")
 * just keeps the access log honest.
 */
export function clientClosed(): ApiError {
  return new ApiError('invalid_request', 'The client closed the request.', { status: 499 as ContentfulStatusCode, retryable: true });
}

/**
 * Any thrown value as an ApiError. Unknown errors become a retryable 500 `model_error`:
 * §7.8 has no generic internal code, and the cause is logged, never sent.
 */
export function toApiError(err: unknown): ApiError {
  if (err instanceof ApiError) return err;
  return new ApiError('model_error', 'Something went wrong on the server. Try again.', { status: 500, retryable: true, cause: err });
}

export function errorResponse(c: Context, err: ApiError): Response {
  const body: ErrorEnvelope = { error: err.toBody() };
  for (const [name, value] of Object.entries(err.headers)) c.header(name, value);
  c.header('Cache-Control', 'no-store');
  return c.json(body, err.status);
}
