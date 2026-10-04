// Entry point: `node src/index.ts` (or `node --watch src/index.ts` for dev).
// Listens on 127.0.0.1 only; Tailscale Funnel forwards :10000 to it (design §6.4).

import { serve } from '@hono/node-server';
import { createApp } from './app.ts';
import { ConfigError, HOST, describeConfig, loadConfig, type Config } from './config.ts';

function fail(message: string): never {
  console.error(`ryoko-server: ${message}`);
  process.exit(1);
}

let config: Config;
try {
  config = loadConfig();
} catch (err) {
  if (err instanceof ConfigError) fail(err.message);
  throw err;
}

let app;
try {
  ({ app } = createApp(config));
} catch (err) {
  fail(`couldn't start: ${(err as Error).message}`);
}

const server = serve({ fetch: app.fetch, hostname: HOST, port: config.port }, (info) => {
  // The pid is for stopping this server alone: every agent's server has the
  // same command line, so `pkill -f` would stop theirs too (AGENTS.md).
  console.log(`Ryoko server on http://${HOST}:${info.port} (${describeConfig(config)}), pid ${process.pid}`);
  console.log(`Dashboard: http://${HOST}:${info.port}/admin`);
});

server.on('error', (err: NodeJS.ErrnoException) => {
  if (err.code === 'EADDRINUSE') fail(`port ${config.port} on ${HOST} is already in use. Stop the other server or set PORT.`);
  fail(`server error: ${err.message}`);
});

let stopping = false;
function shutdown(signal: string) {
  if (stopping) return;
  stopping = true;
  console.log(`Ryoko server stopping (${signal})`);
  server.close(() => process.exit(0));
  // Open SSE streams would hold close() forever.
  if ('closeAllConnections' in server) server.closeAllConnections();
  setTimeout(() => process.exit(0), 2000).unref();
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
