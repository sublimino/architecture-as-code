// The wire contract for money, mirrored on the frontend.
//
// These two shapes are agreed with the money-model side and are reproduced here
// verbatim. If the server's shape changes, this file changes with it — do not
// "improve" the field names locally. `as_of` is snake_case because that is what
// the server sends; renaming it to `asOf` on the way in would put a translation
// layer between the audit trail and the screen, which is the last place anyone
// wants a translation layer.

import type { CurrencyCode } from './currency'
import { SOURCE_CURRENCY } from './currency'

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

/**
 * Lift a bare number from the fixtures or the policy engine into a `Money`.
 *
 * Every such number is GBP today (see SOURCE_CURRENCY). This helper is the
 * single seam where that assumption is applied, so a future non-GBP source
 * changes one constant instead of every call site.
 */
export function sourceMoney(amount: number): Money {
  return { amount, currency: SOURCE_CURRENCY }
}

/** Narrow a `Money | Converted` to the figure that should actually be shown. */
export function isConverted(value: Money | Converted): value is Converted {
  return 'source' in value && 'rate' in value && 'as_of' in value
}
