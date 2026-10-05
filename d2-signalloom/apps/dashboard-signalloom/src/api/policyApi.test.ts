/**
 * Tests for policyApi: the multilayer policy engine's findings, decisions,
 * review, and ingest-rate endpoints.
 *
 * The contract under test is the one the gateway exposes under
 * `/api/signals/policy/*`. `req()` is mocked, so these tests pin the URL and
 * the query string this client builds, the list coercion, and the review
 * error mapping (409 "already recorded", 403 "cannot review").
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const { mockReq, mockIsDemoMode } = vi.hoisted(() => ({
  mockReq: vi.fn(),
  mockIsDemoMode: vi.fn().mockReturnValue(false),
}))

vi.mock('./client', () => ({ req: mockReq }))
vi.mock('./demoMode', () => ({ isDemoMode: mockIsDemoMode }))

import { policyApi, reviewErrorMessage, POLICY_WINDOWS } from './policyApi'

describe('policyApi', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockIsDemoMode.mockReturnValue(false)
    mockReq.mockResolvedValue([])
  })

  it('exposes the four review windows in ascending order', () => {
    expect(POLICY_WINDOWS).toEqual(['5m', '10m', '30m', '90m'])
  })

  it('getFindings sends the window as a query parameter', async () => {
    await policyApi.getFindings('tok', { window: '30m' })
    expect(mockReq).toHaveBeenCalledWith('/signals/policy/findings?window=30m', 'tok')
  })

  it('getFindings passes tenant and limit when given', async () => {
    await policyApi.getFindings('tok', { window: '5m', tenant: 'kusari', limit: 25 })
    expect(mockReq).toHaveBeenCalledWith(
      '/signals/policy/findings?window=5m&tenant=kusari&limit=25',
      'tok',
    )
  })

  it('getDecisions sends the window as a query parameter', async () => {
    await policyApi.getDecisions('tok', { window: '90m' })
    expect(mockReq).toHaveBeenCalledWith('/signals/policy/decisions?window=90m', 'tok')
  })

  it('getRates sends both window and bucket', async () => {
    await policyApi.getRates('tok', { window: '10m', bucket: '1m' })
    expect(mockReq).toHaveBeenCalledWith('/signals/policy/rates?window=10m&bucket=1m', 'tok')
  })

  it('coerces a null list body to an empty array', async () => {
    mockReq.mockResolvedValue(null)
    await expect(policyApi.getFindings('tok', { window: '5m' })).resolves.toEqual([])
    await expect(policyApi.getDecisions('tok', { window: '5m' })).resolves.toEqual([])
    await expect(policyApi.getRates('tok', { window: '5m', bucket: '1m' })).resolves.toEqual([])
  })

  it('reviewDecision posts the verdict and note to the decision review route', async () => {
    mockReq.mockResolvedValue({
      id: 'rev-1',
      decision_id: 'dec-1',
      verdict: 'true_positive',
      note: 'Confirmed exfiltration attempt.',
      reviewer: 'operator@signalloom.local',
      reviewed_at: '2026-10-05T09:00:00Z',
    })
    const review = await policyApi.reviewDecision('tok', 'dec-1', {
      verdict: 'true_positive',
      note: 'Confirmed exfiltration attempt.',
    })
    expect(mockReq).toHaveBeenCalledWith('/signals/policy/decisions/dec-1/review', 'tok', {
      method: 'POST',
      data: { verdict: 'true_positive', note: 'Confirmed exfiltration attempt.' },
    })
    expect(review.verdict).toBe('true_positive')
  })

  it('reviewDecision encodes a decision id with path characters', async () => {
    mockReq.mockResolvedValue({})
    await policyApi.reviewDecision('tok', 'dec/1 2', { verdict: 'needs_info', note: 'ten chars.' })
    expect(mockReq).toHaveBeenCalledWith(
      '/signals/policy/decisions/dec%2F1%202/review',
      'tok',
      expect.anything(),
    )
  })

  describe('demo mode', () => {
    beforeEach(() => mockIsDemoMode.mockReturnValue(true))

    it('serves findings from local fixtures without an HTTP call', async () => {
      const findings = await policyApi.getFindings('tok', { window: '90m' })
      expect(mockReq).not.toHaveBeenCalled()
      expect(findings.length).toBeGreaterThan(0)
    })

    it('serves decisions and rates from local fixtures without an HTTP call', async () => {
      const decisions = await policyApi.getDecisions('tok', { window: '90m' })
      const rates = await policyApi.getRates('tok', { window: '90m', bucket: '5m' })
      expect(mockReq).not.toHaveBeenCalled()
      expect(decisions.length).toBeGreaterThan(0)
      expect(rates.length).toBeGreaterThan(0)
    })

    it('records a review locally so the badge persists across a refetch', async () => {
      const before = await policyApi.getDecisions('tok', { window: '90m' })
      const target = before.find((d) => d.review === null)
      expect(target).toBeDefined()
      await policyApi.reviewDecision('tok', target!.id, {
        verdict: 'false_positive',
        note: 'Known backup job, benign.',
      })
      const after = await policyApi.getDecisions('tok', { window: '90m' })
      expect(after.find((d) => d.id === target!.id)?.review?.verdict).toBe('false_positive')
      expect(mockReq).not.toHaveBeenCalled()
    })

    it('narrows the fixture set as the window shrinks', async () => {
      const wide = await policyApi.getFindings('tok', { window: '90m' })
      const narrow = await policyApi.getFindings('tok', { window: '5m' })
      expect(narrow.length).toBeLessThan(wide.length)
    })
  })

  describe('reviewErrorMessage', () => {
    it('maps 409 to an already-recorded message', () => {
      expect(reviewErrorMessage({ response: { status: 409 } })).toBe(
        'That review is already recorded for this decision.',
      )
    })

    it('maps 403 to a cannot-review message', () => {
      expect(reviewErrorMessage({ response: { status: 403 } })).toBe(
        'Your key cannot review decisions. Ask an operator with review rights.',
      )
    })

    it('maps 404 to a missing-decision message', () => {
      expect(reviewErrorMessage({ response: { status: 404 } })).toBe(
        'The policy engine no longer knows this decision for your tenant.',
      )
    })

    it('maps 502 and 503 to an unreachable message', () => {
      expect(reviewErrorMessage({ response: { status: 502 } })).toBe(
        'The policy engine is unreachable from the portal right now.',
      )
      expect(reviewErrorMessage({ response: { status: 503 } })).toBe(
        'The policy engine is unreachable from the portal right now.',
      )
    })

    it('prefers a server-supplied error message over the fallback', () => {
      expect(
        reviewErrorMessage({ response: { status: 400, data: { error: { message: 'note too short' } } } }),
      ).toBe('note too short')
    })

    it('falls back to the Error message', () => {
      expect(reviewErrorMessage(new Error('Network Error'))).toBe('Network Error')
    })

    it('falls back to a generic message for a non-Error', () => {
      expect(reviewErrorMessage('nope')).toBe('Review failed.')
    })
  })

  describe('isPolicyConnectionError', () => {
    it('recognises the shapes that mean the gateway is down', async () => {
      const { isPolicyConnectionError } = await import('./policyApi')
      expect(isPolicyConnectionError('Network Error')).toBe(true)
      expect(isPolicyConnectionError('connect ECONNREFUSED 127.0.0.1:8080')).toBe(true)
      expect(isPolicyConnectionError('Request failed with status code 502')).toBe(true)
      expect(isPolicyConnectionError('Request failed with status code 503')).toBe(true)
      expect(isPolicyConnectionError('upstream_unavailable')).toBe(true)
    })

    it('does not treat an ordinary failure as a connection error', async () => {
      const { isPolicyConnectionError } = await import('./policyApi')
      expect(isPolicyConnectionError('Request failed with status code 422')).toBe(false)
    })
  })
})
