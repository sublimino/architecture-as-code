// The currency vocabulary, and the one place a new currency gets added.
//
// Scope note: this file owns the SET of currencies and the per-user default.
// It deliberately owns no arithmetic — conversion lives in convert.ts behind
// the rate table in rates.ts, because the rate table is checked in with an
// effective date and the figures it produces have to be defensible in a
// regulatory review. Anything that multiplies a number by a rate belongs
// there, not here.

/**
 * ISO 4217 alphabetic code — three uppercase letters.
 *
 * Kept as a closed union rather than a bare `string` because `Intl` does NOT
 * validate: `new Intl.NumberFormat('en-GB', {currency: 'ZZZ'}).format(1)`
 * returns the string "ZZZ 1.00" instead of throwing. A typo would therefore
 * render as a plausible-looking money figure in a currency that does not
 * exist. The union plus `isCurrencyCode` is the only thing standing between a
 * bad code and a number on an executive's screen.
 */
export type CurrencyCode =
  | 'AED' | 'AUD' | 'CAD' | 'CHF' | 'DKK' | 'EUR' | 'GBP' | 'HKD'
  | 'INR' | 'JPY' | 'NOK' | 'SEK' | 'SGD' | 'USD' | 'ZAR'

/**
 * Selection order in the Settings dropdown.
 *
 * The four the product actually reports in lead; the rest follow alphabetically.
 * This list must stay a subset of the pairs matrix in risk/fx/rates.json — a
 * currency offered here with no rate renders every figure as Unavailable, which
 * is honest but useless. ratesTable.staleness.test.ts asserts the containment.
 */
export const SUPPORTED_CURRENCIES: readonly CurrencyCode[] = [
  'USD', 'GBP', 'EUR', 'JPY',
  'AED', 'AUD', 'CAD', 'CHF', 'DKK', 'HKD', 'INR', 'NOK', 'SEK', 'SGD', 'ZAR',
]

export const CURRENCY_LABELS: Record<CurrencyCode, string> = {
  AED: 'UAE Dirham',
  AUD: 'Australian Dollar',
  CAD: 'Canadian Dollar',
  CHF: 'Swiss Franc',
  DKK: 'Danish Krone',
  EUR: 'Euro',
  GBP: 'Pound Sterling',
  HKD: 'Hong Kong Dollar',
  INR: 'Indian Rupee',
  JPY: 'Japanese Yen',
  NOK: 'Norwegian Krone',
  SEK: 'Swedish Krona',
  SGD: 'Singapore Dollar',
  USD: 'US Dollar',
  ZAR: 'South African Rand',
}

/**
 * How many decimal places this currency's minor unit has.
 *
 * Read from `Intl` rather than a hand-kept table: it already encodes that JPY
 * has NO minor unit, and rendering a yen figure as ¥196203.00 prints a quantity
 * of money that cannot exist. The conformance vectors in risk/fx/testvectors.json
 * carry `minor_units` per case and this function is checked against all of them.
 */
export function minorUnits(currency: CurrencyCode): number {
  // `maximumFractionDigits` is optional in the DOM typings but is always
  // populated for style:'currency'. Two is the ISO 4217 default for the vast
  // majority of codes, so it is the honest fallback if a runtime omits it.
  return new Intl.NumberFormat('en', { style: 'currency', currency })
    .resolvedOptions()
    .maximumFractionDigits ?? 2
}

/**
 * What a user sees before they have ever chosen, which is also what a user with
 * no `user_preferences` row at all resolves to — and that is every user until
 * the first time they change something.
 *
 * USD despite the source data being GBP: this is a deliberate product call, and
 * it is the reason conversion is on the critical path from the very first
 * render rather than a later nicety. Migration 020 sets the same value as the
 * `user_preferences.display_currency` DEFAULT, so the database and this
 * constant have to move together.
 */
export const DEFAULT_CURRENCY: CurrencyCode = 'USD'

export function isCurrencyCode(value: unknown): value is CurrencyCode {
  return typeof value === 'string' && (SUPPORTED_CURRENCIES as readonly string[]).includes(value)
}
