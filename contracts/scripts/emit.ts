// Emits one JSON Schema file per contract into contracts/json-schema/.
// Run from the repo root: pnpm contracts:emit   (or in contracts/: node scripts/emit.ts)

import { mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SCHEMAS, jsonSchemaDocument } from './schemas.ts';

const outDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'json-schema');

mkdirSync(outDir, { recursive: true });
for (const f of readdirSync(outDir)) if (f.endsWith('.schema.json')) rmSync(join(outDir, f));

for (const [name, schema] of Object.entries(SCHEMAS)) {
  writeFileSync(join(outDir, `${name}.schema.json`), JSON.stringify(jsonSchemaDocument(name, schema), null, 2) + '\n');
}
console.log(`Wrote ${Object.keys(SCHEMAS).length} schemas to ${outDir}`);
