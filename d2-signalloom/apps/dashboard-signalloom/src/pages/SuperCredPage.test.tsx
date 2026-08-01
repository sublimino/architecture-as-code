import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
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
  state?: string | null
  phase?: string | null
  supercred?: boolean
  supercred_target?: string
}

function cardvault(overrides: Partial<AgentFixture> = {}): AgentFixture {
  return {
    id: 'agent-cardvault',
    name: 'Cardvault Agent',
    namespace: FLUX_NS,
    type: 'supercred-demo',
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
              { check: 'security-context-present', pass: false, reason: 'securityContext is not set' },
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

  it('renders SuperCred agents returned by the proxy', async () => {
    mockFetch({ agents: [cardvault(), plainAgent('agent-dennis')] })
    renderPage()
    await refresh()
    expect(await screen.findByText('Cardvault Agent')).toBeInTheDocument()
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

  it('passes the agent namespace to the compliance call', async () => {
    const calls = mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Compliance Scan/ }))
    await waitFor(() =>
      expect(
        calls.some(url =>
          url === `/supercred/agents/agent-cardvault/compliance?namespace=${FLUX_NS}`,
        ),
      ).toBe(true),
    )
    expect(await screen.findByText('security-context-present')).toBeInTheDocument()
  })

  it('passes the agent namespace to the stun call', async () => {
    const calls = mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Stun Agent/ }))
    await waitFor(() =>
      expect(
        calls.some(url => url === `/supercred/agents/agent-cardvault/stun?namespace=${FLUX_NS}`),
      ).toBe(true),
    )
    expect(await screen.findByTestId('supercred-stun-result')).toHaveTextContent(/credentials revoked/)
  })

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
    await screen.findByText('Cardvault Agent')
    expect(screen.queryByTestId('supercred-phase-warning')).not.toBeInTheDocument()
  })

  it('renders a fetch failure without crashing', async () => {
    mockFetch({ agentsError: new Error('proxy unreachable') })
    renderPage()
    await refresh()
    expect(await screen.findByTestId('supercred-error')).toHaveTextContent(/proxy unreachable/)
    expect(screen.getByRole('heading', { level: 1, name: /SuperCred Demo/ })).toBeInTheDocument()
  })

  it('names the real Makefile targets in the demo steps', async () => {
    mockFetch({ agents: [] })
    renderPage()
    const steps = screen.getByTestId('supercred-demo-steps')
    expect(steps).toHaveTextContent('make demo-signalloom-supercred-1')
    expect(steps).toHaveTextContent('make demo-signalloom-supercred-2')
    expect(steps).toHaveTextContent('make demo-signalloom-supercred-5')
    expect(steps).not.toHaveTextContent('demo-supercred-step1')
  })
})
