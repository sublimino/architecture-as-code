// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { WhoAuthorizedPanel } from './WhoAuthorizedPanel'
import type { AuthorizationChain } from '../api/weaveApi'

// Mock useAuth0
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    getAccessTokenSilently: vi.fn().mockResolvedValue('fake-token'),
  }),
}))

const mockCompleteChain: AuthorizationChain = {
  action: 'Outbound TLS connection to api.openai.com',
  agentIdentity: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa',
  actsOnBehalfOf: 'system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa acts-on-behalf-of security-admin@controlplane.io (authz: k8s-impersonation-policy)',
  principal: 'security-admin@controlplane.io',
  decision: 'authorized:actionable',
  confidence: 0.87,
  evidenceRefs: [
    'obs-id-001',
    'obs-net-001',
    'opa://decisions/2026-08-15/id-001',
    'k8s-audit://default/secrets/vault-token',
  ],
  attestationGitoid: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  complete: true,
  actorId: 'actor-shadow-llm-001',
  delegationChain: [
    {
      id: 1,
      delegate_actor_id: 'security-admin@controlplane.io',
      principal_actor_id: 'security-admin@controlplane.io',
      authz_ref: 'sso:saml:operator-claim',
      valid_from: '2026-08-15T00:00:00Z',
      role: 'Human Principal',
      containment_evidenced: true,
    },
    {
      id: 2,
      delegate_actor_id: 'agent-planner-service',
      principal_actor_id: 'security-admin@controlplane.io',
      authz_ref: 'k8s-rbac:planner-role-binding',
      valid_from: '2026-08-15T01:00:00Z',
      role: 'Planner / Orchestrator',
      containment_evidenced: true,
      nono_containment: true,
      spiffe_svid: 'spiffe://cluster.local/ns/fe-signalloom/sa/planner-sa',
    },
    {
      id: 3,
      delegate_actor_id: 'pipeline-data-bridge',
      principal_actor_id: 'agent-planner-service',
      authz_ref: 'jwt:openbao-scoped-delegation-token',
      valid_from: '2026-08-15T01:30:00Z',
      role: 'Pipeline Agent',
      containment_evidenced: true,
      nono_containment: true,
      spiffe_svid: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/pipeline-bridge-sa',
    },
    {
      id: 4,
      delegate_actor_id: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa',
      principal_actor_id: 'pipeline-data-bridge',
      authz_ref: 'k8s-impersonation-policy:secret-access',
      valid_from: '2026-08-15T02:00:00Z',
      valid_to: null,
      role: 'Executing Agent',
      containment_evidenced: true,
      nono_containment: true,
      spiffe_svid: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa',
    },
  ],
}

const mockCycleChain: AuthorizationChain = {
  ...mockCompleteChain,
  cycleDetected: true,
}

const mockIncompleteChain: AuthorizationChain = {
  action: 'Unregistered workload execution',
  agentIdentity: 'sa/unbound-agent',
  actsOnBehalfOf: '',
  principal: '',
  decision: 'evaluated:provisional',
  confidence: 0.35,
  evidenceRefs: ['obs-net-002'],
  attestationGitoid: '',
  complete: false,
  actorId: 'actor-unbound-002',
}

describe('WhoAuthorizedPanel', () => {
  it('renders the panel container and heading', () => {
    render(<WhoAuthorizedPanel chain={mockCompleteChain} />)
    expect(screen.getByTestId('who-authorized-panel')).toBeInTheDocument()
    expect(screen.getByText(/Who Authorized This Action\?/i)).toBeInTheDocument()
  })

  it('renders all 7 hops with non-empty content for a complete chain', () => {
    render(<WhoAuthorizedPanel chain={mockCompleteChain} />)

    // Hop 1: Action
    const actionEl = screen.getByTestId('hop-action')
    expect(actionEl).toBeInTheDocument()
    expect(actionEl.textContent).toContain('Outbound TLS connection to api.openai.com')

    // Hop 2: Agent Identity
    const agentEl = screen.getByTestId('hop-agent-identity')
    expect(agentEl).toBeInTheDocument()
    expect(agentEl.textContent).toContain('spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa')

    // Hop 3: Acts-On-Behalf-Of
    const oboEl = screen.getByTestId('hop-acts-on-behalf-of')
    expect(oboEl).toBeInTheDocument()
    expect(oboEl.textContent).toContain('acts-on-behalf-of security-admin@controlplane.io')

    // Hop 4: Principal
    const principalEl = screen.getByTestId('hop-principal')
    expect(principalEl).toBeInTheDocument()
    expect(principalEl.textContent).toContain('security-admin@controlplane.io')

    // Hop 5: Decision
    const decisionEl = screen.getByTestId('hop-decision')
    expect(decisionEl).toBeInTheDocument()
    expect(decisionEl.textContent).toContain('AUTHORIZED:ACTIONABLE')

    // Hop 6: Confidence & Evidence Refs
    const confEl = screen.getByTestId('hop-confidence')
    expect(confEl).toBeInTheDocument()
    expect(confEl.textContent).toContain('87.0% confidence')

    const refsEl = screen.getByTestId('hop-evidence-refs')
    expect(refsEl).toBeInTheDocument()
    expect(refsEl.textContent).toContain('obs-id-001')
    expect(refsEl.textContent).toContain('k8s-audit://default/secrets/vault-token')

    // Hop 7: Attestation GitOID
    const gitoidEl = screen.getByTestId('hop-attestation-gitoid')
    expect(gitoidEl).toBeInTheDocument()
    expect(gitoidEl.textContent).toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
  })

  it('renders COMPLETE ATTESTED CHAIN badge when complete is true', () => {
    render(<WhoAuthorizedPanel chain={mockCompleteChain} />)
    const badge = screen.getByTestId('chain-completeness-badge')
    expect(badge).toBeInTheDocument()
    expect(badge.textContent).toBe('COMPLETE ATTESTED CHAIN')
  })

  it('renders INCOMPLETE CHAIN badge when complete is false', () => {
    render(<WhoAuthorizedPanel chain={mockIncompleteChain} />)
    const badge = screen.getByTestId('chain-completeness-badge')
    expect(badge).toBeInTheDocument()
    expect(badge.textContent).toBe('INCOMPLETE CHAIN')
  })

  it('renders copy GitOID button and handles click', () => {
    const writeTextMock = vi.fn().mockImplementation(() => Promise.resolve())
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText: writeTextMock },
      configurable: true,
      writable: true,
    })

    render(<WhoAuthorizedPanel chain={mockCompleteChain} />)
    const copyBtn = screen.getByTestId('copy-gitoid-button')
    expect(copyBtn).toBeInTheDocument()
    fireEvent.click(copyBtn)
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith(mockCompleteChain.attestationGitoid)
  })

  it('renders Rekor attestation explorer link', () => {
    render(<WhoAuthorizedPanel chain={mockCompleteChain} />)
    const link = screen.getByTestId('rekor-explorer-link')
    expect(link).toBeInTheDocument()
    expect(link).toHaveAttribute('href', expect.stringContaining(mockCompleteChain.attestationGitoid))
    expect(link).toHaveAttribute('target', '_blank')
  })

  it('renders actor selector when available actors are provided', () => {
    const handleSelect = vi.fn()
    const actors = [
      { id: 'actor-1', name: 'Shadow LLM' },
      { id: 'actor-2', name: 'Scanner' },
    ]

    render(
      <WhoAuthorizedPanel
        chain={mockCompleteChain}
        availableActors={actors}
        onSelectActor={handleSelect}
      />
    )

    const select = screen.getByTestId('actor-selector')
    expect(select).toBeInTheDocument()
    fireEvent.change(select, { target: { value: 'actor-2' } })
    expect(handleSelect).toHaveBeenCalledWith('actor-2')
  })

  it('renders Hop 2 agent identity as a drill-down link to the agent overview', () => {
    render(<WhoAuthorizedPanel chain={mockCompleteChain} />)
    const link = screen.getByTestId('hop-agent-identity-link')
    expect(link).toHaveAttribute('href', '/agents/agent-cardvault?tab=overview')
  })

  it('renders stepped multi-node delegation path with hierarchy chips', () => {
    render(<WhoAuthorizedPanel chain={mockCompleteChain} />)
    expect(screen.getByTestId('delegation-stepped-path')).toBeInTheDocument()

    // 4 delegation hops rendered
    expect(screen.getByTestId('delegation-node-0')).toBeInTheDocument()
    expect(screen.getByTestId('delegation-node-1')).toBeInTheDocument()
    expect(screen.getByTestId('delegation-node-2')).toBeInTheDocument()
    expect(screen.getByTestId('delegation-node-3')).toBeInTheDocument()

    // Roles and steps verified
    expect(screen.getByTestId('delegation-node-step-0')).toHaveTextContent('Hop 1 / 4')
    expect(screen.getByTestId('delegation-node-step-3')).toHaveTextContent('Hop 4 / 4')

    // Landlock containment chip on nono-evidenced nodes
    expect(screen.getByTestId('delegation-node-landlock-1')).toHaveTextContent('Landlock Enforced')
    expect(screen.getByTestId('delegation-node-landlock-3')).toHaveTextContent('Landlock Enforced')
  })

  it('opens interactive drill-down modal on node click and closes on dismiss', () => {
    render(<WhoAuthorizedPanel chain={mockCompleteChain} />)
    const node1 = screen.getByTestId('delegation-node-1')

    // Click node 1 (Planner)
    fireEvent.click(node1)
    expect(screen.getByTestId('delegation-drilldown-modal-1')).toBeInTheDocument()
    expect(screen.getByTestId('modal-actor-id-1')).toHaveTextContent('agent-planner-service')
    expect(screen.getByTestId('modal-spiffe-id-1')).toHaveTextContent('spiffe://cluster.local/ns/fe-signalloom/sa/planner-sa')
    expect(screen.getByTestId('modal-authz-ref-1')).toHaveTextContent('k8s-rbac:planner-role-binding')
    expect(screen.getByTestId('modal-containment-1')).toHaveTextContent('Verified active via agent-nono-evidenced')

    // Close modal via close button
    const closeBtn = screen.getByTestId('close-modal-1')
    fireEvent.click(closeBtn)
    expect(screen.queryByTestId('delegation-drilldown-modal-1')).not.toBeInTheDocument()
  })

  it('supports keyboard navigation (Enter key) on delegation nodes', () => {
    render(<WhoAuthorizedPanel chain={mockCompleteChain} />)
    const node2 = screen.getByTestId('delegation-node-2')

    // Press Enter to open
    fireEvent.keyDown(node2, { key: 'Enter', code: 'Enter' })
    expect(screen.getByTestId('delegation-drilldown-modal-2')).toBeInTheDocument()

    // Press Escape to close
    fireEvent.keyDown(node2, { key: 'Escape', code: 'Escape' })
    expect(screen.queryByTestId('delegation-drilldown-modal-2')).not.toBeInTheDocument()
  })

  it('renders prominent CycleDetectedWarning when cycleDetected is true', () => {
    render(<WhoAuthorizedPanel chain={mockCycleChain} />)
    const alert = screen.getByTestId('cycle-detected-warning')
    expect(alert).toBeInTheDocument()
    expect(screen.getByTestId('cycle-detected-badge')).toHaveTextContent('CYCLE BLOCKED')
    expect(screen.getByTestId('cycle-detected-message')).toHaveTextContent(/circular delegation cycle detected/i)
  })
})
