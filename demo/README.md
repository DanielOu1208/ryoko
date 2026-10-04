# Demo video

The 3-minute Ryoko demo: real recordings of the app on the simulator, composed
in [Remotion](https://www.remotion.dev) (`video/`). The narration is recorded
separately against `SCRIPT.md`.

```
demo/
  SCRIPT.md          narration with timecodes and what's on screen
  narration.json     the same lines, for the guide voice and subtitles
  make_guide.py      scratch voice (macOS say) + subtitles → out/
  sim/               the demo profile
  capture/           drives the simulator and records the takes
  video/             the Remotion composition (src/Demo.tsx is the edit)
  out/               raw takes, frames, renders (ignored)
```

## Recording the takes

1. Build Debug into `ios/.build/DerivedData-demo` (see `capture/prep.sh`).
2. Start a server on 8795 from `server/`: `PORT=8795 node src/index.ts`. The
   demo API scripts the picks, two cards and Mimo's plan; translation and
   everything else go to it.
3. Open Xcode (the first bridge call asks to approve the agent), then:
   ```
   demo/capture/prep.sh && python3 demo/capture/scenes.py map park translate mimo
   ```
   Each take lands in `out/raw/<take>.mp4` with `<take>.events.json`.

The app's DEBUG launch arguments do the scripting: `-RyokoDemo nara`,
`-RyokoClockStart <ISO 8601>` (Nara at 9:41 AM), and
`-RyokoTranslateCannedScript coffee`.

## Editing and rendering

```
cd demo/video && npm install
# proxies: 30 fps, last frame held (recordings end at the last change)
for t in map park translate mimo; do
  ffmpeg -i ../out/raw/$t.mp4 -vf "fps=30,tpad=stop_mode=clone:stop_duration=8" \
    -c:v libx264 -crf 14 -g 15 -pix_fmt yuv420p -an public/$t.mp4
done
# public/mimo.png: Mimo cut from the avatar gallery (-RyokoAvatarGallery 1)
npx remotion studio src/index.ts          # preview
node scripts/stills.mjs 30 75 119         # review stills at those seconds
npx remotion render src/index.ts RyokoDemo out/ryoko-demo.mp4 --codec h264 --crf 16
python3 ../make_guide.py                  # scratch narration + subtitles
```

Remotion is free for individuals and companies of up to three people.
