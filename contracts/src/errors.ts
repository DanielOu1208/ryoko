import { Type, type Static } from 'typebox';
import { StringEnum, Strict } from './helpers.ts';

// Design §7.8.

export const ERROR_CODES = [
  'unauthorized',
  'rate_limited',
  'session_busy',
  'invalid_request',
  'invalid_model_output',
  'model_error',
  'timeout',
  'budget_exceeded',
] as const;
export const ErrorCode = StringEnum(ERROR_CODES);
export type ErrorCode = Static<typeof ErrorCode>;

export const ErrorBody = Strict({
  code: ErrorCode,
  message: Type.String({ minLength: 1, maxLength: 300 }),
  retryable: Type.Boolean(),
});
export type ErrorBody = Static<typeof ErrorBody>;

/** Body of every non-2xx JSON response. */
export const ErrorEnvelope = Strict({ error: ErrorBody });
export type ErrorEnvelope = Static<typeof ErrorEnvelope>;
