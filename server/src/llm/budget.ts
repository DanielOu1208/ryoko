// The daily cost kill switch (design §6.4): every model response adds its cost
// (pi's usage cost, or the model's prices), plus Exa search costs. Once a day's
// spend reaches DAILY_BUDGET_USD, model work answers 503 budget_exceeded until
// the server's local date changes. The ledger persists next to the cache, so a
// restart doesn't reset the day.

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { ApiError } from '../errors.ts';

interface Ledger {
  day: string;
  spentUsd: number;
}

export interface BudgetOptions {
  limitUsd: number;
  /** JSON ledger file, or null to keep it in memory. */
  file: string | null;
  now?: () => Date;
}

/** The server's own local date. The budget is about our bill, so the server clock is right here. */
function localDay(date: Date): string {
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

export class Budget {
  /** The dashboard (/admin) can change it while the server runs. */
  limitUsd: number;
  private readonly file: string | null;
  private readonly now: () => Date;
  private ledger: Ledger;

  constructor(options: BudgetOptions) {
    this.limitUsd = options.limitUsd;
    this.file = options.file;
    this.now = options.now ?? (() => new Date());
    this.ledger = { day: localDay(this.now()), spentUsd: 0 };
    if (this.file) {
      try {
        const saved = JSON.parse(readFileSync(this.file, 'utf8')) as Partial<Ledger>;
        if (typeof saved.day === 'string' && typeof saved.spentUsd === 'number' && Number.isFinite(saved.spentUsd)) {
          this.ledger = { day: saved.day, spentUsd: saved.spentUsd };
        }
      } catch {
        // no ledger yet, or unreadable: start the day at zero
      }
    }
  }

  private current(): Ledger {
    const today = localDay(this.now());
    if (this.ledger.day !== today) this.ledger = { day: today, spentUsd: 0 };
    return this.ledger;
  }

  get spentTodayUsd(): number {
    return this.current().spentUsd;
  }

  /** Throws 503 budget_exceeded once today's spend has reached the limit. */
  assertAvailable(): void {
    if (this.current().spentUsd < this.limitUsd) return;
    throw new ApiError('budget_exceeded', "Mimo has reached today's limit. Try again tomorrow.", {
      status: 503,
      retryable: false,
    });
  }

  /** Starts today over at zero (the dashboard's "Reset today's spend"). */
  resetToday(): void {
    this.current().spentUsd = 0;
    this.persist();
  }

  add(usd: number): void {
    if (!(usd > 0)) return;
    this.current().spentUsd += usd;
    this.persist();
  }

  private persist(): void {
    if (!this.file) return;
    try {
      mkdirSync(dirname(this.file), { recursive: true });
      const tmp = `${this.file}.tmp`;
      writeFileSync(tmp, JSON.stringify(this.ledger));
      renameSync(tmp, this.file);
    } catch (err) {
      console.error('Budget ledger write failed:', (err as Error).message);
    }
  }
}
