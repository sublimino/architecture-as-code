// The wire contract for money, mirrored on the frontend.
//
// These two shapes are agreed with the money-model side and are reproduced here
// verbatim. If the server's shape changes, this file changes with it — do not
// "improve" the field names locally. `as_of` is snake_case because that is what
// the server sends; renaming it to `asOf` on the way in would put a translation
// layer between the audit trail and the screen, which is the last place anyone
// wants a translation layer.

import type { CurrencyCode } from './currency'

/**
 * An amount in a stated currency. Never a bare number for money, anywhere.
 *
 * The rule exists because the currency used to be welded into the field NAME
 * (`annual_cost_gbp`, `tolerance_gbp`), which meant a value could be renamed
 * into a different currency by a refactor with nothing to catch it.
 */
export interface Money {
  amount: number
  currency: CurrencyCode
}

/**
 * A converted amount that shows its working.
 *
 * `source`, `rate` and `as_of` are not decoration. A converted figure with no
 * stated rate and no stated date is a figure nobody can defend in a review, and
 * the whole reason the rate table is checked in rather than fetched is so that
 * every number on screen can point at the exact row that produced it.
 */
export interface Converted {
  amount: number
  currency: CurrencyCode
  source: Money
  rate: number
  as_of: string
}

/** Construct a `Money`. */
export function money(amount: number, currency: CurrencyCode): Money {
  return { amount, currency }
}

/** Narrow a `Money | Converted` to the figure that should actually be shown. */
export function isConverted(value: Money | Converted): value is Converted {
  return 'source' in value && 'rate' in value && 'as_of' in value
}

/**
 * Add money values that share a currency.
 *
 * Returns null on a mixed-currency list rather than adding the numbers, because
 * the sum of 100 GBP and 100 USD is not 200 of anything. Callers render the
 * null as unavailable, exactly as they do a missing rate. An empty list is 0 in
 * `fallback`, since "no findings" genuinely is zero exposure.
 *
 * Summing happens in the SOURCE currency and the total is converted once — see
 * the header of convert.ts for why the reverse accumulates error.
 */
export function sumMoney(items: readonly Money[], fallback: CurrencyCode): Money | null {
  if (items.length === 0) return { amount: 0, currency: fallback }

  const currency = items[0].currency
  let total = 0
  for (const item of items) {
    if (item.currency !== currency) return null
    total += item.amount
  }
  return { amount: total, currency }
}

/**
 * Multiply a money value by a dimensionless factor.
 *
 * Used for pro-rating a total across frameworks. Deliberately does NOT round:
 * the single rounding happens at conversion, so an intermediate rounding here
 * would be the double-round convert.ts warns about.
 */
export function scaleMoney(m: Money, factor: number): Money {
  return { amount: m.amount * factor, currency: m.currency }
}
