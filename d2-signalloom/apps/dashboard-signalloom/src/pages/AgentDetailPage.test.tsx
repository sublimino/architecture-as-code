/**
 * Tests for the Request Transition flow on the Agent Detail page.
 *
 * Transitions are operator-mediated: the direct POST /agents/{id}/transition is
 * Entra-only and the api-gateway proxy 403s dashboard users. The dashboard must
 * therefore submit a *request* via the /support channel — these tests assert
 * that behavior (and that no direct transition call is made).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import AgentDetailPage from './AgentDetailPage'
import { api } from '../api/client'
import type { AgentResponse } from '../types/api'

// ── Mocks ──────────────────────────────────────────────────────────────────

// getAccessTokenSilently must keep a STABLE identity across renders, otherwise
// the page's load() useCallback is recreated every render and the load effect
// loops, leaving the page perpetually in its loading state.
vi.mock('../auth/oidc', () => {
  const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
  return { useAuth0: () => ({ getAccessTokenSilently }) }
})

vi.mock('../api/client', () => ({
  api: {
    agents: {
      get: vi.fn(),
      violations: vi.fn().mockResolvedValue({ violations: [], total: 0 }),
      reassess: vi.fn(),
      acknowledge: vi.fn(),
    },
    audit: vi.fn().mockResolvedValue({ events: [], total: 0, page: 1, limit: 50 }),
    compliance: { posture: vi.fn().mockResolvedValue({ agents: [] }) },
    support: vi.fn().mockResolvedValue({
      id: 'req-1', subject: 's', urgency: 'normal',
      submitted_at: '2026-06-11T00:00:00Z', clickup_task_id: 'CU-1',
    }),
  },
}))

function makeAgent(overrides: Partial<AgentResponse> = {}): AgentResponse {
  return {
    id: 'agent-abc-123',
    name: 'Invoice Bot',
    type: 'Signal Loom Built',
    owner: 'ops@acme.com',
    tenant_id: 'tenant-1',
    lifecycle_state: 'enrolled',
    last_transition_at: '2026-06-01T00:00:00Z',
    last_transition_by: 'operator@signal-loom.ai',
    eu_ai_act_risk_class: 'limited',
    compliance_summary: { total_controls: 6, passing: 4, failing: 0, pending: 2, posture_score: 67 },
    created_at: '2026-05-01T00:00:00Z',
    ...overrides,
  }
}

function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/agents/agent-abc-123']}>
      <Routes>
        <Route path="/agents/:id" element={<AgentDetailPage />} />
      </Routes>
    </MemoryRouter>
  )
}

describe('AgentDetailPage — Request Transition', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    ;(api.agents.violations as ReturnType<typeof vi.fn>).mockResolvedValue({ violations: [], total: 0 })
    ;(api.audit as ReturnType<typeof vi.fn>).mockResolvedValue({ events: [], total: 0, page: 1, limit: 50 })
    ;(api.compliance.posture as ReturnType<typeof vi.fn>).mockResolvedValue({ agents: [] })
    ;(api.support as ReturnType<typeof vi.fn>).mockResolvedValue({
      id: 'req-1', subject: 's', urgency: 'normal',
      submitted_at: '2026-06-11T00:00:00Z', clickup_task_id: 'CU-1',
    })
  })

  it('shows a Request Transition button for a non-terminal agent', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent())
    renderPage()
    expect(await screen.findByRole('button', { name: /request transition/i })).toBeInTheDocument()
  })

  it('offers only valid next states for an enrolled agent', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ lifecycle_state: 'enrolled' }))
    renderPage()
    await userEvent.click(await screen.findByRole('button', { name: /request transition/i }))

    const select = screen.getByLabelText(/requested state/i) as HTMLSelectElement
    const values = Array.from(select.options).map(o => o.value)
    // enrolled → active only
    expect(values).toEqual(['active'])
  })

  it('offers suspend and revoke for an active agent', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ lifecycle_state: 'active' }))
    renderPage()
    await userEvent.click(await screen.findByRole('button', { name: /request transition/i }))

    const select = screen.getByLabelText(/requested state/i) as HTMLSelectElement
    const values = Array.from(select.options).map(o => o.value)
    expect(values).toEqual(['suspended', 'revoked'])
  })

  it('does NOT offer transitions for a revoked (terminal) agent', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ lifecycle_state: 'revoked' }))
    renderPage()
    await screen.findByText('Invoice Bot')
    expect(screen.queryByRole('button', { name: /request transition/i })).not.toBeInTheDocument()
    expect(screen.getByText(/no transitions available/i)).toBeInTheDocument()
  })

  it('submits via the support channel and shows success — never calls a direct transition', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ lifecycle_state: 'active' }))
    renderPage()
    await userEvent.click(await screen.findByRole('button', { name: /request transition/i }))

    await userEvent.type(screen.getByLabelText(/reason/i), 'Investigating anomalous behavior')
    await userEvent.click(screen.getByRole('button', { name: /submit request/i }))

    await waitFor(() => expect(api.support).toHaveBeenCalledTimes(1))

    const [, body] = (api.support as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.subject).toContain('Invoice Bot')
    expect(body.subject).toContain('suspended') // default first option for active
    expect(body.message).toContain('agent-abc-123')
    expect(body.message).toContain('Investigating anomalous behavior')

    // The dashboard must never invoke the operator-only transition endpoint.
    expect((api.agents as Record<string, unknown>).transition).toBeUndefined()

    expect(await screen.findByText(/transition requested/i)).toBeInTheDocument()
  })

  it('requires a reason before submitting', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ lifecycle_state: 'active' }))
    renderPage()
    await userEvent.click(await screen.findByRole('button', { name: /request transition/i }))

    // Submit button is disabled until a reason is entered
    expect(screen.getByRole('button', { name: /submit request/i })).toBeDisabled()
    expect(api.support).not.toHaveBeenCalled()
  })
})
