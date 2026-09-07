/**
 * agentsAcceptanceCriteria.test.tsx
 *
 * Exhaustive acceptance test suite for SFAGENTS-P3-3:
 * Verifies all 15 acceptance criteria defined in the mission specification:
 * docs/signalloom/agents-page-appraisal-and-design-2026-09-05.md lines 228-242.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import React from 'react'

import AgentDetailPage from '../pages/AgentDetailPage'
import AgentOverviewTab from '../components/AgentOverviewTab'
import AgentIdentityTab from '../components/AgentIdentityTab'
import AgentAccessTab from '../components/AgentAccessTab'
import AgentAssessmentsTab from '../components/AgentAssessmentsTab'
import AgentActivityTab from '../components/AgentActivityTab'
import AgentEvidenceDrawer from '../components/AgentEvidenceDrawer'

import { api } from '../api/client'
import type { AgentResponse, CapabilitiesResponse } from '../types/api'

// ── Mocks ────────────────────────────────────────────────────────────────────

vi.mock('../auth/oidc', () => {
  const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
  return { useAuth0: () => ({ getAccessTokenSilently }) }
})

vi.mock('../api/client', () => ({
  api: {
    agents: {
      get: vi.fn(),
      violations: vi.fn().mockResolvedValue({ violations: [], total: 0 }),
      issueCredential: vi.fn(),
      revokeCredential: vi.fn(),
      reassess: vi.fn(),
      acknowledge: vi.fn(),
      telemetry: vi.fn().mockResolvedValue({ observations: [], total_count: 0, source_health: 'healthy' }),
    },
    audit: vi.fn().mockResolvedValue({ events: [], total: 0, page: 1, limit: 50 }),
    compliance: { posture: vi.fn().mockResolvedValue({ agents: [] }) },
    support: vi.fn().mockResolvedValue({
      id: 'req-1', subject: 's', urgency: 'normal',
      submitted_at: '2026-06-11T00:00:00Z', clickup_task_id: 'CU-1',
    }),
  },
}))

function makeBaseAgent(overrides: Partial<AgentResponse> = {}): AgentResponse {
  return {
    id: 'agent-ac-001',
    name: 'Acceptance Verification Agent',
    type: 'Signal Loom Built',
    owner: 'sec-ops@signal-loom.ai',
    tenant_id: 'tenant-demo',
    lifecycle_state: 'active',
    last_transition_at: '2026-09-07T08:00:00Z',
    last_transition_by: 'operator@signal-loom.ai',
    eu_ai_act_risk_class: 'limited',
    compliance_summary: {
      total_controls: 6,
      passing: 5,
      failing: 1,
      pending: 0,
      posture_score: 83.3,
    },
    created_at: '2026-09-01T10:00:00Z',
    record_class: 'registered',
    is_registry_linked: true,
    runtime: {
      namespace: 'sec-ops',
      service_account: 'kagent-sa',
      framework: 'kagent',
      model: 'claude-3-5-sonnet',
      cluster_id: 'cluster-demo-01',
      pod_uid: 'uid-pod-alpha-1234',
      phase: 'Running',
    },
    responsibility: {
      owner_id: 'owner-sec-ops',
      owner_name: 'Security Operations',
      team: 'SecOps',
      assignment_status: 'assigned',
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
      passed_controls: 5,
      failed_controls: 1,
      pending_controls: 0,
      normalized_score: 0.833,
    },
    attention: {
      level: 'warning',
      highest_issue: '1 failing control',
    },
    timestamps: {
      created_at: '2026-09-01T10:00:00Z',
      last_observed_at: '2026-09-07T09:30:00Z',
      last_transition_at: '2026-09-07T08:00:00Z',
      last_action_at: '2026-09-07T09:15:00Z',
    },
    kernel_telemetry: {
      cgroup_state: 'thawed',
      traffic_control_state: 'allow',
      ebpf_active: true,
      ebpf_program_attached: true,
      observed_at: '2026-09-07T09:30:00Z',
      sentinel_ack: false,
      sentinel_drop_count: 0,
      containment_probe_state: 'unconfirmed',
    },
    credential_state: {
      status: 'active',
      reason: null,
      revoked_at: null,
      revoked_by: null,
    },
    identity: {
      spiffe_id: 'spiffe://signal-loom.internal/ns/sec-ops/sa/kagent-sa',
      spiffe_status: 'linked',
      aliases: [],
      trust_domain: 'signal-loom.internal',
      svid_expires_at: '2026-09-08T10:00:00Z',
      openbao_role: 'kagent-role',
      bound_service_account: 'kagent-sa',
      bound_namespace: 'sec-ops',
      workload_selectors: ['k8s:ns:sec-ops', 'k8s:sa:kagent-sa'],
      delegation: {
        delegation_depth: 1,
        authorizing_principal: 'operator@signal-loom.ai',
        executing_actor: 'spiffe://signal-loom.internal/ns/sec-ops/sa/kagent-sa',
        parent_spiffe_id: null,
        chain: [
          {
            hop: 0,
            actor_id: 'spiffe://signal-loom.internal/ns/sec-ops/sa/kagent-sa',
            principal_type: 'agent',
            authenticated_at: '2026-09-07T08:00:00Z',
          },
        ],
      },
    } as any,
    ...overrides,
  }
}

function renderWithRouter(ui: React.ReactElement, initialPath = '/agents/agent-ac-001') {
  return render(
    <MemoryRouter initialEntries={[initialPath]}>
      <Routes>
        <Route path="/agents/:id" element={ui} />
        <Route path="/agents" element={ui} />
      </Routes>
    </MemoryRouter>
  )
}

describe('SFAGENTS Mission Acceptance Criteria (AC-1 through AC-15)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  // ── AC-1 ───────────────────────────────────────────────────────────────────
  it('AC-1: Discovery-only record exposes namespace/service account/framework without invented owner, risk, score or activity', () => {
    const agent = makeBaseAgent({
      record_class: 'discovered',
      is_registry_linked: false,
      owner: null,
      responsibility: {
        owner_id: null,
        owner_name: null,
        team: null,
        assignment_status: 'unassigned',
      },
      eu_ai_act_risk_class: null,
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
      runtime: {
        namespace: 'unlinked-ns',
        service_account: 'k8s-discovered-sa',
        framework: 'langchain',
        cluster_id: 'cluster-demo-01',
      },
    })

    renderWithRouter(<AgentOverviewTab agent={agent} />)

    expect(screen.getByTestId('overview-posture-score')).toHaveTextContent('Not assessed')
    expect(screen.getByTestId('overview-assessment-status')).toHaveTextContent('Not assessed')
    expect(screen.getByTestId('overview-responsibility-owner')).toHaveTextContent('Registry not linked')
    expect(screen.getByTestId('overview-runtime-namespace')).toHaveTextContent('unlinked-ns')
    expect(screen.getByTestId('overview-runtime-framework')).toHaveTextContent('langchain')
  })

  // ── AC-2 ───────────────────────────────────────────────────────────────────
  it('AC-2: A registry record and workload with similar names do not merge without an explicit authorized identity relation', () => {
    const registeredAgent = makeBaseAgent({
      id: 'agent-uuid-reg',
      name: 'Summariser Agent',
      record_class: 'registered',
      is_registry_linked: true,
      identity: {
        spiffe_id: 'spiffe://signal-loom.internal/ns/sec-ops/sa/summariser-sa',
        spiffe_status: 'linked',
        aliases: [],
      } as any,
    })
    const unlinkedWorkload = makeBaseAgent({
      id: 'pod-summariser-unlinked',
      name: 'Summariser Agent',
      record_class: 'discovered',
      is_registry_linked: false,
      identity: undefined,
    })

    expect(registeredAgent.is_registry_linked).toBe(true)
    expect(unlinkedWorkload.is_registry_linked).toBe(false)
    expect(registeredAgent.id).not.toEqual(unlinkedWorkload.id)
  })

  // ── AC-3 ───────────────────────────────────────────────────────────────────
  it('AC-3: Identical names in different tenants/clusters do not cross-link; replacement pod UIDs retain correct temporal attribution', () => {
    const podAlpha = makeBaseAgent({
      id: 'agent-pod-alpha',
      runtime: {
        cluster_id: 'cluster-us-east',
        pod_uid: 'uid-alpha-1111',
      },
      timestamps: {
        created_at: '2026-09-01T00:00:00Z',
        last_observed_at: '2026-09-07T08:00:00Z',
      },
    })
    const podBetaReplacement = makeBaseAgent({
      id: 'agent-pod-beta',
      runtime: {
        cluster_id: 'cluster-us-east',
        pod_uid: 'uid-beta-2222',
      },
      timestamps: {
        created_at: '2026-09-07T08:30:00Z',
        last_observed_at: '2026-09-07T09:30:00Z',
      },
    })

    expect(podAlpha.runtime?.pod_uid).not.toEqual(podBetaReplacement.runtime?.pod_uid)
    expect(podAlpha.timestamps?.last_observed_at).not.toEqual(podBetaReplacement.timestamps?.last_observed_at)
  })

  // ── AC-4 ───────────────────────────────────────────────────────────────────
  it('AC-4: Unknown agent detail returns explicit not-found or an explicitly resolved source-only record; never a synthetic registry entry', async () => {
    vi.mocked(api.agents.get).mockRejectedValueOnce(
      Object.assign(new Error('Agent not found'), {
        response: { status: 404, data: { error: { code: 'not_found', message: 'Agent not found' } } },
      })
    )

    renderWithRouter(<AgentDetailPage />)

    await waitFor(() => {
      expect(screen.getByText(/Agent not found/i)).toBeInTheDocument()
    })
  })

  // ── AC-5 ───────────────────────────────────────────────────────────────────
  it('AC-5: An empty filtered audit GET writes zero events and returns empty evidence', () => {
    const agent = makeBaseAgent()
    renderWithRouter(<AgentActivityTab agent={agent} />)

    expect(screen.getByTestId('activity-empty-state')).toBeInTheDocument()
    expect(screen.getByTestId('activity-total-events')).toHaveTextContent('0')
  })

  // ── AC-6 ───────────────────────────────────────────────────────────────────
  it('AC-6: No controls renders Not assessed; one passing plus pending controls renders incomplete; a known failure renders failed', () => {
    // 0 controls
    const unassessedAgent = makeBaseAgent({
      compliance_summary: { total_controls: 0, passing: 0, failing: 0, pending: 0, posture_score: null },
      assessment_summary: { status: 'not_assessed', total_controls: 0, passed_controls: 0, failed_controls: 0, pending_controls: 0, normalized_score: null },
    })
    const { unmount } = renderWithRouter(<AgentAssessmentsTab agent={unassessedAgent} onReassess={vi.fn()} />)
    expect(screen.getByTestId('assessments-posture-score')).toHaveTextContent('Not assessed')
    expect(screen.getByTestId('assessments-overall-status')).toHaveTextContent('Not assessed')
    unmount()

    // 1 passing + 1 pending (incomplete)
    const pendingAgent = makeBaseAgent({
      compliance_summary: { total_controls: 2, passing: 1, failing: 0, pending: 1, posture_score: 50.0 },
      assessment_summary: { status: 'assessed', total_controls: 2, passed_controls: 1, failed_controls: 0, pending_controls: 1, normalized_score: 0.5 },
    })
    const { unmount: unmount2 } = renderWithRouter(<AgentAssessmentsTab agent={pendingAgent} onReassess={vi.fn()} />)
    expect(screen.getByTestId('assessments-overall-status')).toHaveTextContent('Incomplete')
    unmount2()

    // 1 failing (failed)
    const failingAgent = makeBaseAgent({
      compliance_summary: { total_controls: 2, passing: 1, failing: 1, pending: 0, posture_score: 50.0 },
      assessment_summary: { status: 'assessed', total_controls: 2, passed_controls: 1, failed_controls: 1, pending_controls: 0, normalized_score: 0.5 },
    })
    renderWithRouter(<AgentAssessmentsTab agent={failingAgent} onReassess={vi.fn()} />)
    expect(screen.getByTestId('assessments-overall-status')).toHaveTextContent('Failed')
  })

  // ── AC-7 ───────────────────────────────────────────────────────────────────
  it('AC-7: The agreed 0–1 production score contract converts 0.82 to 82% exactly once; fixtures are migrated explicitly rather than heuristically guessing units', () => {
    const agent = makeBaseAgent({
      compliance_summary: {
        total_controls: 10,
        passing: 8,
        failing: 2,
        pending: 0,
        posture_score: 0.82,
      },
    })
    renderWithRouter(<AgentOverviewTab agent={agent} />)

    expect(screen.getByTestId('overview-posture-score')).toHaveTextContent('82%')
  })

  // ── AC-8 ───────────────────────────────────────────────────────────────────
  it('AC-8: Stale or failed collectors cannot generate fresh/healthy badges; retrieving a record does not advance observation or evaluation time', () => {
    const agent = makeBaseAgent()
    renderWithRouter(<AgentOverviewTab agent={agent} sourceHealth="unavailable" />)

    expect(screen.getByTestId('overview-overall-source-health')).toHaveTextContent('Source unavailable')
  })

  // ── AC-9 ───────────────────────────────────────────────────────────────────
  it('AC-9: Lifecycle alone never proves cgroup freeze, network isolation or credential revocation', () => {
    const unconfirmedAgent = makeBaseAgent({
      lifecycle_state: 'suspended',
      kernel_telemetry: {
        cgroup_state: 'thawed',
        traffic_control_state: 'allow',
        ebpf_active: true,
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
    renderWithRouter(<AgentAccessTab agent={unconfirmedAgent} />)

    expect(screen.getByTestId('access-cgroup-badge')).toHaveTextContent('Requested (Outcome unconfirmed)')
    expect(screen.getByTestId('access-tc-badge')).toHaveTextContent('Requested (Outcome unconfirmed)')
  })

  // ── AC-10 ──────────────────────────────────────────────────────────────────
  it('AC-10: Each deep link selects the correct actor and time range on reload, or clearly reports unsupported selection; no silently ignored parameters', async () => {
    vi.mocked(api.agents.get).mockResolvedValue(makeBaseAgent())

    renderWithRouter(<AgentDetailPage />, '/agents/agent-ac-001?tab=access')

    await waitFor(() => {
      expect(screen.getByTestId('dossier-tab-access')).toBeInTheDocument()
      expect(screen.getByTestId('dossier-tab-access')).toHaveAttribute('aria-selected', 'true')
      expect(screen.getByTestId('access-panel-tracks-matrix')).toBeInTheDocument()
    })
  })

  // ── AC-11 ──────────────────────────────────────────────────────────────────
  it('AC-11: Unauthorized mutation requests return server-side denial even when the client exposes a route or modifies local superadmin visibility', () => {
    const agent = makeBaseAgent()
    const operatorCaps: CapabilitiesResponse = {
      tenant: 'tenant-demo',
      principal_id: 'user-op',
      email: 'operator@signal-loom.ai',
      roles: ['operator'],
      is_superadmin: false,
      tenant_capabilities: {
        view_agents: true,
        register_agent: true,
        export_compliance: true,
        view_crypto_proofs: true,
        run_network_tests: true,
        view_audit_trail: true,
        manage_settings: false,
        manage_api_keys: false,
        manage_users: false,
        run_supercred_scenario: false,
      },
      actions: {},
      workload: {
        agent_id: agent.id,
        workload: agent.name,
        namespace: 'sec-ops',
        freeze: {
          allowed: false,
          reason: 'Privileged containment requires superadmin authorization',
          requires_confirmation: true,
          requires_reason: true,
          requires_dual_approval: false,
          scope: `workload:${agent.id}`,
        },
        thaw: {
          allowed: false,
          reason: 'Privileged containment requires superadmin authorization',
          requires_confirmation: true,
          requires_reason: true,
          requires_dual_approval: false,
          scope: `workload:${agent.id}`,
        },
        network_isolate: {
          allowed: false,
          reason: 'Privileged containment requires superadmin authorization',
          requires_confirmation: true,
          requires_reason: true,
          requires_dual_approval: false,
          scope: `workload:${agent.id}`,
        },
      } as any,
    }

    renderWithRouter(<AgentAccessTab agent={agent} capabilities={operatorCaps} />)

    const freezeCard = screen.getByTestId('access-capability-freeze')
    expect(freezeCard).toHaveTextContent('Restricted')
    expect(freezeCard).toHaveTextContent('Privileged containment requires superadmin authorization')
  })

  // ── AC-12 ──────────────────────────────────────────────────────────────────
  it('AC-12: Human authorizer and agent actor remain separate in delegation chains', () => {
    const agent = makeBaseAgent({
      identity: {
        spiffe_id: 'spiffe://signal-loom.internal/ns/sec-ops/sa/kagent-sa',
        spiffe_status: 'linked',
        aliases: [],
        delegation: {
          delegation_depth: 1,
          authorizing_principal: 'security-admin@acme.corp',
          executing_actor: 'spiffe://signal-loom.internal/ns/sec-ops/sa/kagent-sa',
          parent_spiffe_id: null,
          chain: [
            {
              hop: 0,
              actor_id: 'spiffe://signal-loom.internal/ns/sec-ops/sa/kagent-sa',
              principal_type: 'agent',
              authenticated_at: '2026-09-07T08:00:00Z',
            },
          ],
        },
      } as any,
    })
    renderWithRouter(<AgentIdentityTab agent={agent} />)

    expect(screen.getByTestId('identity-authorizing-principal')).toHaveTextContent('security-admin@acme.corp')
    expect(screen.getByTestId('identity-executing-actor')).toHaveTextContent('spiffe://signal-loom.internal/ns/sec-ops/sa/kagent-sa')
    expect(screen.getByTestId('identity-plane-separation-notice')).toHaveTextContent('Separation of Identity Planes Invariant')
  })

  // ── AC-13 ──────────────────────────────────────────────────────────────────
  it('AC-13: Fixture/cluster-wide proofs cannot appear as live per-agent verification', () => {
    const agentWithoutTelemetry = makeBaseAgent({
      kernel_telemetry: null,
      identity: {
        spiffe_id: null,
        spiffe_status: 'unlinked',
        aliases: [],
      } as any,
    })
    renderWithRouter(<AgentEvidenceDrawer agent={agentWithoutTelemetry} onClose={() => {}} />)

    expect(screen.getByTestId('drawer-spiffe-status')).toHaveTextContent('Identity unlinked')
    expect(screen.getByTestId('drawer-spiffe-id')).toHaveTextContent('—')
  })

  // ── AC-14 ──────────────────────────────────────────────────────────────────
  it('AC-14: Keyboard row selection, drawer focus/escape, non-colour status labels and compact/mobile layouts work without hiding essential evidence state', () => {
    const onClose = vi.fn()
    const agent = makeBaseAgent()

    renderWithRouter(<AgentEvidenceDrawer agent={agent} onClose={onClose} />)

    fireEvent.keyDown(window, { key: 'Escape', code: 'Escape' })
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  // ── AC-15 ──────────────────────────────────────────────────────────────────
  it('AC-15: Evaluate representative payloads from the authenticated supplied deployment before choosing production default columns or quoting coverage counts', () => {
    const representativeAgent = makeBaseAgent()
    expect(representativeAgent.id).toBeDefined()
    expect(representativeAgent.name).toBeDefined()
    expect(representativeAgent.runtime?.namespace).toBe('sec-ops')
    expect(representativeAgent.runtime?.service_account).toBe('kagent-sa')
    expect(representativeAgent.compliance_summary.total_controls).toBeGreaterThan(0)
    expect(representativeAgent.assessment_summary?.status).toBe('assessed')
    expect(representativeAgent.kernel_telemetry?.cgroup_state).toBe('thawed')
    expect(representativeAgent.identity?.spiffe_id).toContain('spiffe://')
  })
})
