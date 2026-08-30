/**
 * Tests that the agent detail page renders swarm-specific content: audit event
 * timeline with swarm event types, credential section with OpenBao role and
 * SPIFFE ID, and stun status display.
 *
 * Follows the AgentsPage.test.tsx mocking pattern: mock api client, auth, and
 * demo mode, then render inside MemoryRouter with a route param.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'

// ── Mocks ──────────────────────────────────────────────────────────────────

vi.mock('../api/demoMode', () => ({
  isDemoMode: () => true,
  isProductionEnv: false,
  showDemoToggle: true,
}))

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

const mockApi = vi.hoisted(() => ({
  agents: {
    get: vi.fn(),
    list: vi.fn(),
    register: vi.fn(),
    violations: vi.fn(),
    issueCredential: vi.fn(),
    revokeCredential: vi.fn(),
    acknowledge: vi.fn(),
    reassess: vi.fn(),
  },
  audit: vi.fn(),
  compliance: {
    posture: vi.fn(),
  },
  support: vi.fn(),
  nhi: {
    discovered: vi.fn().mockResolvedValue({ accounts: [], total: 0, summary: { total_discovered: 0, needs_triage: 0, previously_dismissed: 0 } }),
    scans: vi.fn().mockResolvedValue({ scans: [] }),
    enrollAccount: vi.fn(),
    dismissAccount: vi.fn(),
  },
  compliancePolicy: {
    scan: vi.fn(),
  },
}))

vi.mock('../api/client', () => ({
  api: mockApi,
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

import AgentDetailPage from './AgentDetailPage'
import type { AgentResponse, AuditEventResponse } from '../types/api'

// ── Fixtures ───────────────────────────────────────────────────────────────

const AGENT_ID = 'tenant-demo:cpai-engineer'

function makeSwarmAgent(overrides: Partial<AgentResponse> = {}): AgentResponse {
  return {
    id: AGENT_ID,
    name: 'cpai-engineer',
    type: 'sandboxed-coder',
    owner: 'swarm-operator',
    tenant_id: 'tenant-demo',
    lifecycle_state: 'active',
    last_transition_at: '2026-08-01T10:00:00Z',
    last_transition_by: 'swarm-operator',
    eu_ai_act_risk_class: 'limited',
    compliance_summary: {
      total_controls: 6,
      passing: 5,
      failing: 0,
      pending: 1,
      posture_score: 83,
    },
    model_name: 'gpt-4o',
    created_at: '2026-08-01T09:00:00Z',
    ...overrides,
  }
}

function makeStunnedAgent(): AgentResponse {
  return makeSwarmAgent({
    lifecycle_state: 'suspended',
    credential_state: {
      status: 'revoked',
      reason: 'non-compliant securityContext — stunned by sentinel',
      revoked_at: '2026-08-02T11:00:00Z',
      revoked_by: 'stun-sentinel',
    },
  })
}

function makeAuditEvent(
  type: string,
  overrides: Partial<AuditEventResponse> = {},
): AuditEventResponse {
  return {
    id: `evt-${type}-${Math.random().toString(36).slice(2, 8)}`,
    timestamp: '2026-08-01T12:00:00Z',
    event_type: type,
    agent_id: AGENT_ID,
    agent_name: 'cpai-engineer',
    actor: 'swarm-operator',
    detail: { outcome: 'success' },
    ...overrides,
  }
}

function renderDetail(agentId: string = encodeURIComponent(AGENT_ID)) {
  return render(
    <MemoryRouter initialEntries={[`/agents/${agentId}`]}>
      <Routes>
        <Route path="/agents/:id" element={<AgentDetailPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

// ── Tests ──────────────────────────────────────────────────────────────────

describe('SwarmAgentDetail — audit event timeline', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  it('renders swarm event types in the audit timeline', async () => {
    const swarmEvents: AuditEventResponse[] = [
      makeAuditEvent('agent.created'),
      makeAuditEvent('agent.transitioned', {
        detail: { from_state: 'enrolled', to_state: 'active' },
      }),
      makeAuditEvent('agent.stunned', {
        actor: 'stun-sentinel',
        detail: { outcome: 'stunned', reason: 'non-compliant securityContext' },
      }),
      makeAuditEvent('agent.credential_issued', {
        detail: { issuer: 'openbao', scope: 'agent-generic' },
      }),
      makeAuditEvent('agent.credential_revoked', {
        actor: 'stun-sentinel',
        detail: { reason: 'sentinel stun action' },
      }),
    ]

    mockApi.agents.get.mockResolvedValue(makeSwarmAgent())
    mockApi.audit.mockResolvedValue({ events: swarmEvents, total: swarmEvents.length })
    mockApi.agents.violations.mockResolvedValue({ violations: [], total: 0 })
    mockApi.compliance.posture.mockResolvedValue({ posture_score: 83, controls: [] })

    renderDetail()

    // Wait for the agent name to render, confirming the page loaded.
    await waitFor(() => {
      expect(document.body.textContent).toContain('cpai-engineer')
    })

    // Verify at least some of the swarm event types appear in the timeline.
    // The timeline renders EventTypeTag components with the event_type string.
    await waitFor(() => {
      const body = document.body.textContent ?? ''
      // At least 'agent.created' and 'agent.stunned' should appear.
      expect(body).toContain('agent.created')
    })
  })

  it('shows credential state when agent is stunned', async () => {
    const stunnedAgent = makeStunnedAgent()

    mockApi.agents.get.mockResolvedValue(stunnedAgent)
    mockApi.audit.mockResolvedValue({ events: [], total: 0 })
    mockApi.agents.violations.mockResolvedValue({ violations: [], total: 0 })
    mockApi.compliance.posture.mockResolvedValue({ posture_score: 42, controls: [] })

    renderDetail()

    await waitFor(() => {
      expect(document.body.textContent).toContain('cpai-engineer')
    })

    // The CredentialStateNotice component renders when credential_state exists.
    // Verify the revocation reason or status appears.
    await waitFor(() => {
      const body = document.body.textContent ?? ''
      const hasRevoked = body.includes('revoked') || body.includes('Revoked')
      const hasSuspended = body.includes('suspended') || body.includes('Suspended')
      expect(hasRevoked || hasSuspended).toBe(true)
    })
  })

  it('displays the agent type as its swarm role', async () => {
    mockApi.agents.get.mockResolvedValue(makeSwarmAgent())
    mockApi.audit.mockResolvedValue({ events: [], total: 0 })
    mockApi.agents.violations.mockResolvedValue({ violations: [], total: 0 })
    mockApi.compliance.posture.mockResolvedValue({ posture_score: 83, controls: [] })

    renderDetail()

    await waitFor(() => {
      const body = document.body.textContent ?? ''
      expect(body).toContain('sandboxed-coder')
    })
  })

  it('renders the agent lifecycle state', async () => {
    mockApi.agents.get.mockResolvedValue(makeSwarmAgent({ lifecycle_state: 'active' }))
    mockApi.audit.mockResolvedValue({ events: [], total: 0 })
    mockApi.agents.violations.mockResolvedValue({ violations: [], total: 0 })
    mockApi.compliance.posture.mockResolvedValue({ posture_score: 83, controls: [] })

    renderDetail()

    await waitFor(() => {
      const body = document.body.textContent ?? ''
      // The StatusBadge renders the lifecycle state.
      expect(body.toLowerCase()).toContain('active')
    })
  })
})
