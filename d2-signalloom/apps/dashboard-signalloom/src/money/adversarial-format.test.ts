/**
 * Adversarial tests for money formatting — NaN, Infinity, negative zero, and
 * other values that are technically `number` but semantically meaningless as
 * money. These are the values that slip past TypeScript's type system and
 * show up when an API returns unexpected data.
 *
 * Round 3 adversarial testing.
 */
import { describe, it, expect } from 'vitest'
import {
  formatAmount,
  formatMoney,
  formatConverted,
  formatConversionNote,
  formatAsOfNote,
  moneyFormatOptions,
  MONEY_UNAVAILABLE,
} from './format'
import { roundHalfAwayFromZero } from './convert'
import { sumMoney, money } from './money'
import type { Converted } from './money'

const LOCALE = 'en-GB'

// ── formatAmount with non-finite values ─────────────────────────────────────

describe('formatAmount — non-finite values', () => {
  // BUG: formatAmount passes NaN straight to Intl.NumberFormat.format(), which
  // renders it as a currency-prefixed "NaN" string (e.g. "£NaN"). A financial
  // dashboard should never show "NaN" to a user.
  it('does not render NaN as a currency-prefixed string', () => {
    const result = formatAmount(NaN, 'GBP', { locale: LOCALE })
    // Should be MONEY_UNAVAILABLE or a human-readable fallback, never "NaN"
    expect(result).not.toContain('NaN')
  })

  it('does not render Infinity as a currency-prefixed string', () => {
    const result = formatAmount(Infinity, 'GBP', { locale: LOCALE })
    expect(result).not.toContain('Infinity')
    expect(result).not.toContain('∞')
  })

  it('does not render -Infinity as a currency-prefixed string', () => {
    const result = formatAmount(-Infinity, 'GBP', { locale: LOCALE })
    expect(result).not.toContain('Infinity')
    expect(result).not.toContain('∞')
    // Should return MONEY_UNAVAILABLE
    expect(result).toBe(MONEY_UNAVAILABLE)
  })

  it('formats negative zero as zero (no misleading sign)', () => {
    const result = formatAmount(-0, 'GBP', { locale: LOCALE })
    // Should NOT contain a minus sign — negative zero in money is misleading
    expect(result).not.toMatch(/^-/)
  })
})

// ── formatConverted with null ───────────────────────────────────────────────

describe('formatConverted — null handling', () => {
  it('returns MONEY_UNAVAILABLE for null', () => {
    expect(formatConverted(null)).toBe(MONEY_UNAVAILABLE)
  })

  it('returns MONEY_UNAVAILABLE for null even with options', () => {
    expect(formatConverted(null, { locale: 'de-DE', compact: true })).toBe(MONEY_UNAVAILABLE)
  })
})

// ── formatConversionNote edge cases ─────────────────────────────────────────

describe('formatConversionNote — edge cases', () => {
  it('returns null when source and target currencies are the same', () => {
    const c: Converted = {
      amount: 100,
      currency: 'GBP',
      source: { amount: 100, currency: 'GBP' },
      rate: 1,
      as_of: '2026-08-01',
    }
    expect(formatConversionNote(c)).toBeNull()
  })

  it('returns a note when currencies differ', () => {
    const c: Converted = {
      amount: 126,
      currency: 'USD',
      source: { amount: 100, currency: 'GBP' },
      rate: 1.26,
      as_of: '2026-08-01',
    }
    const note = formatConversionNote(c)
    expect(note).toContain('GBP')
    expect(note).toContain('1.26')
    expect(note).toContain('2026-08-01')
  })
})

// ── roundHalfAwayFromZero edge cases ────────────────────────────────────────

describe('roundHalfAwayFromZero — adversarial inputs', () => {
  it('returns NaN for NaN', () => {
    expect(Number.isNaN(roundHalfAwayFromZero(NaN, 2))).toBe(true)
  })

  it('returns NaN for Infinity', () => {
    expect(Number.isNaN(roundHalfAwayFromZero(Infinity, 2))).toBe(true)
  })

  it('returns NaN for -Infinity', () => {
    expect(Number.isNaN(roundHalfAwayFromZero(-Infinity, 2))).toBe(true)
  })

  it('returns 0 for 0 (not -0)', () => {
    const result = roundHalfAwayFromZero(0, 2)
    expect(result).toBe(0)
    expect(Object.is(result, -0)).toBe(false)
  })

  it('treats negative decimals as 0', () => {
    expect(roundHalfAwayFromZero(1.5, -1)).toBe(2)
  })

  it('handles very large numbers', () => {
    // Should not crash or produce Infinity
    const result = roundHalfAwayFromZero(999999999999.999, 2)
    expect(Number.isFinite(result)).toBe(true)
  })

  it('handles very small positive numbers', () => {
    const result = roundHalfAwayFromZero(0.001, 2)
    expect(result).toBe(0)
  })
})

// ── moneyFormatOptions validation ───────────────────────────────────────────

describe('moneyFormatOptions — contract', () => {
  it('sets explicit minimumFractionDigits for compact mode', () => {
    const opts = moneyFormatOptions('GBP', true)
    expect(opts.minimumFractionDigits).toBe(0)
    expect(opts.maximumFractionDigits).toBe(1)
  })

  it('sets explicit minimumFractionDigits for normal mode', () => {
    const opts = moneyFormatOptions('GBP', false)
    expect(opts.minimumFractionDigits).toBe(0)
    expect(opts.maximumFractionDigits).toBe(0)
  })

  it('uses the right options for JPY (zero minor units)', () => {
    // JPY has no minor unit, so the options should still work
    const opts = moneyFormatOptions('JPY', false)
    expect(opts.style).toBe('currency')
    expect(opts.currency).toBe('JPY')
  })
})

// ── sumMoney adversarial ────────────────────────────────────────────────────

describe('sumMoney — adversarial inputs', () => {
  it('returns 0 for empty list', () => {
    const result = sumMoney([], 'GBP')
    expect(result).toEqual({ amount: 0, currency: 'GBP' })
  })

  it('returns null for mixed currencies', () => {
    const items = [money(100, 'GBP'), money(200, 'USD')]
    expect(sumMoney(items, 'GBP')).toBeNull()
  })

  it('sums single-currency list correctly', () => {
    const items = [money(100, 'GBP'), money(200, 'GBP')]
    expect(sumMoney(items, 'GBP')).toEqual({ amount: 300, currency: 'GBP' })
  })

  it('returns null when any item has a NaN amount', () => {
    const items = [money(100, 'GBP'), money(NaN, 'GBP')]
    const result = sumMoney(items, 'GBP')
    // NaN in a sum must not propagate silently — the Go Sum() rejects non-finite
    // amounts with an error, and the TS sumMoney returns null so the caller
    // renders "Unavailable" rather than a garbage figure.
    expect(result).toBeNull()
  })

  it('handles negative amounts', () => {
    const items = [money(100, 'GBP'), money(-50, 'GBP')]
    expect(sumMoney(items, 'GBP')).toEqual({ amount: 50, currency: 'GBP' })
  })
})

// ── formatAsOfNote ──────────────────────────────────────────────────────────

describe('formatAsOfNote — edge cases', () => {
  it('returns null for null input', () => {
    expect(formatAsOfNote(null)).toBeNull()
  })

  it('returns null when currencies match (no conversion happened)', () => {
    const c: Converted = {
      amount: 100,
      currency: 'GBP',
      source: { amount: 100, currency: 'GBP' },
      rate: 1,
      as_of: '2026-08-01',
    }
    expect(formatAsOfNote(c)).toBeNull()
  })

  it('returns a note when currencies differ', () => {
    const c: Converted = {
      amount: 126,
      currency: 'USD',
      source: { amount: 100, currency: 'GBP' },
      rate: 1.26,
      as_of: '2026-08-01',
    }
    expect(formatAsOfNote(c)).toBe('at 2026-08-01 rates')
  })
})
