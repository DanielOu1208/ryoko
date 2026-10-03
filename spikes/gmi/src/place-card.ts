// Spike D3 step 2: place-card JSON via prompt-embedded schema + TypeBox Value.Check + one retry.
// usage: node --experimental-strip-types src/place-card.ts <modelId...>
// env: RUNS (default 5), CASE=heytea|ramen, JSON_OBJECT=1 to also send response_format json_object, REASONING=low
import { writeFileSync, mkdirSync } from 'node:fs';
import { Value } from 'typebox/value';
import type { Context } from '@earendil-works/pi-ai';
import { gmiModels, SHORT } from './gmi.ts';
import { PlaceCardOutput, ALLOWED_BASIS, heytea, heyteaDerived, ramen, ramenDerived, placeCardSystem, placeCardUser } from './fixtures.ts';

const models = gmiModels();
const RUNS = Number(process.env.RUNS ?? 5);
const CASE = process.env.CASE ?? 'heytea';
const JSON_OBJECT = process.env.JSON_OBJECT === '1';
const REASONING = process.env.REASONING as any;
const [situation, derived] = CASE === 'ramen' ? [ramen, ramenDerived] : [heytea, heyteaDerived];
mkdirSync('out', { recursive: true });

function lenientParse(text: string): unknown {
  const t = text.trim().replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '');
  const a = t.indexOf('{'), b = t.lastIndexOf('}');
  return JSON.parse(t.slice(a, b + 1));
}

const PEANUT = /花生|落花生|ピーナッツ|ピーナツ|peanut/i;
const NEGATION = /过敏|不要|不含|没有|别放|去掉|免|アレルギー|抜き|なし|入れないで|allerg|without|no |leave out|skip/i;

async function attempt(model: any, ctx: Context) {
  const t0 = performance.now();
  let ttft = 0, thinkingEvents = 0;
  const s = models.streamSimple(model, ctx, {
    maxTokens: 1500,
    ...(REASONING ? { reasoning: REASONING } : {}),
    ...(JSON_OBJECT ? { samplingParams: { response_format: { type: 'json_object' } } } : {}),
  });
  for await (const e of s) {
    if (e.type === 'text_delta' && !ttft) ttft = performance.now() - t0;
    if (e.type === 'thinking_delta') thinkingEvents++;
  }
  const msg = await s.result();
  const text = msg.content.filter((c) => c.type === 'text').map((c: any) => c.text).join('');
  return { ttft, total: performance.now() - t0, thinkingEvents, text, msg };
}

function analyse(obj: any) {
  const issues: string[] = [];
  const all = [...(obj.phrases ?? []), ...(obj.tips ?? [])];
  for (const x of all) for (const b of x.basis ?? []) if (!ALLOWED_BASIS.has(b)) issues.push(`basis:${b}`);
  for (const p of obj.phrases ?? []) {
    if (situation.localLanguage === 'zh-Hans' && /[A-Za-z]/.test(p.local)) issues.push(`latin:${p.local}`);
    if (situation.localLanguage === 'ja' && /[A-Za-z]/.test(p.local)) issues.push(`latin:${p.local}`);
    if ((p.because ?? '').split(/\s+/).length > 12) issues.push(`because-long:${p.because.split(/\s+/).length}w`);
  }
  for (const t of obj.tips ?? []) if (/[\u3040-\u30ff\u4e00-\u9fff]/.test(t.text) && /^[^A-Za-z]*$/.test(t.text.slice(0, 3))) issues.push(`tip-not-home-lang`);
  for (const x of [...(obj.phrases ?? []).map((p: any) => `${p.local} ${p.gloss}`), ...(obj.tips ?? []).map((t: any) => t.text)])
    if (PEANUT.test(x) && !NEGATION.test(x)) issues.push(`peanut:${x}`);
  return issues;
}

const rows: any[] = [];
for (const id of process.argv.slice(2)) {
  const model = models.getModel('gmi', id);
  if (!model) throw new Error(`unknown model ${id}`);
  for (let i = 0; i < RUNS; i++) {
    const ctx: Context = { systemPrompt: placeCardSystem(situation.localLanguage), messages: [{ role: 'user', content: placeCardUser(situation, derived), timestamp: Date.now() }] };
    const first = await attempt(model, ctx);
    let strictParse = true, parsed: any, schemaOk = false, retried = false, final = first, errors: string[] = [];
    try { JSON.parse(first.text); } catch { strictParse = false; }
    try { parsed = lenientParse(first.text); schemaOk = Value.Check(PlaceCardOutput, parsed); } catch {}
    if (!schemaOk) {
      errors = parsed ? [...Value.Errors(PlaceCardOutput, parsed)].slice(0, 3).map((e: any) => `${e.instancePath} ${e.message}`) : ['parse failed'];
      retried = true;
      ctx.messages.push(first.msg, { role: 'user', content: `That was not valid. Errors: ${errors.join('; ')}. Reply again with only the corrected JSON object.`, timestamp: Date.now() });
      final = await attempt(model, ctx);
      parsed = undefined;
      try { parsed = lenientParse(final.text); schemaOk = Value.Check(PlaceCardOutput, parsed); } catch {}
    }
    const issues = schemaOk ? analyse(parsed) : ['schema-invalid'];
    const row = {
      model: SHORT(id), case: CASE, jsonObject: JSON_OBJECT, reasoning: REASONING ?? 'off', run: i,
      ttft: Math.round(first.ttft), total: Math.round(first.total), retryTotal: retried ? Math.round(first.total + final.total) : undefined,
      thinkingEvents: first.thinkingEvents, strictParse, firstSchemaOk: !retried, schemaOk, firstErrors: errors, issues,
      cost: first.msg.usage.cost.total + (retried ? final.msg.usage.cost.total : 0), outTokens: first.msg.usage.output,
      stop: first.msg.stopReason, err: first.msg.errorMessage, output: parsed ?? first.text,
    };
    rows.push(row);
    console.log(JSON.stringify({ ...row, output: undefined }));
  }
}
writeFileSync(`out/place-card-${CASE}${JSON_OBJECT ? '-jsonobj' : ''}${REASONING ? '-' + REASONING : ''}-${Date.now()}.json`, JSON.stringify(rows, null, 2));
