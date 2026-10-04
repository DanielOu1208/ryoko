// The Hono app: middleware, routes and error handling (design §6.4, §7).
// createApp() has no side effects, so tests drive it with app.request().

import { randomBytes } from 'node:crypto';
import { Hono, type Context } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { bodyLimit } from 'hono/body-limit';
import type { ContentfulStatusCode } from 'hono/utils/http-status';
import {
  AllergyCardRequest,
  AllergyCardResponse,
  DiscoverRequest,
  DiscoverResponse,
  MimoMessageRequest,
  PlaceCardRequest,
  PlaceCardResponse,
  SonioxKeyResponse,
  TranslateRequest,
  TranslateResponse,
} from '@ryoko/contracts';
import type { Config } from './config.ts';
import { ApiError, errorResponse, toApiError } from './errors.ts';
import { bearerAuth } from './middleware/auth.ts';
import { clientInfo, type AppEnv } from './middleware/client.ts';
import { RateLimiter, rateLimit } from './middleware/rate-limit.ts';
import { SESSION_ID, SessionLocks } from './sessions.ts';
import { createSkills, type MimoContext, type MimoRun, type SkillContext, type Skills } from './skills/index.ts';
import { createSonioxMinter, type SonioxMinter } from './soniox.ts';
import { sseResponse } from './sse.ts';
import { checkResponse, readJson } from './validate.ts';

export interface AppOptions {
  /** Defaults to createSkills(config). Tests can inject their own. */
  skills?: Skills;
  /**
   * Mints temporary Soniox keys. Defaults to Soniox itself when SONIOX_API_KEY
   * is set (whatever MODEL is), else null: the route answers 503. Tests inject a stub.
   */
  soniox?: SonioxMinter | null;
  log?: (line: string) => void;
}

export interface RyokoApp {
  app: Hono<AppEnv>;
  skills: Skills;
  sessions: SessionLocks;
}

const newRunId = () => `run_${randomBytes(6).toString('hex')}`;

export function createApp(config: Config, options: AppOptions = {}): RyokoApp {
  const log = options.log ?? ((line: string) => console.log(line));
  const skills = options.skills ?? createSkills(config);
  const sessions = new SessionLocks();
  const limiter = new RateLimiter(config.rateLimitPerMinute);
  // One key per listening session: far fewer than other requests.
  const sonioxLimiter = new RateLimiter(config.soniox.perMinute);
  const sonioxKey = config.env.SONIOX_API_KEY?.trim();
  const soniox =
    options.soniox !== undefined ? options.soniox : sonioxKey ? createSonioxMinter({ apiKey: sonioxKey, settings: config.soniox }) : null;
  const app = new Hono<AppEnv>();

  if (config.logRequests) {
    app.use(async (c, next) => {
      const started = performance.now();
      await next();
      // Never log headers or bodies: they carry the token and the profile.
      log(`${c.req.method} ${c.req.path} ${c.res.status} ${Math.round(performance.now() - started)}ms`);
    });
  }

  app.onError((err, c) => {
    let apiError: ApiError;
    if (err instanceof ApiError) {
      apiError = err;
    } else if (err instanceof HTTPException && err.status < 500) {
      apiError = new ApiError('invalid_request', err.message || 'Bad request.', { status: err.status as ContentfulStatusCode });
    } else {
      apiError = toApiError(err);
      console.error(`Unhandled error on ${c.req.method} ${c.req.path}:`, err);
    }
    return errorResponse(c, apiError);
  });

  app.notFound((c) => errorResponse(c, new ApiError('invalid_request', `No such endpoint: ${c.req.method} ${c.req.path}`, { status: 404 })));

  app.get('/healthz', (c) => {
    c.header('Cache-Control', 'no-store');
    return c.json({ ok: true });
  });

  // Order: auth first (cheap), then who's calling, then the limits, then the body.
  app.use('/v1/*', bearerAuth(config.appToken));
  app.use('/v1/*', clientInfo());
  app.use('/v1/*', rateLimit(limiter));
  app.use(
    '/v1/*',
    bodyLimit({
      maxSize: config.bodyLimitBytes,
      onError: () => {
        throw new ApiError('invalid_request', `The request body is larger than ${config.bodyLimitBytes / 1024} KB.`, { status: 413 });
      },
    }),
  );

  const skillContext = (c: Context<AppEnv>): SkillContext => ({
    installId: c.get('installId'),
    clientVersion: c.get('clientVersion'),
    signal: c.req.raw.signal,
  });

  app.post('/v1/place-card', async (c) => {
    const request = await readJson(c, PlaceCardRequest, 'place-card');
    const response = await skills.placeCard(request, skillContext(c));
    return c.json(checkResponse(PlaceCardResponse, response, 'place-card'));
  });

  app.post('/v1/discover', async (c) => {
    const request = await readJson(c, DiscoverRequest, 'discover');
    const response = await skills.discover(request, skillContext(c));
    return c.json(checkResponse(DiscoverResponse, response, 'discover'));
  });

  app.post('/v1/allergy-card', async (c) => {
    const request = await readJson(c, AllergyCardRequest, 'allergy-card');
    const response = await skills.allergyCard(request, skillContext(c));
    return c.json(checkResponse(AllergyCardResponse, response, 'allergy-card'));
  });

  app.post('/v1/translate', async (c) => {
    const request = await readJson(c, TranslateRequest, 'translate');
    const response = await skills.translate(request, skillContext(c));
    return c.json(checkResponse(TranslateResponse, response, 'translate'));
  });

  // A short-lived, single-use Soniox key for one listening session (tier 2).
  // The body is ignored (the app sends {}). The key is never logged.
  app.post('/v1/soniox-key', rateLimit(sonioxLimiter), async (c) => {
    if (!soniox) {
      throw new ApiError('model_error', "Soniox isn't set up on this server: set SONIOX_API_KEY in server/.env.", { status: 503, retryable: false });
    }
    const key = await soniox(c.req.raw.signal);
    c.header('Cache-Control', 'no-store');
    return c.json(checkResponse(SonioxKeyResponse, key, 'soniox-key'));
  });

  app.post('/v1/sessions/:id/messages', async (c) => {
    const sessionId = c.req.param('id');
    if (!SESSION_ID.test(sessionId)) {
      throw new ApiError('invalid_request', 'The session id must be 1–64 letters, digits, dashes or underscores.');
    }
    const request = await readJson(c, MimoMessageRequest, 'Mimo message');

    const release = sessions.tryAcquire(sessionId);
    if (!release) {
      throw new ApiError('session_busy', 'Mimo is still answering your last message. Try again in a moment.');
    }

    const runId = newRunId();
    const ctx: MimoContext = { ...skillContext(c), sessionId, runId };
    let run: MimoRun;
    try {
      run = await skills.mimo(request, ctx);
    } catch (err) {
      release();
      throw err;
    }

    return sseResponse(
      c,
      async (sink) => {
        // Hold the lock until the run itself returns, not until the client leaves:
        // a model call can outlive the connection, and pi throws on concurrent
        // prompts (design §6.4, decision 21).
        try {
          if (sink.closed) return; // the client left before the run started
          sink.send({ type: 'start', sessionId, runId });
          const stopReason = await run(sink);
          sink.send({ type: 'done', stopReason });
        } finally {
          release();
        }
      },
      {
        pingMs: config.ssePingSeconds * 1000,
        onClose: (reason) => {
          if (reason === 'client_closed' && config.logRequests) log(`SSE ${sessionId} ${runId} closed by the client`);
        },
        onError: (err) => {
          if (!(err instanceof ApiError)) console.error(`Mimo run ${runId} failed:`, err);
        },
      },
    );
  });

  return { app, skills, sessions };
}
