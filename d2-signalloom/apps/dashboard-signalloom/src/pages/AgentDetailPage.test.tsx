/**
 * Tests for the Dossier Route & Tab 1 (Overview) on the Agent Detail page.
 *
 * Covers:
 * - 5-tab Dossier navigation architecture (Overview, Identity, Access & Containment, Assessments & Controls, Activity & Timeline)
 * - Tab 1 (Overview) 4 StatCards summary grid and 3 snapshot detail panels
 * - Truthful language dictionary enforcement ('Not assessed', 'Unassigned', 'Registry not linked', 'Requested (Outcome unconfirmed)')
 * - Observed kernel containment telemetry vs lifecycle requests
 * - Request Transition operator flow
 * - Credential management (issue & revoke)
 * - Activity timeline tab
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import AgentDetailPage from './AgentDetailPage'
import { api } from '../api/client'
import type { AgentResponse } from '../types/api'

// ── Mocks ──────────────────────────────────────────────────────────────────

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
    },
    audit: vi.fn().mockResolvedValue({ events: [], total: 0, page: 1, limit: 50 }),
    compliance: { posture: vi.fn().mockResolvedValue({ agents: [] }) },
    support: vi.fn().mockResolvedValue({
      id: 'req-1', subject: 's', urgency: 'normal',
      submitted_at: '2026-06-11T00:00:00Z', clickup_task_id: 'CU-1',
    }),
  },
}))

function makeAgent(overrides: Partial<AgentResponse> = {}): AgentResponse {
  return {
    id: 'agent-abc-123',
    name: 'Invoice Bot',
    type: 'Signal Loom Built',
    owner: 'ops@acme.com',
    tenant_id: 'tenant-1',
    lifecycle_state: 'enrolled',
    last_transition_at: '2026-06-01T00:00:00Z',
    last_transition_by: 'operator@signal-loom.ai',
    eu_ai_act_risk_class: 'limited',
    compliance_summary: { total_controls: 6, passing: 4, failing: 0, pending: 2, posture_score: 67 },
    created_at: '2026-05-01T00:00:00Z',
    record_class: 'registered',
    is_registry_linked: true,
    runtime: {
      cluster_id: 'cluster-local',
      namespace: 'fe-signalloom-agents',
      pod_name: 'invoice-bot-pod-123',
      pod_uid: 'uid-1111-2222',
      service_account: 'sa-invoice-bot',
      framework: 'kagent',
      model: 'claude-3-7-sonnet',
      execution_mode: 'autonomous',
      node: 'kind-worker-1',
      phase: 'Running',
    },
    responsibility: {
      owner_id: 'user-ops',
      owner_name: 'ops@acme.com',
      team: 'Finance SecOps',
      assignment_status: 'assigned',
    },
    identity: {
      spiffe_id: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-invoice-bot',
      spiffe_status: 'linked',
      aliases: ['inv-bot-v1'],
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
      highest_issue: 'No verified issues',
    },
    timestamps: {
      created_at: '2026-05-01T00:00:00Z',
      last_observed_at: '2026-09-07T09:00:00Z',
      last_transition_at: '2026-06-01T00:00:00Z',
      last_action_at: '2026-09-07T08:45:00Z',
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

function renderPage(initialEntry = '/agents/agent-abc-123') {
  return render(
    <MemoryRouter initialEntries={[initialEntry]}>
      <Routes>
        <Route path="/agents/:id" element={<AgentDetailPage />} />
      </Routes>
    </MemoryRouter>
  )
}

async function openCredentialMenu() {
  await userEvent.click(await screen.findByRole('button', { name: /manage credentials/i }))
}

beforeEach(() => {
  vi.clearAllMocks()
  ;(api.agents.violations as ReturnType<typeof vi.fn>).mockResolvedValue({ violations: [], total: 0 })
  ;(api.agents.issueCredential as ReturnType<typeof vi.fn>).mockResolvedValue({
    agent_id: 'agent-abc-123',
    name: 'Invoice Bot',
    identity_token: 'demo.jwt.issue',
    token_expires_at: '2026-08-03T00:00:00Z',
    token_note: 'demo note',
  })
  ;(api.agents.revokeCredential as ReturnType<typeof vi.fn>).mockResolvedValue({
    agent_id: 'agent-abc-123',
    name: 'Invoice Bot',
    tokens_revoked: 1,
  })
  ;(api.audit as ReturnType<typeof vi.fn>).mockResolvedValue({ events: [], total: 0, page: 1, limit: 50 })
  ;(api.compliance.posture as ReturnType<typeof vi.fn>).mockResolvedValue({ agents: [] })
  ;(api.support as ReturnType<typeof vi.fn>).mockResolvedValue({
    id: 'req-1', subject: 's', urgency: 'normal',
    submitted_at: '2026-06-11T00:00:00Z', clickup_task_id: 'CU-1',
  })
})

describe('AgentDetailPage — Dossier Route & 5-Tab Navigation', () => {
  it('renders all 5 Dossier tabs with Tab 1 Overview active by default', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent())
    renderPage()

    // 5 tabs present
    expect(await screen.findByTestId('dossier-tab-overview')).toBeInTheDocument()
    expect(screen.getByTestId('dossier-tab-identity')).toBeInTheDocument()
    expect(screen.getByTestId('dossier-tab-access')).toBeInTheDocument()
    expect(screen.getByTestId('dossier-tab-assessments')).toBeInTheDocument()
    expect(screen.getByTestId('dossier-tab-activity')).toBeInTheDocument()

    // Overview panel is visible by default
    expect(screen.getByTestId('dossier-panel-overview')).toBeInTheDocument()
    expect(screen.getByTestId('dossier-tab-overview')).toHaveAttribute('aria-selected', 'true')
  })

  it('switches between tabs on user click', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent())
    renderPage()

    await screen.findByTestId('dossier-panel-overview')

    // Click Identity tab
    await userEvent.click(screen.getByTestId('dossier-tab-identity'))
    expect(screen.getByTestId('dossier-panel-identity')).toBeInTheDocument()
    expect(screen.queryByTestId('dossier-panel-overview')).not.toBeInTheDocument()

    // Click Access tab
    await userEvent.click(screen.getByTestId('dossier-tab-access'))
    expect(screen.getByTestId('dossier-panel-access')).toBeInTheDocument()

    // Click Assessments tab
    await userEvent.click(screen.getByTestId('dossier-tab-assessments'))
    expect(screen.getByTestId('dossier-panel-assessments')).toBeInTheDocument()

    // Click Activity tab
    await userEvent.click(screen.getByTestId('dossier-tab-activity'))
    expect(screen.getByTestId('dossier-panel-activity')).toBeInTheDocument()

    // Return to Overview tab
    await userEvent.click(screen.getByTestId('dossier-tab-overview'))
    expect(screen.getByTestId('dossier-panel-overview')).toBeInTheDocument()
  })

  it('honors initial tab search parameter (?tab=assessments)', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent())
    renderPage('/agents/agent-abc-123?tab=assessments')

    expect(await screen.findByTestId('dossier-panel-assessments')).toBeInTheDocument()
    expect(screen.getByTestId('dossier-tab-assessments')).toHaveAttribute('aria-selected', 'true')
    expect(screen.queryByTestId('dossier-panel-overview')).not.toBeInTheDocument()
  })
})

describe('AgentDetailPage — Tab 1 (Overview) Summary Grid & Snapshot Panels', () => {
  it('renders 4 StatCards and 3 detail panels on Overview tab', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent())
    renderPage()

    // 4 StatCards
    expect(await screen.findByTestId('overview-card-posture')).toBeInTheDocument()
    expect(screen.getByTestId('overview-card-attention')).toBeInTheDocument()
    expect(screen.getByTestId('overview-card-identity')).toBeInTheDocument()
    expect(screen.getByTestId('overview-card-containment')).toBeInTheDocument()

    // 3 Detail Panels
    expect(screen.getByTestId('overview-section-runtime')).toBeInTheDocument()
    expect(screen.getByTestId('overview-section-responsibility')).toBeInTheDocument()
    expect(screen.getByTestId('overview-section-source-health')).toBeInTheDocument()
  })

  it('renders truthful "Not assessed" when total controls evaluated is 0', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(
      makeAgent({
        compliance_summary: { total_controls: 0, passing: 0, failing: 0, pending: 0, posture_score: null },
        assessment_summary: { status: 'not_assessed', total_controls: 0, passed_controls: 0, failed_controls: 0, pending_controls: 0, normalized_score: null },
      })
    )
    renderPage()

    expect(await screen.findByTestId('overview-posture-score')).toHaveTextContent('Not assessed')
    expect(screen.getByTestId('overview-assessment-status')).toHaveTextContent('Not assessed')
  })

  it('renders truthful "Unassigned" when owner metadata is absent on registered record', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(
      makeAgent({
        owner: undefined,
        record_class: 'registered',
        is_registry_linked: true,
        responsibility: { owner_id: null, owner_name: null, team: null, assignment_status: 'unassigned' },
      })
    )
    renderPage()

    expect(await screen.findByTestId('overview-responsibility-owner')).toHaveTextContent('Unassigned')
  })

  it('renders truthful "Registry not linked" for unlinked discovered agent', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(
      makeAgent({
        owner: undefined,
        record_class: 'discovered',
        is_registry_linked: false,
        responsibility: { owner_id: null, owner_name: null, team: null, assignment_status: 'registry_unlinked' },
      })
    )
    renderPage()

    expect(await screen.findByTestId('overview-responsibility-owner')).toHaveTextContent('Registry not linked')
  })

  it('renders kernel telemetry FROZEN and DROP when observed in kernel', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(
      makeAgent({
        kernel_telemetry: {
          cgroup_state: 'frozen',
          traffic_control_state: 'drop',
          ebpf_active: true,
          ebpf_program_attached: true,
        },
      })
    )
    renderPage()

    expect(await screen.findByTestId('overview-kernel-cgroup')).toHaveTextContent('cgroup: FROZEN')
    expect(screen.getByTestId('overview-kernel-tc')).toHaveTextContent('TC: DROP')
  })
})

describe('AgentDetailPage — Tab 2 (Identity & SPIFFE Integration)', () => {
  it('renders Tab 2 Identity panel with SPIFFE SVID, certificate validity, selectors, and delegation chain', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent())
    renderPage('/agents/agent-abc-123?tab=identity')

    expect(await screen.findByTestId('dossier-panel-identity')).toBeInTheDocument()
    expect(screen.getByTestId('identity-card-spiffe')).toBeInTheDocument()
    expect(screen.getByTestId('identity-spiffe-id')).toHaveTextContent(
      'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-invoice-bot'
    )
    expect(screen.getByTestId('identity-spiffe-status')).toHaveTextContent('SPIFFE linked')
    expect(screen.getByTestId('identity-card-cert')).toBeInTheDocument()
    expect(screen.getByTestId('identity-card-selectors')).toBeInTheDocument()
    expect(screen.getByTestId('identity-card-custody')).toBeInTheDocument()
    expect(screen.getByTestId('identity-panel-selectors')).toBeInTheDocument()
    expect(screen.getByTestId('identity-panel-delegation')).toBeInTheDocument()
    expect(screen.getByTestId('identity-panel-vault')).toBeInTheDocument()
  })

  it('renders truthful separation of identity planes with authorizing principal and executing actor', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent())
    renderPage('/agents/agent-abc-123?tab=identity')

    expect(await screen.findByTestId('identity-authorizing-principal')).toHaveTextContent('ops@acme.com')
    expect(screen.getByTestId('identity-executing-actor')).toHaveTextContent(
      'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-invoice-bot'
    )
    expect(screen.getByTestId('identity-plane-separation-notice')).toBeInTheDocument()
  })
})

describe('AgentDetailPage — Header & Interactions', () => {
  it('renders Dossier header with agent name, record class, risk badge, and copy ID button', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent())
    renderPage()

    expect(await screen.findByTestId('dossier-agent-name')).toHaveTextContent('Invoice Bot')
    expect(screen.getByTestId('dossier-record-class')).toHaveTextContent('Registered')
    expect(screen.getByTestId('dossier-lifecycle-badge')).toHaveTextContent('enrolled')
    expect(screen.getByTestId('dossier-risk-class')).toHaveTextContent('limited')
    expect(screen.getByTestId('dossier-copy-id')).toBeInTheDocument()
  })

  it('allows safe copying of agent ID to clipboard', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent())
    const writeTextMock = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, {
      clipboard: { writeText: writeTextMock },
    })

    renderPage()
    const copyBtn = await screen.findByTestId('dossier-copy-id')
    await userEvent.click(copyBtn)

    expect(writeTextMock).toHaveBeenCalledWith('agent-abc-123')
  })
})

describe('AgentDetailPage — Request Transition', () => {
  it('shows a Request Transition button for a non-terminal agent', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent())
    renderPage()
    expect(await screen.findByTestId('dossier-request-transition')).toBeInTheDocument()
  })

  it('offers only valid next states for an enrolled agent', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ lifecycle_state: 'enrolled' }))
    renderPage()
    await userEvent.click(await screen.findByTestId('dossier-request-transition'))

    const select = screen.getByLabelText(/requested state/i) as HTMLSelectElement
    const values = Array.from(select.options).map(o => o.value)
    expect(values).toEqual(['active'])
  })

  it('offers suspend and revoke for an active agent', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ lifecycle_state: 'active' }))
    renderPage()
    await userEvent.click(await screen.findByTestId('dossier-request-transition'))

    const select = screen.getByLabelText(/requested state/i) as HTMLSelectElement
    const values = Array.from(select.options).map(o => o.value)
    expect(values).toEqual(['suspended', 'revoked'])
  })

  it('does NOT offer transitions for a revoked (terminal) agent', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ lifecycle_state: 'revoked' }))
    renderPage()
    await screen.findByText('Invoice Bot')
    expect(screen.queryByTestId('dossier-request-transition')).not.toBeInTheDocument()
    expect(screen.getByText(/no transitions available/i)).toBeInTheDocument()
  })

  it('submits via the support channel and shows success — never calls a direct transition', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ lifecycle_state: 'active' }))
    renderPage()
    await userEvent.click(await screen.findByTestId('dossier-request-transition'))

    await userEvent.type(screen.getByLabelText(/reason/i), 'Investigating anomalous behavior')
    await userEvent.click(screen.getByRole('button', { name: /submit request/i }))

    await waitFor(() => expect(api.support).toHaveBeenCalledTimes(1))

    const [, body] = (api.support as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.subject).toContain('Invoice Bot')
    expect(body.subject).toContain('suspended')
    expect(body.message).toContain('agent-abc-123')
    expect(body.message).toContain('Investigating anomalous behavior')

    expect(await screen.findByText(/transition requested/i)).toBeInTheDocument()
  })

  it('requires a reason before submitting', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ lifecycle_state: 'active' }))
    renderPage()
    await userEvent.click(await screen.findByTestId('dossier-request-transition'))

    expect(screen.getByRole('button', { name: /submit request/i })).toBeDisabled()
    expect(api.support).not.toHaveBeenCalled()
  })
})

describe('AgentDetailPage — Credential Actions', () => {
  it('shows the simulated issue notice when credential issuance returns simulated: true', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ lifecycle_state: 'active' }))
    ;(api.agents.issueCredential as ReturnType<typeof vi.fn>).mockResolvedValue({
      agent_id: 'agent-abc-123',
      name: 'Invoice Bot',
      identity_token: 'demo.jwt.issue-simulated',
      token_expires_at: '2026-08-03T00:00:00Z',
      token_note: 'demo note',
      simulated: true,
    })

    renderPage()
    await openCredentialMenu()
    await userEvent.click(screen.getByRole('button', { name: /issue credential/i }))
    await userEvent.click(screen.getByRole('button', { name: /^issue credential$/i }))

    expect(await screen.findByText(/simulated demo credential/i)).toBeInTheDocument()
    expect(
      screen.getByText(/it is not a real SPIFFE SVID and cannot authenticate any live workload/i)
    ).toBeInTheDocument()
    expect(screen.getByText('demo.jwt.issue-simulated')).toBeInTheDocument()
  })

  it('omits the simulated issue notice when credential issuance response has no simulated flag', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ lifecycle_state: 'active' }))
    ;(api.agents.issueCredential as ReturnType<typeof vi.fn>).mockResolvedValue({
      agent_id: 'agent-abc-123',
      name: 'Invoice Bot',
      identity_token: 'demo.jwt.issue-live-shape',
      token_expires_at: '2026-08-03T00:00:00Z',
      token_note: 'demo note',
    })

    renderPage()
    await openCredentialMenu()
    await userEvent.click(screen.getByRole('button', { name: /issue credential/i }))
    await userEvent.click(screen.getByRole('button', { name: /^issue credential$/i }))

    expect(await screen.findByText('demo.jwt.issue-live-shape')).toBeInTheDocument()
    expect(screen.queryByText(/simulated demo credential/i)).not.toBeInTheDocument()
  })

  it('shows the simulated revoke notice and revoked count when revoke returns simulated: true', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ lifecycle_state: 'active' }))
    ;(api.agents.revokeCredential as ReturnType<typeof vi.fn>).mockResolvedValue({
      agent_id: 'agent-abc-123',
      name: 'Invoice Bot',
      tokens_revoked: 2,
      simulated: true,
    })

    renderPage()
    await openCredentialMenu()
    await userEvent.click(screen.getByRole('button', { name: /revoke credential/i }))
    await userEvent.click(screen.getByRole('button', { name: /revoke all credentials/i }))

    expect(await screen.findByText(/credentials revoked/i)).toBeInTheDocument()
    expect(screen.getByText(/2 credentials for/i)).toBeInTheDocument()
    expect(screen.getByText(/simulated demo revoke/i)).toBeInTheDocument()
  })
})

describe('AgentDetailPage — Activity Timeline Tab', () => {
  it('requests audit events and renders them on the Activity timeline tab with StatCards and attribution', async () => {
    const syntheticAgent = makeAgent({
      id: 'agent-cardvault',
      name: 'CardVault Agent',
      type: 'service',
      lifecycle_state: 'suspended',
    })
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(syntheticAgent)
    ;(api.audit as ReturnType<typeof vi.fn>).mockResolvedValue({
      events: [
        {
          id: 'audit-event-1',
          timestamp: '2026-08-20T12:00:00Z',
          event_type: 'agent.stunned',
          agent_id: 'agent-cardvault',
          agent_name: 'CardVault Agent',
          actor: 'demo-operator@signal-loom.ai',
          detail: {
            agent_ref: 'agent-cardvault',
            reason: 'operator-initiated stun via governance API',
            from_state: 'active',
            to_state: 'suspended',
          },
          authorizing_principal_id: 'demo-operator@signal-loom.ai',
          executing_actor_id: 'agent-cardvault',
          attribution_rationale: 'Operator manual containment request',
        },
        {
          id: 'audit-event-2',
          timestamp: '2026-08-20T11:00:00Z',
          event_type: 'agent.transitioned',
          agent_id: 'agent-cardvault',
          agent_name: 'CardVault Agent',
          actor: 'spire/workload-attestor',
          detail: {
            agent_ref: 'agent-cardvault',
            from_state: 'registered',
            to_state: 'active',
          },
          authorizing_principal_id: null,
          executing_actor_id: 'agent-cardvault',
          spiffe_id: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault',
          attribution_rationale: 'Workload attestation verified by SPIRE agent',
        },
      ],
      total: 2,
      page: 1,
      limit: 50,
    })

    renderPage('/agents/agent-cardvault?tab=activity')

    expect(await screen.findByText('CardVault Agent')).toBeInTheDocument()
    expect(api.audit).toHaveBeenCalledWith('test-token', { agent: 'agent-cardvault', limit: 50 })

    // Verify Tab 5 StatCards
    expect(screen.getByTestId('activity-card-total-events')).toBeInTheDocument()
    expect(screen.getByTestId('activity-total-events')).toHaveTextContent('2')
    expect(screen.getByTestId('activity-card-stream-status')).toBeInTheDocument()

    // Verify events rendered with attribution
    expect(screen.getByTestId('activity-event-audit-event-1')).toBeInTheDocument()
    expect(screen.getByTestId('activity-event-audit-event-2')).toBeInTheDocument()
    expect(screen.getAllByText('demo-operator@signal-loom.ai').length).toBeGreaterThanOrEqual(1)
    expect(screen.getByText('Workload attestation verified by SPIRE agent')).toBeInTheDocument()
  })

  it('renders truthful empty state on Activity tab when zero audit events exist without synthesizing fake records', async () => {
    const syntheticAgent = makeAgent({
      id: 'agent-cardvault',
      name: 'CardVault Agent',
    })
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(syntheticAgent)
    ;(api.audit as ReturnType<typeof vi.fn>).mockResolvedValue({
      events: [],
      total: 0,
      page: 1,
      limit: 50,
    })

    renderPage('/agents/agent-cardvault?tab=activity')

    expect(await screen.findByText('CardVault Agent')).toBeInTheDocument()
    expect(screen.getByTestId('activity-empty-state')).toBeInTheDocument()
    expect(screen.getByText('No activity recorded')).toBeInTheDocument()
    expect(screen.getByTestId('activity-total-events')).toHaveTextContent('0')
  })
})

describe('AgentDetailPage — Access & Containment Tab (Tab 3)', () => {
  it('renders Tab 3 Access & Containment when navigated via deep link ?tab=access', async () => {
    const agent = makeAgent({
      id: 'agent-access-123',
      name: 'Access Test Workload',
      kernel_telemetry: {
        cgroup_state: 'frozen',
        traffic_control_state: 'drop',
        ebpf_active: true,
        ebpf_program_attached: true,
        observed_at: '2026-09-07T09:30:00Z',
      },
    })
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(agent)

    renderPage('/agents/agent-access-123?tab=access')

    expect(await screen.findByTestId('dossier-panel-access')).toBeInTheDocument()
    expect(screen.getByTestId('access-cgroup-badge')).toHaveTextContent('cgroup: FROZEN')
    expect(screen.getByTestId('access-tc-badge')).toHaveTextContent('TC: DROP')
    expect(screen.getByTestId('access-panel-tracks-matrix')).toBeInTheDocument()
    expect(screen.getByTestId('access-panel-capabilities')).toBeInTheDocument()
  })
})

describe('AgentDetailPage — Tab 4 (Assessments & Control Ratios)', () => {
  it('renders Tab 4 Assessments & Controls with 4 StatCards and Article 9 breakdown', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(
      makeAgent({
        compliance_summary: { total_controls: 4, passing: 3, failing: 1, pending: 0, posture_score: 0.75 },
        assessment_summary: { status: 'assessed', total_controls: 4, passed_controls: 3, failed_controls: 1, pending_controls: 0, normalized_score: 0.75 },
      })
    )
    ;(api.compliance.posture as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        {
          agent_id: 'agent-abc-123',
          agent_name: 'Test Agent',
          posture_score: 0.75,
          results: [
            {
              agent_id: 'agent-abc-123',
              control_id: 'eu-ai-act:art-9',
              control_name: 'Risk management system',
              framework_name: 'EU AI Act',
              status: 'pass',
              assessed_at: '2026-07-20T10:00:00Z',
              evidence_ref: 'opa://assessments/test/art-9',
            },
            {
              agent_id: 'agent-abc-123',
              control_id: 'soc2:cc7.2',
              control_name: 'System monitoring',
              framework_name: 'SOC 2',
              status: 'fail',
              assessed_at: '2026-07-20T10:00:00Z',
              evidence_ref: 'opa://assessments/test/cc7.2',
            },
          ],
        },
      ],
    })

    renderPage('/agents/agent-abc-123?tab=assessments')

    // Tab 4 panel and StatCards present
    expect(await screen.findByTestId('dossier-panel-assessments')).toBeInTheDocument()
    expect(screen.getByTestId('assessments-card-posture')).toBeInTheDocument()
    expect(screen.getByTestId('assessments-card-counts')).toBeInTheDocument()
    expect(screen.getByTestId('assessments-card-violations')).toBeInTheDocument()
    expect(screen.getByTestId('assessments-card-lifecycle')).toBeInTheDocument()

    // Article 9 section and Framework section
    expect(screen.getByTestId('assessments-section-article9')).toBeInTheDocument()
    expect(screen.getByTestId('assessments-section-frameworks')).toBeInTheDocument()
    expect(screen.getByTestId('control-row-eu-ai-act:art-9')).toBeInTheDocument()
    expect(screen.getByTestId('control-row-soc2:cc7.2')).toBeInTheDocument()
  })

  it('renders truthful "Not assessed" on Tab 4 when 0 controls exist', async () => {
    ;(api.agents.get as ReturnType<typeof vi.fn>).mockResolvedValue(
      makeAgent({
        compliance_summary: { total_controls: 0, passing: 0, failing: 0, pending: 0, posture_score: null },
        assessment_summary: { status: 'not_assessed', total_controls: 0, passed_controls: 0, failed_controls: 0, pending_controls: 0, normalized_score: null },
      })
    )
    ;(api.compliance.posture as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [],
    })

    renderPage('/agents/agent-abc-123?tab=assessments')

    expect(await screen.findByTestId('dossier-panel-assessments')).toBeInTheDocument()
    expect(screen.getByTestId('assessments-posture-score')).toHaveTextContent('Not assessed')
    expect(screen.getByTestId('assessments-control-ratio')).toHaveTextContent('Not assessed')
    expect(screen.getByTestId('assessments-empty-state')).toBeInTheDocument()
  })
})
