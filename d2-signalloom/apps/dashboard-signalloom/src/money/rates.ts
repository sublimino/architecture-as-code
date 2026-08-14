// The FX rate table: checked in, dated, and deliberately offline.
//
// No network call. The reason is auditability rather than latency: a figure
// converted at a rate nobody recorded cannot be reproduced six months later
// when a regulator asks how the number on slide 12 was arrived at. A checked-in
// table with an effective date can be diffed, blamed and re-run.
//
// ── One table, not two ──────────────────────────────────────────────────────
// risk/fx/rates.json is canonical. It is produced by `riskctl fx` from
// risk/fx/rates.yaml and priced with the same code the risk engine uses, and
// this module reads a generated copy of it (ratesTable.generated.ts). The
// dashboard does not author rates. `fair.go` says a second implementation of
// its maths anywhere in the repo is a defect; two rate tables are the same sin
// with worse symptoms — a figure that differs between two views of the same
// product, with no error anywhere.
//
// ── The direction trap ──────────────────────────────────────────────────────
// The table's base is USD and `rates` is units per one USD, so `rates.GBP` is
// 0.79, NOT the 1.2658 a reader expects for GBP→USD. Those are reciprocals and
// getting them backwards is a factor-of-1.6 error on every figure on screen,
// plausible-looking and silent. An earlier draft of this module assumed
// `base: GBP` with `USD: 1.2658` and would have shipped exactly that.
//
// This module therefore never divides. `pairs[from][to]` is precomputed for
// every ordered pair by the engine itself, so `rateFor` is a lookup with no
// arithmetic to get wrong and no second implementation of the division to
// disagree with the first.
//
// `setRateTable` exists so tests and a future feed can be injected without this
// module's default being reachable from either.

import type { CurrencyCode } from './currency'
import { GENERATED_RATE_TABLE } from './ratesTable.generated'

export interface RateTable {
  /** Effective date of every rate in the table, ISO 8601 (YYYY-MM-DD). */
  as_of: string
  /** The currency `rates` is quoted against. Not used for conversion. */
  base: string
  /** base → quote multipliers. Present for provenance; `pairs` does the work. */
  rates: Record<string, number>
  /**
   * `pairs[from][to]` multiplies one unit of `from` into `to`.
   *
   * An absent pair is unsupported and must fail rather than assume 1.0 —
   * that assumption is how a GBP figure ends up wearing a dollar sign.
   */
  pairs: Record<string, Record<string, number>>
}

export interface RateLookup {
  rate: number
  as_of: string
}

/** The canonical table, copied from risk/fx/rates.json at generation time. */
export const DEFAULT_RATE_TABLE: RateTable = GENERATED_RATE_TABLE

let activeTable: RateTable = DEFAULT_RATE_TABLE

/** Install a rate table. Used by tests and by a future live feed. */
export function setRateTable(table: RateTable): void {
  activeTable = table
}

/** Restore the canonical table. Tests call this in afterEach. */
export function resetRateTable(): void {
  activeTable = DEFAULT_RATE_TABLE
}

export function getRateTable(): RateTable {
  return activeTable
}

/**
 * Look up the rate taking one unit of `from` into `to`.
 *
 * Returns `null` — never 1, never an approximation — when the table cannot
 * answer. A rate of 1 would silently render a GBP figure wearing a dollar sign,
 * which is the failure that puts a wrong number in front of an executive with
 * nothing on screen to notice it. `convert()` propagates the null and the
 * formatter refuses to invent a figure from it.
 */
export function rateFor(
  from: CurrencyCode,
  to: CurrencyCode,
  table: RateTable = activeTable,
): RateLookup | null {
  const rate = table.pairs?.[from]?.[to]
  if (typeof rate !== 'number' || !Number.isFinite(rate) || rate <= 0) return null
  return { rate, as_of: table.as_of }
}

/** Every currency the active table can convert between. */
export function supportedCurrencies(table: RateTable = activeTable): string[] {
  return Object.keys(table.pairs ?? {}).sort()
}
