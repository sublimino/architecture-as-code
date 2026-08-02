/**
 * The step -> page effect matrix, as an executable spec.
 *
 * Running the SuperCred demo must visibly move the main (non-superadmin) pages
 * a customer actually uses. These tests drive each page through all five demo
 * steps and assert what changes.
 *
 * /audit is covered separately: the Stun -> Audit Trail write path is owned by
 * the stun-timeline workstream, which records real events through
 * api/demoActivity.ts rather than deriving them here. This file deliberately
 * does not project or assert on /audit.
 *
 * Crucially, they do it by feeding the pages the REAL demo fixtures put through
 * the REAL projection layer — `projectResponse(method, path, resolveFake(...))`
 * — exactly as client.ts does at its single request choke point. No page
 * contains a line of demo-specific code, so if one of these ever fails it means
 * the data layer stopped moving, not that a page forgot a special case.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import type { ReactNode } from 'react'

// ── Mocks ───────────────────────────────────────────────────────────────────

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

const setFailingControls = vi.fn()
vi.mock('../App', () => ({
  useAppContext: () => ({ setFailingControls, failingControls: 0, setHelpOpen: vi.fn(), superadmin: false, setSuperadmin: vi.fn() }),
}))

// Recharts renders SVG that jsdom cannot lay out; the demo assertions are all
// about numbers and table rows, not chart geometry.
vi.mock('recharts', () => {
  const Passthrough = ({ children }: { children?: ReactNode }) => <div>{children}</div>
  return {
    ResponsiveContainer: Passthrough,
    PieChart: Passthrough,
    Pie: Passthrough,
    Cell: () => null,
    Label: () => null,
    AreaChart: Passthrough,
    Area: () => null,
    BarChart: Passthrough,
    Bar: Passthrough,
    XAxis: () => null,
    YAxis: () => null,
    CartesianGrid: () => null,
    Tooltip: () => null,
  }
})

vi.mock('../api/client', () => ({
  api: {
    agents: { list: vi.fn(), register: vi.fn(), update: vi.fn() },
    compliance: { posture: vi.fn(), frameworks: vi.fn(), summary: vi.fn(), export: vi.fn() },
    compliancePolicy: { frameworks: vi.fn(), summary: vi.fn(), scan: vi.fn() },
    nhi: {
      discovered: vi.fn().mockResolvedValue({ accounts: [], total: 0, summary: { total_discovered: 0, needs_triage: 0, previously_dismissed: 0 } }),
      scans: vi.fn().mockResolvedValue({ scans: [] }),
      enrollAccount: vi.fn(),
      dismissAccount: vi.fn(),
    },
    settings: vi.fn(),
    audit: vi.fn(),
    auditExportCsv: vi.fn(),
  },
}))

import { api } from '../api/client'
import { resolveFake } from '../api/fakeData'
import { projectResponse } from '../api/supercredProjection'
import type { SuperCredDemoState, SuperCredPhase } from '../api/supercredTypes'

import AgentsPage from './AgentsPage'
import Compliance from '../views/Compliance'
import CompliancePolicyPage from './CompliancePolicyPage'
import AgentPosturePage from './AgentPosturePage'
import RiskExposurePage from './RiskExposurePage'

// ── The demo state each step produces ───────────────────────────────────────

/**
 * Mirrors what fake-integration-proxy reports at each step: the demo script
 * stamps `signalloom.ai/state` onto the agent pod and the proxy passes it
 * through verbatim.
 */
function stateAt(phase: SuperCredPhase): SuperCredDemoState {
  const label = phase === 'credentialed' ? 'active'
    : phase === 'non-compliant' ? 'non-compliant'
    : phase === 'stunned' ? 'stunned'
    : null

  return {
    phase,
    agent: phase === 'absent' ? null : {
      id: 'agent-cardvault',
      name: 'Cardvault Agent',
      namespace: 'fe-signalloom-agents',
      type: 'Signal Loom Built',
      model: 'gpt-4o',
      supercred: true,
      state: label,
      phase: 'Running',
      stunned_at: phase === 'stunned' ? '2026-08-02T10:05:00Z' : null,
      stun_reason: phase === 'stunned' ? 'compliance-failure: securityContext not set' : null,
    },
    scan: null,
    observedAt: '2026-08-02T10:00:00Z',
  }
}

/** Resolve a demo fixture and put it through the projection, exactly as client.ts does. */
function projected(method: string, path: string, phase: SuperCredPhase, body?: unknown): unknown {
  const base = resolveFake(method, path, body)
  return projectResponse(method, path, base, stateAt(phase))
}

/** Point every mocked API method at the projected fixtures for this demo step. */
function wireApiFor(phase: SuperCredPhase) {
  const scanBody = { namespace: 'default', policyVersion: 'v2.0', frameworks: [] }

  vi.mocked(api.agents.list).mockResolvedValue(projected('GET', '/agents', phase) as never)
  vi.mocked(api.compliance.posture).mockResolvedValue(projected('GET', '/compliance/posture', phase) as never)
  vi.mocked(api.compliance.summary).mockResolvedValue(projected('GET', '/compliance/summary', phase) as never)
  vi.mocked(api.compliance.frameworks).mockResolvedValue(resolveFake('GET', '/compliance/frameworks') as never)
  vi.mocked(api.settings).mockResolvedValue(projected('GET', '/tenant/settings', phase) as never)
  vi.mocked(api.compliancePolicy.frameworks).mockResolvedValue(projected('GET', '/compliance/policy/frameworks', phase) as never)
  vi.mocked(api.compliancePolicy.summary).mockResolvedValue(projected('GET', '/compliance/policy/summary', phase) as never)
  vi.mocked(api.compliancePolicy.scan).mockResolvedValue(
    projected('POST', '/compliance/policy/scan', phase, scanBody) as never,
  )
}

function renderPage(ui: ReactNode) {
  return render(<MemoryRouter>{ui}</MemoryRouter>)
}

/** The £ figure rendered by the stat card with this label. */
function statCardValue(label: string): number {
  const labelEl = screen.getByText(label)
  const card = labelEl.parentElement as HTMLElement
  const value = card.children[1].textContent ?? ''
  return Number(value.replace(/[£,]/g, ''))
}

const AGENT_NAME = 'Cardvault Agent'

/** Total inherent ALE across the 20 baseline policy checks in fakeComplianceData. */
const BASELINE_ALE = 227100
/** Total carried risk across the 5 failing baseline checks. */
const BASELINE_CARRIED = 98700

beforeEach(() => {
  vi.clearAllMocks()
})

// ─────────────────────────────────────────────────────────────────────────────
// 1. /agents — Agents
// ─────────────────────────────────────────────────────────────────────────────

describe('/agents reflects each demo step', () => {
  async function agentRow() {
    const cell = await screen.findByText(AGENT_NAME)
    return cell.closest('tr') as HTMLElement
  }

  it('step 0: the demo agent is absent before the demo starts', async () => {
    wireApiFor('absent')
    renderPage(<AgentsPage />)
    await screen.findByText('Inventory Agent')
    expect(screen.queryByText(AGENT_NAME)).not.toBeInTheDocument()
  })

  it('step 1 deploy: the new agent appears, enrolled', async () => {
    wireApiFor('deployed')
    renderPage(<AgentsPage />)
    expect(within(await agentRow()).getByText('enrolled')).toBeInTheDocument()
  })

  it('step 1 deploy: it raises the "enrolled agents not activated" alert', async () => {
    wireApiFor('deployed')
    renderPage(<AgentsPage />)
    await screen.findByText(AGENT_NAME)
    expect(screen.getByText(/enrolled agents not activated/)).toBeInTheDocument()
  })

  it('step 2 credential chain: the agent goes active and its identity controls pass', async () => {
    wireApiFor('credentialed')
    renderPage(<AgentsPage />)
    const row = await agentRow()
    expect(within(row).getByText('active')).toBeInTheDocument()
    // 7 of 12 controls satisfied once the SPIFFE -> OpenBao chain is verified.
    expect(within(row).getByText('51%')).toBeInTheDocument()
  })

  it('step 3 scan: the agent gains a violation marker and drops into critical posture', async () => {
    wireApiFor('non-compliant')
    renderPage(<AgentsPage />)
    await agentRow()
    expect(screen.getByText(/agents with new violations/)).toBeInTheDocument()
    expect(screen.getByText(/agents with critical posture/)).toBeInTheDocument()
  })

  it('step 3 scan: posture is worse than it was at step 2', async () => {
    wireApiFor('credentialed')
    const { unmount } = renderPage(<AgentsPage />)
    const before = within(await agentRow()).getByText(/%$/).textContent
    unmount()

    wireApiFor('non-compliant')
    renderPage(<AgentsPage />)
    const after = within(await agentRow()).getByText(/%$/).textContent

    expect(Number(after!.replace('%', ''))).toBeLessThan(Number(before!.replace('%', '')))
  })

  it('step 4 stun: the agent is suspended and raises the suspended alert', async () => {
    wireApiFor('stunned')
    renderPage(<AgentsPage />)
    expect(within(await agentRow()).getByText('suspended')).toBeInTheDocument()
    expect(screen.getByText(/suspended agents/)).toBeInTheDocument()
  })

  it('step 5 teardown: the agent is gone and the other agents are untouched', async () => {
    wireApiFor('absent')
    renderPage(<AgentsPage />)
    await screen.findByText('Inventory Agent')
    expect(screen.queryByText(AGENT_NAME)).not.toBeInTheDocument()
    expect(screen.getByText('Showing 6 of 6 agents')).toBeInTheDocument()
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// 2. /compliance — Compliance
// ─────────────────────────────────────────────────────────────────────────────

describe('/compliance reflects each demo step', () => {
  it('step 0: the estate shows only the baseline agents', async () => {
    wireApiFor('absent')
    renderPage(<Compliance />)
    await screen.findByRole('heading', { level: 1, name: 'Compliance' })
    expect(screen.queryByText(AGENT_NAME)).not.toBeInTheDocument()
  })

  it('step 1 deploy: the agent joins the posture table', async () => {
    wireApiFor('deployed')
    renderPage(<Compliance />)
    expect(await screen.findByText(AGENT_NAME)).toBeInTheDocument()
  })

  it('step 3 scan: the failing-control count rises by the three runtime findings', async () => {
    wireApiFor('credentialed')
    const { unmount } = renderPage(<Compliance />)
    await screen.findByText(AGENT_NAME)
    const beforeCalls = vi.mocked(setFailingControls).mock.calls
    const before = beforeCalls[beforeCalls.length - 1][0]
    unmount()
    vi.mocked(setFailingControls).mockClear()

    wireApiFor('non-compliant')
    renderPage(<Compliance />)
    await screen.findByText(AGENT_NAME)
    const afterCalls = vi.mocked(setFailingControls).mock.calls
    const after = afterCalls[afterCalls.length - 1][0]

    // The sidebar Compliance badge reads this number.
    expect(after).toBe(before + 3)
  })

  it('step 3 scan: the agent drops into the critical posture band', async () => {
    wireApiFor('non-compliant')
    renderPage(<Compliance />)
    const row = (await screen.findByText(AGENT_NAME)).closest('tr') as HTMLElement
    const score = Number(within(row).getByText(/%$/).textContent!.replace('%', ''))
    expect(score).toBeLessThan(50)
  })

  it('step 3 scan: the EU AI Act column stays passing, because the findings are NIST controls', async () => {
    // Not a gap — the three runtime findings (securityContext, run-as-non-root,
    // drop-capabilities) are NIST 800-53 SC controls, and the demo tenant has
    // only the EU AI Act framework activated in /tenant/settings. The failure
    // still reaches this page through the posture score and the failing-control
    // count that drives the sidebar badge. Activating NIST for the tenant would
    // additionally surface a failing framework column.
    wireApiFor('non-compliant')
    renderPage(<Compliance />)
    const row = (await screen.findByText(AGENT_NAME)).closest('tr') as HTMLElement
    expect(within(row).queryByText('fail')).not.toBeInTheDocument()
  })

  it('step 4 stun: the agent is shown as suspended', async () => {
    wireApiFor('stunned')
    renderPage(<Compliance />)
    const row = (await screen.findByText(AGENT_NAME)).closest('tr') as HTMLElement
    expect(within(row).getByText('suspended')).toBeInTheDocument()
  })

  it('step 5 teardown: the agent leaves the posture table', async () => {
    wireApiFor('absent')
    renderPage(<Compliance />)
    await screen.findByRole('heading', { level: 1, name: 'Compliance' })
    expect(screen.queryByText(AGENT_NAME)).not.toBeInTheDocument()
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// 3. /compliance/policies — Policy Compliance
// ─────────────────────────────────────────────────────────────────────────────

describe('/compliance/policies reflects each demo step', () => {
  async function totalChecks() {
    await screen.findByText('Total Checks')
    return statCardValue('Total Checks')
  }

  it('step 0: shows the 20 baseline checks', async () => {
    wireApiFor('absent')
    renderPage(<CompliancePolicyPage />)
    expect(await totalChecks()).toBe(20)
  })

  it('grows the evaluated check count at every step', async () => {
    const counts: number[] = []
    for (const phase of ['deployed', 'credentialed', 'non-compliant', 'stunned'] as SuperCredPhase[]) {
      wireApiFor(phase)
      const { unmount } = renderPage(<CompliancePolicyPage />)
      counts.push(await totalChecks())
      unmount()
    }
    expect(counts).toEqual([23, 27, 30, 32])
  })

  it('step 3 scan: the failed count rises by exactly three', async () => {
    wireApiFor('credentialed')
    const { unmount } = renderPage(<CompliancePolicyPage />)
    await screen.findByText('Failed')
    const before = statCardValue('Failed')
    unmount()

    wireApiFor('non-compliant')
    renderPage(<CompliancePolicyPage />)
    await screen.findByText('Failed')
    expect(statCardValue('Failed')).toBe(before + 3)
  })

  it('step 3 scan: exposure jumps; step 4 stun: exposure falls back', async () => {
    const exposure: Record<string, number> = {}
    for (const phase of ['credentialed', 'non-compliant', 'stunned'] as SuperCredPhase[]) {
      wireApiFor(phase)
      const { unmount } = renderPage(<CompliancePolicyPage />)
      await screen.findByText('Total Exposure')
      exposure[phase] = statCardValue('Total Exposure')
      unmount()
    }
    expect(exposure['non-compliant']).toBeGreaterThan(exposure.credentialed)
    expect(exposure.stunned).toBeLessThan(exposure['non-compliant'])
    expect(exposure.stunned).toBeGreaterThan(exposure.credentialed)
  })

  it('step 5 teardown: returns to the baseline', async () => {
    wireApiFor('absent')
    renderPage(<CompliancePolicyPage />)
    await screen.findByText('Total Exposure')
    expect(statCardValue('Total Exposure')).toBe(BASELINE_CARRIED)
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// 4. /compliance/posture — Agent Posture
// ─────────────────────────────────────────────────────────────────────────────

describe('/compliance/posture reflects each demo step', () => {
  it('step 0: shows only the baseline checks', async () => {
    wireApiFor('absent')
    renderPage(<AgentPosturePage />)
    expect(await screen.findByText('15/20')).toBeInTheDocument()
  })

  it('step 2 credential chain: the identity controls appear as passing checks', async () => {
    wireApiFor('credentialed')
    renderPage(<AgentPosturePage />)
    // 20 baseline + 3 governance + 4 identity = 27, of which 15 + 7 pass.
    expect(await screen.findByText('22/27')).toBeInTheDocument()
    expect(screen.getByText('Identification & Auth')).toBeInTheDocument()
  })

  it('step 3 scan: the three runtime findings land as failing checks', async () => {
    wireApiFor('non-compliant')
    renderPage(<AgentPosturePage />)
    expect(await screen.findByText('22/30')).toBeInTheDocument()
    expect(screen.getByText('System & Comms Protection')).toBeInTheDocument()
  })

  it('step 3 scan: the total exposure includes the new findings', async () => {
    wireApiFor('non-compliant')
    renderPage(<AgentPosturePage />)
    await screen.findByText('Total Exposure')
    // 98,700 baseline + 66,400 carried by the three failing runtime controls.
    expect(statCardValue('Total Exposure')).toBe(165100)
  })

  it('step 4 stun: response controls pass and exposure is contained', async () => {
    wireApiFor('stunned')
    renderPage(<AgentPosturePage />)
    expect(await screen.findByText('24/32')).toBeInTheDocument()
    // Carried risk falls to the documented containment residual.
    expect(statCardValue('Total Exposure')).toBe(108660)
  })

  it('step 5 teardown: the SuperCred control sets disappear', async () => {
    wireApiFor('absent')
    renderPage(<AgentPosturePage />)
    await screen.findByText('15/20')
    expect(screen.queryByText(/\[cardvault-agent\]/)).not.toBeInTheDocument()
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// 5. /compliance/risk — Risk Exposure
// ─────────────────────────────────────────────────────────────────────────────

describe('/compliance/risk reflects each demo step', () => {
  async function carriedRisk() {
    await screen.findByText('Carried Risk')
    return statCardValue('Carried Risk')
  }

  it('step 0: shows the baseline carried risk', async () => {
    wireApiFor('absent')
    renderPage(<RiskExposurePage />)
    expect(await carriedRisk()).toBe(BASELINE_CARRIED)
  })

  it('steps 1-2: the agent adds inherent risk but carries none', async () => {
    wireApiFor('credentialed')
    renderPage(<RiskExposurePage />)
    expect(await carriedRisk()).toBe(BASELINE_CARRIED)
    // Inherent ALE still rises — the controls exist whether or not they fail.
    expect(statCardValue('Total ALE')).toBeGreaterThan(BASELINE_ALE)
  })

  it('step 3 scan: carried risk jumps by the three failing controls', async () => {
    wireApiFor('non-compliant')
    renderPage(<RiskExposurePage />)
    expect(await carriedRisk()).toBe(165100)
  })

  it('step 4 stun: containing the agent visibly reduces carried risk', async () => {
    wireApiFor('stunned')
    renderPage(<RiskExposurePage />)
    expect(await carriedRisk()).toBe(108660)
  })

  it('walks carried risk up then down across the whole demo', async () => {
    const walk: number[] = []
    for (const phase of ['absent', 'deployed', 'credentialed', 'non-compliant', 'stunned'] as SuperCredPhase[]) {
      wireApiFor(phase)
      const { unmount } = renderPage(<RiskExposurePage />)
      walk.push(await carriedRisk())
      unmount()
    }
    expect(walk).toEqual([BASELINE_CARRIED, BASELINE_CARRIED, BASELINE_CARRIED, 165100, 108660])
  })

  it('step 5 teardown: risk returns cleanly to the baseline', async () => {
    wireApiFor('absent')
    renderPage(<RiskExposurePage />)
    expect(await carriedRisk()).toBe(BASELINE_CARRIED)
    expect(statCardValue('Total ALE')).toBe(BASELINE_ALE)
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// Cross-cutting: no page special-cases the demo
// ─────────────────────────────────────────────────────────────────────────────

describe('the pages stay demo-agnostic', () => {
  it('renders whatever the data layer reports, including a phase it has never seen', async () => {
    // A hand-built state the projection would never produce: an agent that is
    // stunned but whose name and namespace differ. The page must still render
    // it, because it does not know what a SuperCred agent is.
    const odd: SuperCredDemoState = {
      phase: 'stunned',
      agent: { id: 'agent-other', name: 'Totally Different Agent', namespace: 'elsewhere', supercred: true, state: 'stunned' },
      scan: null,
      observedAt: '2026-08-02T10:00:00Z',
    }
    vi.mocked(api.agents.list).mockResolvedValue(
      projectResponse('GET', '/agents', resolveFake('GET', '/agents'), odd) as never,
    )
    vi.mocked(api.compliancePolicy.scan).mockResolvedValue({ checks: [], summary: null } as never)

    renderPage(<AgentsPage />)
    expect(await screen.findByText('Totally Different Agent')).toBeInTheDocument()
  })

  it('shows the baseline unchanged when the demo is not running', async () => {
    wireApiFor('absent')
    renderPage(<AgentsPage />)
    await screen.findByText('Inventory Agent')
    // Every baseline agent still present, none renamed or reordered.
    for (const name of ['Inventory Agent', 'Triage Agent', 'Sandbox Agent', 'Remediation Agent', 'Vulnerability Scanner', 'Compliance Reporter']) {
      expect(screen.getByText(name)).toBeInTheDocument()
    }
  })
})
