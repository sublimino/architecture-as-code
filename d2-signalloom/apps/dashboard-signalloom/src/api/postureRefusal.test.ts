/**
 * The client boundary must not re-fabricate what the server refused.
 *
 * WHY THIS FILE EXISTS, AND WHY ITS ABSENCE MATTERED
 * -------------------------------------------------
 * `normalizePostureSummary` and `normalizeFrameworkSummary` both ended in
 * `: { amount: 0, currency }`. So when GET /compliance/policy/summary and
 * /compliance/policy/frameworks began reporting `null` -- deliberately,
 * because they answer from `agent_compliance_results`, which has no money
 * column (migration 004), and the zeros they used to send were never computed
 * -- the client turned that null straight back into a zero before any page saw
 * the response.
 *
 * Two services and a database-backed route were changed to stop fabricating
 * zeros. One `?? { amount: 0 }` at the edge reinstated every one of them, and
 * a page then rendered "£0 total exposure", which reads as a clean posture.
 *
 * NEITHER NORMALISER HAD A SINGLE TEST. I checked by mutation before writing
 * this: restoring `return { amount: 0, currency }` left the whole suite green
 * at 234 files / 4010 tests. The server-side leg of this build could be undone
 * by one line at the client boundary and nothing anywhere would have noticed.
 * That is the specific hole these tests fill.
 */
import { describe, it, expect } from 'vitest'
import { normalizePostureSummary, normalizeFrameworkSummary } from './client'
import type { FrameworkSummary, PostureSummary } from '../types/compliance'
import { formatMoney, MONEY_UNAVAILABLE } from '../money/format'

// The refusal object the two routes send, every key present.
const NO_RISK_DATA_PLANE = {
  available: false,
  status: 'NO_RISK_DATA_PLANE',
  reason:
    'this route answers from agent_compliance_results, which has no money column, so there is nothing to aggregate',
  unpricedFields: ['totalAle', 'totalVar95', 'totalTvar', 'totalCarried'],
  unmappedChecks: [],
}

/** An unpriced summary exactly as the route serialises one: nulls, not omissions. */
function unpricedSummary(): PostureSummary {
  return {
    totalChecks: 12,
    passed: 8,
    failed: 4,
    currency: 'GBP',
    totalAle: null,
    totalVar95: null,
    totalTvar: null,
    totalCarried: null,
    carried: null,
    totalCarriedGbp: null,
    scanTimestamp: '2026-10-11T00:00:00Z',
    frameworks: [],
    pricing: NO_RISK_DATA_PLANE,
  }
}

function unpricedFramework(): FrameworkSummary {
  return {
    id: 'eu-ai-act',
    name: 'EU AI Act',
    versions: ['v2.1'],
    totalControls: 6,
    passedControls: 4,
    failedControls: 2,
    totalExposure: null,
    exposure: null,
    totalExposureGbp: null,
    pricing: NO_RISK_DATA_PLANE,
  }
}

describe('normalizePostureSummary preserves a refusal', () => {
  it('leaves all four money fields null rather than manufacturing a zero', () => {
    const out = normalizePostureSummary(unpricedSummary())

    // Each named individually on purpose. A loop would let three pass and one
    // fail with the message naming only the loop.
    expect(out.totalAle, 'totalAle').toBeNull()
    expect(out.totalVar95, 'totalVar95').toBeNull()
    expect(out.totalTvar, 'totalTvar').toBeNull()
    expect(out.totalCarried, 'totalCarried').toBeNull()
  })

  it('keeps the legacy bare-number twin in agreement about absence', () => {
    const out = normalizePostureSummary(unpricedSummary())
    // `carried` and `totalCarriedGbp` are the two denominated/legacy twins of
    // totalCarried. If one goes null while another reports 0, a consumer gets
    // to choose which half to believe, and the one it picks is the zero.
    expect(out.carried, 'carried').toBeNull()
    expect(out.totalCarriedGbp, 'totalCarriedGbp').toBeNull()
  })

  it('renders as Unavailable rather than as a currency amount', () => {
    // The end-to-end consequence, stated as the thing a reader sees. This is
    // the assertion that would have caught the original defect from outside:
    // a zero formats to "£0", which is a figure.
    const out = normalizePostureSummary(unpricedSummary())
    expect(formatMoney(out.totalCarried)).toBe(MONEY_UNAVAILABLE)
    expect(formatMoney(out.totalAle)).toBe(MONEY_UNAVAILABLE)
  })

  it('forwards the refusal so a page can say why', () => {
    const out = normalizePostureSummary(unpricedSummary())
    expect(out.pricing?.status).toBe('NO_RISK_DATA_PLANE')
    expect(out.pricing?.reason).toMatch(/no money column/)
  })

  it('still reports the counts, which ARE computed from stored rows', () => {
    // The counterpart that keeps this honest: the route's counts are real and
    // must survive. A normaliser that nulled everything would pass the four
    // tests above and be useless.
    const out = normalizePostureSummary(unpricedSummary())
    expect(out.totalChecks).toBe(12)
    expect(out.passed).toBe(8)
    expect(out.failed).toBe(4)
    expect(out.currency).toBe('GBP')
  })

  it('passes a PRICED figure through untouched, including a measured zero', () => {
    const priced: PostureSummary = {
      ...unpricedSummary(),
      totalAle: { amount: 41_200, currency: 'GBP' },
      totalVar95: { amount: 98_000, currency: 'GBP' },
      totalTvar: { amount: 120_000, currency: 'GBP' },
      // A MEASURED zero. It must stay a zero: refusing on it would be as wrong
      // as inventing one, and this is the case a naive `if (!amount)` breaks.
      totalCarried: { amount: 0, currency: 'GBP' },
      carried: { amount: 0, currency: 'GBP' },
      totalCarriedGbp: 0,
      pricing: { ...NO_RISK_DATA_PLANE, available: true, status: 'PRICED', unpricedFields: [] },
    }
    const out = normalizePostureSummary(priced)

    expect(out.totalAle).toEqual({ amount: 41_200, currency: 'GBP' })
    expect(out.totalCarried).toEqual({ amount: 0, currency: 'GBP' })
    expect(out.totalCarriedGbp).toBe(0)
    expect(formatMoney(out.totalCarried)).not.toBe(MONEY_UNAVAILABLE)
  })

  it('normalises each nested framework, so a priced headline cannot hide an unpriced row', () => {
    const out = normalizePostureSummary({
      ...unpricedSummary(),
      frameworks: [unpricedFramework()],
    })
    expect(out.frameworks[0].totalExposure).toBeNull()
    expect(out.frameworks[0].exposure).toBeNull()
    expect(out.frameworks[0].totalExposureGbp).toBeNull()
  })
})

describe('normalizeFrameworkSummary preserves a refusal', () => {
  it('leaves exposure null rather than manufacturing a zero', () => {
    const out = normalizeFrameworkSummary(unpricedFramework())
    expect(out.totalExposure, 'totalExposure').toBeNull()
    expect(out.exposure, 'exposure').toBeNull()
    expect(out.totalExposureGbp, 'totalExposureGbp').toBeNull()
    expect(formatMoney(out.totalExposure)).toBe(MONEY_UNAVAILABLE)
  })

  it('still reports the control counts', () => {
    const out = normalizeFrameworkSummary(unpricedFramework())
    expect(out.totalControls).toBe(6)
    expect(out.passedControls).toBe(4)
    expect(out.failedControls).toBe(2)
  })

  it('promotes the legacy bare number when that is all the payload carried', () => {
    // Version skew the other way: an older server that sends only
    // `totalExposureGbp`. That IS a figure and must be used, which is why the
    // fallback chain is kept rather than replaced by a flat null.
    const out = normalizeFrameworkSummary({
      ...unpricedFramework(),
      totalExposureGbp: 31_100,
      pricing: undefined,
    })
    expect(out.totalExposure).toEqual({ amount: 31_100, currency: 'GBP' })
    expect(out.exposure).toEqual({ amount: 31_100, currency: 'GBP' })
  })

  it('honours the document currency rather than defaulting to GBP', () => {
    const out = normalizeFrameworkSummary(
      { ...unpricedFramework(), totalExposureGbp: 500 },
      'USD',
    )
    // The field NAME says Gbp; the document says otherwise and wins. A rename
    // must never be able to silently redenominate a value.
    expect(out.totalExposure).toEqual({ amount: 500, currency: 'USD' })
  })
})
