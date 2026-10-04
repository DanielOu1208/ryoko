// Loads the travel guides into Snowflake (design §8.4) and (re)builds the Cortex
// Search service over them. Run from server/: `pnpm guides:load`.
//
// 1. Fetches each page in GUIDE_PAGES from Wikivoyage and splits it into chunks.
// 2. Replaces RYOKO.GUIDES.GUIDES with them, attribution on every row.
// 3. Replaces the GUIDE_SEARCH Cortex Search service, then runs one test query.
//
// Needs SNOWFLAKE_ACCOUNT_URL and SNOWFLAKE_PAT in server/.env; the token's role
// needs CREATE TABLE and CREATE CORTEX SEARCH SERVICE on the schema. Cortex
// Search needs AI features, which a trial account only has once a card is on file.

import { DEFAULT_ENV_FILE, readEnvFile } from '../src/config.ts';
import { createGuideSearch, GUIDE_SERVICE, GUIDE_TABLE, runSql, snowflakeConfigFrom, type Binding } from '../src/guides/snowflake.ts';
import { chunkPage, fetchPage, GUIDE_PAGES, WIKIVOYAGE_ATTRIBUTION, WIKIVOYAGE_LICENSE, type GuideChunk } from '../src/guides/wikivoyage.ts';

const config = snowflakeConfigFrom({ ...readEnvFile(DEFAULT_ENV_FILE), ...process.env });
if (!config) {
  console.error('Set SNOWFLAKE_ACCOUNT_URL and SNOWFLAKE_PAT in server/.env first.');
  process.exit(1);
}

const chunks: GuideChunk[] = [];
for (const page of GUIDE_PAGES) {
  const fetched = await fetchPage(page.title);
  const pageChunks = chunkPage(page, fetched);
  console.log(`${fetched.title}: ${pageChunks.length} chunks (revision ${fetched.revisionId})`);
  chunks.push(...pageChunks);
  await new Promise((resolve) => setTimeout(resolve, 300)); // be gentle with Wikivoyage
}

await runSql(
  config,
  `CREATE OR REPLACE TABLE ${GUIDE_TABLE} (
    ID STRING NOT NULL,
    PAGE_TITLE STRING NOT NULL,
    SECTION STRING NOT NULL,
    TOPIC STRING NOT NULL,
    COUNTRY_CODE STRING NOT NULL,
    CITY STRING NOT NULL,
    BODY STRING NOT NULL,
    URL STRING NOT NULL,
    LICENSE STRING NOT NULL,
    ATTRIBUTION STRING NOT NULL,
    REVISION_ID NUMBER NOT NULL,
    LOADED_AT TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
  ) COMMENT = 'Wikivoyage travel guides (CC BY-SA 4.0), loaded by server/scripts/load-guides.ts'`,
);

const text = (values: string[]): Binding => ({ type: 'TEXT', value: values });
for (let start = 0; start < chunks.length; start += 200) {
  const batch = chunks.slice(start, start + 200);
  await runSql(
    config,
    `INSERT INTO ${GUIDE_TABLE} (ID, PAGE_TITLE, SECTION, TOPIC, COUNTRY_CODE, CITY, BODY, URL, LICENSE, ATTRIBUTION, REVISION_ID) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    {
      bindings: {
        '1': text(batch.map((c) => c.id)),
        '2': text(batch.map((c) => c.pageTitle)),
        '3': text(batch.map((c) => c.section)),
        '4': text(batch.map((c) => c.topic)),
        '5': text(batch.map((c) => c.countryCode)),
        '6': text(batch.map((c) => c.city ?? '')),
        '7': text(batch.map((c) => c.body)),
        '8': text(batch.map((c) => c.url)),
        '9': text(batch.map(() => WIKIVOYAGE_LICENSE)),
        '10': text(batch.map(() => WIKIVOYAGE_ATTRIBUTION)),
        '11': { type: 'FIXED', value: batch.map((c) => String(c.revisionId)) },
      },
    },
  );
  console.log(`Inserted ${Math.min(start + batch.length, chunks.length)} of ${chunks.length}`);
}

console.log('Building the Cortex Search service (a minute or two)…');
await runSql(
  config,
  `CREATE OR REPLACE CORTEX SEARCH SERVICE ${GUIDE_SERVICE}
    ON BODY
    ATTRIBUTES COUNTRY_CODE, CITY, TOPIC
    WAREHOUSE = ${config.warehouse}
    TARGET_LAG = '1 day'
    AS (SELECT BODY, PAGE_TITLE, SECTION, URL, COUNTRY_CODE, CITY, TOPIC FROM ${GUIDE_TABLE})`,
  { timeoutSeconds: 600 },
);

const search = createGuideSearch(config, { timeoutMs: 10_000 });
const started = Date.now();
const hits = await search('Should I tip at a restaurant?', { countryCode: 'JP' });
console.log(`Test query in ${Date.now() - started} ms:`);
for (const hit of hits) console.log(`- ${hit.pageTitle} › ${hit.section}: ${hit.text.slice(0, 100)}…`);
