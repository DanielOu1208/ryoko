// Picks the skill set for the configured MODEL: fixtures for `faux`, otherwise
// the model-backed skills (W7) on the per-skill models from server/.env.

import type { Config } from '../config.ts';
import { createFauxSkills } from './faux.ts';
import { createModelSkills, type ModelSkillsOptions } from './model.ts';
import type { Skills } from './types.ts';

export type { MimoContext, MimoRun, SkillContext, Skills } from './types.ts';

/** `options` (the shared cache and budget, stats hooks) apply to the model-backed skills only. */
export function createSkills(config: Config, options: ModelSkillsOptions = {}): Skills {
  if (config.model === 'faux') return createFauxSkills(config.faux);
  return createModelSkills(config, options);
}
