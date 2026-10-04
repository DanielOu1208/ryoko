// Short-lived Soniox keys for the app (design §6.4, tier 2): POST /v1/soniox-key.
//
// The server holds the real SONIOX_API_KEY and asks Soniox for a temporary key
// that can open one real-time WebSocket session (`single_use`), only within the
// next minute, and for at most an hour of audio. The app asks for one before
// each listening session, so the real key needn't ship in the app.
//
// Neither key is ever logged or put in an error message. Soniox's own error
// text goes through providerErrorText, which masks anything token-like.
//
// Spike D2 confirmed temporary keys work with this account (mint 201, full session).

import type { SonioxKeyResponse } from '@ryoko/contracts';
import type { SonioxKeyConfig } from './config.ts';
import { ApiError, clampMessage, clientClosed } from './errors.ts';
import { providerErrorText } from './llm/registry.ts';

export const SONIOX_TEMPORARY_KEY_URL = 'https://api.soniox.com/v1/auth/temporary-api-key';

/** Mints one temporary key. Throws ApiError. */
export type SonioxMinter = (signal: AbortSignal) => Promise<SonioxKeyResponse>;

export interface SonioxMinterOptions {
  apiKey: string;
  settings: Pick<SonioxKeyConfig, 'expiresInSeconds' | 'maxSessionSeconds'>;
  /** Defaults to the global fetch. Tests inject their own. */
  fetch?: typeof fetch;
  /** How long to wait for Soniox before giving up. */
  timeoutMs?: number;
  now?: () => Date;
}

/** The body Soniox gets. Exported for the tests: it must never carry the key. */
export function temporaryKeyBody(settings: SonioxMinterOptions['settings']): Record<string, unknown> {
  return {
    usage_type: 'transcribe_websocket',
    expires_in_seconds: settings.expiresInSeconds,
    single_use: true,
    max_session_duration_seconds: settings.maxSessionSeconds,
  };
}

function sonioxError(status: number, text: string): ApiError {
  const detail = providerErrorText(text || `HTTP ${status}`);
  if (status === 401 || status === 403) {
    return new ApiError('model_error', clampMessage(`Soniox didn't accept the server's key (${status}): ${detail}`), { status: 502, retryable: false });
  }
  if (status === 402) {
    return new ApiError('model_error', clampMessage(`The Soniox balance is used up: ${detail}`), { status: 502, retryable: false });
  }
  return new ApiError('model_error', clampMessage(`Soniox couldn't make a key (${status}): ${detail}`), { status: 502, retryable: true });
}

/** Soniox's error text, from `{error_message}` or `{message}`, without the rest of the body. */
function errorText(body: unknown): string {
  if (body && typeof body === 'object') {
    const record = body as Record<string, unknown>;
    for (const field of ['error_message', 'message', 'error_type']) {
      if (typeof record[field] === 'string') return record[field];
    }
  }
  return '';
}

export function createSonioxMinter(options: SonioxMinterOptions): SonioxMinter {
  const doFetch = options.fetch ?? fetch;
  const timeoutMs = options.timeoutMs ?? 8000;
  const now = options.now ?? (() => new Date());
  const body = JSON.stringify(temporaryKeyBody(options.settings));

  return async (signal) => {
    const timeout = AbortSignal.timeout(timeoutMs);
    let response: Response;
    try {
      response = await doFetch(SONIOX_TEMPORARY_KEY_URL, {
        method: 'POST',
        headers: { Authorization: `Bearer ${options.apiKey}`, 'Content-Type': 'application/json' },
        body,
        signal: AbortSignal.any([signal, timeout]),
      });
    } catch (err) {
      if (timeout.aborted) throw new ApiError('timeout', 'Soniox took too long to make a key. Try again.');
      if (signal.aborted) throw clientClosed();
      throw new ApiError('model_error', "The server couldn't reach Soniox. Try again.", { status: 502, retryable: true, cause: err });
    }

    let parsed: unknown = null;
    try {
      parsed = await response.json();
    } catch {
      // not JSON: handled below
    }
    if (!response.ok) throw sonioxError(response.status, errorText(parsed));

    const record = (parsed ?? {}) as Record<string, unknown>;
    const apiKey = typeof record.api_key === 'string' ? record.api_key.trim() : '';
    if (!apiKey) throw new ApiError('model_error', 'Soniox answered without a key. Try again.', { status: 502, retryable: true });
    // Normalize the expiry to plain ISO 8601; if it's missing or odd, count from now.
    const stated = typeof record.expires_at === 'string' ? new Date(record.expires_at) : null;
    const expiresAt = stated && !Number.isNaN(stated.getTime()) ? stated : new Date(now().getTime() + options.settings.expiresInSeconds * 1000);
    return { apiKey, expiresAt: expiresAt.toISOString() };
  };
}
