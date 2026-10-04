import { Type, type Static } from 'typebox';
import { Strict } from './helpers.ts';
import { Timestamp } from './common.ts';

// Design §6.4 (tier 2). POST /v1/soniox-key, with an empty JSON body.
// The server mints a short-lived, single-use Soniox key for one listening
// session, so the app needn't ship the real key. The value is a secret: never
// log it, on either side.

export const SonioxKeyResponse = Strict({
  apiKey: Type.String({ minLength: 1, maxLength: 512, description: 'Temporary Soniox key for one real-time WebSocket session' }),
  expiresAt: Timestamp,
});
export type SonioxKeyResponse = Static<typeof SonioxKeyResponse>;
