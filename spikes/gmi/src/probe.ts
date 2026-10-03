// Raw probe: streaming shape, reasoning fields, json_object support. Never prints the key.
const BASE = 'https://api.gmi-serving.com/v1';
const key = process.env.GMI_API_KEY;
if (!key) throw new Error('GMI_API_KEY missing');
const models = process.argv.slice(2);

async function run(model: string, extra: Record<string, unknown>, label: string) {
  const t0 = performance.now();
  const res = await fetch(`${BASE}/chat/completions`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` },
    body: JSON.stringify({
      model, stream: true, stream_options: { include_usage: true }, max_tokens: 300,
      messages: [{ role: 'system', content: 'Reply only with a JSON object.' }, { role: 'user', content: 'Give {"greeting": "<hello in Chinese>"}' }],
      ...extra,
    }),
  });
  if (!res.ok) { console.log(model, label, 'HTTP', res.status, (await res.text()).slice(0, 300)); return; }
  let ttft = 0, text = '', reasoning = 0; const fields = new Set<string>(); let usage: unknown;
  const dec = new TextDecoder(); let buf = '';
  for await (const chunk of res.body as any) {
    buf += dec.decode(chunk, { stream: true });
    let i; while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
      if (!line.startsWith('data:')) continue; const d = line.slice(5).trim(); if (d === '[DONE]') continue;
      const j = JSON.parse(d); if (j.usage) usage = j.usage;
      const delta = j.choices?.[0]?.delta ?? {};
      for (const k of Object.keys(delta)) if (delta[k]) fields.add(k);
      for (const k of ['reasoning_content', 'reasoning']) if (delta[k]) reasoning += String(delta[k]).length;
      if (delta.content) { if (!ttft) ttft = performance.now() - t0; text += delta.content; }
    }
  }
  console.log(JSON.stringify({ model, label, ttft: Math.round(ttft), total: Math.round(performance.now() - t0), fields: [...fields], reasoningChars: reasoning, text: text.slice(0, 120), usage }));
}
const variants: Record<string, Record<string, unknown>> = {
  plain: {},
  json_object: { response_format: { type: 'json_object' } },
  thinking_disabled: { thinking: { type: 'disabled' } },
  enable_thinking_false: { enable_thinking: false },
  ctk_enable_thinking_false: { chat_template_kwargs: { enable_thinking: false, thinking: false } },
  reasoning_effort_none: { reasoning_effort: 'none' },
};
const pick = (process.env.VARIANTS ?? 'plain,json_object').split(',');
for (const m of models) for (const v of pick) await run(m, variants[v], v);
