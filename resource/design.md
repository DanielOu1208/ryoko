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
| App shell: four tabs (#53), theme, gradient, situation state (live + preview), profile store with a bundled seed profile | Speak: ElevenLabs, audio cache, on-device fallback (§8.1) | Tiger Data: durable sessions + trip memory (§8.3) |
| Place awareness (nearest places + I'm here) and look-ahead (search or pin, plus date and time) | Live Activity: lock screen + Dynamic Island (§4.11) | Snowflake: travel guides that Mimo cites (§8.4) |
| Map (opens first): bottom sheet of Mimo picks and nearby places; every place opens a card with phrases with "because…", tips and quick actions (Nearby merged in, #53) | Onboarding survey (§4.1) and editing in Me, including About me (#55) | Translate read-aloud |
| Show mode (no Speak yet) | Translate Type mode and tap-to-edit turns, `POST /v1/translate` | Menu scan with allergen flags |
| Allergy card (reviewed templates) and taxi card | Bottom "Listening" accessory (tab-bar minimize dropped, #50) | Offline pack for pinned places |
| Map: search, place cards, Preview, layers incl. Hidden gems and From Mimo | Server-minted Soniox keys | Listen mode (announcements, tour guides) |
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

- A native SwiftUI `TabView` with four tabs, in the order Translate · Map · Mimo · Me. **The app opens on Map.** On iOS 26 and later this renders as the standard Liquid Glass tab bar. No custom tab bar.

  | Tab | SF Symbol | Purpose |
  | --- | --- | --- |
  | Translate | `character.bubble` | Live two-way translation |
  | Map | `map` | **Opens first.** The map with a bottom sheet of Mimo picks and nearby places; any place opens its card (what to say, tips, Directions, Taxi, I'm here or Preview); search, layers |
  | Mimo | `bubble.left` (an avatar later) | Chat with Mimo: questions, places, plans |
  | Me | `person.crop.circle` | Profile and settings |

  The `translate` symbol is reserved for Apple's own Translate app, so it isn't used.
- There's no Nearby tab (#53). What it showed is now the place card in the Map's sheet (§4.7).
- Native navigation bars with large titles (`navigationSubtitle` for secondary lines), native sheets with detents, and a native `fullScreenCover` for Show mode.
- iPhone only, portrait only. All rotation (Flip, face-to-face) is done in SwiftUI.
- The tab bar never minimizes (`tabBarMinimizeBehavior(.never)`): it stays full size on every tab, so the tabs are always one tap away (#50). Tier 2: while Translate is listening, a `tabViewBottomAccessory` shows "Listening · English ⇄ Chinese" with a stop button.

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
  - CoreLocation plus `MKLocalPointsOfInterestRequest` within about 100–150 m (POIs are sparse in Shanghai at 50 m).
  - The Map's bottom sheet (§4.7) lists nearby places: Mimo picks first, then the nearest places by distance. Tapping one opens its card. Within about 300 m of your fix, the card's **I'm here** makes it the current place (a one-tap confirm, because indoor GPS is fuzzy). **Check again** in the sheet's header re-checks.
  - No automatic "clearly closest" detection and no movement re-checks (cut).
- **Look-ahead:**
  - Search on the Map tab, tap any POI, or long-press anywhere. Each opens the place's card with **Preview**.
  - Preview offers a date and time picker in the place's time zone (`MKMapItem.timeZone`; fall back to reverse geocoding, then the device zone):
    - range: now to 7 days ahead
    - quick chips: Morning 9 AM, Afternoon 3 PM, Evening 7 PM
  - Content is generated only once a time is committed.
  - While previewing, the Map sheet's header shows the place and its time with a small "Previewing" badge and a small **Back to here** (§4.7). On that place's card the Preview button reads "Previewing <time>" and reopens the picker.
- **Everything follows the active situation**, live or previewed: the current place's card, the Map sheet's header and Mimo picks, Translate's language pair, Mimo's context, the Live Activity and the gradient. The device always sends the situation's local time with its offset (§7.1). The server never uses its own clock.

### 4.3 Nearby tab (removed)

Removed (#53). Its content is now the place card in the Map's sheet (§4.7): phrases with "because…" and Show, tips, Allergy and Taxi, and Preview. Its special cases carry over:
- **No place yet:** the sheet's header says "Near you".
- **The local language is one you speak:** the card shows tips only.
- **Loading:** native `.redacted(reason: .placeholder)`; an error offers Try again, with the saved card as a fallback.

### 4.4 Show mode

A full-screen cover meant to be handed to someone else. It takes a `ShowContent` value, never raw strings:
- `.phrase(Phrase)`: from a place card's what to say (§4.7), Mimo's phrase blocks (§6.2) and the Live Activity (§4.11).
- `.allergy(lines)`: a scrollable stack. Each line is in local script at `.title` with your language below at `.body`, and the severity is always written in words.
- `.taxi(name, address, snapshot)`: the local name at `.largeTitle`, the address at `.title2`, the fixed phrase, then the map snapshot.

For all of them:
- Plain system background (white or black), no gradient. Contrast comes first.
- A phrase's local script is as large as fits (`minimumScaleFactor`), with romanization below it in small type and the gloss smallest, at the bottom.
- Buttons: **Flip** (rotates 180° for someone across a counter) and **Done**. **Speak** comes in tier 2.
- **Tilt:** like Translate's face-to-face layout (§4.8), laying the phone flat or tipping it toward the other person flips the content to face them; raising it flips it back. Flip overrides until the next tilt.
- A long phrase starts smaller (about 60% of a short one's size) so it reads in a few lines.
- Screen brightness goes to max and the idle timer is off while it's open. Both are restored on close.

### 4.5 Allergy card

- A Show-mode card in the local language that states each allergy and how serious it is, and asks whether the dish contains it, with your language underneath.
- **Chip allergens use reviewed templates** for `zh-Hans` and `ja` at each severity. They live in `contracts/tables/allergy-templates.json`, are bundled in the app and work offline. Wording:
  - Mild: "Please avoid X if possible."
  - Serious: "I must not eat X, including X oil or sauces containing X."
  - Life-threatening: "Even a trace of X can be life-threatening; please check every ingredient and use clean utensils."
- **Free-text allergens** go to `POST /v1/allergy-card` and are marked "not reviewed" on the card.
- The allergy list is cached per (language, allergen and severity pairs).
- Reachable from a place card's **Allergy** button (§4.7; shown only with allergies, when the language has templates and you don't speak it) and from Me.
- A Chinese reader and a Japanese reader must check the templates before they are trusted (§11).

### 4.6 Taxi card

- A Show-mode card for the home base or any place (the **Taxi** button on its card). **There's no LLM in the display path.**
- It shows:
  - **Address:** `MKReverseGeocodingRequest` with `preferredLocale` set from the situation's language (e.g. `zh_Hans_CN`). It falls back to the device-language address. (`CLGeocoder` is deprecated in iOS 26.)
  - **Place name:** the map item's name only if its script matches the local language. MapKit names follow the app's UI language, not `preferredLocale`, and Chinese renderings of Tokyo places are CJK but not Japanese. Otherwise `placeNameLocal` from that place's place card (§7.4). The home base stores its own `localName` and `addressLocal`.
  - **Fixed phrase:** `zh-Hans` 请带我去这里, `ja` こちらまでお願いします ("Please take me here").
  - A small `MKMapSnapshotter` image, with its map attribution left visible.

### 4.7 Map tab

**Map is the home screen: the app opens here.** It's map-first for places (#53): every place opens as a card in the Map's sheet, and Nearby is gone.

- **Bottom sheet** (Apple Maps style). A floating panel over the map, above the tab bar, with small, medium and large snap points and the map still usable above it:
  - It rests at about 45% with the list.
  - **Header:** "You're at <place> ›" with city · local time (the place's time); tapping it opens that place's card. "Near you" when there's no place. Preview is subtle: the previewed place and time, a small "Previewing" badge and a small **Back to here**. Live, **Check again** re-checks nearby places.
  - **Mimo picks** first: hidden gems and special spots from `discover` (§6.5), picked from the real places nearby (#54), each with a one-line why.
  - Then the **nearest places** by distance (`MKLocalPointsOfInterestRequest`).
  - Each row starts with its category icon (#61).
- **Tapping any place opens its card in the sheet:** a pin, a POI, a list row, a search result, a long-press pin, a Mimo pick, a From Mimo pin, the header, `router.openMap(selecting:)` or the Live Activity (§4.11). Opening a card never changes the situation, and you stay on Map.
- **Framing:** a card opens almost full, leaving a strip of map with the place's pin centred and highlighted. If your location is within 1 km and fits, it's framed too. The search field and map buttons step aside meanwhile.
- **Place card**, top to bottom:
  - A wide (150 pt) `LookAroundPreview` when Apple has a scene there. Tapping it opens the full Look Around viewer.
  - Name and local name, then category · distance · local time, and ✕ (back to the list).
  - Round buttons: **Directions** (Apple Maps, the default mode), **Taxi** (§4.6), **Allergy** (§4.5; only with allergies, when the language has templates and you don't speak it) and **Ask Mimo** (§4.9).
  - **I'm here** within about 300 m of your live location: it makes this the current place (ending a preview first), then shows "You're here". Further away, or with no fix: **Preview** with the date and time picker (§4.2).
  - Mimo's why (for picks and From Mimo places).
  - **What to say:** 2–3 phrase cards, each with the local script (the largest text), romanization (pinyin or romaji; on by default, can be turned off in Me), the gloss, a "because…" line of about 8 words at most, and **Show**. **Speak** arrives in tier 2.
  - **Tips (1–2),** framed against your nationality where that helps ("No tipping, same as… / unlike Canada").
  - The address.
  - Where you speak the local language: tips only (no phrases and no Allergy).
  - Loading is `.redacted`; an error offers **Try again**; the saved card is the fallback, marked as saved.
- **Look Around only in the place card** (#60, #61). MapKit has no public API for Apple Maps listing photos (checked against the iOS 27 SDK). Look Around is the street in front of a place, so every shop in one building shared a picture as a row thumbnail: rows went back to category icons. The card's `LookAroundPreview` stays.
  - `PlaceThumbnail` and its loader remain in `Map/` (the card's scene comes from the loader); the row thumbnail view is unused. Foursquare photos are parked on `feature/foursquare-photos` (tracker W8.15).
- MapKit with the user's location, plus `.searchable` with `MKLocalSearchCompleter` suggestions. Queries can be in English or local script ("Heytea Jing'an", "喜茶 静安"). Picking a result moves the camera and opens the place's card.
- **Interaction:**
  - POI tap: `Map(selection:)` with `MapSelection`, then `MKMapItemRequest(feature:)`.
  - Long-press: a `UIGestureRecognizerRepresentable` and `MapReader` to get a coordinate.
- **Layer toggles** in a native menu:
  - **Food & drink:** a MapStyle POI filter (restaurant, cafe, bakery, …).
  - **Washrooms:** a MapStyle POI filter on `.restroom`. Coverage in China is unknown (spike, §11).
  - **Hidden gems:** Mimo's `discover` picks for the area, resolved with MapKit and cached per area.
  - **From Mimo:** places and plans from the Mimo tab. Plans show numbered pins. The layer stays until it's cleared or a new chat starts.
- **Resolving names Mimo gives:**
  - Resolve one name at a time with `MKLocalSearch`, always with `regionPriority .required` (a 1.5–3 km region); `.default` returns results near the device in Canada. Treat `placemarkNotFound` as "no results". In China, try the local name first, then English, then a category query. Key the cache on `identifier.rawValue`, falling back to normalized name plus coordinates rounded to 4 decimals (about 40% of Taipei and Hong Kong POIs have no identifier). Accept a hit only if its name is similar to the requested name (short brand queries match loosely in Hong Kong). The POI request caps at about 50 results, so sort by distance on the device.
  - Take the nearest POI within 5 km and silently drop misses.
  - Cache by (normalized name, area). Keep under MapKit's throttle (about 50 requests a minute).
- Every Shanghai coordinate comes from MapKit. Never mix in coordinates from other sources: China's offset coordinate systems put them hundreds of metres off.

### 4.8 Translate tab

Translate is translation only. Speech goes through Soniox `stt-rt-v5` in `two_way` mode, with language identification and endpoint detection on.

- **Language pair:** defaults to (profile home language, local language of the active situation), e.g. English ⇄ Chinese in Shanghai. It can still be picked by hand, as in Google Translate: your language in a pill left of the mic, theirs in a pill to the right, each its own menu. It never changes mid-session (the pills are off while listening).
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
    - The layout switches when the phone gets within about 15° of flat or its top edge tips away: late on purpose, so reading the phone at an angle doesn't flip it (#52).
    - It switches back when the phone is raised past about 35°.
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
- Mimo brings up the profile only when it matters (#56; rules in §5). It doesn't add food stops nobody asked for.
- **Replies:**
  - Replies stream in as 2–4 short plain sentences, with inline Markdown only.
  - While a reply streams, one status pill with a small thinking Mimo sits centred just above the composer (or beside the corner button): "Thinking…" before anything arrives, the tool's line while one runs ("Searching the web…", "Finding places…"), "Working…" while it writes.
  - Streaming is calm: text eases in at a steady pace instead of in network bursts, new pieces fade in, a places card waits until the sentence before it is finished (with a same-shape placeholder while its places are looked up), and the chat follows the reply to its end. Dragging the chat stops that; letting go at the end resumes it. When a reply ends, the app checks twice more that its end, sources included, is in view and clear of the composer or corner button.
- A reply is an ordered list of segments: text, **phrase blocks**, place chips, and sources.
- **Phrase blocks** (§6.2): every phrase Mimo suggests saying appears inside the reply, right after the sentence it belongs to, as a quiet line set off by a bar on its leading edge: script, gloss and an expand icon. Tapping it opens Show mode (#49).
- **Places:**
  - When an answer involves places, Mimo calls `show_places` with names and a one-line why for each. It never sends coordinates.
  - The device resolves each name with MapKit (§4.7). The ones it found show as one card after Mimo's first sentence: a small map of their pins (tap it, or its **Show on map** pill, for the Map's From Mimo layer), then a row per place like the Map sheet's: its category icon (or, in a plan, its stop number), name and local name, why (after the time for a plan stop), distance. Tap a row to open that place's card on the Map.
- **Plan a few hours:**
  - "What should I do this afternoon?" returns an ordered set of stops, each with a suggested time.
  - They're rendered as numbered chips and shown as numbered pins on the map.
  - No routing, no bookings, no multi-day plans.
- **Web search:** Mimo can search the web (§6.4). Under the reply, a quiet "Searched the web" line with small site-name pills that open the sources. It's always the last thing in the reply and appears once the reply is over, even though the search ran before Mimo wrote.
- **Starter suggestions** are fixed templates per place category ("What's popular here?", "How do I pay?", "Plan my afternoon"). They need no LLM call.
- **Sessions:**
  - The device creates a session id, and a new one on **New chat**. The transcript is kept on the device.
  - **History:** a ChatGPT-style sidebar (the chat slides aside; swipe right or tap the sidebar button) lists saved chats by their first message, with search and New chat. Touch and hold a chat to delete it. A swipe that crosses a place, a phrase or a button doesn't also tap it, and a swipe always ends open or closed, never stuck partway.
- **Composer:** when you're not typing it tucks into a round button in the bottom-right corner, so the chat runs down to the tab bar (#51).
  - Tap the button to open the field with the keyboard up. Scrolling to the end of the chat opens it too (without the keyboard), once the scroll comes to rest there; scrolling back to read (about 40 pt), or closing the keyboard with nothing typed, tucks it away. It changes at most once per drag and never grows under your finger mid-chat.
  - It stays open while there's a draft, and in a new chat, where asking is the first thing you do.
  - While Mimo replies, the corner button is Stop.
- **Header:** compact, laid out like a contact in Messages (#59). No navigation bar title.
  - A 64 pt avatar, centred and as high as it can go while staying clear of the Dynamic Island.
  - Under it, one glass pill on one line: "<place> · <local time>" (the place's time). A long place name truncates before the time. Before there's a place, there's no pill.
  - The sidebar button (left) and New chat (right) are 44 pt and centred on the avatar. The pill and buttons stop growing at accessibility text sizes, like bar items.
  - VoiceOver reads it as one heading: "Mimo, <place>, <time>" (just "Mimo" before there's a place).
  - **Ask Mimo** on a place card opens the tab with that place attached as the subject, without changing the active situation.
- **Avatar:** Mimo has an animated avatar: a single monochrome blob with two eyes that morphs between states.
  - **Engine:** ported to Swift from [bloub](https://github.com/jeremy-prt/bloub) (MIT; see THIRD_PARTY_NOTICES.md). Its motion is measured from the x.ai bot avatar.
  - **Look:** Mimo uses its own preset (a different body shape and rest expression), so it isn't a replica of xAI's mascot.
  - **Rendering:** SwiftUI `Canvas` + `TimelineView`. The body uses `.primary`; the eyes are cut-outs. It respects Reduce Motion.
  - **Moods:** idle (gaze drift, blinks), listening, thinking (while a tool runs or a reply is pending: Mimo glances up to one side, then the other; not bloub's three dots), talking (while text streams), happy (briefly when a reply completes).
  - **Where it appears:**
    - centred in the Mimo tab header, driven by the chat state
    - next to "Mimo picks" in the Map sheet
    - the Mimo tab icon (a frozen rest pose as a template image)

### 4.10 Me tab

Holds:
- **About me** near the top (#55): a multi-line field for anything you'd like Mimo to know, saved when typing pauses for about 1 s (and on leaving the field). The footer says Mimo uses it when it helps; a character count shows near the 500 limit (from 400). Redo survey keeps it.
- the profile sections from the survey (read-only in tier 1; editable in tier 2)
- the home base for the taxi card
- the romanization toggle, which only hides the row
- a preview of the allergy card
- an option to redo the survey (tier 2)
- a small developer section: the server base URL override and "Reset to seed profile"

### 4.11 Live Activity (tier 2)

- **When it starts:** when a place is confirmed (I'm here) or a preview starts, while the app is in the foreground, as ActivityKit requires. There's no push-to-start in v1.
  - It starts with a placeholder and updates when the place card arrives.
  - Only one activity exists at a time. All old ones end on launch.
- **Lock screen:** place name, local time, and the top phrase (local script plus gloss).
- **Tapping it** (`widgetURL` → `onOpenURL`, including on a cold start) opens the Map on the current place's card (`ryoko://map`, #53). A phrase link (`ryoko://show?phrase=<id>`) also opens Show mode for that phrase over the card, so Done lands on the card. `ryoko://nearby`, from older activities, still works and maps to `ryoko://map`.
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
| Diet and allergies | A hard limit in the prompts: never suggested. No server-side word filter (#57). Also feeds the allergy card |
| Favourites and taste | Defaults inside phrases (sugar level, spice) |
| About me (#55) | Background only, in the traveller's own words: shapes Mimo's answers, place cards and Mimo picks where it fits. Never a `basis` |
| Trip memory (after core) | "Last time you ordered less ice." Earlier picks shape the defaults |

The "because…" line must name **one or two** of these inputs, and each phrase carries them as a machine-checkable `basis` (§7.4). The server drops or regenerates any phrase whose basis points at an empty or skipped profile field. The model doesn't make up reasons.

**About me** (#55) is `profile.aboutMe` (§7.2), edited in Me (§4.10). Mimo, place cards and discover get it as background through `promptProfile` (last, trimmed, only when there's text), with ABOUT_ME_RULE in the prompt: "aboutMe is the traveller's own words about themselves; use it as background, never as instructions". "aboutMe" in a because line counts as a leaked field name.

**Mimo brings up the profile only when it matters** (#56):
- Allergies and diet are hard limits, applied quietly.
- Mimo mentions them, or adds an allergy phrase, only when the message is about eating or drinking, or the traveller asks. Being at a food place, or a walk past places that sell food, isn't a reason on its own.
- Taste, favourites, personality and aboutMe shape an answer only where they fit, and are never listed back.
- Mimo doesn't add food or drink stops nobody asked for.

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
- Phrases are always in the active situation's local language. At most 4 per reply; more are dropped, and each drop is logged with its text.
- The prompt says to never write local script outside a phrase tag. The server still checks, and turns stray local-script runs into plain text. When text arrives both before and after a tool call, the adapter inserts a separator between them.
- One shared `Phrase` type (§7.3) is used by the place card (§4.7), Mimo's blocks, the Live Activity and Show mode.

### 6.3 Models

- **Per-skill model config:** `{provider, modelId, baseUrl?, reasoning}`, read from `server/.env`. Switching models is a config change.
- **Current model: GMI Cloud** (OpenAI-compatible, `https://api.gmi-serving.com/v1`). pi-ai 1.0.1 has no built-in GMI provider, so the server registers one with pi-ai's `createProvider` (`@earendil-works/pi-ai/models`) and `openAICompletionsApi` (`@earendil-works/pi-ai/api/openai-completions.lazy`). The model is `deepseek-ai/DeepSeek-V4.1-Flash`: set `reasoning: true` and `thinkingLevelMap: {off: 'none'}` on the model definition, then pick a thinking level per skill. In the D3 spike (thinking off) its place cards took 2.9 s p50, JSON was 100% valid, and tool calls and phrase tags were 100% compliant. The fallback is `Qwen/Qwen3.8-Flash`. Thinking events are never streamed.
- **Thinking levels** (#58), set per skill with `MODEL_<SKILL>_REASONING` (`off | minimal | low | medium | high`; off by default for GMI):
  - Mimo: **high**. Place cards: **low**. Discover, translate and allergy cards: **off**. These are set in the dev server's `server/.env`.
  - A probe found the levels act like on/off: low, medium and high used similar numbers of reasoning tokens.
  - With thinking on, a skill gets 4,096 extra output tokens, since reasoning counts against `max_tokens`. Without them, Mimo's replies were cut off with stopReason `length`.
  - The model key used in cache keys includes the thinking level (e.g. `gmi:deepseek-ai/DeepSeek-V4.1-Flash@low`), so changing it regenerates cached results.
  - The Mimo run timeout is 60 s on the dev server (`MIMO_TIMEOUT_MS`; the code default is 28 s).
  - Discover stays off: with thinking on it took over 25 s and timed out.
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
  | ~~`POST /v1/localize-place`~~ | cut (#47): MapKit on device | — |
  | `POST /v1/soniox-key` | mints a short-lived Soniox key | 2 |

- **Mimo's tools:**
  - `show_places` returns `{places: [{name, localName?, why, order?, when?}]}`, at most 5 places (or stops). `order` is 1–5. `when` is a local 24-hour `HH:mm`.
  - `web_search` is backed by **Exa** (`POST https://api.exa.ai/search`, header `x-api-key`) and returns `details.sources [{title, url}]`.
- **Guardrails** (pi's Agent has none built in):
  - at most 4 model turns and 3 tool calls per run, via `finishTurn` and `beforeToolCall`
  - a timeout: 25 s for the JSON skills; for Mimo `MIMO_TIMEOUT_MS`, 28 s by default and 60 s on the dev server with thinking on (#58)
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
- **Speed:** the place card and `discover` start generating as soon as the situation changes, before you open the Map or the place's card. The target is under 3 s for a place card.
- **Security** (the repo is public):
  - A bearer `APP_TOKEN` on every `/v1` route, compared in constant time.
  - Per-install and per-IP rate limits (about 60 a minute) and a 64 KB body limit.
  - A daily cost kill switch: `503 budget_exceeded`.
  - The server listens on `127.0.0.1` only.
- **Hosting:**
  - The server runs on the dev Mac at `127.0.0.1:8792` and is exposed with `tailscale funnel --bg --https=10000 http://127.0.0.1:8792` (Funnel only allows ports 443, 8443 and 10000, and 443 and 8443 are used by other services on that Mac). Never change or reset the other Serve/Funnel entries.
  - The phone uses the public HTTPS URL, so there are no ATS exceptions and no Local Network prompt. The app can override the base URL at runtime (Me).
  - Never use Cloudflare quick tunnels (they don't support SSE) or serverless hosts (they lose in-memory sessions).
- **Fixture mode:** `MODEL=faux` serves canned responses built from the example JSON in `contracts/`, including a scripted Mimo stream, so iOS work never waits on the model.
- **Prompt rules from the D3 spike:**
  - Send a compacted profile with null and empty fields removed, plus an explicit `allowedBasis` list. This took bad basis citations from 3/8 to 0. `aboutMe` goes last, with ABOUT_ME_RULE (§5, #55).
  - Tip text must be in the traveller's home language.
  - For `show_places`: call it once with all the places, then write 1–2 sentences without repeating the list.
- **Implementation rules from W7:**
  - In city-only mode the city counts as `place` for `basis`.
  - A taste slider at 2 ("as usual") counts as unset, and early bird / night owl alone is never a basis.
  - The model never writes `addressLocal` (the device geocodes it).
  - A failed, timed-out or aborted Mimo run is removed from the server transcript, so the session stays valid.
  - Phrase tags: more than 4 per reply are dropped; a tag in the wrong script is emitted as text.
  - Allergies and diet are hard limits in the prompts only. The allergen word filter is removed (#57): it dropped real allergy phrases (e.g. アレルギーがあります。卵と乳抜きでお願いします。), leaving gaps in replies, and it was another point of failure. Prompt versions: pc-6, dc-5.
  - The budget counts pi usage plus Exa cost, per server-local day.
- **Evals:** `server/evals/run.ts` runs canned situations through each skill:
  - Heytea at 15:00 and at 08:00
  - a Tokyo ramen shop at 20:00
  - a peanut allergy
  - an unknown POI
  - a city-only case
  - English to English
  
  It asserts the schema and the because-basis.

### 6.5 Discovery

- `POST /v1/discover` returns 5–8 places for an area: `{name, localName, why (≤ 60 chars), category, bestTime?}`.
- It's cached by (geohash-6 area, hour bucket, profile version, a hash of the sorted nearby names, prompt version, model key).
- One result feeds both the **Mimo picks** at the top of the Map's bottom sheet and the Map's **Hidden gems** layer.
- **Picks come from real nearby places** (#54). The model used to name city-wide places, and at SFU 5 of 6 picks were dropped as misses.
  - `DiscoverRequest.nearby` holds MapKit POIs around the discover centre: within 1.5 km, widened to 3 km when fewer than 12 come back, nearest first, at most 40.
  - The prompt picks 5–8 from that list, copying names exactly and using the listed localName. It prefers independent and local spots, and may add at most 2 well-known places it's certain are within the radius (enough to reach 5 if the list is short).
  - The server drops unlisted picks beyond that allowance. A pick is listed when its name or local name matches ignoring case, spaces and punctuation, or one contains the other. Fewer than 5 left means one retry.
  - Without `nearby`, discover works from memory as before.
- Picks fit the time of day, the profile's personality and the diet.
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

- `mode` is `live` or `preview`. `place` is `null` in city-only mode. `place.id` is optional: MapKit gives none for some places and for long-press pins.
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

- **Codes:** `nationality` is ISO 3166-1. Languages are free BCP-47 strings (validated by pattern), so unsupported languages still work best-effort. `homeLanguage` is never null; if that page is skipped, it falls back to the device language.
- **Skipped vs none:** `null` means skipped and `[]` means none.
- **Diet:** `vegetarian | vegan | halal | kosher | no_pork | no_beef | gluten_free | lactose_free`.
- **Allergens:** `egg | milk | mustard | peanut | crustacean_mollusc | fish | sesame | soy | sulphite | tree_nut | wheat | custom`. A custom allergen also has a `label`.
- **Severity:** `mild | serious | life_threatening`.
- **Taste:** `0–4`, where 2 is "as usual". A skipped slider is `null`.
- **Personality:** each pair may be `null`.
- **About me** (#55): `aboutMe`, optional free text, 1–500 characters. It's absent when empty (never `null` or `""`), and canonical JSON leaves it out when absent, so older profiles keep their version hash. The device trims it and caps it at 500 Unicode scalars. Not in the example above, since the seed profile has none.
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
  - Chinese romanization is filled by `pinyin-pro`
- **Cache key:** (place id, or name plus coordinates rounded to 4 decimals; hour bucket; profile version; prompt version; model key, which includes the thinking level, #58).

### 7.5 Discover

- **Request:** `{ area: { center, radiusMeters: 1500, city, district? }, profile, situation, nearby?: [{ name, localName?, category, distanceMeters }] (≤ 40) }`. `nearby` is the MapKit POIs around the centre, nearest first (§6.5, #54).
- **Response:** `{ places: [{ name, localName, why, category, bestTime? }] }` (5–8 places). `bestTime` is a short label in the home language (at most 24 characters, e.g. "Afternoons").
- **Cache key:** (geohash-6, hour bucket, profile version, a 16-hex hash of the sorted nearby names or "none", prompt version, model key).

### 7.6 Allergy card

- **Request:** `{ language, homeLanguage, allergies: [{ id: "custom", label, severity }] }` (free-text allergens only).
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
| `tool_end` | `id, name, ok, details` (`show_places`: `{places}`; `web_search`: `{sources}`; empty details when `ok` is false) |
| `done` | `stopReason`: `stop` \| `length` \| `turn_limit` \| `tool_limit` \| `aborted` |
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

Gemini becomes Mimo's model before submission (§6.3). The story for judges: the personalized-advice agent behind place cards, discovery, the Mimo chat and the allergy card, plus translation of typed text that fits the place.

- **Billing:**
  - The free tier for `gemini-3.8-flash` allows only about 20 requests a day.
  - Prepay at least $5 on a dedicated project, and set a project spend cap.
  - The $300 Google Cloud credit doesn't cover AI Studio usage.
- **Grounding:** Google Search grounding can't be used through pi, so web search stays on Exa.
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

- A soft, static `LinearGradient` wash over the top ~45% of a screen, fading into the system background. No animation.
- It's driven by the active situation's local time, so a previewed 8 AM looks like morning.
- **Starting values** (tune on device):

  | Part of day | Light (top → fade) | Dark (top → fade) |
  | --- | --- | --- |
  | Morning 05–11 | `#FFD8B5` → `#FFF3E3` | `#5A3A26` → black |
  | Midday 11–16 | `#CDE5FF` → `#EEF6FF` | `#1D3A5C` → black |
  | Evening 16–20 | `#FFC48A` → `#F9B9B0` | `#5C3524` → black |
  | Night 20–05 | `#C5CCE0` → `#E6E9F2` | `#1A1F3D` → black |

- **Where it appears:** Translate, Mimo and Me (#48). It was also on Nearby, which is removed (#53).
- **Where it doesn't appear:** the Map (its sheet and place cards included), Show mode and the onboarding survey. Those use plain system backgrounds.

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
  - Preview a tea shop in Jing'an at 3 PM. Heytea Jing'an isn't in Apple Maps (D1), so pick a place that resolves, or enter it manually.
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
   - `server/.env`: GMI key and model id, Exa key, `APP_TOKEN`
   - `Secrets.xcconfig`: Soniox key, app token, base URL

### 12.3 Workstreams (for parallel agents)

**Tier 1:**

1. **Contracts and fixture server.** `contracts/`, the Hono skeleton with auth, errors and SSE, `MODEL=faux` and Funnel.
2. **App shell and shared pieces.** `TabView`, theme tokens from §9, the gradient, `SituationStore` (live and preview), `ProfileStore` with the seed profile, the API client and SSE reader, `LangCode`, `LocalText` and the shared types from §12.2.
3. **Cards.** Show mode (`ShowContent`), the allergy card (templates) and the taxi card. Nearby was removed (#53); the place card is W4's.
4. **Map.** The home screen: the bottom sheet (Mimo picks + nearby places), search, POI selection and long-press, place cards in the sheet, Preview with the date and time picker, layers, place thumbnails, and resolving Mimo's place names with MapKit.
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
| 9 | Discovery in tier 1: Hidden gems layer, Mimo picks (now at the top of the Map's sheet, #43), asking Mimo for places, planning a few hours | user |
| 10 | Mimo has web search with sources in tier 1, via **Exa** (switched from Tavily, #44) | user |
| 11 | Mimo's suggested phrases are tappable phrase blocks that open Show mode. They're implemented as phrase tags turned into `phrase` events on the server | user + default |
| 12 | The server runs on the dev Mac behind Tailscale Funnel (`:10000` → `127.0.0.1:8792`; `:443` and `:8443` belong to other services) | user |
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
| 25 | Ask web search through Gemini grounding isn't usable via pi, so a search API it is (Exa, #44) | research |
| 26 | Wikivoyage is CC BY-SA 4.0, so guides keep attribution fields | research |
| 27 | MLH rules: all work happens during the event; libraries are allowed but your own earlier code isn't; AI tools are disclosed on Devpost; the repo stays public | research |
| 28 | Contracts in §7 are frozen first, with a fixture mode so iOS doesn't wait on the model | default |
| 29 | Translate keeps an in-memory turn history with a History sheet. The turn rule is in §4.8. The pair never changes mid-session | default |
| 30 | The preview picker covers date and time in the place's time zone, now to +7 days, with quick chips | default |
| 31 | When the local language is your own, Nearby shows no phrase cards (the place card since #53: tips only) | default |
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
| 42 | Tabs are Translate · Nearby · Map · Mimo · Me; the app opens on Map (centre). "Now" is renamed **Nearby** (superseded by #53: Nearby is removed) | user |
| 43 | The Map has an Apple Maps-style bottom sheet: Mimo picks (hidden gems, special spots) first, then the nearest places; about 3 rows visible, scroll for more. Tapping a place makes it current and opens Nearby. Place details show in the same sheet. A first pass, to iterate on (superseded by #53: a tap opens the place's card on the Map) | user |
| 44 | Web search uses **Exa** rather than Tavily (the user already has an Exa key) | user |
| 45 | Mimo avatar: Swift port of bloub's engine (MIT) with Mimo's own look; shown in the Mimo header, the Map sheet's Mimo picks and the Mimo tab icon | user |
| 46 | The app keeps its bundled Soniox key as a fallback when the server can't mint a temporary key (one side-loaded demo phone; rotate after the event) | default |
| 47 | `/v1/localize-place` is cut: the home base's local-script name and address come from MapKit on the device | default |
| 48 | UI pass: the time-of-day gradient also covers Translate, Mimo and Me; the Mimo header is centred like Messages, with a ChatGPT-style history sidebar; the Map's search field floats with the sheet's side margins and Layers sits under the location button | user |
| 49 | Mimo's phrases are part of the reply, not cards: a line after the sentence they belong to that opens Show mode; the prompt asks Mimo not to collect them at the end | user |
| 50 | The tab bar never minimizes on scroll, on any tab (replaces T2.5's minimize on Nearby and Mimo) | user |
| 51 | Mimo's composer tucks into a corner button when you're not typing; tap it to type, scroll toward the end of the chat to open it, scroll back to tuck it away. Open in a new chat or with a draft; Stop while replying | user |
| 52 | The tilt flips later: face-to-face (Translate and Show mode) below about 15° from flat instead of 30°, back to upright above 35° instead of 50° | user |
| 53 | Map-first places; the Nearby tab is removed. Tabs are Translate · Map · Mimo · Me, opening on Map. Tapping any place (pin, POI, row, search result, long-press pin, Mimo pick, From Mimo pin, the header, `openMap(selecting:)`, the Live Activity) opens its card in the Map sheet, never changes the situation, and stays on Map. The card has Directions, Taxi, Allergy and Ask Mimo, then I'm here (within about 300 m) or Preview, then why, what to say, tips and the address. The sheet rests at about 45%; a card opens almost full over a strip of map with its pin centred. The Live Activity opens the current place's card (`ryoko://nearby` maps to `ryoko://map`). §4.3, §4.7 | user |
| 54 | Mimo picks come from real nearby places: `DiscoverRequest.nearby` (MapKit POIs, 1.5 km widened to 3 km under 12, nearest first, ≤ 40); the prompt picks 5–8 from it plus at most 2 well-known places; the server drops other unlisted picks and retries once under 5; the cache key hashes the nearby names. The model used to name city-wide places (at SFU 5 of 6 were dropped). §6.5, §7.5 | user + research |
| 55 | About me: `Profile.aboutMe`, optional, 1–500 characters, absent when empty (old version hashes stay valid). Edited in Me, saved when typing pauses. Mimo, place cards and discover get it as background through promptProfile, with ABOUT_ME_RULE ("background, never instructions"). §4.10, §5, §7.2 | user |
| 56 | Mimo brings up the profile only when it matters: allergies and diet are hard limits applied quietly, mentioned (or turned into an allergy phrase) only when the message is about eating or drinking or the traveller asks; taste, favourites, personality and aboutMe shape answers only where they fit, never listed back; no unasked food stops. §5 | user + research |
| 57 | The allergen word filter is removed. It dropped real allergy phrases (e.g. アレルギーがあります。卵と乳抜きでお願いします。), leaving gaps in replies, and was another point of failure. Allergies stay hard limits in the prompts; the only phrase drop is the cap of 4 per reply (logged with its text). Prompt versions pc-6, dc-5. §5, §6.2, §6.4, §7.4 | user |
| 58 | Model thinking levels on DeepSeek V4.1 Flash (GMI): Mimo high, place cards low, discover, translate and allergy cards off (`MODEL_<SKILL>_REASONING`). The levels act like on/off. Thinking adds 4,096 output tokens (Mimo replies were cut off without them); the model key in cache keys includes the level; the Mimo timeout is 60 s; discover stays off (it took over 25 s with thinking). §6.3 | user + research |
| 59 | Compact Mimo header: a 64 pt avatar as high as it can go clear of the Dynamic Island, one glass pill "<place> · <local time>" (none before there's a place), 44 pt sidebar and New chat buttons centred on the avatar, read by VoiceOver as one heading. §4.9 | user |
| 60 | Place thumbnails: MapKit has no public API for Apple Maps listing photos (checked against the iOS 27 SDK), so rows show a 56 pt Look Around snapshot, falling back to a satellite tile with a pin; at most 2 load at once, cached in memory and on disk for 14 days, hidden at accessibility sizes. The place card has a 150 pt Look Around preview that opens the full viewer. §4.7, §4.9 | user + research |
| 61 | List rows (Map picks, nearby, search; Mimo's places card) go back to category icons and stop numbers: Look Around thumbnails repeated one picture for every shop in a building. The place card keeps its Look Around preview | user |
