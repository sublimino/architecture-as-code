import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import AgentActivityTab from './AgentActivityTab'
import type { AgentResponse, AuditEventResponse, ViolationResponse, TelemetryObservationModel } from '../types/api'

// Mock useAuth0
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    getAccessTokenSilently: vi.fn().mockResolvedValue('fake-token'),
  }),
}))

function createMockAgent(overrides: Partial<AgentResponse> = {}): AgentResponse {
  return {
    id: 'agent-order-uuid',
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
    ...overrides,
  }
}

function createMockAuditEvents(): AuditEventResponse[] {
  return [
    {
      id: 'audit-ev-1',
      timestamp: '2026-09-07T09:00:00Z',
      event_type: 'agent.transitioned',
      agent_id: 'agent-order-uuid',
      agent_name: 'Order Processing Agent',
      actor: 'spire/workload-attestor',
      detail: { to_state: 'active', node: 'kind-worker-1' },
      executing_actor_id: 'agent-order-uuid',
      authorizing_principal_id: 'secops@signal-loom.ai',
      spiffe_id: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-order-agent',
      attribution_rationale: 'Workload attestation verified against SPIRE agent SVID',
      evidence_ref: 'sha256:8f43b12390abcf',
      kernel_telemetry_ref: 'ebpf:attest_ok_pid_4091',
    },
    {
      id: 'audit-ev-2',
      timestamp: '2026-09-07T08:30:00Z',
      event_type: 'compliance.reassess_requested',
      agent_id: 'agent-order-uuid',
      agent_name: 'Order Processing Agent',
      actor: 'compliance-engine',
      detail: { control_id: 'eu-ai-act:art-9', automated: true },
      executing_actor_id: 'agent-order-uuid',
      authorizing_principal_id: 'compliance-officer@signal-loom.ai',
      spiffe_id: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-order-agent',
      attribution_rationale: 'Periodic automated EU AI Act compliance control check',
      evidence_ref: 'witness:art-9-posture-pass',
    },
    {
      id: 'audit-ev-3',
      timestamp: '2026-08-15T09:00:00Z',
      event_type: 'agent.created',
      agent_id: 'agent-order-uuid',
      agent_name: 'Order Processing Agent',
      actor: 'system/discovery',
      detail: { source: 'declarative-cr' },
      executing_actor_id: 'agent-order-uuid',
      attribution_rationale: 'Initial declarative CR discovery',
    },
  ]
}

function createMockViolations(): ViolationResponse[] {
  return [
    {
      id: 'viol-1',
      agent_id: 'agent-order-uuid',
      violation_type: 'Egress Policy Violation',
      severity: 'high',
      status: 'new',
      analysis: 'Workload attempted unexpected external connection to 198.51.100.22:443',
      recommended_action: 'Apply TC DROP rule and review agent network egress policy',
      created_at: '2026-09-07T09:15:00Z',
      acknowledged_by: null,
      acknowledged_at: null,
      resolved_at: null,
    },
  ]
}

function renderWithRouter(ui: React.ReactElement, initialEntries = ['/agents/agent-order-uuid?tab=activity']) {
  return render(<MemoryRouter initialEntries={initialEntries}>{ui}</MemoryRouter>)
}

describe('AgentActivityTab — Tab 5 (Activity & Attributable Timeline)', () => {
  it('renders all 4 summary StatCards with accurate counts and status', () => {
    const agent = createMockAgent()
    const auditEvents = createMockAuditEvents()
    const violations = createMockViolations()

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={auditEvents}
        violations={violations}
        isLiveStreaming={true}
      />
    )

    // Card 1: Total Recorded Events (3 audit + 1 violation = 4)
    expect(screen.getByTestId('activity-card-total-events')).toBeInTheDocument()
    expect(screen.getByTestId('activity-total-events')).toHaveTextContent('4')

    // Card 2: Open Policy Violations (1 new)
    expect(screen.getByTestId('activity-card-violations')).toBeInTheDocument()
    expect(screen.getByTestId('activity-violations-count')).toHaveTextContent('1')

    // Card 3: Attestations & SVIDs (transitioned event + spiffe events)
    expect(screen.getByTestId('activity-card-attestations')).toBeInTheDocument()
    expect(screen.getByTestId('activity-attestations-count')).toHaveTextContent('2')

    // Card 4: Live Stream Status
    expect(screen.getByTestId('activity-card-stream-status')).toBeInTheDocument()
    expect(screen.getByTestId('activity-stream-status')).toHaveTextContent('Stream Active')
  })

  it('renders attributable events with separation of identity planes (authorizer vs workload)', () => {
    const agent = createMockAgent()
    const auditEvents = createMockAuditEvents()

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={auditEvents}
        violations={[]}
      />
    )

    // Verify executing workload actor and human authorizer separation
    const executingActors = screen.getAllByTestId('activity-executing-actor')
    expect(executingActors[0]).toHaveTextContent('agent-order-uuid')

    const authorizers = screen.getAllByTestId('activity-authorizing-principal')
    expect(authorizers[0]).toHaveTextContent('secops@signal-loom.ai')

    // Verify SPIFFE SVID and Attribution Rationale
    const spiffeIds = screen.getAllByTestId('activity-spiffe-id')
    expect(spiffeIds[0]).toHaveTextContent('spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-order-agent')

    const rationales = screen.getAllByTestId('activity-attribution-rationale')
    expect(rationales[0]).toHaveTextContent('Workload attestation verified against SPIRE agent SVID')

    // Verify proof and kernel telemetry references
    const evidenceRefs = screen.getAllByTestId('activity-evidence-ref')
    expect(evidenceRefs[0]).toHaveTextContent('sha256:8f43b12390abcf')
    expect(evidenceRefs[1]).toHaveTextContent('witness:art-9-posture-pass')
    expect(screen.getByTestId('activity-kernel-telemetry-ref')).toHaveTextContent('ebpf:attest_ok_pid_4091')
  })

  it('renders truthful empty state "No activity recorded" when 0 events exist without synthesizing fake records', () => {
    const agent = createMockAgent()

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={[]}
        violations={[]}
      />
    )

    expect(screen.getByTestId('activity-empty-state')).toBeInTheDocument()
    expect(screen.getByText('No activity recorded')).toBeInTheDocument()
    expect(screen.queryByTestId('activity-timeline-list')).not.toBeInTheDocument()
  })

  it('renders truthful degraded state "Source unavailable" when sourceHealth is unavailable', () => {
    const agent = createMockAgent()

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={[]}
        violations={[]}
        sourceHealth="unavailable"
      />
    )

    expect(screen.getByTestId('activity-source-unavailable')).toBeInTheDocument()
    expect(screen.getAllByText('Source unavailable').length).toBeGreaterThanOrEqual(1)
  })

  it('filters timeline items by Event Type', () => {
    const agent = createMockAgent()
    const auditEvents = createMockAuditEvents()
    const violations = createMockViolations()

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={auditEvents}
        violations={violations}
      />
    )

    // Initially 4 items (3 audit + 1 violation)
    expect(screen.getByTestId('activity-event-audit-ev-1')).toBeInTheDocument()
    expect(screen.getByTestId('activity-violation-viol-1')).toBeInTheDocument()

    // Filter to Violations Only
    fireEvent.change(screen.getByTestId('activity-type-filter'), { target: { value: 'violations' } })
    expect(screen.queryByTestId('activity-event-audit-ev-1')).not.toBeInTheDocument()
    expect(screen.getByTestId('activity-violation-viol-1')).toBeInTheDocument()

    // Filter to agent.created
    fireEvent.change(screen.getByTestId('activity-type-filter'), { target: { value: 'agent.created' } })
    expect(screen.getByTestId('activity-event-audit-ev-3')).toBeInTheDocument()
    expect(screen.queryByTestId('activity-violation-viol-1')).not.toBeInTheDocument()
  })

  it('filters timeline items by Identity Plane (human authorizers vs workload)', () => {
    const agent = createMockAgent()
    const auditEvents = createMockAuditEvents()

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={auditEvents}
        violations={[]}
      />
    )

    // Filter to human authorizers
    fireEvent.change(screen.getByTestId('activity-actor-filter'), { target: { value: 'human' } })
    expect(screen.getByTestId('activity-event-audit-ev-1')).toBeInTheDocument()
    expect(screen.getByTestId('activity-event-audit-ev-2')).toBeInTheDocument()
    expect(screen.queryByTestId('activity-event-audit-ev-3')).not.toBeInTheDocument()
  })

  it('filters timeline items by text search across rationale, actor, and payload', () => {
    const agent = createMockAgent()
    const auditEvents = createMockAuditEvents()
    const violations = createMockViolations()

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={auditEvents}
        violations={violations}
      />
    )

    // Search for "SPIRE"
    fireEvent.change(screen.getByTestId('activity-search-input'), { target: { value: 'SPIRE' } })
    expect(screen.getByTestId('activity-event-audit-ev-1')).toBeInTheDocument()
    expect(screen.queryByTestId('activity-event-audit-ev-2')).not.toBeInTheDocument()
    expect(screen.queryByTestId('activity-violation-viol-1')).not.toBeInTheDocument()
  })

  it('toggles live SSE streaming mode and calls callback', () => {
    const agent = createMockAgent()
    const auditEvents = createMockAuditEvents()
    const toggleMock = vi.fn()

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={auditEvents}
        violations={[]}
        isLiveStreaming={true}
        onToggleLiveStream={toggleMock}
      />
    )

    expect(screen.getByTestId('activity-stream-toggle')).toHaveTextContent('Pause Stream')
    fireEvent.click(screen.getByTestId('activity-stream-toggle'))
    expect(toggleMock).toHaveBeenCalledWith(false)
    expect(screen.getByTestId('activity-stream-toggle')).toHaveTextContent('Resume Stream')
  })

  it('handles violation acknowledgment action cleanly', async () => {
    const agent = createMockAgent()
    const violations = createMockViolations()
    const ackMock = vi.fn().mockResolvedValue(undefined)

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={[]}
        violations={violations}
        onAcknowledgeViolation={ackMock}
      />
    )

    const ackBtn = screen.getByTestId('acknowledge-violation-viol-1')
    expect(ackBtn).toBeInTheDocument()
    fireEvent.click(ackBtn)
    expect(ackMock).toHaveBeenCalledWith('viol-1')
  })

  it('renders scoped deep-link buttons to Audit Trail, Signal Fusion, and Weave', () => {
    const agent = createMockAgent({ id: 'agent-deep-123' })

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={[]}
        violations={[]}
      />
    )

    expect(screen.getByTestId('activity-deeplink-audit')).toHaveAttribute('href', '/audit?agent=agent-deep-123')
    expect(screen.getByTestId('activity-deeplink-signal-fusion')).toHaveAttribute('href', '/signal-fusion?actor=agent-deep-123')
    expect(screen.getByTestId('activity-deeplink-weave')).toHaveAttribute('href', '/weave?actor=agent-deep-123')
  })

  it('expands and displays JSON payload detail on toggle', () => {
    const agent = createMockAgent()
    const auditEvents = createMockAuditEvents()

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={auditEvents}
        violations={[]}
      />
    )

    expect(screen.queryByTestId('activity-payload-audit-ev-1')).not.toBeInTheDocument()
    const toggleBtns = screen.getAllByText('▶ View payload detail')
    fireEvent.click(toggleBtns[0])

    expect(screen.getByTestId('activity-payload-audit-ev-1')).toBeInTheDocument()
    expect(screen.getByTestId('activity-payload-audit-ev-1')).toHaveTextContent('"to_state": "active"')
  })

  it('filters activity timeline items from URL search params', () => {
    const agent = createMockAgent()
    const auditEvents = createMockAuditEvents()
    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={auditEvents}
        violations={[]}
      />,
      ['/agents/agent-order-uuid?tab=activity&search=Periodic&type=agent.transitioned']
    )

    expect(screen.getByTestId('activity-search-input')).toHaveValue('Periodic')
    expect(screen.getByTestId('activity-type-filter')).toHaveValue('agent.transitioned')
  })

  it('renders correlated telemetry observations with layer, source, confidence, and payload toggle', () => {
    const agent = createMockAgent()
    const telemetry: TelemetryObservationModel[] = [
      {
        id: 'obs-order-1',
        observed_at: '2026-09-07T09:15:00Z',
        source: 'frostdb-columnar',
        layer: 'LayerNetworkEgress',
        actor_id: 'agent-order-uuid',
        principal_id: 'tenant-acme',
        action: 'egress.traffic_allowed',
        details: { destination: 'internal-mesh.local', bytes: 2048 },
        confidence: 0.98,
      },
      {
        id: 'obs-order-2',
        observed_at: '2026-09-07T09:10:00Z',
        source: 'ebpf-sentinel',
        layer: 'LayerKernelSocket',
        actor_id: 'agent-order-uuid',
        principal_id: 'tenant-acme',
        action: 'socket.ebpf_traced',
        details: { protocol: 'tcp', cgroup_id: 4096 },
        confidence: 1.0,
      },
    ]

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={[]}
        violations={[]}
        telemetryObservations={telemetry}
      />
    )

    expect(screen.getByTestId('activity-telemetry-obs-order-1')).toBeInTheDocument()
    expect(screen.getByText('Layer: LayerNetworkEgress')).toBeInTheDocument()
    expect(screen.getByText('Source: frostdb-columnar')).toBeInTheDocument()
    expect(screen.getByText('98% confidence')).toBeInTheDocument()

    // Payload toggle
    expect(screen.queryByTestId('activity-telemetry-payload-obs-order-1')).not.toBeInTheDocument()
    fireEvent.click(screen.getByTestId('toggle-telemetry-detail-obs-order-1'))
    expect(screen.getByTestId('activity-telemetry-payload-obs-order-1')).toBeInTheDocument()
    expect(screen.getByTestId('activity-telemetry-payload-obs-order-1')).toHaveTextContent('"bytes": 2048')
  })

  it('filters telemetry observations by layer and source filters', () => {
    const agent = createMockAgent()
    const telemetry: TelemetryObservationModel[] = [
      {
        id: 'obs-order-1',
        observed_at: '2026-09-07T09:15:00Z',
        source: 'frostdb-columnar',
        layer: 'LayerNetworkEgress',
        actor_id: 'agent-order-uuid',
        action: 'egress.traffic_allowed',
      },
      {
        id: 'obs-order-2',
        observed_at: '2026-09-07T09:10:00Z',
        source: 'ebpf-sentinel',
        layer: 'LayerKernelSocket',
        actor_id: 'agent-order-uuid',
        action: 'socket.ebpf_traced',
      },
    ]

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={[]}
        violations={[]}
        telemetryObservations={telemetry}
      />
    )

    // Filter by layer
    fireEvent.change(screen.getByTestId('activity-layer-filter'), { target: { value: 'LayerKernelSocket' } })
    expect(screen.queryByTestId('activity-telemetry-obs-order-1')).not.toBeInTheDocument()
    expect(screen.getByTestId('activity-telemetry-obs-order-2')).toBeInTheDocument()

    // Reset and filter by source
    fireEvent.click(screen.getByTestId('activity-clear-filters'))
    expect(screen.getByTestId('activity-telemetry-obs-order-1')).toBeInTheDocument()
    expect(screen.getByTestId('activity-telemetry-obs-order-2')).toBeInTheDocument()

    fireEvent.change(screen.getByTestId('activity-source-filter'), { target: { value: 'frostdb-columnar' } })
    expect(screen.getByTestId('activity-telemetry-obs-order-1')).toBeInTheDocument()
    expect(screen.queryByTestId('activity-telemetry-obs-order-2')).not.toBeInTheDocument()
  })

  it('reflects telemetry observations in summary StatCard count', () => {
    const agent = createMockAgent()
    const telemetry: TelemetryObservationModel[] = [
      {
        id: 'obs-order-1',
        observed_at: '2026-09-07T09:15:00Z',
        source: 'frostdb-columnar',
        layer: 'LayerNetworkEgress',
        actor_id: 'agent-order-uuid',
        action: 'egress.traffic_allowed',
      },
      {
        id: 'obs-order-2',
        observed_at: '2026-09-07T09:10:00Z',
        source: 'ebpf-sentinel',
        layer: 'LayerKernelSocket',
        actor_id: 'agent-order-uuid',
        action: 'socket.ebpf_traced',
      },
    ]

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={[]}
        violations={[]}
        telemetryObservations={telemetry}
      />
    )

    expect(screen.getByTestId('activity-total-events')).toHaveTextContent('2')
    expect(screen.getByTestId('activity-card-total-events')).toHaveTextContent('2 telemetry')
  })

  it('opens AuthorizationProofDrawer on clicking View Proof button and closes on Escape', async () => {
    const agent = createMockAgent()
    const auditEvents = createMockAuditEvents()

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={auditEvents}
        violations={[]}
      />
    )

    // Ensure drawer is initially closed
    expect(screen.queryByTestId('authorization-proof-drawer')).not.toBeInTheDocument()

    // Click View Proof on audit-ev-1
    const proofBtn = screen.getByTestId('activity-action-proof-audit-ev-1')
    expect(proofBtn).toBeInTheDocument()
    fireEvent.click(proofBtn)

    // Drawer opens and displays title and action
    expect(screen.getByTestId('authorization-proof-drawer')).toBeInTheDocument()
    expect(screen.getByTestId('proof-drawer-action-id')).toHaveTextContent('Action: audit-ev-1')
    expect(screen.getByTestId('who-authorized-panel')).toBeInTheDocument()

    // Press Escape to close
    fireEvent.keyDown(window, { key: 'Escape', code: 'Escape' })
    expect(screen.queryByTestId('authorization-proof-drawer')).not.toBeInTheDocument()
  })

  it('allows copying FrostDB digest, audit webhook, and evidence references inside AuthorizationProofDrawer', async () => {
    const writeTextMock = vi.fn().mockImplementation(() => Promise.resolve())
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText: writeTextMock },
      configurable: true,
      writable: true,
    })

    const agent = createMockAgent()
    const auditEvents = createMockAuditEvents()

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={auditEvents}
        violations={[]}
      />
    )

    // Open proof drawer
    fireEvent.click(screen.getByTestId('activity-action-proof-audit-ev-1'))
    expect(screen.getByTestId('authorization-proof-drawer')).toBeInTheDocument()

    // Copy FrostDB
    const copyFrostDb = screen.getByTestId('proof-drawer-copy-frostdb')
    fireEvent.click(copyFrostDb)
    expect(writeTextMock).toHaveBeenCalled()

    // Copy Webhook
    const copyWebhook = screen.getByTestId('proof-drawer-copy-webhook')
    fireEvent.click(copyWebhook)
    expect(writeTextMock).toHaveBeenCalled()

    // Copy Evidence
    const copyEvidence = screen.getByTestId('proof-drawer-copy-evidence')
    fireEvent.click(copyEvidence)
    expect(writeTextMock).toHaveBeenCalled()

    // Close via close button
    const closeBtn = screen.getByTestId('close-proof-drawer')
    fireEvent.click(closeBtn)
    expect(screen.queryByTestId('authorization-proof-drawer')).not.toBeInTheDocument()
  })

  it('filters timeline items using DelegationEventFilter by minHops and resets correctly', () => {
    const agent = createMockAgent()
    const auditEvents: AuditEventResponse[] = [
      {
        id: 'ev-hop-3',
        timestamp: '2026-09-07T09:00:00Z',
        event_type: 'agent.transitioned',
        agent_id: 'agent-order-uuid',
        agent_name: 'Order Processing Agent',
        actor: 'spire/workload-attestor',
        detail: { hop_count: 3 },
      },
      {
        id: 'ev-hop-7',
        timestamp: '2026-09-07T08:30:00Z',
        event_type: 'credential.issued',
        agent_id: 'agent-order-uuid',
        agent_name: 'Order Processing Agent',
        actor: 'spire/workload-attestor',
        detail: { hop_count: 7 },
      },
    ]

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={auditEvents}
        violations={[]}
      />
    )

    // Initially both rendered
    expect(screen.getByTestId('activity-event-ev-hop-3')).toBeInTheDocument()
    expect(screen.getByTestId('activity-event-ev-hop-7')).toBeInTheDocument()

    // Filter by minHops = 5
    const minHopsInput = screen.getByTestId('delegation-min-hops-filter')
    fireEvent.change(minHopsInput, { target: { value: '5' } })

    // ev-hop-3 filtered out, ev-hop-7 remains
    expect(screen.queryByTestId('activity-event-ev-hop-3')).not.toBeInTheDocument()
    expect(screen.getByTestId('activity-event-ev-hop-7')).toBeInTheDocument()

    // Filter by type in DelegationEventFilter
    const typeSelect = screen.getByTestId('delegation-type-filter')
    fireEvent.change(typeSelect, { target: { value: 'agent.transitioned' } })

    // Neither matches (hop-3 is filtered by minHops, hop-7 is credential.issued)
    expect(screen.queryByTestId('activity-event-ev-hop-7')).not.toBeInTheDocument()

    // Reset filter
    const resetBtn = screen.getByTestId('delegation-filter-reset')
    fireEvent.click(resetBtn)

    expect(screen.getByTestId('activity-event-ev-hop-3')).toBeInTheDocument()
    expect(screen.getByTestId('activity-event-ev-hop-7')).toBeInTheDocument()
  })

  it('opens DelegationAttestationDrawer on clicking Attestation button and closes on Escape', () => {
    const agent = createMockAgent()
    const auditEvents = createMockAuditEvents()

    renderWithRouter(
      <AgentActivityTab
        agent={agent}
        auditEvents={auditEvents}
        violations={[]}
      />
    )

    expect(screen.queryByTestId('delegation-attestation-drawer')).not.toBeInTheDocument()

    // Click Attestation button on audit-ev-1
    const attBtn = screen.getByTestId('view-attestation-audit-ev-1')
    expect(attBtn).toBeInTheDocument()
    fireEvent.click(attBtn)

    // Drawer opens
    expect(screen.getByTestId('delegation-attestation-drawer')).toBeInTheDocument()
    expect(screen.getByTestId('attestation-action-id')).toHaveTextContent('Action: audit-ev-1')
    expect(screen.getByTestId('attestation-cosign-sig')).toBeInTheDocument()
    expect(screen.getByTestId('attestation-landlock-status')).toBeInTheDocument()
    expect(screen.getByTestId('attestation-raw-payload')).toBeInTheDocument()

    // Press Escape to close
    fireEvent.keyDown(window, { key: 'Escape', code: 'Escape' })
    expect(screen.queryByTestId('delegation-attestation-drawer')).not.toBeInTheDocument()
  })
})

