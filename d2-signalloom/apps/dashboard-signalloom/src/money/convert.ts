// Turning a `Money` into a `Converted` for display.
//
// This is the display adapter, not a pricing engine: it applies the rate the
// table handed back and records what it applied. The FAIR maths, the magnitude
// triples and the authoritative rate table all live on the money-model side.
// The one multiplication here exists because the dashboard's risk figures are
// checked-in GBP fixtures with no server in the demo path to hand it a
// server-side `Converted`.

import type { CurrencyCode } from './currency'
import type { Converted, Money } from './money'
import { rateFor, type RateTable } from './rates'

/**
 * Convert `m` into `target`, showing the working.
 *
 * Returns `null` when the rate table cannot answer. There is deliberately no
 * fallback: a caller that receives null must render the figure as unavailable
 * rather than showing the source number in the target currency's clothing.
 */
export function convert(
  m: Money,
  target: CurrencyCode,
  table?: RateTable,
): Converted | null {
  const lookup = rateFor(m.currency, target, table)
  if (lookup === null) return null

  return {
    // Rounded to whole units. Every figure these surfaces show is a risk
    // aggregate in the thousands or millions, where a fractional unit is noise
    // that implies a precision the Monte Carlo behind it does not have.
    amount: Math.round(m.amount * lookup.rate),
    currency: target,
    source: m,
    rate: lookup.rate,
    as_of: lookup.as_of,
  }
}
