// MODEL=faux: canned responses from contracts/examples, no model calls (design §6.4).
// Every skill answers with the example for the local language (pickFixture): the
// situation's for place-card, discover and Mimo, the request's for allergy-card,
// and the target language (`to`) for translate.
// Mimo replays mimo[.<variant>].sse.txt with realistic pacing.

import type { SseEvent, StopReason } from '@ryoko/contracts';
import type { FauxConfig } from '../config.ts';
import { loadFixtures, pickFixture, type FixtureSet, type TranscriptItem } from '../fixtures.ts';
import { clientClosed } from '../errors.ts';
import { sleep } from '../sse.ts';
import { sameLanguage } from './translate.ts';
import type { MimoContext, MimoRun, Skills } from './types.ts';

/** Milliseconds before each scripted event, at pace 1. */
export const FAUX_PACING = {
  firstEvent: 350, // time to first token
  text: 40,
  phrase: 40,
  aroundTool: 400, // before tool_start, while the tool "runs", and after tool_end
} as const;

function delayBefore(event: SseEvent, previous: SseEvent | null): number {
  if (previous === null) return FAUX_PACING.firstEvent;
  if (event.type === 'tool_start' || event.type === 'tool_end' || previous.type === 'tool_end') return FAUX_PACING.aroundTool;
  if (event.type === 'phrase') return FAUX_PACING.phrase;
  return FAUX_PACING.text;
}

/** Gives the replayed run this request's ids, so phrase ids stay unique across runs. */
function rewrite(event: SseEvent, scriptRunId: string | null, ctx: MimoContext): SseEvent {
  if (event.type === 'phrase' && scriptRunId) {
    return { ...event, phrase: { ...event.phrase, id: event.phrase.id.split(scriptRunId).join(ctx.runId) } };
  }
  return event;
}

export function replayTranscript(transcript: TranscriptItem[], ctx: MimoContext, pace: number): MimoRun {
  const start = transcript.find((i) => i.kind === 'event' && i.event.type === 'start');
  const scriptRunId = start?.kind === 'event' && start.event.type === 'start' ? start.event.runId : null;

  return async (sink) => {
    let previous: SseEvent | null = null;
    for (const item of transcript) {
      if (sink.closed) return 'aborted';
      if (item.kind === 'comment') {
        // The padding comment is the helper's job; keep only the scripted pings.
        if (item.text === 'ping') sink.comment('ping');
        continue;
      }
      const event = item.event;
      if (event.type === 'start') continue; // the route sends its own
      if (event.type === 'done') return event.stopReason;
      await sleep(delayBefore(event, previous) * pace, sink.signal);
      sink.send(rewrite(event, scriptRunId, ctx));
      previous = event;
    }
    return 'stop' satisfies StopReason;
  };
}

export function createFauxSkills(config: FauxConfig, fixtures: FixtureSet = loadFixtures()): Skills {
  const latency = () => sleep(config.latencyMs);
  return {
    name: 'faux',
    async placeCard(request) {
      await latency();
      const { response } = pickFixture(fixtures.placeCard, request.situation.localLanguage);
      return { ...structuredClone(response), generatedAt: new Date().toISOString() };
    },
    async discover(request) {
      await latency();
      return structuredClone(pickFixture(fixtures.discover, request.situation.localLanguage).response);
    },
    async allergyCard(request) {
      await latency();
      return structuredClone(pickFixture(fixtures.allergyCard, request.language).response);
    },
    async translate(request, ctx) {
      await sleep(config.latencyMs, ctx.signal).catch(() => {
        throw clientClosed();
      });
      // Nothing to translate between a language and itself; otherwise the example
      // for the target language, whatever was typed (it's a fixture).
      if (sameLanguage(request.from, request.to)) return { translation: request.text.trim() };
      return structuredClone(pickFixture(fixtures.translate, request.to).response);
    },
    async mimo(request, ctx) {
      // The model and level are the app's pick; fixtures replay the same script whatever they are.
      return replayTranscript(pickFixture(fixtures.mimo, request.situation.localLanguage).response, ctx, config.pace);
    },
    async mimoModels() {
      await latency();
      return structuredClone(fixtures.mimoModels);
    },
  };
}
