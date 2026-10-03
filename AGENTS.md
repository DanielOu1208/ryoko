# AGENTS.md: conventions for coding agents

Ryoko is an iOS travel app. **Mimo** is its agent, served by a Node server. Before you start:
- Read [`resource/design.md`](resource/design.md), the source of truth: your feature section, plus §6, §7, §9 and §12.
- Find your task in [`resource/implementation-tracking.md`](resource/implementation-tracking.md) and mark it `doing`, with an owner and a branch.

## Hard rules

- **The repo is public.** Never commit keys, tokens, `.env`, `Secrets.xcconfig`, `Local.xcconfig` or `.p8` files. Never inline a key in code, and never bypass GitHub push protection. Example config files hold placeholders only.
- **Everything is written during the hackathon.** Don't copy code from other projects on this machine. Third-party open-source packages are fine.
- **Never commit MapKit response dumps** (Apple Maps terms). Write fixtures by hand. Spike output goes in `spikes/**/out/`, which is gitignored.
- **Stay in your lane.** Edit only the folders your workstream owns (table below). Anything else goes through its owner, or a note in the tracker.

## Layout and ownership

| Path | Owner (workstream, design §12.3) |
| --- | --- |
| `contracts/` | W1 contracts. Others request changes; they don't edit |
| `server/` | W1 (skeleton, fixtures) and W7 (skills, models, caching) |
| `ios/Ryoko.xcodeproj` | Integrator only. Nobody else edits `project.pbxproj` |
| `ios/Shared/` | W2 shell. Shared types and protocols, compiled into the app **and** the widget extension |
| `ios/Ryoko/App/` | W2 shell (tabs, theme, stores, API client) |
| `ios/Ryoko/Nearby/`, `ios/Ryoko/Show/` | W3 Nearby and cards |
| `ios/Ryoko/Map/` | W4 Map (the home screen and its bottom sheet) |
| `ios/Ryoko/Translate/` | W5 Translate |
| `ios/Ryoko/Mimo/` | W6 Mimo tab |
| `ios/Ryoko/Me/`, `ios/Ryoko/Onboarding/` | Tier 2 onboarding and Me |
| `ios/Ryoko/Speech/` | Tier 2 speech |
| `ios/RyokoLiveActivity/` | Tier 2 Live Activity |
| `spikes/` | Throwaway experiments; results go in the tracker |
| `resource/` | The design doc and tracker. Everyone updates the tracker; spec changes go in `design.md` and its change log |

## iOS

- The project uses **synchronized folders**: a `.swift` file dropped into a folder is compiled automatically. Don't edit `project.pbxproj`. If you need a new target, capability, package or Info.plist key, ask the integrator.
- `ios/Shared/` is built into the widget extension too, so use only APIs available in app extensions there. No `UIApplication.shared`.
- The app target defaults to MainActor isolation but the extension doesn't, so types in `ios/Shared/` should be `nonisolated` and `Sendable` (see `RyokoActivityAttributes`).
- Keep non-source files such as plists out of the synced folders: anything in them gets copied as a resource. Config lives in `ios/Config/`.
- The app target enables `MemberImportVisibility`: any file that uses `RyokoLog` (an `os.Logger`) must `import os` itself.
- The contract type `Tip` shadows TipKit's `Tip`. In a file that imports TipKit, write `TipKit.Tip`.
- After any change to `contracts/` or `ios/Shared/`, run `ios/scripts/check-contracts.sh`. Add `--live` to also hit a running server on 8792.
- `DEVELOPMENT_TEAM` comes from the gitignored `ios/Config/Local.xcconfig` (copy `Local.example.xcconfig`); never set it in `project.pbxproj`.
- **Build:** use your own DerivedData per worktree so agents don't collide.
  ```
  xcodebuild -project ios/Ryoko.xcodeproj -scheme Ryoko \
    -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
    -derivedDataPath ios/.build/DerivedData-<your-workstream> build
  ```
- **Targets:** iOS 26.1, iPhone only, portrait only, Swift 6.
  - The app target defaults to `@MainActor` isolation.
  - Callbacks from audio taps (`AVAudioEngine.installTap`), CoreMotion handlers and other real-time threads must be `nonisolated` / `@Sendable`. MainActor-isolated tap closures crash at runtime.
- **Shared app state** is in the SwiftUI environment: `AppSituationStore`, `ProfileStore`, `APIStore`, `\.ryokoAPI`, `\.placeResolver`, `\.speechService` and `AppRouter`.
  - Cross-tab flows go through `AppRouter`: `openMap(selecting:)`, `mapFocus`, `mimoSubject`, `fromMimo` and `show` (Show mode). Never add tab state of your own.
  - **Situation time:** key async work on `.task(id: situation)`, build request bodies from `situationStore.currentSituation()` (it re-stamps live local time), and show clocks with `TimelineView(.everyMinute)`.
  - **Show mode:** set `router.show`, which `RootTabView` presents full screen. A view that is already inside a sheet presents `ShowModeView` itself.
- **Secrets** come from `ios/Config/Secrets.xcconfig` (gitignored; copy `Secrets.example.xcconfig`) through the Info.plist keys `RyokoAppToken`, `RyokoAgentBaseURL` and `RyokoSonioxAPIKey`. In xcconfig, `//` starts a comment, so write URLs as `https:/$()/host:port`.
- **Platform rules:**
  - Use `MKReverseGeocodingRequest`, not `CLGeocoder` (deprecated).
  - Use `.redacted(reason: .placeholder)` for loading states.
  - SF Symbols only; the Translate tab uses `character.bubble`.
  - Show local script through `LocalText`, which sets the language tag.
- **Styling and copy:** design §9. Monochrome controls, no glass on content, sentence case, no exclamation marks, and never "AI", "smart" or "magic" in the UI.

## Server

- Node 24 and pnpm. Hono 4 with `@hono/node-server`. `@earendil-works/pi-agent-core` and `@earendil-works/pi-ai` are pinned at exactly `1.0.1`; don't upgrade.
- Import `Type`, `Static` and `StringEnum` from `@earendil-works/pi-ai`. Use `StringEnum`, never `Type.Enum`.
- Config comes from `server/.env` (gitignored; copy `server/.env.example`). `MODEL=faux` serves fixtures from `contracts/` with no model calls. Use it for iOS work and tests.
- The server listens on `127.0.0.1:8792` only. Every `/v1` route needs `Authorization: Bearer <APP_TOKEN>`.
- Typed model output is provider-agnostic: schema in the prompt, parse the JSON, TypeBox `Value.Check`, retry once. Never rely on provider-specific JSON modes.

## Networking

- **Simulator:** `http://127.0.0.1:8792`. The app allows local networking through ATS.
- **Phone:** the public HTTPS URL of the Tailscale Funnel on port `:10000`. Never write the hostname into the repo.
- Never set `NSAllowsArbitraryLoads`. Never change or reset the other Tailscale Serve/Funnel entries on the dev Mac (`:443` and `:8443` belong to other services).

## Contracts

- `contracts/` holds the TypeBox schemas, example JSON, `mimo.sse.txt` and the language, category and allergy tables. Swift `Codable` mirrors live in `ios/Shared/`.
- If you need a contract change, describe it in the tracker and let W1 make it. Then update both sides in the same change.

## Git

- One branch per task or workstream (`ws/<workstream>-<short-name>`). For parallel agents, work in a separate git worktree.
- Keep commits small and buildable, and rebase on `main` before merging. Never force-push `main`.
- Before any push, run `git status`, and run `git check-ignore -v` on anything that looks like a secret.
- When a task lands, update the tracker row: status, a one-line note, and the PR or commit.
