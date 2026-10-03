// Picks the skill set for the configured MODEL.
// W7: build the model-backed Skills in this folder and return them here for non-faux models.

import type { Config } from '../config.ts';
import { createFauxSkills } from './faux.ts';
import { createPendingSkills } from './pending.ts';
import type { Skills } from './types.ts';

export type { MimoContext, MimoRun, SkillContext, Skills } from './types.ts';

export function createSkills(config: Config): Skills {
  if (config.model === 'faux') return createFauxSkills(config.faux);
  return createPendingSkills(config.model);
}
