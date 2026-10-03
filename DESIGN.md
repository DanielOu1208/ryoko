# Echo: product and design decisions

Status: locked for the hackathon, 2026-10-03.
This is the source of truth for what Echo does and how it looks. An agent building one part should read its feature section, §6 (agent and data), §7 (sponsors) and all of §8 (styling).

## 1. The idea

Echo knows where you are, what time it is there, and who you are, and uses that to hand you the right words in the local language before you need them.

You walk into a tea shop in Shanghai at 3 PM. Echo already shows the order you'd want, written in Chinese, with a line saying why it picked it. You show it to the staff or let the phone say it. When they answer, Translate takes over.

Principles that settle trade-offs:

- **Phrases are the hero.** The thing you'll say next is the biggest element on the main screen.
- **Personalization is visible.** Every suggestion carries a short "because…" line that names the input behind it ("you like it less sweet").
- **Translate is just translation.**
  - Soniox handles speech, with nothing layered on top.
  - Typed or edited text goes through one short translate call to Gemini on our server.
  - No reply chips, no notes, and no read-aloud for now.
- **Native first.** Use system components, a native tab bar, native navigation bars and sheets, SF Pro and SF Symbols. Nothing custom where iOS already has a version.
- **Looking ahead doubles as demo mode.** Any place at any time can be previewed, so the demo doesn't depend on where we physically are.
- **Finish before sponsors.** The core works end to end before any after-core sponsor work starts.

## 2. Scope

| Core (build now) | After core | Not doing |
| --- | --- | --- |
| Onboarding survey → profile | Tiger Data: durable sessions + trip memory (this is where "learns from choices" lives) | Reply chips and context notes in Translate |
| Place awareness + look-ahead (pin + time) | Snowflake: travel knowledge base for cultural tips | ElevenLabs voice cloning (stock voices only) |
| Now tab: personalized phrases, "because…", cultural tips | Menu scan with allergen flags | Politeness toggle |
| Show mode + speak | Offline pack for pinned places | Pronunciation check |
| Allergy card | Listen mode (announcements, tour guides) | Home screen widget |
| Taxi card | Translate read-aloud (speaking each turn's translation) | Parking layer |
| Map: live map, layers, pin picker | | Itinerary planning, social/sharing |
| Translate: voice + type/edit, face-to-face tilt | | Google's agent SDKs (Gemini runs inside pi) |
| Ask: chat with the agent, incl. "ask the map" | | Apple's Translation framework (typed text uses Gemini) |
| Me: profile, home base | | |
| Live Activity (lock screen + Dynamic Island) | | |
| ElevenLabs for Speak buttons | | |
| Gemini as the agent's model | | |

## 3. Navigation

- A native SwiftUI `TabView` with five tabs. On iOS 26 this renders as the standard Liquid Glass tab bar. No custom tab bar.

  | Tab | SF Symbol | Purpose |
  | --- | --- | --- |
  | Now | `location.fill` | Where you are (or are previewing) and what to say there |
  | Map | `map` | Live map, layers, pin picker |
  | Translate | `translate` | Live two-way translation, voice or typed |
  | Ask | `bubble.left` | Chat with the agent |
  | Me | `person.crop.circle` | Profile and settings |

- Native navigation bars with large titles, native sheets with detents, native `fullScreenCover` for Show mode.
- `tabBarMinimizeBehavior(.onScrollDown)` on scrolling tabs (Now, Ask).
- While Translate is listening, a `tabViewBottomAccessory` shows "Listening · English ⇄ Chinese" with a stop button. This lets you jump to Now or Show mode mid-conversation without ending the session.

## 4. Features

### 4.1 Onboarding survey

The survey runs on first launch. It's about 45 seconds, every page can be skipped, and everything is editable later in Me.

1. **Where you're from:** nationality and home language.
2. **Languages you speak.**
3. **What you don't eat:** chips (vegetarian, vegan, halal, kosher, no pork, no beef, gluten-free, lactose-free) plus free text.
4. **Allergies:** chips plus free text, each with a severity (mild / serious / life-threatening).
5. **Your usual:** favourite foods and drinks (chips plus free text). Native sliders for sweetness and spice.
6. **This or that:** four pairs of big tappable cards. Early bird / night owl, local favourite / my usual, save / splurge, quiet / lively.
7. **Where you're staying** (optional). This is the home base for the taxi card.

Built from native parts: paged `NavigationStack` with large titles, bordered/prominent buttons as chips, system sliders, and a glass-prominent Continue button.

### 4.2 Place awareness and look-ahead

- **Live:**
  - CoreLocation plus `MKLocalPointsOfInterestRequest` within about 50 m.
  - If one candidate is clearly closest, Now shows "At Heytea?" with a one-tap confirm (indoor GPS is fuzzy).
  - Otherwise it shows the three nearest places to pick from.
  - It re-checks after moving more than about 100 m.
- **Look-ahead:**
  - Tapping any POI or long-pressing anywhere on the map drops a pin and opens a place sheet with **Preview**.
  - Preview offers a time picker that defaults to now in that place's time zone (`MKMapItem.timeZone`).
  - While previewing, Now shows a banner like "Previewing · Heytea, Jing'an · Sat 3:00 PM" with **Back to here**.
- **Everything follows the active situation**, live or previewed: the Now card, Translate's language pair, Ask's context, the Live Activity and the gradient.

### 4.3 Now tab

Top to bottom:

1. **Header:** city · local time (the place's time, not the device's). Below it, the place name as a large title and the category, plus the confirm/change control.
2. **Phrase cards (2–3).** Each card has:
   - the local script (largest text on screen)
   - romanization (pinyin for Chinese, on by default, can be turned off in Me)
   - the gloss in your language
   - a "because…" line of at most about 8 words

   Actions: **Show** (opens Show mode) and **Speak** (ElevenLabs, §7.1).
3. **Cultural tips (1–2),** framed against your nationality where that helps ("No tipping, same as… / unlike Canada").
4. **Quick cards row:** Allergy card, Taxi card.
5. **Mini map tile:** live, non-interactive. Tapping it opens the Map tab centred here.

If no place is known yet, Now shows "Where are you?" with nearby picks and general tips for the city.
While the card loads, use native `.redacted(reason: .placeholder)`, not a custom shimmer.
When a card arrives, its phrases' audio is fetched in the background so **Speak** plays instantly.

### 4.4 Show mode

A full-screen cover meant to be handed to someone else:
- Plain system background (white or black), no gradient. Contrast comes first.
- The phrase in local script, as large as fits (`minimumScaleFactor`).
- Romanization below it in small type, then the gloss smallest, at the bottom.
- Buttons: **Speak**, **Flip** (rotates 180° for someone across a counter), **Done**.
- Screen brightness goes to max and the idle timer is off while it's open.

### 4.5 Allergy card

- A Show-mode card in the local language that states each allergy and how serious it is.
- It asks whether the dish contains the allergen, with the English original underneath.
- The agent generates it once per (language, allergies) and the result is cached.
- Reachable from Now's quick cards and from Me.

### 4.6 Taxi card

- A Show-mode card for the home base or any place (from its place sheet).
- It shows:
  - the place name and address in local script, from reverse geocoding with the local locale (`CLGeocoder` with `preferredLocale`, e.g. `zh_Hans_CN`)
  - a fixed phrase, "请带我去这里" ("Please take me here")
  - a small `MKMapSnapshotter` image
- No LLM.

### 4.7 Map tab

- MapKit with the user's location.
- Layer toggles in a native menu or toolbar: **Food & drink**, **Washrooms**, **Hidden gems**. Results from Ask appear as a temporary fourth layer, "From Ask".
  - Food & drink: MapKit POI categories (restaurant, cafe, bakery, …).
  - Washrooms: MapKit's `.restroom` category. OSM Overpass `amenity=toilets` is the fallback outside China.
  - Hidden gems: from the agent (§6), resolved to coordinates with MapKit and cached per area.
- Tapping a pin, or long-pressing anywhere, opens a place sheet (medium/large detents). It holds the same phrase cards and tips as Now, plus **Preview**, **Taxi card** and **Ask about this place**.

### 4.8 Translate tab

Translate is translation only. Speech goes through Soniox `stt-rt-v5` in `two_way` mode.

- **Language pair:** defaults to (profile home language, local language of the active situation), e.g. English ⇄ Chinese in Shanghai. It can still be picked by hand.
- **Turns:** the panes show the current speaker's turn. When a few words arrive in the other language, both panes clear for the new turn. Listening stops after 2 minutes of silence or when the app goes to the background.
- **Upright layout** (phone held normally): what was said on top, the translation below.
- **Face-to-face layout** (phone flat or tilted forward):
  - The **top half is rotated 180°** toward the other person and always shows *their* language.
  - The **bottom half** always shows *yours*.
  - When you speak English, your words sit at the bottom and the Chinese translation faces them at the top. When they speak Chinese, their words face them at the top and the English translation sits at the bottom for you.
  - **Detection:** CoreMotion gravity. The layout switches when the phone gets within about 30° of flat or its top edge tips away. It switches back when the phone is raised past about 50°. Hysteresis plus a short debounce stops flicker.
  - A toolbar button forces either layout, for reliability and accessibility.
  - A haptic plays on each switch. The rotation is animated with `.smooth`.
- **Voice / Type:**
  - The bottom bar has the big mic button plus a smaller keyboard button. The keyboard button switches to Type; the mic switches back to Voice.
  - **Type mode:**
    - You type in your language.
    - The translation updates when you pause typing (about 500 ms) and again on **Done**.
    - It comes from `POST /v1/translate` (Gemini, §6), with the active situation passed along so wording fits the place (e.g. 少糖 at a tea shop). Requests that are already out of date are cancelled.
    - While the keyboard is up, the big panes slide off screen. Only a compact preview of the translation shows above the text field.
    - **Done** drops the keyboard and adds the turn to the conversation. The translation then shows full size, flipped if face-to-face.
  - **Editing:**
    - Tap one of your past turns to open an editor with two fields: your text and its translation.
    - Editing your text re-translates it through the same endpoint, replacing Soniox's version.
    - The translation field can also be edited directly. Once it's touched, it stops auto-updating.
- **Read-aloud is deferred.** Translate shows text only. After core, a tap-to-play on a translation is a one-liner on top of the speech module.

### 4.9 Ask tab

- A chat with the agent. Profile and situation are attached to every message automatically.
- Replies stream in. Tool activity appears as one quiet line ("Searching the web…"). Sources are tappable links.
- **Ask the map:**
  - When an answer involves places, the agent calls a `show_places` tool with names and a one-line reason for each. It never sends coordinates.
  - The device finds each place with `MKLocalSearch` near the active situation.
  - The chat shows them as place chips plus **Show on map**, which opens Map with the "From Ask" layer.
- Starter suggestions are fixed templates per place category ("What's popular here?", "How do I pay?"). No LLM call is needed for them.
- One session per trip.

### 4.10 Me tab

Holds:
- the profile sections from the survey, editable
- the home base for the taxi card
- the romanization toggle
- a preview of the allergy card
- an option to redo the survey

### 4.11 Live Activity

- **When it starts:** when a place is confirmed or a preview starts. The app is in the foreground at that moment, which ActivityKit requires. There is no push-to-start in v1.
- **Lock screen:** place name, local time, and the top phrase (local script plus gloss). Tapping it deep-links to Show mode for that phrase.
- **Dynamic Island:**
  - compact: the category's SF Symbol plus a short place name
  - expanded: the phrase
- **When it ends:** on a new place, on leaving, or after 2 hours.

## 5. Personalization rules

| Input | What it changes |
| --- | --- |
| Place (live or previewed) | Which phrases, which language, which tips, the map's centre, Translate's language pair |
| Local time | What's appropriate (morning coffee vs evening drink), opening hours, the gradient |
| Personality | Adventurous / local favourite → the place's specialty. My usual → whatever is closest to your favourites. Save/splurge → price level. Quiet/lively → map and Ask picks |
| Nationality | Tips framed as differences from home norms (tipping, payment, etiquette) |
| Diet and allergies | Hard filter: never suggested. Also feeds the allergy card |
| Favourites and taste | Defaults inside phrases (sugar and ice level, spice) |
| Trip memory (after core) | "Last time you ordered less ice." Earlier picks shape the defaults |

The "because…" line must name one of these inputs. The model doesn't make up reasons.

## 6. Agent and data

- **Model:** Gemini Flash (the newest Flash in pi-ai's catalog) through pi-ai's built-in `google` provider. The agent server just registers that provider. No Google agent SDK. DeepSeek V4.1 Flash on GMI stays as the fallback.
- **The device owns the profile and sends it with each request.** No accounts in v1. Memory (after core) is keyed by an anonymous install ID.
- **The device owns geography.** MapKit handles the map, POIs, finding places by name and time zones. The agent names places; the device turns names into coordinates. That rules out made-up coordinates and avoids Google Maps data, which is weak in mainland China.
- **The agent server** (pi's agent loop and pi-ai behind a thin HTTP/SSE adapter). Starting shape:

  | Endpoint | Skill | Output |
  | --- | --- | --- |
  | `POST /v1/place-card` | `place-card` | `{ phrases: [{ local, romanization, gloss, because }], tips: [{ text }] }` |
  | `POST /v1/sessions/:id/messages` (SSE) | `ask` (general + `show_places`) | Streamed events (text deltas, tool start/end, run end). `show_places` details: `[{ name, why }]` |
  | `POST /v1/hidden-gems` | `hidden-gems` | `[{ name, why }]` for an area |
  | `POST /v1/allergy-card` | `allergy-card` | `{ local, english }` |
  | `POST /v1/translate` | `translate` (no tools, plain-text reply) | `{ translation }` for `{ text, from, to, situation }` |

- **Storage:**
  - For the core, sessions are kept in memory on the server.
  - The first durable store is Tiger Data (§7.3). No other database in between.
- **Speed:**
  - The place card starts generating as soon as the place changes (before you open Now).
  - It's cached by (place, hour bucket, profile version).
  - Target: under 3 s.
  - No web search for chains the model already knows.
  - Hidden gems are prefetched for the demo area.
- **Profile schema** (from the survey, §4.1):
  - nationality, home language, spoken languages
  - diet restrictions
  - allergies, each with a severity
  - favourite foods and drinks
  - taste (sweetness, spice)
  - personality (the four this-or-that picks)
  - home base (name, address, coordinates)

  Romanization preference stays on the device.

## 7. Sponsor integrations

### 7.1 ElevenLabs: core

All spoken output goes through ElevenLabs: Speak on phrase cards, Show mode, and the allergy and taxi cards. Speech is always on demand, never in real time.

- **Voices:** stock voices only, one per language from the voice library. Start with one Mandarin and one English voice.
- **Model:** a low-latency multilingual TTS model (e.g. `eleven_flash_v2_5`; check the current list when building).
- **Calls:** the device calls ElevenLabs directly, with the key in a gitignored `Secrets.xcconfig`, next to the Soniox key.
- **Caching:** audio is cached on the device by hash of (text, voice, model), so repeated phrases are instant and free.
- **Fallback:** `AVSpeechSynthesizer` when offline or on error.
- **Audio session:** stop Translate's listening session before playing, so the two never overlap.

### 7.2 Gemini: core

Gemini is the model inside pi (§6). The story for judges: the personalized-advice agent behind Now, Ask, hidden gems and the allergy card, plus translation of typed text that fits the place.

If typed translation feels slow, switch only the `translate` skill to Qwen on Cerebras (`qwen-3.8-27b`, already in pi-ai's catalog). That's a config change. Don't do it pre-emptively: most of the wait is the network round trip, not generation. After core, Tiger Data memory also uses Gemini embeddings (same key).

### 7.3 Tiger Data: after core

Durable storage and trip memory, on Tiger Cloud Postgres.

- **Sessions:** a Postgres-backed session store for the agent server.
- **Trip memory:**
  - A `trip_events` hypertable: time, install ID, kind (`place_confirmed`, `phrase_shown`, `phrase_spoken`, `typed_translation`), place, text, and a pgvector embedding.
  - The agent gets recent events plus the top-k similar ones as a `<trip_memory>` prompt section.
  - This is where "learns from choices" lives.
- **Story for judges:** a time-series trip timeline that makes suggestions better as you travel.

### 7.4 Snowflake: after core

A travel knowledge base the agent cites for cultural tips.

- A `guides` table: Wikivoyage pages for the demo cities and China etiquette, with attribution.
- A Cortex Search service over that table.
- An agent tool, `search_guides`, calls the Cortex Search REST API with `fetch`.
- Used by the `place-card` tips and by Ask for culture questions, with a cited source.
- Not used for user memory: Cortex Search refreshes on a delay, and per-user memory is small and changes constantly. That's Tiger Data's job.

## 8. Styling

Reference: Luma. Lots of whitespace, confident type, few controls, and colour that comes from the content instead of decoration.
**This is a first pass. Build it simply, look at it on a device, then iterate.**

### 8.1 Type

- **SF Pro** everywhere, through Dynamic Type text styles (no fixed sizes). Chinese falls back to PingFang SC automatically.
- **Hierarchy comes from size and weight only:**
  - Place name: `.largeTitle.bold()`
  - Phrase (local script): `.title.weight(.semibold)`
  - Romanization: `.subheadline`, secondary
  - Gloss: `.body`, secondary
  - "because…": `.footnote`, tertiary
  - Show mode phrase: as large as fits

### 8.2 Colour

- **Controls are monochrome.** The accent is the primary label colour (black in light mode, white in dark), e.g. `.tint(.primary)`.
- **Colour on screen comes only from the time-of-day gradient, the map and content.**
- Red is reserved for recording/stop and for allergy severity.
- Light and dark mode are both supported.

### 8.3 Time-of-day gradient

- A soft, static gradient wash over the top ~45% of Now and of place sheets, fading into the system background.
- It's driven by the active situation's local time, so a previewed 8 AM looks like morning.
- **First pass:** a `LinearGradient` or a static `MeshGradient`, with no animation.
- **Starting values** (tune on device):

  | Part of day | Light (top → fade) | Dark (top → fade) |
  | --- | --- | --- |
  | Morning 05–11 | `#FFD8B5` → `#FFF3E3` | `#5A3A26` → black |
  | Midday 11–16 | `#CDE5FF` → `#EEF6FF` | `#1D3A5C` → black |
  | Evening 16–20 | `#FFC48A` → `#F9B9B0` | `#5C3524` → black |
  | Night 20–05 | `#C5CCE0` → `#E6E9F2` | `#1A1F3D` → black |

- **Where it doesn't appear:** Show mode, Translate, Ask, Me and the onboarding survey. Those use plain system backgrounds.

### 8.4 Surfaces

- **Liquid Glass is for controls floating over content only:** tab bar, toolbars, the mic button, the bottom accessory, Show/Speak buttons.
- Content cards are solid (`secondarySystemGroupedBackground`) with a 24 pt continuous corner radius. No glass on cards.
- Chips are capsules. Margins are 20 pt horizontal on an 8 pt grid.

### 8.5 Icons, motion, haptics

- SF Symbols only, monochrome or hierarchical rendering.
- Native springs (`.smooth`, `.snappy`), symbol effects and `contentTransition` for changing text.
- `sensoryFeedback` on confirming a place, opening Show mode, starting or stopping listening, and the face-to-face flip.

### 8.6 Copy

- Sentence case, short, and no exclamation marks.
- Never "AI", "smart" or "magic". Features are named for what they do (Ask, Show, Translate).
- Local script comes first, then the translation.

### 8.7 Don'ts

- No purple-blue gradients or glows, no gradient text, no sparkle icons, no emoji in the UI.
- No custom tab bars or nav headers, no glass on content, no custom loading shimmers.

## 9. Demo: a tea shop in Shanghai

**Demo profile:** Canadian, English. Serious peanut allergy, likes things less sweet. Picks "local favourite" over "my usual". Home base is a hotel in Jing'an.

1. **Onboarding.** Mostly pre-filled. Show the allergy and sweetness pages live (about 20 s).
2. **Map.** Find a Heytea in Jing'an, tap **Preview**, set 3:00 PM.
3. **Now.**
   - An afternoon wash.
   - Phrase card: 一杯多肉葡萄，少糖少冰 · *yì bēi duō ròu pú tao, shǎo táng shǎo bīng* · "One grape fruit tea, less sugar, less ice" · *because you like it less sweet and it's their signature*.
   - Tip: "Most people order by scanning the QR code at the counter; ordering at the counter is fine too."
   - The Live Activity appears. Show the lock screen.
4. **Show mode.** A teammate plays the staff member. Tap **Speak** (ElevenLabs Mandarin voice).
5. **Translate.**
   - Lay the phone flat on the "counter". It flips to face-to-face.
   - The teammate asks in Mandarin (在这喝还是带走？) and you answer in English. The Chinese faces them at the top of the screen.
   - Fix a mis-heard word by tapping your turn and typing.
6. **Allergy card.** Show it once.
7. **Ask.** "Somewhere quiet nearby to sit, with a washroom?" The answer comes back with places, then **Show on map**.
8. **Taxi card** back to the hotel.
9. **If the after-core work is done:**
   - The tip cites a guide (Snowflake).
   - Re-previewing Heytea the next day shows "last time: less ice" (Tiger Data).

## 10. Open questions and risks

- **MapKit from outside China.** Does searching around Shanghai, and getting Chinese place names, work from a phone here? Check this first. If names come back in English, the agent translates the name for the taxi card.
- **Washroom coverage.** How complete MapKit's `.restroom` data is in China is unknown.
- **Hidden gems quality.** Prefetch and sanity-check the demo area.
- **Place-card speed on Gemini Flash.** Mitigations: warm-up and cache. DeepSeek on GMI is the fallback.
- **Typed-translation speed.** Measure it on venue wifi. If it's slow, move the `translate` skill to Cerebras (§7.2).
- **Tilt detection.** It may trigger while you're just reading the phone at an angle. Tune the thresholds on device; the manual toggle is the backstop.
- **ElevenLabs Mandarin voice.** Check quality and latency. On-device speech is the fallback.
- **Allergy card accuracy.** The English always shows underneath. Consider a reviewed template for the demo language.
- **Networking.** The phone needs to reach the agent server at the venue (tunnel or Tailscale).
- **Keys in the app build.** The Soniox and ElevenLabs keys are baked in. That's fine for the hackathon; rotate them afterwards.

## 11. Workstreams (for parallel agents)

**Core:**

1. **App shell and theme.** `TabView`, the theme tokens from §8, the gradient view and situation state (live/preview). Everyone else depends on this, so it goes first.
2. **Onboarding and Me.** The survey, the profile store, and the profile schema on the device and the server.
3. **Now and cards.** Phrase cards, Show mode, allergy card, taxi card, Live Activity (widget extension).
4. **Map.** Layers, place sheet, Preview and time picker, resolving agent place names with MapKit.
5. **Translate.** The Soniox client and captions, the language pair from the situation, then the face-to-face tilt, Type mode and editing, the bottom accessory, and styling.
6. **Speech.** The ElevenLabs client, audio cache, on-device fallback and audio-session handling, shared by Now, Show mode and the cards.
7. **Ask.** The chat client over SSE, place chips, the "From Ask" layer.
8. **Agent server and skills.** The HTTP/SSE adapter, the Gemini provider, `place-card`, `ask` + `show_places`, `hidden-gems`, `allergy-card`, `translate`, caching.

**After core:**

9. **Tiger Data.** A Postgres session store, the `trip_events` hypertable, Gemini embeddings, and the `<trip_memory>` section.
10. **Snowflake.** The `guides` table, the Cortex Search service, and the `search_guides` tool.
