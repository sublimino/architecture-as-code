import { describe, it, expect, afterEach } from 'vitest'
import { convert } from './convert'
import { money } from './money'
import { rateFor, setRateTable, resetRateTable, DEFAULT_RATE_TABLE } from './rates'

afterEach(resetRateTable)

describe('rateFor', () => {
  it('answers a conversion from the table base', () => {
    expect(rateFor('GBP', 'USD')).toEqual({ rate: 1.2658, as_of: DEFAULT_RATE_TABLE.as_of })
  })

  it('treats identity as rate 1 without needing a table entry', () => {
    expect(rateFor('USD', 'USD')?.rate).toBe(1)
  })

  it('returns null for a cross-rate rather than computing one', () => {
    // USD is not the base. Deriving USD→EUR would be a second, quietly
    // divergent implementation of arithmetic the model side owns.
    expect(rateFor('USD', 'EUR')).toBeNull()
  })

  it('returns null — never 1 — when the target is absent from the table', () => {
    setRateTable({ as_of: '2026-08-01', base: 'GBP', rates: { GBP: 1 } })
    expect(rateFor('GBP', 'USD')).toBeNull()
  })

  it('rejects a nonsensical rate instead of propagating it', () => {
    for (const bad of [0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
      setRateTable({ as_of: '2026-08-01', base: 'GBP', rates: { GBP: 1, USD: bad } })
      expect(rateFor('GBP', 'USD')).toBeNull()
    }
  })
})

describe('convert', () => {
  it('shows its working: source, rate and as_of all survive', () => {
    const c = convert(money(1000, 'GBP'), 'USD')
    expect(c).toEqual({
      amount: 1266,
      currency: 'USD',
      source: { amount: 1000, currency: 'GBP' },
      rate: 1.2658,
      as_of: '2026-08-01',
    })
  })

  it('rounds to whole units', () => {
    expect(convert(money(1000, 'GBP'), 'USD')?.amount).toBe(Math.round(1000 * 1.2658))
  })

  it('is an identity that still records provenance', () => {
    const c = convert(money(4200, 'GBP'), 'GBP')
    expect(c?.amount).toBe(4200)
    expect(c?.rate).toBe(1)
    expect(c?.source.currency).toBe('GBP')
  })

  it('returns null when no rate exists — it does NOT relabel the source', () => {
    const c = convert(money(1000, 'USD'), 'EUR')
    expect(c).toBeNull()
  })

  it('never yields a figure whose currency differs from what produced it', () => {
    // The invariant behind the whole contract: if a Converted exists at all,
    // its amount is its source amount times its own stated rate. Nothing in
    // this module can emit a number that its own provenance does not explain.
    for (const target of ['USD', 'GBP', 'EUR'] as const) {
      const c = convert(money(3333, 'GBP'), target)
      if (c === null) continue
      expect(c.amount).toBe(Math.round(c.source.amount * c.rate))
    }
  })

  it('honours an injected table so a real artefact drops in without code change', () => {
    setRateTable({ as_of: '2027-03-09', base: 'GBP', rates: { GBP: 1, USD: 2 } })
    const c = convert(money(500, 'GBP'), 'USD')
    expect(c?.amount).toBe(1000)
    expect(c?.as_of).toBe('2027-03-09')
  })
})
