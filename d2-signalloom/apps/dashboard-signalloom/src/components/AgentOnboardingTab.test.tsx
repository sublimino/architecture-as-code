import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
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

describe('AgentOnboardingTab', () => {
  it('renders onboarding guide header and pre-flight diagnostics matrix', () => {
    const agent = createMockAgent()
    render(<AgentOnboardingTab agent={agent} />)

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
    render(
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
    render(<AgentOnboardingTab agent={agent} onOpenClaim={onOpenClaim} />)

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

    render(<AgentOnboardingTab agent={fluxAgent} />)

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

    render(<AgentOnboardingTab agent={argoAgent} />)

    expect(screen.getByTestId('onboarding-gitops-notice')).toBeInTheDocument()
    expect(screen.getByTestId('gitops-engine-badge')).toHaveTextContent('ArgoCD Managed')
    expect(screen.getByTestId('gitops-recommendation')).toHaveTextContent('managed by GitOps (argo)')
  })

  it('does not render GitOps notice card for bare unmanaged workloads', () => {
    const bareAgent = createMockAgent()
    render(<AgentOnboardingTab agent={bareAgent} />)

    expect(screen.queryByTestId('onboarding-gitops-notice')).not.toBeInTheDocument()
  })
})
