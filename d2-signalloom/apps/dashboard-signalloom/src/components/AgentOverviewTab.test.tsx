import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import AgentOverviewTab, { type AgentOverviewTabProps } from './AgentOverviewTab'
import type { AgentResponse, SourceHealthMap } from '../types/api'

function renderTab(ui: React.ReactElement) {
  return render(<MemoryRouter>{ui}</MemoryRouter>)
}

function createMockAgent(overrides: Partial<AgentResponse> = {}): AgentResponse {
  return {
    id: 'agent-123-uuid',
    name: 'Order Processing Agent',
    type: 'Signal Loom Built',
    owner: 'alice@signal-loom.ai',
    tenant_id: 'tenant-acme',
    lifecycle_state: 'active',
    last_transition_at: '2026-09-01T12:00:00Z',
    last_transition_by: 'operator@signal-loom.ai',
    eu_ai_act_risk_class: 'limited',
    compliance_summary: {
      total_controls: 10,
      passing: 8,
      failing: 2,
      pending: 0,
      posture_score: 80,
    },
    created_at: '2026-08-15T09:00:00Z',
    record_class: 'registered',
    is_registry_linked: true,
    runtime: {
      cluster_id: 'cluster-prod-1',
      namespace: 'fe-signalloom-agents',
      pod_name: 'order-agent-pod-7b9d',
      pod_uid: 'uid-9876-5432',
      service_account: 'sa-order-agent',
      framework: 'kagent',
      model: 'claude-3-7-sonnet',
      execution_mode: 'autonomous',
      node: 'kind-worker-1',
      phase: 'Running',
    },
    responsibility: {
      owner_id: 'user-alice',
      owner_name: 'alice@signal-loom.ai',
      team: 'SecOps Core',
      assignment_status: 'assigned',
    },
    identity: {
      spiffe_id: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-order-agent',
      spiffe_status: 'linked',
      aliases: ['order-proc', 'app:order-v1'],
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
      total_controls: 10,
      passed_controls: 8,
      failed_controls: 2,
      pending_controls: 0,
      normalized_score: 0.8,
    },
    attention: {
      level: 'critical',
      highest_issue: '2 failing controls detected',
    },
    timestamps: {
      created_at: '2026-08-15T09:00:00Z',
      last_observed_at: '2026-09-07T09:30:00Z',
      last_transition_at: '2026-09-01T12:00:00Z',
      last_action_at: '2026-09-07T09:15:00Z',
    },
    kernel_telemetry: {
      cgroup_state: 'thawed',
      traffic_control_state: 'allow',
      ebpf_active: true,
      ebpf_program_attached: true,
    },
    ...overrides,
  }
}

describe('AgentOverviewTab — 4 Summary StatCards', () => {
  it('renders Posture Score card with assessed percentage and controls breakdown', () => {
    const agent = createMockAgent()
    renderTab(<AgentOverviewTab agent={agent} />)

    expect(screen.getByTestId('overview-card-posture')).toBeInTheDocument()
    expect(screen.getByTestId('overview-posture-score')).toHaveTextContent('80%')
    expect(screen.getByTestId('overview-assessment-status')).toHaveTextContent('2 failing / 10 total')
  })

  it('renders truthful "Not assessed" when total controls evaluated is 0', () => {
    const agent = createMockAgent({
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
    renderTab(<AgentOverviewTab agent={agent} />)

    expect(screen.getByTestId('overview-posture-score')).toHaveTextContent('Not assessed')
    expect(screen.getByTestId('overview-assessment-status')).toHaveTextContent('Not assessed')
    // Fail-safe check: must never display 0% or Compliant
    expect(screen.queryByText('0%')).not.toBeInTheDocument()
    expect(screen.queryByText('Compliant')).not.toBeInTheDocument()
  })

  it('renders Attention card with critical badge and highest issue description', () => {
    const agent = createMockAgent({
      attention: {
        level: 'critical',
        highest_issue: 'Critical network egress violation',
      },
    })
    renderTab(<AgentOverviewTab agent={agent} />)

    expect(screen.getByTestId('overview-card-attention')).toBeInTheDocument()
    expect(screen.getByTestId('overview-attention-level')).toHaveTextContent('CRITICAL')
    expect(screen.getByTestId('overview-highest-issue')).toHaveTextContent('Critical network egress violation')
  })

  it('renders SPIFFE Trust card with linked status, SVID, and aliases', () => {
    const agent = createMockAgent()
    renderTab(<AgentOverviewTab agent={agent} />)

    expect(screen.getByTestId('overview-card-identity')).toBeInTheDocument()
    expect(screen.getByTestId('overview-spiffe-status')).toHaveTextContent('SPIFFE linked')
    expect(screen.getByTestId('overview-spiffe-id')).toHaveTextContent('spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-order-agent')
    expect(screen.getByTestId('overview-identity-aliases')).toHaveTextContent('order-proc')
  })

  it('renders Kernel Containment card with cgroup FROZEN and TC DROP when kernel telemetry active', () => {
    const agent = createMockAgent({
      kernel_telemetry: {
        cgroup_state: 'frozen',
        traffic_control_state: 'drop',
        ebpf_active: true,
        ebpf_program_attached: true,
      },
    })
    renderTab(<AgentOverviewTab agent={agent} />)

    expect(screen.getByTestId('overview-card-containment')).toBeInTheDocument()
    expect(screen.getByTestId('overview-kernel-cgroup')).toHaveTextContent('cgroup: FROZEN')
    expect(screen.getByTestId('overview-kernel-tc')).toHaveTextContent('TC: DROP')
  })

  it('renders "Requested (Outcome unconfirmed)" when containment requested without kernel telemetry ACK', () => {
    const agent = createMockAgent({
      lifecycle_state: 'suspended',
      kernel_telemetry: {
        cgroup_state: 'unknown',
        traffic_control_state: 'unknown',
      },
    })
    renderTab(<AgentOverviewTab agent={agent} />)

    expect(screen.getByTestId('overview-card-containment')).toBeInTheDocument()
    expect(screen.getByTestId('overview-kernel-unconfirmed')).toHaveTextContent('Requested (Outcome unconfirmed)')
  })
})

describe('AgentOverviewTab — 3 Snapshot Detail Panels', () => {
  it('renders Runtime & Deployment Snapshot panel with workload metadata', () => {
    const agent = createMockAgent()
    renderTab(<AgentOverviewTab agent={agent} />)

    expect(screen.getByTestId('overview-section-runtime')).toBeInTheDocument()
    expect(screen.getByTestId('overview-runtime-namespace')).toHaveTextContent('fe-signalloom-agents (cluster-prod-1)')
    expect(screen.getByTestId('overview-runtime-framework')).toHaveTextContent('kagent (autonomous)')
    expect(screen.getByTestId('overview-runtime-model')).toHaveTextContent('claude-3-7-sonnet')
    expect(screen.getByTestId('overview-runtime-sa')).toHaveTextContent('sa-order-agent')
    expect(screen.getByTestId('overview-runtime-node')).toHaveTextContent('kind-worker-1')
    expect(screen.getByTestId('overview-runtime-phase')).toHaveTextContent('Running')
    expect(screen.getByTestId('overview-runtime-pod-uid')).toHaveTextContent('uid-9876-5432')
  })

  it('renders Responsibility & Ownership panel with assigned owner and decoupling note', () => {
    const agent = createMockAgent()
    renderTab(<AgentOverviewTab agent={agent} />)

    expect(screen.getByTestId('overview-section-responsibility')).toBeInTheDocument()
    expect(screen.getByTestId('overview-responsibility-owner')).toHaveTextContent('alice@signal-loom.ai')
    expect(screen.getByTestId('overview-responsibility-team')).toHaveTextContent('SecOps Core')
    expect(screen.getByTestId('overview-responsibility-status')).toHaveTextContent('assigned')
    expect(screen.getByTestId('overview-responsibility-tenant')).toHaveTextContent('tenant-acme')
    expect(screen.getByText(/Identity Plane Decoupling:/i)).toBeInTheDocument()
  })

  it('renders truthful "Registry not linked" for discovered unlinked workloads', () => {
    const agent = createMockAgent({
      owner: undefined,
      record_class: 'discovered',
      is_registry_linked: false,
      responsibility: {
        owner_id: null,
        owner_name: null,
        team: null,
        assignment_status: 'registry_unlinked',
      },
    })
    renderTab(<AgentOverviewTab agent={agent} />)

    expect(screen.getByTestId('overview-responsibility-owner')).toHaveTextContent('Registry not linked')
  })

  it('renders truthful "Unassigned" when owner metadata is absent on registered workload', () => {
    const agent = createMockAgent({
      owner: undefined,
      record_class: 'registered',
      is_registry_linked: true,
      responsibility: {
        owner_id: null,
        owner_name: null,
        team: null,
        assignment_status: 'unassigned',
      },
    })
    renderTab(<AgentOverviewTab agent={agent} />)

    expect(screen.getByTestId('overview-responsibility-owner')).toHaveTextContent('Unassigned')
  })

  it('renders Evidence Sources & Freshness panel with microservice health and timestamps', () => {
    const agent = createMockAgent()
    const healthDetail: SourceHealthMap = {
      k8s_discovery: { status: 'healthy', message: 'OK' },
      postgres_registry: { status: 'healthy', message: 'OK' },
      crypto_proofs: { status: 'healthy', message: 'OK' },
    }
    renderTab(<AgentOverviewTab agent={agent} sourceHealth="healthy" sourceHealthDetail={healthDetail} />)

    expect(screen.getByTestId('overview-section-source-health')).toBeInTheDocument()
    expect(screen.getByTestId('overview-overall-source-health')).toHaveTextContent('Healthy')
    expect(screen.getByTestId('overview-k8s-health')).toHaveTextContent('healthy')
    expect(screen.getByTestId('overview-postgres-health')).toHaveTextContent('healthy')
    expect(screen.getByTestId('overview-crypto-health')).toHaveTextContent('healthy')
    expect(screen.getByTestId('overview-last-observed')).toBeInTheDocument()
    expect(screen.getByTestId('overview-last-transition')).toBeInTheDocument()
    expect(screen.getByTestId('overview-last-action')).toBeInTheDocument()
  })

  it('renders truthful "Source unavailable" when collector health is unavailable', () => {
    const agent = createMockAgent()
    renderTab(<AgentOverviewTab agent={agent} sourceHealth="unavailable" />)

    expect(screen.getByTestId('overview-overall-source-health')).toHaveTextContent('Source unavailable')
    expect(screen.getByTestId('overview-k8s-health')).toHaveTextContent('unavailable')
  })
})

describe('AgentOverviewTab — Deep-Link Actions Integration', () => {
  it('renders scoped deep-link buttons pointing to dossier tabs and secondary investigative surfaces with correct query params', () => {
    const agent = createMockAgent()
    renderTab(<AgentOverviewTab agent={agent} />)

    const identityLink = screen.getByTestId('overview-link-identity')
    expect(identityLink).toHaveAttribute('href', `/agents/${agent.id}?tab=identity`)

    const accessLink = screen.getByTestId('overview-link-access')
    expect(accessLink).toHaveAttribute('href', `/agents/${agent.id}?tab=access`)

    const assessmentsLink = screen.getByTestId('overview-link-assessments')
    expect(assessmentsLink).toHaveAttribute('href', `/agents/${agent.id}?tab=assessments`)

    const activityLink = screen.getByTestId('overview-link-activity')
    expect(activityLink).toHaveAttribute('href', `/agents/${agent.id}?tab=activity`)

    const auditLink = screen.getByTestId('overview-deeplink-audit')
    expect(auditLink).toHaveAttribute('href', `/audit?agent=${encodeURIComponent(agent.id)}`)

    const credLink = screen.getByTestId('overview-deeplink-credentials')
    expect(credLink).toHaveAttribute('href', `/credential-inventory?actor=${encodeURIComponent(agent.id)}`)

    const topologyLink = screen.getByTestId('overview-deeplink-topology')
    expect(topologyLink).toHaveAttribute('href', `/agent-trust-topology?actor=${encodeURIComponent(agent.id)}`)
  })
})
