import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import AgentAccessTab from './AgentAccessTab'
import type { AgentResponse, CapabilitiesResponse } from '../types/api'

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
      observed_at: '2026-09-07T09:30:00Z',
    },
    credential_state: {
      status: 'active',
      reason: null,
      revoked_at: null,
      revoked_by: null,
    },
    ...overrides,
  }
}

function createMockCapabilities(isSuperadmin = false): CapabilitiesResponse {
  return {
    tenant: 'tenant-acme',
    principal_id: 'user-123',
    email: 'operator@signal-loom.ai',
    roles: isSuperadmin ? ['superadmin', 'operator'] : ['operator'],
    is_superadmin: isSuperadmin,
    tenant_capabilities: {
      view_agents: true,
      register_agent: true,
      export_compliance: true,
      view_crypto_proofs: true,
      run_network_tests: true,
      view_audit_trail: true,
      manage_settings: isSuperadmin,
      manage_api_keys: isSuperadmin,
      manage_users: isSuperadmin,
      run_supercred_scenario: isSuperadmin,
    },
    actions: {},
    workload: {
      agent_id: 'agent-123-uuid',
      workload: 'Order Processing Agent',
      namespace: 'fe-signalloom-agents',
      freeze: {
        allowed: isSuperadmin,
        reason: isSuperadmin ? 'Permitted for superadmin' : 'Privileged containment requires superadmin authorization',
        requires_confirmation: true,
        requires_reason: true,
        requires_dual_approval: false,
        scope: 'workload:agent-123-uuid',
      },
      thaw: {
        allowed: isSuperadmin,
        reason: isSuperadmin ? 'Permitted for superadmin' : 'Privileged containment requires superadmin authorization',
        requires_confirmation: true,
        requires_reason: true,
        requires_dual_approval: false,
        scope: 'workload:agent-123-uuid',
      },
      network_isolate: {
        allowed: isSuperadmin,
        reason: isSuperadmin ? 'Permitted for superadmin' : 'Privileged network isolation requires superadmin authorization',
        requires_confirmation: true,
        requires_reason: true,
        requires_dual_approval: false,
        scope: 'workload:agent-123-uuid',
      },
      network_restore: {
        allowed: isSuperadmin,
        reason: isSuperadmin ? 'Permitted for superadmin' : 'Privileged network restoration requires superadmin authorization',
        requires_confirmation: true,
        requires_reason: true,
        requires_dual_approval: false,
        scope: 'workload:agent-123-uuid',
      },
      revoke_credentials: {
        allowed: isSuperadmin,
        reason: isSuperadmin ? 'Permitted for superadmin' : 'Credential revocation requires superadmin authorization',
        requires_confirmation: true,
        requires_reason: true,
        requires_dual_approval: false,
        scope: 'workload:agent-123-uuid',
      },
      issue_credentials: {
        allowed: true,
        reason: 'Permitted for tenant operator',
        requires_confirmation: false,
        requires_reason: false,
        requires_dual_approval: false,
        scope: 'workload:agent-123-uuid',
      },
      reassess_compliance: {
        allowed: true,
        reason: 'Permitted for tenant operator',
        requires_confirmation: false,
        requires_reason: false,
        requires_dual_approval: false,
        scope: 'workload:agent-123-uuid',
      },
      decommission: {
        allowed: false,
        reason: 'Irreversible decommission requires enforced dual approval',
        requires_confirmation: true,
        requires_reason: true,
        requires_dual_approval: true,
        scope: 'workload:agent-123-uuid',
      },
      run_scenario: {
        allowed: isSuperadmin,
        reason: isSuperadmin ? 'Permitted for superadmin in lab/demo environment' : 'SuperCred demo scenarios require superadmin authorization',
        requires_confirmation: true,
        requires_reason: false,
        requires_dual_approval: false,
        scope: 'workload:agent-123-uuid',
      },
    },
    source_health: 'healthy',
  }
}

describe('AgentAccessTab — 3 Independent Containment Tracks & StatCards', () => {
  it('renders all 4 overview StatCards with initial normal state', () => {
    const agent = createMockAgent()
    render(<AgentAccessTab agent={agent} />)

    expect(screen.getByTestId('access-track-cgroup')).toBeInTheDocument()
    expect(screen.getByTestId('access-track-tc')).toBeInTheDocument()
    expect(screen.getByTestId('access-track-spiffe-crl')).toBeInTheDocument()
    expect(screen.getByTestId('access-track-sentinel')).toBeInTheDocument()

    expect(screen.getByTestId('access-cgroup-badge')).toHaveTextContent('cgroup: THAWED')
    expect(screen.getByTestId('access-tc-badge')).toHaveTextContent('TC: PASS')
    expect(screen.getByTestId('access-spiffe-crl-badge')).toHaveTextContent('SVID: ACTIVE')
    expect(screen.getByTestId('access-ebpf-status')).toHaveTextContent('eBPF Sentinel Active')
  })

  it('renders observed cgroup FROZEN and TC DROP when kernel telemetry confirms containment', () => {
    const agent = createMockAgent({
      lifecycle_state: 'suspended',
      kernel_telemetry: {
        cgroup_state: 'frozen',
        traffic_control_state: 'drop',
        ebpf_active: true,
        ebpf_program_attached: true,
        observed_at: '2026-09-07T09:35:00Z',
      },
      credential_state: {
        status: 'revoked',
        reason: 'compliance-failure: securityContext not set',
        revoked_at: '2026-09-07T09:35:00Z',
        revoked_by: 'platform/sentinel-governor',
      },
    })
    render(<AgentAccessTab agent={agent} />)

    expect(screen.getByTestId('access-cgroup-badge')).toHaveTextContent('cgroup: FROZEN')
    expect(screen.getByTestId('access-tc-badge')).toHaveTextContent('TC: DROP')
    expect(screen.getByTestId('access-spiffe-crl-badge')).toHaveTextContent('CRL: REVOKED')
  })

  it('renders "Requested (Outcome unconfirmed)" when containment is requested without kernel telemetry ACK', () => {
    const agent = createMockAgent({
      lifecycle_state: 'suspended',
      kernel_telemetry: {
        cgroup_state: 'thawed',
        traffic_control_state: 'allow',
        ebpf_active: true,
        ebpf_program_attached: true,
      },
      operational_state: {
        runtime_status: 'suspended',
        containment: {
          process_freeze: 'requested',
          network_isolation: 'requested',
          credential_revocation: 'requested',
        },
      },
    })
    render(<AgentAccessTab agent={agent} />)

    expect(screen.getByTestId('access-cgroup-badge')).toHaveTextContent('Requested (Outcome unconfirmed)')
    expect(screen.getByTestId('access-tc-badge')).toHaveTextContent('Requested (Outcome unconfirmed)')
    expect(screen.getByTestId('access-spiffe-crl-badge')).toHaveTextContent('Requested (Outcome unconfirmed)')
  })
})

describe('AgentAccessTab — Containment Tracks Matrix Table', () => {
  it('renders the 3 independent tracks table with enforcement layers and telemetry signals', () => {
    const agent = createMockAgent()
    render(<AgentAccessTab agent={agent} />)

    const matrix = screen.getByTestId('access-panel-tracks-matrix')
    expect(matrix).toBeInTheDocument()
    expect(matrix).toHaveTextContent('Process Execution (Freeze)')
    expect(matrix).toHaveTextContent('Network Boundary (Isolation)')
    expect(matrix).toHaveTextContent('Cryptographic Auth (Revocation)')
    expect(matrix).toHaveTextContent('Linux cgroup v2 (cgroup.freeze)')
    expect(matrix).toHaveTextContent('Traffic Control (cls_bpf / TC matchall)')
    expect(matrix).toHaveTextContent('SPIFFE SVID CRL & OpenBao JWT Roles')
  })
})

describe('AgentAccessTab — Server-Authorized Action Capabilities & RBAC', () => {
  it('renders capabilities for tenant operator with restricted privileged containment actions', () => {
    const agent = createMockAgent()
    const caps = createMockCapabilities(false) // Non-superadmin operator
    render(<AgentAccessTab agent={agent} capabilities={caps} />)

    expect(screen.getByTestId('access-panel-capabilities')).toBeInTheDocument()
    expect(screen.getByTestId('access-identity-planes-callout')).toBeInTheDocument()
    expect(screen.getByTestId('access-identity-planes-callout')).toHaveTextContent('Separation of Identity Planes Invariant')

    // Freeze is restricted for operator
    const freezeCard = screen.getByTestId('access-capability-freeze')
    expect(freezeCard).toHaveTextContent('Process Freeze')
    expect(freezeCard).toHaveTextContent('Restricted')
    expect(freezeCard).toHaveTextContent('Privileged containment requires superadmin authorization')

    // Issue credentials is allowed for operator
    const issueCard = screen.getByTestId('access-capability-issue_credentials')
    expect(issueCard).toHaveTextContent('Issue Credentials')
    expect(issueCard).toHaveTextContent('Allowed')
    expect(issueCard).toHaveTextContent('Permitted for tenant operator')

    // Decommission is restricted with dual approval required
    const decomCard = screen.getByTestId('access-capability-decommission')
    expect(decomCard).toHaveTextContent('Decommission Workload')
    expect(decomCard).toHaveTextContent('Restricted')
    expect(decomCard).toHaveTextContent('Irreversible decommission requires enforced dual approval')
    expect(decomCard).toHaveTextContent('Dual approval')
  })

  it('renders capabilities for superadmin with permitted containment actions', () => {
    const agent = createMockAgent()
    const caps = createMockCapabilities(true) // Superadmin
    render(<AgentAccessTab agent={agent} capabilities={caps} />)

    const freezeCard = screen.getByTestId('access-capability-freeze')
    expect(freezeCard).toHaveTextContent('Process Freeze')
    expect(freezeCard).toHaveTextContent('Allowed')
    expect(freezeCard).toHaveTextContent('Permitted for superadmin')

    const isolateCard = screen.getByTestId('access-capability-network_isolate')
    expect(isolateCard).toHaveTextContent('Network Isolate')
    expect(isolateCard).toHaveTextContent('Allowed')
    expect(isolateCard).toHaveTextContent('Permitted for superadmin')
  })
})

describe('AgentAccessTab — Truthful Language Dictionary', () => {
  it('renders truthful "Not assessed" when controls evaluated is 0', () => {
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
      },
    })
    render(<AgentAccessTab agent={agent} />)

    expect(screen.getByTestId('access-posture-truthful')).toHaveTextContent('Not assessed')
  })

  it('renders truthful "Unassigned" when owner metadata is absent', () => {
    const agent = createMockAgent({
      owner: null,
      responsibility: {
        owner_id: null,
        owner_name: null,
        team: null,
        assignment_status: 'unassigned',
      },
    })
    render(<AgentAccessTab agent={agent} />)

    expect(screen.getByTestId('access-owner-truthful')).toHaveTextContent('Unassigned')
  })

  it('renders truthful "Registry not linked" for unlinked discovered workloads', () => {
    const agent = createMockAgent({
      owner: null,
      record_class: 'discovered',
      is_registry_linked: false,
      responsibility: {
        owner_id: null,
        owner_name: null,
        team: null,
        assignment_status: 'registry_unlinked',
      },
    })
    render(<AgentAccessTab agent={agent} />)

    expect(screen.getByTestId('access-owner-truthful')).toHaveTextContent('Registry not linked')
  })

  it('renders truthful "Source unavailable" when collector source health is unavailable', () => {
    const agent = createMockAgent()
    render(<AgentAccessTab agent={agent} sourceHealth="unavailable" />)

    expect(screen.getByTestId('access-source-health-truthful')).toHaveTextContent('Source unavailable')
  })
})
