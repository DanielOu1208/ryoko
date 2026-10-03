// D2 spike: analyse a recorded Soniox run (out/runs/<label>.json).
// - speech segments from the clean PCM (energy VAD), expected language per segment
// - latency to first token / first final / first translation per segment
// - <end> arrival relative to end of speech
// - language-ID mismatches (final and non-final)
// - Simplified vs Traditional check on zh text (via `swift` Hant-Hans transform)
// - design §4.8 turn rule simulation, with and without <end>, for several thresholds
//
// Usage: node analyze.mjs <label> --vad out/audio/conv_zh.pcm --expect en,zh,en
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { execFileSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));

// ---------- VAD ----------
export function speechSegments(pcm, { frameMs = 20, thresholdDb = -42, mergeGapMs = 800, minMs = 200 } = {}) {
  const samples = new Int16Array(pcm.buffer, pcm.byteOffset, Math.floor(pcm.length / 2));
  const frame = 16 * frameMs;
  const active = [];
  for (let i = 0; i + frame <= samples.length; i += frame) {
    let s = 0;
    for (let j = i; j < i + frame; j++) s += samples[j] * samples[j];
    const db = 20 * Math.log10(Math.sqrt(s / frame) / 32768 + 1e-12);
    active.push(db > thresholdDb);
  }
  const segs = [];
  let cur = null;
  active.forEach((a, k) => {
    const t = k * frameMs;
    if (a) {
      if (cur && t - cur.end <= mergeGapMs) cur.end = t + frameMs;
      else {
        cur = { start: t, end: t + frameMs };
        segs.push(cur);
      }
    }
  });
  return segs.filter((s) => s.end - s.start >= minMs);
}

// ---------- token helpers ----------
const CJK = /[぀-ヿ㐀-䶿一-鿿豈-﫿가-힯]/gu;
export const cjkCount = (s) => (s.match(CJK) ?? []).length;
export const isWordy = (s) => /[\p{L}\p{N}]/u.test(s);
const isOriginal = (tok) => tok.translation_status !== "translation" && tok.text !== "<end>" && tok.text !== "<fin>";
const isTranslation = (tok) => tok.translation_status === "translation";

// ---------- turn rule ----------
// Feed final tokens in arrival order. A new turn starts once the pending tokens in a
// different language reach `minTokens` wordy tokens or `minCjk` CJK characters.
// `<end>` commits the open turn. Translation tokens attach to the most recent turn whose
// language equals their source_language.
export function simulateTurns(finals, { minTokens = 2, minCjk = 2, useEnd = true } = {}) {
  const turns = [];
  let open = null;
  let pending = [];
  const events = [];
  const pendingCount = () => ({
    tokens: pending.filter((p) => isWordy(p.text)).length,
    cjk: pending.reduce((n, p) => n + cjkCount(p.text), 0),
  });
  const newTurn = (lang, toks, t, why) => {
    open = { lang, original: toks.map((x) => x.text).join(""), translation: "", startedAt: t, why, closedBy: null, lateTranslationTokens: 0 };
    turns.push(open);
  };
  for (const f of finals) {
    const tok = f.tok;
    if (tok.text === "<end>") {
      if (!useEnd) continue;
      if (pending.length && open) {
        events.push({ t: f.t, note: `<end> with ${pending.length} pending other-language token(s) merged back` });
        open.original += pending.map((x) => x.text).join("");
        pending = [];
      }
      if (open) {
        open.closedBy = "end";
        open.closedAt = f.t;
        open = null;
      }
      continue;
    }
    if (isTranslation(tok)) {
      const target = [...turns].reverse().find((tt) => tt.lang === tok.source_language);
      if (target) {
        target.translation += tok.text;
        if (target.closedBy) target.lateTranslationTokens += 1;
      } else events.push({ t: f.t, note: `orphan translation token "${tok.text}"` });
      continue;
    }
    if (!isOriginal(tok)) continue;
    const lang = tok.language ?? "?";
    if (!open) {
      if (!isWordy(tok.text) && !tok.text.trim()) continue; // skip leading whitespace
      newTurn(lang, [tok], f.t, "first-or-after-end");
      continue;
    }
    if (lang === open.lang) {
      if (pending.length) {
        events.push({ t: f.t, note: `false flip absorbed: "${pending.map((p) => p.text).join("")}" (${pending[0].language})` });
        open.original += pending.map((x) => x.text).join("");
        pending = [];
      }
      open.original += tok.text;
      continue;
    }
    pending.push(tok);
    const c = pendingCount();
    if (c.tokens >= minTokens || c.cjk >= minCjk) {
      open.closedBy = "switch";
      open.closedAt = f.t;
      newTurn(lang, pending, f.t, "switch");
      pending = [];
    }
  }
  if (pending.length && open) open.original += pending.map((x) => x.text).join("");
  return { turns, events };
}

// ---------- Simplified check ----------
function toSimplified(texts) {
  if (!texts.length) return [];
  const src = `import Foundation
let input = CommandLine.arguments.dropFirst()
for s in input { print(s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s) }`;
  const file = join(here, "out/.hans.swift");
  writeFileSync(file, src);
  try {
    return execFileSync("swift", [file, ...texts], { encoding: "utf8" }).split("\n").slice(0, texts.length);
  } catch {
    return texts.map(() => null);
  }
}

// ---------- main analysis ----------
export function analyse(run, segs, expect) {
  const msgs = run.log.filter((l) => l.kind === "msg");
  const err = msgs.find((m) => m.msg.error_code);
  if (err) return { error: `${err.msg.error_code} ${err.msg.error_type}: ${err.msg.error_message}` };
  const labelled = segs.map((s, i) => ({ ...s, lang: expect[i] ?? "?" }));
  const segOf = (ms) => {
    let best = null;
    for (const s of labelled) if (ms >= s.start - 300 && ms <= s.end + 300) best = s;
    return best;
  };

  const finals = [];
  const perSeg = labelled.map((s) => ({
    lang: s.lang,
    speechStart: s.start,
    speechEnd: s.end,
    firstToken: null,
    firstFinal: null,
    firstTranslation: null,
    firstFinalTranslation: null,
    end: null,
    original: "",
    translation: "",
    nonFinalLangMismatch: new Set(),
    finalLangMismatch: [],
  }));
  const idx = (s) => labelled.indexOf(s);
  let lastOriginalSeg = null;
  const procLag = [];

  for (const m of msgs) {
    const toks = m.msg.tokens ?? [];
    if (m.msg.final_audio_proc_ms != null) procLag.push(m.t - m.msg.final_audio_proc_ms);
    for (const tok of toks) {
      if (tok.is_final) finals.push({ t: m.t, tok, text: tok.text, language: tok.language });
      if (tok.text === "<end>") {
        const ps = lastOriginalSeg != null ? perSeg[lastOriginalSeg] : null;
        if (ps && ps.end == null) ps.end = m.t;
        continue;
      }
      if (isOriginal(tok) && tok.start_ms != null) {
        const s = segOf(tok.start_ms);
        if (!s) continue;
        const ps = perSeg[idx(s)];
        lastOriginalSeg = idx(s);
        if (ps.firstToken == null && isWordy(tok.text)) ps.firstToken = m.t;
        if (tok.is_final && ps.firstFinal == null && isWordy(tok.text)) ps.firstFinal = m.t;
        if (tok.is_final) ps.original += tok.text;
        if (isWordy(tok.text) && tok.language && tok.language !== s.lang) {
          if (tok.is_final) ps.finalLangMismatch.push(`${tok.text}(${tok.language})`);
          else ps.nonFinalLangMismatch.add(`${tok.text}(${tok.language})`);
        }
      } else if (isTranslation(tok)) {
        // attribute to the latest segment whose language is the source language and that already started
        const cand = perSeg.filter((p) => p.lang === tok.source_language && p.firstToken != null && p.firstToken <= m.t);
        const ps = cand[cand.length - 1];
        if (!ps) continue;
        if (ps.firstTranslation == null && isWordy(tok.text)) ps.firstTranslation = m.t;
        if (tok.is_final) {
          if (ps.firstFinalTranslation == null && isWordy(tok.text)) ps.firstFinalTranslation = m.t;
          ps.translation += tok.text;
          if (ps.end != null) ps.translationAfterEnd = (ps.translationAfterEnd ?? 0) + 1;
        }
      }
    }
  }

  // token tagging samples
  const tagShapes = new Map();
  for (const f of finals) {
    const k = JSON.stringify({
      translation_status: f.tok.translation_status,
      language: f.tok.language,
      source_language: f.tok.source_language,
      has_ms: f.tok.start_ms != null,
      end: f.tok.text === "<end>" || undefined,
    });
    tagShapes.set(k, (tagShapes.get(k) ?? 0) + 1);
  }

  const r = (x) => (x == null ? null : Math.round(x));
  const segments = perSeg.map((p) => ({
    lang: p.lang,
    speech: `${p.speechStart}-${p.speechEnd}ms`,
    firstTokenAfterOnset: r(p.firstToken && p.firstToken - p.speechStart),
    firstFinalAfterOnset: r(p.firstFinal && p.firstFinal - p.speechStart),
    firstTranslationAfterOnset: r(p.firstTranslation && p.firstTranslation - p.speechStart),
    firstFinalTranslationAfterOnset: r(p.firstFinalTranslation && p.firstFinalTranslation - p.speechStart),
    endAfterSpeechEnd: r(p.end && p.end - p.speechEnd),
    finalTranslationTokensAfterEnd: p.translationAfterEnd ?? 0,
    original: p.original.trim(),
    translation: p.translation.trim(),
    finalLangMismatch: p.finalLangMismatch,
    nonFinalLangMismatch: [...p.nonFinalLangMismatch],
  }));

  // Simplified check over all zh text (original and translation)
  const zhTexts = [];
  for (const s of segments) {
    if (s.lang === "zh" && s.original) zhTexts.push(s.original);
    if (s.lang !== "zh" && run.pair === "zh" && s.translation) zhTexts.push(s.translation);
  }
  const hans = toSimplified(zhTexts);
  const script = zhTexts.map((t, i) => ({ text: t, simplified: hans[i] == null ? "unknown" : hans[i] === t }));

  const turnRuns = {};
  for (const [name, opt] of Object.entries({
    "spec(2 tok|2 cjk)+end": { minTokens: 2, minCjk: 2, useEnd: true },
    "spec, no <end>": { minTokens: 2, minCjk: 2, useEnd: false },
    "1 tok|1 cjk, no <end>": { minTokens: 1, minCjk: 1, useEnd: false },
    "3 tok|3 cjk, no <end>": { minTokens: 3, minCjk: 3, useEnd: false },
  })) {
    const { turns, events } = simulateTurns(finals, opt);
    turnRuns[name] = {
      langs: turns.map((t) => t.lang).join(","),
      ok: turns.map((t) => t.lang).join(",") === expect.join(","),
      turns: turns.map((t) => ({ lang: t.lang, why: t.why, closedBy: t.closedBy, late: t.lateTranslationTokens, original: t.original.trim(), translation: t.translation.trim() })),
      events,
    };
  }

  const ends = finals.filter((f) => f.tok.text === "<end>").map((f) => r(f.t));
  return {
    label: run.label,
    connectMs: run.log.find((l) => l.kind === "open")?.connectMs,
    messages: msgs.length,
    finishedAtMs: r(msgs.find((m) => m.msg.finished)?.t),
    endTokensAtMs: ends,
    medianFinalLagMs: r(procLag.sort((a, b) => a - b)[Math.floor(procLag.length / 2)]),
    segments,
    script,
    tagShapes: Object.fromEntries(tagShapes),
    turnRuns,
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: { vad: { type: "string" }, expect: { type: "string" } },
  });
  const label = positionals[0];
  const run = JSON.parse(readFileSync(join(here, "out/runs", `${label}.json`), "utf8"));
  const pcm = readFileSync(resolve(here, values.vad ?? run.file));
  const segs = speechSegments(pcm);
  const res = analyse(run, segs, values.expect.split(","));
  mkdirSync(join(here, "out/results"), { recursive: true });
  writeFileSync(join(here, "out/results", `${label}.json`), JSON.stringify(res, null, 2));
  console.log(JSON.stringify(res, null, 2));
}
