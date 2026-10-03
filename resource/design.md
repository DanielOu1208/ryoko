# Ryoko: product and design decisions

Status: locked for the hackathon, 2026-10-03. Revised the same day after an audit of every open question. §13 lists each decision and where it came from.
This is the source of truth for what Ryoko does and how it looks. An agent building one part should read its feature section, §6 (Mimo and the server), §7 (contracts), §9 (styling) and §12 (build setup).
Build progress is tracked in [`implementation-tracking.md`](implementation-tracking.md). Update it as you work.

## 1. The idea

Ryoko knows where you are, what time it is there, and who you are, and uses that to hand you the right words in the local language before you need them.

You walk into a tea shop in Shanghai at 3 PM. Ryoko already shows the order you'd want, written in Chinese, with a line saying why it picked it. You show it to the staff. When they answer, Translate takes over.

**Mimo** is the agent behind it: a calm local friend who writes the phrases and tips, finds places worth going to, plans a few hours, and answers questions. Mimo is a core part of the product, not a side feature.

Principles that settle trade-offs:

- **Phrases are the hero.** The thing you'll say next is the biggest element on the main screen. Any phrase Mimo suggests anywhere can be opened as a full-screen card to show someone.
- **Personalization is visible.** Every suggestion carries a short "because…" line that names the input behind it ("you like it less sweet").
- **Mimo names, the device locates.** Mimo names places and explains why. The phone finds them with MapKit. The agent never sends coordinates.
- **Translate is just translation.**
  - Soniox handles speech, with nothing layered on top.
  - Typed or edited text goes through one short translate call on our server (tier 2).
  - No reply chips, no notes, and no read-aloud for now.
- **Native first.** Use system components, a native tab bar, native navigation bars and sheets, SF Pro and SF Symbols. Nothing custom where iOS already has a version.
- **Looking ahead doubles as demo mode.** Any place at any time can be previewed, so nothing depends on where we physically are.
- **Finish before sponsors.** Tier 1 works end to end before tier 2, and the core works end to end before any after-core sponsor work starts.

## 2. Scope

Languages: **Mandarin (Simplified, `zh-Hans`) and Japanese (`ja`)** are first-class: tuned prompts, romanization, fixed phrases and allergy templates. Other languages are best effort.

| Tier 1: working core (build now) | Tier 2 (next) | After core |
| --- | --- | --- |
| App shell: five tabs, theme, gradient, situation state (live + preview), profile store with a bundled seed profile | Speak: ElevenLabs, audio cache, on-device fallback (§8.1) | Tiger Data: durable sessions + trip memory (§8.3) |
| Place awareness (nearest three + confirm) and look-ahead (search or pin, plus date and time) | Live Activity: lock screen + Dynamic Island (§4.11) | Snowflake: travel guides that Mimo cites (§8.4) |
| Now: phrases with "because…", tips, quick cards, Mimo picks nearby, mini map | Onboarding survey (§4.1) and editing in Me | Translate read-aloud |
| Show mode (no Speak yet) | Translate Type mode and tap-to-edit turns, `POST /v1/translate` | Menu scan with allergen flags |
| Allergy card (reviewed templates) and taxi card | Bottom "Listening" accessory and tab-bar minimize | Offline pack for pinned places |
| Map: search, place sheet, Preview, layers incl. Hidden gems and From Mimo | Server-minted Soniox keys | Listen mode (announcements, tour guides) |
| Translate: voice, face-to-face tilt, turn history | Switch the model from GMI to Gemini (§6.3), before submission | |
| Mimo tab: chat, phrase blocks, places, plans for a few hours, web search with sources | | |
| Agent server: `place-card`, `mimo`, `discover`, `allergy-card` | | |

**Not doing:**
- reply chips and context notes in Translate
- ElevenLabs voice cloning (stock voices only)
- a politeness toggle
- pronunciation checks
- a home screen widget
- a parking layer
- social or sharing
- Google's agent SDKs (the model runs inside pi)
- Apple's Translation framework
- full itinerary planning: multi-day trips, routing, bookings ("plan a few hours" is in)

**Cut for now:**
- live-place heuristics beyond "nearest three + confirm"
- the OSM Overpass washroom fallback
- direct editing of the translation field
- `MeshGradient`
- opening hours (MapKit exposes none)

## 3. Navigation

- A native SwiftUI `TabView` with five tabs. On iOS 26 and later this renders as the standard Liquid Glass tab bar. No custom tab bar.

  | Tab | SF Symbol | Purpose |
  | --- | --- | --- |
  | Now | `location.fill` | Where you are (or are previewing) and what to say there |
  | Map | `map` | Search, layers, place sheets, Preview |
  | Translate | `character.bubble` | Live two-way translation |
  | Mimo | `bubble.left` (an avatar later) | Chat with Mimo: questions, places, plans |
  | Me | `person.crop.circle` | Profile and settings |

  The `translate` symbol is reserved for Apple's own Translate app, so it isn't used.
- Native navigation bars with large titles (`navigationSubtitle` for secondary lines), native sheets with detents, and a native `fullScreenCover` for Show mode.
- iPhone only, portrait only. All rotation (Flip, face-to-face) is done in SwiftUI.
- Tier 2: `tabBarMinimizeBehavior(.onScrollDown)` on Now and Mimo. While Translate is listening, a `tabViewBottomAccessory` shows "Listening · English ⇄ Chinese" with a stop button.

## 4. Features

### 4.1 Onboarding survey (tier 2)

Until the survey is built, a bundled **seed profile** (§10) drives personalization, so tier 1 is still fully personalized.

The survey runs on first launch. It takes about 45 seconds, every page can be skipped, and everything is editable later in Me.

1. **Where you're from:** nationality and home language.
2. **Languages you speak.**
3. **What you don't eat:** chips (vegetarian, vegan, halal, kosher, no pork, no beef, gluten-free, lactose-free) plus free text.
4. **Allergies:** chips (§7.2's allergen list) plus free text, each with a severity (mild / serious / life-threatening).
5. **Your usual:** favourite foods and drinks (chips plus free text). Native sliders for sweetness and spice (5 steps; the middle is "as usual").
6. **This or that:** four pairs of big tappable cards: early bird / night owl, local favourite / my usual, save / splurge, quiet / lively.
7. **Where you're staying** (optional): the home base for the taxi card. Enter it with a search field (`MKLocalSearchCompleter`) or "Pick on map".

A skipped page is stored as `null`, and "none" as an empty list (§7.2).

Built from native parts: a paged `NavigationStack` with large titles, bordered/prominent buttons as chips, system sliders, and a glass-prominent Continue button.

### 4.2 Place awareness and look-ahead

- **Local language** is worked out on the device, never by the agent.
  - The place's region code maps to a language through CLDR likely subtags: CN → `zh-Hans`, JP → `ja`, TW and HK → `zh-Hant`.
  - A small override table handles exceptions: Quebec → `fr`; Hong Kong speech (Cantonese) is flagged as unsupported.
- **Live:**
  - CoreLocation plus `MKLocalPointsOfInterestRequest` within about 50 m.
  - Now shows the three nearest places to pick from, with a one-tap confirm, because indoor GPS is fuzzy. A refresh control re-checks.
  - No automatic "clearly closest" detection and no movement re-checks (cut).
- **Look-ahead:**
  - Search on the Map tab, tap any POI, or long-press anywhere. Each opens a place sheet with **Preview**.
  - Preview offers a date and time picker in the place's time zone (`MKMapItem.timeZone`; fall back to reverse geocoding, then the device zone):
    - range: now to 7 days ahead
    - quick chips: Morning 9 AM, Afternoon 3 PM, Evening 7 PM
  - Content is generated only once a time is committed.
  - While previewing, Now shows a banner like "Previewing · Heytea, Jing'an · Sat 3:00 PM" with **Back to here**. Tapping the banner reopens the picker.
- **Everything follows the active situation**, live or previewed: the Now card, Mimo picks, Translate's language pair, Mimo's context, the Live Activity and the gradient. The device always sends the situation's local time with its offset (§7.1). The server never uses its own clock.

### 4.3 Now tab

Now is first about the place you're at (or previewing). Top to bottom:

1. **Header:** city · local time (the place's time, not the device's). Below it, the place name as a large title and the category, plus the confirm/change control.
2. **Phrase cards (2–3).** Each card has:
   - the local script (the largest text on screen)
   - romanization: pinyin for Chinese, romaji for Japanese; on by default, can be turned off in Me
   - the gloss in your language
   - a "because…" line of about 8 words at most

   Actions: **Show** (opens Show mode). **Speak** arrives in tier 2.
3. **Cultural tips (1–2),** framed against your nationality where that helps ("No tipping, same as… / unlike Canada").
4. **Quick cards row:** Allergy card, Taxi card.
5. **Mimo picks nearby:** 3–5 places from `discover` (§6.5) that fit this time of day and your profile, each with a one-line why. They're generated in the background whenever the situation changes. Tapping one opens its place sheet.
6. **Mini map tile:** live and non-interactive. Tapping it opens the Map tab centred here.

Special cases:
- **No place known yet:** Now shows "Where are you?" with nearby places to pick and general tips for the city.
- **The local language is one you speak** (e.g. live in Vancouver for an English speaker): no phrase cards. Now shows the header, tips, Mimo picks and a prominent **Preview a place** button that opens Map.
- **Loading:** native `.redacted(reason: .placeholder)`, not a custom shimmer.

### 4.4 Show mode

A full-screen cover meant to be handed to someone else. It takes a `ShowContent` value, never raw strings:
- `.phrase(Phrase)`: from Now, place sheets and Mimo's phrase blocks (§6.2).
- `.allergy(lines)`: a scrollable stack. Each line is in local script at `.title` with your language below at `.body`, and the severity is always written in words.
- `.taxi(name, address, snapshot)`: the local name at `.largeTitle`, the address at `.title2`, the fixed phrase, then the map snapshot.

For all of them:
- Plain system background (white or black), no gradient. Contrast comes first.
- A phrase's local script is as large as fits (`minimumScaleFactor`), with romanization below it in small type and the gloss smallest, at the bottom.
- Buttons: **Flip** (rotates 180° for someone across a counter) and **Done**. **Speak** comes in tier 2.
- Screen brightness goes to max and the idle timer is off while it's open. Both are restored on close.

### 4.5 Allergy card

- A Show-mode card in the local language that states each allergy and how serious it is, and asks whether the dish contains it, with your language underneath.
- **Chip allergens use reviewed templates** for `zh-Hans` and `ja` at each severity. They live in `contracts/allergy-templates.json`, are bundled in the app and work offline. Wording:
  - Mild: "Please avoid X if possible."
  - Serious: "I must not eat X, including X oil or sauces containing X."
  - Life-threatening: "Even a trace of X can be life-threatening; please check every ingredient and use clean utensils."
- **Free-text allergens** go to `POST /v1/allergy-card` and are marked "not reviewed" on the card.
- The allergy list is cached per (language, allergen and severity pairs).
- Reachable from Now's quick cards and from Me.
- A Chinese reader and a Japanese reader must check the templates before they are trusted (§11).

### 4.6 Taxi card

- A Show-mode card for the home base or any place (from its place sheet). **There's no LLM in the display path.**
- It shows:
  - **Address:** `MKReverseGeocodingRequest` with `preferredLocale` set from the situation's language (e.g. `zh_Hans_CN`). It falls back to the device-language address. (`CLGeocoder` is deprecated in iOS 26.)
  - **Place name:** the map item's name if it's already in local script. Otherwise `placeNameLocal` from that place's place card (§7.4). The home base stores its own `localName` and `addressLocal`.
  - **Fixed phrase:** `zh-Hans` 请带我去这里, `ja` こちらまでお願いします ("Please take me here").
  - A small `MKMapSnapshotter` image, with its map attribution left visible.

### 4.7 Map tab

- MapKit with the user's location, plus `.searchable` with `MKLocalSearchCompleter` suggestions. Queries can be in English or local script ("Heytea Jing'an", "喜茶 静安"). Picking a result moves the camera and opens the place sheet.
- **Interaction:**
  - POI tap: `Map(selection:)` with `MapSelection`, then `MKMapItemRequest(feature:)`.
  - Long-press: a `UIGestureRecognizerRepresentable` and `MapReader` to get a coordinate.
- **Layer toggles** in a native menu:
  - **Food & drink:** a MapStyle POI filter (restaurant, cafe, bakery, …).
  - **Washrooms:** a MapStyle POI filter on `.restroom`. Coverage in China is unknown (spike, §11).
  - **Hidden gems:** Mimo's `discover` picks for the area, resolved with MapKit and cached per area.
  - **From Mimo:** places and plans from the Mimo tab. Plans show numbered pins. The layer stays until it's cleared or a new chat starts.
- **Resolving names Mimo gives:**
  - Resolve one name at a time with `MKLocalSearch` (`regionPriority .required`, a 1.5–3 km region). In China, try the local name first.
  - Take the nearest POI within 5 km and silently drop misses.
  - Cache by (normalized name, area). Keep under MapKit's throttle (about 50 requests a minute).
- Every Shanghai coordinate comes from MapKit. Never mix in coordinates from other sources: China's offset coordinate systems put them hundreds of metres off.
- **Place sheet** (medium/large detents) holds:
  - the same phrase cards and tips as Now (generated on open, cached)
  - **Preview** with the date and time picker
  - **Taxi card**
  - **Ask Mimo about this place**

### 4.8 Translate tab

Translate is translation only. Speech goes through Soniox `stt-rt-v5` in `two_way` mode, with language identification and endpoint detection on.

- **Language pair:** defaults to (profile home language, local language of the active situation), e.g. English ⇄ Chinese in Shanghai. It can still be picked by hand. It never changes mid-session.
- **Turns:**
  - Translate keeps an in-memory list of turns: id, speaker (me / them), original, translation, source (voice / typed), and whether it was edited.
  - The panes show the latest turn. A **History** toolbar button opens a sheet listing every turn.
  - A new turn starts when at least 2 final tokens (or 2 CJK characters) arrive in the other language. The panes never clear before the new turn has text. Soniox's `<end>` commits a turn to history.
  - Listening stops after 2 minutes of silence or when the app goes to the background. History isn't persisted.
- **Upright layout** (phone held normally): what was said on top, the translation below.
- **Face-to-face layout** (phone flat or tilted forward):
  - The **top half is rotated 180°** toward the other person and always shows *their* language.
  - The **bottom half** always shows *yours*.
  - When you speak English, your words sit at the bottom and the Chinese translation faces them at the top. When they speak Chinese, their words face them at the top and the English translation sits at the bottom for you.
  - **Detection:** CoreMotion gravity (no permission needed; only testable on a device).
    - The layout switches when the phone gets within about 30° of flat or its top edge tips away.
    - It switches back when the phone is raised past about 50°.
    - Hysteresis plus a short debounce stops flicker.
  - A toolbar button forces either layout, for reliability and accessibility.
  - A haptic plays on each switch. The rotation is animated with `.smooth`, or a crossfade when Reduce Motion is on.
- **Type and edit (tier 2):**
  - **Type mode:**
    - The bottom bar has the big mic button and a smaller keyboard button. You type in your language.
    - The translation updates on **Done**, then on typing pauses of about 500 ms.
    - It comes from `POST /v1/translate`, with the active situation passed along so wording fits the place (e.g. 少糖 at a tea shop). Requests that are out of date are cancelled.
    - While the keyboard is up, the big panes slide off screen and only a compact preview of the translation shows above the text field.
    - **Done** adds the turn and shows the translation full size, flipped if face-to-face.
  - **Editing:**
    - Tap your latest turn, or one of yours in History, to edit your text. It re-translates through the same endpoint.
    - Soniox pauses while the editor is open.
    - Direct editing of the translation field is cut.
- **Read-aloud is deferred.** Translate shows text only.

### 4.9 Mimo tab

- A chat with Mimo (§6.1). The profile, the active situation, up to 20 nearby MapKit POIs and an optional subject place are attached to every message automatically.
- **Replies:**
  - Replies stream in as 2–4 short plain sentences, with inline Markdown only.
  - Tool activity appears as one quiet line ("Searching the web…", "Finding places…").
- A reply is an ordered list of segments: text, **phrase blocks**, place chips, and sources.
- **Phrase blocks** (§6.2): every phrase Mimo suggests saying appears between paragraphs as a compact block showing script, romanization, gloss and a chevron, in the same look as Now's phrase cards. Tapping a block opens it in Show mode.
- **Places:**
  - When an answer involves places, Mimo calls `show_places` with names and a one-line why for each. It never sends coordinates.
  - The device resolves each name with MapKit (§4.7). Chips appear for the ones it found, plus **Show on map**, which opens Map with the From Mimo layer.
- **Plan a few hours:**
  - "What should I do this afternoon?" returns an ordered set of stops, each with a suggested time.
  - They're rendered as numbered chips and shown as numbered pins on the map.
  - No routing, no bookings, no multi-day plans.
- **Web search:** Mimo can search the web (§6.4). Sources show as tappable links under the reply.
- **Starter suggestions** are fixed templates per place category ("What's popular here?", "How do I pay?", "Plan my afternoon"). They need no LLM call.
- **Sessions:**
  - The device creates a session id, and a new one on **New chat**. The transcript is kept on the device.
  - **Ask Mimo about this place** (from a place sheet) opens the tab with that place attached as the subject, without changing the active situation.
- **Avatar:** to be explored later (an animated character, in the style of a companion avatar). Leave room for it in the tab's header.

### 4.10 Me tab

Holds:
- the profile sections from the survey (read-only in tier 1; editable in tier 2)
- the home base for the taxi card
- the romanization toggle, which only hides the row
- a preview of the allergy card
- an option to redo the survey (tier 2)
- a small developer section: the server base URL override and "Reset to seed profile"

### 4.11 Live Activity (tier 2)

- **When it starts:** when a place is confirmed or a preview starts, while the app is in the foreground, as ActivityKit requires. There's no push-to-start in v1.
  - It starts with a placeholder and updates when the place card arrives.
  - Only one activity exists at a time. All old ones end on launch.
- **Lock screen:** place name, local time, and the top phrase (local script plus gloss). Tapping it deep-links to Show mode for that phrase (`widgetURL` → `onOpenURL`, including on a cold start).
- **Dynamic Island:**
  - compact: the category's SF Symbol plus a short place name
  - expanded: the phrase
  - The island shows nothing while Ryoko itself is in the foreground.
- **When it ends:** on a new place, on leaving, or after 2 hours. (The system limit is 8 hours active plus 4 on the lock screen.)
- **Limits:**
  - The payload stays under 4 KB: short strings only.
  - The extension has no network or location access.
  - `NSSupportsLiveActivities` is the only requirement: no entitlement or App Group.

### 4.12 States

Every tab defines its empty, loading (`.redacted`), error (a message plus retry), offline (the last cached card, marked as such) and permission-denied (location, microphone) states. The server being unreachable is a normal error state, never a crash or an endless spinner.

## 5. Personalization rules

| Input | What it changes |
| --- | --- |
| Place (live or previewed) | Which phrases, which language, which tips, Mimo picks, the map's centre, Translate's language pair |
| Local time | What's appropriate (morning coffee vs evening drink), Mimo picks and plans, the gradient |
| Personality | Local favourite → the place's specialty. My usual → whatever is closest to your favourites. Save / splurge → price level. Quiet / lively → Mimo picks, Hidden gems and plans. Early bird / night owl → discovery hints only (early-opening or late-opening picks), never cited in a "because…" line |
| Nationality | Tips framed as differences from home norms (tipping, payment, etiquette) |
| Diet and allergies | Hard filter: never suggested, enforced by a server-side check as well as the prompt. Also feeds the allergy card |
| Favourites and taste | Defaults inside phrases (sugar level, spice) |
| Trip memory (after core) | "Last time you ordered less ice." Earlier picks shape the defaults |

The "because…" line must name **one or two** of these inputs, and each phrase carries them as a machine-checkable `basis` (§7.4). The server drops or regenerates any phrase whose basis points at an empty or skipped profile field. The model doesn't make up reasons.

## 6. Mimo and the server

### 6.1 Mimo

- **Role:** Mimo is the one agent behind:
  - the place-card phrases and tips
  - discovery (Mimo picks and Hidden gems)
  - the Mimo chat, including plans
  - free-text allergy cards
  
  It has one persona everywhere.
- **Persona: a calm local friend.** Warm, brief, first person, as someone who lives there. No exclamation marks, no emoji. The UI never calls Mimo "AI", "smart" or "magic".
- **The device owns the profile** and sends it with each request. There are no accounts in v1. Memory (after core) is keyed by an anonymous install id.
- **The device owns geography.** MapKit handles the map, POIs, finding places by name, and time zones. Mimo names places, and the device turns names into coordinates. That rules out made-up coordinates and avoids Google Maps data, which is weak in mainland China.

### 6.2 Phrase blocks

- **Marking:** the `mimo` skill prompt tells the model to put every sayable phrase on its own line as `<phrase lang="zh-Hans" local="…" gloss="…" romanization="…"/>`. Romanization is optional.
- **Server stream transformer:** the SSE adapter buffers text from `<phrase` to `/>` and parses the tag.
  - It fills romanization: [`pinyin-pro`](https://www.npmjs.com/package/pinyin-pro) for Chinese (MIT, with tone sandhi on), and the model's own romanization for Japanese.
  - It emits a `phrase` event (§7.7) in order between `text` events.
  - A malformed or unterminated tag is flushed as plain text at the end of the run.
  - The stored transcript keeps the raw tag, so Mimo sees its earlier phrases.
- Phrases are always in the active situation's local language. At most about 4 per reply. The allergen filter applies to phrase text too.
- One shared `Phrase` type (§7.3) is used by Now's cards, place sheets, Mimo's blocks and Show mode.

### 6.3 Models

- **Per-skill model config:** `{provider, modelId, baseUrl?, reasoning}`, read from `server/.env`. Switching models is a config change.
- **Now: GMI Cloud** (OpenAI-compatible, `https://api.gmi-serving.com/v1`). pi-ai 1.0.1 has no built-in GMI provider, so the server registers one with pi-ai's `createProvider` (`@earendil-works/pi-ai/models`) and `openAICompletionsApi` (`@earendil-works/pi-ai/api/openai-completions.lazy`). The default model is DeepSeek V4.1 Flash; confirm the exact model id in the GMI console.
- **Typed output is provider-agnostic.** The JSON schema goes in the prompt. The server parses the JSON, checks it with TypeBox `Value.Check`, retries once, then returns `invalid_model_output`. (GMI's `json_schema` response mode is staging-only.)
- **Tier 2: switch to Gemini before submission**, so the Gemini track qualifies:
  - `gemini-3.8-flash` (GA) through pi-ai's built-in `google` provider, with reasoning `low` (thinking can't be turned off).
  - Typed translation on a Flash-Lite model at `minimal`.
  - Never send temperature or top_p. Never use `-latest` aliases.
  - Gemini's native `responseJsonSchema` (via pi's `onPayload`) is an optional optimization added at switch time, never the only path.
  - This needs a billed Gemini project (§8.2).
- Moving any skill to Cerebras would need its own account and key. It is not a config-only change.

### 6.4 Server

- **Stack:**
  - Node 24 with native type stripping, Hono 4 with `@hono/node-server`.
  - `@earendil-works/pi-agent-core` and `@earendil-works/pi-ai` pinned exactly at **1.0.1** (MIT, ESM, Node ≥ 22.19). Don't upgrade during the event.
  - Import `Type`, `Static` and `StringEnum` from pi-ai. Use `StringEnum`, never `Type.Enum`. Pin TypeBox to 1.3.27 for `Value`.
  - The server is written from scratch in this repo.
- **Endpoints:**

  | Endpoint | Skill | Tier |
  | --- | --- | --- |
  | `GET /healthz` | (no auth) | 1 |
  | `POST /v1/place-card` | `place-card` | 1 |
  | `POST /v1/discover` | `discover` | 1 |
  | `POST /v1/allergy-card` | `allergy-card` (free-text allergens only) | 1 |
  | `POST /v1/sessions/:id/messages` (SSE) | `mimo` | 1 |
  | `POST /v1/translate` | `translate` (no tools) | 2 |
  | `POST /v1/localize-place` | local-script name and address for a home base | 2 |
  | `POST /v1/soniox-key` | mints a short-lived Soniox key | 2 |

- **Mimo's tools:**
  - `show_places` returns `{places: [{name, localName?, why, order?, when?}]}`, at most 5 places (or stops).
  - `web_search` is backed by Tavily and returns `details.sources [{title, url}]`.
- **Guardrails** (pi's Agent has none built in):
  - at most 4 model turns and 3 tool calls per run, via `finishTurn` and `beforeToolCall`
  - a 25–30 s timeout
  - abort when the client disconnects
  - one run per session at a time: a second message gets 409 `session_busy`
  - drop thinking events
  - low retry delays, so a rate limit surfaces as an error, not a hang
- **Sessions:** created lazily on the first message to an id and kept in memory. Before each message, the server replaces the profile and situation sections of the system prompt instead of appending them.
- **Caching:**
  - an in-memory LRU (about 500 entries), persisted to a gitignored JSON file so a restart keeps it warm
  - in-flight de-duplication: later callers wait on the same generation, and one client disconnecting never cancels a shared generation
  - errors and invalid output are never cached
  - the keys are listed in §7
- **Speed:** the place card and `discover` start generating as soon as the situation changes, before you open Now. The target is under 3 s for a place card.
- **Security** (the repo is public):
  - A bearer `APP_TOKEN` on every `/v1` route, compared in constant time.
  - Per-install and per-IP rate limits (about 60 a minute) and a 64 KB body limit.
  - A daily cost kill switch: `503 budget_exceeded`.
  - The server listens on `127.0.0.1` only.
- **Hosting:**
  - The server runs on the dev Mac at `127.0.0.1:8790` and is exposed with `tailscale funnel --bg --https=8443 http://127.0.0.1:8790`. Don't touch any other Serve or Funnel ports already in use on that Mac.
  - The phone uses the public HTTPS URL, so there are no ATS exceptions and no Local Network prompt. The app can override the base URL at runtime (Me).
  - Never use Cloudflare quick tunnels (they don't support SSE) or serverless hosts (they lose in-memory sessions).
- **Fixture mode:** `MODEL=faux` serves canned responses built from the example JSON in `contracts/`, including a scripted Mimo stream, so iOS work never waits on the model.
- **Evals:** `server/evals/run.ts` runs canned situations through each skill:
  - Heytea at 15:00 and at 08:00
  - a Tokyo ramen shop at 20:00
  - a peanut allergy
  - an unknown POI
  - a city-only case
  - English to English
  
  It asserts the schema, the because-basis and the allergen filter.

### 6.5 Discovery

- `POST /v1/discover` returns 5–8 places for an area: `{name, localName, why (≤ 60 chars), category, bestTime?}`.
- It's cached by (geohash-6 area, hour bucket, profile version).
- One result feeds both Now's **Mimo picks nearby** (the top 3–5) and the Map's **Hidden gems** layer.
- Picks favour lesser-known places that fit the time of day, the profile's personality and the diet.
- The device resolves each name with MapKit (§4.7) and silently drops misses.

## 7. Contracts

`contracts/` is the source of truth. It holds:
- TypeBox schemas, with JSON Schema emitted from them
- one example request and response per endpoint
- `mimo.sse.txt`, an example stream transcript
- the `LangCode` and category tables
- the allergy templates

Swift `Codable` types in `ios/Shared/` mirror the schemas by hand. Changes go through the server workstream. Every request carries `Authorization: Bearer <APP_TOKEN>`, `X-Install-Id` and `X-Client-Version`.

### 7.1 Situation

```json
{
  "mode": "preview",
  "localTime": "2026-10-05T15:00:00+08:00",
  "timeZone": "Asia/Shanghai",
  "hourBucket": "2026-10-05T15",
  "place": {
    "id": "<MKMapItem.Identifier raw value>",
    "name": "Heytea",
    "localName": "喜茶",
    "category": "cafe",
    "address": "…",
    "coordinate": { "lat": 31.2235, "lon": 121.4453 }
  },
  "city": "Shanghai",
  "district": "Jing'an",
  "countryCode": "CN",
  "localLanguage": "zh-Hans"
}
```

- `mode` is `live` or `preview`. `place` is `null` in city-only mode.
- The server works out the weekday and part of day from `localTime` only.
- `category` is a short slug from the shared category table, which also holds display names, SF Symbols and Mimo's starter suggestions.

### 7.2 Profile

```json
{
  "version": "<sha-256 of the canonical JSON>",
  "nationality": "CA",
  "homeLanguage": "en",
  "spokenLanguages": ["en"],
  "diet": [],
  "dietNotes": "",
  "allergies": [{ "id": "peanut", "severity": "serious" }],
  "favourites": { "foods": [], "drinks": ["fruit tea"] },
  "taste": { "sweetness": 1, "spice": 2 },
  "personality": { "rhythm": "night_owl", "food": "local_favourite", "budget": "save", "vibe": "quiet" },
  "homeBase": { "name": "…", "localName": "…", "address": "…", "addressLocal": "…", "coordinate": { "lat": 0, "lon": 0 } }
}
```

- **Codes:** `nationality` is ISO 3166-1. Languages are BCP-47.
- **Skipped vs none:** `null` means skipped and `[]` means none.
- **Diet:** `vegetarian | vegan | halal | kosher | no_pork | no_beef | gluten_free | lactose_free`.
- **Allergens:** `egg | milk | mustard | peanut | crustacean_mollusc | fish | sesame | soy | sulphite | tree_nut | wheat | custom`. A custom allergen also has a `label`.
- **Severity:** `mild | serious | life_threatening`.
- **Taste:** `0–4`, where 2 is "as usual". A skipped slider is `null`.
- **Personality:** each pair may be `null`.
- **Romanization preference** stays on the device.

### 7.3 Phrase

`{ id, lang, local, romanization: string | null, gloss, because?, basis? }`

`basis` is 1–2 values from `place | localTime | personality | nationality | diet | allergy | favourites | taste | memory`. For Latin-script languages, `romanization` is `null` and the row is hidden.

### 7.4 Place card

- **Request:** `{ profile, situation }`.
- **Response:** `{ language, phrases: Phrase[2–3] (with because and basis), tips: [{ text, basis }] (1–2), placeNameLocal?, addressLocal?, generatedAt }`.
- **Server checks:**
  - the basis matches filled-in profile fields
  - "because…" is about 10 words at most
  - Chinese local text contains no Latin letters
  - the allergen filter passes
  - Chinese romanization is filled by `pinyin-pro`
- **Cache key:** (place id, or name plus coordinates rounded to 4 decimals; hour bucket; profile version; prompt version; model id).

### 7.5 Discover

- **Request:** `{ area: { center, radiusMeters: 1500, city, district? }, profile, situation }`.
- **Response:** `{ places: [{ name, localName, why, category, bestTime? }] }` (5–8 places).
- **Cache key:** (geohash-6, hour bucket, profile version).

### 7.6 Allergy card

- **Request:** `{ language, allergies }` (free-text allergens only).
- **Response:** `{ language, title, items: [{ allergenId, local, home, severity }], requestLocal, requestHome, romanization?, reviewed: false }`.
- **Templated chip allergens** never call the server.

### 7.7 Mimo messages (SSE)

**Request:** `POST /v1/sessions/:id/messages` with `{ clientMessageId, message (≤ 2,000 chars), profile, situation, nearby?: [{ name, localName?, category, distanceMeters }] (≤ 20), subjectPlace? }`.

**Stream format:**
- Each event is exactly one `data: {json}` line followed by a blank line. No `event:` lines.
- The server sends a padding comment of more than 512 bytes first, because URLSession holds back the first bytes. It then sends `: ping` every 15 s.
- Headers: `Cache-Control: no-cache`, `X-Accel-Buffering: no`.

| Event | Fields |
| --- | --- |
| `start` | `sessionId, runId` |
| `text` | `delta` |
| `phrase` | `phrase` (a `Phrase`) |
| `tool_start` | `id, name, label` |
| `tool_end` | `id, name, ok, details` (`show_places`: `{places}`; `web_search`: `{sources}`) |
| `done` | `stopReason` |
| `error` | `code, message, retryable` |

Clients ignore event types they don't know.

### 7.8 Errors

- **JSON endpoints** return `{ "error": { "code", "message", "retryable" } }`.
- **Codes:** `unauthorized`, `rate_limited`, `session_busy`, `invalid_request`, `invalid_model_output`, `model_error`, `timeout`, `budget_exceeded`.

### 7.9 Language codes

One `LangCode` table (Swift and TypeScript) maps each BCP-47 tag to:
- the Soniox code
- the voice (tier 2)
- the `Locale` for geocoding
- the romanization source
- a display name

| Tag | Soniox | Locale | Romanization |
| --- | --- | --- | --- |
| `zh-Hans` | `zh` | `zh_Hans_CN` | pinyin (`pinyin-pro`, on the server) |
| `ja` | `ja` | `ja_JP` | romaji (model) |
| `en` | `en` | `en` | none |

A `LocalText` view applies `.typesettingLanguage` and `accessibilitySpeechLanguage` wherever local script appears, so CJK glyphs and VoiceOver are correct.

## 8. Sponsor integrations

Relevant tracks: ElevenLabs, Gemini API, Tiger Data, Snowflake API, plus Best Solo, Best Design and .Tech. Opt into each on Devpost.

### 8.1 ElevenLabs: tier 2

All spoken output goes through ElevenLabs: Speak on phrase cards and in Show mode, and on the allergy and taxi cards. Speech is always on demand, never in real time.

- **Account:** the free tier can't use Voice Library voices over the API and gets blocked on shared IPs. Use the MLH ElevenLabs code (a free 3-month subscription) or Starter. Create a restricted key (Text to Speech only) with a credit limit.
- **Voices:** stock voices only, one each for Mandarin, Japanese and English. Listen to candidates before hard-coding voice ids.
- **Model:** `eleven_flash_v2_5` (low latency, includes Chinese and Japanese). `eleven_multilingual_v2` is an option because cached audio favours quality.
- **Calls:** the device calls ElevenLabs directly, with the key in the gitignored `Secrets.xcconfig`.
- **Caching:** audio is cached on the device by a hash of (text, voice, model), so repeated phrases are instant and free.
- **Fallback:** `AVSpeechSynthesizer` when offline or on error.
- **Audio session:** use `.playback` (the default category is silenced by the silent switch). Stop Translate's listening session before playing, so the two never overlap.

### 8.2 Gemini: tier 2 switch

Gemini becomes Mimo's model before submission (§6.3). The story for judges: the personalized-advice agent behind Now, discovery, the Mimo chat and the allergy card, plus translation of typed text that fits the place.

- **Billing:**
  - The free tier for `gemini-3.8-flash` allows only about 20 requests a day.
  - Prepay at least $5 on a dedicated project, and set a project spend cap.
  - The $300 Google Cloud credit doesn't cover AI Studio usage.
- **Grounding:** Google Search grounding can't be used through pi, so web search stays on Tavily.
- **Embeddings:** after core, Tiger Data memory also uses Gemini embeddings (same key).

### 8.3 Tiger Data: after core

Durable storage and trip memory, on Tiger Cloud Postgres (the free plan is enough; MLH offers credits).

- **Sessions:** a Postgres-backed session store for the agent server. Store pi's message objects verbatim, in jsonb. Never switch an existing session's model.
- **Trip memory:**
  - A `trip_events` hypertable: time, install id, kind (`place_confirmed`, `phrase_shown`, `phrase_spoken`, `typed_translation`), place, text, and a pgvector embedding. Match the embedding dimension to the model.
  - Mimo gets recent events plus the top-k similar ones as a `<trip_memory>` prompt section.
  - This is where "learns from choices" lives.
- **Story for judges:** a time-series trip timeline that makes suggestions better as you travel.

### 8.4 Snowflake: after core

A travel knowledge base that Mimo cites for cultural tips.

- A `guides` table: Wikivoyage pages for the demo cities and etiquette. Wikivoyage text is CC BY-SA 4.0, so each row keeps attribution fields (article URL, licence) and cited tips link back to the article.
- A Cortex Search service over that table, queried over REST with a programmatic access token. The account's authentication policy has to allow PATs.
- For place cards, the server runs the search *before* building the prompt and injects the results, so the card stays fast. Mimo's chat gets a `search_guides` tool for culture questions, with a cited source.
- Not used for user memory: Cortex Search refreshes on a delay, and per-user memory is small and changes constantly. That's Tiger Data's job.

## 9. Styling

Reference: Luma. Lots of whitespace, confident type, few controls, and colour that comes from the content instead of decoration.
**This is a first pass. Build it simply, look at it on a device, then iterate.**

### 9.1 Type

- **SF Pro** everywhere, through Dynamic Type text styles (no fixed sizes). Chinese falls back to PingFang SC and Japanese to Hiragino automatically, given the right language tag (§7.9).
- **Hierarchy comes from size and weight only:**
  - Place name: `.largeTitle.bold()`
  - Phrase (local script): `.title.weight(.semibold)` (`.title3.weight(.semibold)` in Mimo's phrase blocks)
  - Romanization: `.subheadline`, secondary
  - Gloss: `.body`, secondary
  - "because…": `.footnote`, tertiary
  - Show mode phrase: as large as fits

### 9.2 Colour

- **Controls are monochrome.** The accent is the primary label colour (black in light mode, white in dark), e.g. `.tint(.primary)`.
- **Colour on screen comes only from the time-of-day gradient, the map and content.**
- Red is reserved for recording/stop and for allergy severity. Severity is also always written in words.
- Light and dark mode are both supported.

### 9.3 Time-of-day gradient

- A soft, static `LinearGradient` wash over the top ~45% of Now and of place sheets, fading into the system background. No animation.
- It's driven by the active situation's local time, so a previewed 8 AM looks like morning.
- **Starting values** (tune on device):

  | Part of day | Light (top → fade) | Dark (top → fade) |
  | --- | --- | --- |
  | Morning 05–11 | `#FFD8B5` → `#FFF3E3` | `#5A3A26` → black |
  | Midday 11–16 | `#CDE5FF` → `#EEF6FF` | `#1D3A5C` → black |
  | Evening 16–20 | `#FFC48A` → `#F9B9B0` | `#5C3524` → black |
  | Night 20–05 | `#C5CCE0` → `#E6E9F2` | `#1A1F3D` → black |

- **Where it doesn't appear:** Show mode, Translate, Mimo, Me and the onboarding survey. Those use plain system backgrounds.

### 9.4 Surfaces

- **Liquid Glass is for controls floating over content only:** the tab bar, toolbars, the mic button, the bottom accessory, and the Show/Speak buttons.
- Content cards, including Mimo's phrase blocks, are solid (`secondarySystemGroupedBackground`) with a 24 pt continuous corner radius. No glass on cards.
- Chips are capsules. Margins are 20 pt horizontal on an 8 pt grid.

### 9.5 Icons, motion, haptics

- SF Symbols only, monochrome or hierarchical rendering. The app icon is not built from SF Symbols; their licence doesn't allow it.
- Native springs (`.smooth`, `.snappy`), symbol effects and `contentTransition` for changing text.
- `sensoryFeedback` on confirming a place, opening Show mode, starting or stopping listening, and the face-to-face flip.
- Every icon-only button has an `accessibilityLabel`.

### 9.6 Copy

- Sentence case, short, and no exclamation marks.
- Never "AI", "smart" or "magic". Features are named for what they do (Show, Translate). The one exception is the **Mimo** tab, named after the companion who answers there.
- Mimo speaks as a calm local friend: first person, brief, warm.
- Local script comes first, then the translation.

### 9.7 Don'ts

- No purple-blue gradients or glows, no gradient text, no sparkle icons, no emoji in the UI.
- No custom tab bars or nav headers, no glass on content, no custom loading shimmers.

## 10. Demo (open)

The demo script and format are still being worked out and don't drive build decisions.

- **Seed profile** (bundled; also the demo profile): Canadian, English. A serious peanut allergy and a liking for less sweet things (sweetness 1). Picks "local favourite" over "my usual", "save" and "quiet". Home base is a hotel in Jing'an, with its Chinese name and address filled in by hand.
- **Ideas so far, not final:**
  - Preview a Heytea in Jing'an at 3 PM.
  - A Mandarin-speaking friend plays the staff member for face-to-face Translate.
  - Mimo answers a question with tappable phrases and places.
  - A second stop previews a Tokyo ramen shop with a ticket machine, where the card regenerates in Japanese.
- **Known pitfalls:**
  - The survey has no ice setting, so a "less ice" phrase has no real "because…" source.
  - Mimo can't verify amenities such as washrooms; the Washrooms layer can.
  - During judging (Sunday 12:00–17:00 PDT) it is Monday 3–8 AM in Shanghai, so always preview a chosen time.
  - Required for submission: a demo video of up to 3 minutes and a Devpost write-up that lists the AI tools used.

## 11. Open questions and risks

**Device spikes** (the first hour of implementation; these can't be settled any earlier):
1. **MapKit from outside China:**
   - What do search, POIs, reverse geocoding (with a `zh_Hans_CN` / `ja_JP` locale) and time zones return for Shanghai and Tokyo, from a phone in Canada?
   - Are names in local script or English?
   - Does the `.restroom` filter return anything in China?
   
   Test in the simulator first (a hand-written `.gpx` file can simulate Jing'an), then on the phone.
2. **Soniox:** accuracy, script, latency and false language switches for zh ⇄ en and ja ⇄ en in a noisy hall. Tune the turn rule (§4.8) there.
3. **GMI:** how long a place card takes, and whether the chosen model calls tools reliably (`show_places`, `web_search`).
4. **Funnel:** does SSE stream through Tailscale Funnel without buffering, and what is the round-trip time on venue Wi-Fi and on cellular?

**Risks:**
- **Allergy card accuracy.** This is safety text. Your language always shows underneath, the chip templates are reviewed, and free-text cards say "not reviewed". A Chinese reader and a Japanese reader still need to check the templates.
- **Romanization.** `pinyin-pro` handles tone sandhi, but polyphones can still be wrong. The on-device transform is only a fallback. Japanese romaji comes from the model.
- **Tilt detection** may trigger while you're just reading the phone at an angle. Tune it on device; the manual toggle is the backstop.
- **Networking at the venue.** The server is behind Funnel on the dev Mac, so keep the lid open, the Mac plugged in and `caffeinate` running, with a phone hotspot as a backup uplink.
- **Keys in the app build.** The Soniox key and app token are baked in, which is fine for the hackathon. Server-minted Soniox keys come in tier 2. Rotate everything after the event.
- **Name.** "Ryoko" is also a well-known travel Wi-Fi hotspot brand. Kept for now.

## 12. Build setup and workstreams

### 12.1 Repo layout

```
ios/         Xcode project: the Ryoko app + the RyokoLiveActivity widget extension
server/      Node 24 + Hono + pi
contracts/   schemas, examples, mimo.sse.txt, LangCode and category tables, allergy templates
resource/    this document, image references
AGENTS.md    conventions for coding agents (CLAUDE.md points to it)
```

### 12.2 Before any agent starts

1. **`.gitignore` first**, in the first code commit. It covers:
   - `.env` and `.env.*` (but `!.env.example`)
   - `**/Secrets.xcconfig` and `**/Local.xcconfig`
   - `*.p8`
   - `node_modules/`
   - `xcuserdata/`, `*.xcuserstate`, `DerivedData/`, `.build/`, `build/`
   - the server's cache file
   - `.DS_Store`
   
   Commit `server/.env.example` and `Secrets.example.xcconfig` with placeholder values.
2. **Create the Xcode project in the Xcode GUI** (about 10 minutes, done by the user):
   - An iOS App (SwiftUI) named Ryoko.
   - A Widget Extension named RyokoLiveActivity, with "Include Live Activity" checked. Delete the home-screen widget and control templates.
   - Synced folders per workstream, plus `Shared/`, which is a member of both targets.
   - Settings: the paid team, deployment target **26.1**, iPhone only, portrait only.
   - Info.plist keys: location when in use, microphone, `NSSupportsLiveActivities`.
   - xcconfig files: in xcconfig, `//` starts a comment, so write URLs as `https:/$()/host`.
   - Build once in the simulator and once on the phone, then commit.
3. **`AGENTS.md`** covers:
   - folder ownership: agents add files only inside their own synced folder; only the integrator edits `project.pbxproj`; `contracts/` changes go through the server workstream
   - the exact `xcodebuild` command, with a per-worktree `-derivedDataPath` and simulator
   - Swift rules: MainActor by default; audio-tap and CoreMotion callbacks are nonisolated, since MainActor-isolated tap closures crash
   - networking: the Funnel HTTPS URL, or http to the Mac's Tailscale 100.x IP; never `NSAllowsArbitraryLoads`
   - never inline keys, and never bypass push protection
   - never commit MapKit response dumps: fixtures are written by hand (Apple Maps terms)
4. **Contracts and shared Swift pieces** come first. They're owned by workstreams 1 and 2:
   - the `Codable` `Situation`, `Profile` and `Phrase` types
   - the protocols `RyokoAPI`, `PlaceResolver`, `SituationStore` and `SpeechService`, each with a fixture implementation
   - stubs for `PhraseCardView`, `TipRow` and `ShowContent`
   - a SwiftUI preview gallery
   
   Other workstreams fill in implementations behind these protocols.
5. **Keys in place:**
   - `server/.env`: GMI key and model id, Tavily key, `APP_TOKEN`
   - `Secrets.xcconfig`: Soniox key, app token, base URL

### 12.3 Workstreams (for parallel agents)

**Tier 1:**

1. **Contracts and fixture server.** `contracts/`, the Hono skeleton with auth, errors and SSE, `MODEL=faux` and Funnel.
2. **App shell and shared pieces.** `TabView`, theme tokens from §9, the gradient, `SituationStore` (live and preview), `ProfileStore` with the seed profile, the API client and SSE reader, `LangCode`, `LocalText` and the shared types from §12.2.
3. **Now and cards.** Now (phrases, tips, quick cards, Mimo picks, mini map), Show mode (`ShowContent`), the allergy card (templates) and the taxi card.
4. **Map.** Search, POI selection and long-press, the place sheet, Preview with the date and time picker, layers, and resolving Mimo's place names with MapKit.
5. **Translate.** The Soniox WebSocket client (there's no Swift SDK; 16 kHz mono PCM), turns and history, the pair from the situation, the face-to-face tilt and the manual toggle.
6. **Mimo tab.** The chat over SSE, segments (text, phrase blocks, place chips, sources), plans, starters, New chat, and "Ask Mimo about this place".
7. **Agent server and skills.**
   - the GMI provider and per-skill config
   - `place-card`, `discover`, `allergy-card` and `mimo` (`show_places`, `web_search`)
   - the phrase-tag transformer and `pinyin-pro`
   - guardrails, caching, security and evals

**Tier 2:**

8. **Speech.** ElevenLabs, the audio cache, the on-device fallback and audio-session handling.
9. **Live Activity.**
10. **Onboarding and Me editing.**
11. **Translate Type mode and editing**, plus `/v1/translate`.
12. **Gemini switch**, plus server-minted Soniox keys.

**After core:**

13. **Tiger Data.** The session store, the `trip_events` hypertable, Gemini embeddings, and `<trip_memory>`.
14. **Snowflake.** The `guides` table, Cortex Search, and `search_guides`.

## 13. Decisions log (2026-10-03)

Source: **user** (decided by the team), **research** (checked against primary sources the same day) or **default** (a proposed default nobody objected to).

| # | Decision | Source |
| --- | --- | --- |
| 1 | The team is solo, driving coding agents in parallel. Plan for a correct first pass, not around the deadline (Devpost: Sun Oct 4, 12:00 PM PDT) | user |
| 2 | Tier 1 is the working core in §2. Speak moves to tier 2 | user |
| 3 | The demo device is an iPhone 18 Pro Max on iOS 27. Deployment target 26.1 (the newest API used is `tabViewBottomAccessory(isEnabled:)`) | user + research |
| 4 | A paid Apple Developer team. Live Activities need only the Info.plist key | user + research |
| 5 | Mandarin (`zh-Hans`) and Japanese are first-class | user |
| 6 | The agent is **Mimo**: a core feature behind most of the app, a calm-local-friend persona, its own **Mimo** tab, and an avatar to explore later | user |
| 7 | Mimo's server is built from scratch on the pi npm packages, pinned at 1.0.1 | user + research |
| 8 | Model: GMI Cloud now, with provider-agnostic typed output. Switch to Gemini before submission | user + research |
| 9 | Discovery in tier 1: Hidden gems layer, Mimo picks on Now, asking Mimo for places, planning a few hours | user |
| 10 | Mimo has Tavily web search with sources in tier 1 | user |
| 11 | Mimo's suggested phrases are tappable phrase blocks that open Show mode. They're implemented as phrase tags turned into `phrase` events on the server | user + default |
| 12 | The server runs on the dev Mac behind Tailscale Funnel (`:8443` → `127.0.0.1:8790`) | user |
| 13 | After core: Tiger Data, then Snowflake | user |
| 14 | The Soniox key has a funded balance (Soniox no longer gives free credits) | user + research |
| 15 | The demo is still open and doesn't drive decisions | user |
| 16 | Local language comes from the region code on the device. The agent never decides it | research + default |
| 17 | Use `MKReverseGeocodingRequest` with `preferredLocale`, since `CLGeocoder` is deprecated in iOS 26 | research |
| 18 | MapKit exposes no opening hours, so they're dropped from personalization | research |
| 19 | The Translate tab uses `character.bubble`, since `translate` is reserved | research |
| 20 | Chinese romanization comes from `pinyin-pro` on the server; the on-device transform is only a fallback | research + default |
| 21 | pi has no turn limit and throws on concurrent prompts, so guardrails and per-session locks are ours to build | research |
| 22 | GMI's `json_schema` mode is staging-only, so typed output is prompt plus validation | research |
| 23 | ElevenLabs: free tier can't use library voices over the API. Use the MLH code or Starter | research |
| 24 | Gemini: the free tier is about 20 requests a day; a billed project and a spend cap are needed before switching. Thinking can't be off on 3.8 Flash | research |
| 25 | Ask web search through Gemini grounding isn't usable via pi, so Tavily it is | research |
| 26 | Wikivoyage is CC BY-SA 4.0, so guides keep attribution fields | research |
| 27 | MLH rules: all work happens during the event; libraries are allowed but your own earlier code isn't; AI tools are disclosed on Devpost; the repo stays public | research |
| 28 | Contracts in §7 are frozen first, with a fixture mode so iOS doesn't wait on the model | default |
| 29 | Translate keeps an in-memory turn history with a History sheet. The turn rule is in §4.8. The pair never changes mid-session | default |
| 30 | The preview picker covers date and time in the place's time zone, now to +7 days, with quick chips | default |
| 31 | When the local language is your own, Now shows no phrase cards | default |
| 32 | The allergy card uses reviewed templates for chip allergens. The LLM is used only for free text, marked "not reviewed" | default |
| 33 | No LLM in the taxi card's display path. There's a fixed phrase per language | default |
| 34 | One `discover` endpoint feeds both Mimo picks and Hidden gems | default |
| 35 | The "because…" line names one or two inputs, carried as a checked `basis` | default |
| 36 | Map layers: Food & drink and Washrooms use MapStyle filters. Overpass is cut | default |
| 37 | Security: bearer token, rate limits, cost kill switch; the server listens on localhost only | default |
| 38 | Caching: an LRU persisted to disk, with in-flight de-duplication; keys in §7 | default |
| 39 | Onboarding is tier 2; a seed profile drives personalization until then | default |
| 40 | iPhone only, portrait only; `ShowContent` enum; `LocalText` with language tags | default |
| 41 | Build setup: `.gitignore` first, the Xcode project created by hand, `AGENTS.md`, shared Swift pieces first | default |
