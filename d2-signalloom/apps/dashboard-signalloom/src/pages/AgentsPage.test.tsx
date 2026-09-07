/**
 * Tests for SFAGENTS-P1-6: Operational Inventory Table & StatCards.
 * Covers:
 * - 7-column operational table headers & cells
 * - 4 StatCards (Needs Attention, Identity Coverage, Observed Workloads, Evidence Coverage)
 * - Truthful UI language: 'Not assessed', 'Unassigned', 'Registry not linked', 'Source unavailable'
 * - Truthful kernel containment telemetry: cgroup FROZEN / TC DROP, Requested (Outcome unconfirmed)
 * - Compliance scan, agent registration, filtering, search, and signal summary
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import AgentsPage from './AgentsPage'
import { api } from '../api/client'
import type { AgentResponse, AgentListResponse } from '../types/api'
import { fakeWeaveData } from '../api/fakeWeaveData'
import { clearSignalSummaryCache } from '../hooks/useSignalSummary'

// ── Mocks ──────────────────────────────────────────────────────────────────

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

vi.mock('../api/client', () => ({
  api: {
    agents: {
      list: vi.fn(),
      register: vi.fn(),
      update: vi.fn(),
    },
    nhi: {
      discovered: vi.fn().mockResolvedValue({ accounts: [], total: 0, summary: { total_discovered: 0, needs_triage: 0, previously_dismissed: 0 } }),
      scans: vi.fn().mockResolvedValue({ scans: [] }),
      enrollAccount: vi.fn(),
      dismissAccount: vi.fn(),
    },
    compliancePolicy: {
      scan: vi.fn(),
    },
  },
}))

const mockWeaveApi = vi.hoisted(() => ({
  getObservations: vi.fn(),
  getActors: vi.fn(),
  getCoverage: vi.fn(),
  getActor: vi.fn(),
  promoteActor: vi.fn(),
  runCorrelation: vi.fn(),
}))

vi.mock('../api/weaveApi', () => ({
  weaveApi: mockWeaveApi,
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

function renderPage(initialEntries = ['/agents']) {
  return render(
    <MemoryRouter initialEntries={initialEntries}>
      <AgentsPage />
    </MemoryRouter>,
  )
}

describe('AgentsPage — Compliance Scan & Register', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [makeAgent()],
      total: 1,
      source_health: 'healthy',
      meta: {
        total_records: 1,
        operational_count: 1,
        registered_count: 1,
        discovered_count: 0,
        resolved_count: 0,
        fixture_count: 0,
      },
    } satisfies AgentListResponse)
  })

  it('renders the Scan Compliance button in the page header', async () => {
    renderPage()
    expect(await screen.findByRole('button', { name: /scan compliance/i })).toBeInTheDocument()
  })

  it('calls compliancePolicy.scan and shows scanning state on click', async () => {
    const scanResult = {
      checks: [],
      summary: { totalChecks: 0, passed: 0, failed: 0, currency: 'GBP', totalAle: { amount: 0, currency: 'GBP' }, totalVar95: { amount: 0, currency: 'GBP' }, totalTvar: { amount: 0, currency: 'GBP' }, totalCarried: { amount: 0, currency: 'GBP' }, scanTimestamp: '2026-08-01T00:00:00Z', frameworks: [] },
    }
    ;(api.compliancePolicy.scan as ReturnType<typeof vi.fn>).mockResolvedValue(scanResult)

    renderPage()
    const btn = await screen.findByRole('button', { name: /scan compliance/i })
    await userEvent.click(btn)

    await waitFor(() => expect(api.compliancePolicy.scan).toHaveBeenCalledTimes(1))
  })

  it('shows last scanned timestamp after a successful scan', async () => {
    const scanResult = {
      checks: [],
      summary: { totalChecks: 0, passed: 0, failed: 0, currency: 'GBP', totalAle: { amount: 0, currency: 'GBP' }, totalVar95: { amount: 0, currency: 'GBP' }, totalTvar: { amount: 0, currency: 'GBP' }, totalCarried: { amount: 0, currency: 'GBP' }, scanTimestamp: '2026-08-01T12:00:00Z', frameworks: [] },
    }
    ;(api.compliancePolicy.scan as ReturnType<typeof vi.fn>).mockResolvedValue(scanResult)

    renderPage()
    const btn = await screen.findByRole('button', { name: /scan compliance/i })
    await userEvent.click(btn)

    await waitFor(() => {
      expect(screen.getByText(/last scanned/i)).toBeInTheDocument()
    })
  })

  it('shows the auto-scan cron schedule note', async () => {
    renderPage()
    await screen.findByRole('button', { name: /scan compliance/i })
    expect(screen.getByText(/auto-scan every 15 minutes/i)).toBeInTheDocument()
  })

  it('renders the Register Agent button and opens registration modal', async () => {
    renderPage()
    const btn = await screen.findByRole('button', { name: /register agent/i })
    expect(btn).toBeInTheDocument()
    await userEvent.click(btn)

    const heading = screen.getByText('Register New Agent')
    expect(heading).toBeInTheDocument()
  })

  it('calls api.agents.register on form submit', async () => {
    ;(api.agents.register as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ name: 'New Bot' }))
    renderPage()

    const btn = await screen.findByRole('button', { name: /register agent/i })
    await userEvent.click(btn)

    const heading = screen.getByText('Register New Agent')
    const modal = heading.closest('.card')!
    const modalScope = within(modal as HTMLElement)

    const nameInput = modal.querySelector('input[required]') as HTMLInputElement
    await userEvent.type(nameInput, 'New Bot')

    const typeSelect = modalScope.getByRole('combobox')
    await userEvent.selectOptions(typeSelect, 'Custom')

    const submitBtn = modalScope.getAllByRole('button', { name: /register agent/i }).pop()!
    await userEvent.click(submitBtn)

    await waitFor(() => expect(api.agents.register).toHaveBeenCalledTimes(1))
  })
})

describe('AgentsPage — 4 StatCards (SFAGENTS-P1-6)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  it('renders the 4 StatCards: Needs Attention, Identity Coverage, Observed Workloads, Evidence Coverage', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        makeAgent({ name: 'Agent Alpha', lifecycle_state: 'active' }),
        makeAgent({ id: 'agent-2', name: 'Agent Beta', lifecycle_state: 'suspended', compliance_summary: { total_controls: 5, passing: 3, failing: 2, pending: 0, posture_score: 0.6 } }),
      ],
      total: 2,
      source_health: 'healthy',
      source_health_detail: {
        k8s_discovery: { status: 'healthy' },
        postgres_registry: { status: 'healthy' },
        crypto_proofs: { status: 'healthy' },
      },
      meta: {
        total_records: 2,
        operational_count: 2,
        registered_count: 2,
        discovered_count: 0,
        resolved_count: 0,
        fixture_count: 0,
      },
    } satisfies AgentListResponse)

    renderPage()

    expect(await screen.findByTestId('statcard-attention')).toBeInTheDocument()
    expect(screen.getByTestId('statcard-identity')).toBeInTheDocument()
    expect(screen.getByTestId('statcard-workloads')).toBeInTheDocument()
    expect(screen.getByTestId('statcard-evidence')).toBeInTheDocument()

    // Needs Attention card reflects failing controls
    const cardAttention = screen.getByTestId('statcard-attention')
    expect(within(cardAttention).getByText('Needs Attention')).toBeInTheDocument()
    expect(within(cardAttention).getByText(/2 failing controls/i)).toBeInTheDocument()

    // Identity Coverage card reflects 100% governed resolution
    const cardIdentity = screen.getByTestId('statcard-identity')
    expect(within(cardIdentity).getByText('Identity Coverage')).toBeInTheDocument()
    expect(within(cardIdentity).getByText('100%')).toBeInTheDocument()

    // Observed Workloads card reflects 2 active workloads
    const cardWorkloads = screen.getByTestId('statcard-workloads')
    expect(within(cardWorkloads).getByText('Observed Workloads')).toBeInTheDocument()
    expect(within(cardWorkloads).getByText('2')).toBeInTheDocument()

    // Evidence Coverage card reflects Healthy
    const cardEvidence = screen.getByTestId('statcard-evidence')
    expect(within(cardEvidence).getByText('Evidence Coverage')).toBeInTheDocument()
    expect(within(cardEvidence).getByText('Healthy')).toBeInTheDocument()
  })

  it('displays degraded/unavailable source status in Evidence Coverage card', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [makeAgent()],
      total: 1,
      source_health: 'degraded',
      source_health_detail: {
        k8s_discovery: { status: 'healthy' },
        postgres_registry: { status: 'healthy' },
        crypto_proofs: { status: 'degraded' },
      },
    } satisfies AgentListResponse)

    renderPage()

    const cardEvidence = await screen.findByTestId('statcard-evidence')
    expect(within(cardEvidence).getByText('Degraded')).toBeInTheDocument()
    expect(within(cardEvidence).getByText(/Proofs: degraded/i)).toBeInTheDocument()
  })
})

describe('AgentsPage — 7-Column Operational Inventory Table (SFAGENTS-P1-6)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  it('renders exactly the 7 column headers matching design spec', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [makeAgent()],
      total: 1,
    })
    renderPage()

    await screen.findByText('Invoice Bot')
    const ths = screen.getAllByRole('columnheader')
    expect(ths).toHaveLength(7)
    expect(ths[0]).toHaveTextContent('Agent')
    expect(ths[1]).toHaveTextContent('Runtime')
    expect(ths[2]).toHaveTextContent('Responsibility')
    expect(ths[3]).toHaveTextContent('Operational State')
    expect(ths[4]).toHaveTextContent('Attention')
    expect(ths[5]).toHaveTextContent('Identity & Evidence')
    expect(ths[6]).toHaveTextContent('Last Observed')
  })

  it('renders exactly 7 table cells (td) per row with rich operational metadata', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [makeAgent()],
      total: 1,
    })
    renderPage()

    const name = await screen.findByText('Invoice Bot')
    const row = name.closest('tr')!
    const tds = row.querySelectorAll('td')
    expect(tds).toHaveLength(7)

    // Column 1 (Agent): Name + Registered badge
    expect(tds[0]).toHaveTextContent('Invoice Bot')
    expect(tds[0]).toHaveTextContent('Registered')

    // Column 2 (Runtime): namespace/framework + model
    expect(tds[1]).toHaveTextContent('default')
    expect(tds[1]).toHaveTextContent('LangGraph')
    expect(tds[1]).toHaveTextContent('gpt-4o')

    // Column 3 (Responsibility): owner + team
    expect(tds[2]).toHaveTextContent('ops@acme.com')
    expect(tds[2]).toHaveTextContent('Operations')

    // Column 4 (Operational State): active lifecycle badge + kernel telemetry
    expect(tds[3]).toHaveTextContent('active')

    // Column 5 (Attention): passing control count
    expect(tds[4]).toHaveTextContent('4/6 passing')

    // Column 6 (Identity & Evidence): SPIFFE linkage
    expect(tds[5]).toHaveTextContent('SPIFFE linked')

    // Column 7 (Last Observed): relative timestamp
    expect(tds[6]).toBeInTheDocument()
  })

  it('correctly filters governed agents by lifecycle state chips', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        makeAgent({ name: 'Active Agent', lifecycle_state: 'active' }),
        makeAgent({ id: 'agent-2', name: 'Suspended Agent', lifecycle_state: 'suspended' }),
      ],
      total: 2,
    })
    renderPage()

    await screen.findByText('Active Agent')

    // Filter to suspended only
    await userEvent.click(screen.getByTestId('agent-lifecycle-filter-suspended'))

    expect(screen.getByText('Active Agent').closest('tbody')).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByText('Suspended Agent')).toBeInTheDocument()
  })

  it('restores the unfiltered rows after clearing search or chips', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        makeAgent({ name: 'Active Agent', lifecycle_state: 'active' }),
        makeAgent({ id: 'agent-2', name: 'Suspended Agent', lifecycle_state: 'suspended' }),
      ],
      total: 2,
    })
    renderPage()

    await screen.findByText('Active Agent')
    const search = screen.getByRole('textbox', { name: 'Search agents' })
    await userEvent.type(search, 'suspended')
    expect(screen.getByText('Active Agent').closest('tbody')).toHaveAttribute('aria-hidden', 'true')

    await userEvent.click(screen.getByRole('button', { name: 'Clear' }))
    expect(screen.getByText('Active Agent')).toBeInTheDocument()
    expect(screen.getByText('Suspended Agent')).toBeInTheDocument()
  })
})

describe('AgentsPage — Truthful Language Dictionary (SFAGENTS-P1-6)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  it('renders "Not assessed" when 0 controls are evaluated (never "Compliant" or "0%")', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        makeAgent({
          name: 'Unassessed Agent',
          compliance_summary: { total_controls: 0, passing: 0, failing: 0, pending: 0, posture_score: null },
          assessment_summary: { status: 'not_assessed', total_controls: 0, passed_controls: 0, failed_controls: 0, pending_controls: 0, normalized_score: null },
        }),
      ],
      total: 1,
    })
    renderPage()

    await screen.findByText('Unassessed Agent')
    expect(screen.getAllByText('Not assessed').length).toBeGreaterThanOrEqual(1)
    expect(screen.queryByText('Compliant')).not.toBeInTheDocument()
    expect(screen.queryByText('0%')).not.toBeInTheDocument()
  })

  it('renders "Unassigned" when owner metadata is absent on registered workload', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        makeAgent({
          name: 'Ownerless Agent',
          owner: null,
          responsibility: { owner_name: null, owner_id: null, team: null, assignment_status: 'unassigned' },
        }),
      ],
      total: 1,
    })
    renderPage()

    await screen.findByText('Ownerless Agent')
    expect(screen.getByText('Unassigned')).toBeInTheDocument()
  })

  it('renders "Registry not linked" when discovery record has no registry binding', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        makeAgent({
          name: 'Discovered Pod',
          owner: null,
          record_class: 'discovered',
          is_registry_linked: false,
          identity: { spiffe_id: null, spiffe_status: 'unlinked', aliases: [] },
          responsibility: { owner_name: null, owner_id: null, team: null, assignment_status: 'registry_unlinked' },
        }),
      ],
      total: 1,
    })
    renderPage()

    await screen.findByText('Discovered Pod')
    expect(screen.getByText('Registry not linked')).toBeInTheDocument()
    expect(screen.getByText('Observed workload')).toBeInTheDocument()
  })

  it('renders "Source unavailable" when primary collectors are offline', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [],
      total: 0,
      source_health: 'unavailable',
    } satisfies AgentListResponse)
    renderPage()

    expect(await screen.findByText(/Source unavailable/i)).toBeInTheDocument()
  })
})

describe('AgentsPage — Kernel Containment Telemetry (SFAGENTS-P1-6)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  it('renders "cgroup: FROZEN" and "TC: DROP" when kernel telemetry confirms isolation', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        makeAgent({
          id: 'agent-frozen-1',
          name: 'Frozen Workload',
          lifecycle_state: 'suspended',
          kernel_telemetry: {
            cgroup_state: 'frozen',
            traffic_control_state: 'drop',
            ebpf_active: true,
            observed_at: '2026-06-01T12:00:00Z',
          },
        }),
      ],
      total: 1,
    })
    renderPage()

    await screen.findByText('Frozen Workload')
    expect(screen.getByTestId('kernel-telemetry-cgroup-agent-frozen-1')).toHaveTextContent('cgroup: FROZEN')
    expect(screen.getByTestId('kernel-telemetry-tc-agent-frozen-1')).toHaveTextContent('TC: DROP')
  })

  it('renders "Requested (Outcome unconfirmed)" when containment is requested without kernel telemetry ACK', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        makeAgent({
          id: 'agent-unconfirmed-1',
          name: 'Stunned Workload',
          lifecycle_state: 'suspended',
          kernel_telemetry: null, // No kernel telemetry returned
        }),
      ],
      total: 1,
    })
    renderPage()

    await screen.findByText('Stunned Workload')
    expect(screen.getByTestId('kernel-telemetry-unconfirmed-agent-unconfirmed-1')).toHaveTextContent('Requested (Outcome unconfirmed)')
    expect(screen.queryByTestId('kernel-telemetry-cgroup-agent-unconfirmed-1')).not.toBeInTheDocument()
  })

  it('renders "cgroup: THAWED" and "TC: PASS" when normal active telemetry is observed', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        makeAgent({
          id: 'agent-active-1',
          name: 'Active Workload',
          lifecycle_state: 'active',
          kernel_telemetry: {
            cgroup_state: 'thawed',
            traffic_control_state: 'allow',
            ebpf_active: true,
          },
        }),
      ],
      total: 1,
    })
    renderPage()

    await screen.findByText('Active Workload')
    expect(screen.getByTestId('kernel-telemetry-cgroup-agent-active-1')).toHaveTextContent('cgroup: THAWED')
    expect(screen.getByTestId('kernel-telemetry-tc-agent-active-1')).toHaveTextContent('TC: PASS')
  })
})

describe('AgentsPage — Signal Summary Panel', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [makeAgent()],
      total: 1,
    })
  })

  it('renders the signal summary panel when signal data is available', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)
    renderPage()

    expect(await screen.findByTestId('signal-summary-panel')).toBeInTheDocument()
    expect(screen.getByTestId('agents-signal-badge')).toBeInTheDocument()
  })

  it('shows the View Weave button linking to the weave page', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)
    renderPage()

    const btn = await screen.findByRole('button', { name: /view weave/i })
    expect(btn).toBeInTheDocument()
    expect(btn).toHaveAttribute('title', 'View full Signal Weave correlation dashboard')
  })

  it('does not render the signal panel when no observations exist', async () => {
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
    renderPage()

    await screen.findByText('Invoice Bot')
    expect(screen.queryByTestId('signal-summary-panel')).not.toBeInTheDocument()
  })
})

describe('AgentsPage — Quick Evidence Side Drawer (SFAGENTS-P1-7)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  it('opens quick evidence side drawer when an agent row is clicked', async () => {
    const agent = makeAgent({
      id: 'agent-drawer-test-1',
      name: 'Drawer Test Workload',
      type: 'Signal Loom Built',
      runtime: {
        namespace: 'sec-ops',
        framework: 'kagent',
        execution_mode: 'autonomous',
        model: 'claude-3-7-sonnet',
        node: 'worker-node-1',
        pod_uid: 'pod-uid-test-1',
        service_account: 'test-sa',
        phase: 'Running',
      },
      responsibility: {
        owner_name: 'alice@signal-loom.ai',
        team: 'Platform Security',
        assignment_status: 'assigned',
      },
      identity: {
        spiffe_id: 'spiffe://cluster.local/ns/sec-ops/sa/test-sa',
        spiffe_status: 'linked',
        aliases: ['alias-alpha'],
      },
      attention: {
        level: 'critical',
        highest_issue: '2 failing controls detected',
      },
      compliance_summary: {
        total_controls: 5,
        passing: 3,
        failing: 2,
        pending: 0,
        posture_score: 0.6,
      },
      kernel_telemetry: {
        cgroup_state: 'frozen',
        traffic_control_state: 'drop',
        ebpf_active: true,
      },
    })

    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [agent],
      total: 1,
    })

    renderPage()

    await screen.findByText('Drawer Test Workload')
    expect(screen.queryByTestId('agent-evidence-drawer')).not.toBeInTheDocument()

    // Click on the agent row
    await userEvent.click(screen.getByTestId('agent-row-agent-drawer-test-1'))

    // Drawer should open
    expect(screen.getByTestId('agent-evidence-drawer')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-agent-name')).toHaveTextContent('Drawer Test Workload')
    expect(screen.getByTestId('drawer-agent-id')).toHaveTextContent('ID: agent-drawer-test-1')
    expect(screen.getByTestId('drawer-runtime-namespace')).toHaveTextContent('sec-ops')
    expect(screen.getByTestId('drawer-runtime-framework')).toHaveTextContent('kagent (autonomous)')
    expect(screen.getByTestId('drawer-responsibility-owner')).toHaveTextContent('alice@signal-loom.ai')
    expect(screen.getByTestId('drawer-spiffe-status')).toHaveTextContent('SPIFFE linked')
    expect(screen.getByTestId('drawer-kernel-cgroup')).toHaveTextContent('cgroup: FROZEN')
    expect(screen.getByTestId('drawer-kernel-tc')).toHaveTextContent('TC: DROP')
    expect(screen.getByTestId('drawer-posture-score')).toHaveTextContent('60%')
  })

  it('opens quick evidence side drawer via keyboard selection (Enter key)', async () => {
    const agent = makeAgent({
      id: 'agent-kb-test-1',
      name: 'Keyboard Select Agent',
    })

    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [agent],
      total: 1,
    })

    renderPage()

    await screen.findByText('Keyboard Select Agent')
    const row = screen.getByTestId('agent-row-agent-kb-test-1')

    fireEvent.keyDown(row, { key: 'Enter', code: 'Enter' })

    expect(screen.getByTestId('agent-evidence-drawer')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-agent-name')).toHaveTextContent('Keyboard Select Agent')
  })

  it('closes quick evidence drawer on close button click and on Escape key', async () => {
    const agent = makeAgent({
      id: 'agent-close-test-1',
      name: 'Dismissable Agent',
    })

    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [agent],
      total: 1,
    })

    renderPage()

    await screen.findByText('Dismissable Agent')
    await userEvent.click(screen.getByTestId('agent-row-agent-close-test-1'))

    expect(screen.getByTestId('agent-evidence-drawer')).toBeInTheDocument()

    // Click close button
    await userEvent.click(screen.getByTestId('agent-evidence-drawer-close'))
    expect(screen.queryByTestId('agent-evidence-drawer')).not.toBeInTheDocument()

    // Re-open and close with Escape
    await userEvent.click(screen.getByTestId('agent-row-agent-close-test-1'))
    expect(screen.getByTestId('agent-evidence-drawer')).toBeInTheDocument()

    fireEvent.keyDown(window, { key: 'Escape', code: 'Escape' })
    expect(screen.queryByTestId('agent-evidence-drawer')).not.toBeInTheDocument()
  })

  it('renders truthful language in drawer for unassessed and unlinked records', async () => {
    const discoveredAgent = makeAgent({
      id: 'agent-disc-drawer',
      name: 'Discovered Pod',
      record_class: 'discovered',
      is_registry_linked: false,
      owner: null,
      responsibility: undefined,
      compliance_summary: {
        total_controls: 0,
        passing: 0,
        failing: 0,
        pending: 0,
        posture_score: null,
      },
      assessment_summary: {
        status: 'not_assessed',
        total_controls: 0,
        passed_controls: 0,
        failed_controls: 0,
        pending_controls: 0,
        normalized_score: null,
      },
    })

    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [discoveredAgent],
      total: 1,
    })

    renderPage()

    await screen.findByText('Discovered Pod')
    await userEvent.click(screen.getByTestId('agent-row-agent-disc-drawer'))

    expect(screen.getByTestId('agent-evidence-drawer')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-responsibility-owner')).toHaveTextContent('Registry not linked')
    expect(screen.getByTestId('drawer-assessment-status')).toHaveTextContent('Not assessed')
    expect(screen.getByTestId('drawer-posture-score')).toHaveTextContent('Not assessed')
  })
})

describe('AgentsPage — URL Deep-Link Engine & Secondary Filters', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  it('initializes search and lifecycle filters from URL search params', async () => {
    const agentActive = makeAgent({ id: 'agent-act', name: 'Active Bot', lifecycle_state: 'active' })
    const agentDraft = makeAgent({ id: 'agent-drf', name: 'Draft Bot', lifecycle_state: 'draft' })

    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [agentActive, agentDraft],
      total: 2,
    })

    renderPage(['/agents?search=Active&lifecycle=active'])

    expect(await screen.findByText('Active Bot')).toBeInTheDocument()
    const rowAct = screen.getByTestId('agent-row-agent-act').closest('tbody')
    const rowDrf = screen.getByTestId('agent-row-agent-drf').closest('tbody')
    expect(rowAct).toHaveAttribute('aria-hidden', 'false')
    expect(rowDrf).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByRole('textbox', { name: 'Search agents' })).toHaveValue('Active')
  })

  it('opens agent evidence drawer when ?drawer= is present in URL', async () => {
    const agent = makeAgent({ id: 'agent-drawer-test', name: 'Drawer Bot' })
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [agent],
      total: 1,
    })

    renderPage(['/agents?drawer=agent-drawer-test'])

    expect(await screen.findByTestId('agent-evidence-drawer')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-agent-name')).toHaveTextContent('Drawer Bot')
  })
})

