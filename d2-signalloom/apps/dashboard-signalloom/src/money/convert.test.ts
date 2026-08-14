import { describe, it, expect, afterEach } from 'vitest'
import { convert } from './convert'
import { money } from './money'
import { rateFor, setRateTable, resetRateTable, DEFAULT_RATE_TABLE, supportedCurrencies } from './rates'
import { fakeRateTable } from '../test-utils/rateTable'

afterEach(resetRateTable)

// The arithmetic itself is pinned by convert.conformance.test.ts against the
// risk engine's own 48 vectors. This file covers what those vectors cannot:
// the behaviour when the table CANNOT answer, and the injection seam.

describe('rateFor against the canonical table', () => {
  it('answers every ordered pair the engine precomputed', () => {
    const currencies = supportedCurrencies()
    expect(currencies.length).toBeGreaterThanOrEqual(15)
    for (const from of currencies) {
      for (const to of currencies) {
        expect(rateFor(from as never, to as never)).not.toBeNull()
      }
    }
  })

  it('answers a cross-rate, because the engine precomputed it', () => {
    // An earlier draft refused cross-rates to avoid implementing the division
    // itself. It still does no division — the canonical table ships all 225
    // ordered pairs, so USD->EUR is a lookup like any other.
    expect(rateFor('USD', 'EUR')?.rate).toBe(DEFAULT_RATE_TABLE.pairs.USD.EUR)
  })

  it('is exactly 1 for identity, so figures already in the repo cannot move', () => {
    for (const c of supportedCurrencies()) {
      expect(rateFor(c as never, c as never)?.rate).toBe(1)
    }
  })

  it('carries the table effective date on every lookup', () => {
    expect(rateFor('GBP', 'USD')?.as_of).toBe(DEFAULT_RATE_TABLE.as_of)
  })
})

describe('rateFor when the table cannot answer', () => {
  it('returns null — never 1 — for an absent pair', () => {
    setRateTable(fakeRateTable({ 'GBP->GBP': 1 }))
    expect(rateFor('GBP', 'USD')).toBeNull()
  })

  it('returns null for a currency the table has never heard of', () => {
    setRateTable(fakeRateTable({ 'GBP->USD': 1.2658 }))
    expect(rateFor('JPY', 'USD')).toBeNull()
  })

  it('rejects a nonsensical rate instead of propagating it', () => {
    for (const bad of [0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
      setRateTable(fakeRateTable({ 'GBP->USD': bad }))
      expect(rateFor('GBP', 'USD')).toBeNull()
    }
  })
})

describe('convert', () => {
  it('shows its working: source, rate and as_of all survive', () => {
    const c = convert(money(1000, 'GBP'), 'USD')
    expect(c).toEqual({
      amount: 1265.82,
      currency: 'USD',
      source: { amount: 1000, currency: 'GBP' },
      rate: DEFAULT_RATE_TABLE.pairs.GBP.USD,
      as_of: DEFAULT_RATE_TABLE.as_of,
    })
  })

  it('returns null when no rate exists — it does NOT relabel the source', () => {
    setRateTable(fakeRateTable({ 'GBP->GBP': 1 }))
    expect(convert(money(1000, 'GBP'), 'USD')).toBeNull()
  })

  it('never yields a figure its own provenance cannot explain', () => {
    // The invariant behind the whole contract: a Converted's amount is its
    // source amount times its own stated rate, rounded once to the target's
    // minor units. Nothing here can emit a number that does not follow.
    for (const target of ['USD', 'EUR', 'JPY'] as const) {
      const c = convert(money(3333.33, 'GBP'), target)
      expect(c).not.toBeNull()
      expect(Math.abs(c!.amount - c!.source.amount * c!.rate)).toBeLessThanOrEqual(0.5)
    }
  })

  it('honours an injected table so a live feed drops in without code change', () => {
    setRateTable(fakeRateTable({ 'GBP->USD': 2 }, { as_of: '2027-03-09' }))
    const c = convert(money(500, 'GBP'), 'USD')
    expect(c?.amount).toBe(1000)
    expect(c?.as_of).toBe('2027-03-09')
  })
})
