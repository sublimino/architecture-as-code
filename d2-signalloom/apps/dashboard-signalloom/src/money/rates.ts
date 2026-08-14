// The FX rate table: checked in, dated, and deliberately offline.
//
// No network call. Andy's call, and the reason is auditability rather than
// latency: a figure converted at a rate nobody recorded cannot be reproduced
// six months later when a regulator asks how the number on slide 12 was
// arrived at. A checked-in table with an effective date can be diffed, blamed
// and re-run.
//
// ── Boundary ────────────────────────────────────────────────────────────────
// This module is the seam between the dashboard and the money-model side, which
// owns the authoritative table. It exposes ONE function, `rateFor`, and that
// function performs a table LOOKUP — it does not compute cross-rates and it
// does not fall back. Cross-rate arithmetic belongs to the model side; doing it
// here would put a second, quietly divergent implementation of the same maths
// in the codebase, which is the exact defect the FAIR engines had before they
// were converged.
//
// `setRateTable` exists so tests and a future real table can be injected
// without this file's default being reachable from either. Per the project's
// testability rule, every external dependency is overridable.

import type { CurrencyCode } from './currency'

export interface RateTable {
  /** Effective date of every rate in the table, ISO 8601 (YYYY-MM-DD). */
  as_of: string
  /** The currency every rate is quoted against. */
  base: CurrencyCode
  /** base → quote multipliers. `rates[base]` is 1 by definition. */
  rates: Partial<Record<CurrencyCode, number>>
}

export interface RateLookup {
  rate: number
  as_of: string
}

/**
 * Placeholder table pending the money-model side's authoritative artefact.
 *
 * INTERIM. These are plausible mid-2026 rates, not sourced figures, and they
 * are flagged as such rather than left to look official. When the model side
 * lands its checked-in table, this constant is replaced by a read of that file
 * and nothing else in the dashboard changes — that is the point of the seam.
 */
export const DEFAULT_RATE_TABLE: RateTable = {
  as_of: '2026-08-01',
  base: 'GBP',
  rates: {
    GBP: 1,
    USD: 1.2658,
    EUR: 1.1735,
  },
}

let activeTable: RateTable = DEFAULT_RATE_TABLE

/** Install a rate table. Used by tests and by the real artefact at startup. */
export function setRateTable(table: RateTable): void {
  activeTable = table
}

/** Restore the checked-in default. Tests call this in afterEach. */
export function resetRateTable(): void {
  activeTable = DEFAULT_RATE_TABLE
}

export function getRateTable(): RateTable {
  return activeTable
}

/**
 * Look up the rate to convert `from` into `to`.
 *
 * Returns `null` — never 1, never an approximation — when the table cannot
 * answer. A rate of 1 would silently render a GBP figure wearing a dollar sign,
 * which is the failure that puts a wrong number in front of an executive with
 * nothing on screen to notice it. Callers are expected to render "unavailable"
 * on null; `convert()` propagates it and the formatter refuses to invent one.
 *
 * Only conversions FROM the table's base are answered. A cross-rate (say
 * USD→EUR) needs arithmetic this module has deliberately not taken on, so it
 * returns null rather than guessing.
 */
export function rateFor(
  from: CurrencyCode,
  to: CurrencyCode,
  table: RateTable = activeTable,
): RateLookup | null {
  // Identity is not a conversion and needs no rate table to be truthful.
  if (from === to) return { rate: 1, as_of: table.as_of }

  if (from !== table.base) return null

  const rate = table.rates[to]
  if (typeof rate !== 'number' || !Number.isFinite(rate) || rate <= 0) return null

  return { rate, as_of: table.as_of }
}
