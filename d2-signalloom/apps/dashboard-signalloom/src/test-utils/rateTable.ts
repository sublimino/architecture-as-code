// Builds a RateTable for tests without restating the pairs matrix by hand.
//
// The real table carries 225 precomputed ordered pairs; a test that wants "GBP
// converts to USD at 1.2658 and nothing else exists" should say that, not
// hand-assemble a nested object. Keeping the construction here also means a
// change to the RateTable shape breaks in one place rather than in nine.

import type { RateTable } from '../money/rates'

export interface FakeRateOptions {
  as_of?: string
  base?: string
}

/**
 * A table whose only conversions are the ones named.
 *
 * `pairs` is given as "FROM->TO": rate. Identity pairs are NOT added
 * automatically — a test that wants GBP→GBP to work must say so, because
 * silently supplying identities would hide exactly the missing-rate case these
 * tests exist to exercise.
 */
export function fakeRateTable(
  pairs: Record<string, number>,
  options: FakeRateOptions = {},
): RateTable {
  const matrix: Record<string, Record<string, number>> = {}
  for (const [pair, rate] of Object.entries(pairs)) {
    const [from, to] = pair.split('->')
    matrix[from] = matrix[from] ?? {}
    matrix[from][to] = rate
  }
  return {
    as_of: options.as_of ?? '2026-08-01',
    base: options.base ?? 'USD',
    rates: {},
    pairs: matrix,
  }
}
