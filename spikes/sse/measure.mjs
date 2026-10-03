// Spawns `curl -sN <args>` and prints per-line arrival times plus a summary.
// Usage: node spikes/sse/measure.mjs [curl args...] URL
import { spawn } from 'node:child_process';
import readline from 'node:readline';

const start = Date.now();
const curl = spawn('curl', ['-sN', '-w', '%{stderr}curl: ip=%{remote_ip} ttfb=%{time_starttransfer}s connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s\n', ...process.argv.slice(2)]);
curl.stderr.pipe(process.stdout);
const rl = readline.createInterface({ input: curl.stdout });
let first = null, prev = null;
const gaps = [], lags = [];
rl.on('line', (line) => {
  const now = Date.now();
  if (!line) return;
  if (first === null) first = now - start;
  const label = line.startsWith(':') && line.length > 20 ? `: <pad ${line.length}B>` : line;
  let lag = '';
  const m = line.match(/"t":(\d+)/);
  if (m) {
    lags.push(now - Number(m[1]));
    lag = ` lag=${now - Number(m[1])}ms`;
    if (prev !== null) gaps.push(now - prev);
    prev = now;
  }
  if (!process.env.QUIET) console.log(`+${String(now - start).padStart(5)}ms${lag}  ${label.slice(0, 70)}`);
});
curl.on('close', () => {
  const r = (a) => (a.length ? `min=${Math.min(...a)} max=${Math.max(...a)} avg=${Math.round(a.reduce((x, y) => x + y, 0) / a.length)}` : 'n/a');
  console.log(`SUMMARY firstLine=${first}ms total=${Date.now() - start}ms gaps[${r(gaps)}] lag[${r(lags)}]`);
});
