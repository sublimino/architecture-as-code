/**
 * Integrity tests over the compliance fixture itself.
 *
 * These assert on NUMBERS, never on formatted strings. jsdom reports the en-US
 * locale regardless of what the app configures, so a currency assertion written
 * against a rendered string passes for the wrong reason and keeps passing when
 * the locale wiring breaks.
 *
 * The point of this file is the FAIR coherence check. Every row on the posture
 * page carries four money figures that a reader is invited to treat as risk
 * quantification. Fabricated figures do not announce themselves — a row with
 * VaR95 below ALE is arithmetically impossible under the model but renders
 * exactly as convincingly as a correct one. A property test over every row is
 * the only thing that catches the next hand-authored row that gets it wrong.
 */
import { describe, it, expect } from 'vitest'
import {
  ALL_CHECKS,
  POSTURE_SUMMARY,
  FRAMEWORK_LIST,
  DEMO_CURRENCY,
  buildPostureSummary,
  checksForVersion,
} from './fakeComplianceData'
import type { ComplianceCheck } from '../types/compliance'
import type { CurrencyCode } from '../money/currency'
import { sumMoney } from '../money/money'

const EXPECTED_FRAMEWORKS = [
  'EU AI Act',
  'NIST 800-53',
  'DORA',
  'NIS2',
  'Cyber Resilience Act',
  'FINOS AI Governance Framework',
]

describe('fakeComplianceData — FAIR coherence', () => {
  it('has rows to check (guards against an empty-fixture vacuous pass)', () => {
    expect(ALL_CHECKS.length).toBeGreaterThanOrEqual(60)
  })

  it.each(ALL_CHECKS.map((c) => [`${c.framework} ${c.control}`, c] as const))(
    'orders ALE < VaR95 < TVaR for %s',
    (_label, c: ComplianceCheck) => {
      expect(c.ale.amount).toBeLessThan(c.var95.amount)
      expect(c.var95.amount).toBeLessThan(c.tvar.amount)
    },
  )

  it.each(ALL_CHECKS.map((c) => [`${c.framework} ${c.control}`, c] as const))(
    'carries exposure only when the control fails for %s',
    (_label, c: ComplianceCheck) => {
      expect(c.carried.amount).toBe(c.passed ? 0 : c.ale.amount)
    },
  )

  it('states every money figure in the document currency', () => {
    for (const c of ALL_CHECKS) {
      expect([c.ale.currency, c.var95.currency, c.tvar.currency, c.carried.currency])
        .toEqual([DEMO_CURRENCY, DEMO_CURRENCY, DEMO_CURRENCY, DEMO_CURRENCY])
    }
  })

  it('keeps every figure finite and positive', () => {
    for (const c of ALL_CHECKS) {
      for (const m of [c.ale, c.var95, c.tvar, c.carried]) {
        expect(Number.isFinite(m.amount)).toBe(true)
        expect(m.amount).toBeGreaterThanOrEqual(0)
      }
      expect(c.ale.amount).toBeGreaterThan(0)
    }
  })

  it('couples the v2.0 policy version to failure, in both directions', () => {
    // The what-if scan derives pass/fail from policyVersion — checksForVersion
    // makes every non-v2.1 row pass at v2.1. A failing row authored at v2.1
    // would therefore stay failing at every version, which is not a policy
    // story anyone can explain.
    for (const c of ALL_CHECKS) {
      expect(c.policyVersion === 'v2.0').toBe(!c.passed)
    }
  })

  it('keeps VaR95 and TVaR multiples in one band across every framework', () => {
    // Not a law of the model, but a calibration invariant: rows authored by
    // hand drift, and a row whose VaR95 is 40x its ALE while its neighbours sit
    // at 4x is either a typo or a different calibration silently mixed in.
    for (const c of ALL_CHECKS) {
      const varMultiple = c.var95.amount / c.ale.amount
      const tailMultiple = c.tvar.amount / c.var95.amount
      expect(varMultiple).toBeGreaterThanOrEqual(4)
      expect(varMultiple).toBeLessThanOrEqual(5)
      expect(tailMultiple).toBeGreaterThanOrEqual(1.5)
      expect(tailMultiple).toBeLessThanOrEqual(1.7)
    }
  })
})

describe('fakeComplianceData — framework coverage', () => {
  it('carries all six frameworks', () => {
    expect([...new Set(ALL_CHECKS.map((c) => c.framework))]).toEqual(EXPECTED_FRAMEWORKS)
  })

  it('summarises every framework present in the checks', () => {
    // The regression this guards: `frameworks` used to be a hand-written list
    // of two, so a framework could be fully present in the rows and entirely
    // absent from the summary and the /compliance/policy/frameworks route.
    expect(POSTURE_SUMMARY.frameworks.map((f) => f.name)).toEqual(EXPECTED_FRAMEWORKS)
    expect(FRAMEWORK_LIST.map((f) => f.name)).toEqual(EXPECTED_FRAMEWORKS)
  })

  it('keeps the two pre-existing framework ids stable', () => {
    const ids = Object.fromEntries(POSTURE_SUMMARY.frameworks.map((f) => [f.name, f.id]))
    expect(ids['EU AI Act']).toBe('eu-ai-act')
    expect(ids['NIST 800-53']).toBe('nist-800-53')
  })

  it('gives every framework a unique slug id', () => {
    const ids = POSTURE_SUMMARY.frameworks.map((f) => f.id)
    expect(new Set(ids).size).toBe(ids.length)
    for (const id of ids) expect(id).toMatch(/^[a-z0-9]+(-[a-z0-9]+)*$/)
  })

  it('namespaces control ids within their framework', () => {
    // groupChecks keys sections on framework + control set. Two frameworks may
    // legitimately reuse a control set name; two rows in the SAME framework may
    // not reuse a control id, or they collapse into one accordion.
    const seen = new Set<string>()
    for (const c of ALL_CHECKS) {
      const key = `${c.framework}::${c.control}`
      expect(seen.has(key)).toBe(false)
      seen.add(key)
    }
  })

  it('makes each framework summary add up to its own rows', () => {
    for (const fw of POSTURE_SUMMARY.frameworks) {
      const rows = ALL_CHECKS.filter((c) => c.framework === fw.name)
      expect(fw.totalControls).toBe(rows.length)
      expect(fw.passedControls).toBe(rows.filter((c) => c.passed).length)
      expect(fw.failedControls).toBe(rows.length - fw.passedControls)
      expect(fw.totalExposure.amount).toBe(
        rows.reduce((sum, c) => sum + c.carried.amount, 0),
      )
    }
  })

  it('makes the document totals equal the sum of the framework totals', () => {
    const perFramework = POSTURE_SUMMARY.frameworks.reduce((s, f) => s + f.totalExposure.amount, 0)
    expect(POSTURE_SUMMARY.totalCarried.amount).toBe(perFramework)
    expect(POSTURE_SUMMARY.totalChecks).toBe(ALL_CHECKS.length)
    expect(POSTURE_SUMMARY.passed + POSTURE_SUMMARY.failed).toBe(ALL_CHECKS.length)
  })

  it('keeps the document ALE < VaR95 < TVaR at the aggregate level too', () => {
    expect(POSTURE_SUMMARY.totalAle.amount).toBeLessThan(POSTURE_SUMMARY.totalVar95.amount)
    expect(POSTURE_SUMMARY.totalVar95.amount).toBeLessThan(POSTURE_SUMMARY.totalTvar.amount)
  })
})

describe('fakeComplianceData — what-if scan by policy version', () => {
  it('passes everything at v1.0 and carries no exposure', () => {
    const checks = checksForVersion('v1.0')
    expect(checks).toHaveLength(ALL_CHECKS.length)
    expect(checks.every((c) => c.passed)).toBe(true)
    expect(checks.every((c) => c.carried.amount === 0)).toBe(true)
  })

  it('carries the authored failures at v2.0', () => {
    const checks = checksForVersion('v2.0')
    const failed = checks.filter((c) => !c.passed)
    expect(failed.length).toBeGreaterThan(0)
    expect(failed.every((c) => c.carried.amount === c.ale.amount)).toBe(true)
  })

  it('clears the v2.0 failures at v2.1 and drops their carried exposure', () => {
    const checks = checksForVersion('v2.1')
    const stillFailing = checks.filter((c) => !c.passed)
    expect(stillFailing).toHaveLength(0)
    expect(sumMoney(checks.map((c) => c.carried), DEMO_CURRENCY)?.amount).toBe(0)
  })

  it('holds the FAIR ordering invariant at every policy version', () => {
    for (const version of ['v1.0', 'v2.0', 'v2.1']) {
      for (const c of checksForVersion(version)) {
        expect(c.ale.amount).toBeLessThan(c.var95.amount)
        expect(c.var95.amount).toBeLessThan(c.tvar.amount)
        expect(c.carried.amount).toBe(c.passed ? 0 : c.ale.amount)
      }
    }
  })
})

// ─── Multi-currency documents ───────────────────────────────────────────────
//
// The header of fakeComplianceData.ts states that multi-currency rendering is
// exercised here, in documents built in other currencies and a deliberately
// mixed one. Until this file existed that sentence was a claim about a file
// that was never written. These are the cases it describes.

function redenominate(checks: ComplianceCheck[], currency: CurrencyCode): ComplianceCheck[] {
  return checks.map((c) => ({
    ...c,
    ale: { ...c.ale, currency },
    var95: { ...c.var95, currency },
    tvar: { ...c.tvar, currency },
    carried: { ...c.carried, currency },
  }))
}

describe('fakeComplianceData — multi-currency documents', () => {
  it.each(['USD', 'EUR', 'JPY'] as const)('reports a whole document in %s', (currency) => {
    const doc = buildPostureSummary(redenominate(ALL_CHECKS, currency))

    // Value assertions, not formatted-string assertions: under jsdom's en-US
    // locale a GBP figure and a USD figure can format to the same glyphs.
    expect(doc.currency).toBe(currency)
    expect(doc.totalCarried.currency).toBe(currency)
    expect(doc.totalCarried.amount).toBe(POSTURE_SUMMARY.totalCarried.amount)
    for (const fw of doc.frameworks) {
      expect(fw.totalExposure.currency).toBe(currency)
    }
  })

  it('refuses to total a deliberately mixed-currency document', () => {
    const mixed = [
      ...redenominate(ALL_CHECKS.slice(0, 5), 'GBP'),
      ...redenominate(ALL_CHECKS.slice(5), 'USD'),
    ]
    // sumMoney returns null on mixed input rather than adding numbers that are
    // not the same kind of thing; the page renders that null as Unavailable.
    expect(sumMoney(mixed.map((c) => c.carried), 'GBP')).toBeNull()
  })

  it('preserves the document currency when a scan carries no exposure at all', () => {
    // An all-passing document has nothing to take a currency from, so the
    // fallback is the only thing keeping the zero denominated.
    const doc = buildPostureSummary(checksForVersion('v1.0'))
    expect(doc.totalCarried.amount).toBe(0)
    expect(doc.totalCarried.currency).toBe(DEMO_CURRENCY)
  })
})
