// Mimo's <trip_memory> prompt section (design §6.6, §8.3): the latest events and
// the older ones most like the message, with times relative to the traveller's
// local "now", so "yesterday at the ramen shop" means something to the model.

import type { Situation, TripEventKind } from '@ryoko/contracts';
import type { Recall, RecalledEvent } from './tiger.ts';

const DID: Record<TripEventKind, string> = {
  place_confirmed: 'was at',
  phrase_shown: 'showed a phrase',
  phrase_spoken: 'said a phrase',
  typed_translation: 'typed in Translate',
};

/** `2026-10-05` from a local ISO time, as a day number for comparing dates. */
function localDay(iso: string): number | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  return match ? Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])) / 86_400_000 : null;
}

/** "12 min ago", "today 19:42", "yesterday 19:42", "3 days ago, 19:42", or the date. */
export function when(event: RecalledEvent, situation: Situation): string {
  const minutes = Math.round((Date.parse(situation.localTime) - event.time.getTime()) / 60_000);
  if (minutes >= 0 && minutes < 2) return 'just now';
  if (minutes >= 0 && minutes < 60) return `${minutes} min ago`;
  const clock = event.localTime?.slice(11, 16) ?? null;
  const eventDay = event.localTime ? localDay(event.localTime) : null;
  const today = localDay(situation.localTime);
  if (eventDay === null || today === null || !clock) {
    const hours = Math.max(1, Math.round(minutes / 60));
    return hours < 48 ? `${hours} h ago` : `${Math.round(hours / 24)} days ago`;
  }
  const days = today - eventDay;
  if (days <= 0) return `today ${clock}`;
  if (days === 1) return `yesterday ${clock}`;
  if (days < 7) return `${days} days ago, ${clock}`;
  return event.localTime!.slice(0, 10);
}

function line(event: RecalledEvent, situation: Situation): Record<string, string> {
  const out: Record<string, string> = { when: when(event, situation), did: DID[event.kind], text: event.text };
  if (event.meaning) out.meaning = event.meaning;
  if (event.placeName && event.kind !== 'place_confirmed') out.at = event.category ? `${event.placeName} (${event.category})` : event.placeName;
  if (event.kind === 'place_confirmed' && event.category) out.category = event.category;
  if (event.city && event.city !== situation.city) out.city = event.city;
  return out;
}

/** The section, or null when there's nothing to remember. */
export function tripMemorySection(recall: Recall, situation: Situation): string | null {
  if (recall.recent.length === 0 && recall.similar.length === 0) return null;
  const parts = ['<trip_memory>'];
  if (recall.recent.length > 0) {
    parts.push('Latest on this trip, newest first:', JSON.stringify(recall.recent.map((e) => line(e, situation))));
  }
  if (recall.similar.length > 0) {
    parts.push('Earlier moments like this message:', JSON.stringify(recall.similar.map((e) => line(e, situation))));
  }
  parts.push('</trip_memory>');
  return parts.join('\n');
}
