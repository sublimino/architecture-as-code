/**
 * Absence must not be coloured like a clean posture.
 *
 * Every exposure StatCard in the product read
 * `(m?.amount ?? 0) > 0 ? amber : teal`, so an absent figure took the same
 * green as a measured zero. Colour is the one channel a reader takes in before
 * any text, so that `?? 0` made "not computed" and "computed as zero"
 * indistinguishable at exactly the point where the distinction matters most --
 * and it did so on four surfaces: RiskExposurePage twice, CompliancePolicyPage
 * and AgentPosturePage.
 *
 * Written AFTER mutation-testing the replacement and finding the mutant
 * survived: flipping the absent branch from `--muted` back to `--teal` left
 * the whole suite green at 234 files / 4021 tests. The helper existed, the
 * pages used it, and nothing asserted the one thing it was for.
 */
import { describe, it, expect } from 'vitest'
import { exposureAccent } from './tokens'

describe('exposureAccent distinguishes three states, not two', () => {
  it('colours a positive exposure amber', () => {
    expect(exposureAccent({ amount: 98_700 })).toBe('var(--amber)')
  })

  it('colours a MEASURED zero teal, because a measured zero is a clean posture', () => {
    expect(exposureAccent({ amount: 0 })).toBe('var(--teal)')
  })

  it('colours an absent figure muted, NOT teal', () => {
    // The assertion that matters. `not.toBe(teal)` is stated explicitly
    // alongside the positive one: the defect was never "wrong colour", it was
    // "the same colour as the good news".
    expect(exposureAccent(null)).toBe('var(--muted)')
    expect(exposureAccent(undefined)).toBe('var(--muted)')
    expect(exposureAccent(null)).not.toBe(exposureAccent({ amount: 0 }))
  })

  it('colours a non-finite amount muted rather than scoring NaN as a band', () => {
    // NaN fails every comparison, so `> 0` is false and the old expression
    // returned teal for it too.
    expect(exposureAccent({ amount: Number.NaN })).toBe('var(--muted)')
    expect(exposureAccent({ amount: Number.POSITIVE_INFINITY })).toBe('var(--muted)')
  })

  it('gives absence and zero different colours, which is the whole point', () => {
    const colours = new Set([
      exposureAccent({ amount: 1 }),
      exposureAccent({ amount: 0 }),
      exposureAccent(null),
    ])
    expect(colours.size, 'positive, zero and absent must be three distinct colours').toBe(3)
  })
})
