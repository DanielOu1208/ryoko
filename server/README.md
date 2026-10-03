# @ryoko/server

Mimo's server (design §6.4): Hono 4 on `@hono/node-server`, run by Node 24 with native type stripping. It listens on `127.0.0.1:8792` only; Tailscale Funnel `:10000` forwards to it.

## Commands

From the repo root (`pnpm install` first):

```sh
MODEL=faux pnpm --dir server dev     # fixtures, restarts on change (or: pnpm server:faux)
MODEL=faux pnpm --dir server start   # fixtures, no watch
pnpm --dir server test               # node:test suite
pnpm --dir server typecheck
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
| `src/skills/` | The `Skills` interface (`types.ts`), `faux.ts`, and `pending.ts` (non-faux until W7) |

## Request pipeline (`/v1/*`)

bearer auth → client info → rate limit (token buckets, 60/min per install id **and** per IP) → 64 KB body limit → JSON parse + contract check → skill → response contract check.

| Situation | Status | Code |
| --- | --- | --- |
| Missing or wrong token | 401 | `unauthorized` |
| Over the rate limit (`Retry-After` set) | 429 | `rate_limited` |
| Bad JSON, contract miss, bad session id or `X-Install-Id`, unknown route (404), body over 64 KB (413) | 400/404/413 | `invalid_request` |
| A second message while a session's run is going | 409 | `session_busy` |
| A skill returned something off-contract | 502 | `invalid_model_output` |
| `MODEL` isn't `faux` (until W7) | 503 | `model_error` |
| Unexpected exception (logged, not sent) | 500 | `model_error` |

Client IP: the server only accepts loopback connections, so behind Funnel it uses the last `X-Forwarded-For` entry (the one Funnel appends).

## Fixture mode (`MODEL=faux`)

- JSON endpoints return the `contracts/examples/<endpoint>[.<variant>].response.json` whose request has the same local language (`situation.localLanguage`, or `language` for allergy cards): `ja` gives Tokyo, `zh-Hans` Shanghai. Then the same primary language (`zh-Hant` gets `zh-Hans`), then the default pair. New example pairs are picked up automatically. `generatedAt` is set to now.
- `POST /v1/sessions/:id/messages` replays `contracts/examples/mimo.sse.txt`: about 350 ms to the first event, 40 ms per text or phrase, 400 ms before `tool_start`, during the tool, and after `tool_end`. `FAUX_PACE` scales that. The `start` event carries the real session id and a fresh run id, and phrase ids use the run id.
- Every fixture is checked against its schema at startup, so a broken example stops the boot.

## Adding the real skills (W7)

Implement `Skills` from `src/skills/types.ts` in `src/skills/` and return it from `createSkills()` in `src/skills/index.ts` for non-faux models. Routes, validation, the session lock and SSE framing stay as they are:

- JSON skills take the validated request and return the response object. The route checks it against the contract before sending.
- `mimo(request, ctx)` prepares a run (throw an `ApiError` here to answer with a JSON envelope) and returns `async (sink) => stopReason`. The route sends `start` before it and `done` after it. The run sends `text`, `phrase`, `tool_start` and `tool_end` with `sink.send()` (each is checked against the `SseEvent` union), and should stop when `sink.signal` aborts. A throw becomes an `error` event.
