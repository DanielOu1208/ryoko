# Ryoko

An iPhone travel app built for StormHack 2026. Ryoko uses your location, local time and preferences to suggest what to say in the local language. Mandarin and Japanese are the main focus.

Walk into a tea shop, get a phrase that fits your order, and show it to the staff. Mimo, the app's travel companion, can also suggest nearby places and help you plan a few hours.

## What's in the app

- A map with nearby places, Mimo picks and previews for another place or time.
- Phrase cards with translations, romanization and a short reason for each suggestion.
- Full-screen Show mode, plus allergy and taxi cards.
- Mimo chat with phrases, place suggestions and web sources.
- Two-way voice translation with a face-to-face layout. Real speech still needs a valid Soniox key and testing on an iPhone.

The app uses SwiftUI and MapKit. Mimo runs on a Node 24 server using Hono and pi, with GMI Cloud for model calls and Exa for web search. Soniox handles speech translation.

## Run locally

You'll need Xcode with the iOS 26.1 SDK or later, Node 24 and pnpm.

```sh
pnpm install
cp server/.env.example server/.env
cp ios/Config/Secrets.example.xcconfig ios/Config/Secrets.xcconfig
cp ios/Config/Local.example.xcconfig ios/Config/Local.xcconfig
```

Set `APP_TOKEN` in both `server/.env` and `Secrets.xcconfig` to the same value, then start the fixture server:

```sh
pnpm server:faux
```

Open `ios/Ryoko.xcodeproj`, choose the `Ryoko` scheme and run on an iPhone simulator. The default server URL is `http://127.0.0.1:8792`. In Me → Developer, choose the live server to connect to the local fixture server, then preview a sample place and open Nearby.

Fixture mode uses sample responses without model keys. For live Mimo setup, see [server/README.md](server/README.md). Keep `.env`, `Secrets.xcconfig` and `Local.xcconfig` out of Git.

## Project docs

- [Product and design](resource/design.md)
- [Build progress and known gaps](resource/implementation-tracking.md)
- [API contracts](contracts/README.md)
