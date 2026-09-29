/**
 * Kernel freeze split brain: a pod the kernel has frozen with no stun record.
 *
 * Live, three pods in fe-signalloom-agents sat at `cgroup.events frozen 1` with
 * no stun label and rendered as idle for up to 22 days. The badge must name the
 * split brain, and the idle wording must not survive next to it.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import AgentsPage from './AgentsPage'
import DiscoveryPage from './DiscoveryPage'
import AgentOverviewTab from '../components/AgentOverviewTab'
import { api } from '../api/client'
import { weaveApi } from '../api/weaveApi'
import { splitBrainFrozenAgentFixture } from '../api/fakeData'
import type { AgentResponse, DiscoveryWorkload } from '../types/api'
import { clearSignalSummaryCache } from '../hooks/useSignalSummary'

if (!('mocked' in vi)) {
  ;(vi as any).mocked = (fn: any) => fn
}

vi.mock('../auth/oidc', () => {
  const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
  return { useAuth0: () => ({ getAccessTokenSilently }) }
})

vi.mock('../api/agentClaim', () => ({
  claimDiscoveredAgent: vi.fn(),
  submitClaim: vi.fn(),
  releaseClaim: vi.fn(),
  listClaims: vi.fn().mockResolvedValue([]),
}))

vi.mock('../api/client', () => ({
  api: {
    agents: { list: vi.fn(), get: vi.fn(), register: vi.fn(), update: vi.fn(), claim: vi.fn(), autoclaimDiscovered: vi.fn() },
    discovery: { workloads: vi.fn(), autoclaimNamespace: vi.fn(), enroll: vi.fn(), dismiss: vi.fn() },
    nhi: {
      discovered: vi.fn().mockResolvedValue({ accounts: [], total: 0, summary: { total_discovered: 0, needs_triage: 0, previously_dismissed: 0 } }),
      scans: vi.fn().mockResolvedValue({ scans: [] }),
      enrollAccount: vi.fn(),
      dismissAccount: vi.fn(),
    },
    compliancePolicy: { scan: vi.fn() },
  },
}))

vi.mock('../api/weaveApi', () => ({
  weaveApi: {
    getObservations: vi.fn(),
    getActors: vi.fn(),
    getCoverage: vi.fn(),
    getActor: vi.fn(),
    promoteActor: vi.fn(),
    runCorrelation: vi.fn(),
  },
}))

function makeAgent(overrides: Partial<AgentResponse> = {}): AgentResponse {
  return {
    id: 'agent-abc-123',
    name: 'Invoice Bot',
    type: 'Signal Loom Built',
    owner: 'ops@acme.com',
    tenant_id: 'tenant-1',
    lifecycle_state: 'active',
    last_transition_at: '2026-06-01T00:00:00Z',
    last_transition_by: 'operator@signal-loom.ai',
    eu_ai_act_risk_class: 'limited',
    compliance_summary: { total_controls: 6, passing: 4, failing: 0, pending: 2, posture_score: 0.67 },
    created_at: '2026-05-01T00:00:00Z',
    record_class: 'registered',
    is_registry_linked: true,
    runtime: {
      namespace: 'default',
      framework: 'LangGraph',
      model: 'gpt-4o',
      execution_mode: 'autonomous',
    },
    responsibility: {
      owner_name: 'ops@acme.com',
      team: 'Operations',
      assignment_status: 'assigned',
    },
    identity: {
      spiffe_id: 'spiffe://cluster.local/ns/default/sa/invoice-bot',
      spiffe_status: 'linked',
      aliases: [],
    },
    operational_state: {
      runtime_status: 'running',
      containment: {
        process_freeze: 'inactive',
        network_isolation: 'inactive',
        credential_revocation: 'inactive',
      },
    },
    assessment_summary: {
      status: 'assessed',
      total_controls: 6,
      passed_controls: 4,
      failed_controls: 0,
      pending_controls: 2,
      normalized_score: 0.67,
    },
    attention: {
      level: 'none',
      highest_issue: null,
    },
    timestamps: {
      created_at: '2026-05-01T00:00:00Z',
      last_observed_at: '2026-06-01T12:00:00Z',
      last_transition_at: '2026-06-01T00:00:00Z',
    },
    ...overrides,
  }
}


function listOf(agents: AgentResponse[]) {
  ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
    agents,
    total: agents.length,
    source_health: 'healthy',
  })
}

function renderAgents() {
  return render(
    <MemoryRouter initialEntries={['/agents']}>
      <AgentsPage />
    </MemoryRouter>,
  )
}

const lancelot = splitBrainFrozenAgentFixture
const stunnedFrozen = makeAgent({
  id: 'agent-stunned-frozen',
  name: 'Stunned Frozen',
  lifecycle_state: 'stunned',
  kernel_state: 'frozen',
  kernel_observed_at: '2026-07-27T11:00:00Z',
  split_brain: [],
})
const unknownKernel = makeAgent({ id: 'agent-unknown-kernel', name: 'Unknown Kernel', kernel_state: 'unknown', split_brain: [] })

describe('split-brain fixture', () => {
  it('is shaped like agent-sir-lancelot: idle label, frozen kernel, observed 22 days before the demo clock', () => {
    expect(lancelot.lifecycle_state).toBe('idle')
    expect(lancelot.kernel_state).toBe('frozen')
    expect(lancelot.split_brain).toEqual(['kernel frozen without stun record'])
    const days = (Date.parse('2026-07-27T12:00:00Z') - Date.parse(lancelot.kernel_observed_at as string)) / 86_400_000
    expect(days).toBe(22)
  })
})

describe('AgentsPage kernel freeze state', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    ;(weaveApi as any).getObservations.mockResolvedValue([])
    ;(weaveApi as any).getActors.mockResolvedValue([])
  })

  it('(a) renders the split-brain badge and no idle or thawed wording', async () => {
    listOf([lancelot])
    renderAgents()
    const row = await screen.findByTestId(`agent-row-${lancelot.id}`)
    const badge = within(row).getByTestId(`kernel-state-badge-${lancelot.id}`)
    expect(badge).toHaveTextContent('FROZEN (no stun record)')
    expect(within(row).queryByText(/\bidle\b/i)).not.toBeInTheDocument()
    expect(within(row).queryByText(/THAWED/)).not.toBeInTheDocument()
  })

  it('(a) the drawer shows the split-brain badge and not idle', async () => {
    listOf([lancelot])
    renderAgents()
    await userEvent.click(await screen.findByTestId(`agent-row-${lancelot.id}`))
    const drawer = await screen.findByTestId('agent-evidence-drawer')
    expect(within(drawer).getAllByText('FROZEN (no stun record)').length).toBeGreaterThan(0)
    expect(within(drawer).queryByText(/\bidle\b/i)).not.toBeInTheDocument()
    expect(within(drawer).queryByText(/THAWED/)).not.toBeInTheDocument()
  })

  it('(b) stunned and kernel-frozen renders a neutral confirmation, not the split-brain badge', async () => {
    listOf([stunnedFrozen])
    renderAgents()
    const row = await screen.findByTestId(`agent-row-${stunnedFrozen.id}`)
    const badge = within(row).getByTestId(`kernel-state-badge-${stunnedFrozen.id}`)
    expect(badge).toHaveTextContent(/^frozen$/)
    expect(within(row).queryByText('FROZEN (no stun record)')).not.toBeInTheDocument()
  })

  it('(c) unknown kernel state renders no kernel badge', async () => {
    listOf([unknownKernel])
    renderAgents()
    const row = await screen.findByTestId(`agent-row-${unknownKernel.id}`)
    expect(within(row).queryByTestId(`kernel-state-badge-${unknownKernel.id}`)).not.toBeInTheDocument()
  })

  it('(d) the attention filter keeps split-brain pods and drops clean ones', async () => {
    const clean = makeAgent({ id: 'agent-clean', name: 'Clean Agent' })
    listOf([lancelot, clean])
    renderAgents()
    await screen.findByTestId(`agent-row-${clean.id}`)
    await userEvent.click(screen.getByTestId('agent-attention-filter-btn'))
    // Filtered-out rows stay mounted in an aria-hidden tbody (see AgentsPage.test.tsx).
    expect(screen.getByTestId(`agent-row-${lancelot.id}`).closest('tbody')).toHaveAttribute('aria-hidden', 'false')
    expect(screen.getByTestId(`agent-row-${clean.id}`).closest('tbody')).toHaveAttribute('aria-hidden', 'true')
  })
})

describe('DiscoveryPage kernel freeze state', () => {
  function workload(overrides: Partial<DiscoveryWorkload>): DiscoveryWorkload {
    return {
      id: 'w', name: 'w', source: 'local_k8s', source_label: 'Local K8s', namespace: 'fe-signalloom-agents',
      status: 'governed', owner: 'ops@acme.com', spiffe_id: null, model: null, last_seen_at: null,
      recommendations: { config: 'pass', content: 'pass', supply_chain: 'pass', eu_ai_act: 'pass' },
      metadata: {}, ...overrides,
    }
  }

  it('(d) the attention facet surfaces a governed, owned split-brain workload', async () => {
    const frozen = workload({
      id: 'agent-sir-lancelot', name: 'agent-sir-lancelot', kernel_state: 'frozen',
      kernel_observed_at: '2026-07-05T12:00:00Z', split_brain: ['kernel frozen without stun record'],
    })
    const clean = workload({ id: 'agent-clean', name: 'agent-clean', kernel_state: 'running', split_brain: [] })
    ;(api.discovery.workloads as ReturnType<typeof vi.fn>).mockResolvedValue({
      workloads: [frozen, clean], total: 2,
      summary: { total: 2, total_discovered: 0, in_review: 0, ignored: 0, revoked: 0, governed: 2, by_source: { local_k8s: 2 }, by_state: {} },
    })
    render(<MemoryRouter initialEntries={['/discovery']}><DiscoveryPage /></MemoryRouter>)
    const row = await screen.findByTestId('discovery-row-agent-sir-lancelot')
    expect(within(row).getByTestId('kernel-state-badge-agent-sir-lancelot')).toHaveTextContent('FROZEN (no stun record)')
    await userEvent.click(screen.getByTestId('discovery-attention-facet-btn'))
    expect(screen.getByTestId('discovery-row-agent-sir-lancelot')).toBeInTheDocument()
    expect(screen.queryByTestId('discovery-row-agent-clean')).not.toBeInTheDocument()
  })
})

describe('kernel telemetry tags read cgroup_state from the sentinel annotation', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    ;(weaveApi as any).getObservations.mockResolvedValue([])
    ;(weaveApi as any).getActors.mockResolvedValue([])
  })

  const suspendedUnknown = makeAgent({
    id: 'agent-suspended-unknown',
    name: 'Suspended Unknown',
    lifecycle_state: 'suspended',
    kernel_state: 'unknown',
    kernel_telemetry: { cgroup_state: 'unknown', traffic_control_state: 'unknown', source: 'unavailable' },
  })
  const frozenNoTc = makeAgent({
    id: 'agent-frozen-no-tc',
    name: 'Frozen No TC',
    lifecycle_state: 'stunned',
    kernel_state: 'frozen',
    kernel_telemetry: { cgroup_state: 'frozen', traffic_control_state: 'unknown', source: 'sentinel-annotation' },
  })
  const thawedNoTc = makeAgent({
    id: 'agent-thawed-no-tc',
    name: 'Thawed No TC',
    kernel_state: 'running',
    kernel_telemetry: { cgroup_state: 'thawed', traffic_control_state: 'unknown', source: 'sentinel-annotation' },
  })
  const noTelemetry = makeAgent({ id: 'agent-no-telemetry', name: 'No Telemetry', kernel_state: 'unknown', kernel_telemetry: null })

  it('a suspended agent with unknown kernel state shows neither FROZEN nor THAWED', async () => {
    listOf([suspendedUnknown])
    renderAgents()
    const row = await screen.findByTestId(`agent-row-${suspendedUnknown.id}`)
    expect(within(row).queryByText(/cgroup: FROZEN/)).not.toBeInTheDocument()
    expect(within(row).queryByText(/THAWED/)).not.toBeInTheDocument()
    expect(within(row).queryByText(/TC: DROP/)).not.toBeInTheDocument()
  })

  it('a sentinel-observed freeze shows cgroup FROZEN but claims nothing about TC', async () => {
    listOf([frozenNoTc])
    renderAgents()
    const row = await screen.findByTestId(`agent-row-${frozenNoTc.id}`)
    expect(within(row).getByText('cgroup: FROZEN')).toBeInTheDocument()
    expect(within(row).queryByText(/TC: DROP/)).not.toBeInTheDocument()
  })

  it('an observed thaw shows THAWED but not TC PASS', async () => {
    listOf([thawedNoTc])
    renderAgents()
    const row = await screen.findByTestId(`agent-row-${thawedNoTc.id}`)
    expect(within(row).getByText('cgroup: THAWED')).toBeInTheDocument()
    expect(within(row).queryByText(/TC: PASS/)).not.toBeInTheDocument()
  })

  it('no telemetry renders no THAWED or PASS in the row, the drawer or the overview tab', async () => {
    listOf([noTelemetry])
    renderAgents()
    const row = await screen.findByTestId(`agent-row-${noTelemetry.id}`)
    expect(within(row).queryByText(/THAWED|TC: PASS/)).not.toBeInTheDocument()
    await userEvent.click(row)
    const drawer = await screen.findByTestId('agent-evidence-drawer')
    expect(within(drawer).queryByText(/THAWED|TC: PASS/)).not.toBeInTheDocument()
  })

  it('the overview tab renders nothing for unknown telemetry', () => {
    render(<MemoryRouter><AgentOverviewTab agent={noTelemetry} /></MemoryRouter>)
    expect(screen.queryByText(/THAWED|TC: PASS/)).not.toBeInTheDocument()
  })
})
