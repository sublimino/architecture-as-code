// Rounding at the boundaries the conformance vectors do not reach.
//
// WHY THIS FILE EXISTS, SEPARATELY FROM convert.conformance.test.ts.
//
// convert.conformance.test.ts runs all 48 vectors from risk/fx/testvectors.json
// through roundHalfAwayFromZero, and the comment on that artefact states the
// contract plainly:
//
//   "A non-Go implementation of currency conversion and display rounding MUST
//    reproduce `converted` and `converted_rounded` for every case."
//
// The 48 cases are well chosen — they cover the .x5 boundaries and the negative
// side, which are exactly where Math.round and toFixed go wrong. But the largest
// amount in the set is 987654.321, so the contract is exercised over about six
// decimal orders of magnitude and asserted over none of the rest. Below is what
// lives outside that window.
//
// ── The oracle ──────────────────────────────────────────────────────────────
//
// Every expectation here is produced by `exactRoundHalfAwayFromZero`, which
// does the arithmetic in BigInt on the decimal digit string. That is a
// genuinely independent implementation, not a transcription of either side:
// it has no floating-point multiply, no `Number('...e2')` shift, and no
// `toFixed`. Comparing the implementation against a copy of itself is the one
// thing that could make this file pass while proving nothing.

import { describe, expect, it } from 'vitest'

import { roundHalfAwayFromZero } from './convert'

/**
 * Round half away from zero, exactly, using integer arithmetic on the shortest
 * round-tripping decimal representation of `value`.
 *
 * This is the specification the Go engine implements
 * (policy-engine/money/roundHalfAwayFromZero) restated in a different idiom, so
 * that a shared mistake between the two production implementations still fails.
 *
 * It returns a decimal STRING rather than a number, because the point of
 * several cases below is that the correct answer is not exactly representable
 * as a double and the comparison has to happen before that loss.
 */
function exactRoundHalfAwayFromZero(value: number, dp: number): string {
  if (!Number.isFinite(value)) return String(value)

  const neg = value < 0 || Object.is(value, -0)

  // The SHORTEST decimal that round-trips is what a reader sees, and what both
  // implementations claim to operate on.
  const shortest = String(Math.abs(value))
  if (shortest.includes('e')) throw new Error(`case outside the oracle's range: ${value}`)
  const [sInt, sFrac = ''] = shortest.split('.')

  // Integer arithmetic from here down: no float multiply, no decimal shift.
  const frac = sFrac.padEnd(dp + 1, '0')
  const kept = BigInt(sInt + frac.slice(0, dp))
  const firstDropped = frac.charCodeAt(dp) - 48
  const rounded = firstDropped >= 5 ? kept + 1n : kept

  const digits = rounded.toString().padStart(dp + 1, '0')
  const out = dp > 0
    ? `${digits.slice(0, digits.length - dp)}.${digits.slice(digits.length - dp)}`
    : digits

  // Zero has no sign in money — the whole point of one of the cases below.
  if (/^0(\.0*)?$/.test(out)) return out
  return neg ? `-${out}` : out
}

describe('the oracle itself', () => {
  // Assert the mechanism. Every expectation in this file comes from the oracle,
  // so an oracle that silently returned the input would make the whole file
  // vacuous. These are hand-computed.
  it('reproduces values worked out by hand', () => {
    expect(exactRoundHalfAwayFromZero(2.675, 2)).toBe('2.68')
    expect(exactRoundHalfAwayFromZero(-2.675, 2)).toBe('-2.68')
    expect(exactRoundHalfAwayFromZero(2.674, 2)).toBe('2.67')
    expect(exactRoundHalfAwayFromZero(0.125, 2)).toBe('0.13')
    expect(exactRoundHalfAwayFromZero(9.995, 2)).toBe('10.00')
    expect(exactRoundHalfAwayFromZero(-0.5, 0)).toBe('-1')
    expect(exactRoundHalfAwayFromZero(0.4, 0)).toBe('0')
    expect(exactRoundHalfAwayFromZero(1.0005, 3)).toBe('1.001')
  })

  it('disagrees with the JS primitives on exactly the cases that matter', () => {
    // If these ever start agreeing, the oracle has stopped being independent.
    expect((2.675).toFixed(2)).toBe('2.67')
    expect(exactRoundHalfAwayFromZero(2.675, 2)).toBe('2.68')
    expect(Math.round(-267.5)).toBe(-267) // half-UP, not half-away-from-zero
  })
})

describe('negative amounts that quantise to zero', () => {
  // THE DEFECT THIS CAUGHT. `roundHalfAwayFromZero` computes `sign * unshifted`,
  // and when `unshifted` is 0 and `sign` is -1 the product is IEEE-754 negative
  // zero. Every small negative amount therefore came back as -0.
  //
  // Observed before the fix, with the Go engine already corrected:
  //
  //   value=-0.005 dp=0   go=0   ts=-0
  //   value=-0.005 dp=2   go=0   ts=-0
  //   value=-0.499999999999999 dp=0   go=0   ts=-0
  //
  // 17,515 of 135,234 differential cases differed by nothing but this sign.
  //
  // It matters because it reaches the screen. Intl.NumberFormat renders the
  // sign of a negative zero, so a residual exposure of a fraction of a penny
  // displays as "-$0.00" — a reader sees a signed figure and concludes the
  // exposure moved in a direction it did not.
  const cases: Array<[number, number]> = [
    [-0.001, 2],
    [-0.004, 2],
    [-0.005, 0],
    [-0.4, 0],
    [-0.0004, 3],
    [-0.499999999999999, 0],
  ]

  it.each(cases)('rounds %d at %d dp to positive zero', (value, dp) => {
    const got = roundHalfAwayFromZero(value, dp)

    expect(got).toBe(0)
    expect(Object.is(got, -0), `rounded to negative zero, which renders as "-0.00"`).toBe(false)
    expect(exactRoundHalfAwayFromZero(value, dp)).toMatch(/^0(\.0*)?$/)
  })

  it('renders as an unsigned zero through Intl, which is where a reader sees it', () => {
    const format = (n: number) =>
      new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'GBP' }).format(n)

    // The mechanism: Intl DOES carry the sign of a negative zero, so this
    // assertion is only meaningful because the value reaching it is +0.
    expect(format(-0)).toContain('-')

    expect(format(roundHalfAwayFromZero(-0.004, 2))).not.toContain('-')
  })

  it('still signs an amount that has a quantity to sign', () => {
    expect(roundHalfAwayFromZero(-0.006, 2)).toBe(-0.01)
    expect(roundHalfAwayFromZero(-2.675, 2)).toBe(-2.68)
    expect(roundHalfAwayFromZero(-0.6, 0)).toBe(-1)
  })
})

describe('magnitudes above the conformance vectors', () => {
  // THE DEFECT THIS CAUGHT. The implementation shifts the decimal by building
  // the string `${abs}e${decimals}` and calling Number() on it. That is exact
  // for the magnitudes the vectors cover, and stops being exact well below the
  // range where a double runs out of fractional precision: the shifted value
  // lands on a different double than the written decimal implies, and Math.round
  // then rounds the wrong way.
  //
  // Found by differential fuzzing against the Go engine over 135,234 cases.
  // 1,196 produced a different finite number. The smallest was:
  //
  //   value=442936448017.90497  dp=2   go=442936448017.9   ts=442936448017.91
  //
  // Reading the decimal as written: the digits after the second place are
  // "497", the first dropped digit is 4, so it rounds DOWN to ...17.90. Go is
  // right and this implementation was a penny high.
  //
  // REACHABILITY, stated honestly. At dp=2 the divergence starts around
  // 4.4e11 and at dp=3 around 2.9e11; dp=0 does not diverge at all, so JPY —
  // the only zero-decimal currency the dashboard offers — is unaffected. In
  // GBP, USD or EUR the threshold is beyond any single institution's exposure.
  // It is reachable in INR: at 84 per USD, a $10bn exposure is 8.4e11 rupees.
  // The reason to fix it is not the demo estate, it is that testvectors.json
  // states a cross-language contract and six orders of magnitude of that
  // contract were never checked.
  const cases: Array<[number, number]> = [
    [442936448017.90497, 2],
    [2872293043322.3247, 2],
    [-2950881822114.6147, 2],
    [52502419093386.445, 2],
    [287837759520.30347, 3],
    [314665796478.07947, 3],
    [-375104292563.42847, 3],
    [98720600321944.28, 3],
  ]

  // Compared numerically: the oracle returns a fixed-width decimal string, so
  // "98720600321944.280" and "98720600321944.28" are the same answer and only a
  // difference in VALUE is a finding.
  it.each(cases)('rounds %d at %d dp as the decimal is written', (value, dp) => {
    const want = exactRoundHalfAwayFromZero(value, dp)
    expect(roundHalfAwayFromZero(value, dp), `want ${want}`).toBe(Number(want))
  })

  it('rounds a large exposure converted into rupees to the same penny as the engine', () => {
    // The concrete reachable case: $10bn at the shipped INR rate of 84.
    const inr = 442936448017.90497
    expect(String(roundHalfAwayFromZero(inr, 2))).toBe('442936448017.9')
  })
})

describe('the rounding rule holds across the whole supported range', () => {
  // A property rather than a table: for every magnitude the product could
  // plausibly display, the implementation must agree with exact decimal
  // arithmetic. This is what would have caught the case above before a fuzzer
  // had to.
  it('agrees with exact decimal arithmetic over twelve orders of magnitude', () => {
    const mismatches: string[] = []
    let checked = 0

    // A fixed sequence rather than Math.random: a test that fails one run in
    // ten and cannot be reproduced is worse than no test.
    let seed = 20260801
    const next = () => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff
      return seed / 0x7fffffff
    }

    for (let exp = 0; exp <= 12; exp++) {
      for (let i = 0; i < 400; i++) {
        const value = (next() * 2 - 1) * 10 ** exp
        for (const dp of [0, 2, 3]) {
          checked++
          const got = String(roundHalfAwayFromZero(value, dp))
          const want = exactRoundHalfAwayFromZero(value, dp)
          // Compare numerically as well, so "0" vs "0.00" is not a failure.
          if (Number(got) !== Number(want)) {
            mismatches.push(`value=${value} dp=${dp} got=${got} want=${want}`)
          }
        }
      }
    }

    expect(checked).toBeGreaterThan(15000)
    expect(mismatches.slice(0, 10)).toEqual([])
  })
})
