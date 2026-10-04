# @ryoko/contracts

The source of truth for Ryoko's API (design §7). Owned by W1; other workstreams request changes in the tracker. Swift `Codable` mirrors live in `ios/Shared/` and are kept in step by hand.

| Path | What |
| --- | --- |
| `src/` | TypeBox 1.3.27 schemas. Each schema has a `Static` type with the same name. Import from `@ryoko/contracts` |
| `json-schema/` | JSON Schema 2020-12, emitted from `src/`. Don't edit by hand |
| `examples/` | Hand-written requests and responses per endpoint, the seed profile and `mimo.sse.txt` |
| `tables/` | `langcodes.json`, `categories.json`, `allergy-templates.json`. The app bundles them; the server reads them |
| `test/` | `node:test`: every example and table against its schema, plus the SSE transcript line by line |

## Commands (run from the repo root)

```sh
pnpm install            # root workspace: contracts + server
pnpm contracts:emit     # regenerate json-schema/ after changing src/
pnpm contracts:test     # validate examples, tables, mimo.sse.txt; checks json-schema/ is in sync
pnpm contracts:check    # typecheck + emit + test
```

## Rules

- **Enums** use the local `StringEnum`. It emits `{type: 'string', enum: [...]}` like pi-ai's, never `anyOf`/`const`. Never use `Type.Enum` or `Type.Literal`. A test fails if `const` appears in any schema.
- **Objects** use `Strict(...)`, which sets `additionalProperties: false`.
- **`null` vs absent:** in the profile, `null` means skipped and `[]` means none. The one exception is `aboutMe`, which is absent when empty (never `null` or `""`), so older profiles keep their version. Optional fields elsewhere are omitted, not `null`.
- **Times:** `situation.localTime` always carries its UTC offset. The server never uses its own clock for the situation.
- **Profile version:** sha-256 (lowercase hex) of the canonical JSON of the profile without `version`. Canonical means keys sorted, no whitespace, `JSON.stringify` escaping, and absent optional keys left out (`profileVersion()` in `src/canonical.ts`). The server treats it as an opaque cache key.

## Importing from the server (Node 24 type stripping)

`exports["."]` points at `src/index.ts`, and the server runs it with Node's built-in type stripping. Node refuses to strip types under `node_modules`. pnpm links the package into `server/node_modules/@ryoko/contracts` as a symlink, and Node resolves symlinks to the real path (`contracts/src/…`), so stripping works. This was verified with a symlinked consumer: the schemas and the `with { type: 'json' }` example imports both load.

- **Don't run the server with `--preserve-symlinks`.** With it, Node fails with `ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING`.
- **Fallback** if a tool ever copies the package into `node_modules` (e.g. `pnpm deploy`, or `node-linker=hoisted` with `inject`): run the server with `tsx` (`pnpm add -D tsx`, then `tsx src/main.ts`), which transpiles `node_modules` too.
- The source is erasable-only TypeScript: `import type`, `.ts` extensions in relative imports, no enums or namespaces. `tsconfig.json` enforces this with `erasableSyntaxOnly` and `verbatimModuleSyntax`.

Example and table JSON can be imported directly:

```ts
import seed from '@ryoko/contracts/examples/profile.seed.json' with { type: 'json' };
```

## Examples

The situation places (`Wutong Coffee` 梧桐咖啡 in Jing'an, `Menya Kaze` 麺屋 風 in Nishi-Shinjuku) are **fictional**, and their ids start with `fixture-`. The places in `discover.response.json` and in the `show_places` event of `mimo.sse.txt` are real, well-known spots typed by hand, so the device can resolve them with MapKit in fixture mode. Nothing here comes from a MapKit response.

The tier 2 Translate endpoints have examples too: `translate[.tokyo].{request,response}.json` (typed text, one per target language, which the faux server picks by `to`) and `soniox-key.response.json`, whose key is an obvious placeholder. A real minted key is a secret and never goes in a file.

`place-photos.{request,response}.json` (`POST /v1/place-photos`) are hand-written, never a Foursquare response: the urls are `https://example.com/` placeholders, and the third place shows "no photo" (no `url`). The faux server and the app's fixtures answer every place with no url.

**`profile.seed.json`'s home base is a placeholder.** The hotel name, address and coordinate are made up and labelled as a placeholder. Replace them with the real hotel, with its coordinate from MapKit (design §4.7), before any demo.

## Allergy templates

`tables/allergy-templates.json` is safety text. It covers zh-Hans and ja for every chip allergen at all three severities, with the wording from design §4.5. "X oil" appears only where such an oil exists: peanut, sesame, soy, tree nut and mustard. Every language block is `"reviewed": false` until a native Chinese reader and a native Japanese reader check each line, then set `reviewed: true` and `reviewedBy`. zh-Hant has only the taxi phrase so far (best-effort).
