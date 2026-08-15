import { describe, it, expect } from 'vitest'
import {
  isCurrencyCode,
  SUPPORTED_CURRENCIES,
  DEFAULT_CURRENCY,
  CURRENCY_LABELS,
  minorUnits,
  type CurrencyCode,
} from './currency'

// ─── isCurrencyCode ──────────────────────────────────────────────────────
//
// The mutation this test was written to catch: removing the `.includes(value)`
// check so `isCurrencyCode` accepts any string. That mutation passed the entire
// vitest suite (150 tests, 0 failures) because nothing called `isCurrencyCode`
// with a bad input and expected `false`. The JSDoc above the function says
// explicitly: "Intl does NOT validate — `new Intl.NumberFormat('en-GB',
// {currency: 'ZZZ'}).format(1)` returns 'ZZZ 1.00' instead of throwing."
// The guard existed and was untested, so the thing it guarded against was
// exactly as reachable as if the guard did not exist.

describe('isCurrencyCode', () => {
  it('accepts every supported currency', () => {
    for (const code of SUPPORTED_CURRENCIES) {
      expect(isCurrencyCode(code)).toBe(true)
    }
  })

  it('rejects an invalid ISO 4217 code', () => {
    expect(isCurrencyCode('ZZZ')).toBe(false)
  })

  it('rejects an empty string', () => {
    expect(isCurrencyCode('')).toBe(false)
  })

  it('rejects a lowercase variant of a valid code', () => {
    expect(isCurrencyCode('usd')).toBe(false)
  })

  it('rejects null', () => {
    expect(isCurrencyCode(null)).toBe(false)
  })

  it('rejects undefined', () => {
    expect(isCurrencyCode(undefined)).toBe(false)
  })

  it('rejects a number', () => {
    expect(isCurrencyCode(840)).toBe(false)
  })
})

// ─── SUPPORTED_CURRENCIES ────────────────────────────────────────────────

describe('SUPPORTED_CURRENCIES', () => {
  it('includes at least the four primary currencies', () => {
    for (const code of ['USD', 'GBP', 'EUR', 'JPY'] as const) {
      expect(SUPPORTED_CURRENCIES).toContain(code)
    }
  })

  it('has no duplicates', () => {
    expect(new Set(SUPPORTED_CURRENCIES).size).toBe(SUPPORTED_CURRENCIES.length)
  })
})

// ─── CURRENCY_LABELS ─────────────────────────────────────────────────────

describe('CURRENCY_LABELS', () => {
  it('has a label for every supported currency', () => {
    for (const code of SUPPORTED_CURRENCIES) {
      expect(CURRENCY_LABELS[code]).toBeTruthy()
    }
  })
})

// ─── DEFAULT_CURRENCY ────────────────────────────────────────────────────

describe('DEFAULT_CURRENCY', () => {
  it('is USD', () => {
    expect(DEFAULT_CURRENCY).toBe('USD')
  })

  it('is in the supported set', () => {
    expect(SUPPORTED_CURRENCIES).toContain(DEFAULT_CURRENCY)
  })
})

// ─── minorUnits ──────────────────────────────────────────────────────────

describe('minorUnits', () => {
  it('returns 0 for JPY (no minor unit)', () => {
    expect(minorUnits('JPY')).toBe(0)
  })

  it('returns 2 for USD', () => {
    expect(minorUnits('USD')).toBe(2)
  })

  it('returns 2 for GBP', () => {
    expect(minorUnits('GBP')).toBe(2)
  })
})
