// D2 spike: stream a 16 kHz mono s16le PCM file to Soniox stt-rt-v5 at real-time pace
// and record every response with its receive time.
//
// Usage: node stream.mjs --file out/audio/conv_zh.pcm --pair zh --label conv_zh [--temp-key]
//                        [--chunk-ms 120] [--extra '{"max_endpoint_delay_ms":1000}']
//
// The API key is read from server/.env at runtime and never printed or written.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const here = dirname(fileURLToPath(import.meta.url));

export function loadSonioxKey() {
  const env = readFileSync(resolve(here, "../../server/.env"), "utf8");
  const line = env.split(/\r?\n/).find((l) => l.startsWith("SONIOX_API_KEY="));
  const key = line?.slice("SONIOX_API_KEY=".length).trim().replace(/^["']|["']$/g, "");
  if (!key) throw new Error("SONIOX_API_KEY missing in server/.env");
  return key;
}

export async function mintTempKey(apiKey, seconds = 60) {
  const res = await fetch("https://api.soniox.com/v1/auth/temporary-api-key", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ usage_type: "transcribe_websocket", expires_in_seconds: seconds }),
  });
  const body = await res.json().catch(() => ({}));
  return { status: res.status, key: body.api_key, expiresAt: body.expires_at, error: body.error_message };
}

export function buildConfig(pair, extra = {}) {
  return {
    model: "stt-rt-v5",
    audio_format: "pcm_s16le",
    sample_rate: 16000,
    num_channels: 1,
    language_hints: ["en", pair],
    enable_language_identification: true,
    enable_endpoint_detection: true,
    translation: { type: "two_way", language_a: "en", language_b: pair },
    ...extra,
  };
}

export function streamFile({ apiKey, pcm, config, chunkMs = 120, onMessage }) {
  const bytesPerMs = 32; // 16 kHz * 2 bytes
  const chunkBytes = chunkMs * bytesPerMs;
  return new Promise((resolveP) => {
    const ws = new WebSocket("wss://stt-rt.soniox.com/transcribe-websocket");
    ws.binaryType = "arraybuffer";
    const log = [];
    let t0 = null;
    const now = () => (t0 === null ? 0 : performance.now() - t0);
    let timer = null;
    let sentBytes = 0;
    const tOpenStart = performance.now();

    ws.addEventListener("open", () => {
      log.push({ kind: "open", connectMs: Math.round(performance.now() - tOpenStart) });
      ws.send(JSON.stringify({ api_key: apiKey, ...config }));
      t0 = performance.now();
      let i = 0;
      const tick = () => {
        if (ws.readyState !== WebSocket.OPEN) return;
        const start = i * chunkBytes;
        if (start >= pcm.length) {
          ws.send(""); // empty frame = end of audio
          log.push({ kind: "eos", t: now(), audioMs: sentBytes / bytesPerMs });
          return;
        }
        const chunk = pcm.subarray(start, start + chunkBytes);
        ws.send(chunk);
        sentBytes += chunk.length;
        i += 1;
        // schedule against the wall clock to avoid drift
        const due = t0 + i * chunkMs;
        timer = setTimeout(tick, Math.max(0, due - performance.now()));
      };
      tick();
    });
    ws.addEventListener("message", (ev) => {
      const t = now();
      let msg;
      try {
        msg = JSON.parse(typeof ev.data === "string" ? ev.data : Buffer.from(ev.data).toString("utf8"));
      } catch {
        msg = { unparsed: String(ev.data) };
      }
      const entry = { kind: "msg", t, audioSentMs: sentBytes / bytesPerMs, msg };
      log.push(entry);
      onMessage?.(entry);
    });
    ws.addEventListener("error", (ev) => {
      log.push({ kind: "error", t: now(), message: ev?.message ?? String(ev?.error ?? "ws error") });
    });
    ws.addEventListener("close", (ev) => {
      clearTimeout(timer);
      log.push({ kind: "close", t: now(), code: ev.code, reason: ev.reason });
      resolveP(log);
    });
  });
}

// CLI
if (import.meta.url === `file://${process.argv[1]}`) {
  const { values } = parseArgs({
    options: {
      file: { type: "string" },
      pair: { type: "string" },
      label: { type: "string" },
      "temp-key": { type: "boolean", default: false },
      "chunk-ms": { type: "string", default: "120" },
      extra: { type: "string", default: "{}" },
    },
  });
  const pcm = readFileSync(resolve(here, values.file));
  let apiKey = loadSonioxKey();
  if (values["temp-key"]) {
    const tk = await mintTempKey(apiKey, 60);
    console.log(`temp key mint: HTTP ${tk.status}${tk.key ? " (ok)" : ` ${tk.error ?? ""}`}`);
    if (!tk.key) process.exit(1);
    apiKey = tk.key;
  }
  const config = buildConfig(values.pair, JSON.parse(values.extra));
  const log = await streamFile({
    apiKey,
    pcm,
    config,
    chunkMs: Number(values["chunk-ms"]),
    onMessage: (e) => {
      if (e.msg.error_code) console.log(`ERROR ${e.msg.error_code} ${e.msg.error_type ?? ""}: ${e.msg.error_message}`);
    },
  });
  const outDir = join(here, "out/runs");
  mkdirSync(outDir, { recursive: true });
  const label = values.label ?? values.file.replace(/.*\//, "").replace(/\.pcm$/, "");
  writeFileSync(
    join(outDir, `${label}.json`),
    JSON.stringify({ label, file: values.file, pair: values.pair, config, tempKey: values["temp-key"], log }, null, 0),
  );
  const msgs = log.filter((l) => l.kind === "msg");
  const close = log.find((l) => l.kind === "close");
  const errs = msgs.filter((m) => m.msg.error_code);
  console.log(
    `${label}: ${msgs.length} msgs, close ${close?.code} ${close?.reason ?? ""}, errors ${errs.length}, finished ${msgs.some((m) => m.msg.finished)}`,
  );
  if (errs.length || !msgs.some((m) => m.msg.finished)) process.exitCode = 2;
}
