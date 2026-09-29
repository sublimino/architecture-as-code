import { render, screen, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import AgentEvidenceDrawer from './AgentEvidenceDrawer'
import type { AgentResponse, SourceHealthMap } from '../types/api'

const mockGetAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently: mockGetAccessTokenSilently }),
}))

const mockUseAgentRisk = vi.fn().mockReturnValue({
  data: null,
  loading: false,
  error: null,
  source: 'fixture',
  refresh: vi.fn(),
})

vi.mock('../hooks/useAgentRisk', () => ({
  useAgentRisk: (id: string | null) => mockUseAgentRisk(id),
}))

const mockAgent: AgentResponse = {
  id: 'agent-uuid-1234',
  name: 'Security Sentinel Bot',
  type: 'Signal Loom Built',
  tenant_id: 'tenant-demo',
  lifecycle_state: 'active',
  last_transition_at: '2026-09-07T08:00:00Z',
  eu_ai_act_risk_class: 'limited',
  compliance_summary: {
    total_controls: 6,
    passing: 5,
    failing: 1,
    pending: 0,
    posture_score: 0.83,
  },
  created_at: '2026-09-01T10:00:00Z',
  record_class: 'registered',
  is_registry_linked: true,
  runtime: {
    namespace: 'sec-ops',
    framework: 'kagent',
    execution_mode: 'autonomous',
    model: 'claude-3-7-sonnet',
    node: 'node-pool-1',
    pod_uid: 'pod-uid-sentinel-999',
    service_account: 'sentinel-sa',
    phase: 'Running',
  },
  responsibility: {
    owner_name: 'alice@signal-loom.ai',
    team: 'Platform Security',
    assignment_status: 'assigned',
  },
  identity: {
    spiffe_id: 'spiffe://cluster.local/ns/sec-ops/sa/sentinel-sa',
    spiffe_status: 'linked',
    aliases: ['sentinel-alias-1', 'sentinel-alias-2'],
  },
  attention: {
    level: 'critical',
    highest_issue: '1 failing control detected',
  },
  timestamps: {
    created_at: '2026-09-01T10:00:00Z',
    last_observed_at: '2026-09-07T08:30:00Z',
    last_transition_at: '2026-09-07T08:00:00Z',
  },
  kernel_telemetry: {
    cgroup_state: 'thawed',
    traffic_control_state: 'allow',
    ebpf_active: true,
  },
}

const mockSourceHealthDetail: SourceHealthMap = {
  k8s_discovery: { status: 'healthy', message: 'Discovery responsive' },
  postgres_registry: { status: 'healthy', message: 'Registry responsive' },
  crypto_proofs: { status: 'healthy', message: 'Crypto responsive' },
}

describe('AgentEvidenceDrawer Component', () => {
  beforeEach(() => {
    mockUseAgentRisk.mockReturnValue({
      data: null,
      loading: false,
      error: null,
      source: 'fixture',
      refresh: vi.fn(),
    })
  })

  it('renders null when agent is null', () => {
    const { container } = render(
      <AgentEvidenceDrawer
        agent={null}
        onClose={vi.fn()}
      />
    )
    expect(container.firstChild).toBeNull()
  })

  it('renders drawer header, badges, and identifiers', () => {
    render(
      <AgentEvidenceDrawer
        agent={mockAgent}
        sourceHealth="healthy"
        sourceHealthDetail={mockSourceHealthDetail}
        onClose={vi.fn()}
      />
    )

    expect(screen.getByTestId('agent-evidence-drawer')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-agent-name')).toHaveTextContent('Security Sentinel Bot')
    expect(screen.getByTestId('drawer-record-class-badge')).toHaveTextContent('Registered')
    expect(screen.getByTestId('drawer-lifecycle-badge')).toHaveTextContent('active')
    expect(screen.getByTestId('drawer-agent-id')).toHaveTextContent('ID: agent-uuid-1234')
  })

  it('safely copies Agent ID without credential secret material', async () => {
    const writeTextMock = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, {
      clipboard: {
        writeText: writeTextMock,
      },
    })

    render(
      <AgentEvidenceDrawer
        agent={mockAgent}
        onClose={vi.fn()}
      />
    )

    const copyBtn = screen.getByTestId('drawer-copy-id')
    await userEvent.click(copyBtn)

    expect(writeTextMock).toHaveBeenCalledWith('agent-uuid-1234')
    expect(screen.getByTestId('drawer-copy-id')).toHaveTextContent('Copied!')
  })

  it('truthful language: renders "Not assessed" when 0 controls are evaluated', () => {
    const unassessedAgent: AgentResponse = {
      ...mockAgent,
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
    }

    render(
      <AgentEvidenceDrawer
        agent={unassessedAgent}
        onClose={vi.fn()}
      />
    )

    expect(screen.getByTestId('drawer-assessment-status')).toHaveTextContent('Not assessed')
    expect(screen.getByTestId('drawer-posture-score')).toHaveTextContent('Not assessed')
  })

  it('truthful language: renders "Unassigned" when owner metadata is absent', () => {
    const unassignedAgent: AgentResponse = {
      ...mockAgent,
      owner: null,
      responsibility: {
        owner_name: null,
        team: null,
        assignment_status: 'unassigned',
      },
      record_class: 'registered',
      is_registry_linked: true,
    }

    render(
      <AgentEvidenceDrawer
        agent={unassignedAgent}
        onClose={vi.fn()}
      />
    )

    expect(screen.getByTestId('drawer-responsibility-owner')).toHaveTextContent('Unassigned')
  })

  it('truthful language: renders "Registry not linked" when discovery record has no registry relationship', () => {
    const discoveredAgent: AgentResponse = {
      ...mockAgent,
      owner: null,
      responsibility: undefined,
      record_class: 'discovered',
      is_registry_linked: false,
    }

    render(
      <AgentEvidenceDrawer
        agent={discoveredAgent}
        onClose={vi.fn()}
      />
    )

    expect(screen.getByTestId('drawer-responsibility-owner')).toHaveTextContent('Registry not linked')
  })

  it('truthful language: renders source health statuses and degrades on outages', () => {
    const degradedHealth: SourceHealthMap = {
      k8s_discovery: { status: 'unavailable', message: 'Cluster unreachable' },
      postgres_registry: { status: 'healthy' },
      crypto_proofs: { status: 'degraded' },
    }

    render(
      <AgentEvidenceDrawer
        agent={mockAgent}
        sourceHealth="degraded"
        sourceHealthDetail={degradedHealth}
        onClose={vi.fn()}
      />
    )

    expect(screen.getByTestId('drawer-k8s-health')).toHaveTextContent('unavailable')
    expect(screen.getByTestId('drawer-postgres-health')).toHaveTextContent('healthy')
    expect(screen.getByTestId('drawer-crypto-health')).toHaveTextContent('degraded')
  })

  it('kernel telemetry: renders "cgroup: FROZEN" and "TC: DROP" when telemetry confirms isolation', () => {
    const frozenAgent: AgentResponse = {
      ...mockAgent,
      lifecycle_state: 'suspended',
      kernel_telemetry: {
        cgroup_state: 'frozen',
        traffic_control_state: 'drop',
        ebpf_active: true,
      },
    }

    render(
      <AgentEvidenceDrawer
        agent={frozenAgent}
        onClose={vi.fn()}
      />
    )

    expect(screen.getByTestId('drawer-kernel-cgroup')).toHaveTextContent('cgroup: FROZEN')
    expect(screen.getByTestId('drawer-kernel-tc')).toHaveTextContent('TC: DROP')
  })

  it('kernel telemetry: renders "Requested (Outcome unconfirmed)" when containment is requested without kernel telemetry ACK', () => {
    const requestedAgent: AgentResponse = {
      ...mockAgent,
      lifecycle_state: 'suspended',
      kernel_telemetry: {
        cgroup_state: 'thawed',
        traffic_control_state: 'allow',
        ebpf_active: true,
      },
    }

    render(
      <AgentEvidenceDrawer
        agent={requestedAgent}
        onClose={vi.fn()}
      />
    )

    expect(screen.getByTestId('drawer-kernel-unconfirmed')).toHaveTextContent('Requested (Outcome unconfirmed)')
  })

  it('kernel telemetry: renders "cgroup: THAWED" and "TC: PASS" when normal telemetry is observed', () => {
    render(
      <AgentEvidenceDrawer
        agent={mockAgent}
        onClose={vi.fn()}
      />
    )

    expect(screen.getByTestId('drawer-kernel-cgroup')).toHaveTextContent('cgroup: THAWED')
    expect(screen.getByTestId('drawer-kernel-tc')).toHaveTextContent('TC: PASS')
  })

  it('renders runtime snapshot and identity details', () => {
    render(
      <AgentEvidenceDrawer
        agent={mockAgent}
        onClose={vi.fn()}
      />
    )

    expect(screen.getByTestId('drawer-runtime-namespace')).toHaveTextContent('sec-ops')
    expect(screen.getByTestId('drawer-runtime-framework')).toHaveTextContent('kagent (autonomous)')
    expect(screen.getByTestId('drawer-runtime-model')).toHaveTextContent('claude-3-7-sonnet')
    expect(screen.getByTestId('drawer-runtime-sa')).toHaveTextContent('sentinel-sa')
    expect(screen.getByTestId('drawer-runtime-node')).toHaveTextContent('node-pool-1')
    expect(screen.getByTestId('drawer-runtime-pod-uid')).toHaveTextContent('pod-uid-sentinel-999')
    expect(screen.getByTestId('drawer-runtime-phase')).toHaveTextContent('Running')

    expect(screen.getByTestId('drawer-spiffe-status')).toHaveTextContent('SPIFFE linked')
    expect(screen.getByTestId('drawer-spiffe-id')).toHaveTextContent('spiffe://cluster.local/ns/sec-ops/sa/sentinel-sa')
    expect(screen.getByTestId('drawer-identity-aliases')).toHaveTextContent('sentinel-alias-1')
  })

  it('handles user actions: close button, backdrop click, Escape key, Open full record, and Edit', async () => {
    const onClose = vi.fn()
    const onOpenFullRecord = vi.fn()
    const onEdit = vi.fn()

    const { unmount } = render(
      <AgentEvidenceDrawer
        agent={mockAgent}
        onClose={onClose}
        onOpenFullRecord={onOpenFullRecord}
        onEdit={onEdit}
      />
    )

    // 1. Close button (x)
    await userEvent.click(screen.getByTestId('agent-evidence-drawer-close'))
    expect(onClose).toHaveBeenCalledTimes(1)

    // 2. Open Full Record (Footer)
    await userEvent.click(screen.getByTestId('drawer-open-full-record'))
    expect(onOpenFullRecord).toHaveBeenCalledWith('agent-uuid-1234')

    // 2b. Open Full Dossier (Header)
    await userEvent.click(screen.getByTestId('drawer-header-full-record'))
    expect(onOpenFullRecord).toHaveBeenCalledTimes(2)

    // 3. Edit Agent
    await userEvent.click(screen.getByTestId('drawer-edit-agent'))
    expect(onEdit).toHaveBeenCalledWith(mockAgent)

    // 4. Close footer button
    await userEvent.click(screen.getByTestId('drawer-close-btn'))
    expect(onClose).toHaveBeenCalledTimes(2)

    // 5. Backdrop click
    await userEvent.click(screen.getByTestId('agent-evidence-drawer-backdrop'))
    expect(onClose).toHaveBeenCalledTimes(3)

    // 6. Escape keydown
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledTimes(4)

    unmount()
  })

  it('quantitative risk: renders OpenFAIR metrics and live source badge when risk data is available', () => {
    mockUseAgentRisk.mockReturnValue({
      data: {
        agentId: 'agent-uuid-1234',
        currency: 'GBP',
        lef: { min: 0.01, mode: 0.05, max: 0.2 },
        lossMagnitude: {
          min: { amount: 32872, currency: 'GBP' },
          mode: { amount: 563520, currency: 'GBP' },
          max: { amount: 5870000, currency: 'GBP' },
        },
        ale: { amount: 21681338, currency: 'GBP' },
        pml: { amount: 51342162, currency: 'GBP' },
        var95: { amount: 51342162, currency: 'GBP' },
        tvar: { amount: 60172685, currency: 'GBP' },
        carried: { amount: 66189954, currency: 'GBP' },
        tier: 'caged',
        simulation: { iterations: 10000, seed: 20260907, riskLoad: 0.1, tailDominated: false },
        source: 'riskctl',
      },
      loading: false,
      error: null,
      source: 'riskctl',
      refresh: vi.fn(),
    })

    render(
      <AgentEvidenceDrawer
        agent={mockAgent}
        onClose={vi.fn()}
      />
    )

    expect(screen.getByTestId('drawer-section-risk')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-section-risk-source')).toHaveTextContent('LIVE riskctl')
    expect(screen.getByTestId('drawer-section-risk-ale')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-section-risk-pml')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-section-risk-lef')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-section-risk-lm')).toBeInTheDocument()
  })

  it('quantitative risk: renders error state with retry when risk calculation fails with upstream error', async () => {
    const refreshMock = vi.fn()
    mockUseAgentRisk.mockReturnValue({
      data: null,
      loading: false,
      error: 'signal-ingest service unreachable',
      source: 'riskctl',
      refresh: refreshMock,
    })

    render(
      <AgentEvidenceDrawer
        agent={mockAgent}
        onClose={vi.fn()}
      />
    )

    expect(screen.getByTestId('drawer-section-risk-error')).toBeInTheDocument()
    expect(screen.getByText(/signal-ingest service unreachable/i)).toBeInTheDocument()

    const retryBtn = screen.getByRole('button', { name: /retry/i })
    await userEvent.click(retryBtn)
    expect(refreshMock).toHaveBeenCalledTimes(1)
  })

  it('quantitative risk: renders loading state while awaiting calculation', () => {
    mockUseAgentRisk.mockReturnValue({
      data: null,
      loading: true,
      error: null,
      source: 'riskctl',
      refresh: vi.fn(),
    })

    render(
      <AgentEvidenceDrawer
        agent={mockAgent}
        onClose={vi.fn()}
      />
    )

    const riskWidget = screen.getByTestId('drawer-section-risk')
    expect(riskWidget).toHaveAttribute('data-loading', 'true')
    expect(screen.getByTestId('drawer-section-risk-ale-value')).toHaveTextContent('…')
  })
})

