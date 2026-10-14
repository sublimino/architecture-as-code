import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import PolicyEvaluationPage from './PolicyEvaluationPage'
import { api } from '../api/client'

// ── Mocks ──────────────────────────────────────────────────────────────────

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

vi.mock('../api/client', () => ({
  api: {
    compliance: {
      frameworks: vi.fn(),
    },
    agents: {
      list: vi.fn(),
    },
  },
}))

function renderPage(initialEntries = ['/evaluations?framework=eu-ai-act']) {
  return render(
    <MemoryRouter initialEntries={initialEntries}>
      <PolicyEvaluationPage />
    </MemoryRouter>
  )
}

describe('PolicyEvaluationPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [
        {
          id: 'a0000000-0000-0000-0000-000000000001',
          name: 'Sentinel Alpha',
          tenant_id: 'tid',
          lifecycle_state: 'Governed',
          last_transition_at: null,
          compliance_summary: { total_controls: 6, passing: 4, failing: 2, pending: 0, posture_score: 0.67 },
        },
      ],
    } as never)
    vi.mocked(api.compliance.frameworks).mockResolvedValue([
      {
        id: 'eu-ai-act',
        name: 'EU AI Act',
        version: 'v2.1.0',
        regulatory_body: 'European Commission',
        compliance_deadline: '2026-08-02',
        control_count: 6,
        controls: [],
      },
    ] as never)
  })

  it('renders header, agent information, and evaluation tabs', async () => {
    renderPage(['/evaluations?framework=eu-ai-act&agent=a0000000-0000-0000-0000-000000000001'])

    await waitFor(() => {
      expect(screen.getByTestId('eval-header-title')).toHaveTextContent(/Policy Evaluation: Sentinel Alpha/i)
    })
    expect(screen.getByTestId('eval-framework-badge')).toHaveTextContent('EU-AI-ACT')
    expect(screen.getByTestId('eval-tab-violations')).toBeInTheDocument()
    expect(screen.getByTestId('eval-tab-checks')).toBeInTheDocument()
    expect(screen.getByTestId('eval-tab-sources')).toBeInTheDocument()
    expect(screen.getByTestId('eval-tab-attestation')).toBeInTheDocument()
  })

  it('renders actionable policy violations and suggested patch', async () => {
    renderPage(['/evaluations?framework=eu-ai-act&tab=violations'])

    await waitFor(() => {
      expect(screen.getByText(/EU AI Act Art 14: Human Oversight Intervention Interface/i)).toBeInTheDocument()
    })
    expect(screen.getAllByText(/Actionable Remediation Patch/i).length).toBeGreaterThan(0)
  })

  it('filters violations to specific violation when deep-linked', async () => {
    renderPage(['/evaluations?framework=eu-ai-act&tab=violations&violation=Human%20Oversight'])

    await waitFor(() => {
      expect(screen.getByText(/Filtered to deep-linked violation:/i)).toBeInTheDocument()
    })
    expect(screen.getByText('Human Oversight')).toBeInTheDocument()
  })

  it('switches to all policy checks tab showing CEL expressions and cost units', async () => {
    const user = userEvent.setup()
    renderPage(['/evaluations?framework=eu-ai-act'])

    const checksTab = await screen.findByTestId('eval-tab-checks')
    await user.click(checksTab)

    expect(await screen.findByText(/Evaluated Policy Rules/i)).toBeInTheDocument()
    expect(screen.getByText(/Cost: 18 units/i)).toBeInTheDocument()
  })

  it('switches to input sources tab showing raw workload manifest and telemetry', async () => {
    const user = userEvent.setup()
    renderPage(['/evaluations?framework=eu-ai-act'])

    const sourcesTab = await screen.findByTestId('eval-tab-sources')
    await user.click(sourcesTab)

    expect(await screen.findByText(/Input Source Data \(Evaluated Bindings\)/i)).toBeInTheDocument()
  })

  it('switches to in-toto attestation tab with cryptographic witness verification', async () => {
    const user = userEvent.setup()
    renderPage(['/evaluations?framework=eu-ai-act'])

    const attestationTab = await screen.findByTestId('eval-tab-attestation')
    await user.click(attestationTab)

    expect(await screen.findByText(/in-toto Statement v1 Attestation/i)).toBeInTheDocument()
    expect(screen.getByText(/https:\/\/in-toto.io\/Statement\/v1/i)).toBeInTheDocument()
    expect(screen.getByText(/cosign:local-demo-only/i)).toBeInTheDocument()
  })
})
