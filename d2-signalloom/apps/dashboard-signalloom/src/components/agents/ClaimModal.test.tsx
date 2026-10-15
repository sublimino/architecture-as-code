import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import ClaimModal, { getAgentWorkloadSecurityProfile } from './ClaimModal'
import type { AgentResponse } from '../../types/api'
import * as agentClaimApi from '../../api/agentClaim'
import { api } from '../../api/client'

const authState = vi.hoisted(() => ({
  user: { sub: 'test-user' } as { email?: string; name?: string; sub?: string },
}))

vi.mock('../../auth/oidc', () => ({
  useAuth0: () => ({
    getAccessTokenSilently: vi.fn().mockResolvedValue('test-token'),
    user: authState.user,
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
    authState.user = { sub: 'test-user' }
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
    expect(profile.description).toContain('stun-sentinel in-kernel eBPF')
    expect(profile.description).not.toMatch(/tetragon/i)
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

  it('separates editable owner assignment from authenticated operator identity', () => {
    render(<ClaimModal agent={createMockDiscoveredAgent()} onClose={vi.fn()} />)

    expect(screen.getByText('Assigned Owner')).toBeInTheDocument()
    expect(screen.queryByText(/Assigned Owner \/ Operator/i)).not.toBeInTheDocument()
    expect(screen.getByTestId('claim-modal-owner')).toBeInstanceOf(HTMLInputElement)
    expect(screen.getByTestId('claim-modal-operator')).not.toBeInstanceOf(HTMLInputElement)
    expect(screen.getByTestId('claim-modal-operator')).toHaveTextContent('test-user')
  })

  it('uses subject for operator authority while preserving name-based owner prefill', () => {
    authState.user = { name: 'Owner Display Name', sub: 'operator-subject-42' }
    render(<ClaimModal agent={createMockDiscoveredAgent()} onClose={vi.fn()} />)

    expect(screen.getByTestId('claim-modal-owner')).toHaveValue('Owner Display Name')
    expect(screen.getByTestId('claim-modal-operator')).toHaveTextContent('operator-subject-42')
    expect(screen.getByTestId('claim-modal-operator')).not.toHaveTextContent('Owner Display Name')
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
          owner: 'test-user',
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

  it('renders right-hand pre-flight info panel with workload diagnostics', () => {
    const agent = createMockDiscoveredAgent({ tenant_id: 'default' })
    render(<ClaimModal agent={agent} onClose={vi.fn()} />)

    expect(screen.getByTestId('claim-modal-info-panel')).toBeInTheDocument()
    expect(screen.getByText('Workload Pre-Flight & Diagnostics')).toBeInTheDocument()
    expect(screen.getByText('Pre-Flight Invariants')).toBeInTheDocument()
    expect(screen.getByTestId('claim-modal-tenant-verified')).toBeInTheDocument()
  })

  it('displays pre-emptive tenant mismatch warning when workload belongs to another tenant', () => {
    const kusariAgent: AgentResponse = {
      ...createMockDiscoveredAgent(),
      id: 'agent-kusari-847cc7d984-mwg8c',
      name: 'kusari-agent',
      tenant: 'kusari',
      tenant_id: 'kusari',
    }
    render(<ClaimModal agent={kusariAgent} onClose={vi.fn()} />)

    expect(screen.getByTestId('claim-modal-tenant-mismatch-warning')).toBeInTheDocument()
    expect(screen.getByTestId('claim-modal-tenant-mismatch-warning')).toHaveTextContent('Tenant Mismatch')
    expect(screen.getByTestId('claim-modal-tenant-mismatch-warning')).toHaveTextContent('kusari')
    expect(screen.getByTestId('claim-modal-tenant-mismatch-warning')).toHaveTextContent('kubectl -n fe-signalloom-agents label pod')
  })

  it('displays GitOps warning notice in info panel when workload is managed by GitOps', () => {
    const gitopsAgent: AgentResponse = {
      ...createMockDiscoveredAgent(),
      runtime: {
        ...createMockDiscoveredAgent().runtime,
        labels: {
          'kustomize.toolkit.fluxcd.io/name': 'agent-flux-app',
          'kustomize.toolkit.fluxcd.io/namespace': 'flux-system',
        },
      } as any,
    }

    render(<ClaimModal agent={gitopsAgent} onClose={vi.fn()} />)

    const infoPanel = screen.getByTestId('claim-modal-info-panel')
    expect(infoPanel).toBeInTheDocument()

    const gitopsNotice = screen.getByTestId('claim-modal-gitops-notice')
    expect(gitopsNotice).toBeInTheDocument()
    expect(gitopsNotice).toHaveTextContent('GitOps Managed Workload')
    expect(gitopsNotice).toHaveTextContent('managed by GitOps (flux)')
    expect(gitopsNotice).toHaveTextContent('Commit the governance label change to your git repository or Kustomization manifest')
    expect(screen.getByTestId('claim-modal-gitops-badge')).toHaveTextContent('Flux')
    expect(screen.getByTestId('claim-modal-gitops-patch')).toHaveTextContent('signalloom.ai/tenant')
  })

  it('does not display GitOps notice in info panel when workload is unmanaged', () => {
    const bareAgent = createMockDiscoveredAgent()
    render(<ClaimModal agent={bareAgent} onClose={vi.fn()} />)

    expect(screen.queryByTestId('claim-modal-gitops-notice')).not.toBeInTheDocument()
  })

  it('renders Red Blocked claimability status and undeclared model objection when model is missing', () => {
    const unmodeledAgent = createMockDiscoveredAgent({
      id: 'test-agent-stunned',
      name: 'test-agent-stunned',
      tenant_id: 'default',
      runtime: {
        ...createMockDiscoveredAgent().runtime,
        pod_name: 'test-agent-stunned',
        model: null,
      },
    })
    render(<ClaimModal agent={unmodeledAgent} onClose={vi.fn()} />)

    const statusBanner = screen.getByTestId('claim-modal-claimability-status')
    expect(statusBanner).toBeInTheDocument()
    expect(statusBanner).toHaveTextContent('Claim Blocked — Action Required')
    expect(screen.getByTestId('claim-modal-claimability-badge')).toHaveTextContent('Blocked')

    const prereqsMatrix = screen.getByTestId('claim-modal-prereqs-matrix')
    expect(prereqsMatrix).toBeInTheDocument()

    const modelPrereq = screen.getByTestId('claim-modal-prereq-model')
    expect(modelPrereq).toBeInTheDocument()
    expect(screen.getByTestId('claim-modal-prereq-model-badge')).toHaveTextContent('UNDECLARED')
    expect(modelPrereq).toHaveTextContent('signalloom.ai/model')
    expect(screen.getByTestId('claim-modal-copy-model-btn')).toBeInTheDocument()

    expect(screen.getByTestId('claim-modal-model-undeclared-badge')).toHaveTextContent('UNDECLARED ON POD')
    expect(screen.getByTestId('claim-modal-model-warning')).toHaveTextContent('signalloom.ai/model')
    expect(screen.getByTestId('claim-modal-blocker-advisory')).toHaveTextContent('Pre-flight blockers detected')
  })

  it('renders Green Claimable status when model is declared and tenant boundary is aligned', () => {
    const claimableAgent = createMockDiscoveredAgent({
      tenant_id: 'default',
      runtime: {
        ...createMockDiscoveredAgent().runtime,
        model: 'anthropic/claude-sonnet-4',
      },
    })
    render(<ClaimModal agent={claimableAgent} onClose={vi.fn()} />)

    const statusBanner = screen.getByTestId('claim-modal-claimability-status')
    expect(statusBanner).toBeInTheDocument()
    expect(statusBanner).toHaveTextContent('Claimable — Ready for Governance')
    expect(screen.getByTestId('claim-modal-claimability-badge')).toHaveTextContent('Claimable')

    expect(screen.getByTestId('claim-modal-prereq-model-badge')).toHaveTextContent('VERIFIED')
    expect(screen.getByTestId('claim-modal-prereq-tenant-badge')).toHaveTextContent('ALIGNED')
    expect(screen.queryByTestId('claim-modal-model-warning')).not.toBeInTheDocument()
    expect(screen.queryByTestId('claim-modal-blocker-advisory')).not.toBeInTheDocument()
  })

  it('displays active claimError prop with detailed objection diagnostic and copyable command', () => {
    const agent = createMockDiscoveredAgent({
      id: 'test-agent-stunned',
      name: 'test-agent-stunned',
      tenant_id: 'default',
    })
    const claimError = "Workload 'test-agent-stunned' declares no signalloom.ai/model; refusing to record an invented model"

    render(<ClaimModal agent={agent} claimError={claimError} onClose={vi.fn()} />)

    const errorAlert = screen.getByTestId('claim-modal-error')
    expect(errorAlert).toBeInTheDocument()
    expect(errorAlert).toHaveTextContent('Workload Model Objection: Missing signalloom.ai/model')
    expect(errorAlert).toHaveTextContent("declares no signalloom.ai/model; refusing to record an invented model")
    expect(errorAlert).toHaveTextContent('Signal Loom strictly mandates that every governed agent declares an approved AI foundation model')
    expect(screen.getByTestId('claim-modal-copy-model-cmd-btn')).toBeInTheDocument()

    expect(screen.getByTestId('claim-modal-claimability-badge')).toHaveTextContent('Blocked')
  })

  it('auto-refreshes on mount, fetches fresh agent from API, and updates currentAgent', async () => {
    const initialAgent = createMockDiscoveredAgent({
      id: 'agent-mount-refresh',
      name: 'agent-mount-refresh',
      runtime: {
        ...createMockDiscoveredAgent().runtime,
        pod_name: 'initial-pod-name',
        service_account: 'initial-sa',
      },
    })

    const freshAgent: AgentResponse = {
      ...initialAgent,
      runtime: {
        ...initialAgent.runtime,
        pod_name: 'refreshed-pod-name',
        service_account: 'refreshed-sa-live',
      },
    }

    const getSpy = vi.spyOn(api.agents, 'get').mockResolvedValue(freshAgent)

    render(<ClaimModal agent={initialAgent} onClose={vi.fn()} />)

    await waitFor(() => {
      expect(getSpy).toHaveBeenCalledWith('test-token', 'agent-mount-refresh')
    })

    await waitFor(() => {
      expect(screen.getByTestId('claim-modal-prereq-spiffe')).toHaveTextContent('refreshed-sa-live')
    })
  })

  it('auto-clears missing model objection, cleans URL params, and turns status Green Claimable when refresh returns model', async () => {
    window.history.replaceState(
      {},
      '',
      '/agents/discovered:test-agent-stunned?claim_error=Workload+test-agent-stunned+declares+no+signalloom.ai%2Fmodel'
    )

    const unmodeledAgent = createMockDiscoveredAgent({
      id: 'test-agent-stunned',
      name: 'test-agent-stunned',
      tenant_id: 'default',
      runtime: {
        ...createMockDiscoveredAgent().runtime,
        pod_name: 'test-agent-stunned',
        model: null,
      },
    })

    const refreshedAgentWithModel: AgentResponse = {
      ...unmodeledAgent,
      runtime: {
        ...unmodeledAgent.runtime,
        model: 'claude-3-5-sonnet',
      },
    }

    vi.spyOn(api.agents, 'get').mockResolvedValue(refreshedAgentWithModel)
    const onClearClaimError = vi.fn()

    render(
      <ClaimModal
        agent={unmodeledAgent}
        claimError="Workload 'test-agent-stunned' declares no signalloom.ai/model; refusing to record an invented model"
        onClose={vi.fn()}
        onClearClaimError={onClearClaimError}
      />
    )

    await waitFor(() => {
      expect(screen.getByTestId('claim-modal-claimability-badge')).toHaveTextContent('Claimable')
    })

    expect(screen.getByTestId('claim-modal-claimability-status')).toHaveTextContent('Claimable — Ready for Governance')
    expect(screen.getByTestId('claim-modal-prereq-model-badge')).toHaveTextContent('VERIFIED')
    expect(screen.getByTestId('claim-modal-prereq-model')).toHaveTextContent('claude-3-5-sonnet')
    expect(screen.queryByTestId('claim-modal-error')).not.toBeInTheDocument()

    expect(onClearClaimError).toHaveBeenCalled()

    expect(window.location.search).not.toContain('claim_error')
    expect(window.location.search).not.toContain('error')

    expect(screen.getByTestId('claim-modal-refreshed-badge')).toHaveTextContent('Workload refreshed: model detected')
  })

  it('triggers refresh and updates pre-flight matrix when clicking claim-modal-refresh-btn', async () => {
    const unmodeledAgent = createMockDiscoveredAgent({
      id: 'test-agent-refresh-click',
      name: 'test-agent-refresh-click',
      tenant_id: 'default',
      runtime: {
        ...createMockDiscoveredAgent().runtime,
        model: null,
      },
    })

    const refreshedAgent: AgentResponse = {
      ...unmodeledAgent,
      runtime: {
        ...unmodeledAgent.runtime,
        model: 'claude-3-5-sonnet',
      },
    }

    const getSpy = vi.spyOn(api.agents, 'get').mockResolvedValueOnce(unmodeledAgent)

    render(<ClaimModal agent={unmodeledAgent} onClose={vi.fn()} />)

    expect(screen.getByTestId('claim-modal-claimability-badge')).toHaveTextContent('Blocked')
    expect(screen.getByTestId('claim-modal-prereq-model-badge')).toHaveTextContent('UNDECLARED')

    getSpy.mockResolvedValueOnce(refreshedAgent)

    const refreshBtn = screen.getByTestId('claim-modal-refresh-btn')
    fireEvent.click(refreshBtn)

    await waitFor(() => {
      expect(screen.getByTestId('claim-modal-claimability-badge')).toHaveTextContent('Claimable')
    })

    expect(screen.getByTestId('claim-modal-prereq-model-badge')).toHaveTextContent('VERIFIED')
    expect(screen.getByTestId('claim-modal-prereq-model')).toHaveTextContent('claude-3-5-sonnet')
    expect(screen.getByTestId('claim-modal-refreshed-badge')).toHaveTextContent('Workload refreshed: model detected')
  })

  it('executes pre-flight refresh before submitting claim and invalidates query caches', async () => {
    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    })
    const invalidateSpy = vi.spyOn(queryClient, 'invalidateQueries')

    const agent = createMockDiscoveredAgent({
      id: 'test-agent-presubmission',
      name: 'test-agent-presubmission',
      tenant_id: 'default',
      runtime: {
        ...createMockDiscoveredAgent().runtime,
        model: 'claude-3-5-sonnet',
      },
    })

    const getSpy = vi.spyOn(api.agents, 'get').mockResolvedValue(agent)
    const claimSpy = vi.spyOn(agentClaimApi, 'claimDiscoveredAgent').mockResolvedValue({
      claim_id: 'claim-uuid-1',
      status: 'granted',
      spiffe_svid_verified: true,
      allocated_token_budget: 250000,
      signal_session_url: '/ws/session/1',
      ebpf_sentinel_bound: true,
      agent_id: 'test-agent-presubmission',
    })

    const onClose = vi.fn()
    const onSuccess = vi.fn()

    render(
      <QueryClientProvider client={queryClient}>
        <ClaimModal agent={agent} onClose={onClose} onSuccess={onSuccess} />
      </QueryClientProvider>
    )

    getSpy.mockClear()

    const submitBtn = screen.getByTestId('claim-modal-submit-btn')
    fireEvent.click(submitBtn)

    await waitFor(() => {
      expect(claimSpy).toHaveBeenCalled()
    })

    expect(getSpy).toHaveBeenCalledWith('test-token', 'test-agent-presubmission')
    expect(onSuccess).toHaveBeenCalled()
    expect(onClose).toHaveBeenCalled()

    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['agents'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['discovery'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['workloads'] })
  })

  it('invokes onRefreshWorkload prop when provided instead of default api.agents.get', async () => {
    const initialAgent = createMockDiscoveredAgent({
      id: 'custom-refresh-agent',
      tenant_id: 'default',
      runtime: {
        ...createMockDiscoveredAgent().runtime,
        model: null,
      },
    })

    const freshAgent: AgentResponse = {
      ...initialAgent,
      runtime: {
        ...initialAgent.runtime,
        model: 'claude-3-5-sonnet',
      },
    }

    const customRefresh = vi.fn().mockResolvedValue(freshAgent)

    render(<ClaimModal agent={initialAgent} onClose={vi.fn()} onRefreshWorkload={customRefresh} />)

    await waitFor(() => {
      expect(customRefresh).toHaveBeenCalledWith('custom-refresh-agent')
    })

    await waitFor(() => {
      expect(screen.getByTestId('claim-modal-claimability-badge')).toHaveTextContent('Claimable')
    })
  })

  it('correctly maps demo-user@signalloom.local to tenant-demo avoiding false tenant mismatch', async () => {
    const prevUser = authState.user
    authState.user = { email: 'demo-user@signalloom.local', sub: 'demo-user' }

    const demoAgent = createMockDiscoveredAgent({
      id: 'demo-tenant-agent',
      name: 'test-agent-stunned',
      tenant_id: 'tenant-demo',
      tenant: 'tenant-demo',
      runtime: {
        ...createMockDiscoveredAgent().runtime,
        model: 'claude-3-5-sonnet',
      },
    })

    vi.spyOn(api.agents, 'get').mockResolvedValue(demoAgent)

    try {
      render(<ClaimModal agent={demoAgent} onClose={vi.fn()} />)

      await waitFor(() => {
        expect(screen.getByTestId('claim-modal-claimability-badge')).toHaveTextContent('Claimable')
      })

      expect(screen.getByTestId('claim-modal-prereq-tenant-badge')).toHaveTextContent('ALIGNED')
      expect(screen.getByTestId('claim-modal-prereq-tenant')).toHaveTextContent('tenant-demo')
      expect(screen.queryByTestId('claim-modal-error')).not.toBeInTheDocument()
    } finally {
      authState.user = prevUser
    }
  })
})




