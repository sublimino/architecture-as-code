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
    // Mock navigator.clipboard
    Object.assign(navigator, {
      clipboard: {
        writeText: vi.fn().mockImplementation(() => Promise.resolve()),
      },
    })

    render(<WhoAuthorizedPanel chain={mockCompleteChain} />)
    const copyBtn = screen.getByTestId('copy-gitoid-button')
    expect(copyBtn).toBeInTheDocument()
    fireEvent.click(copyBtn)
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith(mockCompleteChain.attestationGitoid)
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
})

