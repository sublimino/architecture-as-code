import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import ClaimModal, { getAgentWorkloadSecurityProfile } from './ClaimModal'
import type { AgentResponse } from '../../types/api'
import * as agentClaimApi from '../../api/agentClaim'

vi.mock('../../auth/oidc', () => ({
  useAuth0: () => ({
    getAccessTokenSilently: vi.fn().mockResolvedValue('test-token'),
    user: { sub: 'test-user' },
    isAuthenticated: true,
  }),
}))

function createMockDiscoveredAgent(overrides: Partial<AgentResponse> = {}): AgentResponse {
  return {
    id: 'discovered-agent-123',
    name: 'agent-nono-evidenced-fccfbb-xp8v7',
    type: 'Signal Loom Built',
    owner: 'unassigned',
    tenant_id: 'tenant-acme',
    lifecycle_state: 'discovered',
    last_transition_at: '2026-09-10T10:00:00Z',
    last_transition_by: 'system',
    eu_ai_act_risk_class: 'limited',
    compliance_summary: {
      total_controls: 5,
      passing: 5,
      failing: 0,
      pending: 0,
      posture_score: 100,
    },
    created_at: '2026-09-10T10:00:00Z',
    record_class: 'discovered',
    is_registry_linked: false,
    runtime: {
      cluster_id: 'osramp',
      namespace: 'fe-signalloom-agents',
      pod_name: 'agent-nono-evidenced-fccfbb-xp8v7',
      pod_uid: 'uid-nono-1234',
      service_account: 'agent-nono-evidenced',
      framework: 'nono-sandboxed',
      model: 'anthropic/claude-sonnet-4',
      execution_mode: 'landlock-lsm',
      node: 'kind-control-plane',
      phase: 'Running',
    },
    identity: {
      spiffe_id: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced',
      spiffe_status: 'linked',
      aliases: [],
    },
    ...overrides,
  }
}

describe('ClaimModal & getAgentWorkloadSecurityProfile', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
  })

  it('correctly classifies Nono sandboxed agent profile', () => {
    const nonoAgent = createMockDiscoveredAgent({
      name: 'agent-nono-evidenced',
    })
    const profile = getAgentWorkloadSecurityProfile(nonoAgent)
    expect(profile.profile).toBe('nono-sandboxed')
    expect(profile.label).toBe('Nono Sandboxed')
  })

  it('correctly classifies standard baseline agent profile', () => {
    const standardAgent = createMockDiscoveredAgent({
      name: 'agent-standard-baseline',
      runtime: {
        cluster_id: 'osramp',
        namespace: 'fe-signalloom-agents',
        pod_name: 'agent-standard-baseline-6699c8bdb5-bxpwp',
        pod_uid: 'uid-std-5678',
        service_account: 'agent-standard-baseline',
        framework: 'standard-container',
        model: 'openai/gpt-4o-mini',
        execution_mode: 'container',
        node: 'kind-control-plane',
        phase: 'Running',
      },
    })
    const profile = getAgentWorkloadSecurityProfile(standardAgent)
    expect(profile.profile).toBe('standard-container')
    expect(profile.label).toBe('Standard Container')
  })

  it('renders modal with agent prefilled values and security badge', () => {
    const agent = createMockDiscoveredAgent()
    render(<ClaimModal agent={agent} onClose={vi.fn()} />)

    expect(screen.getByTestId('claim-modal')).toBeDefined()
    expect(screen.getByTestId('claim-modal-security-badge').textContent).toContain('Nono Sandboxed')
    expect((screen.getByTestId('claim-modal-pod-name') as HTMLInputElement).value).toBe('agent-nono-evidenced-fccfbb-xp8v7')
    expect((screen.getByTestId('claim-modal-namespace') as HTMLInputElement).value).toBe('fe-signalloom-agents')
    expect((screen.getByTestId('claim-modal-spiffe-id') as HTMLInputElement).value).toBe('spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced')
  })

  it('submits claim successfully and triggers onSuccess & onClose', async () => {
    const claimSpy = vi.spyOn(agentClaimApi, 'claimDiscoveredAgent').mockResolvedValue({
      claim_id: 'claim-nono-uuid',
      status: 'granted',
      spiffe_svid_verified: true,
      allocated_token_budget: 250000,
      signal_session_url: '/ws/session/1',
      ebpf_sentinel_bound: true,
      agent_id: 'agent-nono-evidenced',
    })

    const onClose = vi.fn()
    const onSuccess = vi.fn()
    const agent = createMockDiscoveredAgent()

    render(<ClaimModal agent={agent} onClose={onClose} onSuccess={onSuccess} />)

    const submitBtn = screen.getByTestId('claim-modal-submit-btn')
    fireEvent.click(submitBtn)

    await waitFor(() => {
      expect(claimSpy).toHaveBeenCalledWith(
        'test-token',
        'discovered-agent-123',
        expect.objectContaining({
          pod_name: 'agent-nono-evidenced-fccfbb-xp8v7',
          namespace: 'fe-signalloom-agents',
          spiffe_id: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced',
        })
      )
      expect(onSuccess).toHaveBeenCalled()
      expect(onClose).toHaveBeenCalled()
    })
  })

  it('displays conflict error message when claim returns 409', async () => {
    const conflictError = Object.assign(new Error('Conflict'), {
      response: { status: 409 },
    })
    vi.spyOn(agentClaimApi, 'claimDiscoveredAgent').mockRejectedValue(conflictError)

    const agent = createMockDiscoveredAgent()
    render(<ClaimModal agent={agent} onClose={vi.fn()} />)

    const submitBtn = screen.getByTestId('claim-modal-submit-btn')
    fireEvent.click(submitBtn)

    await waitFor(() => {
      expect(screen.getByTestId('claim-modal-error')).toBeDefined()
      expect(screen.getByTestId('claim-modal-error').textContent).toContain('already claimed by another operator tenant')
    })
  })

  it('invokes onClose when cancel button or close button is clicked', () => {
    const onClose = vi.fn()
    const agent = createMockDiscoveredAgent()
    render(<ClaimModal agent={agent} onClose={onClose} />)

    const closeBtn = screen.getByTestId('claim-modal-close-btn')
    fireEvent.click(closeBtn)
    expect(onClose).toHaveBeenCalledTimes(1)

    const cancelBtn = screen.getByTestId('claim-modal-cancel-btn')
    fireEvent.click(cancelBtn)
    expect(onClose).toHaveBeenCalledTimes(2)
  })
})
