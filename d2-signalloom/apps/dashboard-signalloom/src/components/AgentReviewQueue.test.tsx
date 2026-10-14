import { describe, expect, it } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import axe from 'axe-core'
import AgentReviewQueue from './AgentReviewQueue'
import { deriveAgentReview } from '../data/agentReview'
import type { AgentResponse } from '../types/api'

const agents: AgentResponse[] = Array.from({ length: 6 }, (_, i) => ({
  id: `a${i}`, name: `Bot ${i}`, type: null, tenant_id: 't', lifecycle_state: 'active',
  created_at: null, last_transition_at: null, eu_ai_act_risk_class: null,
  compliance_summary: { total_controls: 5, passing: 2, failing: 3, pending: 0, posture_score: 0.4 },
}))
const review = deriveAgentReview(agents)
function queue(props: Partial<React.ComponentProps<typeof AgentReviewQueue>> = {}) {
  return <MemoryRouter><Routes><Route path="/" element={<AgentReviewQueue review={review} loaded loading={false} error={null} onRetry={() => {}} {...props} />} /><Route path="/agents/:id" element={<p>Agent dossier</p>} /></Routes></MemoryRouter>
}
describe('read-only agent review queue', () => {
  it('permits narrow layouts to wrap heading, counts, evidence and controls rather than clip overflow', () => {
    render(queue({ error: 'a-very-long-unbroken-refresh-error-message' }))
    const region = screen.getByRole('region', { name: 'Review queue' })
    expect(region).toHaveStyle({ minWidth: '0', maxWidth: '100%', whiteSpace: 'normal', overflowWrap: 'anywhere' })
    expect(region.style.overflow).not.toBe('hidden')
    for (const element of [within(region).getByRole('heading'), within(region).getByText(/Last known: 12 issues/), ...within(region).getAllByRole('link'), ...within(region).getAllByRole('button')]) {
      expect(element).toHaveStyle({ minWidth: '0', maxWidth: '100%', whiteSpace: 'normal', overflowWrap: 'anywhere' })
    }
    for (const row of within(region).getAllByRole('listitem')) {
      expect(row).toHaveClass('agent-review-queue__row')
    }
  })
  it('shows top five issues, distinct affected counts, owner fallback, and working expansion', async () => {
    render(queue())
    const region = screen.getByRole('region', { name: 'Review queue' })
    expect(within(region).getByText('12 issues · 6 affected agents')).toBeInTheDocument()
    expect(within(region).getAllByRole('listitem')).toHaveLength(5)
    expect(within(region).getAllByText('Unassigned')).toHaveLength(5)
    await userEvent.click(screen.getByRole('button', { name: 'View all 12 issues' }))
    expect(within(region).getAllByRole('listitem')).toHaveLength(12)
    expect(screen.getByRole('button', { name: 'Show fewer' })).toHaveAttribute('aria-expanded', 'true')
    await userEvent.click(screen.getByRole('button', { name: 'Show fewer' }))
    expect(within(region).getAllByRole('listitem')).toHaveLength(5)
  })
  it.each(['Failing controls', 'Critical posture'])('navigates the formerly inert %s action to the supported assessments dossier', async reason => {
    render(queue())
    const link = screen.getByRole('link', { name: `Review agent Bot 0: ${reason}` })
    expect(link).toHaveAttribute('href', '/agents/a0?tab=assessments')
    await userEvent.click(link)
    expect(screen.getByText('Agent dossier')).toBeInTheDocument()
  })
  it('never claims a clear queue before successful loading or after unavailable evidence', () => {
    const empty = deriveAgentReview([])
    const { rerender } = render(queue({ review: empty, loaded: false, loading: true }))
    expect(screen.getByText('Loading review evidence…')).toBeInTheDocument()
    expect(screen.queryByText('No agents need review')).not.toBeInTheDocument()
    rerender(queue({ review: empty, loaded: false, error: 'offline' }))
    expect(screen.getByRole('alert')).toHaveTextContent('Review queue unavailable: offline')
    rerender(queue({ review: empty, loaded: true }))
    expect(screen.getByText('No agents need review')).toBeInTheDocument()
    rerender(queue({ review: empty, loaded: true, sourceHealth: 'unavailable' }))
    expect(screen.queryByText('No agents need review')).not.toBeInTheDocument()
  })
  it('keeps stale evidence visible on refresh/failure, clearly labels the successful refresh time', () => {
    const { rerender } = render(queue({ loading: true, lastRefresh: '2026-10-13T10:00:00Z' }))
    expect(screen.queryByText(/Refreshing review evidence/)).not.toBeInTheDocument()
    expect(screen.getByText('12 issues · 6 affected agents')).toBeInTheDocument()
    expect(screen.getAllByRole('listitem')).toHaveLength(5)
    rerender(queue({ error: 'timeout', lastRefresh: '2026-10-13T10:00:00Z' }))
    expect(screen.getByRole('alert')).toHaveTextContent('Refresh failed; showing stale review evidence: timeout')
    expect(screen.getByText(/Last successful API refresh:/)).toBeInTheDocument()
    expect(screen.queryByText(/first detected/i)).not.toBeInTheDocument()
    expect(screen.getAllByRole('listitem')).toHaveLength(5)
  })
  it('keeps counts, row identities and accessible full evidence stable across background refresh', () => {
    const { rerender } = render(queue())
    const rows = screen.getAllByRole('listitem')
    const count = screen.getByText('12 issues · 6 affected agents')
    rerender(queue({ loading: true, review: deriveAgentReview(agents.map(agent => ({ ...agent }))) }))
    expect(screen.getByText('12 issues · 6 affected agents')).toBe(count)
    expect(screen.queryByText(/Refreshing review evidence/)).not.toBeInTheDocument()
    expect(screen.getByRole('region', { name: 'Review queue' })).not.toHaveAttribute('aria-busy', 'true')
    screen.getAllByRole('listitem').forEach((row, index) => {
      expect(row).toBe(rows[index])
      expect(within(row).getByText(review.issues[index].description)).toHaveAttribute('title', review.issues[index].description)
    })
  })
  it('retains the loaded empty state while refreshing', () => {
    const { rerender } = render(queue({ review: deriveAgentReview([]) }))
    const empty = screen.getByText('No agents need review')
    rerender(queue({ review: deriveAgentReview([]), loading: true }))
    expect(screen.getByText('No agents need review')).toBe(empty)
    expect(screen.getByText('0 issues · 0 affected agents')).toBeInTheDocument()
  })
  it('has accessible region, links, list and expansion controls', async () => {
    render(queue())
    const result = await axe.run(screen.getByRole('region', { name: 'Review queue' }), { rules: { 'color-contrast': { enabled: false } } })
    expect(result.violations).toEqual([])
  })
  it.each(['unavailable', 'degraded'] as const)('qualifies counts as observed when sources are %s, including zero', sourceHealth => {
    const { rerender } = render(queue({ review: deriveAgentReview([]), sourceHealth }))
    expect(screen.getByText('Observed: 0 issues · 0 affected agents')).toBeInTheDocument()
    expect(screen.queryByText('0 issues · 0 affected agents', { exact: true })).not.toBeInTheDocument()
    rerender(queue({ sourceHealth }))
    expect(screen.getByText('Observed: 12 issues · 6 affected agents')).toBeInTheDocument()
    rerender(queue({ error: 'offline', sourceHealth }))
    expect(screen.getByText('Last known: 12 issues · 6 affected agents')).toBeInTheDocument()
  })
})
