// Renders review stills: node scripts/stills.mjs 30 40.5 75 … (seconds) → out/stills/t_<s>.png
import {bundle} from '@remotion/bundler';
import {renderStill, selectComposition} from '@remotion/renderer';
import path from 'node:path';

const times = process.argv.slice(2).map(Number);
const serveUrl = await bundle({entryPoint: path.resolve('src/index.ts')});
const composition = await selectComposition({serveUrl, id: 'RyokoDemo'});
for (const t of times) {
  const output = `out/stills/t_${t}.png`;
  await renderStill({serveUrl, composition, frame: Math.round(t * composition.fps), output, scale: 0.5});
  console.log(output);
}
