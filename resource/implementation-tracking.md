# Ryoko: implementation tracking

A living tracker for the build. **Update it as you work.** When you start a task, mark it in progress and fill in Owner and Branch/PR. When you finish, mark it done and add a one-line note: what landed, and anything the next person needs to know.

- The spec is [`design.md`](design.md); § numbers below refer to it.
- If the build forces a change to the spec, update `design.md` and add a row to the change log at the bottom.

**Status:** `todo` · `doing` · `blocked` · `review` · `done` · `cut`

**Owner:** a person or agent label, e.g. `daniel`, `agent:map`.

## Snapshot

| Area | Status | Notes |
| --- | --- | --- |
| Setup (§12.2) | done | S1–S5 done |
| Device spikes (§11) | doing | D1, D3, D4 done (D1/D4 from the Mac); D2 done (desk) |
| Tier 1: working core | doing | **All of W1–W7 built, end-to-end checked against real GMI, reviewed and fixed.** Open: mic and tilt on the phone, minor follow-ups (see Fix round). W8 avatar in progress |
| Tier 2 | doing | T2.2–T2.6 done (merged, verified end to end on real GMI, reviewed, fixed). T2.1 Speak waits for an ElevenLabs key; T2.7 Gemini deferred |
| After core | todo | |
| Submission | todo | |

## What works in the app right now

Updated 2026-10-03 16:40. Update this section whenever a screen changes state.

| Screen | State | What you can do |
| --- | --- | --- |
| Tab bar | **Working** | Native Liquid Glass bar: Translate · Nearby · **Map (opens first)** · Mimo · Me |
| Nearby (was Now) | **Working** (W3) | Phrase cards with Show, tips, Allergy and Taxi quick cards, mini map (opens Map), preview banner with tap-to-change-time, special cases with a way to the Map, saved card when offline. Large-text layout fixed |
| Map | **Working** (W4), the launch tab | Opens on the map at your location with a floating sheet above the tab bar: Mimo picks with whys, then the nearest places; tap a row → it becomes your place → Nearby. ⓘ, a pin, a search result or a long-press opens details in the sheet (phrases, Preview, Taxi card, Ask Mimo, Make this my place). Layers: Food & drink, Washrooms, Hidden gems, From Mimo |
| Translate | **Working on device** (W5) | Real mic speech on the iPhone 18 Pro Max, English ⇄ the place's language (or picked), live panes upright or face to face with **working tilt**, History, clear error messages. In the simulator use `-RyokoTranslateSource canned` (the sim mic aborts) **T2:** Type mode with live preview, edit your turns, Listening bar on other tabs, server-minted Soniox keys. |
| Mimo | **Working** (W6 UI + W7 real model) | Ask Mimo or tap a starter: streamed reply with tappable phrase blocks (open Show), place chips (open Map), Show on map, source links; Stop, New chat, Ask Mimo about this place; transcript kept on device. Mimo's animated avatar is in the header (it thinks, talks and reacts) and is the tab icon. |
| Me | **Working** (T2.3) | Every profile section editable (saves live), home base by search or map, Redo survey, allergy card, romanization toggle, Credits, Developer |
| Onboarding | **Working** (T2.3) | 7-page survey on first launch (each page skippable); DEBUG builds offer 'Use demo profile' |
| Live Activity | **Working** (T2.2) | Lock screen + Dynamic Island with the place and its top phrase; tap opens Show mode |
| Show mode | **Working** (W3) | Full screen for phrases, the allergy card and the taxi card: Flip, Done, max brightness, screen stays awake |
| Server | **Real Mimo on GMI** (W7) | `pnpm server:dev` runs the real skills on DeepSeek V4.1 Flash: place cards ~2.6 s, discover ~3 s, Mimo chat with show_places and Exa web search, streamed phrase events with pinyin. `MODEL=faux` still serves fixtures |

**How to see it:** run `MODEL=faux pnpm server:dev`, build the `Ryoko` scheme on an iPhone simulator, then use Me → Developer → Preview a sample place and open the Nearby tab.

## UI test runs (Codex computer use)

| Date | Build | Result | Findings |
| --- | --- | --- | --- |
| 2026-10-03 15:13 | `cb26c3f`, iPhone 17 Pro Max sim, faux server on :8793 | A–G pass, H fail | **Pass:** all tabs open; romanization toggle; Live ↔ Fixtures switch and base URL (POST /v1/place-card seen); Back to here; location Allow → nearest 3 → confirm → card, and Deny → "Location is off" with Open Settings; error state with retry; Reset (not red). **Fail (H):** at the largest accessibility text size in dark mode, Now's header hides the local time, and "Previewing", "PM" and "Ramen" break mid-word (→ W3.3). **Design gaps (expected, W3 not built):** banner has no place name and doesn't reopen the picker; no Show button, quick cards or mini map; Me has no allergy-card preview. Evidence: `/tmp/ryoko-codex-ui/` (local only) |
| 2026-10-03 17:30 | `575e786` (before the avatar), iPhone 17 Pro Max sim, **real GMI** server on :8793 | A, C, D, G, H pass; B, E, F partial (long-press and a mid-reply Stop can't be driven by computer use) | **No functional bugs or crashes.** Real place card from a Mimo pick (GMI 3.5 s); real Mimo reply to a typed question; Show/Flip/Done, allergy 'Not reviewed', taxi, mini map, banner time sheet, numbered Show-on-map pins, New chat, canned Translate (4 turns, flip, History, pair menu), Me allergy row, dark + accessibility-large OK. **Design notes:** the Map sheet is translucent when fully expanded (§9.4 wants solid content); the avatar was absent (pre-W8.3 build); a far pick starts a preview (intended) |
| 2026-10-03 18:00 | `856e383` (with the avatar), iPhone 17 Pro Max sim, real GMI on :8793 | Tab icon, Map picks avatar, Mimo intro, composing mood, thinking→streaming during a real reply, DEBUG gallery: pass. Completion wink: **fail** (a focused composer outranked happy); fixed in the next commit with a 2.5 s happy beat | Long-presses can't be driven by computer use; **the user verified Map long-press and the Translate layout menu on the iPhone 18 Pro Max**. No clipping, dark-mode or crash issues |

**Device Hub workaround** (Xcode 27 ships no Simulator.app): if computer use times out selecting Device Hub (`-10005`), launch `/Applications/Xcode.app/Contents/Applications/DeviceHub.app/Contents/MacOS/DeviceHub` directly. Coordinate clicks can still fail intermittently (`noWindowsAvailable`); accessibility actions and screenshots work. See openai/codex#44717.

## Active branches and lanes (2026-10-03 18:05)

| Branch / worktree | Purpose | Owns |
| --- | --- | --- |
| `ui-refine` at `../stormhack26-ui` | The user's UI refinement pass | `ios/Ryoko/Map/`, `ios/Ryoko/Nearby/`, `ios/Ryoko/Mimo/`, `ios/Ryoko/App/Theme/Theme.swift` |
| `main` | T2.2–T2.6 merged | Everything else. **Doesn't touch the ui-refine lanes** until ui-refine merges back |

The live server for the phone runs from `main` on `127.0.0.1:8792`, behind the Funnel on `:10000`. Don't stop it.

## 0. Setup before agents fan out (§12.2)

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| S1 | Root `.gitignore`, `server/.env.example`, `Secrets.example.xcconfig` | lead | done |  | `.gitignore`, `server/.env.example`; local `server/.env` has a random `APP_TOKEN` |
| S2 | Xcode project in the GUI: Ryoko app, RyokoLiveActivity extension, synced folders, `Shared/` in both targets, team, iOS 26.1, iPhone and portrait only, Info.plist keys, xcconfigs. Builds on simulator and phone | agent:xcode | done |  | Generated from the CLI: synced folders (`Ryoko/`, `Shared/` in both targets, `RyokoLiveActivity/`), xcconfigs, shared scheme. Simulator build OK, launches with the 5-tab Liquid Glass bar; signed generic-device build OK. Still to do: run it on the physical phone; add Assets.xcassets (app icon) later |
| S3 | `AGENTS.md` (+ `CLAUDE.md` → `AGENTS.md`): ownership, build command, Swift rules, networking, key rules | lead | done |  | `AGENTS.md` and `CLAUDE.md` (imports AGENTS.md) |
| S4 | Keys in place: `server/.env` (GMI key + model id, Exa key, `APP_TOKEN`), `Secrets.xcconfig` (Soniox key, app token, base URL) | daniel | done |  | All keys in place (checked by length only): APP_TOKEN, GMI_API_KEY + GMI_MODEL, SONIOX_API_KEY (server/.env + Secrets.xcconfig), EXA_API_KEY (a live Exa search returned 200). Enter keys with `bash scripts/set-keys.sh` |
| S5 | Tailscale Funnel `:10000` → `127.0.0.1:8792` (`:443`/`:8443` belong to other services), reachable from the phone over cellular | agent:sse | done |  | `:10000` Funnel → `127.0.0.1:8792` (8790/8791 are taken by aerivoiceweb `wrangler dev`); `:443`/`:8443` untouched. Phone check over cellular still to do |

## 1. Device spikes (§11)

Write down what you find. The results may change the spec.

| # | Question | Owner | Status | Result |
| --- | --- | --- | --- | --- |
| D1 | MapKit from Canada: Shanghai and Tokyo search, POIs, reverse geocoding in `zh_Hans_CN` / `ja_JP`, time zones, `.restroom` coverage. Simulator first (Jing'an `.gpx`), then the phone | agent:mapkit | done (desk) | MapKit works from a plain CLI on the Mac. **Shanghai:** 26 POIs at 300 m, all `Asia/Shanghai`; reverse geocoding with `zh_Hans_CN` gives Chinese, but only to road level; restrooms sparse (0 at 300 m, 2 at 1.5 km); **Heytea Jing'an isn't in Apple's data**; `.default` priority leaks to Canadian results. **Tokyo:** 49 POIs, full `ja_JP` addresses, plenty of restrooms. **Names follow the app's language, not `preferredLocale`** (an English UI gives romanized or English names, and the language is fixed per process), so local names come from `placeNameLocal`. `timeZone` and `identifier` are always present. Phone check still to do: English iPhone on venue Wi-Fi, Heytea on iOS, restroom layer, `.required` from Vancouver. Code: `spikes/mapkit/` **Follow-up:** **Taipei** has rich data: 50嵐 9 hits, CoCo, 春水堂; house-number addresses in `zh_Hant_TW`; Traditional names under a zh-Hant UI; restrooms 38–50. It's the best Mandarin stand-in. **Hong Kong** has Heytea and rich data, but is Cantonese and matches short brand queries loosely. About 40% of TW/HK POIs have no identifier. |
| D2 | Soniox zh⇄en and ja⇄en: accuracy, script, latency, false language switches in a noisy hall. Tune the turn rule (§4.8) | agent:soniox | done (desk) | Valid key. TTS clips: connect 230–420 ms; median final lag zh/en 0.6–0.8 s, ja 1.1–1.6 s; zh always Simplified. **Turn rule as specified (2 tok / 2 CJK + <end>) splits every conversation correctly (en,zh,en / en,ja,en), including noisy variants**; also works without <end>. No translations arrive after <end>. Translation quality good; brand names miss (多肉葡萄 → "a pot of grapes"). **Temporary keys work** (mint 201 + full session), so T2.6 is feasible. Still to do: real voices in a noisy hall, on the phone |
| D3 | GMI: place-card latency (target < 3 s), and how reliably the model calls `show_places` / `web_search` | agent:gmi | done | **`deepseek-ai/DeepSeek-V4.1-Flash`, thinking off** (fallback `Qwen/Qwen3.8-Flash`). Place card p50 2.9 s / max 3.7 s; JSON 100% valid; show_places 10/10 in 2 turns; Mimo turn p50 4.4 s; phrase tags 5/5. Qwen and GLM are 2–3× slower. `json_object` mode works but doesn't help. Provider snippet and prompt rules are in design §6.2–6.4. Code: `spikes/gmi/src/` |
| D4 | SSE through Funnel: no buffering? Round-trip time on venue Wi-Fi and on cellular | agent:sse | done | Desk: public Funnel path, no buffering. **Phone: the app on the iPhone 18 Pro Max talks to the real server through the Funnel** (discover 4.0 s, Mimo reply 4.2 s with show_places). Cellular-only RTT not separately measured |

## 2. Tier 1: working core (§2, §12.3)

### W1. Contracts and fixture server

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W1.1 | TypeBox schemas + emitted JSON Schema for §7.1–7.8 | wf:contracts | done |  | `@ryoko/contracts`: TypeBox 1.3.27, local StringEnum, `additionalProperties:false`; 21 JSON Schema files via `pnpm contracts:emit` |
| W1.2 | Example request and response JSON per endpoint, plus `mimo.sse.txt` | wf:contracts | done |  | Hand-written examples (fictional Shanghai café, Tokyo ramen ticket-machine shop), `profile.seed.json`, `mimo.sse.txt`; 25 tests pass (`pnpm contracts:test`) |
| W1.3 | `LangCode` table, category table (display names, SF Symbols, starters), allergy templates (zh-Hans, ja × chip allergens × 3 severities) | wf:contracts | review |  | Tables done (langcodes incl. best-effort zh-Hant, 14 categories, allergy templates). **Allergy and taxi text has had no native review (`reviewed:false`)**: needs a Chinese reader and a Japanese reader |
| W1.4 | Hono skeleton: `/healthz`, bearer auth, error envelope, rate limit, body limit, SSE helper (512-byte padding, pings) | wf:server | done |  | Hono 4.13 on Node 24 type stripping. Bearer auth (constant time), install-id/IP rate limit, 64 KB limit, schema validation in and out, §7.8 errors everywhere, SSE helper (padding, pings, abort on close), per-session busy lock. 32 tests pass (`pnpm --filter ./server test`) |
| W1.5 | `MODEL=faux` fixture mode serving the examples, including a scripted Mimo stream | wf:server | done |  | `MODEL=faux` serves the examples by `localLanguage` and replays `mimo.sse.txt` with realistic pacing. Follow-up: add a Tokyo discover example, a zh-Hans allergy card and a zh-Hans Mimo transcript (W1.6) |
| W1.6 | Fixture gaps: `discover.tokyo.*`, zh-Hans `allergy-card.*`, zh-Hans `mimo.*.sse.txt` (+ server picks the transcript by language) | agent:fixtures | done |  | Tokyo discover (7 real Shinjuku places), zh-Hans allergy card (kiwi), zh-Hans Mimo transcript (3 real Jing'an places). The server and FixtureRyokoAPI pick a variant by language (exact tag, then primary subtag, then default). Contracts 32/32, server 38/38, iOS check 186/186 |

### W2. App shell and shared pieces

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W2.1 | `TabView` (Translate, Nearby, Map, Mimo, Me; opens on Map), theme tokens, time-of-day `LinearGradient` | wf:ios-shell | done |  | Native 5-tab `TabView`, theme tokens, `TimeOfDayGradient` using the §9.3 hex values (light and dark) in the situation's time zone |
| W2.2 | Codable `Situation`, `Profile`, `Phrase` mirroring `contracts/` | wf:ios-core | done |  | Codable mirrors of every §7 shape in `ios/Shared/Contracts/` (nonisolated, Sendable, Foundation only). Values the server sends tolerate unknown cases; `MimoEvent.unknown` |
| W2.3 | `SituationStore`: live (nearest 3 + confirm) and preview (place + date-time); local-language derivation | wf:ios-shell | done |  | Real `SituationStore`: live (nearest 3 within 150 m + confirm, `placemarkNotFound` means no results), preview, local language derived on device, contract `Situation` with an offset `localTime`. DEBUG sample-place launch hooks |
| W2.4 | `ProfileStore` with the bundled seed profile (§10) and content-hash version | wf:ios-shell | done |  | `ProfileStore`: seed profile, persisted edits, sha-256 canonical `version`, reset. Me: read-only profile, romanization toggle, developer section (fixtures or live server, base URL). Now wired to the place card (redacted, error, retry); verified against the faux server |
| W2.5 | `RyokoAPI` client + SSE line reader; base-URL override; fixture implementation | wf:ios-core | done |  | `RyokoAPI` protocol, `LiveRyokoAPI` (headers, install id, base-URL override, SSE line reader), `FixtureRyokoAPI` with bundled examples. `ios/scripts/check-contracts.sh --live`: 173 pass against the faux server, Mimo stream parsed end to end |
| W2.6 | `PlaceResolver`, `SpeechService` protocols with fixtures; `LocalText`; stubs for `PhraseCardView`, `TipRow`, `ShowContent`; preview gallery | wf:ios-core | done |  | `PlaceResolver`, `SpeechService`, `SituationStore` protocols with fixtures; `LocalText`, `PhraseCardView`, `TipRow`, `ShowContent`; `FixtureSelfCheck` (DEBUG); `ios/scripts/sync-fixtures.sh` |
| W2.7 | Review fixes: session lock held until the run stops; SSE escapes U+0085/2028/2029 (and iOS reads by LF bytes); live situation re-stamped every local hour and when the app becomes active; `AppRouter` + resolver/speech environment for cross-tab flows | wf:fix | done | | Server 34/34, iOS contract check 176/176 (180 live). Not yet seen at runtime: a real hour tick, and the router consumers (W3/W4/W6) |

### W3. Nearby and cards

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W3.1 | Nearby (renamed from Now): header, phrase cards with "because…", **Show button**, tips, quick cards, mini map; preview banner with the place name that reopens the picker | wf:W3 | done |  | Phrase cards with Show (router.show), 1–2 tips, quick cards (Allergy, Taxi), live non-interactive mini map → openMap(centeredOn:) |
| W3.2 | ~~Mimo picks row on Now~~: moved to the Map's bottom sheet (W4.5) |  | cut |  | Design change #43 |
| W3.3 | Nearby special cases: no place ("Where are you?" opens the Map list), local language = home language, loading/error/offline; **fix the largest-text layout bug** (see UI test findings) | wf:W3 | done |  | Special cases: no place (Open the map / Use my location), city-only (tips, picker, taxi to home base), you speak the language (no phrases, Preview a place); offline shows the saved card, marked. Large-text fixes kept |
| W3.4 | Show mode (`ShowContent` .phrase / .allergy / .taxi): max brightness, idle timer, Flip, Done | wf:W3 | done |  | Show mode for phrase/allergy/taxi: plain background, Flip rotates the content only, Done, brightness via windowScene.screen + idle timer off (restored), @ScaledMetric sizing |
| W3.5 | Allergy card: templates offline + `/v1/allergy-card` for free text ("not reviewed") | wf:W3 | done |  | Allergy card from bundled templates (zh-Hans, ja) plus /v1/allergy-card for typed-in allergens ('Not reviewed'); stricter severity wins; disabled with a note for languages without templates; Me row opens it |
| W3.6 | Taxi card: `MKReverseGeocodingRequest` in the local locale, local name, fixed phrase, snapshot | wf:W3 | done |  | TaxiCardFactory: name rule via ScriptMatch, MKReverseGeocodingRequest in the local locale (CJK lines joined natively), template phrase, MKMapSnapshotter; card(forHomeBase:) added; cached per session |

### W4. Map

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W4.1 | Map with `.searchable` + `MKLocalSearchCompleter`; POI tap (`MapSelection`) and long-press | wf:W4 | done |  | Map home at your location, .searchable + MKLocalSearchCompleter (biased to the visible region), POI tap (MapSelection → MKMapItemRequest), long-press (reverse-geocoded). Real touch untested (no tap automation) |
| W4.2 | Place sheet: phrase cards, tips, Preview with date-time picker + chips, Taxi card, Ask Mimo about this place | wf:W4 | done |  | Place details in the same panel: Mimo's why, Make this my place, Preview (PreviewTimeSheet), Taxi card (TaxiCardFactory → Show from the panel), Ask Mimo, phrase cards and tips |
| W4.3 | Layers: Food & drink and Washrooms (MapStyle filters), Hidden gems, From Mimo (numbered for plans) | wf:W4 | done |  | Layers menu: Food & drink + Washrooms (MapStyle POI filters), Hidden gems (orange), From Mimo (numbered plan pins, clear action); router.mapFocus applied then cleared |
| W4.4 | `PlaceResolver`: name → MKMapItem, local name first in China, 5 km cap, cache, throttle-safe | wf:W4 | done |  | LivePlaceResolver: always .required, local name first in China, nearest hit within 5 km, name-match ranking, cache by identifier or name+coordinate, 40/min throttle; registered in RyokoApp |
| W4.5 | **Map home bottom sheet** (Apple Maps style): Mimo picks first (from `discover`), then the nearest places; ~3 rows at the small detent, scroll for more; tapping a place makes it current and opens Nearby (`router.openNearby()`); place details shown in the same sheet | wf:W4 | done |  | Bottom sheet = in-tab floating panel above the tab bar (a native .sheet covered the tab bar); 3 snap points, ~3 rows at small; header Near you / Previewing; Mimo picks first, then up to 25 nearest; row tap → makeCurrent + openNearby; ⓘ → details |

### W5. Translate

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W5.1 | Soniox WebSocket client (`stt-rt-v5`, `two_way`, language ID, endpoints), 16 kHz mono PCM capture (nonisolated tap) | wf:W5 | done |  | SonioxSession + MicrophoneCapture. **Verified on the iPhone 18 Pro Max**: real mic speech is transcribed and translated (the simulator mic still aborts; device-only) |
| W5.2 | Turn model + rule (§4.8), History sheet, 2-minute silence stop | wf:W5 | done |  | TurnBuilder (pure): 2 wordy final tokens or 2 CJK characters start a turn, false flips absorbed, <end> commits, late translations attach by source_language; History sheet; 2-minute silence stop (tokens, not audio energy). Harness passes; real tokens untested |
| W5.3 | Pair from situation (manual pick, fixed mid-session) | wf:W5 | done |  | Pair from the situation via LangCode, manual picker (their language / your language), fixed mid-session |
| W5.4 | Upright + face-to-face layouts, CoreMotion tilt with hysteresis, manual toggle, haptics | wf:W5 | done |  | Upright + face-to-face, tilt hysteresis, toolbar toggle, haptics. **Tilt verified on the iPhone 18 Pro Max** |

### W6. Mimo tab

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W6.1 | Chat over SSE: segments (text, phrase, places, sources), quiet tool line, 2–4-sentence replies | wf:W6 | done |  | SSE chat with ordered segments, inline Markdown, quiet tool line, error ends the reply, Stop/Try again, 409 handling; sends profile, currentSituation(), up to 20 POIs, subjectPlace |
| W6.2 | Phrase blocks → Show mode | wf:W6 | done |  | Phrase blocks (PhraseCardView .block) set router.show = .phrase, with a haptic |
| W6.3 | Place chips + Show on map (From Mimo layer); plans as numbered stops | wf:W6 | done |  | Place chips via the shared resolver (misses dropped), openMap(selecting:), Show on map; plans as numbered stops with times |
| W6.4 | Starters per category, New chat, Ask Mimo about this place (subject place), local transcript | wf:W6 | done |  | Starters per category plus a time-of-day plan starter; New chat; subject chip; transcripts saved on device (20 most recent). Tested on fixtures only; real model is checked in e2e |

### W7. Agent server and skills

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W7.1 | pi 1.0.1 pinned; GMI custom provider; per-skill model config from `.env` | wf:W7 | done |  | pi 1.0.1 pinned; GMI registered as an OpenAI-compatible provider (reasoning:true, off→none); per-skill MODEL_<SKILL> overrides; google provider lazy for the Gemini switch |
| W7.2 | Provider-agnostic typed output: schema in prompt → parse → `Value.Check` → retry once | wf:W7 | done |  | Provider-agnostic typed output: schema in prompt → tolerant parse → Value.Clean/Check → skill checks → one retry listing problems → 502 |
| W7.3 | `place-card` skill + server checks (basis, length, no Latin in zh, allergen filter, `pinyin-pro`) | wf:W7 | done |  | place-card with compacted profile + allowedBasis; checks (basis, ≤12-word because, script, no Latin in zh, allergen + diet filter with safety exemption); pinyin-pro. Evals: 100% valid, p50 2.6 s, max 2.9 s |
| W7.4 | `discover` skill (Mimo picks + Hidden gems) | wf:W7 | done |  | discover: 5–8 places, why ≤60 chars, bestTime; drops duplicates, wrong-script names, allergen conflicts. ~3.1 s |
| W7.5 | `allergy-card` skill (free text only) | wf:W7 | done |  | allergy-card: free text only, §4.5 wording, severity from the request, reviewed:false, pinyin |
| W7.6 | `mimo` skill: persona, `show_places`, Exa `web_search`, sessions, guardrails (4 turns, 3 tools, timeout, busy lock) | wf:W7 | done |  | mimo: pi-agent-core Agent per session, context sections replaced per message, show_places + Exa web_search, ≤4 turns / ≤3 tools, timeout, abort on disconnect, rollback of failed runs |
| W7.7 | Phrase-tag stream transformer → `phrase` events | wf:W7 | done |  | Phrase-tag transformer: buffered tags → phrase events, pinyin fill, ≤4 per reply, separator around tool calls, malformed tags flushed as text |
| W7.8 | Caching (persisted LRU, in-flight de-duplication), prefetch on situation change, daily cost kill switch | wf:W7 | done |  | Persisted LRU in server/.cache (survives restart, 2 ms hits), in-flight de-duplication, daily budget kill switch (pi usage + Exa cost); $0.18 spent so far |
| W7.9 | `server/evals/run.ts` with the canned situations (§6.4) | wf:W7 | done |  | server/evals/run.ts on real GMI (RUNS=2): place-card/discover/allergy 100% valid. 89 offline tests pass; check-contracts --live 193/193 |

### Fix round after W3–W7 (2026-10-03)

| Issue | Severity | Outcome |
| --- | --- | --- |
| Allergen filter let "peanut milk tea, no ice" through (a safety cue anywhere cleared the item) | blocker | **Fixed**: a cue only clears the mention it governs; 有…吗 / "is there" are no longer cues; regression tests from real model output; evals list allergen mentions for a person to read; prompt versions bumped (pc-4, dc-3) |
| Resolver accepted wrong places ("Hanazono Shrine" → a festival listing) | major | **Fixed**: whole-word name matching (only area, branch or kind words may be added; CJK = same name + branch suffix); pick rows show MapKit's name; 29/29 name-match cases pass |
| Discover invented places | major | **Fixed** (prompt): only long-established places that certainly exist; 14/14 real in two real calls, 10/14 resolved, all correctly |
| Home-base taxi card showed the Shanghai hotel in Tokyo | major | **Fixed**: offered only within 50 km, otherwise "Your home base is in another city" |
| Prominent buttons blank in dark mode | major | **Fixed**: shared `.monochromeProminent` style in Theme.swift, used by all 7 prominent buttons |
| Mic capture aborts in the simulator | major | **Open**: needs a run on the phone |

**Follow-ups (minor, from the review and the e2e check):**
- double haptic when Show opens from Mimo or the Map
- collapsed Map sheet shows no rows at the largest text sizes
- Preview from Map details should open Nearby
- no prefetch of place card and discover on situation change (§6.4 Speed)
- Mimo session transcript grows without a limit
- show_places whys aren't allergen-checked
- loose script checks (kana passes as Han)
- idle-timer writes from Translate and Show can conflict
- makeCurrent falls back to country US
- PlaceCardCache key ignores profile.version
- the model sometimes writes local script outside phrase tags
- 2 Tokyo discover fixtures no longer resolve under the stricter matcher
- overlapping From Mimo pins
- stale `-RyokoInitialTab now` comment
- duplicated "speaks the local language" helpers


### W8. Mimo avatar (design §4.9, decision #45)

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W8.1 | Port bloub's `src/bot/` engine to Swift (pure `sample(t)`, exact measured constants, MIT header + THIRD_PARTY_NOTICES.md) with a numeric exactness check against the TS engine | agent:avatar | done |  | 11 engine files ported with MIT headers; THIRD_PARTY_NOTICES.md. Exactness: 1199 frames / 113 cases / ~600k numbers + 2040 eye-fit entries vs the TS engine, max error 5.7e-14 (a doctored reference fails the check) |
| W8.2 | `MimoAvatarView(mood:size:)` (Canvas + TimelineView, .primary body, eye cut-outs, Reduce Motion), `MimoMood` (idle/listening/thinking/talking/happy), Mimo's own style preset, `MimoAvatarIcon` template image, DEBUG gallery | agent:avatar | done |  | `.mimo` style = pebble body (galet) + attentive upright eyes (x.ai is a circle glancing up-right). MimoMood idle/listening/thinking/talking/happy, MimoAvatarView (Canvas+TimelineView, Reduce Motion holds a still pose), MimoAvatarIcon template image, DEBUG MimoAvatarGallery |
| W8.3 | Integrate: Mimo tab header (mood follows the chat stream/tool/done), Map sheet "Mimo picks" header, Mimo tab icon in RootTabView, credits line in Me | lead | done |  | Mimo intro avatar + a toolbar avatar during chats (mood: thinking while a tool runs / before text, talking while streaming, listening while typing, happy after a reply); avatar beside "Mimo picks" in the Map sheet (thinking only until the first pick shows); Mimo tab icon = MimoAvatarIcon; DEBUG `-RyokoAvatarGallery 1`; Me → Credits links bloub (MIT) |
| W8.4 | UI refine pass (design #48, #49): Map search/Layers, gradient on more tabs, Mimo header + history sidebar, inline phrases, places card, status pill and calmer streaming, Show tilt, Translate language pills | lead | review | `ui-refine` | Simulator-checked (screenshots); on the iPhone 18 Pro Max for hand testing (tilt, sidebar swipes, keyboard scroll). Prompt change (phrases after their sentence) needs the main server restarted. Commits cde32aa, 7102a20, ea2ab70, 40bd4d6, ce23d5a (search line held 2.5 s, one source pill per site), 09d07d3 (Translate language pills beside the mic; Type's keyboard button moved to the status row) |

## 3. Tier 2

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| T2.1 | Speak: ElevenLabs client (restricted key via the MLH code or Starter), audio cache, `AVSpeechSynthesizer` fallback, `.playback` session, stop Translate first | | todo | | |
| T2.2 | Live Activity: attributes in `Shared/`, lock screen, Dynamic Island, deep link to Show, one at a time | wf:T2 | done | `worktree-wf_be317781-a93-1` | Starts on confirm/preview (only where there are phrases), one at a time, placeholder → real top phrase (≤ ~320 B), 2 h end + staleDate; lock screen + Dynamic Island (category symbol + short name, expanded phrase); ryoko://show deep link opens Show (cold start too); waits 2.5 s for profile edits to settle. Real tap on the phone still to try |
| T2.3 | Onboarding survey (7 pages) + editing in Me + redo survey | wf:T2 | done |  | 7-page survey on first launch (skips → null), DEBUG 'Use demo profile'; Me: every section editable live (text saves after a 1 s pause), home base via search or pick on map, Redo survey; profile.version updates so the server regenerates cards |
| T2.4 | Translate Type mode + tap-to-edit turns + `/v1/translate` | wf:T2 | done |  | Type mode with a live preview (500 ms pauses, stale requests cancelled), Done adds the turn; tap your turn (panes or History) to edit and re-translate; /v1/translate on GMI ~1.6–2.2 s cold, cached |
| T2.5 | Bottom Listening accessory + tab-bar minimize | wf:T2 | done |  | App-wide TranslateModel; 'Listening · English ⇄ Japanese' accessory with stop on other tabs; tab bar minimizes on scroll on Nearby and Mimo only (design §3) |
| T2.6 | Server-minted Soniox keys (`/v1/soniox-key`) | wf:T2 | done |  | /v1/soniox-key mints single-use 60 s keys (3600 s session cap, 10/min); each session uses one; falls back to the bundled key only when the server can't mint (kept for the hackathon, #46) |
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
| X6 | Basic project README | agent:docs | done | `ws/docs-basic-readme`; [88e1033](https://github.com/DanielOu1208/stormhack26/commit/88e1033): concise overview, local setup and doc links; humanizer pass, links and commands checked |

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
| 2026-10-03 | Live situations are re-stamped hourly and when the app becomes active (only if the hour changed); cross-tab navigation goes through `AppRouter` | W1/W2 review | no (implementation; documented in AGENTS.md) |
| 2026-10-03 | Map-first: tabs are Translate · Nearby · Map · Mimo · Me, opening on Map; Now → Nearby; Map bottom sheet with Mimo picks then nearby places; Mimo picks moved off Nearby | user | yes (#42, #43) |
| 2026-10-03 | Web search provider Tavily → Exa (`EXA_API_KEY`) | user | yes (#44) |
| 2026-10-03 | Map bottom sheet is an in-tab floating panel above the tab bar, not a native `.sheet` (inside TabView a sheet covers the tab bar). Tapping a far pick previews it at the current time; within 300 m it becomes the live place | W4 | no (implementation) |
| 2026-10-03 | Map sheet stays translucent (material, Apple Maps style); the user is happy with it, which overrides §9.4's solid-surface note for this floating panel | user | no |
| 2026-10-03 | The bundled Soniox key stays as a fallback when the server can't mint a key (hackathon robustness) | review default | yes (#46) |
| 2026-10-03 | `/v1/localize-place` cut: the home base's local name/address are worked out on device with MapKit | T2.3 | yes (#47) |
| 2026-10-03 | Tab bar minimize limited to Nearby and Mimo (design §3) | T2 review/fix | no (matches §3) |
