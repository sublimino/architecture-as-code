/**
 * The audience window has to move on its own.
 *
 * The instructor drives the demo in one browser window. A second window,
 * projected to the room, sits on the ordinary customer pages and nobody
 * touches it for the length of the talk. Every page a demo phase lands on
 * therefore has to refresh itself:
 *
 *   phase 1 deploy      -> /agents               -> AgentsPage
 *   phase 2 credential  -> /credential-inventory -> CredentialInventoryPage
 *   phase 3 scan        -> /compliance           -> views/Compliance
 *   phase 4 stun        -> /agents               -> AgentsPage
 *   phase 5 teardown    -> /audit                -> views/AuditTrail
 *
 * pollInterval.test.ts guards the constant; this file guards that the pages
 * are actually wired to it, and that speeding them up 360x did not break the
 * pages being sped up.
 *
 * Split out of audienceEvidence.test.tsx: mounting these pages retains memory
 * per mount, and one file holding both the refresh mechanics and the evidence
 * assertions grew heavy enough to exhaust a 4GB heap. Separate files get
 * separate environments, and the two are separate concerns anyway.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import userEvent from '@testing-library/user-event'
import type { ReactNode } from 'react'

// ── Mocks ───────────────────────────────────────────────────────────────────

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

// superadmin: false — this evidence is for ordinary users.
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
    agents: { list: vi.fn(), register: vi.fn(), update: vi.fn() },
    compliance: { posture: vi.fn(), frameworks: vi.fn(), summary: vi.fn(), export: vi.fn() },
    compliancePolicy: { frameworks: vi.fn(), summary: vi.fn(), scan: vi.fn() },
    nhi: {
      discovered: vi.fn(), scans: vi.fn(), enrollAccount: vi.fn(), dismissAccount: vi.fn(),
    },
    settings: vi.fn(),
    audit: vi.fn(),
    auditExportCsv: vi.fn(),
    health: { crypto: vi.fn() },
  },
}))

import { api } from '../api/client'
import { resolveFake } from '../api/fakeData'
import { projectResponse } from '../api/supercredProjection'
import { LIVE_POLL_MS } from '../api/pollInterval'
import type { SuperCredDemoState, SuperCredPhase } from '../api/supercredTypes'

import AgentsPage from './AgentsPage'
import CredentialInventoryPage from './CredentialInventoryPage'
import Compliance from '../views/Compliance'
import AuditTrail from '../views/AuditTrail'

// ── Demo state, exactly as the proxy reports it ─────────────────────────────

const AGENT_NAME = 'Cardvault Agent'
const STUN_REASON = 'compliance-failure: securityContext not set'

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
  vi.mocked(api.compliance.posture).mockResolvedValue(projected('GET', '/compliance/posture', phase) as never)
  vi.mocked(api.compliance.summary).mockResolvedValue(projected('GET', '/compliance/summary', phase) as never)
  vi.mocked(api.compliance.frameworks).mockResolvedValue(resolveFake('GET', '/compliance/frameworks') as never)
  vi.mocked(api.settings).mockResolvedValue(projected('GET', '/tenant/settings', phase) as never)
}

function renderPage(ui: ReactNode) {
  return render(<MemoryRouter>{ui}</MemoryRouter>)
}

beforeEach(() => {
  vi.clearAllMocks()

  // clearAllMocks wipes recorded calls but NOT implementations, so a test that
  // makes a call reject leaves it rejecting for every test after it.
  vi.mocked(api.audit).mockResolvedValue({ events: [], total: 0 } as never)
  vi.mocked(api.health.crypto).mockResolvedValue({ proofs: [] } as never)
  vi.mocked(api.nhi.scans).mockResolvedValue({ scans: [] } as never)
  vi.mocked(api.nhi.discovered).mockResolvedValue({
    accounts: [], total: 0,
    summary: { total_discovered: 0, needs_triage: 0, previously_dismissed: 0 },
  } as never)
})

// ── Every phase target polls at demo speed ──────────────────────────────────

describe('every page a demo phase lands on refreshes without a manual reload', () => {
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

  /** Every polling interval registered on mount. */
  const registeredIntervals = () => setIntervalSpy.mock.calls.map((call) => Number(call[1]))

  it('phase 1 and 4 — AgentsPage polls at the demo cadence', async () => {
    wireApiFor('stunned')
    renderPage(<AgentsPage />)
    await screen.findByRole('heading', { level: 1, name: 'Agents' })

    expect(registeredIntervals()).toContain(LIVE_POLL_MS)
    expect(registeredIntervals()).not.toContain(15 * 60 * 1000)
  })

  it('phase 2 — CredentialInventoryPage polls at all', async () => {
    // It previously fetched once on mount and then showed that first answer
    // forever. A page that never polls is the same defect as one that polls
    // too slowly, and grepping for a slow constant would never have found it.
    renderPage(<CredentialInventoryPage />)
    await screen.findByRole('heading', { level: 1, name: /credential inventory/i })

    expect(registeredIntervals()).toContain(LIVE_POLL_MS)
  })

  it('phase 3 — Compliance polls at the demo cadence', async () => {
    wireApiFor('non-compliant')
    renderPage(<Compliance />)
    await screen.findByRole('heading', { level: 1, name: 'Compliance' })

    expect(registeredIntervals()).toContain(LIVE_POLL_MS)
    expect(registeredIntervals()).not.toContain(15 * 60 * 1000)
  })

  it('phase 5 — AuditTrail polls at the demo cadence', async () => {
    // The payoff page: the agent is gone, the record of what happened is not.
    renderPage(<AuditTrail />)
    await screen.findByRole('heading', { level: 1, name: 'Audit Trail' })

    expect(registeredIntervals()).toContain(LIVE_POLL_MS)
    expect(registeredIntervals()).not.toContain(15 * 60 * 1000)
  })

  it('polls fast enough that a phase change lands inside a spoken sentence', async () => {
    wireApiFor('stunned')
    renderPage(<AgentsPage />)
    await screen.findByRole('heading', { level: 1, name: 'Agents' })

    expect(registeredIntervals().filter((ms) => ms <= 5_000).length).toBeGreaterThan(0)
  })
})

// ── The refresh actually delivers new state ─────────────────────────────────

describe('a stun landing mid-talk reaches the audience window', () => {
  it('re-fetches on the interval and renders the new state', async () => {
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

// ── What a 360x faster poll would otherwise have broken on /audit ───────────
//
// Swapping AuditTrail's constant alone would have shipped two regressions.
// Both were harmless at fifteen minutes and are not at 2.5s.

describe('AuditTrail background refresh does not wreck the page it refreshes', () => {
  const EVENT = {
    id: 'evt-1', timestamp: '2026-08-02T10:05:00Z', event_type: 'agent.stunned',
    agent_id: 'agent-cardvault', agent_name: AGENT_NAME,
    actor: 'signal-loom-platform', detail: { reason: STUN_REASON },
  }

  // EventTag renders a <span role="button">, and the same event type also
  // appears as an <option> in the filter select — so the type name alone is
  // ambiguous. Role scoping is the idiom the existing AuditTrail tests use.
  const stunTag = () => screen.getByRole('button', { name: 'agent.stunned' })
  const auditCalls = () => vi.mocked(api.audit).mock.calls
  const pagesFetched = () => auditCalls().map((c) => (c[1] as { page: number }).page)

  /**
   * Render, then hand back the poll callback the page registered.
   *
   * Deliberately no fake timers. Testing Library's findBy and waitFor helpers
   * are themselves polling loops, and running one inside an auto-advancing
   * fake clock is its own hazard. Calling the registered callback invokes the
   * exact code path the interval would, with no clock involved at all.
   */
  async function renderAuditAndCapturePoll(): Promise<() => void> {
    const setIntervals = vi.spyOn(globalThis, 'setInterval')
    try {
      renderPage(<AuditTrail />)
      await screen.findByRole('button', { name: 'agent.stunned' })
      const call = setIntervals.mock.calls.find((c) => Number(c[1]) === LIVE_POLL_MS)
      if (!call) throw new Error('AuditTrail registered no poll at LIVE_POLL_MS')
      return call[0] as () => void
    } finally {
      setIntervals.mockRestore()
    }
  }

  it('never blanks the table into "Loading…" on a poll', async () => {
    vi.mocked(api.audit).mockResolvedValue({ events: [EVENT], total: 1 } as never)
    const poll = await renderAuditAndCapturePoll()

    await act(async () => { poll() })

    // The old fetchPage flipped `loading` on every refresh. At this cadence
    // that is a table that spends its life saying "Loading…".
    expect(screen.queryByText('Loading…')).not.toBeInTheDocument()
    // The bare-string check above went vacuous when the loading treatment
    // moved to LoadingState, whose copy is "Loading audit events…" — assert
    // on the component itself so this test still guards what it was written
    // to guard.
    expect(screen.queryByTestId('audit-load-state')).not.toBeInTheDocument()
    expect(stunTag()).toBeInTheDocument()
  })

  it('keeps the last good page when a poll fails, rather than showing an error', async () => {
    vi.mocked(api.audit).mockResolvedValue({ events: [EVENT], total: 1 } as never)
    const poll = await renderAuditAndCapturePoll()

    vi.mocked(api.audit).mockRejectedValue(new Error('ECONNRESET'))
    await act(async () => { poll() })

    // One blip must not replace the audit record with an error state in front
    // of the room.
    expect(stunTag()).toBeInTheDocument()
    expect(screen.queryByText(/Something went wrong/)).not.toBeInTheDocument()
  })

  it('stands the poll down past page 1 so "Load More" is not undone 2.5s later', async () => {
    // Asserted structurally rather than by advancing a clock: the property is
    // "no interval is registered while paged deeper", and watching
    // registration is both exact and instant.
    const setIntervals = vi.spyOn(globalThis, 'setInterval')
    const clearIntervals = vi.spyOn(globalThis, 'clearInterval')
    try {
      const many = Array.from({ length: 50 }, (_, i) => ({ ...EVENT, id: `evt-${i}` }))
      vi.mocked(api.audit).mockResolvedValue({ events: many, total: 200 } as never)
      renderPage(<AuditTrail />)
      const loadMore = await screen.findByRole('button', { name: /load more/i })

      const polls = () => setIntervals.mock.calls.filter((c) => Number(c[1]) === LIVE_POLL_MS)
      expect(polls().length).toBe(1)

      const clearsBefore = clearIntervals.mock.calls.length
      const pollsBefore = polls().length

      await userEvent.click(loadMore)
      await waitFor(() => expect(pagesFetched()).toContain(2))

      // Paging deeper tears the poll down and does not start a new one — a
      // refresh of page 1 would replace the rows just appended.
      expect(clearIntervals.mock.calls.length).toBeGreaterThan(clearsBefore)
      expect(polls().length).toBe(pollsBefore)
    } finally {
      setIntervals.mockRestore()
      clearIntervals.mockRestore()
    }
  })
})
