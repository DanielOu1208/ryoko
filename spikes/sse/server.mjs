// Spike D4: SSE through Tailscale Funnel. Plain node:http, no dependencies.
// Usage: PORT=8792 node spikes/sse/server.mjs
import http from 'node:http';

const PORT = Number(process.env.PORT ?? 8792);
const HOST = '127.0.0.1';
const PAD = ':' + ' '.repeat(2048) + '\n\n'; // > 512 bytes so URLSession flushes

function sse(res, { pad }) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'X-Accel-Buffering': 'no',
    Connection: 'keep-alive',
  });
  res.flushHeaders();
  res.socket?.setNoDelay(true);
  if (pad) res.write(PAD);
  let i = 0;
  const send = (obj) => res.write(`data: ${JSON.stringify(obj)}\n\n`);
  const timer = setInterval(() => {
    if (i < 10) {
      send({ type: 'text', delta: `chunk ${i} `, t: Date.now() });
      i++;
      return;
    }
    clearInterval(timer);
    res.write(': ping\n\n');
    send({ type: 'done', stopReason: 'stop' });
    res.end();
  }, 300);
  res.on('close', () => clearInterval(timer));
}

http
  .createServer((req, res) => {
    const path = new URL(req.url, 'http://x').pathname;
    console.log(new Date().toISOString(), req.method, path, 'funnel=' + (req.headers['tailscale-funnel-request'] ?? '-'), 'xff=' + (req.headers['x-forwarded-for'] ?? '-'));
    if (req.method === 'GET' && path === '/healthz') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      return res.end('ok');
    }
    if (req.method === 'GET' && path === '/sse') return sse(res, { pad: true });
    if (req.method === 'GET' && path === '/sse-nopad') return sse(res, { pad: false });
    res.writeHead(404).end();
  })
  .listen(PORT, HOST, () => console.log(`sse spike on http://${HOST}:${PORT}`));
