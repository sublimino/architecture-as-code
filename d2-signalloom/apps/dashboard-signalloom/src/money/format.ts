// Rendering money as text. `Intl` does the work; this file decides the options.
//
// The old implementation was `'£' + n.toLocaleString('en-GB')`, repeated in
// four files. That hardcodes the symbol, hardcodes its placement before the
// number, and hardcodes two decimal places' worth of assumptions about what a
// currency even is. None of those survive contact with a second currency:
// de-DE puts the symbol last (`1.234.568 €`), JPY has no minor unit at all, and
// en-GB renders US dollars as `US$` rather than `$` precisely so a reader
// cannot confuse them with Canadian or Australian dollars.
//
// So: no symbol table, no placement logic, no `toFixed`. `Intl.NumberFormat`
// already encodes every one of those rules per locale × currency, and it ships
// in the platform — this file adds no dependency.

import type { CurrencyCode } from './currency'
import type { Converted, Money } from './money'

/**
 * What the user sees where a figure could not be converted.
 *
 * Deliberately not a number and not a dash. A dash reads as zero at a glance,
 * and zero exposure is a claim rather than an absence.
 */
export const MONEY_UNAVAILABLE = 'Unavailable'

/** Fallback locale when the browser will not say. */
export const FALLBACK_LOCALE = 'en-GB'

/**
 * Above this, figures abbreviate (`US$2.5M`). Below it they group in full
 * (`US$847,000`).
 *
 * The threshold is not new — it reproduces the behaviour FleetRiskGauge already
 * had, so switching that component onto `Intl` changes the currency and nothing
 * else. A gauge that silently restyled every figure under a million at the same
 * time as changing currency would make any visual regression impossible to
 * attribute.
 */
export const COMPACT_THRESHOLD = 1_000_000

export interface FormatOptions {
  /** Overrides the resolved browser locale. Tests pin this for determinism. */
  locale?: string
  /** Abbreviate values at or above `compactThreshold`. */
  compact?: boolean
  /**
   * Where abbreviation starts. Defaults to COMPACT_THRESHOLD.
   *
   * Chart axis ticks pass 0 so every tick abbreviates: an axis of
   * `US$126,580`-width labels overlaps at any sane chart size, and unlike a
   * headline figure a tick is read for magnitude rather than for its value.
   */
  compactThreshold?: number
}

/**
 * The locale used for grouping separators and symbol placement.
 *
 * Keyed off the browser's `navigator.language`, falling back to `en-GB`. The
 * fallback is en-GB rather than en-US because this product's users and every
 * existing date format in the dashboard are British — `toLocaleString('en-GB')`
 * appears in a dozen files.
 *
 * Note the division of labour: the LOCALE decides grouping and placement, the
 * CURRENCY decides symbol and how many decimal places exist. They are separate
 * inputs, which is why a UK user seeing US dollars correctly gets `US$1,266`
 * and not `$1,266`.
 */
export function resolveLocale(): string {
  try {
    return navigator.language || FALLBACK_LOCALE
  } catch {
    // No navigator (SSR, some test runners) — deterministic fallback.
    return FALLBACK_LOCALE
  }
}

function formatterFor(currency: CurrencyCode, locale: string, compact: boolean): Intl.NumberFormat {
  if (compact) {
    return new Intl.NumberFormat(locale, {
      style: 'currency',
      currency,
      notation: 'compact',
      maximumFractionDigits: 1,
    })
  }
  return new Intl.NumberFormat(locale, {
    style: 'currency',
    currency,
    // Whole units only. Every figure on these surfaces is a risk aggregate
    // where showing cents implies a precision the simulation does not have.
    // Both bounds are set explicitly: leaving minimumFractionDigits to the
    // currency default (2 for USD) while capping the maximum at 0 is a
    // RangeError waiting on a stricter ICU build than the one we run today.
    minimumFractionDigits: 0,
    maximumFractionDigits: 0,
  })
}

/** Format a plain amount in a stated currency. */
export function formatAmount(
  amount: number,
  currency: CurrencyCode,
  options: FormatOptions = {},
): string {
  const locale = options.locale ?? resolveLocale()
  const threshold = options.compactThreshold ?? COMPACT_THRESHOLD
  const compact = (options.compact ?? false) && Math.abs(amount) >= threshold
  return formatterFor(currency, locale, compact).format(amount)
}

/** Format a `Money` in its own currency — no conversion implied. */
export function formatMoney(m: Money, options: FormatOptions = {}): string {
  return formatAmount(m.amount, m.currency, options)
}

/**
 * Format a converted figure, or `MONEY_UNAVAILABLE` when conversion failed.
 *
 * Accepting `null` is the point of the signature: it makes "there is no rate"
 * a case the caller has to pass through this function rather than something a
 * caller can forget, and there is no path through here that renders the source
 * amount labelled as the target currency.
 */
export function formatConverted(c: Converted | null, options: FormatOptions = {}): string {
  if (c === null) return MONEY_UNAVAILABLE
  return formatAmount(c.amount, c.currency, options)
}

/**
 * The provenance line shown beside a converted figure.
 *
 * Returns null when nothing was actually converted (source currency equals
 * display currency), because "converted from GBP at 1.0" is noise that trains
 * readers to ignore the line that matters.
 */
export function formatConversionNote(c: Converted | null): string | null {
  if (c === null) return null
  if (c.source.currency === c.currency) return null
  return `Converted from ${c.source.currency} at ${c.rate} · rates of ${c.as_of}`
}

/** Short provenance suffix for dense surfaces (table cells, gauge subtitles). */
export function formatAsOfNote(c: Converted | null): string | null {
  if (c === null) return null
  if (c.source.currency === c.currency) return null
  return `at ${c.as_of} rates`
}
