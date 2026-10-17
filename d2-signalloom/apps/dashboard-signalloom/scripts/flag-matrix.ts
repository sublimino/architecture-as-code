/**
 * Pairwise flag-matrix generator.
 *
 * 23 boolean flags have 2^23 (~8.4M) combinations; no suite renders those. But a
 * defect that depends on flags usually depends on one or two of them, so a set
 * of rows in which every PAIR of flags takes all four value combinations
 * (on/on, on/off, off/on, off/off) at least once catches the interactions that
 * matter. For the 23-flag registry that is 8 rows.
 *
 * Construction (a binary covering array of strength 2): with N rows, row 0 is
 * all off, and each flag gets a distinct column whose other N-1 entries have
 * exactly w = ceil(N/2) ones. For any two flags:
 *   off/off  row 0;
 *   on/off and off/on  the columns are distinct with equal weight, so each has
 *            a one where the other has a zero;
 *   on/on    two w-subsets of N-1 rows must intersect, since 2w >= N > N-1.
 * N is the smallest row count with C(N-1, w) >= the number of flags. Columns are
 * taken in lexicographic order, so the output is deterministic and a failing
 * row can be named by index.
 *
 *   bun scripts/flag-matrix.ts           one row per line, enabled flags listed
 *   bun scripts/flag-matrix.ts --json    rows as a JSON array of flag maps
 *
 * Design: docs/signalloom/feature-flag-account-types.md ("How we test flag
 * configurations").
 */
import { DEFAULT_SYSTEM_FLAGS } from '../src/types/features'

export type FlagRow = Record<string, boolean>

function binomial(n: number, k: number): number {
  if (k < 0 || k > n) return 0
  let r = 1
  for (let i = 1; i <= k; i++) r = (r * (n - k + i)) / i
  return Math.round(r)
}

/** The first `count` k-subsets of {0..n-1}, in lexicographic order. */
function subsets(n: number, k: number, count: number): number[][] {
  const out: number[][] = []
  const current: number[] = []
  const walk = (start: number): void => {
    if (out.length === count) return
    if (current.length === k) {
      out.push([...current])
      return
    }
    for (let i = start; i < n; i++) {
      current.push(i)
      walk(i + 1)
      current.pop()
    }
  }
  walk(0)
  return out
}

/** Rows covering every value pair of every two flags in `keys`. */
export function pairwiseRows(keys: string[]): FlagRow[] {
  if (keys.length === 0) return []
  let rows = 2
  while (binomial(rows - 1, Math.ceil(rows / 2)) < keys.length) rows++
  const weight = Math.ceil(rows / 2)
  const columns = subsets(rows - 1, weight, keys.length)
  return Array.from({ length: rows }, (_, r) => {
    const row: FlagRow = {}
    keys.forEach((key, c) => {
      row[key] = r > 0 && columns[c]!.includes(r - 1)
    })
    return row
  })
}

/** The flag-value pairs the rows leave uncovered, as `a=on|b=off` strings. */
export function uncoveredPairs(keys: string[], rows: FlagRow[]): string[] {
  const missing: string[] = []
  const word = (v: boolean) => (v ? 'on' : 'off')
  for (let i = 0; i < keys.length; i++)
    for (let j = i + 1; j < keys.length; j++)
      for (const a of [false, true])
        for (const b of [false, true])
          if (!rows.some((row) => row[keys[i]!] === a && row[keys[j]!] === b))
            missing.push(`${keys[i]}=${word(a)}|${keys[j]}=${word(b)}`)
  return missing
}

/** Pairwise rows over the full flag registry. */
export function registryRows(): FlagRow[] {
  return pairwiseRows(Object.keys(DEFAULT_SYSTEM_FLAGS))
}

if (import.meta.main) {
  const rows = registryRows()
  if (process.argv.includes('--json')) {
    console.log(JSON.stringify(rows, null, 2))
  } else {
    rows.forEach((row, i) => {
      const on = Object.keys(row).filter((k) => row[k])
      console.log(`row ${i}: ${on.length} on: ${on.join(' ') || '(none)'}`)
    })
  }
}
