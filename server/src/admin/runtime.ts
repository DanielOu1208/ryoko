// What the dashboard (/admin) reads and changes: the live config and skills, the
// setting overrides, and the activity log (what Mimo is doing and did lately).
//
// Overrides are env values laid over server/.env and go through configFromEnv,
// so they're checked exactly like the file. They live in memory only: a restart
// goes back to server/.env. The response cache and the budget ledger are kept
// across skill rebuilds; Mimo's sessions aren't (a session never changes model).

import type { ResponseCache } from '../cache.ts';
import { configFromEnv, ConfigError, describeModel, SKILL_MODEL_ENV, SKILL_NAMES, type Config, type SkillName } from '../config.ts';
import type { Budget } from '../llm/budget.ts';
import { createSkills, type Skills } from '../skills/index.ts';
import type { MimoSessions } from '../skills/mimo/session.ts';
import type { ModelSkills } from '../skills/model.ts';
import { ActivityLog } from './activity.ts';

/** The env settings the dashboard can change without a restart. */
export const RUNTIME_SETTINGS: readonly string[] = [
  'MODEL',
  ...SKILL_NAMES.flatMap((skill) => [SKILL_MODEL_ENV[skill], `${SKILL_MODEL_ENV[skill]}_REASONING`]),
  'DAILY_BUDGET_USD',
  'FAUX_PACE',
  'FAUX_LATENCY_MS',
];

const isModelSkills = (skills: Skills): skills is ModelSkills => 'mimoSessions' in skills;

/** What decides the skill set: changing anything else keeps the skills (and Mimo's sessions). */
const skillsKey = (config: Config) => JSON.stringify([config.model, config.models, config.faux]);

export class Runtime {
  readonly startedAt = Date.now();
  config: Config;
  skills: Skills;
  overrides: Record<string, string> = {};
  readonly activity = new ActivityLog();
  /** The response cache and the budget, from the first model-backed build on (null before, in fixture mode). */
  cache: ResponseCache | null = null;
  budget: Budget | null = null;
  /** server/.env merged with the process environment, as at startup. Secret: never send it. */
  private readonly baseEnv: Readonly<Record<string, string | undefined>>;

  /** `skills` replaces the configured ones (tests); a settings change still rebuilds from the config. */
  constructor(config: Config, skills?: Skills) {
    this.config = config;
    this.baseEnv = config.env;
    this.skills = this.adopt(skills ?? this.build(config));
  }

  /** Mimo's sessions, or null in fixture mode. */
  get mimoSessions(): MimoSessions | null {
    return isModelSkills(this.skills) ? this.skills.mimoSessions : null;
  }

  /** A skill's model as `provider:modelId[@thinking]`, or `fixtures`. */
  modelFor(skill: SkillName): string {
    return this.config.models ? describeModel(this.config.models[skill]) : 'fixtures';
  }

  /** Each setting's value as the server sees it (override, else server/.env, else ''). */
  settings(): { key: string; value: string; overridden: boolean }[] {
    const env = { ...this.baseEnv, ...this.overrides };
    return RUNTIME_SETTINGS.map((key) => ({ key, value: env[key]?.trim() ?? '', overridden: key in this.overrides }));
  }

  /** Whether an env key (a provider key) is set. The value never leaves this class. */
  hasKey(name: string): boolean {
    return Boolean(this.baseEnv[name]?.trim());
  }

  /**
   * Sets overrides; null drops one (back to server/.env), '' unsets the setting.
   * Throws ConfigError on a bad value, and then nothing changes. Returns whether the skills were rebuilt.
   */
  apply(changes: Record<string, unknown>): boolean {
    const next = { ...this.overrides };
    for (const [key, value] of Object.entries(changes)) {
      if (!RUNTIME_SETTINGS.includes(key)) throw new ConfigError(`${key} can't be changed from the dashboard.`);
      if (value === null) delete next[key];
      else if (typeof value === 'string') next[key] = value.trim();
      else throw new ConfigError(`${key} must be a string or null.`);
    }
    return this.use(next);
  }

  /** Drops every override: back to server/.env. */
  reset(): boolean {
    return this.use({});
  }

  private use(overrides: Record<string, string>): boolean {
    const config = configFromEnv({ ...this.baseEnv, ...overrides });
    const rebuild = skillsKey(config) !== skillsKey(this.config);
    const skills = rebuild ? this.adopt(this.build(config)) : this.skills;
    this.overrides = overrides;
    this.config = config;
    this.skills = skills;
    if (this.budget) this.budget.limitUsd = config.dailyBudgetUsd;
    return rebuild;
  }

  private build(config: Config): Skills {
    return createSkills(config, {
      ...(this.cache ? { cache: this.cache } : {}),
      ...(this.budget ? { budget: this.budget } : {}),
      onSkillStats: (stats) => this.activity.skillStats(stats),
      onMimoStats: (stats) => this.activity.mimoStats(stats),
      onMimoEvent: (runId, event) => this.activity.mimoRunEvent(runId, event),
    });
  }

  /** Keeps the model-backed skills' cache and budget for the next build. */
  private adopt(skills: Skills): Skills {
    if (isModelSkills(skills)) {
      this.cache = skills.cache;
      this.budget = skills.budget;
    }
    return skills;
  }
}
