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
| Tier 1: working core | doing | **All of W1–W7 built, end-to-end checked against real GMI, reviewed and fixed.** W8 avatar done. **Merged on `main` (W8.6–W8.14):** Map-first places with Nearby removed (#53), picks grounded in real nearby places (#54), About me (#55), Mimo relevance (#56), allergen filter removed (#57), thinking levels (#58), compact Mimo header (#59), place thumbnails (#60), and the sidebar/composer fix. Open: minor follow-ups (see Fix round); W8.5 hand testing on the phone |
| Tier 2 | doing | T2.2–T2.6 done (merged, verified end to end on real GMI, reviewed, fixed). T2.1 Speak waits for an ElevenLabs key; T2.7 Gemini deferred |
| After core | todo | |
| Submission | todo | |

## What works in the app right now

Updated 2026-10-03 22:20. Update this section whenever a screen changes state.

| Screen | State | What you can do |
| --- | --- | --- |
| Tab bar | **Working** | Native Liquid Glass bar with four tabs: Translate · **Map (opens first)** · Mimo · Me. It never minimizes |
| Nearby | **Removed** (#53, W8.6) | Its phrases, tips, Allergy, Taxi and Preview live on the Map's place card. `ryoko://nearby` and `-RyokoInitialTab nearby` open the Map |
| Map | **Working** (W4, W8.6), the launch tab | Opens on the map at your location; the sheet rests at about 45%. Header: "You're at <place> ›" (opens its card), "Near you", or the previewed place with a small Previewing badge and Back to here. Mimo picks (grounded in the real places nearby) with whys, then the nearest places, each with a Look Around thumbnail. **Any place** (pin, POI, row, search result, long-press, pick, From Mimo pin, the header) opens its **card**: Look Around preview, Directions, Taxi, Allergy, Ask Mimo, I'm here (within 300 m) or Preview, why, what to say with Show, tips, address. Opening a card never changes your place. Layers: Food & drink, Washrooms, Hidden gems, From Mimo |
| Translate | **Working on device** (W5) | Real mic speech on the iPhone 18 Pro Max, English ⇄ the place's language (or picked), live panes upright or face to face with **working tilt**, History, clear error messages. In the simulator use `-RyokoTranslateSource canned` (the sim mic aborts) **T2:** Type mode with live preview, edit your turns, Listening bar on other tabs, server-minted Soniox keys. |
| Mimo | **Working** (W6 UI + W7 real model) | Ask Mimo or tap a starter: streamed reply with tappable phrase blocks (open Show), a places card with thumbnails (a row opens the place's card on the Map), Show on map, source links; Stop, New chat, Ask Mimo about a place (its map preview tops the first message and opens its card); a model picker in the composer (level button, model list, a level slider coloured warm to cool); history sidebar; composer tucked into a corner button; transcript kept on device. Compact header: 64 pt animated avatar and one "<place> · <time>" pill. Mimo brings up allergies only around food. |
| Me | **Working** (T2.3, W8.8) | About me at the top (Mimo's background), every profile section editable (saves when typing pauses), home base by search or map, Redo survey, allergy card, romanization toggle, Credits, Developer |
| Onboarding | **Working** (T2.3) | 7-page survey on first launch (each page skippable); DEBUG builds offer 'Use demo profile' |
| Live Activity | **Working** (T2.2) | Lock screen + Dynamic Island with the place and its top phrase; a tap opens the Map on the current place's card, a phrase link opens Show mode over it |
| Show mode | **Working** (W3) | Full screen for phrases, the allergy card and the taxi card: Flip, tilt, Done, max brightness, screen stays awake |
| Server | **Real Mimo on GMI** (W7) | `pnpm server:dev` runs the real skills on DeepSeek V4.1 Flash with per-skill thinking (Mimo high, place cards low, the rest off): Mimo chat with show_places and Exa web search, streamed phrase events with pinyin, discover picks from the nearby list. No allergen word filter. `MODEL=faux` still serves fixtures |

**How to see it:** run `MODEL=faux pnpm server:dev`, build the `Ryoko` scheme on an iPhone simulator, then use Me → Developer → Preview a sample place and open the Map: the sheet's header shows the previewed place; tap it for its card.

## UI test runs (Codex computer use)

| Date | Build | Result | Findings |
| --- | --- | --- | --- |
| 2026-10-03 15:13 | `cb26c3f`, iPhone 17 Pro Max sim, faux server on :8793 | A–G pass, H fail | **Pass:** all tabs open; romanization toggle; Live ↔ Fixtures switch and base URL (POST /v1/place-card seen); Back to here; location Allow → nearest 3 → confirm → card, and Deny → "Location is off" with Open Settings; error state with retry; Reset (not red). **Fail (H):** at the largest accessibility text size in dark mode, Now's header hides the local time, and "Previewing", "PM" and "Ramen" break mid-word (→ W3.3). **Design gaps (expected, W3 not built):** banner has no place name and doesn't reopen the picker; no Show button, quick cards or mini map; Me has no allergy-card preview. Evidence: `/tmp/ryoko-codex-ui/` (local only) |
| 2026-10-03 17:30 | `575e786` (before the avatar), iPhone 17 Pro Max sim, **real GMI** server on :8793 | A, C, D, G, H pass; B, E, F partial (long-press and a mid-reply Stop can't be driven by computer use) | **No functional bugs or crashes.** Real place card from a Mimo pick (GMI 3.5 s); real Mimo reply to a typed question; Show/Flip/Done, allergy 'Not reviewed', taxi, mini map, banner time sheet, numbered Show-on-map pins, New chat, canned Translate (4 turns, flip, History, pair menu), Me allergy row, dark + accessibility-large OK. **Design notes:** the Map sheet is translucent when fully expanded (§9.4 wants solid content); the avatar was absent (pre-W8.3 build); a far pick starts a preview (intended) |
| 2026-10-03 18:00 | `856e383` (with the avatar), iPhone 17 Pro Max sim, real GMI on :8793 | Tab icon, Map picks avatar, Mimo intro, composing mood, thinking→streaming during a real reply, DEBUG gallery: pass. Completion wink: **fail** (a focused composer outranked happy); fixed in the next commit with a 2.5 s happy beat | Long-presses can't be driven by computer use; **the user verified Map long-press and the Translate layout menu on the iPhone 18 Pro Max**. No clipping, dark-mode or crash issues |

**Device Hub workaround** (Xcode 27 ships no Simulator.app): if computer use times out selecting Device Hub (`-10005`), launch `/Applications/Xcode.app/Contents/Applications/DeviceHub.app/Contents/MacOS/DeviceHub` directly. Coordinate clicks can still fail intermittently (`noWindowsAvailable`); accessibility actions and screenshots work. See openai/codex#44717.

## Active branches and lanes (2026-10-03 22:20)

| Branch / worktree | Purpose | Owns |
| --- | --- | --- |
| `main` | Everything through `9673a23`: T2.2–T2.6, the UI refine pass (PR #2), and W8.6–W8.14 (Map-first redesign, picks grounding, About me, Mimo relevance, filter removal, thinking levels, Mimo header, thumbnails, sidebar/composer fix) | Everything. The agent worktrees under `.claude/worktrees/` (`worktree-agent-*`, `worktree-wf_3dfe753f-*`, `worktree-wf_bbcc6949-*`) and `ui-refine` at `../stormhack26-ui` are all merged; their lanes are free again |

`b84343a` (after those merges) only adds a Foursquare key to `scripts/set-keys.sh` and a placeholder to `server/.env.example`, for place photos; nothing uses it yet.

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
| W2.1 | `TabView` (Translate, Nearby, Map, Mimo, Me; opens on Map), theme tokens, time-of-day `LinearGradient` | wf:ios-shell | done |  | Native 5-tab `TabView` (four tabs since W8.6, #53), theme tokens, `TimeOfDayGradient` using the §9.3 hex values (light and dark) in the situation's time zone |
| W2.2 | Codable `Situation`, `Profile`, `Phrase` mirroring `contracts/` | wf:ios-core | done |  | Codable mirrors of every §7 shape in `ios/Shared/Contracts/` (nonisolated, Sendable, Foundation only). Values the server sends tolerate unknown cases; `MimoEvent.unknown` |
| W2.3 | `SituationStore`: live (nearest 3 + confirm) and preview (place + date-time); local-language derivation | wf:ios-shell | done |  | Real `SituationStore`: live (nearest 3 within 150 m + confirm, `placemarkNotFound` means no results), preview, local language derived on device, contract `Situation` with an offset `localTime`. DEBUG sample-place launch hooks |
| W2.4 | `ProfileStore` with the bundled seed profile (§10) and content-hash version | wf:ios-shell | done |  | `ProfileStore`: seed profile, persisted edits, sha-256 canonical `version`, reset. Me: read-only profile, romanization toggle, developer section (fixtures or live server, base URL). Now wired to the place card (redacted, error, retry); verified against the faux server |
| W2.5 | `RyokoAPI` client + SSE line reader; base-URL override; fixture implementation | wf:ios-core | done |  | `RyokoAPI` protocol, `LiveRyokoAPI` (headers, install id, base-URL override, SSE line reader), `FixtureRyokoAPI` with bundled examples. `ios/scripts/check-contracts.sh --live`: 173 pass against the faux server, Mimo stream parsed end to end |
| W2.6 | `PlaceResolver`, `SpeechService` protocols with fixtures; `LocalText`; stubs for `PhraseCardView`, `TipRow`, `ShowContent`; preview gallery | wf:ios-core | done |  | `PlaceResolver`, `SpeechService`, `SituationStore` protocols with fixtures; `LocalText`, `PhraseCardView`, `TipRow`, `ShowContent`; `FixtureSelfCheck` (DEBUG); `ios/scripts/sync-fixtures.sh` |
| W2.7 | Review fixes: session lock held until the run stops; SSE escapes U+0085/2028/2029 (and iOS reads by LF bytes); live situation re-stamped every local hour and when the app becomes active; `AppRouter` + resolver/speech environment for cross-tab flows | wf:fix | done | | Server 34/34, iOS contract check 176/176 (180 live). Not yet seen at runtime: a real hour tick, and the router consumers (W3/W4/W6) |

### W3. Nearby (removed, #53) and cards

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W3.1 | Nearby (renamed from Now): header, phrase cards with "because…", **Show button**, tips, quick cards, mini map; preview banner with the place name that reopens the picker | wf:W3 | done |  | **Superseded by W8.6 (#53): Nearby is removed; this is now the Map's place card.** Phrase cards with Show (router.show), 1–2 tips, quick cards (Allergy, Taxi), live non-interactive mini map → openMap(centeredOn:) |
| W3.2 | ~~Mimo picks row on Now~~: moved to the Map's bottom sheet (W4.5) |  | cut |  | Design change #43 |
| W3.3 | Nearby special cases: no place ("Where are you?" opens the Map list), local language = home language, loading/error/offline; **fix the largest-text layout bug** (see UI test findings) | wf:W3 | done |  | **Superseded by W8.6 (#53): the place card has these cases (tips only where you speak the language, redacted, Try again, saved card).** Special cases: no place (Open the map / Use my location), city-only (tips, picker, taxi to home base), you speak the language (no phrases, Preview a place); offline shows the saved card, marked. Large-text fixes kept |
| W3.4 | Show mode (`ShowContent` .phrase / .allergy / .taxi): max brightness, idle timer, Flip, Done | wf:W3 | done |  | Show mode for phrase/allergy/taxi: plain background, Flip rotates the content only, Done, brightness via windowScene.screen + idle timer off (restored), @ScaledMetric sizing |
| W3.5 | Allergy card: templates offline + `/v1/allergy-card` for free text ("not reviewed") | wf:W3 | done |  | Allergy card from bundled templates (zh-Hans, ja) plus /v1/allergy-card for typed-in allergens ('Not reviewed'); stricter severity wins; disabled with a note for languages without templates; Me row opens it |
| W3.6 | Taxi card: `MKReverseGeocodingRequest` in the local locale, local name, fixed phrase, snapshot | wf:W3 | done |  | TaxiCardFactory: name rule via ScriptMatch, MKReverseGeocodingRequest in the local locale (CJK lines joined natively), template phrase, MKMapSnapshotter; card(forHomeBase:) added; cached per session |

### W4. Map

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W4.1 | Map with `.searchable` + `MKLocalSearchCompleter`; POI tap (`MapSelection`) and long-press | wf:W4 | done |  | Map home at your location, .searchable + MKLocalSearchCompleter (biased to the visible region), POI tap (MapSelection → MKMapItemRequest), long-press (reverse-geocoded). Real touch untested (no tap automation) |
| W4.2 | Place sheet: phrase cards, tips, Preview with date-time picker + chips, Taxi card, Ask Mimo about this place | wf:W4 | done |  | **Superseded by W8.6 (#53): place details became the place card (I'm here or Preview; no Make this my place).** Place details in the same panel: Mimo's why, Make this my place, Preview (PreviewTimeSheet), Taxi card (TaxiCardFactory → Show from the panel), Ask Mimo, phrase cards and tips |
| W4.3 | Layers: Food & drink and Washrooms (MapStyle filters), Hidden gems, From Mimo (numbered for plans) | wf:W4 | done |  | Layers menu: Food & drink + Washrooms (MapStyle POI filters), Hidden gems (orange), From Mimo (numbered plan pins, clear action); router.mapFocus applied then cleared |
| W4.4 | `PlaceResolver`: name → MKMapItem, local name first in China, 5 km cap, cache, throttle-safe | wf:W4 | done |  | LivePlaceResolver: always .required, local name first in China, nearest hit within 5 km, name-match ranking, cache by identifier or name+coordinate, 40/min throttle; registered in RyokoApp |
| W4.5 | **Map home bottom sheet** (Apple Maps style): Mimo picks first (from `discover`), then the nearest places; ~3 rows at the small detent, scroll for more; tapping a place makes it current and opens Nearby (`router.openNearby()`); place details shown in the same sheet | wf:W4 | done |  | **Row tap superseded by W8.6 (#53): a row opens the place's card; nothing opens Nearby.** Bottom sheet = in-tab floating panel above the tab bar (a native .sheet covered the tab bar); 3 snap points, ~3 rows at small; header Near you / Previewing; Mimo picks first, then up to 25 nearest; row tap → makeCurrent + openNearby; ⓘ → details |

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
| W7.3 | `place-card` skill + server checks (basis, length, no Latin in zh, allergen filter, `pinyin-pro`) | wf:W7 | done |  | place-card with compacted profile + allowedBasis; checks (basis, ≤12-word because, script, no Latin in zh, ~~allergen + diet filter with safety exemption~~ **superseded: the filter is removed, W8.10 (#57)**); pinyin-pro. Evals: 100% valid, p50 2.6 s, max 2.9 s |
| W7.4 | `discover` skill (Mimo picks + Hidden gems) | wf:W7 | done |  | discover: 5–8 places, why ≤60 chars, bestTime; drops duplicates, wrong-script names, ~~allergen conflicts~~ (superseded: no allergen check since W8.10, #57). ~3.1 s. Picks now come from the nearby list (W8.7, #54) |
| W7.5 | `allergy-card` skill (free text only) | wf:W7 | done |  | allergy-card: free text only, §4.5 wording, severity from the request, reviewed:false, pinyin |
| W7.6 | `mimo` skill: persona, `show_places`, Exa `web_search`, sessions, guardrails (4 turns, 3 tools, timeout, busy lock) | wf:W7 | done |  | mimo: pi-agent-core Agent per session, context sections replaced per message, show_places + Exa web_search, ≤4 turns / ≤3 tools, timeout, abort on disconnect, rollback of failed runs |
| W7.7 | Phrase-tag stream transformer → `phrase` events | wf:W7 | done |  | Phrase-tag transformer: buffered tags → phrase events, pinyin fill, ≤4 per reply, separator around tool calls, malformed tags flushed as text |
| W7.8 | Caching (persisted LRU, in-flight de-duplication), prefetch on situation change, daily cost kill switch | wf:W7 | done |  | Persisted LRU in server/.cache (survives restart, 2 ms hits), in-flight de-duplication, daily budget kill switch (pi usage + Exa cost); $0.18 spent so far |
| W7.9 | `server/evals/run.ts` with the canned situations (§6.4) | wf:W7 | done |  | server/evals/run.ts on real GMI (RUNS=2): place-card/discover/allergy 100% valid. 89 offline tests pass; check-contracts --live 193/193 |

### Fix round after W3–W7 (2026-10-03)

| Issue | Severity | Outcome |
| --- | --- | --- |
| Allergen filter let "peanut milk tea, no ice" through (a safety cue anywhere cleared the item) | blocker | **Superseded: the allergen filter is removed (W8.10, #57); allergies are hard limits in the prompts only.** Was fixed: a cue only clears the mention it governs; 有…吗 / "is there" are no longer cues; regression tests from real model output; evals list allergen mentions for a person to read; prompt versions bumped (pc-4, dc-3) |
| Resolver accepted wrong places ("Hanazono Shrine" → a festival listing) | major | **Fixed**: whole-word name matching (only area, branch or kind words may be added; CJK = same name + branch suffix); pick rows show MapKit's name; 29/29 name-match cases pass |
| Discover invented places | major | **Fixed** (prompt): only long-established places that certainly exist; 14/14 real in two real calls, 10/14 resolved, all correctly |
| Home-base taxi card showed the Shanghai hotel in Tokyo | major | **Fixed**: offered only within 50 km, otherwise "Your home base is in another city" |
| Prominent buttons blank in dark mode | major | **Fixed**: shared `.monochromeProminent` style in Theme.swift, used by all 7 prominent buttons |
| Mic capture aborts in the simulator | major | **Open**: needs a run on the phone |

**Follow-ups (minor, from the review and the e2e check):**
- double haptic when Show opens from Mimo or the Map
- collapsed Map sheet shows no rows at the largest text sizes
- ~~Preview from Map details should open Nearby~~ (obsolete: Nearby is removed, #53)
- no prefetch of place card and discover on situation change (§6.4 Speed)
- Mimo session transcript grows without a limit
- ~~show_places whys aren't allergen-checked~~ (obsolete: no server-side allergen check, #57)
- loose script checks (kana passes as Han)
- idle-timer writes from Translate and Show can conflict
- makeCurrent falls back to country US
- PlaceCardCache key ignores profile.version
- the model sometimes writes local script outside phrase tags
- 2 Tokyo discover fixtures no longer resolve under the stricter matcher
- overlapping From Mimo pins
- ~~stale `-RyokoInitialTab now` comment~~ (done in W8.6: `now` and `nearby` open the Map)
- duplicated "speaks the local language" helpers


### W8. Mimo avatar and later passes (design §4.9, decisions #45 onward)

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| W8.1 | Port bloub's `src/bot/` engine to Swift (pure `sample(t)`, exact measured constants, MIT header + THIRD_PARTY_NOTICES.md) with a numeric exactness check against the TS engine | agent:avatar | done |  | 11 engine files ported with MIT headers; THIRD_PARTY_NOTICES.md. Exactness: 1199 frames / 113 cases / ~600k numbers + 2040 eye-fit entries vs the TS engine, max error 5.7e-14 (a doctored reference fails the check) |
| W8.2 | `MimoAvatarView(mood:size:)` (Canvas + TimelineView, .primary body, eye cut-outs, Reduce Motion), `MimoMood` (idle/listening/thinking/talking/happy), Mimo's own style preset, `MimoAvatarIcon` template image, DEBUG gallery | agent:avatar | done |  | `.mimo` style = pebble body (galet) + attentive upright eyes (x.ai is a circle glancing up-right). MimoMood idle/listening/thinking/talking/happy, MimoAvatarView (Canvas+TimelineView, Reduce Motion holds a still pose), MimoAvatarIcon template image, DEBUG MimoAvatarGallery |
| W8.3 | Integrate: Mimo tab header (mood follows the chat stream/tool/done), Map sheet "Mimo picks" header, Mimo tab icon in RootTabView, credits line in Me | lead | done |  | Mimo intro avatar + a toolbar avatar during chats (mood: thinking while a tool runs / before text, talking while streaming, listening while typing, happy after a reply); avatar beside "Mimo picks" in the Map sheet (thinking only until the first pick shows); Mimo tab icon = MimoAvatarIcon; DEBUG `-RyokoAvatarGallery 1`; Me → Credits links bloub (MIT) |
| W8.4 | UI refine pass (design #48, #49): Map search/Layers, gradient on more tabs, Mimo header + history sidebar, inline phrases, places card, status pill and calmer streaming, Show tilt, Translate language pills | lead | done | `ui-refine`, PR #2, merged `cd4365f` | Simulator-checked (screenshots); on the iPhone 18 Pro Max for hand testing (tilt, sidebar swipes, keyboard scroll). Prompt change (phrases after their sentence) is live: the main server was restarted after the merge. Merge check: every line the PR deletes was traced to its commit; none of T2.2–T2.6 is lost (only the old keyboard-button spot, now in the status row, and a stale Me comment). Commits cde32aa, 7102a20, ea2ab70, 40bd4d6, ce23d5a (search line held 2.5 s, one source pill per site), 09d07d3 (Translate language pills beside the mic; Type's keyboard button moved to the status row) |
| W8.5 | Mimo tab feedback from the phone (design #50, #51): a sidebar swipe across the places card opened the Map; the tab bar shrank on scroll; the composer took room while not typing | lead | review | `main` | Swipe: the simultaneous drag stays (scrolling and text selection unaffected) and taps in the chat (places, Show on map, phrases, starters, header buttons, retry) are ignored while a sideways swipe moves the chat and for 0.4 s after. Tab bar: `.never` on every tab. Composer: corner button when not typing (Stop while replying); tap opens it with the keyboard, scrolling toward the end opens it, scrolling back or closing the keyboard tucks it away; open in a new chat or with a draft. Simulator-checked (empty, tucked, opened with keyboard); swipes and scroll-to-open need hand testing on the iPhone. End of the chat: an animated scroll cut short by the keyboard left the scroll phase at `.animating` and the chat stopped following, so a reply's end (its sources) could sit under the composer or tab bar. The chat now keeps a follow flag (only your drag turns it off; letting go at the end turns it back on), follows any content or inset change, and re-checks 0.3 s and 1 s after a reply ends. The end marker includes the bottom margin. Sources show once the reply is over, always last. Checked on the simulator: tucked composer, keyboard up, reopened chat. Tilt: flips later (#52), 15°/35° instead of 30°/50°; turn-rule harness 23/23. Round 2 from the phone: (a) the sidebar could stick partway after a little scrolling, because the SwiftUI drag inside the scroll view sometimes never ended. It's now a UIKit pan (`MimoSidebarSwipe`, recognized alongside everything) that always ends, plus a 0.35 s watchdog and a reset when a scroll starts. (b) The composer auto-open was glitchy: the `.sizeChanges` scroll anchor shifted the chat as the bar came and went, and it opened mid-scroll under the finger. The anchor is removed (`followsEnd` keeps the end in view, the keyboard included). The composer now tucks away after scrolling back 40 pt, at most once per drag, and only opens when a scroll comes to rest at the end. Round 2 landed as W8.14 (`c1f2f82`) |
| W8.6 | Map redesign and Nearby removal (design #53, §4.3, §4.7, §4.11) | agent:map | done | `worktree-agent-abfd3c3fca91acd3a`, merged `32363d1` | Tabs are Translate · Map · Mimo · Me. Every place tap opens its card in the Map sheet and never changes the situation; only I'm here (within 300 m) or Preview do. Card: Directions, Taxi, Allergy (conditional), Ask Mimo; I'm here / You're here or Preview; why, what to say, tips, address; redacted, Try again, saved-card fallback. Sheet rests at 45%; a card opens almost full with the pin centred in a strip of map (your location framed within 1 km). Header "You're at <place> ›", "Near you", subtle Previewing badge and Back to here. Live Activity links open the current place's card (`ryoko://nearby` → map). PlaceCardCache and PreviewTimeSheet moved to `Map/`; NearbyView, mini map, quick cards and banner deleted. Commits 5b775ef, 09aaa0f, f5d2ee1 (framing from the measured layout, header control beside the title), 06ae4a0 (comments) |
| W8.7 | Picks grounding: Mimo picks come from the real places nearby (design #54, §6.5, §7.5) | lead + agent:server | done | contracts `d376313` on `main`; server `worktree-agent-a0ead7e00edead475`, merged `e1cdca8`; iOS `b2393b7` (merged with W8.6) | Contract: optional `DiscoverRequest.nearby` (≤ 40). iOS `MapDiscoverNearby`: POIs within 1.5 km (3 km when fewer than 12), nearest first. Server: prompt picks 5–8 from the list (names copied, listed localName, independent spots), at most 2 well-known extras; unlisted picks beyond that dropped (name match ignoring case, spaces, punctuation, or containment); under 5 → one retry; cache key adds a 16-hex hash of the sorted names; dc-4. Why: at SFU 5 of 6 picks were dropped as misses. Commits d376313, 30db9b7, b2393b7 |
| W8.8 | About me: `Profile.aboutMe`, edited in Me (design #55, §4.10, §5, §7.2) | agent:about-me | done | `worktree-wf_3dfe753f-d45-1` (contracts + server), `-2` (iOS), merged `ec1c737`, `f3ed4e5`, `696a76b` | Optional, 1–500 chars, absent when empty; canonical JSON leaves it out, so old version hashes stay valid (parity test pins seed + aboutMe). promptProfile adds it last for Mimo, place cards and discover, with ABOUT_ME_RULE; "aboutMe" in a because line counts as a leaked field name (pc-5). Me: About me at the top, 3–8 line field saved ~1 s after typing pauses, footer "Mimo uses this when it helps", count from 400; Redo survey keeps it. check-contracts compares hashes with canonical.ts. Commits e7afad2, 5f96de8 |
| W8.9 | Mimo relevance: allergies and diet come up only around food (design #56, §5) | agent:about-me | done | `worktree-wf_3dfe753f-d45-3-fix`, merged `696a76b` | Mimo prompt: allergies and diet are hard limits applied quietly, mentioned (or an allergy phrase added) only when the message is about eating or drinking or the traveller asks; other preferences shape answers only where they fit, never listed back; no unasked food or drink stops. Live eval on DeepSeek V4.1 Flash: non-food follow-ups 0 of 4 mention allergies, "what should we do tonight" 1 of 5 (was 3 of 3), food questions 4 of 4 keep the hard limit with a safe phrase. Commits e7afad2 (prompt), 329fd18 |
| W8.10 | Filter removal: the allergen word filter is gone (design #57, §5, §6.2, §6.4, §7.4) | lead + agent:server | done | `ca83135` on `main`; `worktree-wf_bbcc6949-058-1`, merged `2bc6eeb` | User decision. `safety.ts` deleted: it dropped real allergy phrases (アレルギーがあります。卵と乳抜きでお願いします。). Mimo phrases, place-card phrases and tips, and discover picks aren't word-checked; allergies and diet stay hard limits in the prompts. The only phrase drop is the cap of 4 per reply, logged with its text. pc-6, dc-5 (discover also gets ABOUT_ME_RULE). Evals lose the allergen review column; a Mimo regression test keeps the egg-and-milk phrase. Commits ca83135, d6bd134, ac17fdb (the safety-words rule without its rationale, which the model repeated back) |
| W8.11 | Thinking levels per skill (design #58, §6.3) | lead | done | `main` | Dev `server/.env`: `MODEL_MIMO_REASONING=high`, `MODEL_PLACE_CARD_REASONING=low`, discover off, `MIMO_TIMEOUT_MS=60000` (code defaults stay off and 28 s). A probe found low, medium and high use similar reasoning tokens (on/off in effect). With thinking on a skill gets 4,096 extra output tokens (Mimo replies stopped with `length` without them); the model key in cache keys gains `@<level>`. Discover with thinking took over 25 s and timed out, so it stays off. Commits e02ed8b, 4fb257b |
| W8.12 | Mimo header: compact, one-line pill (design #59, §4.9) | agent:mimo-header | done | `worktree-wf_bbcc6949-058-2`, merged `b51bc12` | 64 pt avatar (was 82), 8 pt higher, clear of the Dynamic Island; one glass pill "<place> · <local time>", the name truncating before the time; no pill before there's a place; 44 pt sidebar and New chat centred on the avatar; VoiceOver reads one heading "Mimo, <place>, <time>". Pill and buttons stop growing at accessibility sizes. Commits bf5e356, 119dc23 |
| W8.13 | Place thumbnails: Look Around previews (design #60, §4.7, §4.9) | agent:thumbnails | done | `worktree-wf_bbcc6949-058-3`, `-4-fix`, merged `180583c`, `9673a23` | `PlaceThumbnail` / `PlaceThumbnailLoader` in `Map/`: 56 pt Look Around snapshot in Map list, pick and search rows and Mimo's places rows (plan stop number as a corner badge); satellite tile with a monochrome pin where there's no scene; category icon while loading. ≤ 2 loads at once, queued work dropped when a row disappears, 60 s pause on throttle; memory + disk cache (Caches, 14 days, key v2), and only real results are kept, so a temporary failure retries. Hidden at accessibility sizes (Mimo rows too). Map card: 150 pt LookAroundPreview opening the full viewer. MapKit has no public listing-photo API (iOS 27 SDK). Commits c741260, dd62943, 923cd05 |
| W8.14 | Mimo sidebar/composer fix (W8.5 round 2) | lead | done | `main`, `c1f2f82` | The sidebar swipe is a UIKit pan (`MimoSidebarSwipe`) that always ends, plus a 0.35 s watchdog and a reset when a scroll starts. The `.sizeChanges` scroll anchor is removed; the composer tucks away after 40 pt back, at most once per drag, and opens only when a scroll comes to rest at the end. Design §4.9 already describes it |
| W8.15 | Place photos from Foursquare (`POST /v1/place-photos`): photo first, then Look Around, then satellite; "Powered by Foursquare" | agent | parked | `feature/foursquare-photos` (bc8bced), not merged | Built and tested (contracts 43, server 150, iOS checks 239). Not merged by the user's choice: the account had no credits for Premium `photos` calls (HTTP 429), and Foursquare's pay-as-you-go terms allow caching only place and photo ids, while the branch caches photo urls for 30 days. Main keeps the Look Around thumbnails (W8.13). To revive: add credits, decide the caching question, merge the branch |
| W8.16 | List rows back to category icons (Map picks, nearby, search; Mimo's places card with stop numbers); the place card keeps its Look Around preview (design #61) | lead | done | `main` | Reverted the row thumbnail commits' changes to `MapPlaceList.swift` and `MimoPlacesView.swift` (from 696a76b); `PlaceThumbnail` and its loader stay for the card. Simulator-checked on the iPhone 17 Pro Max: list, card, Mimo plan |
| W8.17 | Map navigation (design #62): rests at 60%, cards open in place with ‹ Back (scroll kept), empty-map tap goes back, pin framed above the sheet, collapsed card hides Look Around, 1:1 drag | agent | done | 0bb9c10, 925525a | Simulator-checked (resting, swap, back with scroll kept, large, collapsed, dark, AX5). Real drags and the empty-map tap need the phone. Pull-down-from-scroll-top to shrink not done (fights ScrollView bounce). The logo and legal notice follow the sheet (snapped sizes) while the map holds still: the top inset moves with the bottom one so MapKit never re-centres (the map reaches above the screen), insets change in one step, and framed regions settle into a plain camera |
| W8.18 | Mimo places resolve reliably (design #63): local-name fallback in the resolver, retry after a MapKit throttle, more kind-of-place words and romanized pairs ("Chuo" = "Central"), Mimo copies `nearby` names | agent | done | `ws/mimo-place-reliability` | Two of seven places went missing in a Shinjuku chat ("Tokyo Metropolitan Government Building", "Coffee Edinburgh"): MapKit found both under other names and the matcher rejected them. Now found, plus "…Observatory" and "Shinjuku Central Park" (MapKit: "Shinjuku Chuo Park"). A Mac MapKit probe with Mimo's real names finds 7 of 9; the misses are a café in Ginza and a generic katakana name. Simulator (iPhone 18 Pro Max, Tokyo preview, real GMI): 2 of 2, then 2 of 3, the miss a Shibuya café 3.5 km away (Mimo suggesting too far, rightly dropped). Matcher checks 40/40, server 122 tests, app builds |
| W8.19 | The profile only where it matters (design #64): Mimo prompt rewrite (no example allergens, ordering-only allergy rule, never its own), place cards allow allergy/diet/taste/favourites bases only at food places, pc-7 | agent | done | `main` | Before/after with real GMI (Shinjuku, peanut allergy, fruit tea favourite): Mimo's unasked allergy mentions 5/18 → 1/28, preference mentions 1/18 → 0/18; non-food cards' profile phrases 7/12 → 0/12; ordering questions and food cards keep their allergy phrase. Server 122 tests. Place cards regenerate (pc-7) |
| W8.20 | Thinking-orb loading where Mimo is working (design #65): `ThinkingOrbs` package; `MimoWorking` card and `ArrivingStack` (card dissolves into the first card, the rest rise in turn) for picks, place cards and Mimo's places; small orb rows for more picks and the allergy card; orb while locating | lead | done | `213cf9d` | Package pinned at 1.1.0 in the app target only (not the widget). Simulator-checked on the iPhone 17: locating → picks → rows rising with "Picking more places"; a slow place card (`-RyokoMapCardLatency 3`) dissolving into its phrase cards; a Mimo reply's places card |
| W8.21 | Map fixes (design #66): cards open at full height; Mimo picks pinned by default; Food & drink and Washrooms as pins from a search of the visible map (quarters, 8 × 8 thinning); Ask Mimo opens a new chat asking about the place | lead | done | `22140e2` | Simulator-checked on the iPhone 17: picks as orange pins; Washrooms spread across Shinjuku incl. Yoyogi park; Food & drink spread; a pick's card at full height; Ask Mimo logs a new chat and sends "Tell me more about Omoide Yokocho." with the subject |
| W8.22 | Blue wash that reacts (design #67): `AmbientGradient` (mesh) replaces the time-of-day gradient; one blue, more saturated in light mode; drifts while Mimo streams or Translate connects, swells with the mic level while listening; still under Reduce Motion | agent | done | `main` | Simulator-checked (iPhone 18 Pro Max): Mimo streaming a reply (drifting periwinkle), Translate listening to the canned script in light and dark |
| W8.23 | Translate manual turns (design #68): the pills say who's speaking while listening, a tap hands over; Soniox `finalize` at each hand-over (2 s fallback); translations follow the turn that heard their source language; "Hearing Chinese? Tap Chinese to switch" hint; `language_hints_strict` | agent | done | `main` | Turn-rule harness 29/29 (6 new manual cases). Simulator: canned zh conversation with hand-overs, light and dark. Not yet tried with the real microphone on a phone |
| W8.24 | Me redesign (design #69): avatar header, allergy card at a glance, profile summary, About me, Settings sub-screen | agent:me | done | `main` | New `MeHeader.swift` (avatar, picker sheet, chips flow layout), `MeGlance.swift` (allergy card at a glance, profile rows), `MeSettingsView.swift` (the old sections, unchanged behaviour); `MeView` routes with `MeRoute` (settings, editor). The avatar is `@AppStorage("RyokoMeAvatarSymbol")`, not a profile field. `AllergyCardSection` in `Show/` is no longer used by Me (its debug hook `-RyokoMeShowAllergy` moved to the new card). Simulator-checked on an iPhone 18 Pro (fixture mode, Tokyo preview): light and dark home, Settings scrolled to the developer section, avatar picker |
| W8.25 | Server activity view at `/admin`, one terminal-style screen (top bar, Now, Models, Activity, Detail, System): Mimo's model up top; live "Right now" (thinking text, tool calls with arguments and results, the reply streaming, running skill calls); feed of the last 40 replies and skill calls with cost and cache source; settings panel (models, reasoning, budget, fixture pacing) and actions (clear cache, reset spend, forget chats); local only | lead | review | `ws/w7-dashboard` | Settings are env overrides run through `configFromEnv`, in memory until restart; a model change rebuilds the skills, keeping the cache and budget. Mimo's thinking and tool arguments come from an `onRunEvent` hook in `MimoSessions`; each reply records the model it ran on (per-chat models, W6 model picker). Funnel (forwarded) and non-loopback hosts get 404; writes need `X-Ryoko-Admin: 1`. Server 130 tests (8 new). Checked in headless Chrome (1440×900, 1280×760) and ego-browser (row detail, transcript, filter) with a scripted run paused mid-reply |
| W8.26 | Mimo model picker (design #73): `GET /v1/mimo-models` (server catalog in `src/llm/catalog.ts`; Gemini via pi-ai's google provider once `GEMINI_API_KEY` is set), `model`/`effort` on Mimo messages, a chat switches model keeping its history; app: `MimoModelStore` + `MimoModelButton` (level button in the composer, popover with model menu, reset and a level slider) | agent:mimo-models | review | `ws/w6-mimo-models` | Contracts changed at the lead's request (W1 to review). Server 134 tests (12 new); contract check 236/236. Live on GMI: DeepSeek → GPT-6.1 Sol mid-chat kept the history (21.6 s at medium); GPT-6 Luna took 56 s once at Instant (GMI's GPTs run 6–30 s a turn); Kimi K3 dropped (cut off at the token limit). Codex UI check on the iPhone 18 Pro Max, two rounds, light and dark: popover, slider colours per level, in-popover model list with the checkmark on the right, reset, a reply on Luna, the button centred on Send. Gemini live (key in `server/.env`): a chat moved DeepSeek → Gemini 3.8 Flash (4 s, knew the earlier places) → 3.5 Flash-Lite (a phrase), and Flash-Lite planned with `show_places`; fresh Gemini 3.8 Flash chats then failed on Google's 503 "high demand" (2026-10-04 10:40), which now reaches the app as Google's sentence instead of nested JSON |
| W8.27 | Ask Mimo place preview (design #72): the place's map preview above the first message opens its card on the Map; the "About" chip and `router.mimoSubject` are gone, the subject lives on the transcript | agent:mimo-models | review | `ws/w6-mimo-models` | Simulator-checked on the iPhone 18 Pro Max against real GMI (`-RyokoMimoSubject 1`): preview, reply, no chip |

## 3. Tier 2

| # | Task | Owner | Status | Branch/PR | Notes |
| --- | --- | --- | --- | --- | --- |
| T2.1 | Speak: ElevenLabs client (restricted key via the MLH code or Starter), audio cache, `AVSpeechSynthesizer` fallback, `.playback` session, stop Translate first | | todo | | |
| T2.2 | Live Activity: attributes in `Shared/`, lock screen, Dynamic Island, deep link to Show, one at a time | wf:T2 | done | `worktree-wf_be317781-a93-1` | Starts on confirm/preview (only where there are phrases), one at a time, placeholder → real top phrase (≤ ~320 B), 2 h end + staleDate; lock screen + Dynamic Island (category symbol + short name, expanded phrase); ryoko://show deep link opens Show (cold start too); waits 2.5 s for profile edits to settle. Real tap on the phone still to try |
| T2.3 | Onboarding survey (7 pages) + editing in Me + redo survey | wf:T2 | done |  | 7-page survey on first launch (skips → null), DEBUG 'Use demo profile'; Me: every section editable live (text saves after a 1 s pause), home base via search or pick on map, Redo survey; profile.version updates so the server regenerates cards |
| T2.4 | Translate Type mode + tap-to-edit turns + `/v1/translate` | wf:T2 | done |  | Type mode with a live preview (500 ms pauses, stale requests cancelled), Done adds the turn; tap your turn (panes or History) to edit and re-translate; /v1/translate on GMI ~1.6–2.2 s cold, cached |
| T2.5 | Bottom Listening accessory + tab-bar minimize | wf:T2 | done |  | App-wide TranslateModel; 'Listening · English ⇄ Japanese' accessory with stop on other tabs; tab bar minimizes on scroll on Nearby and Mimo only (design §3) |
| T2.6 | Server-minted Soniox keys (`/v1/soniox-key`) | wf:T2 | done |  | /v1/soniox-key mints single-use 60 s keys (3600 s session cap, 10/min); each session uses one; falls back to the bundled key only when the server can't mint (kept for the hackathon, #46) |
| T2.7 | Switch to Gemini: billed project + spend cap, `gemini-3.8-flash` (reasoning low), Flash-Lite for translate, rerun evals | | todo | | Required before submission (Gemini track). W8.26 already offers Gemini 3.8 Flash and 3.5 Flash-Lite in Mimo's picker once `GEMINI_API_KEY` is set |

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
| 2026-10-03 | Tab bar never minimizes; Mimo composer tucks into a corner button when not typing | user (phone testing) | yes (#50, #51) |
| 2026-10-03 | Tilt flips later: face-to-face below ~15° from flat (was 30°), upright above ~35° (was 50°); Translate and Show mode | user (phone testing) | yes (#52) |
| 2026-10-03 | Mimo sidebar swipe is a UIKit pan that always ends; the composer opens only when a scroll comes to rest at the end (W8.14) | user (phone testing) | yes (§4.9, already there) |
| 2026-10-03 | Map-first places: the Nearby tab is removed (tabs Translate · Map · Mimo · Me); every place opens its card in the Map sheet without changing the situation; I'm here or Preview on the card; the sheet rests at 45%; the Live Activity opens the current place's card (W8.6) | user | yes (#53; §2, §3, §4.2–§4.7, §4.11, §6.2, §8.2, §9.3, §12.3) |
| 2026-10-03 | Mimo picks come from the real places nearby: `DiscoverRequest.nearby` (≤ 40), unlisted picks capped at 2, cache key hashes the nearby names (W8.7) | at SFU 5 of 6 picks were dropped as misses | yes (#54; §6.5, §7.5) |
| 2026-10-03 | `Profile.aboutMe`, edited in Me, background for Mimo, place cards and discover with ABOUT_ME_RULE (W8.8) | user | yes (#55; §4.10, §5, §7.2) |
| 2026-10-03 | Mimo brings up allergies and diet only around eating or drinking, other preferences only where they fit, and adds no unasked food stops (W8.9) | user (review: unasked food stops with peanut phrases) | yes (#56; §5, §4.9) |
| 2026-10-03 | The allergen word filter is removed; allergies and diet are hard limits in the prompts only; the only phrase drop is the cap of 4 (W8.10) | user (it dropped real allergy phrases, leaving gaps in replies) | yes (#57; §5, §6.2, §6.4, §7.4) |
| 2026-10-03 | Per-skill thinking on GMI: Mimo high, place cards low, the rest off; +4,096 output tokens when on; the level is in the model key; Mimo timeout 60 s (W8.11) | Mimo replies cut off with `length`; discover timed out with thinking | yes (#58; §6.3, §6.4, §7.4) |
| 2026-10-03 | Compact Mimo header: 64 pt avatar, one "<place> · <time>" pill (none before a place), 44 pt buttons centred on the avatar (W8.12) | user | yes (#59; §4.9) |
| 2026-10-03 | Place thumbnails: Look Around snapshots in Map and Mimo rows (satellite fallback), a Look Around preview on the place card (W8.13) | user; MapKit has no listing-photo API | yes (#60; §4.7, §4.9) |
| 2026-10-03 | List rows back to category icons; Look Around stays in the place card only | user | yes (#61) |
| 2026-10-03 | Map sheet rests at 60%; Apple Maps-style card navigation with Back; 1:1 drag | user | yes (#62) |
| 2026-10-04 | Resolver's local-name fallback and throttle retry; Mimo copies `nearby` names (W8.18) | user (Mimo's places went missing) | yes (#63; §4.7) |
| 2026-10-04 | Mimo and place cards bring up allergies and preferences only where they matter (W8.19) | user | yes (#64; §4.9, §5) |
| 2026-10-04 | The wash is one blue and reacts to Mimo working and to the voice in Translate (W8.22) | user | yes (#67; §9.2, §9.3) |
| 2026-10-04 | Translate's turns are manual: tap a language to hand over (W8.23) | user (auto switching too sensitive) | yes (#68; §4.8) |
| 2026-10-04 | Me is a styled home (avatar, allergy card at a glance, profile summary, About me) with the rest in Settings (W8.24) | user | yes (#69; §4.10) |
