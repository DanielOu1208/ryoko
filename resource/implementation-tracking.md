# Ryoko: implementation tracking

A living tracker for the build. **Update it as you work.** When you start a task, mark it in progress and fill in Owner and Branch/PR. When you finish, mark it done and add a one-line note: what landed, and anything the next person needs to know.

- The spec is [`design.md`](design.md); § numbers below refer to it.
- If the build forces a change to the spec, update `design.md` and add a row to the change log at the bottom.

**Status:** `todo` · `doing` · `blocked` · `review` · `done` · `cut`

**Owner:** a person or agent label, e.g. `daniel`, `agent:map`.

## Snapshot

| Area | Status | Notes |
| --- | --- | --- |
| Setup (§12.2) | doing | S1, S2, S3, S5 done; S4 waiting on keys |
| Device spikes (§11) | doing | D1, D3, D4 done (D1/D4 from the Mac); D2 waiting on Soniox key |
| Tier 1: working core | doing | W1 and W2 built; verify and review running (workflow) |
| Tier 2 | todo | |
| After core | todo | |
| Submission | todo | |

## 0. Setup before agents fan out (§12.2)

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| S1 | Root `.gitignore`, `server/.env.example`, `Secrets.example.xcconfig` | lead | done |  | `.gitignore`, `server/.env.example`; local `server/.env` has a random `APP_TOKEN` |
| S2 | Xcode project in the GUI: Ryoko app, RyokoLiveActivity extension, synced folders, `Shared/` in both targets, team, iOS 26.1, iPhone and portrait only, Info.plist keys, xcconfigs. Builds on simulator and phone | agent:xcode | done |  | Generated from the CLI: synced folders (`Ryoko/`, `Shared/` in both targets, `RyokoLiveActivity/`), xcconfigs, shared scheme. Simulator build OK, launches with the 5-tab Liquid Glass bar; signed generic-device build OK. Still to do: run it on the physical phone; add Assets.xcassets (app icon) later |
| S3 | `AGENTS.md` (+ `CLAUDE.md` → `AGENTS.md`): ownership, build command, Swift rules, networking, key rules | lead | done |  | `AGENTS.md` and `CLAUDE.md` (imports AGENTS.md) |
| S4 | Keys in place: `server/.env` (GMI key + model id, Tavily key, `APP_TOKEN`), `Secrets.xcconfig` (Soniox key, app token, base URL) | daniel | blocked |  | GMI key and `GMI_MODEL` are in `server/.env`. Still needed: SONIOX_API_KEY (server/.env + Secrets.xcconfig), TAVILY_API_KEY |
| S5 | Tailscale Funnel `:10000` → `127.0.0.1:8792` (`:443`/`:8443` belong to other services), reachable from the phone over cellular | agent:sse | done |  | `:10000` Funnel → `127.0.0.1:8792` (8790/8791 are taken by aerivoiceweb `wrangler dev`); `:443`/`:8443` untouched. Phone check over cellular still to do |

## 1. Device spikes (§11)

Write down what you find. The results may change the spec.

| # | Question | Owner | Status | Result |
| --- | --- | --- | --- | --- |
| D1 | MapKit from Canada: Shanghai and Tokyo search, POIs, reverse geocoding in `zh_Hans_CN` / `ja_JP`, time zones, `.restroom` coverage. Simulator first (Jing'an `.gpx`), then the phone | agent:mapkit | done (desk) | MapKit works from a plain CLI on the Mac. **Shanghai:** 26 POIs at 300 m, all `Asia/Shanghai`; reverse geocoding with `zh_Hans_CN` gives Chinese, but only to road level; restrooms sparse (0 at 300 m, 2 at 1.5 km); **Heytea Jing'an isn't in Apple's data**; `.default` priority leaks to Canadian results. **Tokyo:** 49 POIs, full `ja_JP` addresses, plenty of restrooms. **Names follow the app's language, not `preferredLocale`** (an English UI gives romanized or English names, and the language is fixed per process), so local names come from `placeNameLocal`. `timeZone` and `identifier` are always present. Phone check still to do: English iPhone on venue Wi-Fi, Heytea on iOS, restroom layer, `.required` from Vancouver. Code: `spikes/mapkit/` **Follow-up:** **Taipei** has rich data: 50嵐 9 hits, CoCo, 春水堂; house-number addresses in `zh_Hant_TW`; Traditional names under a zh-Hant UI; restrooms 38–50. It's the best Mandarin stand-in. **Hong Kong** has Heytea and rich data, but is Cantonese and matches short brand queries loosely. About 40% of TW/HK POIs have no identifier. |
| D2 | Soniox zh⇄en and ja⇄en: accuracy, script, latency, false language switches in a noisy hall. Tune the turn rule (§4.8) |  | blocked | Needs SONIOX_API_KEY in `server/.env` |
| D3 | GMI: place-card latency (target < 3 s), and how reliably the model calls `show_places` / `web_search` | agent:gmi | done | **`deepseek-ai/DeepSeek-V4.1-Flash`, thinking off** (fallback `Qwen/Qwen3.8-Flash`). Place card p50 2.9 s / max 3.7 s; JSON 100% valid; show_places 10/10 in 2 turns; Mimo turn p50 4.4 s; phrase tags 5/5. Qwen and GLM are 2–3× slower. `json_object` mode works but doesn't help. Provider snippet and prompt rules are in design §6.2–6.4. Code: `spikes/gmi/src/` |
| D4 | SSE through Funnel: no buffering? Round-trip time on venue Wi-Fi and on cellular | agent:sse | done (desk) | Public Funnel path exercised (relay IPs, `Tailscale-Funnel-Request` header). **No buffering**: events arrive ~300 ms apart; lag 58–162 ms on average, max 497 ms; first byte 0.4–1.5 s (mostly TLS). /healthz RTT p50 ~0.5 s (reused connection) / ~0.8 s (new connection) on jittery Wi-Fi. Keep the 512-byte padding for URLSession. Phone check: URLSession `bytes(for:)` on `/sse` over cellular. Code: `spikes/sse/` |

## 2. Tier 1: working core (§2, §12.3)

### W1. Contracts and fixture server

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W1.1 | TypeBox schemas + emitted JSON Schema for §7.1–7.8 | wf:contracts | done |  | `@ryoko/contracts`: TypeBox 1.3.27, local StringEnum, `additionalProperties:false`; 21 JSON Schema files via `pnpm contracts:emit` |
| W1.2 | Example request and response JSON per endpoint, plus `mimo.sse.txt` | wf:contracts | done |  | Hand-written examples (fictional Shanghai café, Tokyo ramen ticket-machine shop), `profile.seed.json`, `mimo.sse.txt`; 25 tests pass (`pnpm contracts:test`) |
| W1.3 | `LangCode` table, category table (display names, SF Symbols, starters), allergy templates (zh-Hans, ja × chip allergens × 3 severities) | wf:contracts | review |  | Tables done (langcodes incl. best-effort zh-Hant, 14 categories, allergy templates). **Allergy and taxi text has had no native review (`reviewed:false`)**: needs a Chinese reader and a Japanese reader |
| W1.4 | Hono skeleton: `/healthz`, bearer auth, error envelope, rate limit, body limit, SSE helper (512-byte padding, pings) | wf:server | done |  | Hono 4.13 on Node 24 type stripping. Bearer auth (constant time), install-id/IP rate limit, 64 KB limit, schema validation in and out, §7.8 errors everywhere, SSE helper (padding, pings, abort on close), per-session busy lock. 32 tests pass (`pnpm --filter ./server test`) |
| W1.5 | `MODEL=faux` fixture mode serving the examples, including a scripted Mimo stream | wf:server | done |  | `MODEL=faux` serves the examples by `localLanguage` and replays `mimo.sse.txt` with realistic pacing. Follow-up: add a Tokyo discover example, a zh-Hans allergy card and a zh-Hans Mimo transcript (W1.6) |
| W1.6 | Fixture gaps: `discover.tokyo.*`, zh-Hans `allergy-card.*`, zh-Hans `mimo.*.sse.txt` (+ server picks the transcript by language) | | todo | | Without these, faux Tokyo previews show Shanghai picks and faux Shanghai chat shows Japanese phrases |

### W2. App shell and shared pieces

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W2.1 | `TabView` (Now, Map, Translate, Mimo, Me), theme tokens, time-of-day `LinearGradient` | wf:ios-shell | done |  | Native 5-tab `TabView`, theme tokens, `TimeOfDayGradient` using the §9.3 hex values (light and dark) in the situation's time zone |
| W2.2 | Codable `Situation`, `Profile`, `Phrase` mirroring `contracts/` | wf:ios-core | done |  | Codable mirrors of every §7 shape in `ios/Shared/Contracts/` (nonisolated, Sendable, Foundation only). Values the server sends tolerate unknown cases; `MimoEvent.unknown` |
| W2.3 | `SituationStore`: live (nearest 3 + confirm) and preview (place + date-time); local-language derivation | wf:ios-shell | done |  | Real `SituationStore`: live (nearest 3 within 150 m + confirm, `placemarkNotFound` means no results), preview, local language derived on device, contract `Situation` with an offset `localTime`. DEBUG sample-place launch hooks |
| W2.4 | `ProfileStore` with the bundled seed profile (§10) and content-hash version | wf:ios-shell | done |  | `ProfileStore`: seed profile, persisted edits, sha-256 canonical `version`, reset. Me: read-only profile, romanization toggle, developer section (fixtures or live server, base URL). Now wired to the place card (redacted, error, retry); verified against the faux server |
| W2.5 | `RyokoAPI` client + SSE line reader; base-URL override; fixture implementation | wf:ios-core | done |  | `RyokoAPI` protocol, `LiveRyokoAPI` (headers, install id, base-URL override, SSE line reader), `FixtureRyokoAPI` with bundled examples. `ios/scripts/check-contracts.sh --live`: 173 pass against the faux server, Mimo stream parsed end to end |
| W2.6 | `PlaceResolver`, `SpeechService` protocols with fixtures; `LocalText`; stubs for `PhraseCardView`, `TipRow`, `ShowContent`; preview gallery | wf:ios-core | done |  | `PlaceResolver`, `SpeechService`, `SituationStore` protocols with fixtures; `LocalText`, `PhraseCardView`, `TipRow`, `ShowContent`; `FixtureSelfCheck` (DEBUG); `ios/scripts/sync-fixtures.sh` |

### W3. Now and cards

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W3.1 | Now: header, phrase cards with "because…", tips, quick cards, mini map | | todo | | |
| W3.2 | Now: Mimo picks nearby row (from `discover`, background prefetch) | | todo | | |
| W3.3 | Now special cases: no place, local language = home language, loading/error/offline | | todo | | |
| W3.4 | Show mode (`ShowContent` .phrase / .allergy / .taxi): max brightness, idle timer, Flip, Done | | todo | | |
| W3.5 | Allergy card: templates offline + `/v1/allergy-card` for free text ("not reviewed") | | todo | | |
| W3.6 | Taxi card: `MKReverseGeocodingRequest` in the local locale, local name, fixed phrase, snapshot | | todo | | |

### W4. Map

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W4.1 | Map with `.searchable` + `MKLocalSearchCompleter`; POI tap (`MapSelection`) and long-press | | todo | | |
| W4.2 | Place sheet: phrase cards, tips, Preview with date-time picker + chips, Taxi card, Ask Mimo about this place | | todo | | |
| W4.3 | Layers: Food & drink and Washrooms (MapStyle filters), Hidden gems, From Mimo (numbered for plans) | | todo | | |
| W4.4 | `PlaceResolver`: name → MKMapItem, local name first in China, 5 km cap, cache, throttle-safe | | todo | | |

### W5. Translate

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W5.1 | Soniox WebSocket client (`stt-rt-v5`, `two_way`, language ID, endpoints), 16 kHz mono PCM capture (nonisolated tap) | | todo | | |
| W5.2 | Turn model + rule (§4.8), History sheet, 2-minute silence stop | | todo | | |
| W5.3 | Pair from situation (manual pick, fixed mid-session) | | todo | | |
| W5.4 | Upright + face-to-face layouts, CoreMotion tilt with hysteresis, manual toggle, haptics | | todo | | Tilt can only be tested on a device |

### W6. Mimo tab

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W6.1 | Chat over SSE: segments (text, phrase, places, sources), quiet tool line, 2–4-sentence replies | | todo | | |
| W6.2 | Phrase blocks → Show mode | | todo | | |
| W6.3 | Place chips + Show on map (From Mimo layer); plans as numbered stops | | todo | | |
| W6.4 | Starters per category, New chat, Ask Mimo about this place (subject place), local transcript | | todo | | |

### W7. Agent server and skills

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W7.1 | pi 1.0.1 pinned; GMI custom provider; per-skill model config from `.env` | | todo | | |
| W7.2 | Provider-agnostic typed output: schema in prompt → parse → `Value.Check` → retry once | | todo | | |
| W7.3 | `place-card` skill + server checks (basis, length, no Latin in zh, allergen filter, `pinyin-pro`) | | todo | | |
| W7.4 | `discover` skill (Mimo picks + Hidden gems) | | todo | | |
| W7.5 | `allergy-card` skill (free text only) | | todo | | |
| W7.6 | `mimo` skill: persona, `show_places`, Tavily `web_search`, sessions, guardrails (4 turns, 3 tools, timeout, busy lock) | | todo | | |
| W7.7 | Phrase-tag stream transformer → `phrase` events | | todo | | |
| W7.8 | Caching (persisted LRU, in-flight de-duplication), prefetch on situation change, daily cost kill switch | | todo | | |
| W7.9 | `server/evals/run.ts` with the canned situations (§6.4) | | todo | | |

## 3. Tier 2

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| T2.1 | Speak: ElevenLabs client (restricted key via the MLH code or Starter), audio cache, `AVSpeechSynthesizer` fallback, `.playback` session, stop Translate first | | todo | | |
| T2.2 | Live Activity: attributes in `Shared/`, lock screen, Dynamic Island, deep link to Show, one at a time | | todo | | |
| T2.3 | Onboarding survey (7 pages) + editing in Me + redo survey | | todo | | |
| T2.4 | Translate Type mode + tap-to-edit turns + `/v1/translate` | | todo | | |
| T2.5 | Bottom Listening accessory + tab-bar minimize | | todo | | |
| T2.6 | Server-minted Soniox keys (`/v1/soniox-key`) | | todo | | |
| T2.7 | Switch to Gemini: billed project + spend cap, `gemini-3.8-flash` (reasoning low), Flash-Lite for translate, rerun evals | | todo | | Required before submission (Gemini track) |

## 4. After core

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| A1 | Tiger Data: Postgres session store, `trip_events` hypertable, Gemini embeddings, `<trip_memory>` | | todo | | |
| A2 | Snowflake: `guides` table (Wikivoyage with attribution), Cortex Search, `search_guides` | | todo | | |

## 5. Submission

| # | Task | Owner | Status | Notes |
| --- | --- | --- | --- | --- |
| X1 | Devpost draft with GitHub link | | todo | Deadline Sun Oct 4, 12:00 PM PDT |
| X2 | Demo video (≤ 3 min) | | todo | |
| X3 | Write-up, screenshots (no keys or URLs visible), "built with", **AI tools disclosed** | | todo | |
| X4 | Opt into tracks: ElevenLabs, Gemini API, Tiger Data, Snowflake API, Best Solo, Best Design, .Tech | | todo | Each track needs its own opt-in |
| X5 | Repo stays public; rotate all keys after the event | | todo | |

## Blockers

| Date | Blocker | Owner | Resolution |
| --- | --- | --- | --- |
| | | | |

## Change log (spec changes made during implementation)

| Date | Change | Why | design.md updated? |
| --- | --- | --- | --- |
| 2026-10-03 | Initial tracker created from design.md §12 | | yes |
| 2026-10-03 | §4.2: live POIs within 100–150 m. §4.6: use the map item's name only if its script matches the local language, otherwise `placeNameLocal`. §4.7: always `regionPriority .required`, treat `placemarkNotFound` as no results. §10: Heytea Jing'an isn't in Apple Maps | D1 spike | yes |
| 2026-10-03 | Server port 8790 → **8792** (8790/8791 are used by another local dev server); Funnel `:10000` → 8792 | D4 spike | yes |
| 2026-10-03 | §4.7: cache-key fallback when there's no identifier, a name-similarity check, sort POIs by distance | D1 follow-up (Taipei/HK) | yes |
| 2026-10-03 | §6.3 model fixed to DeepSeek V4.1 Flash, thinking off; §6.2 the allergen filter allows safety mentions, plus a separator between text around tool calls; §6.4 prompt rules | D3 spike | yes |
| 2026-10-03 | §7: allergy-card request adds `homeLanguage`; templates at `contracts/tables/`; `done.stopReason` values; `when` = HH:mm; `bestTime` label; free BCP-47 language strings; optional `place.id` | W1 contracts | yes |
| 2026-10-03 | §7.8 mapping: >64 KB → 413 `invalid_request`, unknown route → 404 `invalid_request`, unhandled → 500 `model_error`. A failed Mimo run ends with one `error` event (terminal, no `done`) | W1 server | no (implementation detail) |
