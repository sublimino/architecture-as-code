import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import SuperCredPage from './SuperCredPage'

const AGENTS_NS = 'fe-signalloom-agents'
const FLUX_NS = 'fe-signalloom'

interface AgentFixture {
  id: string
  name: string
  namespace: string
  type?: string | null
  framework?: string | null
  model?: string | null
  state?: string | null
  phase?: string | null
  supercred?: boolean
  supercred_target?: string
  stunned_at?: string
  stun_reason?: string
}

function cardvault(overrides: Partial<AgentFixture> = {}): AgentFixture {
  return {
    id: 'agent-cardvault',
    name: 'Cardvault Agent',
    namespace: FLUX_NS,
    type: 'supercred-demo',
    framework: 'langchain',
    model: 'gpt-4',
    state: 'idle',
    phase: 'Running',
    supercred: true,
    supercred_target: 'cardvault.inf-signalloom.svc.cluster.local:8080',
    ...overrides,
  }
}

function plainAgent(id: string): AgentFixture {
  return { id, name: id, namespace: AGENTS_NS, type: 'demo', state: 'active', phase: 'Running' }
}

function stunnedCardvault(): AgentFixture {
  return cardvault({
    state: 'stunned',
    stunned_at: '2026-01-01T00:01:00Z',
    stun_reason: 'non-compliant securityContext',
  })
}

/** Route fetches by URL so a test only declares the payloads it cares about. */
function mockFetch(routes: {
  agents?: AgentFixture[]
  compliance?: unknown
  stun?: unknown
  agentsError?: Error
}) {
  const calls: string[] = []
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input)
    calls.push(url)
    if (url.includes('/compliance')) {
      return {
        ok: true,
        json: async () =>
          routes.compliance ?? {
            agent_id: 'agent-cardvault',
            compliant: false,
            results: [
              { check: 'security-context-present', pass: false, reason: 'securityContext is not set', severity: 'critical' },
              { check: 'resource-limits-set', pass: true, reason: 'CPU and memory limits configured', severity: 'high' },
              { check: 'network-policy-exists', pass: false, reason: 'No NetworkPolicy targets this pod', severity: 'high' },
            ],
            evaluated_at: '2026-01-01T00:00:00Z',
          },
      } as Response
    }
    if (url.includes('/stun')) {
      return {
        ok: true,
        json: async () =>
          routes.stun ?? {
            agent_id: 'agent-cardvault',
            namespace: FLUX_NS,
            state: 'stunned',
            stunned_at: '2026-01-01T00:00:00Z',
            message: 'Agent agent-cardvault stunned: credentials revoked',
          },
      } as Response
    }
    if (routes.agentsError) throw routes.agentsError
    return {
      ok: true,
      json: async () => ({
        agents: routes.agents ?? [],
        namespaces: [AGENTS_NS, FLUX_NS],
      }),
    } as Response
  })
  globalThis.fetch = fetchMock as unknown as typeof fetch
  return calls
}

function renderPage() {
  return render(
    <MemoryRouter>
      <SuperCredPage />
    </MemoryRouter>,
  )
}

async function refresh() {
  await userEvent.click(screen.getByRole('button', { name: /Refresh Agents/ }))
}

describe('SuperCredPage', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  // ─── Core agent rendering ────────────────────────────────────────────────

  it('renders SuperCred agents returned by the proxy', async () => {
    mockFetch({ agents: [cardvault(), plainAgent('agent-dennis')] })
    renderPage()
    await refresh()
    // Agent name appears in multiple sections (agent list + lifecycle); verify
    // at least one renders.
    const matches = await screen.findAllByText('Cardvault Agent')
    expect(matches.length).toBeGreaterThanOrEqual(1)
  })

  it('shows the namespace the agent was discovered in', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    expect(await screen.findByTestId('agent-namespace-agent-cardvault')).toHaveTextContent(FLUX_NS)
  })

  it('says so explicitly when agents were found but none is SuperCred', async () => {
    mockFetch({ agents: [plainAgent('agent-dennis'), plainAgent('agent-patsy')] })
    renderPage()
    await refresh()
    const emptyState = await screen.findByTestId('supercred-empty-state')
    expect(emptyState).toHaveTextContent(/2 runtime agents/)
    expect(emptyState).toHaveTextContent(/none carries the SuperCred label/i)
    expect(emptyState).toHaveTextContent('make demo-signalloom-supercred-1')
  })

  it('distinguishes "not loaded yet" from "loaded but empty"', async () => {
    mockFetch({ agents: [] })
    renderPage()
    expect(screen.getByTestId('supercred-not-loaded')).toBeInTheDocument()
    expect(screen.queryByTestId('supercred-empty-state')).not.toBeInTheDocument()
    await refresh()
    expect(await screen.findByTestId('supercred-empty-state')).toBeInTheDocument()
    expect(screen.queryByTestId('supercred-not-loaded')).not.toBeInTheDocument()
  })

  // ─── Compliance ──────────────────────────────────────────────────────────

  it('passes the agent namespace to the compliance call', async () => {
    const calls = mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Compliance Scan/ }))
    await waitFor(() =>
      expect(
        calls.some(url =>
          url === `/supercred-api/agents/agent-cardvault/compliance?namespace=${FLUX_NS}`,
        ),
      ).toBe(true),
    )
    expect(await screen.findByText('security-context-present')).toBeInTheDocument()
  })

  it('shows compliance summary counts after scan', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Compliance Scan/ }))
    const summary = await screen.findByTestId('supercred-compliance-summary')
    expect(summary).toHaveTextContent('1 passed')
    expect(summary).toHaveTextContent('2 failed')
    expect(summary).toHaveTextContent('3 total checks')
  })

  it('renders severity column for compliance results', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Compliance Scan/ }))
    const compliance = await screen.findByTestId('supercred-compliance')
    expect(compliance).toHaveTextContent('critical')
    expect(compliance).toHaveTextContent('high')
  })

  it('renders multiple compliance check rows', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Compliance Scan/ }))
    expect(await screen.findByText('security-context-present')).toBeInTheDocument()
    expect(screen.getByText('resource-limits-set')).toBeInTheDocument()
    expect(screen.getByText('network-policy-exists')).toBeInTheDocument()
  })

  // ─── Stun ────────────────────────────────────────────────────────────────

  it('passes the agent namespace to the stun call', async () => {
    const calls = mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Stun Agent/ }))
    await waitFor(() =>
      expect(
        calls.some(url => url === `/supercred-api/agents/agent-cardvault/stun?namespace=${FLUX_NS}`),
      ).toBe(true),
    )
    expect(await screen.findByTestId('supercred-stun-result')).toHaveTextContent(/credentials revoked/)
  })

  it('shows automated stun actions after stun', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Stun Agent/ }))
    const actions = await screen.findByTestId('supercred-stun-actions')
    expect(actions).toHaveTextContent('OpenBao dynamic lease revoked')
    expect(actions).toHaveTextContent('SPIFFE SVID rotation blocked')
    expect(actions).toHaveTextContent('deny-all egress')
    expect(actions).toHaveTextContent('audit trail')
  })

  it('hides stun button for already-stunned agents', async () => {
    mockFetch({ agents: [stunnedCardvault()] })
    renderPage()
    await refresh()
    await screen.findAllByText('Cardvault Agent')
    expect(screen.queryByRole('button', { name: /Stun Agent/ })).not.toBeInTheDocument()
  })

  // ─── Phase warnings ─────────────────────────────────────────────────────

  it('warns when an agent pod phase means it cannot run', async () => {
    mockFetch({ agents: [cardvault({ phase: 'Pending' })] })
    renderPage()
    await refresh()
    const warning = await screen.findByTestId('supercred-phase-warning')
    expect(warning).toHaveTextContent(/Pending/)
    expect(warning).toHaveTextContent('make demo-signalloom-supercred-images')
  })

  it('does not warn for a healthy Running agent', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await screen.findAllByText('Cardvault Agent')
    expect(screen.queryByTestId('supercred-phase-warning')).not.toBeInTheDocument()
  })

  // ─── Error handling ──────────────────────────────────────────────────────

  it('renders a fetch failure without crashing', async () => {
    mockFetch({ agentsError: new Error('proxy unreachable') })
    renderPage()
    await refresh()
    expect(await screen.findByTestId('supercred-error')).toHaveTextContent(/proxy unreachable/)
    expect(screen.getByRole('heading', { level: 1, name: /SuperCred Demo/ })).toBeInTheDocument()
  })

  // ─── Architecture overview ──────────────────────────────────────────────

  it('renders architecture overview section', () => {
    mockFetch({ agents: [] })
    renderPage()
    const arch = screen.getByTestId('supercred-architecture')
    expect(arch).toHaveTextContent('Architecture Overview')
    expect(arch).toHaveTextContent('zero-trust credential lifecycle')
    expect(arch).toHaveTextContent('SPIFFE SVID')
  })

  it('renders flow diagram with 6 steps', () => {
    mockFetch({ agents: [] })
    renderPage()
    const diagram = screen.getByTestId('supercred-flow-diagram')
    expect(diagram).toHaveTextContent('Agent Deploy')
    expect(diagram).toHaveTextContent('SPIFFE SVID')
    expect(diagram).toHaveTextContent('OpenBao Exchange')
    expect(diagram).toHaveTextContent('Service Call')
    expect(diagram).toHaveTextContent('Compliance Scan')
    expect(diagram).toHaveTextContent('Enforce/Revoke')
  })

  // ─── Lifecycle timeline ─────────────────────────────────────────────────

  it('renders credential lifecycle timeline when agent is loaded', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    const lifecycle = await screen.findByTestId('supercred-lifecycle')
    expect(lifecycle).toHaveTextContent('Credential Lifecycle')
    expect(lifecycle).toHaveTextContent('Cardvault Agent')
  })

  it('shows all 6 lifecycle steps', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    for (let i = 1; i <= 6; i++) {
      expect(await screen.findByTestId(`lifecycle-step-${i}`)).toBeInTheDocument()
    }
  })

  it('marks deployment steps as completed for a running agent', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    // Steps 1-4 should be completed for a running agent
    for (const step of [1, 2, 3, 4]) {
      const status = await screen.findByTestId(`lifecycle-status-${step}`)
      expect(status).toHaveTextContent('completed')
    }
    // Step 5 should be active (awaiting scan)
    expect(await screen.findByTestId('lifecycle-status-5')).toHaveTextContent('active')
    // Step 6 should be pending (awaiting action)
    expect(await screen.findByTestId('lifecycle-status-6')).toHaveTextContent('pending')
  })

  it('marks step 6 as failed for a stunned agent', async () => {
    mockFetch({ agents: [stunnedCardvault()] })
    renderPage()
    await refresh()
    const step6 = await screen.findByTestId('lifecycle-status-6')
    expect(step6).toHaveTextContent('failed')
  })

  it('does not render lifecycle when no agents are loaded', () => {
    mockFetch({ agents: [] })
    renderPage()
    expect(screen.queryByTestId('supercred-lifecycle')).not.toBeInTheDocument()
  })

  // ─── Credential inventory ───────────────────────────────────────────────

  it('renders credential inventory table when agent is loaded', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    const creds = await screen.findByTestId('supercred-credentials')
    expect(creds).toHaveTextContent('Credential Inventory')
  })

  it('shows 3 credential records with correct issuers', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    const creds = await screen.findByTestId('supercred-credentials')
    expect(creds).toHaveTextContent('spire-server.spire-system')
    expect(creds).toHaveTextContent('openbao.openbao-system')
    expect(creds).toHaveTextContent('cardvault-service')
  })

  it('shows active status for credentials of a running agent', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    const spiffeCred = await screen.findByTestId('credential-status-cred-agent-cardvault-spiffe')
    expect(spiffeCred).toHaveTextContent('active')
    const openbao = screen.getByTestId('credential-status-cred-agent-cardvault-openbao')
    expect(openbao).toHaveTextContent('active')
  })

  it('shows revoked status for credentials of a stunned agent', async () => {
    mockFetch({ agents: [stunnedCardvault()] })
    renderPage()
    await refresh()
    const spiffeCred = await screen.findByTestId('credential-status-cred-agent-cardvault-spiffe')
    expect(spiffeCred).toHaveTextContent('revoked')
    const openbao = screen.getByTestId('credential-status-cred-agent-cardvault-openbao')
    expect(openbao).toHaveTextContent('revoked')
  })

  it('shows rotation count for credentials', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    // The OpenBao credential has rotation_count: 2
    const creds = await screen.findByTestId('supercred-credentials')
    expect(within(creds).getByText('2')).toBeInTheDocument()
  })

  it('does not render credentials when no agents are loaded', () => {
    mockFetch({ agents: [] })
    renderPage()
    expect(screen.queryByTestId('supercred-credentials')).not.toBeInTheDocument()
  })

  // ─── Discovery summary ─────────────────────────────────────────────────

  it('renders discovery summary after loading agents', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    const summary = await screen.findByTestId('supercred-discovery-summary')
    expect(summary).toHaveTextContent('Discovery Summary')
    expect(screen.getByTestId('discovery-total')).toHaveTextContent('1')
    expect(screen.getByTestId('discovery-supercred')).toHaveTextContent('1')
    expect(screen.getByTestId('discovery-namespaces')).toHaveTextContent('2')
    expect(screen.getByTestId('discovery-blocked')).toHaveTextContent('0')
  })

  it('shows blocked count in discovery summary for pending agents', async () => {
    mockFetch({ agents: [cardvault({ phase: 'Pending' })] })
    renderPage()
    await refresh()
    expect(await screen.findByTestId('discovery-blocked')).toHaveTextContent('1')
  })

  it('shows namespace list in discovery summary', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    const nsList = await screen.findByTestId('discovery-namespace-list')
    expect(nsList).toHaveTextContent(AGENTS_NS)
    expect(nsList).toHaveTextContent(FLUX_NS)
  })

  // ─── Demo steps ─────────────────────────────────────────────────────────

  it('names the real Makefile targets in the demo steps', async () => {
    mockFetch({ agents: [] })
    renderPage()
    const steps = screen.getByTestId('supercred-demo-steps')
    expect(steps).toHaveTextContent('make demo-signalloom-supercred-1')
    expect(steps).toHaveTextContent('make demo-signalloom-supercred-2')
    expect(steps).toHaveTextContent('make demo-signalloom-supercred-5')
    expect(steps).not.toHaveTextContent('demo-supercred-step1')
  })

  // ─── Agent detail rendering ─────────────────────────────────────────────

  it('shows framework and model when present', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    // Agent namespace test-id is unique to the agent row
    const nsEl = await screen.findByTestId('agent-namespace-agent-cardvault')
    const row = nsEl.closest('div')!.parentElement!
    expect(row).toHaveTextContent('Framework: langchain')
    expect(row).toHaveTextContent('Model: gpt-4')
  })

  it('shows stun reason for stunned agents', async () => {
    mockFetch({ agents: [stunnedCardvault()] })
    renderPage()
    await refresh()
    const nsEl = await screen.findByTestId('agent-namespace-agent-cardvault')
    const row = nsEl.closest('div')!.parentElement!
    expect(row).toHaveTextContent('non-compliant securityContext')
  })
})
