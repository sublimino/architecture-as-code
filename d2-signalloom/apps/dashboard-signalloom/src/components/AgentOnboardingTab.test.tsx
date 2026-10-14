import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import AgentOnboardingTab from './AgentOnboardingTab'
import type { AgentResponse } from '../types/api'

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    getAccessTokenSilently: vi.fn().mockResolvedValue('test-token'),
    user: { email: 'operator@signalloom.demo', tenant: 'default' },
    isAuthenticated: true,
  }),
}))

function createMockAgent(overrides: Partial<AgentResponse> = {}): AgentResponse {
  return {
    id: 'agent-kusari-847cc7d984-mwg8c',
    name: 'kusari-agent',
    type: 'custom',
    owner: 'unassigned',
    tenant_id: 'kusari',
    tenant: 'kusari',
    lifecycle_state: 'discovered',
    last_transition_at: null,
    eu_ai_act_risk_class: 'limited',
    compliance_summary: {
      total_controls: 8,
      passing: 6,
      failing: 2,
      pending: 0,
      posture_score: 75,
    },
    created_at: '2026-10-14T10:00:00Z',
    record_class: 'discovered',
    is_registry_linked: false,
    runtime: {
      cluster_id: 'osramp',
      namespace: 'fe-signalloom-agents',
      pod_name: 'agent-kusari-847cc7d984-mwg8c',
      service_account: 'kusari-agent',
      framework: 'custom',
      model: 'deterministic',
      node: 'kind-control-plane',
      phase: 'Running',
    },
    ...overrides,
  }
}

function renderTab(ui: React.ReactElement, initialEntries = ['/']) {
  return render(
    <MemoryRouter initialEntries={initialEntries}>
      {ui}
    </MemoryRouter>
  )
}

describe('AgentOnboardingTab', () => {
  it('renders onboarding guide header and pre-flight diagnostics matrix', () => {
    const agent = createMockAgent()
    renderTab(<AgentOnboardingTab agent={agent} />)

    expect(screen.getByTestId('agent-onboarding-tab')).toBeInTheDocument()
    expect(screen.getByText('Workload Onboarding & Governance Guide')).toBeInTheDocument()
    expect(screen.getByTestId('onboarding-diag-tenant')).toBeInTheDocument()
    expect(screen.getByTestId('onboarding-diag-spiffe')).toBeInTheDocument()
    expect(screen.getByTestId('onboarding-diag-sensor')).toBeInTheDocument()
    expect(screen.getByTestId('onboarding-diag-policy')).toBeInTheDocument()
    expect(screen.getByText('3-Step Workload Claim & Onboarding Procedure')).toBeInTheDocument()
  })

  it('renders tenant objection banner with remediation commands when workload tenant differs from operator tenant', () => {
    const agent = createMockAgent({ tenant: 'kusari', tenant_id: 'kusari' })
    renderTab(
      <AgentOnboardingTab
        agent={agent}
        claimError="Could not claim kusari-agent: Workload 'agent-kusari-847cc7d984-mwg8c' belongs to another tenant"
      />
    )

    expect(screen.getByTestId('onboarding-objection-banner')).toBeInTheDocument()
    expect(screen.getByText(/Multi-Tenant Claim Objection: Cross-Tenant Boundary Protection/)).toBeInTheDocument()
    expect(screen.getByText(/Could not claim kusari-agent: Workload 'agent-kusari-847cc7d984-mwg8c' belongs to another tenant/)).toBeInTheDocument()
    expect(screen.getByText(/kubectl -n fe-signalloom-agents label pod agent-kusari-847cc7d984-mwg8c signalloom.ai\/tenant=default --overwrite/)).toBeInTheDocument()
  })

  it('invokes onOpenClaim callback when Claim Agent Workload button is clicked', () => {
    const onOpenClaim = vi.fn()
    const agent = createMockAgent()
    renderTab(<AgentOnboardingTab agent={agent} onOpenClaim={onOpenClaim} />)

    const claimBtn = screen.getByTestId('onboarding-open-claim-btn')
    fireEvent.click(claimBtn)
    expect(onOpenClaim).toHaveBeenCalledTimes(1)
  })

  it('renders GitOps notice card when workload has Flux GitOps management signals', () => {
    const fluxAgent = createMockAgent({
      runtime: {
        cluster_id: 'osramp',
        namespace: 'fe-signalloom-agents',
        pod_name: 'agent-flux-managed-pod',
        labels: {
          'kustomize.toolkit.fluxcd.io/name': 'apps-fleet',
          'kustomize.toolkit.fluxcd.io/namespace': 'flux-system',
        },
      } as any,
    })

    renderTab(<AgentOnboardingTab agent={fluxAgent} />)

    expect(screen.getByTestId('onboarding-gitops-notice')).toBeInTheDocument()
    expect(screen.getByTestId('gitops-engine-badge')).toHaveTextContent('Flux GitOps Managed')
    expect(screen.getByTestId('gitops-recommendation')).toHaveTextContent(
      'This workload is managed by GitOps (flux). Imperative changes via kubectl will be overwritten by GitOps reconciliation. Commit the governance label change to your git repository or Kustomization manifest.'
    )
    expect(screen.getByTestId('onboarding-gitops-patch')).toHaveTextContent('signalloom.ai/tenant: default')
    expect(screen.getByTestId('onboarding-copy-gitops-patch-btn')).toBeInTheDocument()
  })

  it('renders ArgoCD GitOps badge when workload is managed by ArgoCD', () => {
    const argoAgent = createMockAgent({
      runtime: {
        cluster_id: 'osramp',
        namespace: 'fe-signalloom-agents',
        pod_name: 'agent-argo-managed-pod',
        labels: {
          'argocd.argoproj.io/instance': 'argo-fleet-app',
        },
      } as any,
    })

    renderTab(<AgentOnboardingTab agent={argoAgent} />)

    expect(screen.getByTestId('onboarding-gitops-notice')).toBeInTheDocument()
    expect(screen.getByTestId('gitops-engine-badge')).toHaveTextContent('ArgoCD Managed')
    expect(screen.getByTestId('gitops-recommendation')).toHaveTextContent('managed by GitOps (argo)')
  })

  it('does not render GitOps notice card for bare unmanaged workloads', () => {
    const bareAgent = createMockAgent()
    renderTab(<AgentOnboardingTab agent={bareAgent} />)

    expect(screen.queryByTestId('onboarding-gitops-notice')).not.toBeInTheDocument()
  })

  it('renders AI model objection banner with copyable remediation commands when workload lacks model declaration (e.g. netassert-generic-agent-fixture)', () => {
    const agent = createMockAgent({
      id: 'netassert-generic-agent-fixture-545f77f844-lvcdz',
      name: 'netassert-generic-agent-fixture',
      runtime: {
        cluster_id: 'osramp',
        namespace: 'fe-signalloom-agents',
        pod_name: 'netassert-generic-agent-fixture-545f77f844-lvcdz',
        service_account: 'netassert-agent',
        framework: 'custom',
        model: '' as any,
        node: 'kind-control-plane',
        phase: 'Running',
      },
    })

    renderTab(
      <AgentOnboardingTab
        agent={agent}
        claimError="Could not claim netassert-generic-agent-fixture-545f77f844-lvcdz: Workload 'netassert-generic-agent-fixture-545f77f844-lvcdz' declares no signalloom.ai/model; refusing to record an invented model."
      />
    )

    expect(screen.getByTestId('onboarding-objection-banner')).toBeInTheDocument()
    expect(screen.getByText(/Missing AI Model Declaration \(signalloom\.ai\/model\)/)).toBeInTheDocument()
    expect(screen.getByText(/refusing to record an invented model/)).toBeInTheDocument()
    expect(screen.getByText(/kubectl -n fe-signalloom-agents label pod netassert-generic-agent-fixture-545f77f844-lvcdz signalloom\.ai\/model=claude-3-5-sonnet --overwrite/)).toBeInTheDocument()
    expect(screen.getByText(/kubectl -n fe-signalloom-agents patch deployment netassert-generic-agent-fixture/)).toBeInTheDocument()
    expect(screen.getByTestId('onboarding-diag-model')).toBeInTheDocument()
    expect(screen.getByTestId('onboarding-diag-model')).toHaveTextContent('UNDECLARED')
  })

  it('renders undeclared tenant objection when error indicates workload_tenant_undeclared', () => {
    const agent = createMockAgent({
      id: 'agent-undeclared-tenant-1',
      name: 'undeclared-agent',
      tenant: undefined,
      tenant_id: 'undeclared',
    })

    renderTab(
      <AgentOnboardingTab
        agent={agent}
        claimError="Could not claim undeclared-agent: Workload 'agent-undeclared-tenant-1' declares no signalloom.ai/tenant; it cannot be claimed"
      />
    )

    expect(screen.getByTestId('onboarding-objection-banner')).toBeInTheDocument()
    expect(screen.getByText(/Undeclared Workload Tenant \(signalloom\.ai\/tenant\)/)).toBeInTheDocument()
    expect(screen.getByText(/kubectl -n fe-signalloom-agents label pod agent-kusari-847cc7d984-mwg8c signalloom\.ai\/tenant=default --overwrite/)).toBeInTheDocument()
  })

  it('renders model mismatch objection when asserted model differs from declared workload model', () => {
    const agent = createMockAgent({
      runtime: {
        cluster_id: 'osramp',
        namespace: 'fe-signalloom-agents',
        pod_name: 'agent-model-mismatch',
        service_account: 'test-agent',
        framework: 'custom',
        model: 'gpt-4o',
        node: 'kind-control-plane',
        phase: 'Running',
      },
    })

    renderTab(
      <AgentOnboardingTab
        agent={agent}
        claimError="Workload 'agent-model-mismatch' declares model 'gpt-4o', not 'claude-3-5-sonnet'"
      />
    )

    const banner = screen.getByTestId('onboarding-objection-banner')
    expect(banner).toBeInTheDocument()
    expect(within(banner).getByText(/Model Mismatch Objection/)).toBeInTheDocument()
    expect(within(banner).getByText(/Claim with Declared Model:/)).toBeInTheDocument()
    expect(within(banner).getAllByText(/gpt-4o/).length).toBeGreaterThanOrEqual(1)
  })

  it('reads claim_error from URL search params when prop is omitted', () => {
    const agent = createMockAgent({
      id: 'netassert-generic-agent-fixture-545f77f844-lvcdz',
      name: 'netassert-generic-agent-fixture',
    })

    render(
      <AgentOnboardingTab agent={agent} />,
      {
        wrapper: ({ children }) => (
          <MemoryRouter initialEntries={['/agents/netassert-generic-agent-fixture-545f77f844-lvcdz?tab=onboarding&claim_error=Workload%20declares%20no%20signalloom.ai%2Fmodel']}>
            {children}
          </MemoryRouter>
        ),
      }
    )

    expect(screen.getByTestId('onboarding-objection-banner')).toBeInTheDocument()
    expect(screen.getByText(/Missing AI Model Declaration \(signalloom\.ai\/model\)/)).toBeInTheDocument()
  })
})

