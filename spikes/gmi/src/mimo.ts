// Spike D3 steps 3 and 4: tool calls and phrase tags through a pi-agent-core Agent.
// usage: node --experimental-strip-types src/mimo.ts <tools|phrases> <modelId...>
import { writeFileSync, mkdirSync } from 'node:fs';
import { Value } from 'typebox/value';
import { Agent, type AgentTool } from '@earendil-works/pi-agent-core';
import { Type } from '@earendil-works/pi-ai';
import { gmiModels, SHORT } from './gmi.ts';
import { heytea, heyteaDerived, mimoSystem } from './fixtures.ts';

const models = gmiModels();
const MODE = process.argv[2];
const RUNS = Number(process.env.RUNS ?? 5);
mkdirSync('out', { recursive: true });

const ShowPlacesParams = Type.Object({
  places: Type.Array(
    Type.Object({
      name: Type.String({ description: 'Name as shown on maps, in English or the common romanized form.' }),
      localName: Type.Optional(Type.String({ description: 'Name in local script.' })),
      why: Type.String({ description: 'Why it suits the user, at most 60 characters.' }),
      order: Type.Optional(Type.Integer({ minimum: 1, description: 'Stop number when planning.' })),
      when: Type.Optional(Type.String({ description: 'Suggested local time, e.g. 15:30.' })),
    }),
    { minItems: 1, maxItems: 5 },
  ),
});

function makeTools(log: any) {
  const showPlaces: AgentTool<typeof ShowPlacesParams> = {
    name: 'show_places',
    label: 'Showing places',
    description: 'Show specific places to the user as cards on the map. Call once with every place you are suggesting.',
    parameters: ShowPlacesParams,
    execute: async (_id, params) => {
      log.showPlaces.push(params);
      return { content: [{ type: 'text', text: `Shown ${params.places.length} places to the user.` }], details: { places: params.places } };
    },
  };
  const webSearch: AgentTool<any> = {
    name: 'web_search',
    label: 'Searching',
    description: 'Search the web for current facts (hours, events). Returns short snippets with sources.',
    parameters: Type.Object({ query: Type.String() }),
    execute: async (_id, params: any) => {
      log.webSearch.push(params.query);
      return {
        content: [{ type: 'text', text: `Results for "${params.query}":\n1. Jing'an Park (静安公园) - open 06:00-18:00, quiet lawns and a pond. (sh.gov.cn)\n2. Columbia Circle (上生·新所) - restored compound with courtyards and cafes. (timeout.com)` }],
        details: { sources: [{ title: "Jing'an Park", url: 'https://example.com/a' }, { title: 'Columbia Circle', url: 'https://example.com/b' }] },
      };
    },
  };
  return [showPlaces, webSearch];
}

async function runOnce(modelId: string, prompt: string) {
  const model = models.getModel('gmi', modelId)!;
  const log: any = { showPlaces: [], webSearch: [], invalidArgs: [], toolErrors: 0 };
  let turns = 0, toolCalls = 0, thinkingEvents = 0, ttft = 0, text = '';
  const t0 = performance.now();
  const agent = new Agent({
    initialState: { systemPrompt: mimoSystem(heytea, heyteaDerived), model, thinkingLevel: 'off', tools: makeTools(log) },
    streamFn: (m, ctx, opts) => models.streamSimple(m, ctx, { ...opts, maxTokens: 1500, maxRetryDelayMs: 2000 }),
    toolExecution: 'sequential',
    beforeToolCall: async ({ toolCall }) => {
      toolCalls++;
      if (toolCalls > 3) return { block: true, reason: 'tool budget exhausted', terminate: true };
      if (toolCall.name === 'show_places' && !Value.Check(ShowPlacesParams, toolCall.arguments)) log.invalidArgs.push(toolCall.arguments);
    },
    finishTurn: async ({ message }) => {
      if (message.stopReason === 'error' || message.stopReason === 'aborted') return;
      if (turns >= 4) return { action: 'end' };
    },
  });
  agent.subscribe((e) => {
    if (e.type === 'turn_start') turns++;
    if (e.type === 'tool_execution_end' && e.isError) log.toolErrors++;
    if (e.type === 'message_update') {
      const a = e.assistantMessageEvent;
      if (a.type === 'thinking_delta') thinkingEvents++;
      if (a.type === 'text_delta') { if (!ttft) ttft = performance.now() - t0; text += a.delta; }
    }
  });
  const timer = setTimeout(() => agent.abort(), 30_000);
  try { await agent.prompt(prompt); } finally { clearTimeout(timer); }
  const err = agent.state.errorMessage;
  return { total: Math.round(performance.now() - t0), ttft: Math.round(ttft), turns, toolCalls, thinkingEvents, text, err, ...log };
}

const PHRASE_RE = /<phrase\s+([^>]*?)\/>/g;
function scorePhrases(text: string) {
  const tags = [...text.matchAll(PHRASE_RE)];
  const parsed = tags.map((m) => Object.fromEntries([...m[1].matchAll(/(\w+)="([^"]*)"/g)].map((a) => [a[1], a[2]])));
  const lines = text.split('\n');
  const ownLine = tags.every((m) => lines.some((l) => l.trim() === m[0]));
  const attrsOk = parsed.every((p) => p.lang === 'zh-Hans' && p.local && p.gloss && !/[A-Za-z]/.test(p.local));
  const stray = (text.match(/<phrase/g) ?? []).length !== tags.length; // unterminated / malformed
  const outside = text.replace(PHRASE_RE, '').trim();
  const fenced = /```/.test(text);
  const compliant = tags.length >= 1 && tags.length <= 4 && ownLine && attrsOk && !stray && !fenced;
  return { tagCount: tags.length, ownLine, attrsOk, stray, fenced, hasOutsideText: outside.length > 0, cjkOutside: /[\u4e00-\u9fff]/.test(outside), compliant, phrases: parsed };
}

const rows: any[] = [];
const prompts = MODE === 'tools' ? ['Somewhere quiet nearby to sit?', 'Plan my afternoon around here'] : ['How do I ask for less sugar and to take it away?'];
for (const id of process.argv.slice(3)) for (const prompt of prompts) for (let i = 0; i < RUNS; i++) {
  const r = await runOnce(id, prompt);
  const row: any = { model: SHORT(id), mode: MODE, prompt, run: i, ...r };
  if (MODE === 'tools') row.showPlacesValid = r.showPlaces.length > 0 && r.invalidArgs.length === 0 && r.toolErrors === 0;
  else Object.assign(row, scorePhrases(r.text));
  rows.push(row);
  console.log(JSON.stringify({ ...row, text: r.text.slice(0, 160).replace(/\n/g, ' / '), showPlaces: r.showPlaces.map((s: any) => s.places.map((p: any) => p.name)), phrases: undefined }));
}
writeFileSync(`out/mimo-${MODE}-${Date.now()}.json`, JSON.stringify(rows, null, 2));
