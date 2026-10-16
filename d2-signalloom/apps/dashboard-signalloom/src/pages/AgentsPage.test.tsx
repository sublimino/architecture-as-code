/**
 * Tests for SFAGENTS-P1-6: Operational Inventory Table & StatCards.
 * Covers:
 * - 8-column compact operational table headers & cells
 * - 4 StatCards (Needs Attention, Identity Coverage, Observed Workloads, Evidence Coverage)
 * - Truthful UI language: 'Not assessed', 'Unassigned', 'Registry not linked', 'Source unavailable'
 * - Truthful kernel containment telemetry: cgroup FROZEN / TC DROP, Requested (Outcome unconfirmed)
 * - Compliance scan, agent registration, filtering, search, and signal summary
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor, within, fireEvent, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import axe from 'axe-core'
import AgentsPage from './AgentsPage'
import { api } from '../api/client'
import { claimDiscoveredAgent } from '../api/agentClaim'
import { weaveApi } from '../api/weaveApi'
import type { AgentResponse, AgentListResponse } from '../types/api'
import { fakeWeaveData } from '../api/fakeWeaveData'
import { clearSignalSummaryCache } from '../hooks/useSignalSummary'

// ── Mocks ──────────────────────────────────────────────────────────────────

if (!('mocked' in vi)) {
  ;(vi as any).mocked = (fn: any) => fn
}

const mockNavigate = vi.fn()
vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return {
    ...actual,
    useNavigate: () => mockNavigate,
  }
})

const mockGetAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
let mockUser: Record<string, unknown> | undefined
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently: mockGetAccessTokenSilently, user: mockUser }),
}))

// GET /api/v1/me is the authority for the session tenant. Without a stub the
// relative fetch rejects, which is the "server has not answered" case.
function stubMe(tenant: string, email = 'demo-user@signalloom.local') {
  vi.stubGlobal('fetch', vi.fn(async (url: string) => {
    if (String(url) === '/api/v1/me') {
      return new Response(JSON.stringify({ subject: 'sub', tenant, email, superadmin: false }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }
    throw new Error(`unexpected fetch ${String(url)}`)
  }))
}

afterEach(() => {
  vi.unstubAllGlobals()
  mockUser = undefined
})

vi.mock('../api/agentClaim', () => ({
  claimDiscoveredAgent: vi.fn(),
  submitClaim: vi.fn(),
  releaseClaim: vi.fn(),
  listClaims: vi.fn().mockResolvedValue([]),
}))

vi.mock('../api/client', () => ({
  api: {
    agents: {
      list: vi.fn(),
      get: vi.fn(),
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

const mockWeaveApi = weaveApi as any
const claimDiscoveredAgentMock = claimDiscoveredAgent as any
const claimApiMock = {
  claimDiscoveredAgent: claimDiscoveredAgentMock,
}

function withLabels(agent: AgentResponse, labels: Record<string, string>): AgentResponse {
  return { ...agent, labels } as AgentResponse
}

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

  it('renders the Register Agent button in the page header and not in the filter bar', async () => {
    renderPage()
    const headerBtn = await screen.findByTestId('header-register-agent-btn')
    expect(headerBtn).toBeInTheDocument()
    expect(headerBtn).toHaveTextContent('Register Agent')

    const filterGroup = screen.getByRole('group', { name: /filter agents by lifecycle state/i })
    const filterBar = filterGroup.parentElement!
    expect(within(filterBar).queryByRole('button', { name: /register agent/i })).toBeNull()
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

describe('AgentsPage — Compact Operational Inventory Table (SFAGENTS-P1-6)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  it('renders eight column headers with separate Observed and Actions', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [makeAgent()],
      total: 1,
    })
    renderPage()

    await screen.findByText('Invoice Bot')
    const ths = screen.getAllByRole('columnheader')
    expect(ths).toHaveLength(8)
    expect(ths[0]).toHaveTextContent('Agent')
    expect(ths[1]).toHaveTextContent('Runtime')
    expect(ths[2]).toHaveTextContent('Responsibility')
    expect(ths[3]).toHaveTextContent('Operational State')
    expect(ths[4]).toHaveTextContent('Attention')
    expect(ths[5]).toHaveTextContent('Identity & Evidence')
    expect(ths[6]).toHaveTextContent('Seen')
    expect(ths[6]).toHaveAttribute('aria-label', 'Observed')
    expect(ths[7]).toHaveTextContent('Actions')
  })

  it('renders eight table cells per row retaining rich operational metadata', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [makeAgent()],
      total: 1,
    })
    renderPage()

    const name = await screen.findByText('Invoice Bot')
    const row = name.closest('tr')!
    const tds = row.querySelectorAll('td')
    expect(tds).toHaveLength(8)

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
        makeAgent({ name: 'Active Agent', lifecycle_state: 'Governed' }),
        makeAgent({ id: 'agent-2', name: 'Suspended Agent', lifecycle_state: 'Suspended' }),
      ],
      total: 2,
    })
    renderPage()

    await screen.findByText('Active Agent')

    // Filter to suspended only
    await userEvent.click(screen.getByTestId('agent-lifecycle-filter-Suspended'))

    expect(screen.getByText('Active Agent').closest('tbody')).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByText('Suspended Agent')).toBeInTheDocument()
  })

  it('restores the unfiltered rows after clearing search or chips', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        makeAgent({ name: 'Active Agent', lifecycle_state: 'Governed' }),
        makeAgent({ id: 'agent-2', name: 'Suspended Agent', lifecycle_state: 'Suspended' }),
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

  it('strictly excludes shadow discovery records from the operational table', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        makeAgent({ id: 'gov-1', name: 'Governed Agent', record_class: 'registered', lifecycle_state: 'Governed' }),
        makeAgent({ id: 'shadow-1', name: 'Shadow Workload', record_class: 'discovery' as any, lifecycle_state: 'Suspended' }),
      ],
      total: 2,
    })
    renderPage()

    expect(await screen.findByText('Governed Agent')).toBeInTheDocument()
    expect(screen.queryByText('Shadow Workload')).not.toBeInTheDocument()
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

  it('renders "Registry not linked" and "Details" with whitespace separation without concatenation', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [
        makeAgent({
          id: 'agent-unlinked-spacing',
          name: 'Unlinked Pod',
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

    await screen.findByText('Unlinked Pod')
    const row = screen.getByTestId('agent-row-agent-unlinked-spacing')
    const cells = row.querySelectorAll('td')
    const responsibilityCell = cells[2]
    expect(responsibilityCell).toBeDefined()
    expect(responsibilityCell.textContent).not.toContain('Registry not linkedDetails')
    expect(responsibilityCell.textContent).toMatch(/Registry not linked\s+Details/)
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
    expect(screen.getByTestId('kernel-telemetry-unconfirmed-agent-unconfirmed-1')).toHaveTextContent(/^Unconfirmed$/)
    expect(screen.queryByTestId('kernel-telemetry-cgroup-agent-unconfirmed-1')).not.toBeInTheDocument()
    fireEvent.focus(screen.getByRole('button', { name: /Containment outcome details/ }))
    expect(screen.getByRole('tooltip')).toHaveTextContent('Requested (Outcome unconfirmed)')
    expect(screen.getByRole('tooltip')).toHaveTextContent('Containment requested but kernel telemetry observation is unconfirmed')
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

    await screen.findByTestId('agent-row-agent-drawer-test-1')
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

  it('provides direct links to the full agent dossier in Column 1 and Column 7 without opening the drawer', async () => {
    const agent = makeAgent({
      id: 'agent-nav-test-1',
      name: 'Direct Nav Agent',
    })

    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [agent],
      total: 1,
    })

    renderPage()

    await screen.findByText('Direct Nav Agent')

    // Column 1 link
    const agentLink = screen.getByTestId('agent-link-agent-nav-test-1')
    expect(agentLink).toBeInTheDocument()
    expect(agentLink.getAttribute('href')).toBe('/agents/agent-nav-test-1?tab=overview')

    // Column 7 Dossier action button
    const dossierBtn = screen.getByTestId('agent-dossier-btn-agent-nav-test-1')
    expect(dossierBtn).toBeInTheDocument()
    expect(dossierBtn.getAttribute('href')).toBe('/agents/agent-nav-test-1?tab=overview')

    // Clicking the direct link stops propagation and does not open the drawer
    await userEvent.click(agentLink)
    expect(screen.queryByTestId('agent-evidence-drawer')).not.toBeInTheDocument()
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

  it('does not render Live containment cockpit at the top of the agents page, but renders it in drawer when open', async () => {
    const agent = makeAgent({ id: 'agent-cockpit-check', name: 'Cockpit Check Agent' })
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [agent],
      total: 1,
    })

    // 1. On main /agents page, no cockpit at top of page
    const { unmount } = renderPage(['/agents'])
    await screen.findByRole('button', { name: /scan compliance/i })
    expect(screen.queryByTestId('agent-cockpit-section')).not.toBeInTheDocument()
    expect(screen.queryByText('Live containment cockpit')).not.toBeInTheDocument()
    unmount()

    // 2. When ?drawer= is present, cockpit is rendered inside the drawer
    renderPage(['/agents?drawer=agent-cockpit-check'])
    const drawer = await screen.findByTestId('agent-evidence-drawer')
    expect(drawer).toBeInTheDocument()
    expect(within(drawer).getByTestId('agent-cockpit-section')).toBeInTheDocument()
    expect(within(drawer).getByText('Live containment cockpit')).toBeInTheDocument()
  })

  it('opens agent evidence drawer via ?drawer= URL parameter and renders quantitative risk section without error', async () => {
    const agent = makeAgent({ id: '5d9d84b5-b7d5-50b8-8fcf-d2ae4cc74599', name: 'Risk Evaluated Agent' })
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [agent],
      total: 1,
    })

    renderPage(['/agents?drawer=5d9d84b5-b7d5-50b8-8fcf-d2ae4cc74599'])

    expect(await screen.findByTestId('agent-evidence-drawer')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-agent-name')).toHaveTextContent('Risk Evaluated Agent')

    // Quantitative Risk panel renders (or graceful non-crashing error state without mock network)
    await waitFor(() => {
      expect(
        screen.queryByTestId('drawer-section-risk') || screen.queryByTestId('drawer-section-risk-error')
      ).toBeInTheDocument()
    })

    // Verify it did not crash with unhandled 502/invalid upstream error
    expect(screen.queryByText(/invalid_upstream_response/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/policy-engine returned unparseable JSON/i)).not.toBeInTheDocument()
  })


  it('populates search and displays active-selector-badge from ?selector= param', async () => {
    const agent1 = makeAgent({ id: 'agent-planner', name: 'Trust Planner', identity: { spiffe_id: '', spiffe_status: 'linked', aliases: [], selectors: ['k8s:sa:planner'] } })
    const agent2 = makeAgent({ id: 'agent-triage', name: 'Trust Triage' })

    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [agent1, agent2],
      total: 2,
    })

    renderPage(['/agents?selector=k8s:sa:planner'])

    expect(await screen.findByText('Trust Planner')).toBeInTheDocument()
    expect(screen.getByTestId('active-selector-badge')).toBeInTheDocument()
    expect(screen.getByTestId('active-selector-badge')).toHaveTextContent('k8s:sa:planner')

    const row1 = screen.getByTestId('agent-row-agent-planner').closest('tbody')
    const row2 = screen.getByTestId('agent-row-agent-triage').closest('tbody')
    expect(row1).toHaveAttribute('aria-hidden', 'false')
    expect(row2).toHaveAttribute('aria-hidden', 'true')
  })

  it('populates search with prefix from ?id= param and clears on clear button click', async () => {
    const agent1 = makeAgent({ id: 'UUID-23-1245-124', name: 'Target Agent' })
    const agent2 = makeAgent({ id: 'other-agent', name: 'Other Agent' })

    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [agent1, agent2],
      total: 2,
    })

    renderPage(['/agents?id=UUID-23-1245-124'])

    expect(await screen.findByText('Target Agent')).toBeInTheDocument()
    expect(screen.getByTestId('active-selector-badge')).toHaveTextContent('id:UUID-23-1245-124')

    await userEvent.click(screen.getByTestId('clear-selector-button'))
    expect(screen.queryByTestId('active-selector-badge')).not.toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Search agents' })).toHaveValue('')
  })
})

describe('AgentsPage — Auto-Claim workflow (SLAC-P2-1)', () => {
  const discoveredAgent = () => makeAgent({
    id: 'discovered:claim-target',
    name: 'Kagent Reader',
    owner: null,
    record_class: 'discovered',
    is_registry_linked: false,
    namespace: 'fe-signalloom-agents',
    service_account: 'kagent-reader',
    framework: 'kagent',
    model_name: 'anthropic-claude',
    runtime: {
      namespace: 'fe-signalloom-agents',
      pod_name: 'kagent-k8s-reader',
      service_account: 'kagent-reader',
      framework: 'kagent',
      model: 'anthropic-claude',
    },
    identity: {
      spiffe_id: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-reader',
      spiffe_status: 'unlinked',
      aliases: [],
    },
    responsibility: {
      owner_name: null,
      owner_id: null,
      team: null,
      assignment_status: 'registry_unlinked',
    },
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

  const grantedClaim = {
    claim_id: 'claim-kagent-reader',
    status: 'granted' as const,
    spiffe_svid_verified: true,
    allocated_token_budget: 100000,
    signal_session_url: '/ws/agents/registry-agent/signal',
    ebpf_sentinel_bound: true,
    agent_id: 'registry-agent',
  }

  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  it('renders the secondary Auto-Claim action only for discovered or unlinked rows', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [
        discoveredAgent(),
        makeAgent({ id: 'unlinked-registered', name: 'Unlinked Registered', record_class: 'registered', is_registry_linked: false }),
        makeAgent({ id: 'governed', name: 'Governed Agent', record_class: 'resolved', is_registry_linked: true }),
      ],
      total: 3,
    })

    renderPage()

    const buttons = await screen.findAllByTestId('agent-auto-claim-btn')
    expect(buttons).toHaveLength(2)
    expect(screen.getByRole('button', { name: 'Claim Kagent Reader into governance' })).toHaveClass('btn-secondary')
    expect(screen.getByRole('button', { name: 'Claim Unlinked Registered into governance' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Claim Governed Agent into governance' })).not.toBeInTheDocument()
  })

  it('submits once, isolates the row click, and renders authoritative resolved posture without reload', async () => {
    let resolveClaim!: (value: typeof grantedClaim) => void
    claimApiMock.claimDiscoveredAgent.mockImplementation(() => new Promise(resolve => { resolveClaim = resolve }))
    const claimed = makeAgent({
      id: 'registry-agent',
      name: 'Kagent Reader',
      record_class: 'resolved',
      is_registry_linked: true,
      compliance_summary: { total_controls: 6, passing: 5, failing: 1, pending: 0, posture_score: 0.83 },
      assessment_summary: { status: 'not_assessed', total_controls: 0, passed_controls: 0, failed_controls: 0, pending_controls: 0, normalized_score: null },
    })
    vi.mocked(api.agents.list)
      .mockResolvedValueOnce({ agents: [discoveredAgent()], total: 1 })
      .mockResolvedValue({ agents: [claimed], total: 1 })
    vi.mocked(api.agents.get).mockResolvedValue(claimed)

    renderPage()
    const button = await screen.findByTestId('agent-auto-claim-btn')
    await userEvent.click(button)

    expect(button).toBeDisabled()
    expect(button).toHaveAttribute('aria-busy', 'true')
    expect(screen.getByTestId('agent-auto-claim-spinner-discovered:claim-target')).toBeInTheDocument()
    expect(screen.queryByTestId('agent-evidence-drawer')).not.toBeInTheDocument()
    fireEvent.click(button)
    expect(claimApiMock.claimDiscoveredAgent).toHaveBeenCalledTimes(1)
    expect(claimApiMock.claimDiscoveredAgent).toHaveBeenCalledWith(
      'test-token',
      'discovered:claim-target',
      {
        pod_name: 'kagent-k8s-reader',
        display_name: 'Kagent Reader',
        namespace: 'fe-signalloom-agents',
        spiffe_id: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-reader',
        harness: 'kagent',
        model: 'anthropic-claude',
        declared_tools: [],
        token_budget_limit: 100000,
        agent_id: 'discovered:claim-target',
      },
    )

    resolveClaim(grantedClaim)

    await waitFor(() => expect(api.agents.get).toHaveBeenCalledWith('test-token', 'registry-agent'))
    const resolvedRow = await screen.findByTestId('agent-row-registry-agent')
    expect(within(resolvedRow).getByText('Resolved')).toBeInTheDocument()
    expect(within(resolvedRow).getByText('83%')).toBeInTheDocument()
    expect(screen.queryByTestId('agent-auto-claim-btn')).not.toBeInTheDocument()
    expect(screen.getByTestId('agent-claim-toast')).toHaveAttribute('role', 'status')
    expect(screen.getByTestId('agent-claim-toast')).toHaveTextContent('Kagent Reader claimed into governance successfully.')
    expect(api.agents.list).toHaveBeenCalledTimes(2)
  })

  it('navigates to the onboarding tab with claim error details on claim failure instead of transient alert popup', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({ agents: [discoveredAgent()], total: 1 })
    claimApiMock.claimDiscoveredAgent.mockRejectedValue(new Error('Workload declares no signalloom.ai/model; refusing to record an invented model'))

    renderPage()
    await userEvent.click(await screen.findByTestId('agent-auto-claim-btn'))

    await waitFor(() => {
      expect(mockNavigate).toHaveBeenCalledWith(
        expect.stringContaining('/agents/discovered%3Aclaim-target?tab=onboarding&claim_error=')
      )
    })
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(api.agents.get).not.toHaveBeenCalled()
  })

  it('navigates to the onboarding tab on non-granted claim status instead of showing alert popup', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({ agents: [discoveredAgent()], total: 1 })
    claimApiMock.claimDiscoveredAgent.mockResolvedValue({ ...grantedClaim, status: 'pending-review' })

    renderPage()
    await userEvent.click(await screen.findByTestId('agent-auto-claim-btn'))

    await waitFor(() => {
      expect(mockNavigate).toHaveBeenCalledWith(
        expect.stringContaining('/agents/discovered%3Aclaim-target?tab=onboarding&claim_error=Claim%20was%20pending-review.')
      )
    })
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(api.agents.get).not.toHaveBeenCalled()
  })

  it('ignores a stale polling response that began before the successful claim', async () => {
    let resolveStaleList!: (value: AgentListResponse) => void
    const claimedAgent = makeAgent({
      id: 'registry-agent',
      name: 'Kagent Reader',
      record_class: 'resolved',
      is_registry_linked: true,
      compliance_summary: { total_controls: 6, passing: 5, failing: 1, pending: 0, posture_score: 0.83 },
    })
    vi.mocked(api.agents.list)
      .mockResolvedValueOnce({ agents: [discoveredAgent()], total: 1 })
      .mockImplementationOnce(() => new Promise(resolve => { resolveStaleList = resolve }))
      .mockResolvedValue({ agents: [claimedAgent], total: 1 })
    vi.mocked(api.compliancePolicy.scan).mockResolvedValue({
      checks: [],
      summary: {
        totalChecks: 0,
        passed: 0,
        failed: 0,
        currency: 'GBP',
        totalAle: { amount: 0, currency: 'GBP' },
        totalVar95: { amount: 0, currency: 'GBP' },
        totalTvar: { amount: 0, currency: 'GBP' },
        totalCarried: { amount: 0, currency: 'GBP' },
        scanTimestamp: '2026-09-08T12:00:00Z',
        frameworks: [],
      },
    })
    claimApiMock.claimDiscoveredAgent.mockResolvedValue(grantedClaim)
    vi.mocked(api.agents.get).mockResolvedValue(claimedAgent)

    renderPage()
    await screen.findByTestId('agent-auto-claim-btn')
    await userEvent.click(screen.getByRole('button', { name: /scan compliance/i }))
    await waitFor(() => expect(api.agents.list).toHaveBeenCalledTimes(2))
    await userEvent.click(screen.getByTestId('agent-auto-claim-btn'))
    await screen.findByTestId('agent-row-registry-agent')

    resolveStaleList({ agents: [discoveredAgent()], total: 1 })

    await waitFor(() => expect(screen.getByTestId('agent-row-registry-agent')).toHaveTextContent('Resolved'))
    expect(screen.queryByTestId('agent-auto-claim-btn')).not.toBeInTheDocument()
  })

  it('has zero axe-core violations in the Auto-Claim action cell', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({ agents: [discoveredAgent()], total: 1 })
    renderPage()

    const button = await screen.findByTestId('agent-auto-claim-btn')
    const actionCell = button.closest('td')
    expect(actionCell).not.toBeNull()
    const audit = await axe.run(actionCell as HTMLElement, {
      rules: { 'color-contrast': { enabled: false } },
    })
    expect(audit.violations).toEqual([])
  })
})

describe('AgentsPage: Sortability and Timestamps (SLMS-P3-1)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  it('renders relative observation with full timestamp and timezone accessible on focus', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [
        makeAgent({
          id: 'agent-ts-1',
          name: 'Timestamp Agent',
          timestamps: {
            last_observed_at: '2026-09-29T14:30:00Z',
          },
        }),
      ],
      total: 1,
    })
    renderPage()

    const tsCell = await screen.findByTestId('agent-full-timestamp-agent-ts-1')
    expect(tsCell).toHaveTextContent(/\d+[mhd] ago|just now|In future/)
    fireEvent.focus(tsCell)
    const tooltip = screen.getByRole('tooltip')
    expect(tooltip).toHaveTextContent(/29 Sept? 2026/)
    expect(tooltip).toHaveTextContent(/14:30:00|15:30:00/)
    expect(tooltip).toHaveTextContent('2026-09-29T14:30:00Z')
    expect(tooltip).toHaveTextContent('UTC')
    fireEvent.keyDown(tsCell, { key: 'Escape' })
    expect(screen.queryByRole('tooltip')).not.toBeInTheDocument()
  })

  it('sorts agents ascending and descending when clicking Operational State header', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [
        makeAgent({ id: 'agent-z', name: 'Zeta Agent', lifecycle_state: 'Suspended' }),
        makeAgent({ id: 'agent-a', name: 'Alpha Agent', lifecycle_state: 'Governed' }),
      ],
      total: 2,
    })
    renderPage()

    await screen.findByText('Alpha Agent')
    const sortHeader = screen.getByTestId('sort-header-lifecycle')

    // First click: asc (Governed before Suspended)
    await userEvent.click(sortHeader)
    let rows = screen.getAllByRole('button', { name: /View evidence for/i })
    expect(rows[0]).toHaveTextContent('Alpha Agent')
    expect(rows[1]).toHaveTextContent('Zeta Agent')

    // Second click: desc (Suspended before Governed)
    await userEvent.click(sortHeader)
    rows = screen.getAllByRole('button', { name: /View evidence for/i })
    expect(rows[0]).toHaveTextContent('Zeta Agent')
    expect(rows[1]).toHaveTextContent('Alpha Agent')
  })

  it('sorts agents chronologically when clicking Last Observed header', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [
        makeAgent({ id: 'agent-old', name: 'Older Agent', timestamps: { last_observed_at: '2026-01-01T00:00:00Z' } }),
        makeAgent({ id: 'agent-new', name: 'Newer Agent', timestamps: { last_observed_at: '2026-09-29T12:00:00Z' } }),
      ],
      total: 2,
    })
    renderPage()

    await screen.findByText('Older Agent')
    const sortHeader = screen.getByTestId('sort-header-last-assessed')

    // First click: asc (Older before Newer)
    await userEvent.click(sortHeader)
    let rows = screen.getAllByRole('button', { name: /View evidence for/i })
    expect(rows[0]).toHaveTextContent('Older Agent')
    expect(rows[1]).toHaveTextContent('Newer Agent')

    // Second click: desc (Newer before Older)
    await userEvent.click(sortHeader)
    rows = screen.getAllByRole('button', { name: /View evidence for/i })
    expect(rows[0]).toHaveTextContent('Newer Agent')
    expect(rows[1]).toHaveTextContent('Older Agent')
  })

  it('filters agents when Needs review button is clicked', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [
        makeAgent({ id: 'agent-healthy', name: 'Healthy Agent', lifecycle_state: 'Governed', compliance_summary: { total_controls: 5, passing: 5, failing: 0, pending: 0, posture_score: 1.0 } }),
        makeAgent({ id: 'agent-failing', name: 'Failing Agent', lifecycle_state: 'Governed', compliance_summary: { total_controls: 5, passing: 4, failing: 1, pending: 0, posture_score: 0.8 } }),
      ],
      total: 2,
    })
    renderPage()

    await screen.findByText('Healthy Agent')
    expect(screen.getByTestId('agent-row-agent-failing')).toBeInTheDocument()

    const attentionBtn = screen.getByTestId('agent-attention-filter-btn')
    await userEvent.click(attentionBtn)
    expect(screen.getByText('Healthy Agent').closest('tbody')).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByTestId('agent-row-agent-failing').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
  })

  it('retains tenant evidence in the eight-column compact layout', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [
        makeAgent({ id: 'agent-tenant-test', name: 'Tenant Bot', tenant: 'tenant-demo', tenant_id: 'tenant-demo' }),
      ],
      total: 1,
    })
    renderPage()

    await screen.findByText('Tenant Bot')
    expect(screen.getByTestId('agent-tenant-badge-agent-tenant-test')).toHaveTextContent('tenant-demo')
    const row = screen.getByTestId('agent-row-agent-tenant-test')
    expect(row.querySelectorAll('td')).toHaveLength(8)
  })

  it('renders Undeclared tenant badge and responsibility text when agent declares no tenant', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [
        makeAgent({ id: 'agent-undeclared-test', name: 'Undeclared Bot', tenant: null, tenant_id: 'undeclared' }),
      ],
      total: 1,
    })
    renderPage()

    await screen.findByText('Undeclared Bot')
    expect(screen.getByTestId('agent-tenant-badge-agent-undeclared-test')).toHaveTextContent('Undeclared')
  })

  it('filters workloads using the GitOps Managed and Tenant Mismatch filter buttons', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({
      // AgentResponse declares no `labels` (nor does the API's AgentResponse),
      // so the field is attached outside the type: hasGitOpsMetadata reads it
      // duck-typed. Spelling it inside makeAgent() fails `tsc` (TS2353).
      agents: [
        withLabels(makeAgent({ id: 'agent-gitops', name: 'GitOps Agent', tenant_id: 'tenant-1' }),
          { 'kustomize.toolkit.fluxcd.io/name': 'apps' }),
        withLabels(makeAgent({ id: 'agent-mismatch', name: 'Mismatch Agent', tenant_id: 'tenant-different' }), {}),
        withLabels(makeAgent({ id: 'agent-normal', name: 'Standard Agent', tenant_id: 'tenant-1' }), {}),
      ],
      total: 3,
    })
    stubMe('tenant-1')
    renderPage()

    await screen.findByText('GitOps Agent')
    await waitFor(() => expect(screen.getByTestId('agent-tenant-mismatch-filter-btn')).toHaveTextContent('1'))
    expect(screen.getByTestId('agent-row-agent-gitops')).toBeInTheDocument()
    expect(screen.getByTestId('agent-row-agent-mismatch')).toBeInTheDocument()
    expect(screen.getByTestId('agent-row-agent-normal')).toBeInTheDocument()

    const gitopsBtn = screen.getByTestId('agent-gitops-filter-btn')
    const mismatchBtn = screen.getByTestId('agent-tenant-mismatch-filter-btn')

    // Initial states
    expect(gitopsBtn).toHaveAttribute('aria-pressed', 'false')
    expect(mismatchBtn).toHaveAttribute('aria-pressed', 'false')
    expect(gitopsBtn).toHaveTextContent('GitOps Managed')
    expect(mismatchBtn).toHaveTextContent('Tenant Mismatch')

    // 1. Activate GitOps filter: only agent-gitops is visible
    await userEvent.click(gitopsBtn)
    expect(gitopsBtn).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByTestId('agent-row-agent-gitops').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
    expect(screen.getByTestId('agent-row-agent-mismatch').closest('tbody')).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByTestId('agent-row-agent-normal').closest('tbody')).toHaveAttribute('aria-hidden', 'true')

    // Deactivate GitOps filter
    await userEvent.click(gitopsBtn)
    expect(gitopsBtn).toHaveAttribute('aria-pressed', 'false')
    expect(screen.getByTestId('agent-row-agent-gitops').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
    expect(screen.getByTestId('agent-row-agent-mismatch').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
    expect(screen.getByTestId('agent-row-agent-normal').closest('tbody')).toHaveAttribute('aria-hidden', 'false')

    // 2. Activate Tenant Mismatch filter: only agent-mismatch is visible
    await userEvent.click(mismatchBtn)
    expect(mismatchBtn).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByTestId('agent-row-agent-gitops').closest('tbody')).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByTestId('agent-row-agent-mismatch').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
    expect(screen.getByTestId('agent-row-agent-normal').closest('tbody')).toHaveAttribute('aria-hidden', 'true')

    // Deactivate Tenant Mismatch filter
    await userEvent.click(mismatchBtn)
    expect(mismatchBtn).toHaveAttribute('aria-pressed', 'false')
    expect(screen.getByTestId('agent-row-agent-gitops').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
    expect(screen.getByTestId('agent-row-agent-mismatch').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
    expect(screen.getByTestId('agent-row-agent-normal').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
  })
})

describe('AgentsPage — review queue integration', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  it.each([false, true])('keeps loaded poll UI and row identities stable during deferred refresh (empty=%s)', async empty => {
    const response: AgentListResponse = { agents: empty ? [] : [makeAgent({ lifecycle_state: 'suspended' })], total: empty ? 0 : 1 }
    let resolveRefresh!: (value: AgentListResponse) => void
    const intervals = vi.spyOn(window, 'setInterval')
    vi.mocked(api.agents.list).mockResolvedValueOnce(response).mockImplementationOnce(() => new Promise(resolve => { resolveRefresh = resolve }))
    const { unmount } = renderPage()
    expect(screen.getByTestId('agents-poll-state-loader')).toBeInTheDocument()
    await waitFor(() => expect(screen.getByTestId('agents-poll-state')).toHaveAttribute('data-status', 'success'))
    const queue = screen.getByRole('region', { name: 'Review queue' })
    const rows = within(queue).queryAllByRole('listitem')
    const count = within(queue).getByText(/issues? · .* affected/)
    const stamp = queue.querySelector('time')!.dateTime
    const inventory = empty ? null : screen.getByTestId('agent-row-agent-abc-123')
    try {
      vi.useFakeTimers({ toFake: ['Date'] })
      vi.setSystemTime(Date.parse(stamp) + 60_000)
      const poll = intervals.mock.calls.find(([, delay]) => delay === 2500)![0] as () => void
      await act(async () => { poll() })
      expect(api.agents.list).toHaveBeenCalledTimes(2)
      expect(screen.getByTestId('agents-poll-state')).toHaveAttribute('data-status', 'success')
      expect(screen.queryByTestId('agents-poll-state-loader')).not.toBeInTheDocument()
      expect(screen.getByTestId('agents-poll-state-message')).toHaveTextContent('Refreshed 1m ago')
      expect(within(screen.getByTestId('agents-poll-state')).getByTestId('loading-indicator')).toHaveAttribute('data-motion', 'static')
      expect(within(queue).queryByText(/Refreshing review evidence/)).not.toBeInTheDocument()
      expect(within(queue).getByText(/issues? · .* affected/)).toBe(count)
      expect(queue.querySelector('time')!.dateTime).toBe(stamp)
      if (empty) expect(within(queue).getByText('No agents need review')).toBeInTheDocument()
      else expect(screen.getByTestId('agent-row-agent-abc-123')).toBe(inventory)
      within(queue).queryAllByRole('listitem').forEach((row, index) => expect(row).toBe(rows[index]))
      await act(async () => { resolveRefresh(response) })
      expect(screen.getByTestId('agents-poll-state')).toHaveAttribute('data-status', 'success')
      expect(queue.querySelector('time')!.dateTime).not.toBe(stamp)
      expect(screen.getByTestId('agents-poll-state-message')).toHaveTextContent('Refreshed just now')
      within(queue).queryAllByRole('listitem').forEach((row, index) => expect(row).toBe(rows[index]))
    } finally {
      unmount()
      intervals.mockRestore()
      vi.useRealTimers()
    }
  })

  it('shares exact affected population between queue, card and Needs review filter', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({ agents: [
      makeAgent({ id: 'overlap', name: 'Overlap', compliance_summary: { total_controls: 5, passing: 1, failing: 4, pending: 0, posture_score: 20 } }),
      makeAgent({ id: 'stopped', name: 'Stopped', operational_state: { runtime_status: 'Stopped', containment: { process_freeze: 'inactive', network_isolation: 'inactive', credential_revocation: 'inactive' } } }),
      makeAgent({ id: 'clean', name: 'Clean suspended', lifecycle_state: 'Suspended' }),
      makeAgent({ id: 'confirmed', name: 'Confirmed', lifecycle_state: 'stunned', kernel_state: 'frozen' }),
      makeAgent({ id: 'credential', name: 'Revoked credentials', credential_state: { status: 'revoked' } as AgentResponse['credential_state'] }),
    ], total: 5 })
    renderPage()
    const region = await screen.findByRole('region', { name: 'Review queue' })
    await waitFor(() => expect(within(region).getByText('4 issues · 3 affected agents')).toBeInTheDocument())
    expect(within(screen.getByTestId('statcard-attention')).getByText('3')).toBeInTheDocument()
    const filter = screen.getByRole('button', { name: /Needs review/ })
    expect(filter).toHaveTextContent('3')
    await userEvent.click(filter)
    for (const id of ['overlap', 'stopped', 'credential']) expect(screen.getByTestId(`agent-row-${id}`).closest('tbody')).toHaveAttribute('aria-hidden', 'false')
    for (const id of ['clean', 'confirmed']) expect(screen.getByTestId(`agent-row-${id}`).closest('tbody')).toHaveAttribute('aria-hidden', 'true')
  })

  it('retains queue and inventory evidence after a failed refresh and recovers on retry', async () => {
    const agents = [makeAgent({ id: 'evidence', lifecycle_state: 'stunned' })]
    vi.mocked(api.agents.list).mockResolvedValueOnce({ agents, total: 1 }).mockRejectedValueOnce(new Error('refresh offline')).mockResolvedValue({ agents: [], total: 0 })
    vi.mocked(api.compliancePolicy.scan).mockResolvedValue({ summary: { scanTimestamp: '2026-10-13T10:00:00Z' } } as Awaited<ReturnType<typeof api.compliancePolicy.scan>>)
    renderPage()
    await screen.findByTestId('agent-row-evidence')
    const queue = screen.getByRole('region', { name: 'Review queue' })
    await userEvent.click(screen.getByRole('button', { name: /scan compliance/i }))
    await waitFor(() => expect(within(queue).getByRole('alert')).toHaveTextContent('Refresh failed; showing stale review evidence: refresh offline'))
    expect(within(queue).getByRole('link', { name: /Review agent Invoice Bot: Containment unconfirmed/ })).toHaveAttribute('href', '/agents/evidence?tab=access')
    expect(screen.getByTestId('agent-row-evidence')).toBeInTheDocument()
    expect(within(queue).queryByText('No agents need review')).not.toBeInTheDocument()
    await userEvent.click(within(queue).getByRole('button', { name: 'Retry' }))
    await waitFor(() => expect(within(queue).getByText('No agents need review')).toBeInTheDocument())
  })
})

describe('AgentsPage — Filter Chips & State Counts', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  it('renders all filter chips with accurate counts and isolates matching workloads', async () => {
    // 8 Governed agents (active/registered), 2 unlinked discovered workloads (10 total)
    // 1 with GitOps labels, 2 with tenant mismatch, 1 needing review
    const mockAgents: AgentResponse[] = [
      // 7 active Kagent workloads
      makeAgent({ id: 'kagent-1', name: 'Kagent Alpha', lifecycle_state: 'active', tenant: 'tenant-demo', tenant_id: 'tenant-demo' }),
      makeAgent({ id: 'kagent-2', name: 'Kagent Beta', lifecycle_state: 'active', tenant: 'tenant-demo', tenant_id: 'tenant-demo' }),
      makeAgent({ id: 'kagent-3', name: 'Kagent Gamma', lifecycle_state: 'active', tenant: 'tenant-demo', tenant_id: 'tenant-demo' }),
      makeAgent({ id: 'kagent-4', name: 'Kagent Delta', lifecycle_state: 'active', tenant: 'tenant-demo', tenant_id: 'tenant-demo' }),
      makeAgent({ id: 'kagent-5', name: 'Kagent Epsilon', lifecycle_state: 'active', tenant: 'tenant-demo', tenant_id: 'tenant-demo' }),
      makeAgent({ id: 'kagent-6', name: 'Kagent Zeta', lifecycle_state: 'active', tenant: 'tenant-demo', tenant_id: 'tenant-demo' }),
      withLabels(makeAgent({ id: 'kagent-7', name: 'Kagent Eta', lifecycle_state: 'active', tenant: 'tenant-demo', tenant_id: 'tenant-demo' }), { 'kustomize.toolkit.fluxcd.io/name': 'kagent' }),
      // 1 registered custom agent with non-compliant control (needs review)
      makeAgent({
        id: 'agent-echo',
        name: 'Echo Agent',
        lifecycle_state: 'registered',
        tenant: 'tenant-demo',
        tenant_id: 'tenant-demo',
        compliance_summary: { total_controls: 6, passing: 4, failing: 2, pending: 0, posture_score: 0.67 },
      }),
      // 2 discovered unlinked workloads with idle lifecycle and no tenant (tenant mismatch + unlinked)
      makeAgent({
        id: 'netassert-pod',
        name: 'NetAssert Pod',
        lifecycle_state: 'idle',
        record_class: 'discovered',
        is_registry_linked: false,
        tenant: null,
        tenant_id: 'undeclared',
      }),
      makeAgent({
        id: 'stunned-pod',
        name: 'Stunned Pod',
        lifecycle_state: 'idle',
        record_class: 'discovered',
        is_registry_linked: false,
        tenant: null,
        tenant_id: 'undeclared',
      }),
    ]

    vi.mocked(api.agents.list).mockResolvedValue({
      agents: mockAgents,
      total: 10,
    })

    renderPage(['/agents?tenant=tenant-demo'])

    await screen.findByText('Kagent Alpha')

    // 1. Verify chip counts
    // All states: 10
    const allChip = screen.getByTestId('agent-lifecycle-filter-all')
    expect(allChip).toHaveTextContent('All states')
    expect(allChip).toHaveTextContent('10')

    // Governed: 8 (7 active + 1 registered)
    const governedChip = screen.getByTestId('agent-lifecycle-filter-Governed')
    expect(governedChip).toHaveTextContent('Governed')
    expect(governedChip).toHaveTextContent('8')

    // Suspended: 0
    const suspendedChip = screen.getByTestId('agent-lifecycle-filter-Suspended')
    expect(suspendedChip).toHaveTextContent('Suspended')
    expect(suspendedChip).toHaveTextContent('0')

    // Revoked: 0
    const revokedChip = screen.getByTestId('agent-lifecycle-filter-Revoked')
    expect(revokedChip).toHaveTextContent('Revoked')
    expect(revokedChip).toHaveTextContent('0')

    // Unlinked: 2 (netassert-pod, stunned-pod)
    const unlinkedChip = screen.getByTestId('agent-unlinked-filter-btn')
    expect(unlinkedChip).toHaveTextContent('Unlinked')
    expect(unlinkedChip).toHaveTextContent('2')

    // GitOps Managed: 1 (kagent-7)
    const gitopsChip = screen.getByTestId('agent-gitops-filter-btn')
    expect(gitopsChip).toHaveTextContent('GitOps Managed')
    expect(gitopsChip).toHaveTextContent('1')

    // Tenant Mismatch: 2 (the 2 undeclared pods vs tenant-demo session tenant)
    const mismatchChip = screen.getByTestId('agent-tenant-mismatch-filter-btn')
    expect(mismatchChip).toHaveTextContent('Tenant Mismatch')
    expect(mismatchChip).toHaveTextContent('2')

    // Needs review: 1 (agent-echo with failing: 2)
    const reviewChip = screen.getByTestId('agent-attention-filter-btn')
    expect(reviewChip).toHaveTextContent('Needs review')
    expect(reviewChip).toHaveTextContent('1')

    // 2. Click Governed: isolates 8 governed workloads, hides 2 unlinked pods
    await userEvent.click(governedChip)
    expect(governedChip).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByTestId('agent-row-kagent-1').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
    expect(screen.getByTestId('agent-row-agent-echo').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
    expect(screen.getByTestId('agent-row-netassert-pod').closest('tbody')).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByTestId('agent-row-stunned-pod').closest('tbody')).toHaveAttribute('aria-hidden', 'true')

    // 3. Click All states to reset lifecycle
    await userEvent.click(allChip)
    expect(allChip).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByTestId('agent-row-netassert-pod').closest('tbody')).toHaveAttribute('aria-hidden', 'false')

    // 4. Click Unlinked: isolates the 2 unlinked workloads
    await userEvent.click(unlinkedChip)
    expect(unlinkedChip).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByTestId('agent-row-kagent-1').closest('tbody')).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByTestId('agent-row-agent-echo').closest('tbody')).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByTestId('agent-row-netassert-pod').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
    expect(screen.getByTestId('agent-row-stunned-pod').closest('tbody')).toHaveAttribute('aria-hidden', 'false')

    // Deactivate Unlinked
    await userEvent.click(unlinkedChip)
    expect(unlinkedChip).toHaveAttribute('aria-pressed', 'false')

    // 5. Click Needs review: isolates agent-echo
    await userEvent.click(reviewChip)
    expect(reviewChip).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByTestId('agent-row-agent-echo').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
    expect(screen.getByTestId('agent-row-kagent-1').closest('tbody')).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByTestId('agent-row-netassert-pod').closest('tbody')).toHaveAttribute('aria-hidden', 'true')

    // 6. Click Clear: restores all workloads
    const clearBtn = screen.getByRole('button', { name: 'Clear' })
    await userEvent.click(clearBtn)
    expect(screen.getByTestId('agent-row-kagent-1').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
    expect(screen.getByTestId('agent-row-agent-echo').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
    expect(screen.getByTestId('agent-row-netassert-pod').closest('tbody')).toHaveAttribute('aria-hidden', 'false')
  })
})

describe('AgentsPage — server session tenant and unlinked filter', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  const hidden = (id: string) => screen.getByTestId(`agent-row-${id}`).closest('tbody')?.getAttribute('aria-hidden')
  const mismatchChip = () => screen.getByTestId('agent-tenant-mismatch-filter-btn')
  const unlinkedChip = () => screen.getByTestId('agent-unlinked-filter-btn')

  const tenantAgents = () => [
    makeAgent({ id: 'kusari-agent', name: 'Kusari Agent', tenant: 'kusari', tenant_id: 'kusari' }),
    makeAgent({ id: 'demo-agent', name: 'Demo Agent', tenant: 'tenant-demo', tenant_id: 'tenant-demo' }),
    makeAgent({ id: 'other-agent', name: 'Other Agent', tenant: 'tenant-1', tenant_id: 'tenant-1' }),
  ]

  it('takes the session tenant from /api/v1/me, not the email domain (kusari-operator → kusari)', async () => {
    mockUser = { email: 'kusari-operator@signalloom.local', preferred_username: 'kusari-operator' }
    stubMe('kusari', 'kusari-operator@signalloom.local')
    vi.mocked(api.agents.list).mockResolvedValue({ agents: tenantAgents(), total: 3 })
    renderPage()

    await screen.findByText('Kusari Agent')
    await waitFor(() => expect(mismatchChip()).toHaveTextContent('Tenant Mismatch2'))
    await userEvent.click(mismatchChip())
    expect(hidden('kusari-agent')).toBe('true')
    expect(hidden('demo-agent')).toBe('false')
    expect(hidden('other-agent')).toBe('false')
  })

  it('reports no tenant mismatch while the server tenant is unknown, rather than inventing one', async () => {
    mockUser = { email: 'demo-user@signalloom.local' }
    vi.mocked(api.agents.list).mockResolvedValue({ agents: tenantAgents(), total: 3 })
    renderPage()

    await screen.findByText('Kusari Agent')
    await waitFor(() => expect(mockGetAccessTokenSilently).toHaveBeenCalled())
    await act(async () => { await Promise.resolve() })
    expect(mismatchChip()).toHaveTextContent('Tenant Mismatch0')
    expect(hidden('kusari-agent')).toBe('false')
    expect(hidden('demo-agent')).toBe('false')
    expect(hidden('other-agent')).toBe('false')
  })

  const unlinkedAgents = () => [
    makeAgent({ id: 'discovered-only', name: 'Discovered Only', record_class: 'discovered', is_registry_linked: true }),
    makeAgent({ id: 'unlinked-only', name: 'Unlinked Only', record_class: 'registered', is_registry_linked: false }),
    makeAgent({ id: 'linked-registered', name: 'Linked Registered', record_class: 'registered', is_registry_linked: true }),
  ]

  it('counts and isolates either discovered or registry-unlinked rows under Unlinked', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({ agents: unlinkedAgents(), total: 3 })
    renderPage()

    await screen.findByText('Discovered Only')
    expect(unlinkedChip()).toHaveTextContent('Unlinked2')
    await userEvent.click(unlinkedChip())
    expect(hidden('discovered-only')).toBe('false')
    expect(hidden('unlinked-only')).toBe('false')
    expect(hidden('linked-registered')).toBe('true')
  })

  it('applies ?unlinked=true on load', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({ agents: unlinkedAgents(), total: 3 })
    renderPage(['/agents?unlinked=true'])

    await screen.findByText('Discovered Only')
    expect(unlinkedChip()).toHaveAttribute('aria-pressed', 'true')
    expect(hidden('discovered-only')).toBe('false')
    expect(hidden('unlinked-only')).toBe('false')
    expect(hidden('linked-registered')).toBe('true')
  })

  it('labels the lifecycle chips and the attribute chips as separate groups', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({ agents: unlinkedAgents(), total: 3 })
    renderPage()

    await screen.findByText('Discovered Only')
    const lifecycle = screen.getByRole('group', { name: 'Filter agents by lifecycle state' })
    const attributes = screen.getByRole('group', { name: 'Filter agents by registry link, review, GitOps and tenant' })
    expect(within(lifecycle).getAllByRole('button').map(b => b.getAttribute('data-testid'))).toEqual(
      expect.arrayContaining(['agent-lifecycle-filter-all']),
    )
    expect(within(lifecycle).getAllByRole('button').every(b => b.getAttribute('data-testid')?.startsWith('agent-lifecycle-filter-'))).toBe(true)
    expect(within(attributes).getAllByRole('button').map(b => b.getAttribute('data-testid'))).toEqual([
      'agent-unlinked-filter-btn',
      'agent-attention-filter-btn',
      'agent-gitops-filter-btn',
      'agent-tenant-mismatch-filter-btn',
    ])
  })
})

describe('AgentsPage — Claude Managed Parity & Runtime Display', () => {
  it('renders Daily News Jokester with runtime claude-managed', async () => {
    const jokester = makeAgent({
      id: 'agent_01FoEhnKF9QsC5DGmuELhm7G',
      name: 'Daily News Jokester',
      model_name: 'claude-opus-5-5',
      owner: 'Andrew Martin (User)',
      record_class: 'discovered',
      is_registry_linked: false,
      lifecycle_state: 'active',
      runtime: {
        namespace: 'cloud-dev',
        framework: 'claude-managed',
        model: 'claude-opus-5-5',
        execution_mode: 'autonomous',
      },
    })
    vi.mocked(api.agents.list).mockResolvedValue({ agents: [jokester], total: 1 })
    renderPage()

    await screen.findByText('Daily News Jokester')
    const row = screen.getByTestId('agent-row-agent_01FoEhnKF9QsC5DGmuELhm7G')
    expect(within(row).getByText('claude-managed')).toBeInTheDocument()
  })

  it('displays claude-managed for Claude agents identified by framework, type, or model name', async () => {
    const agentFramework = makeAgent({
      id: 'agent-fw',
      name: 'Agent Framework',
      runtime: {
        namespace: 'cloud-dev',
        framework: 'claude-managed',
        execution_mode: 'autonomous',
      },
    })
    const agentType = makeAgent({
      id: 'agent-type',
      name: 'Agent Type',
      type: 'claude',
      runtime: {
        namespace: 'cloud-dev',
        framework: undefined,
        execution_mode: 'autonomous',
      },
    })
    const agentModel = makeAgent({
      id: 'agent-model',
      name: 'Agent Model',
      model_name: 'claude-3-5-sonnet-20241022',
      runtime: {
        namespace: 'cloud-dev',
        framework: undefined,
        execution_mode: 'autonomous',
      },
    })
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [agentFramework, agentType, agentModel],
      total: 3,
    })
    renderPage()

    await screen.findByText('Agent Framework')
    const rowFw = screen.getByTestId('agent-row-agent-fw')
    const rowType = screen.getByTestId('agent-row-agent-type')
    const rowModel = screen.getByTestId('agent-row-agent-model')

    expect(within(rowFw).getByText('claude-managed')).toBeInTheDocument()
    expect(within(rowType).getByText('claude-managed')).toBeInTheDocument()
    expect(within(rowModel).getByText('claude-managed')).toBeInTheDocument()
  })

  it('sorts and filters claude-managed agents seamlessly', async () => {
    const jokester = makeAgent({
      id: 'agent_01FoEhnKF9QsC5DGmuELhm7G',
      name: 'Daily News Jokester',
      model_name: 'claude-opus-5-5',
      runtime: {
        namespace: 'cloud-dev',
        framework: 'claude-managed',
        execution_mode: 'autonomous',
      },
    })
    const otherAgent = makeAgent({
      id: 'agent-other',
      name: 'Zeta Other Agent',
      runtime: {
        namespace: 'prod-eu',
        framework: 'LangGraph',
        execution_mode: 'autonomous',
      },
    })
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [jokester, otherAgent],
      total: 2,
    })
    renderPage()

    await screen.findByText('Daily News Jokester')

    // Filter by searching claude-managed
    const searchInput = screen.getByPlaceholderText(/Search agents/i)
    await userEvent.type(searchInput, 'claude-managed')

    const rowJokester = screen.getByTestId('agent-row-agent_01FoEhnKF9QsC5DGmuELhm7G').closest('tbody')
    const rowOther = screen.getByTestId('agent-row-agent-other').closest('tbody')

    expect(rowJokester).toHaveAttribute('aria-hidden', 'false')
    expect(rowOther).toHaveAttribute('aria-hidden', 'true')

    // Clear search
    await userEvent.clear(searchInput)
    expect(rowJokester).toHaveAttribute('aria-hidden', 'false')
    expect(rowOther).toHaveAttribute('aria-hidden', 'false')

    // Test sorting by runtime
    const runtimeSortHeader = screen.getByTestId('sort-header-runtime')
    await userEvent.click(runtimeSortHeader)
    const rows = screen.getAllByRole('button', { name: /View evidence for/i })
    expect(rows[0]).toHaveTextContent('Daily News Jokester')
  })

  it('opens drawer and focuses agent when ?selected= is passed in URL', async () => {
    const jokester = makeAgent({
      id: 'agent_01FoEhnKF9QsC5DGmuELhm7G',
      name: 'Daily News Jokester',
      model_name: 'claude-opus-5-5',
      runtime: {
        namespace: 'cloud-dev',
        framework: 'claude-managed',
        execution_mode: 'autonomous',
      },
    })
    vi.mocked(api.agents.list).mockResolvedValue({ agents: [jokester], total: 1 })
    renderPage(['/agents?selected=agent_01FoEhnKF9QsC5DGmuELhm7G'])

    await screen.findByText('Daily News Jokester')
    expect(await screen.findByTestId('agent-evidence-drawer')).toBeInTheDocument()
  })

  it('opens drawer and displays row when ?selected= matches claude agent with cluster id tenant-demo:claude-agent-fin-analyst', async () => {
    const claudeAgent = makeAgent({
      id: 'tenant-demo:claude-agent-fin-analyst',
      name: 'Daily News Jokester',
      model_name: 'claude-opus-5-5',
      type: 'claude',
      runtime: {
        namespace: 'cloud-dev',
        framework: 'claude-managed',
        execution_mode: 'autonomous',
      },
    })
    vi.mocked(api.agents.list).mockResolvedValue({ agents: [claudeAgent], total: 1 })
    renderPage(['/agents?selected=agent_01FoEhnKF9QsC5DGmuELhm7G&drawer=agent_01FoEhnKF9QsC5DGmuELhm7G'])

    // The agent row should not be filtered out
    expect(await screen.findByText('Daily News Jokester')).toBeInTheDocument()
    // The evidence drawer should open
    expect(await screen.findByTestId('agent-evidence-drawer')).toBeInTheDocument()
  })
})

