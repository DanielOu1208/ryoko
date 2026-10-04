// The travel guides (design §8.4): Wikivoyage chunking and the Cortex Search client.

import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { createGuideSearch, guideSourcesOf, snowflakeConfigFrom, type SnowflakeConfig } from '../src/guides/snowflake.ts';
import { chunkPage, packParagraphs, sectionAnchor, splitSections } from '../src/guides/wikivoyage.ts';

const extract = [
  'Shinjuku is a central ward of Tokyo with the busiest station in the world, and plenty to eat around it at any hour.',
  '',
  '== Eat ==',
  'Ramen shops near the station often sell tickets from a machine by the door; buy one and hand it to the staff.',
  '=== Budget ===',
  'Chains like Matsuya serve set meals for well under ¥1,000, ordered from a ticket machine at the entrance.',
  '== Sleep ==',
  'Hotels of every kind are around the west exit, from capsule hotels to the Park Hyatt and everything in between.',
].join('\n');

describe('wikivoyage chunks', () => {
  test('sections follow the headings, with the text before the first one as Overview', () => {
    const sections = splitSections(extract).map((s) => s.path.join(' › '));
    assert.deepEqual(sections, ['Overview', 'Eat', 'Eat › Budget', 'Sleep']);
  });

  test('a page keeps its listed sections, with attribution and an anchored URL on every chunk', () => {
    const page = { title: 'Tokyo/Shinjuku', countryCode: 'JP', city: 'Tokyo', sections: ['overview', 'eat'] };
    const chunks = chunkPage(page, { title: 'Tokyo/Shinjuku', url: 'https://en.wikivoyage.org/wiki/Tokyo/Shinjuku', revisionId: 7, extract });
    assert.deepEqual(chunks.map((c) => c.section), ['Overview', 'Eat', 'Eat › Budget']);
    assert.equal(chunks[2]!.url, 'https://en.wikivoyage.org/wiki/Tokyo/Shinjuku#Budget');
    assert.equal(chunks[0]!.url, 'https://en.wikivoyage.org/wiki/Tokyo/Shinjuku');
    assert.match(chunks[1]!.body, /^Tokyo\/Shinjuku — Eat: Ramen shops/);
    assert.equal(new Set(chunks.map((c) => c.id)).size, chunks.length);
  });

  test('without a section list, Sleep and the like are skipped', () => {
    const chunks = chunkPage({ title: 'X', countryCode: 'JP', city: null }, { title: 'X', url: 'https://en.wikivoyage.org/wiki/X', revisionId: 1, extract });
    assert.equal(chunks.some((c) => c.topic === 'sleep'), false);
  });

  test('long text is packed into chunks of at most the limit, cut at sentence ends', () => {
    const long = Array.from({ length: 40 }, (_, i) => `Sentence number ${i} says something useful about trains.`).join(' ');
    const chunks = packParagraphs(long, 300);
    assert.ok(chunks.length > 1);
    assert.ok(chunks.every((c) => c.length <= 300));
    assert.ok(chunks.every((c) => c.endsWith('.')));
  });

  test('section anchors use underscores', () => {
    assert.equal(sectionAnchor('Stay safe'), 'Stay_safe');
  });
});

describe('cortex search client', () => {
  const config: SnowflakeConfig = { accountUrl: 'https://org-acct.snowflakecomputing.com', pat: 'secret', role: 'R', warehouse: 'W', database: 'RYOKO', schema: 'GUIDES' };

  test('config needs the account URL and the token', () => {
    assert.equal(snowflakeConfigFrom({}), null);
    assert.equal(snowflakeConfigFrom({ SNOWFLAKE_ACCOUNT_URL: 'https://example.com', SNOWFLAKE_PAT: 'x' }), null);
    assert.equal(snowflakeConfigFrom({ SNOWFLAKE_ACCOUNT_URL: 'https://org-acct.snowflakecomputing.com/', SNOWFLAKE_PAT: 'x' })?.accountUrl, 'https://org-acct.snowflakecomputing.com');
  });

  test('queries the service with the country filter, keeps only Wikivoyage links, and caches', async () => {
    const requests: { url: string; body: Record<string, unknown>; auth: string | null }[] = [];
    const fakeFetch = (async (url: string, init: RequestInit) => {
      requests.push({ url, body: JSON.parse(String(init.body)), auth: new Headers(init.headers).get('authorization') });
      return new Response(
        JSON.stringify({
          results: [
            { body: 'Japan — Buy › Tipping: Tipping is not a part of Japanese culture.', page_title: 'Japan', section: 'Buy › Tipping', url: 'https://en.wikivoyage.org/wiki/Japan#Tipping' },
            { body: 'Elsewhere: not a guide', page_title: 'Bad', section: 'x', url: 'https://evil.example/' },
          ],
        }),
        { status: 200 },
      );
    }) as typeof fetch;
    const search = createGuideSearch(config, { fetch: fakeFetch });
    const hits = await search('tipping', { countryCode: 'jp' });
    assert.equal(requests[0]!.url, 'https://org-acct.snowflakecomputing.com/api/v2/databases/RYOKO/schemas/GUIDES/cortex-search-services/GUIDE_SEARCH:query');
    assert.deepEqual(requests[0]!.body.filter, { '@eq': { country_code: 'JP' } });
    assert.equal(requests[0]!.auth, 'Bearer secret');
    assert.deepEqual(hits, [{ pageTitle: 'Japan', section: 'Buy › Tipping', url: 'https://en.wikivoyage.org/wiki/Japan#Tipping', text: 'Tipping is not a part of Japanese culture.' }]);
    await search('Tipping ', { countryCode: 'JP' });
    assert.equal(requests.length, 1);
    assert.deepEqual(guideSourcesOf([...hits, ...hits]), [{ title: 'Wikivoyage: Japan › Buy', url: 'https://en.wikivoyage.org/wiki/Japan#Tipping' }]);
  });

  test('an HTTP error throws without the token in the message', async () => {
    const search = createGuideSearch(config, { fetch: (async () => new Response('{"message":"nope"}', { status: 401 })) as unknown as typeof fetch });
    await assert.rejects(search('q', {}), (err: Error) => /HTTP 401/.test(err.message) && !err.message.includes('secret'));
  });
});
