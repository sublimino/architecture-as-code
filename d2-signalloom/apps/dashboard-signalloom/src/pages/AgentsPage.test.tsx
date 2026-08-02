import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import AgentsPage from './AgentsPage'
import { api } from '../api/client'
import type { AgentResponse } from '../types/api'

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently: vi.fn().mockResolvedValue('test-token') }),
}))

vi.mock('../api/client', () => ({
  api: {
    agents: { list: vi.fn() },
    nhi: {
      discovered: vi.fn().mockResolvedValue({
        accounts: [],
        summary: { total_discovered: 0, needs_triage: 0, previously_dismissed: 0 },
      }),
      scans: vi.fn().mockResolvedValue({ scans: [] }),
    },
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
    eu_ai_act_risk_class: 'limited_risk',
    compliance_summary: { total_controls: 6, passing: 4, failing: 0, pending: 2, posture_score: 67 },
    created_at: '2026-05-01T00:00:00Z',
    ...overrides,
  }
}

function renderPage() {
  return render(
    <MemoryRouter>
      <AgentsPage />
    </MemoryRouter>
  )
}

describe('AgentsPage — lifecycle tooltip + EU AI Act column', () => {
  it('shows an EU AI Act column with the risk class badge', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({ agents: [makeAgent()], total: 1 })
    renderPage()

    expect(await screen.findByText('EU AI Act')).toBeInTheDocument()
    expect(await screen.findByText('limited risk')).toBeInTheDocument()
  })

  it('renders a placeholder when eu_ai_act_risk_class is null', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [makeAgent({ eu_ai_act_risk_class: null })],
      total: 1,
    })
    renderPage()

    await screen.findByText('Invoice Bot')
    expect(screen.getAllByText('—').length).toBeGreaterThan(0)
  })

  it('shows a descriptive tooltip on the lifecycle-state badge', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({ agents: [makeAgent({ lifecycle_state: 'suspended' })], total: 1 })
    renderPage()

    const badge = await screen.findByText('suspended')
    await waitFor(() => expect(badge.closest('[title]')).toHaveAttribute(
      'title',
      expect.stringContaining('reversible')
    ))
  })
})
