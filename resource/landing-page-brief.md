# Ryoko: landing page brief

A guide for building the Ryoko landing page. The full spec is [`design.md`](design.md); § numbers below refer to it. When this brief and `design.md` disagree, `design.md` wins.

## Ground rules

- **Work in `site/`** at the repo root (or a separate repo). Don't touch `ios/`, `server/`, `contracts/` or `.env` files.
- **Static only.** Use the stack below, and point a `.tech` domain at it (MLH gives one free; this also covers the .Tech track).
- **Start from scratch.** MLH rules don't allow code written before the event, so don't copy files from other projects. Using the same stack is fine.
- **No secrets anywhere:** no API keys, no server URL, no Tailscale address, not even in screenshots.
- **Only claim what works.** Section 3 lists features in two groups. Check with Daniel before launch on which "coming soon" features actually shipped.

## Stack

The same setup as the AeriVoice site, minus everything a one-page site doesn't need.

| Piece | Choice | Why |
| --- | --- | --- |
| Framework | [Astro](https://astro.build) with `output: 'static'` | Plain HTML out, no JavaScript unless you add it, components for repeated sections |
| Styling | One `src/styles/global.css` with CSS variables for the colours in §5 | No Tailwind or UI kit needed for one page |
| Interactivity | None to start. Add `@astrojs/react` only if a section really needs it | Keeps the page fast |
| SEO | `@astrojs/sitemap`, `site` set in `astro.config.mjs`, Open Graph tags in the layout | Shareable link previews on Devpost and social |
| Hosting | Cloudflare Workers static assets, deployed with `wrangler` | Free, fast, custom domains in one config file |
| Language | TypeScript, Node 24 | Same as the server |

Setup:

```sh
npm create astro@latest site -- --template minimal --typescript strict
cd site
npx astro add sitemap
npm install -D wrangler
```

`site/wrangler.jsonc` (assets only, no Worker script):

```jsonc
{
  "name": "ryoko-web",
  "compatibility_date": "2026-10-03",
  "assets": { "directory": "./dist" },
  "routes": [{ "pattern": "<your-domain>.tech", "custom_domain": true }]
}
```

Scripts in `site/package.json`:

```json
"dev": "astro dev",
"check": "astro check",
"build": "astro build",
"deploy": "npm run build && wrangler deploy"
```

Deploy with `npx wrangler login` once, then `npm run deploy`. Before the domain is set up, leave out `routes`; it deploys to a `*.workers.dev` URL. To use the `.tech` domain, add it to Cloudflare as a zone (change its nameservers at get.tech), then add the `routes` entry.

## 1. What Ryoko is

**One line:** Ryoko knows where you are, what time it is there, and who you are, and hands you the right words in the local language before you need them.

**The moment that sells it:** You walk into a tea shop in Shanghai at 3 PM. Ryoko already shows the order you'd want, written in Chinese, with a line saying why it picked it ("you like it less sweet"). You show it to the staff. When they answer, Translate takes over.

**Who it's for:** travellers in China and Japan who don't speak the language. Mandarin (Simplified Chinese) and Japanese are the first-class languages.

**Mimo** is the companion behind the app: a calm local friend who writes your phrases, finds places worth going to, plans a few hours, and answers questions.

## 2. Key messages

Pick headlines from these. Each one is a real principle in the app (§1).

1. **The right words, before you need them.** Phrases come first. The thing you'll say next is the biggest thing on screen.
2. **Personal, and it tells you why.** Every suggestion carries a short "because…" line: your allergy, your taste, the time of day.
3. **Show it, don't struggle to say it.** Any phrase opens as a big full-screen card to hand to someone, with a Flip button for across the counter.
4. **A local friend in your pocket.** Mimo answers questions, finds hidden gems and plans an afternoon, with real places on a real map.
5. **Look ahead anywhere.** Preview any place at any time before you go: a Tokyo ramen shop at 8 PM, a Shanghai café tomorrow morning.

## 3. Features

### Core (safe to show)

| Feature | What to say | Spec |
| --- | --- | --- |
| Now | Where you are and what to say there: 2–3 phrases in local script with pinyin or romaji, a "because…" line, and cultural tips framed against your home country ("No tipping, unlike Canada") | §4.3 |
| Show mode | Full-screen phrase card at max brightness, Flip to face the other person | §4.4 |
| Allergy card | States each allergy and how serious it is in the local language, with your language underneath. Common allergens use reviewed wording and work offline | §4.5 |
| Taxi card | Your hotel or any place in local script, with "Please take me here" and a small map | §4.6 |
| Map | Search in English or local script, tap any place for phrases and tips. Layers for food and drink, washrooms, hidden gems, and Mimo's picks | §4.7 |
| Translate | Live two-way voice translation. Lay the phone flat between you and the screen splits: their language faces them, yours faces you | §4.8 |
| Mimo | Chat with a local friend: questions, places, a plan for the afternoon, web search with sources. Phrases in replies open as Show cards | §4.9 |
| Look-ahead | Preview any place at any date and time up to a week ahead | §4.2 |

### Coming soon (confirm before listing)

- **Speak:** phrases read aloud in a natural voice (ElevenLabs)
- **Lock screen and Dynamic Island:** your top phrase for the current place, one tap from the lock screen
- **Onboarding:** a 45-second survey for diet, allergies, taste and travel style
- **Type to translate:** typed translations that fit the place
- **Trip memory:** "Last time you ordered less ice." Suggestions improve as you travel

## 4. Suggested page structure

1. **Hero:** name, one-line pitch, a phone mockup of Now at a Shanghai tea shop.
2. **The moment:** the tea-shop story from §1 in three short steps (walk in → show the phrase → they reply, Translate takes over).
3. **Features:** Now, Show mode, Translate face-to-face, Mimo, Map. One short paragraph and one screenshot each.
4. **Built for safety:** the allergy card. A short, sober section, with no hype.
5. **Personal by design:** the "because…" line, with one example card.
6. **Built with:** SwiftUI and MapKit, Soniox (speech), Gemini and GMI Cloud (Mimo), ElevenLabs, Tiger Data, Snowflake. Confirm the final list with Daniel; only list what's actually used.
7. **Footer:** StormHack 2026, GitHub link, team.

## 5. Look and feel

Match the app (§9), so the page and the screenshots feel like one product.

- **Reference: Luma.** Lots of whitespace, confident type, few elements. Colour comes from content (screenshots, maps), not decoration.
- **Type:** the system font stack (`-apple-system, "SF Pro", system-ui`). Hierarchy from size and weight only.
- **Colour:** mostly black and white with monochrome buttons. The only accent is the app's time-of-day gradient, used as a soft wash behind the hero:

  | Part of day | Top | Fade |
  | --- | --- | --- |
  | Morning | `#FFD8B5` | `#FFF3E3` |
  | Midday | `#CDE5FF` | `#EEF6FF` |
  | Evening | `#FFC48A` | `#F9B9B0` |
  | Night | `#C5CCE0` | `#E6E9F2` |

- **Cards:** solid, rounded (about 24 px radius), no glassmorphism on content.
- Support light and dark mode, and make it work on a phone first. Most visitors will open it on one.
- Show Chinese and Japanese text with the right `lang` attribute (`lang="zh-Hans"`, `lang="ja"`) so the fonts render correctly.

## 6. Copy rules

From §9.6 and §9.7. These apply to the page as much as to the app.

- Sentence case, short sentences, **no exclamation marks**.
- **Never say "AI", "smart" or "magic".** Name features for what they do (Show, Translate). Mimo is "a calm local friend", not an assistant or a bot.
- Local script first, then the translation.
- **Don't use:** purple-blue gradients or glows, gradient text, sparkle icons, emoji.
- **Allergy wording stays modest.** Don't promise it keeps anyone safe. Say it helps you explain your allergy clearly.

## 7. Assets

- **Screenshots:** take them from the running app once the screens exist (ask Daniel for a build or a TestFlight invite). Until then, use clearly marked placeholders. Make sure no keys or URLs are visible (the Me tab's developer section shows the server URL).
- **Example phrase** for mockups: 少糖，去冰 (shǎo táng, qù bīng), "Less sugar, no ice", because you like it less sweet.
- **Icons:** don't copy SF Symbols onto the web page; their licence covers Apple platforms only. Use a free icon set (Lucide, Phosphor) or none.
- **App icon and Mimo avatar:** not designed yet. Leave a slot for them.

## 8. Open points

- **The name.** "Ryoko" is also a well-known travel Wi-Fi hotspot brand (§11). Pick a domain that's easy to change, and avoid anything that looks like that brand.
- Final list of shipped features and "built with" sponsors: confirm with Daniel before submission (Sun Oct 4, 12:00 PM PDT).
