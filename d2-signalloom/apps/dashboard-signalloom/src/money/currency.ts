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
export type CurrencyCode = 'USD' | 'GBP' | 'EUR'

/** Selection order in the Settings dropdown. */
export const SUPPORTED_CURRENCIES: readonly CurrencyCode[] = ['USD', 'GBP', 'EUR']

export const CURRENCY_LABELS: Record<CurrencyCode, string> = {
  USD: 'US Dollar',
  GBP: 'Pound Sterling',
  EUR: 'Euro',
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

/**
 * The currency the checked-in risk figures are natively denominated in.
 *
 * Every `ale` / `var95` / `tvar` / `carriedGbp` number in the fixtures and in
 * the policy-engine output is GBP. Naming it once here means a money value that
 * arrives as a bare `number` can be lifted into a `Money` without each call
 * site restating the assumption — and when the source data stops being GBP,
 * this constant is the thing that fails loudly rather than a dozen literals.
 */
export const SOURCE_CURRENCY: CurrencyCode = 'GBP'

export function isCurrencyCode(value: unknown): value is CurrencyCode {
  return typeof value === 'string' && (SUPPORTED_CURRENCIES as readonly string[]).includes(value)
}
