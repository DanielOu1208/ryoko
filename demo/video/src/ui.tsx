import React from 'react';
import {
  AbsoluteFill,
  Easing,
  Freeze,
  OffthreadVideo,
  Sequence,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';

export const FONT = '-apple-system, "SF Pro Display", "SF Pro", system-ui, sans-serif';
export const INK = '#1d1d1f';
export const SECONDARY = '#6e6e73';
export const ACCENT = '#3a5bd9';
export const PAPER = '#f5f5f7';

// The recordings are 1206 × 2622 (iPhone 18 Pro, 3×).
export const SCREEN_H = 840;
export const SCREEN_W = (SCREEN_H * 1206) / 2622;
export const BEZEL = 13;
export const PHONE_W = SCREEN_W + BEZEL * 2;
export const PHONE_H = SCREEN_H + BEZEL * 2;

const smooth = Easing.bezier(0.45, 0, 0.2, 1);

/** Linear keyframes, eased between each pair. `points` are [seconds, value]. */
export const track = (t: number, points: [number, number][]) => {
  if (t <= points[0][0]) return points[0][1];
  for (let i = 1; i < points.length; i++) {
    const [t1, v1] = points[i];
    const [t0, v0] = points[i - 1];
    if (t <= t1) return interpolate(t, [t0, t1], [v0, v1], {easing: smooth});
  }
  return points[points.length - 1][1];
};

export type Camera = {
  t: number;
  x: number; // where the focus point sits on stage
  y: number;
  s: number; // zoom
  fx?: number; // focus point on the phone, 0…1
  fy?: number;
  rx?: number; // tilt back, degrees (phone laid flat)
  o?: number; // opacity
};

const camValue = (t: number, keys: Camera[], pick: (c: Camera) => number) =>
  track(t, keys.map((k) => [k.t, pick(k)] as [number, number]));

/** One stretch of a take on the phone: `from` seconds into the take, at `rate`, or frozen. */
export type Clip = {take: string; at: number; dur: number; from: number; rate?: number; freeze?: boolean};

export const Screen: React.FC<{clips: Clip[]; offset?: number}> = ({clips, offset = 0}) => {
  const {fps} = useVideoConfig();
  return (
    <>
      {clips.map((c, i) => {
        const video = (
          <OffthreadVideo
            src={staticFile(`${c.take}.mp4`)}
            trimBefore={Math.round(c.from * fps)}
            playbackRate={c.rate ?? 1}
            muted
            style={{width: '100%', height: '100%', objectFit: 'cover', display: 'block'}}
          />
        );
        return (
          <Sequence key={i} from={Math.round((c.at - offset) * fps)} durationInFrames={Math.round(c.dur * fps)} layout="none">
            <AbsoluteFill>{c.freeze ? <Freeze frame={0}>{video}</Freeze> : video}</AbsoluteFill>
          </Sequence>
        );
      })}
    </>
  );
};

/** An iPhone (titanium edge, black bezel) with `children` as its screen. */
export const PhoneFrame: React.FC<{children: React.ReactNode; scale?: number}> = ({children, scale = 1}) => {
  const radius = SCREEN_W * 0.137;
  return (
    <div
      style={{
        width: PHONE_W * scale,
        height: PHONE_H * scale,
        borderRadius: (radius + BEZEL) * scale,
        padding: BEZEL * scale,
        boxSizing: 'border-box',
        background: 'linear-gradient(145deg, #3a3a3d 0%, #1b1b1d 38%, #2c2c2f 62%, #0f0f10 100%)',
        boxShadow: [
          `0 ${50 * scale}px ${90 * scale}px rgba(20, 24, 60, 0.22)`,
          `0 ${12 * scale}px ${28 * scale}px rgba(0, 0, 0, 0.14)`,
          `inset 0 0 0 ${1.5 * scale}px rgba(255, 255, 255, 0.16)`,
          `inset 0 0 0 ${3.5 * scale}px #050506`,
        ].join(', '),
        position: 'relative',
      }}
    >
      {/* side buttons */}
      {[
        {side: 'left', top: 0.2, h: 0.045},
        {side: 'left', top: 0.28, h: 0.075},
        {side: 'left', top: 0.37, h: 0.075},
        {side: 'right', top: 0.3, h: 0.11},
      ].map((b, i) => (
        <div
          key={i}
          style={{
            position: 'absolute',
            [b.side]: -3 * scale,
            top: PHONE_H * scale * b.top,
            width: 4 * scale,
            height: PHONE_H * scale * b.h,
            borderRadius: 2 * scale,
            background: 'linear-gradient(90deg, #2a2a2d, #4a4a4e)',
          }}
        />
      ))}
      <div
        style={{
          width: '100%',
          height: '100%',
          borderRadius: radius * scale,
          overflow: 'hidden',
          background: '#fff',
          position: 'relative',
          transform: 'translateZ(0)',
        }}
      >
        {children}
      </div>
    </div>
  );
};

/** The phone placed and moved by a camera track (seconds from the composition's start). */
export const CameraPhone: React.FC<{keys: Camera[]; children: React.ReactNode}> = ({keys, children}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const t = frame / fps;
  const x = camValue(t, keys, (k) => k.x);
  const y = camValue(t, keys, (k) => k.y);
  const s = camValue(t, keys, (k) => k.s);
  const fx = camValue(t, keys, (k) => k.fx ?? 0.5);
  const fy = camValue(t, keys, (k) => k.fy ?? 0.5);
  const rx = camValue(t, keys, (k) => k.rx ?? 0);
  const o = camValue(t, keys, (k) => k.o ?? 1);
  return (
    <AbsoluteFill style={{perspective: 2200, perspectiveOrigin: `${x}px ${y}px`}}>
      <div
        style={{
          position: 'absolute',
          left: x - fx * PHONE_W,
          top: y - fy * PHONE_H,
          transformOrigin: `${fx * PHONE_W}px ${fy * PHONE_H}px`,
          transform: `scale(${s}) rotateX(${rx}deg)`,
          opacity: o,
        }}
      >
        <PhoneFrame>{children}</PhoneFrame>
      </div>
    </AbsoluteFill>
  );
};

/** The page: Apple's light grey with a slow periwinkle wash (Ryoko's blue). */
export const Backdrop: React.FC = () => {
  const frame = useCurrentFrame();
  const t = frame / 30;
  const blob = (cx: number, cy: number, r: number, color: string, phase: number) => (
    <div
      style={{
        position: 'absolute',
        left: cx + Math.sin(t * 0.13 + phase) * 60 - r,
        top: cy + Math.cos(t * 0.11 + phase) * 40 - r,
        width: r * 2,
        height: r * 2,
        borderRadius: '50%',
        background: `radial-gradient(circle, ${color} 0%, rgba(255,255,255,0) 68%)`,
      }}
    />
  );
  return (
    <AbsoluteFill style={{background: PAPER, overflow: 'hidden'}}>
      {blob(1450, 260, 720, 'rgba(120, 140, 255, 0.20)', 0)}
      {blob(1700, 900, 620, 'rgba(160, 130, 255, 0.13)', 2)}
      {blob(300, 980, 620, 'rgba(120, 170, 255, 0.10)', 4)}
    </AbsoluteFill>
  );
};

export type Card = {
  at: number;
  until: number;
  eyebrow?: string;
  title: string;
  sub?: string;
  x?: number;
  y?: number;
  width?: number;
  align?: 'left' | 'center';
};

/** A headline that rises in and fades out. */
export const Headline: React.FC<{card: Card}> = ({card}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const local = frame - card.at * fps;
  const enter = spring({frame: local, fps, config: {damping: 200, mass: 0.9}, durationInFrames: Math.round(0.9 * fps)});
  const exit = interpolate(frame, [(card.until - 0.45) * fps, card.until * fps], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const part = (delay: number) => {
    const p = spring({frame: local - delay * fps, fps, config: {damping: 200}, durationInFrames: Math.round(0.9 * fps)});
    return {opacity: p * exit, transform: `translateY(${(1 - p) * 26}px)`, filter: `blur(${(1 - p) * 6}px)`};
  };
  if (frame < card.at * fps || frame > card.until * fps) return null;
  const align = card.align ?? 'left';
  return (
    <div
      style={{
        position: 'absolute',
        left: card.x ?? 170,
        top: card.y ?? 540,
        width: card.width ?? 640,
        transform: `translate(${align === 'center' ? '-50%' : '0'}, -50%)`,
        textAlign: align,
        fontFamily: FONT,
        color: INK,
        opacity: enter > 0 ? 1 : 0,
      }}
    >
      {card.eyebrow && (
        <div style={{...part(0), fontSize: 26, fontWeight: 600, color: ACCENT, letterSpacing: '0.01em', marginBottom: 14}}>
          {card.eyebrow}
        </div>
      )}
      <div style={{...part(0.08), fontSize: 68, fontWeight: 700, lineHeight: 1.06, letterSpacing: '-0.025em', textWrap: 'balance'}}>{card.title}</div>
      {card.sub && (
        <div style={{...part(0.2), fontSize: 30, fontWeight: 500, lineHeight: 1.32, color: SECONDARY, marginTop: 22, letterSpacing: '-0.01em', textWrap: 'pretty'}}>
          {card.sub}
        </div>
      )}
    </div>
  );
};

/** Mimo, cut from the app's avatar gallery (black on transparent). */
export const Mimo: React.FC<{size: number; style?: React.CSSProperties}> = ({size, style}) => (
  <div style={{width: size, height: size, overflow: 'hidden', position: 'relative', ...style}}>
    <img
      src={staticFile('mimo.png')}
      style={{position: 'absolute', width: size * 1.516, left: -size * 0.25, top: -size * 0.22}}
    />
  </div>
);
