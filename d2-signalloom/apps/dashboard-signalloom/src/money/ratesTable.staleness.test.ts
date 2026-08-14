// Guards the generated rate table against the canonical artefact.
//
// risk/fx/rates.json is produced by `riskctl fx` and is the single source of
// truth for FX in this repo. src/money/ratesTable.generated.ts is a committed
// copy for the browser build. A copy that drifts is worse than no copy: the
// dashboard would price a figure differently from the engine that produced it,
// with no error anywhere and nothing on screen to notice.
//
// The Go side has a matching test that fails when rates.json is stale against
// rates.yaml. This is the third link in the same chain: yaml -> json -> ts.
//
// NOTE ON SKIPPING: risk/fx/ lands with the money-model branch. Until those
// branches merge, the canonical file is absent from this worktree and the
// comparison cannot run — so it is skipped rather than quietly passing. It
// activates the moment the two branches are together, which is when a drift
// could first happen.

import { describe, it, expect } from 'vitest'
import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { GENERATED_RATE_TABLE } from './ratesTable.generated'
import { DEFAULT_RATE_TABLE, rateFor, supportedCurrencies } from './rates'
import { SUPPORTED_CURRENCIES } from './currency'

const CANONICAL = resolve(__dirname, '../../../../../risk/fx/rates.json')
const CANONICAL_VECTORS = resolve(__dirname, '../../../../../risk/fx/testvectors.json')
const canonicalPresent = existsSync(CANONICAL)
const vectorsPresent = existsSync(CANONICAL_VECTORS)

describe('the generated rate table matches the canonical artefact', () => {
  it.skipIf(!canonicalPresent)(
    'is byte-equivalent to risk/fx/rates.json — run bun run scripts/generate-rates.ts',
    () => {
      const canonical = JSON.parse(readFileSync(CANONICAL, 'utf8'))
      expect(GENERATED_RATE_TABLE.as_of).toBe(canonical.as_of)
      expect(GENERATED_RATE_TABLE.base).toBe(canonical.base)
      expect(GENERATED_RATE_TABLE.rates).toEqual(canonical.rates)
      expect(GENERATED_RATE_TABLE.pairs).toEqual(canonical.pairs)
    },
  )

  it.runIf(!canonicalPresent)(
    'reports that the canonical file is not in this worktree yet',
    () => {
      // Deliberately not silent. A skipped comparison should be visible in the
      // run, not something a reader has to infer from an absence.
      expect(canonicalPresent).toBe(false)
    },
  )

  it.skipIf(!vectorsPresent)(
    'vendors risk/fx/testvectors.json unchanged — conformance must test the real cases',
    () => {
      // The vectors are vendored into __fixtures__ so the dashboard suite runs
      // standalone. A vendored copy that drifts is worse than none:
      // convert.conformance.test.ts would go green against cases the engine no
      // longer produces, which reads as agreement and is not.
      const canonical = JSON.parse(readFileSync(CANONICAL_VECTORS, 'utf8'))
      const vendored = JSON.parse(
        readFileSync(resolve(__dirname, '__fixtures__/fxTestVectors.json'), 'utf8'),
      )
      expect(vendored.as_of).toBe(canonical.as_of)
      expect(vendored.cases).toEqual(canonical.cases)
    },
  )
})

describe('the generated table is internally coherent', () => {
  it('is the table the app actually uses', () => {
    expect(DEFAULT_RATE_TABLE).toBe(GENERATED_RATE_TABLE)
  })

  it('carries an effective date, because a rate without one cannot be defended', () => {
    expect(GENERATED_RATE_TABLE.as_of).toMatch(/^\d{4}-\d{2}-\d{2}$/)
  })

  it('precomputes every ordered pair — a gap would render as Unavailable', () => {
    const currencies = supportedCurrencies()
    const missing: string[] = []
    for (const from of currencies) {
      for (const to of currencies) {
        if (rateFor(from as never, to as never) === null) missing.push(`${from}->${to}`)
      }
    }
    expect(missing).toEqual([])
    expect(currencies.length ** 2).toBe(
      Object.values(GENERATED_RATE_TABLE.pairs).reduce((n, row) => n + Object.keys(row).length, 0),
    )
  })

  it('offers no currency in Settings that the table cannot convert to', () => {
    // A currency in the dropdown with no rate renders every figure as
    // Unavailable — honest, but a dead end the user cannot get out of except
    // by changing it back.
    const convertible = new Set(supportedCurrencies())
    const orphans = SUPPORTED_CURRENCIES.filter((c) => !convertible.has(c))
    expect(orphans).toEqual([])
  })

  it('is exactly 1 on the diagonal, so an unconverted figure cannot move', () => {
    for (const c of supportedCurrencies()) {
      expect(GENERATED_RATE_TABLE.pairs[c][c]).toBe(1)
    }
  })
})
