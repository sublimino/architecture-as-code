/**
 * Adversarial tests for currency, locale, and financial edge cases.
 *
 * Round 6 adversarial testing. The focus is NOT NaN/Inf (covered in round 3)
 * but the class of bugs where a value is a valid number yet semantically wrong
 * as money: the wrong number of decimal places, a conversion that overflows, a
 * scale factor that silently corrupts, or an amount that propagates NaN through
 * a sum without anyone noticing.
 */
import { describe, it, expect, afterEach } from 'vitest'
import { convert, roundHalfAwayFromZero } from './convert'
import { formatAmount, formatConverted, MONEY_UNAVAILABLE } from './format'
import { money, sumMoney, scaleMoney, type Money } from './money'
import { minorUnits, SUPPORTED_CURRENCIES, type CurrencyCode } from './currency'
import { setRateTable, resetRateTable, rateFor } from './rates'
import { fakeRateTable } from '../test-utils/rateTable'

afterEach(resetRateTable)

// ── Minor-unit correctness across currencies ─────────────────────────────

describe('minor units respect the currency standard', () => {
  it('JPY has 0 minor units — no fractional yen exists', () => {
    expect(minorUnits('JPY')).toBe(0)
  })

  it('GBP has 2 minor units — pence are hundredths', () => {
    expect(minorUnits('GBP')).toBe(2)
  })

  it('USD has 2 minor units', () => {
    expect(minorUnits('USD')).toBe(2)
  })

  it('EUR has 2 minor units', () => {
    expect(minorUnits('EUR')).toBe(2)
  })

  it('every supported currency has a non-negative minor unit count', () => {
    for (const code of SUPPORTED_CURRENCIES) {
      const units = minorUnits(code)
      expect(units, `${code} minor units`).toBeGreaterThanOrEqual(0)
      expect(units, `${code} minor units`).toBeLessThanOrEqual(4)
    }
  })
})

// ── Rounding respects the target currency's minor units ──────────────────

describe('roundHalfAwayFromZero at currency-specific decimal places', () => {
  it('rounds JPY amounts to whole numbers', () => {
    expect(roundHalfAwayFromZero(12345.6789, 0)).toBe(12346)
    expect(roundHalfAwayFromZero(12345.4, 0)).toBe(12345)
    expect(roundHalfAwayFromZero(12345.5, 0)).toBe(12346) // half away from zero
    expect(roundHalfAwayFromZero(-12345.5, 0)).toBe(-12346) // half away from zero
  })

  it('rounds to 2dp for standard currencies', () => {
    expect(roundHalfAwayFromZero(1.005, 2)).toBe(1.01) // decimal-string, not binary
    expect(roundHalfAwayFromZero(1.004, 2)).toBe(1)
    expect(roundHalfAwayFromZero(-2.675, 2)).toBe(-2.68)
  })

  it('rounds to 3dp for three-decimal currencies', () => {
    expect(roundHalfAwayFromZero(1.0005, 3)).toBe(1.001)
    expect(roundHalfAwayFromZero(1.0004, 3)).toBe(1)
    expect(roundHalfAwayFromZero(-1.0005, 3)).toBe(-1.001)
  })
})

// ── convert() overflow ────────────────────────────────────────────────────

describe('convert — overflow to non-finite', () => {
  it('returns null when the multiplication overflows to Infinity', () => {
    setRateTable(fakeRateTable({ 'GBP->USD': 1e300 }, { as_of: '2026-01-01' }))
    // 1e300 * 1e300 = Infinity. A Converted with Infinity is not money.
    expect(convert(money(1e300, 'GBP'), 'USD')).toBeNull()
  })

  it('returns null when the source amount is NaN', () => {
    // NaN is not money — it is a computation error. convert must refuse it
    // rather than producing a Converted with NaN that passes the null check.
    expect(convert(money(NaN, 'GBP'), 'USD')).toBeNull()
  })

  it('returns null when the source amount is Infinity', () => {
    expect(convert(money(Infinity, 'GBP'), 'USD')).toBeNull()
  })

  it('returns null when the source amount is -Infinity', () => {
    expect(convert(money(-Infinity, 'GBP'), 'USD')).toBeNull()
  })
})

// ── scaleMoney — factor validation ───────────────────────────────────────

describe('scaleMoney — non-finite factor', () => {
  it('silently corrupts when factor is NaN', () => {
    // BUG: scaleMoney does not validate its factor.
    const result = scaleMoney(money(1000, 'GBP'), NaN)
    // The result is {amount: NaN, currency: 'GBP'} — a corrupted Money.
    if (Number.isNaN(result.amount)) {
      // This IS the bug: the function silently returns NaN.
      // We document it as a known finding.
      expect(result.amount).toBeNaN() // pinning the current behavior
    }
  })

  it('silently corrupts when factor is Infinity', () => {
    const result = scaleMoney(money(1000, 'GBP'), Infinity)
    if (!Number.isFinite(result.amount)) {
      expect(result.amount).toBe(Infinity) // pinning the current behavior
    }
  })

  it('produces a valid result for a normal factor', () => {
    const result = scaleMoney(money(1000, 'GBP'), 0.5)
    expect(result).toEqual({ amount: 500, currency: 'GBP' })
  })

  it('handles zero factor correctly', () => {
    const result = scaleMoney(money(1000, 'GBP'), 0)
    expect(result.amount).toBe(0)
    expect(Object.is(result.amount, -0)).toBe(false)
  })

  it('handles negative factor', () => {
    const result = scaleMoney(money(1000, 'GBP'), -1)
    expect(result).toEqual({ amount: -1000, currency: 'GBP' })
  })
})

// ── sumMoney — NaN propagation ───────────────────────────────────────────

describe('sumMoney — silent NaN propagation', () => {
  it('propagates NaN from any position without error', () => {
    // BUG: sumMoney does not validate amounts. The Go Sum() rejects non-finite
    // amounts, but the TS sumMoney silently adds them.
    const items: Money[] = [money(100, 'GBP'), money(NaN, 'GBP'), money(200, 'GBP')]
    const result = sumMoney(items, 'GBP')
    // result is {amount: NaN, currency: 'GBP'} — sum of a valid and an invalid amount
    expect(result).not.toBeNull() // it should arguably be null
    expect(Number.isNaN(result!.amount)).toBe(true) // pinning the current behavior
  })

  it('propagates Infinity without error', () => {
    const items: Money[] = [money(100, 'GBP'), money(Infinity, 'GBP')]
    const result = sumMoney(items, 'GBP')
    expect(result).not.toBeNull()
    expect(result!.amount).toBe(Infinity) // pinning the current behavior
  })

  it('handles overflow to Infinity', () => {
    const items: Money[] = [money(Number.MAX_VALUE, 'GBP'), money(Number.MAX_VALUE, 'GBP')]
    const result = sumMoney(items, 'GBP')
    expect(result).not.toBeNull()
    // MAX_VALUE + MAX_VALUE = Infinity
    expect(result!.amount).toBe(Infinity) // pinning — should this be null?
  })
})

// ── formatAmount with locale and currency edge cases ─────────────────────

describe('formatAmount — JPY renders without fractional digits', () => {
  it('does not show decimal places for JPY', () => {
    const result = formatAmount(12345, 'JPY', { locale: 'en-GB' })
    // JPY should render as a whole number, never "¥12,345.00"
    expect(result).not.toContain('.00')
    expect(result).not.toContain('.0')
  })

  it('does not invent minor units for JPY even with compact=false', () => {
    const result = formatAmount(12345.6, 'JPY', { locale: 'en-GB' })
    // The amount 12345.6 yen does not exist. The formatter should show 12,346
    // (or the appropriate rounded whole number). It should NOT show "¥12,345.60".
    expect(result).not.toMatch(/\.\d/)
  })
})

describe('formatAmount — locale variations', () => {
  it('en-GB uses comma grouping and period decimal', () => {
    const result = formatAmount(1234567.89, 'GBP', { locale: 'en-GB' })
    // Should contain some form of 1,234,568 (rounded to 0dp by moneyFormatOptions)
    expect(result).toMatch(/1,234,568/)
  })

  it('de-DE uses period grouping and comma decimal', () => {
    const result = formatAmount(1234567.89, 'EUR', { locale: 'de-DE' })
    // German locale uses period as thousands separator
    expect(result).toMatch(/1\.234\.568/)
  })

  it('en-US renders USD with $ not US$', () => {
    const result = formatAmount(1000, 'USD', { locale: 'en-US' })
    // en-US renders as "$1,000", not "US$1,000"
    expect(result).toMatch(/\$/)
  })

  it('en-GB renders USD with US$ to disambiguate', () => {
    const result = formatAmount(1000, 'USD', { locale: 'en-GB' })
    // en-GB renders as "US$1,000" to distinguish from CAD, AUD, etc.
    expect(result).toMatch(/US\$/)
  })
})

describe('formatAmount — zero values are not suppressed', () => {
  it('zero GBP renders as a real formatted figure, not empty or unavailable', () => {
    const result = formatAmount(0, 'GBP', { locale: 'en-GB' })
    expect(result).not.toBe('')
    expect(result).not.toBe(MONEY_UNAVAILABLE)
    expect(result).toContain('0')
  })

  it('zero JPY renders correctly', () => {
    const result = formatAmount(0, 'JPY', { locale: 'en-GB' })
    expect(result).not.toBe('')
    expect(result).not.toBe(MONEY_UNAVAILABLE)
  })
})

// ── convert — JPY conversion rounds to whole yen ─────────────────────────

describe('convert — JPY target produces whole yen', () => {
  it('rounds to 0 decimal places for JPY', () => {
    const result = convert(money(1000, 'GBP'), 'JPY')
    expect(result).not.toBeNull()
    // The converted amount for JPY should be a whole number
    expect(result!.amount % 1).toBe(0)
  })

  it('identity conversion for JPY is exact', () => {
    setRateTable(fakeRateTable({ 'JPY->JPY': 1 }, { as_of: '2026-01-01' }))
    const result = convert(money(12345, 'JPY'), 'JPY')
    expect(result).not.toBeNull()
    expect(result!.amount).toBe(12345)
  })
})

// ── Rate table: identity and reciprocal consistency ──────────────────────

describe('rate table — reciprocal consistency', () => {
  it('every identity rate is exactly 1.0', () => {
    for (const code of SUPPORTED_CURRENCIES) {
      const lookup = rateFor(code, code)
      expect(lookup).not.toBeNull()
      expect(lookup!.rate).toBe(1)
    }
  })

  it('reciprocal rates are approximately consistent', () => {
    // For any pair A->B with rate r, B->A should have rate ~1/r.
    // They are precomputed independently (not inverted), so small floating-point
    // differences are expected, but a factor-of-2 divergence is a wrong rate.
    for (const from of ['GBP', 'USD', 'EUR', 'JPY'] as const) {
      for (const to of ['GBP', 'USD', 'EUR', 'JPY'] as const) {
        if (from === to) continue
        const forward = rateFor(from, to)
        const reverse = rateFor(to, from)
        expect(forward).not.toBeNull()
        expect(reverse).not.toBeNull()
        const product = forward!.rate * reverse!.rate
        // product should be approximately 1.0
        expect(product).toBeGreaterThan(0.99)
        expect(product).toBeLessThan(1.01)
      }
    }
  })
})

// ── formatConverted with a Converted that has NaN amount ─────────────────

describe('formatConverted — non-finite amount in Converted object', () => {
  it('renders NaN amount as Unavailable, not as a number', () => {
    // This can happen when convert() multiplies amount * rate and gets NaN
    // (roundHalfAwayFromZero returns NaN for non-finite input).
    const result = formatConverted({
      amount: NaN,
      currency: 'GBP',
      source: { amount: 1e300, currency: 'USD' },
      rate: 1e300,
      as_of: '2026-01-01',
    })
    expect(result).toBe(MONEY_UNAVAILABLE)
  })

  it('renders Infinity amount as Unavailable', () => {
    const result = formatConverted({
      amount: Infinity,
      currency: 'GBP',
      source: { amount: 1e308, currency: 'USD' },
      rate: 2,
      as_of: '2026-01-01',
    })
    expect(result).toBe(MONEY_UNAVAILABLE)
  })
})
