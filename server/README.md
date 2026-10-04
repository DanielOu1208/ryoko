# @ryoko/server

Mimo's server (design §6.4): Hono 4 on `@hono/node-server`, run by Node 24 with native type stripping. It listens on `127.0.0.1:8792` only; Tailscale Funnel `:10000` forwards to it.

## Commands

From the repo root (`pnpm install` first):

```sh
MODEL=faux pnpm --dir server dev     # fixtures, restarts on change (or: pnpm server:faux)
MODEL=faux pnpm --dir server start   # fixtures, no watch
pnpm --dir server start              # the real skills on GMI (MODEL=gmi is the default)
pnpm --dir server test               # node:test suite, offline (pi-ai's faux provider stands in for the model)
pnpm --dir server typecheck
pnpm --dir server evals              # canned situations on the REAL model (a few cents); RUNS=2, ONLY=placeCard,mimo
server/scripts/smoke.sh              # curls every endpoint of a running server; reads the token from server/.env
```

`MODEL` in the environment overrides `server/.env`, so `MODEL=faux` works without editing the file. Config is `server/.env` (copy `.env.example`); the server exits with a clear message if `APP_TOKEN` is missing.

## Layout

| Path | What |
| --- | --- |
| `src/index.ts` | Entry: config, listen on 127.0.0.1, graceful stop |
| `src/app.ts` | `createApp(config)`: middleware, routes, error envelope. No side effects, so tests use `app.request()` |
| `src/config.ts` | `server/.env` + `process.env` (env wins). Never logs secret values |
| `src/errors.ts` | `ApiError` and the §7.8 envelope `{error: {code, message, retryable}}` |
| `src/middleware/` | Bearer auth (constant time), `X-Install-Id` / `X-Client-Version` / client IP, rate limit |
| `src/validate.ts` | Request and response checks against `@ryoko/contracts` (TypeBox `Value.Check`) |
| `src/sse.ts` | `sseResponse()`: §7.7 headers, >512-byte padding, `data:` lines, `: ping` every 15 s, abort on client close |
| `src/sessions.ts` | One Mimo run per session (`409 session_busy`) |
| `src/fixtures.ts` | Loads and checks `contracts/examples` for fixture mode |
| `src/skills/` | The `Skills` interface (`types.ts`), `faux.ts` (fixtures), `model.ts` (the real skills, W7), one file per skill, and `mimo/` |
| `src/skills/context.ts` | Persona, compacted profile, `allowedBasis`, time facts from the situation clock, language and script helpers |
| `src/skills/safety.ts` | The allergen and diet filter (en, zh, ja word lists; safety mentions allowed) |
| `src/skills/romanize.ts` | pinyin-pro (tone sandhi on) for Chinese; the model's romaji for Japanese |
| `src/skills/mimo/` | `session.ts` (Agent per session, guardrails), `phrase-stream.ts` (phrase tags → events), `tools.ts`, `exa.ts`, `prompt.ts` |
| `src/llm/` | `registry.ts` (pi-ai Models, the GMI provider, per-skill models), `typed.ts` (typed output), `budget.ts` (daily kill switch) |
| `src/cache.ts` | Persisted LRU with in-flight de-duplication |
| `src/soniox.ts` | Mints temporary Soniox keys for `POST /v1/soniox-key` |
| `evals/run.ts` | Evals against the real model |

## Request pipeline (`/v1/*`)

bearer auth → client info → rate limit (token buckets, 60/min per install id **and** per IP) → 64 KB body limit → JSON parse + contract check → skill → response contract check.

| Situation | Status | Code |
| --- | --- | --- |
| Missing or wrong token | 401 | `unauthorized` |
| Over the rate limit (`Retry-After` set) | 429 | `rate_limited` |
| Bad JSON, contract miss, bad session id or `X-Install-Id`, unknown route (404), body over 64 KB (413) | 400/404/413 | `invalid_request` |
| A second message while a session's run is going | 409 | `session_busy` |
| A skill returned something off-contract, or the model failed its checks twice | 502 | `invalid_model_output` |
| The provider failed (rate limit, 5xx, bad key) | 502 | `model_error` |
| The model's provider key is missing (e.g. no `GMI_API_KEY`) | 503 | `model_error` (not retryable) |
| A skill ran past its time limit | 504 | `timeout` |
| Today's model spend reached `DAILY_BUDGET_USD` | 503 | `budget_exceeded` |
| Unexpected exception (logged, not sent) | 500 | `model_error` |

Client IP: the server only accepts loopback connections, so behind Funnel it uses the last `X-Forwarded-For` entry (the one Funnel appends).

## Fixture mode (`MODEL=faux`)

- JSON endpoints return the `contracts/examples/<endpoint>[.<variant>].response.json` whose request has the same local language (`situation.localLanguage`, or `language` for allergy cards): `ja` gives Tokyo, `zh-Hans` Shanghai. Then the same primary language (`zh-Hant` gets `zh-Hans`), then the default pair. New example pairs are picked up automatically. `generatedAt` is set to now.
- `POST /v1/sessions/:id/messages` replays `contracts/examples/mimo.sse.txt`: about 350 ms to the first event, 40 ms per text or phrase, 400 ms before `tool_start`, during the tool, and after `tool_end`. `FAUX_PACE` scales that. The `start` event carries the real session id and a fresh run id, and phrase ids use the run id.
- Every fixture is checked against its schema at startup, so a broken example stops the boot.

## The real skills (W7)

`MODEL` (default `gmi`) is the default model as `provider[:modelId]`; `MODEL_PLACE_CARD`, `MODEL_DISCOVER`, `MODEL_ALLERGY_CARD` and `MODEL_MIMO` override it per skill, and `MODEL_<SKILL>_REASONING` sets thinking (`off` by default for GMI). Providers: `gmi` (registered here as an OpenAI-compatible pi-ai provider: reasoning on in the model definition with `thinkingLevelMap.off = 'none'`, requested with thinking off) and `google` (pi-ai's built-in, for the tier 2 Gemini switch; loaded only if a skill names it). A missing provider key answers 503 `model_error`; an unknown provider stops the boot.

**Typed output** (`src/llm/typed.ts`): the JSON Schema goes in the system prompt; the reply is parsed (code fences and stray text tolerated), cleaned of unknown keys, checked with TypeBox `Value.Check`, then by the skill's own checks. Items that fail a check are dropped; if too few are left, the model is asked once more with the problems listed; a second miss is 502 `invalid_model_output`. The assembled response is checked against the contract schema before it's cached or sent. No provider JSON modes.

**place-card**: compacted profile (no version, nulls or empties; no night owl; taste 2 counts as unset; `aboutMe` trimmed and last, which the prompt frames as background, never instructions) plus an explicit `allowedBasis`. Checks: basis only from `allowedBasis`; "because…" at most about 10 words (12 allowed) and no field names; local text in the local script and no Latin letters in Chinese; the allergen/diet filter (safety mentions such as 我对花生过敏 pass); pinyin from pinyin-pro replaces the model's for Chinese. `placeNameLocal` is the device's local name, else the model's when it's in the local script; the model never writes addresses.

**translate** (tier 2, `POST /v1/translate`): typed or edited text in Translate, `{text, from, to, situation?}` → `{translation}`. No tools or persona. The prompt gets the two languages, the place's category (so "less sweet" comes out as 少糖 at a tea shop) and the text, nothing else, because the cache key is (text with whitespace collapsed, from, to, category). Checks: the translation is in the target script and isn't the original handed back; wrapping quotes come off. Unlike the other JSON skills it **stops when its client leaves** (Translate cancels a stale request as you keep typing): `ResponseCache.getOrCreateCancellable` aborts the generation once every caller waiting on it is gone, so a shared generation still survives one client leaving. A cancelled request logs as 499. `MODEL=faux` answers with `translate[.tokyo].response.json` by `to`. Real GMI: cold p50 about 1.6 s, cache hit a few ms.

**soniox-key** (tier 2, `POST /v1/soniox-key`, body `{}`): mints a temporary Soniox key with the server's `SONIOX_API_KEY` (`usage_type: transcribe_websocket`, `expires_in_seconds: 60`, `single_use: true`, `max_session_duration_seconds: 3600`) and returns `{apiKey, expiresAt}` with `Cache-Control: no-store`. It works whatever `MODEL` is, since it isn't a model call. Its own rate limit (`SONIOX_KEYS_PER_MINUTE`, 10 per install and per IP) sits on top of the general one. No `SONIOX_API_KEY` → 503 `model_error` (not retryable), which the app treats as "no key server" and falls back to its bundled key. Soniox errors → 502 `model_error`, with token-like runs masked. Neither key is ever logged.

**discover**: 5–8 places, `why` ≤ 60 characters (the prompt asks for 50), category from the table, `bestTime` ≤ 24; duplicates, wrong-script local names and allergen picks are dropped. **allergy-card**: free-text allergens only, the §4.5 wording per severity, severity taken from the request, `reviewed: false`, pinyin for Chinese.

**mimo** (`src/skills/mimo/`): one pi-agent-core `Agent` per session id, in memory (idle sessions dropped after 6 h). Before each message the leading system message's `profile`, `situation`, `nearby` and `subject` sections are replaced, never appended. The prompt keeps allergies and diet as hard limits applied quietly, mentioned (or turned into an allergy phrase) only when the message is about eating or drinking or the traveller asks; the rest of the profile, `aboutMe` included, shapes answers only where it fits. Guardrails: 4 model turns (`finishTurn` → `turn_limit`), 3 tool calls (`beforeToolCall` blocks the 4th → `tool_limit`), `MIMO_TIMEOUT_MS` (28 s → `timeout` error event), abort on client disconnect (`aborted`), thinking events never streamed, `maxRetries: 1` and `maxRetryDelayMs: 1500`. A failed, timed-out or aborted exchange is removed from the transcript. Tools: `show_places` (sloppy arguments are fixed before validation) and `web_search` (Exa `POST /search`, 4 results; titles and URLs become `details.sources`, short excerpts go to the model; offered only when `EXA_API_KEY` is set). The phrase-tag transformer buffers `<phrase …/>` across deltas, fills pinyin, drops allergen phrases and wrappers like `<phrases>`, caps 4 per reply, flushes a malformed or unterminated tag as text, inserts a blank line between text before and after a tool call, and trims whitespace around phrase blocks. The transcript keeps the raw tags. One log line per run (no content): stop reason, turns, tools, phrases, latency, cost.

**Caching** (`src/cache.ts`): 500 entries, persisted to `server/.cache/responses.json` (gitignored) a second after a change and on exit. Keys: place card (place id, or name + coordinates to 4 decimals, or the city; hour bucket; profile version; prompt version; model; local language), discover (geohash-6, radius, hour bucket, profile version, prompt version, model, language), allergy card (language, home language, label + severity pairs in order, prompt version, model). Concurrent callers share one generation, which never sees a client's abort signal. Errors and invalid output are never stored.

**Budget** (`src/llm/budget.ts`): every response's cost (pi's usage cost, else the model's per-token prices) and each Exa search's `costDollars` go into a ledger at `server/.cache/budget.json`, per local day. At `DAILY_BUDGET_USD` (default 15) model work answers 503 `budget_exceeded`.
