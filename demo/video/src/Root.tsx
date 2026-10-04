import {Composition, Still} from 'remotion';
import {Demo, DURATION, FPS} from './Demo';

export const RemotionRoot = () => (
  <>
    <Composition id="RyokoDemo" component={Demo} durationInFrames={DURATION} fps={FPS} width={1920} height={1080} />
    <Still id="Poster" component={Demo} width={1920} height={1080} />
  </>
);
