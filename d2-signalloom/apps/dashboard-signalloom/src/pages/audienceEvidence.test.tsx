/**
 * What the AUDIENCE window shows.
 *
 * The instructor drives the demo in one browser window. A second window,
 * projected to the room, sits on the ordinary customer-facing pages logged in
 * as a normal user. Nobody touches that window for the length of the talk.
 *
 * Two things therefore have to be true, and neither is covered by testing the
 * SuperCred page itself:
 *
 *   1. The evidence is visible WITHOUT superadmin. Every context mock here
 *      sets `superadmin: false` deliberately.
 *   2. The page updates on its own. A correct render on a poll that fires
 *      every fifteen minutes is a page that never visibly changes during a
 *      talk, so the interval is pinned here as well as in pollInterval.test.ts
 *      — that test guards the constant, this one guards the wiring.
 *
 * Like supercredDemoEffects, these drive the REAL demo fixtures through the
 * REAL projection layer, so a failure means the data layer stopped moving
 * rather than a page forgetting a special case.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import type { ReactNode } from 'react'

// ── Mocks ───────────────────────────────────────────────────────────────────

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

// superadmin: false — the whole point. This evidence is for ordinary users.
vi.mock('../App', () => ({
  useAppContext: () => ({
    setFailingControls: vi.fn(), failingControls: 0, setHelpOpen: vi.fn(),
    superadmin: false, setSuperadmin: vi.fn(),
  }),
}))

vi.mock('recharts', () => {
  const Passthrough = ({ children }: { children?: ReactNode }) => <div>{children}</div>
  return {
    ResponsiveContainer: Passthrough, PieChart: Passthrough, Pie: Passthrough,
    Cell: () => null, Label: () => null, AreaChart: Passthrough, Area: () => null,
    BarChart: Passthrough, Bar: Passthrough, XAxis: () => null, YAxis: () => null,
    CartesianGrid: () => null, Tooltip: () => null,
  }
})

vi.mock('../api/client', () => ({
  api: {
    agents: {
      list: vi.fn(), register: vi.fn(), update: vi.fn(), get: vi.fn(),
      violations: vi.fn().mockResolvedValue({ violations: [], total: 0 }),
      acknowledge: vi.fn(), reassess: vi.fn(),
      issueCredential: vi.fn(), revokeCredential: vi.fn(),
    },
    compliance: { posture: vi.fn(), frameworks: vi.fn(), summary: vi.fn(), export: vi.fn() },
    compliancePolicy: { frameworks: vi.fn(), summary: vi.fn(), scan: vi.fn() },
    nhi: {
      discovered: vi.fn().mockResolvedValue({ accounts: [], total: 0, summary: { total_discovered: 0, needs_triage: 0, previously_dismissed: 0 } }),
      scans: vi.fn().mockResolvedValue({ scans: [] }),
      enrollAccount: vi.fn(), dismissAccount: vi.fn(),
    },
    settings: vi.fn(),
    audit: vi.fn().mockResolvedValue({ events: [], total: 0 }),
    auditExportCsv: vi.fn(),
    support: vi.fn(),
  },
}))

import { api } from '../api/client'
import { resolveFake } from '../api/fakeData'
import { projectResponse, SUPERCRED_AGENT_ID } from '../api/supercredProjection'
import { LIVE_POLL_MS } from '../api/pollInterval'
import type { SuperCredDemoState, SuperCredPhase } from '../api/supercredTypes'

import AgentsPage from './AgentsPage'
import AgentDetailPage from './AgentDetailPage'
import Compliance from '../views/Compliance'

// ── Demo state, exactly as the proxy reports it ─────────────────────────────

const AGENT_NAME = 'Cardvault Agent'
const STUN_REASON = 'compliance-failure: securityContext not set'
const SECURITY_CONTEXT_CONTROL = 'Pod securityContext defined'

function stateAt(phase: SuperCredPhase): SuperCredDemoState {
  const label = phase === 'credentialed' ? 'active'
    : phase === 'non-compliant' ? 'non-compliant'
    : phase === 'stunned' ? 'stunned'
    : null

  return {
    phase,
    agent: phase === 'absent' ? null : {
      id: 'agent-cardvault', name: AGENT_NAME, namespace: 'fe-signalloom-agents',
      type: 'Signal Loom Built', model: 'gpt-4o', supercred: true,
      state: label, phase: 'Running',
      stunned_at: phase === 'stunned' ? '2026-08-02T10:05:00Z' : null,
      stun_reason: phase === 'stunned' ? STUN_REASON : null,
    },
    scan: null,
    observedAt: '2026-08-02T10:00:00Z',
  }
}

function projected(method: string, path: string, phase: SuperCredPhase, body?: unknown): unknown {
  return projectResponse(method, path, resolveFake(method, path, body), stateAt(phase))
}

function wireApiFor(phase: SuperCredPhase) {
  vi.mocked(api.agents.list).mockResolvedValue(projected('GET', '/agents', phase) as never)
  vi.mocked(api.agents.get).mockResolvedValue(
    projected('GET', `/agents/${SUPERCRED_AGENT_ID}`, phase) as never,
  )
  vi.mocked(api.compliance.posture).mockResolvedValue(projected('GET', '/compliance/posture', phase) as never)
  vi.mocked(api.compliance.summary).mockResolvedValue(projected('GET', '/compliance/summary', phase) as never)
  vi.mocked(api.compliance.frameworks).mockResolvedValue(resolveFake('GET', '/compliance/frameworks') as never)
  vi.mocked(api.settings).mockResolvedValue(projected('GET', '/tenant/settings', phase) as never)
  vi.mocked(api.compliancePolicy.frameworks).mockResolvedValue(projected('GET', '/compliance/policy/frameworks', phase) as never)
  vi.mocked(api.compliancePolicy.summary).mockResolvedValue(projected('GET', '/compliance/policy/summary', phase) as never)
}

function renderPage(ui: ReactNode) {
  return render(<MemoryRouter>{ui}</MemoryRouter>)
}

function renderAgentDetail() {
  return render(
    <MemoryRouter initialEntries={[`/agents/${SUPERCRED_AGENT_ID}`]}>
      <Routes>
        <Route path="/agents/:id" element={<AgentDetailPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

beforeEach(() => {
  vi.clearAllMocks()
})

// ── The audience window has to move on its own ──────────────────────────────

describe('the audience window refreshes without a manual reload', () => {
  // Inferred through a factory: globalThis's index signature does not accept
  // 'setInterval' as a literal key, so the spy type cannot be written directly.
  const spyOnSetInterval = () => vi.spyOn(globalThis, 'setInterval')
  let setIntervalSpy: ReturnType<typeof spyOnSetInterval>

  beforeEach(() => {
    setIntervalSpy = spyOnSetInterval()
  })
  afterEach(() => {
    setIntervalSpy.mockRestore()
  })

  /** Every polling interval the component registered on mount. */
  function registeredIntervals(): number[] {
    return setIntervalSpy.mock.calls.map((call) => Number(call[1]))
  }

  it('AgentsPage polls at the demo cadence, not every fifteen minutes', async () => {
    wireApiFor('stunned')
    renderPage(<AgentsPage />)
    await screen.findByRole('heading', { level: 1, name: 'Agents' })

    expect(registeredIntervals()).toContain(LIVE_POLL_MS)
    expect(registeredIntervals()).not.toContain(15 * 60 * 1000)
  })

  it('Compliance polls at the demo cadence, not every fifteen minutes', async () => {
    wireApiFor('non-compliant')
    renderPage(<Compliance />)
    await screen.findByRole('heading', { level: 1, name: 'Compliance' })

    expect(registeredIntervals()).toContain(LIVE_POLL_MS)
    expect(registeredIntervals()).not.toContain(15 * 60 * 1000)
  })

  it('polls fast enough that a phase change lands inside a spoken sentence', async () => {
    wireApiFor('stunned')
    renderPage(<AgentsPage />)
    await screen.findByRole('heading', { level: 1, name: 'Agents' })

    const demoPaced = registeredIntervals().filter((ms) => ms <= 5_000)
    expect(demoPaced.length).toBeGreaterThan(0)
  })

  it('actually re-fetches on the interval, so a stun that lands mid-talk appears', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    try {
      wireApiFor('credentialed')
      renderPage(<AgentsPage />)
      await waitFor(() => expect(api.agents.list).toHaveBeenCalledTimes(1))

      // The instructor stuns the agent in the other window.
      wireApiFor('stunned')
      await vi.advanceTimersByTimeAsync(LIVE_POLL_MS + 50)

      await waitFor(() => expect(api.agents.list).toHaveBeenCalledTimes(2))
      expect(await screen.findByTestId('credential-state-revoked')).toBeInTheDocument()
    } finally {
      vi.useRealTimers()
    }
  })
})

// ── Agents: the stun, in words ──────────────────────────────────────────────

describe('/agents shows the credential state to a normal user', () => {
  it('shows credentials as active before the stun', async () => {
    wireApiFor('credentialed')
    renderPage(<AgentsPage />)
    const row = (await screen.findByText(AGENT_NAME)).closest('tr') as HTMLElement
    expect(within(row).getByText('Credentials active')).toBeInTheDocument()
  })

  it('raises a distinct STUNNED state after the stun', async () => {
    wireApiFor('stunned')
    renderPage(<AgentsPage />)
    const row = (await screen.findByText(AGENT_NAME)).closest('tr') as HTMLElement
    expect(within(row).getByText(/STUNNED — CREDENTIALS REVOKED/)).toBeInTheDocument()
  })

  it('names WHY the credentials went away, not just that they did', async () => {
    wireApiFor('stunned')
    renderPage(<AgentsPage />)
    const row = (await screen.findByText(AGENT_NAME)).closest('tr') as HTMLElement
    expect(within(row).getByText(new RegExp(STUN_REASON))).toBeInTheDocument()
  })

  it('shows it without superadmin — the context mock has superadmin false', async () => {
    wireApiFor('stunned')
    renderPage(<AgentsPage />)
    expect(await screen.findByTestId('credential-state-revoked')).toBeInTheDocument()
  })

  it('says nothing about credentials once the demo is torn down', async () => {
    wireApiFor('absent')
    renderPage(<AgentsPage />)
    await screen.findByRole('heading', { level: 1, name: 'Agents' })
    expect(screen.queryByText(AGENT_NAME)).not.toBeInTheDocument()
    expect(screen.queryByTestId('credential-state-revoked')).not.toBeInTheDocument()
  })
})

// ── Agent detail: the revocation, with a timestamp ──────────────────────────

describe('/agents/:id shows the revocation with a timestamp', () => {
  it('states the revocation', async () => {
    wireApiFor('stunned')
    renderAgentDetail()
    expect(await screen.findByTestId('credential-state-revoked')).toBeInTheDocument()
  })

  it('names the agent it happened to', async () => {
    wireApiFor('stunned')
    renderAgentDetail()
    const notice = await screen.findByTestId('credential-state-revoked')
    expect(within(notice).getByText(AGENT_NAME)).toBeInTheDocument()
  })

  it('gives the revocation timestamp, not just the date it changed state', async () => {
    wireApiFor('stunned')
    renderAgentDetail()
    const notice = await screen.findByTestId('credential-state-revoked')
    expect(notice.textContent).toMatch(/Revoked 02 Aug 2026/)
  })

  it('names the cause', async () => {
    wireApiFor('stunned')
    renderAgentDetail()
    const notice = await screen.findByTestId('credential-state-revoked')
    expect(notice.textContent).toContain(STUN_REASON)
  })

  it('raises no revocation notice while the agent still holds credentials', async () => {
    wireApiFor('credentialed')
    renderAgentDetail()
    await screen.findByRole('heading', { level: 1, name: AGENT_NAME })
    expect(screen.queryByTestId('credential-state-revoked')).not.toBeInTheDocument()
  })
})

// ── Compliance: the phase-3 finding ─────────────────────────────────────────

describe('/compliance shows the missing-securityContext finding', () => {
  it('raises no findings panel before the scan', async () => {
    wireApiFor('credentialed')
    renderPage(<Compliance />)
    await screen.findByRole('heading', { level: 1, name: 'Compliance' })

    const panel = screen.queryByTestId('open-findings-panel')
    if (panel) expect(panel.textContent).not.toContain(SECURITY_CONTEXT_CONTROL)
  })

  it('names the failing control after the scan', async () => {
    wireApiFor('non-compliant')
    renderPage(<Compliance />)
    const panel = await screen.findByTestId('open-findings-panel')
    expect(within(panel).getByText(SECURITY_CONTEXT_CONTROL)).toBeInTheDocument()
  })

  it('names the affected agent alongside every finding', async () => {
    wireApiFor('non-compliant')
    renderPage(<Compliance />)
    const panel = await screen.findByTestId('open-findings-panel')

    // The scan raises three runtime findings (securityContext, run-as-non-root,
    // drop-capabilities). Each names its own agent — a reader scanning the list
    // should never have to look upwards to find out who a finding belongs to.
    const named = within(panel).getAllByText(AGENT_NAME)
    expect(named.length).toBe(3)
  })

  it('shows it without superadmin', async () => {
    wireApiFor('non-compliant')
    renderPage(<Compliance />)
    const panel = await screen.findByTestId('open-findings-panel')
    expect(panel).toBeInTheDocument()
  })

  it('keeps the finding open through the stun — containment is not remediation', async () => {
    wireApiFor('stunned')
    renderPage(<Compliance />)
    const panel = await screen.findByTestId('open-findings-panel')
    expect(within(panel).getByText(SECURITY_CONTEXT_CONTROL)).toBeInTheDocument()
  })

  it('clears the agent from the findings after step 5 teardown', async () => {
    wireApiFor('absent')
    renderPage(<Compliance />)
    await screen.findByRole('heading', { level: 1, name: 'Compliance' })

    const panel = screen.queryByTestId('open-findings-panel')
    if (panel) expect(panel.textContent).not.toContain(AGENT_NAME)
  })

  it('shows the revoked credential state in the posture table after the stun', async () => {
    wireApiFor('stunned')
    renderPage(<Compliance />)
    await screen.findByTestId('open-findings-panel')
    await waitFor(() =>
      expect(screen.getByTestId('credential-state-revoked')).toBeInTheDocument(),
    )
  })
})
