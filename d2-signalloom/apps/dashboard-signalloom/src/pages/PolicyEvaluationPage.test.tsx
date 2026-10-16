import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import PolicyEvaluationPage from './PolicyEvaluationPage'
import { api } from '../api/client'
import { setDemoMode } from '../api/demoMode'

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
      get: vi.fn(),
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

describe('PolicyEvaluationPage (demo mode)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    setDemoMode(true)
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

// ── Live mode: never fabricate an agent or a verdict ────────────────────────

// Strings that exist only in the demo fixtures. None may reach live mode.
const FIXTURE_STRINGS = [
  'a0000000',
  'agent-cardvault',
  'cardvault-agent',
  'claude-3-5-sonnet',
  'cosign:local-demo-only',
  'tenant-demo',
  'signalloom.demo',
]

function expectNoFixture(container: HTMLElement) {
  const html = container.innerHTML
  for (const s of FIXTURE_STRINGS) expect(html).not.toContain(s)
  expect(container.textContent ?? '').not.toMatch(/\bDemo\b/)
}

const REAL_AGENT = {
  id: 'tenant-x:abc12345',
  name: 'payments-bot',
  tenant_id: 'tenant-x',
  lifecycle_state: 'Governed',
  last_transition_at: null,
  identity: { spiffe_id: 'spiffe://prod.example/ns/payments/sa/payments-bot' },
  runtime: { model: 'gpt-4o-2024-08-06' },
  compliance_summary: { total_controls: 9, passing: 7, failing: 2, pending: 0, posture_score: 0.78 },
}

describe('PolicyEvaluationPage (live mode)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    setDemoMode(false)
    vi.mocked(api.agents.list).mockResolvedValue({ agents: [REAL_AGENT] } as never)
    vi.mocked(api.agents.get).mockRejectedValue(Object.assign(new Error('Request failed with status code 404'), { response: { status: 404 } }))
    vi.mocked(api.compliance.frameworks).mockResolvedValue([] as never)
  })

  it('with no ?agent= asks the operator to choose a real agent and fabricates nothing', async () => {
    const { container } = renderPage(['/evaluations?framework=eu-ai-act'])

    expect(await screen.findByTestId('eval-choose-agent')).toBeInTheDocument()
    const choice = await screen.findByRole('link', { name: 'payments-bot' })
    expect(choice.getAttribute('href')).toContain('agent=tenant-x%3Aabc12345')
    expect(screen.getByRole('link', { name: /agents page/i }).getAttribute('href')).toBe('/agents')
    expect(screen.queryByTestId('eval-header-title')).toBeNull()
    expectNoFixture(container)
  })

  it('with an unknown ?agent= shows a not-found state, not a lookalike', async () => {
    const { container } = renderPage(['/evaluations?framework=eu-ai-act&agent=ghost-agent'])

    expect(await screen.findByTestId('eval-agent-not-found')).toHaveTextContent('No agent matches ghost-agent')
    expect(screen.queryByTestId('eval-header-title')).toBeNull()
    expectNoFixture(container)
  })

  it.each(['PAYMENTS-BOT', 'payments'])('does not match the lookalike %s (case or substring)', async (ref) => {
    renderPage([`/evaluations?framework=eu-ai-act&agent=${ref}`])
    expect(await screen.findByTestId('eval-agent-not-found')).toHaveTextContent(`No agent matches ${ref}`)
    expect(screen.queryByTestId('eval-header-title')).toBeNull()
  })

  it('with a known ?agent= shows the real agent from the API and no demo verdicts', async () => {
    const { container } = renderPage(['/evaluations?framework=eu-ai-act&agent=payments-bot'])

    await waitFor(() => {
      expect(screen.getByTestId('eval-header-title')).toHaveTextContent('Policy Evaluation: payments-bot')
    })
    expect(screen.getByText('spiffe://prod.example/ns/payments/sa/payments-bot')).toBeInTheDocument()
    expect(screen.getByText('gpt-4o-2024-08-06')).toBeInTheDocument()
    // Real compliance figures from the agent record.
    expect(screen.getByTestId('eval-live-controls')).toHaveTextContent('7 / 9')
    // No live evaluation API: checks are not evaluated, never a demo verdict.
    expect(screen.getByTestId('eval-not-evaluated')).toBeInTheDocument()
    expect(screen.queryByText(/FAIL \(/)).toBeNull()
    expect(screen.queryByText(/PASS \(COMPLIANT\)/)).toBeNull()
    expect(screen.queryByText(/Cryptographically Verified/)).toBeNull()
    expect(screen.queryByText(/EU AI Act Art 14/)).toBeNull()
    expect(screen.queryByRole('button', { name: /Re-evaluate/ })).toBeNull()
    expectNoFixture(container)
  })

  it('matches by exact id and by the <tenant>:<id> suffix', async () => {
    renderPage(['/evaluations?agent=abc12345'])
    await waitFor(() => {
      expect(screen.getByTestId('eval-header-title')).toHaveTextContent('Policy Evaluation: payments-bot')
    })
  })

  it('fetches an agent not in the first page of the list by id', async () => {
    vi.mocked(api.agents.get).mockResolvedValue({ ...REAL_AGENT, id: 'tenant-x:zz999999', name: 'paged-out' } as never)
    renderPage(['/evaluations?agent=tenant-x:zz999999'])
    await waitFor(() => {
      expect(screen.getByTestId('eval-header-title')).toHaveTextContent('Policy Evaluation: paged-out')
    })
    expect(api.agents.get).toHaveBeenCalledWith('test-token', 'tenant-x:zz999999')
  })

  it('shows a load failure instead of falling back to a fixture', async () => {
    vi.mocked(api.agents.list).mockRejectedValue(new Error('upstream 503'))
    const { container } = renderPage(['/evaluations?agent=payments-bot'])

    expect(await screen.findByTestId('eval-load-error')).toHaveTextContent('upstream 503')
    expect(screen.queryByTestId('eval-header-title')).toBeNull()
    expectNoFixture(container)
  })

  it('demo mode with no ?agent= still renders the demo fixture agent', async () => {
    setDemoMode(true)
    renderPage(['/evaluations?framework=eu-ai-act'])
    await waitFor(() => {
      expect(screen.getByTestId('eval-header-title')).toHaveTextContent('Policy Evaluation: agent-cardvault')
    })
  })
})
