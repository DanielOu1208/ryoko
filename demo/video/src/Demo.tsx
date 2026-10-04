import React from 'react';
import {AbsoluteFill, Sequence, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {
  ACCENT,
  Backdrop,
  Camera,
  CameraPhone,
  Card,
  Clip,
  FONT,
  Headline,
  INK,
  Mimo,
  PhoneFrame,
  SECONDARY,
  Screen,
  track,
} from './ui';

export const FPS = 30;
export const DURATION = 180 * FPS;

// Where the phone rests: the right half, text on the left.
const PX = 1330;
const PY = 540;
const rest = (t: number, extra: Partial<Camera> = {}): Camera => ({t, x: PX, y: PY, s: 1, ...extra});
/** Zoom on a point of the screen (fx, fy) and bring it to (x, y). */
const zoom = (t: number, s: number, fx: number, fy: number, x = PX, y = PY): Camera => ({t, x, y, s, fx, fy});

// ---------------------------------------------------------------------------
// The edit. Times are seconds on the timeline; `from` is seconds into a take.
// Takes (demo/out/raw → public/*.mp4, 30 fps): map, park, translate, mimo.
// ---------------------------------------------------------------------------

/** The phone's screen, shot by shot. */
const CLIPS: Clip[] = [
  // Intro and Map: locating → picks arrive → scroll the picks.
  {take: 'map', at: 3.2, dur: 13.8, from: 4.0},
  // Search: typing "7-eleven" (the bridge taps keys slowly; sped up).
  {take: 'map', at: 17.0, dur: 4.6, from: 17.8, rate: 2.5},
  // The 7-Eleven card: Look Around, phrases arriving, scrolled to them.
  {take: 'map', at: 21.6, dur: 15.4, from: 29.9},
  // Show mode, then Flip.
  {take: 'map', at: 37.0, dur: 7.5, from: 52.3, rate: 1.2},
  // Me.
  {take: 'map', at: 44.5, dur: 11.5, from: 63.2},
  // Nara Park: the picks, tap, its card…
  {take: 'park', at: 56.0, dur: 8.5, from: 11.0},
  // …scrolled down to the tips (quicker), then held.
  {take: 'park', at: 64.5, dur: 4.6, from: 21.5, rate: 3},
  {take: 'park', at: 69.1, dur: 10.9, from: 35.3},
  // Translate, ready to listen (held while the section opens).
  {take: 'translate', at: 80.0, dur: 15.5, from: 3.2, freeze: true},
  // The coffee order: mic, English → Chinese, the barista's answer, flip, two more lines.
  {take: 'translate', at: 95.5, dur: 39.5, from: 3.5},
  // Mimo: a new chat…
  {take: 'mimo', at: 135.0, dur: 2.5, from: 1.5},
  {take: 'mimo', at: 137.5, dur: 1.2, from: 4.0, rate: 2},
  // …typing the question on the keyboard (sped up to a natural pace)…
  {take: 'mimo', at: 138.7, dur: 6.2, from: 6.4, rate: 6.15},
  // …send, thinking, searching the web, the plan arrives…
  {take: 'mimo', at: 144.9, dur: 10.6, from: 44.5},
  // …Show on map.
  {take: 'mimo', at: 155.5, dur: 4.5, from: 68.2},
];

/** The camera on the phone. */
const CAMERA: Camera[] = [
  {t: 0, x: PX, y: PY + 900, s: 1, o: 0},
  {t: 3.3, x: PX, y: PY + 900, s: 1, o: 0},
  {t: 4.9, x: PX, y: PY, s: 1, o: 1},
  rest(26.5),
  // Phrases: lean in on the cards and their "because" lines.
  zoom(28.5, 1.45, 0.5, 0.72, PX - 40, PY + 40),
  zoom(35.5, 1.45, 0.5, 0.72, PX - 40, PY + 40),
  rest(37.2),
  rest(44.0),
  rest(56.0),
  rest(68.8),
  // Nara Park's tips.
  zoom(70.6, 1.6, 0.5, 0.7, PX - 60, PY + 30),
  zoom(79.0, 1.6, 0.5, 0.7, PX - 60, PY + 30),
  rest(80.4),
  // Translate: the language pills, then the conversation.
  rest(86.0),
  zoom(88.0, 1.5, 0.5, 0.86, PX - 30, PY + 120),
  zoom(94.0, 1.5, 0.5, 0.86, PX - 30, PY + 120),
  rest(96.0),
  // "Lay the phone flat": tip it back as the app flips.
  rest(109.8),
  {t: 111.2, x: PX, y: PY + 30, s: 0.98, rx: 38},
  {t: 113.4, x: PX, y: PY + 30, s: 0.98, rx: 38},
  rest(114.9),
  // The translation, expanded and large: theirs (top, turned to face them)…
  zoom(116.3, 1.5, 0.5, 0.3, PX - 40, PY - 20),
  zoom(119.6, 1.5, 0.5, 0.3, PX - 40, PY - 20),
  rest(121.4),
  // …then the barista's answer, in English for you.
  rest(122.6),
  zoom(124.4, 1.55, 0.5, 0.6, PX - 50, PY + 10),
  zoom(131.0, 1.55, 0.5, 0.6, PX - 50, PY + 10),
  rest(133.0),
  rest(135.0),
  // Mimo's plan.
  rest(151.6),
  zoom(153.0, 1.35, 0.5, 0.45, PX - 30, PY),
  zoom(154.9, 1.35, 0.5, 0.45, PX - 30, PY),
  rest(155.8),
  {t: 158.6, x: PX, y: PY, s: 1, o: 1},
  {t: 159.6, x: PX + 40, y: PY, s: 0.94, o: 0},
];

/** Headlines on the left. */
const CARDS: Card[] = [
  {at: 4.4, until: 9.8, eyebrow: 'Ryoko', title: 'Your whole trip, in one app.', sub: 'Personal from the moment you land.'},
  {at: 10.2, until: 21.3, eyebrow: 'Map', title: 'See what’s around you.', sub: 'Mimo picks the temples, cafés and local favourites worth your time.'},
  {at: 21.8, until: 36.8, eyebrow: 'What to say', title: 'The right phrase, right where you are.', sub: 'Written for this place, your usual order and your allergy.'},
  {at: 37.2, until: 44.3, eyebrow: 'Show mode', title: 'Show it. Flip it.', sub: 'Full screen for the staff, turned to face them.'},
  {at: 44.7, until: 55.7, eyebrow: 'Me', title: 'Built around you.', sub: 'Allergies, diet, favourites and travel style shape every suggestion.'},
  {at: 56.3, until: 79.7, eyebrow: 'Tips', title: 'Know the local customs.', sub: 'Like how to greet Nara’s bowing deer.'},
  {at: 80.4, until: 95.2, eyebrow: 'Translate', title: 'Live, split-screen translation.', sub: 'No waiting. No passing the phone back and forth.'},
  {at: 95.7, until: 108.4, eyebrow: 'Translate', title: 'Ask in English. They hear Chinese.', sub: 'Ordering coffee in Shanghai, in real time.'},
  {at: 108.8, until: 134.6, eyebrow: 'Face to face', title: 'Lay it flat. Their half faces them.', sub: 'Each translation fills the screen, easy to read across the counter.'},
  {at: 135.3, until: 159.4, eyebrow: 'Mimo', title: 'Ask Mimo anything.', sub: 'A plan, the places on the map and the phrase you’ll need.'},
];

export const Demo: React.FC = () => (
  <AbsoluteFill style={{fontFamily: FONT}}>
    <Backdrop />
    <Sequence from={0} durationInFrames={Math.round(4.6 * FPS)} layout="none">
      <TitleCard />
    </Sequence>
    <Sequence from={0} durationInFrames={160 * FPS} layout="none">
      <CameraPhone keys={CAMERA}>
        <Screen clips={CLIPS} />
      </CameraPhone>
    </Sequence>
    {CARDS.map((c, i) => (
      <Headline key={i} card={c} />
    ))}
    <Sequence from={160 * FPS} durationInFrames={13 * FPS} layout="none">
      <Montage />
    </Sequence>
    <Sequence from={172.6 * FPS} durationInFrames={Math.round(7.4 * FPS)} layout="none">
      <EndCard />
    </Sequence>
  </AbsoluteFill>
);

// ---------------------------------------------------------------------------

const TitleCard: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const t = frame / fps;
  const p = spring({frame: frame - 6, fps, config: {damping: 200, mass: 1.2}});
  const out = interpolate(t, [2.7, 3.5], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const lift = interpolate(t, [2.7, 3.5], [0, -60], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const sub = spring({frame: frame - 22, fps, config: {damping: 200}});
  return (
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', opacity: out, transform: `translateY(${lift}px)`}}>
      <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 18}}>
        <Mimo size={128} style={{opacity: p, transform: `scale(${0.8 + 0.2 * p})`}} />
        <div
          style={{
            fontSize: 150,
            fontWeight: 700,
            letterSpacing: '-0.045em',
            color: INK,
            opacity: p,
            transform: `translateY(${(1 - p) * 30}px)`,
            filter: `blur(${(1 - p) * 10}px)`,
          }}
        >
          Ryoko
        </div>
        <div style={{fontSize: 40, fontWeight: 500, color: SECONDARY, letterSpacing: '-0.01em', opacity: sub, transform: `translateY(${(1 - sub) * 16}px)`}}>
          Travel, tailored to you.
        </div>
      </div>
    </AbsoluteFill>
  );
};

/** Four features, four phones (stills from the takes). */
const FEATURES: {take: string; from: number; label: string; sub: string}[] = [
  {take: 'map', from: 50.0, label: 'Personal phrases', sub: 'For the place you’re in'},
  {take: 'park', from: 40.0, label: 'Local customs', sub: 'Tips worth knowing'},
  {take: 'translate', from: 40.0, label: 'Split-screen translation', sub: 'Face to face, live'},
  {take: 'mimo', from: 72.5, label: 'Mimo', sub: 'Plans and places, on the map'},
];

const Montage: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const t = frame / fps;
  const scale = 0.66;
  const out = interpolate(t, [11.8, 12.9], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const title = spring({frame: frame - 4, fps, config: {damping: 200}});
  return (
    <AbsoluteFill style={{opacity: out}}>
      <div
        style={{
          position: 'absolute',
          top: 70,
          width: '100%',
          textAlign: 'center',
          fontSize: 56,
          fontWeight: 700,
          letterSpacing: '-0.025em',
          color: INK,
          opacity: title,
          transform: `translateY(${(1 - title) * 20}px)`,
        }}
      >
        Everything you need, in one app.
      </div>
      <div style={{position: 'absolute', top: 180, width: '100%', display: 'flex', justifyContent: 'center', gap: 64}}>
        {FEATURES.map((f, i) => {
          const p = spring({frame: frame - 8 - i * 5, fps, config: {damping: 200, mass: 1.1}});
          const drift = track(t, [
            [0, 0],
            [12, -14],
          ]);
          return (
            <div key={f.take} style={{display: 'flex', flexDirection: 'column', alignItems: 'center', opacity: p, transform: `translateY(${(1 - p) * 80 + drift}px)`}}>
              <PhoneFrame scale={scale}>
                <Screen clips={[{take: f.take, at: 0, dur: 13, from: f.from, freeze: true}]} />
              </PhoneFrame>
              <div style={{marginTop: 30, fontSize: 30, fontWeight: 650, color: INK, letterSpacing: '-0.015em'}}>{f.label}</div>
              <div style={{marginTop: 6, fontSize: 23, fontWeight: 500, color: SECONDARY}}>{f.sub}</div>
            </div>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};

const EndCard: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const p = spring({frame: frame - 4, fps, config: {damping: 200, mass: 1.2}});
  const sub = spring({frame: frame - 18, fps, config: {damping: 200}});
  return (
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
      <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16}}>
        <Mimo size={110} style={{opacity: p, transform: `scale(${0.85 + 0.15 * p})`}} />
        <div style={{fontSize: 132, fontWeight: 700, letterSpacing: '-0.045em', color: INK, opacity: p, filter: `blur(${(1 - p) * 8}px)`}}>Ryoko</div>
        <div style={{fontSize: 38, fontWeight: 500, color: SECONDARY, opacity: sub, transform: `translateY(${(1 - sub) * 14}px)`}}>
          Travel, tailored to you.
        </div>
        <div style={{marginTop: 26, fontSize: 24, fontWeight: 600, color: ACCENT, opacity: sub}}>Map · Translate · Mimo · Me</div>
      </div>
    </AbsoluteFill>
  );
};
