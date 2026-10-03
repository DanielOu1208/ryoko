// D2: one compact table from out/results/*.json
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const dir = join(dirname(fileURLToPath(import.meta.url)), "out/results");
const files = readdirSync(dir).filter((f) => f.endsWith(".json")).sort();
for (const f of files) {
  const r = JSON.parse(readFileSync(join(dir, f), "utf8"));
  if (r.error) {
    console.log(`${f}: ERROR ${r.error}`);
    continue;
  }
  console.log(`\n## ${r.label}  (connect ${r.connectMs} ms, median final lag ${r.medianFinalLagMs} ms, <end> at ${r.endTokensAtMs.join("/")} ms)`);
  for (const s of r.segments) {
    console.log(
      `  [${s.lang} ${s.speech}] tok ${s.firstTokenAfterOnset} | final ${s.firstFinalAfterOnset} | tr ${s.firstTranslationAfterOnset} | tr-final ${s.firstFinalTranslationAfterOnset} | <end> +${s.endAfterSpeechEnd} | tr-after-end ${s.finalTranslationTokensAfterEnd}`,
    );
    console.log(`     orig: ${s.original}`);
    console.log(`     tran: ${s.translation}`);
    if (s.finalLangMismatch.length || s.nonFinalLangMismatch.length)
      console.log(`     lang mismatch final=${JSON.stringify(s.finalLangMismatch)} nonfinal=${JSON.stringify(s.nonFinalLangMismatch)}`);
  }
  for (const sc of r.script) console.log(`  simplified=${sc.simplified}: ${sc.text}`);
  for (const [name, t] of Object.entries(r.turnRuns)) {
    console.log(`  turns ${name}: ${t.langs} ${t.ok ? "OK" : "WRONG"}${t.events.length ? ` events=${JSON.stringify(t.events.map((e) => e.note))}` : ""}`);
  }
  console.log(`  tags: ${JSON.stringify(r.tagShapes)}`);
}
