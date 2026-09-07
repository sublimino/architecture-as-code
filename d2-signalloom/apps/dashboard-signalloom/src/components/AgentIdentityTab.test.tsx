import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import AgentIdentityTab from './AgentIdentityTab'
import type { AgentResponse, SourceHealthMap } from '../types/api'

function createMockAgent(overrides: Partial<AgentResponse> = {}): AgentResponse {
  return {
    id: 'agent-123-uuid',
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
      trust_domain: 'signalloom.demo',
      svid_type: 'x509',
      cert_valid_from: '2026-09-07T08:00:00Z',
      cert_valid_until: new Date(Date.now() + 14400000).toISOString(),
      cert_issuer: 'spiffe://signalloom.demo/spire/server',
      selectors: [
        'k8s:ns:fe-signalloom-agents',
        'k8s:sa:sa-order-agent',
        'k8s:pod-uid:uid-9876-5432',
        'k8s:node:kind-worker-1',
        'container:name:order-processing-agent',
      ],
      authorizing_principal_id: 'alice@signal-loom.ai',
      executing_actor_id: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-order-agent',
      delegation_hops: 1,
      openbao_role: 'agent-trust-sa-order-agent',
      openbao_path: 'kv/data/signalloom/agent-trust/fe-signalloom-agents/*',
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
      total_controls: 10,
      passed_controls: 8,
      failed_controls: 2,
      pending_controls: 0,
      normalized_score: 0.8,
    },
    attention: {
      level: 'critical',
      highest_issue: '2 failing controls detected',
    },
    timestamps: {
      created_at: '2026-08-15T09:00:00Z',
      last_observed_at: '2026-09-07T09:30:00Z',
      last_transition_at: '2026-09-01T12:00:00Z',
      last_action_at: '2026-09-07T09:15:00Z',
    },
    credential_state: {
      status: 'active',
      reason: null,
      revoked_at: null,
      revoked_by: null,
    },
    ...overrides,
  }
}

describe('AgentIdentityTab — 4 Summary StatCards', () => {
  it('renders SPIFFE Workload SVID card with full URI, linkage badge, trust domain and copy button', () => {
    const agent = createMockAgent()
    render(<AgentIdentityTab agent={agent} />)

    expect(screen.getByTestId('identity-card-spiffe')).toBeInTheDocument()
    expect(screen.getByTestId('identity-spiffe-id')).toHaveTextContent(
      'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-order-agent'
    )
    expect(screen.getByTestId('identity-spiffe-status')).toHaveTextContent('SPIFFE linked')
    expect(screen.getByTestId('identity-trust-domain')).toHaveTextContent('signalloom.demo')
    expect(screen.getByTestId('identity-copy-spiffe-id')).toBeInTheDocument()
  })

  it('renders Certificate Validity card with active status, SVID type and issuer', () => {
    const agent = createMockAgent()
    render(<AgentIdentityTab agent={agent} />)

    expect(screen.getByTestId('identity-card-cert')).toBeInTheDocument()
    expect(screen.getByTestId('identity-svid-type')).toHaveTextContent('X.509 SVID')
    expect(screen.getByTestId('identity-cert-validity')).toHaveTextContent(/Valid/i)
    expect(screen.getByTestId('identity-cert-issuer')).toHaveTextContent(
      'spiffe://signalloom.demo/spire/server'
    )
  })

  it('renders Workload Attestation card with selector count and target service account', () => {
    const agent = createMockAgent()
    render(<AgentIdentityTab agent={agent} />)

    expect(screen.getByTestId('identity-card-selectors')).toBeInTheDocument()
    expect(screen.getByTestId('identity-selectors-count')).toHaveTextContent('5 selectors')
    expect(screen.getByTestId('identity-card-selectors')).toHaveTextContent(
      'fe-signalloom-agents/sa-order-agent'
    )
  })

  it('renders Key Custody & Roles card with OpenBao role and in-memory custody mode', () => {
    const agent = createMockAgent()
    render(<AgentIdentityTab agent={agent} />)

    expect(screen.getByTestId('identity-card-custody')).toBeInTheDocument()
    expect(screen.getByTestId('identity-openbao-role')).toHaveTextContent('agent-trust-sa-order-agent')
    expect(screen.getByTestId('identity-card-custody')).toHaveTextContent('In-memory mTLS (No export)')
  })
})

describe('AgentIdentityTab — SVID Selectors & Workload Binding', () => {
  it('renders all attested SPIFFE selectors in the assertion list', () => {
    const agent = createMockAgent()
    render(<AgentIdentityTab agent={agent} />)

    const list = screen.getByTestId('identity-selectors-list')
    expect(list).toHaveTextContent('k8s:ns:fe-signalloom-agents')
    expect(list).toHaveTextContent('k8s:sa:sa-order-agent')
    expect(list).toHaveTextContent('k8s:pod-uid:uid-9876-5432')
    expect(list).toHaveTextContent('k8s:node:kind-worker-1')
    expect(list).toHaveTextContent('container:name:order-processing-agent')
  })

  it('renders runtime binding details including cluster, namespace, node, and pod UID', () => {
    const agent = createMockAgent()
    render(<AgentIdentityTab agent={agent} />)

    const panel = screen.getByTestId('identity-panel-selectors')
    expect(panel).toHaveTextContent('cluster-prod-1')
    expect(panel).toHaveTextContent('fe-signalloom-agents')
    expect(panel).toHaveTextContent('sa-order-agent')
    expect(panel).toHaveTextContent('kind-worker-1')
    expect(panel).toHaveTextContent('uid-9876-5432')
  })

  it('renders registered identity aliases when present', () => {
    const agent = createMockAgent()
    render(<AgentIdentityTab agent={agent} />)

    const aliasesList = screen.getByTestId('identity-aliases-list')
    expect(aliasesList).toHaveTextContent('order-proc')
    expect(aliasesList).toHaveTextContent('app:order-v1')
  })
})

describe('AgentIdentityTab — Delegation Chain & Separation of Identity Planes', () => {
  it('renders the 4-step delegation graph from Root CA to Executing Actor SVID', () => {
    const agent = createMockAgent()
    render(<AgentIdentityTab agent={agent} />)

    const chain = screen.getByTestId('identity-delegation-chain')
    expect(chain).toHaveTextContent('spiffe://signalloom.demo')
    expect(chain).toHaveTextContent('spiffe://signalloom.demo/spire/server')
    expect(screen.getByTestId('identity-authorizing-principal')).toHaveTextContent(
      'alice@signal-loom.ai'
    )
    expect(screen.getByTestId('identity-executing-actor')).toHaveTextContent(
      'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-order-agent'
    )
  })

  it('renders the explicit Separation of Identity Planes invariant notice', () => {
    const agent = createMockAgent()
    render(<AgentIdentityTab agent={agent} />)

    const notice = screen.getByTestId('identity-plane-separation-notice')
    expect(notice).toHaveTextContent('Separation of Identity Planes Invariant')
    expect(notice).toHaveTextContent('authorizing_principal_id')
    expect(notice).toHaveTextContent('executing_actor_id')
    expect(notice).toHaveTextContent('Workload identities do not inherit human user administrative permissions')
  })

  it('renders delegation hops count and tenant boundary', () => {
    const agent = createMockAgent()
    render(<AgentIdentityTab agent={agent} />)

    expect(screen.getByTestId('identity-delegation-hops')).toHaveTextContent(
      '1 hop (Delegated by alice@signal-loom.ai)'
    )
    expect(screen.getByTestId('identity-panel-delegation')).toHaveTextContent('tenant-acme')
  })
})

describe('AgentIdentityTab — OpenBao Integration & Key Custody', () => {
  it('renders OpenBao JWT role and secret path boundary', () => {
    const agent = createMockAgent()
    render(<AgentIdentityTab agent={agent} />)

    expect(screen.getByTestId('identity-openbao-role-detail')).toHaveTextContent('agent-trust-sa-order-agent')
    expect(screen.getByTestId('identity-openbao-path-detail')).toHaveTextContent(
      'kv/data/signalloom/agent-trust/fe-signalloom-agents/*'
    )
  })

  it('renders audience and rotation policy', () => {
    const agent = createMockAgent()
    render(<AgentIdentityTab agent={agent} />)

    const panel = screen.getByTestId('identity-panel-vault')
    expect(panel).toHaveTextContent('openbao-supercredential')
    expect(panel).toHaveTextContent('1h rotation')
  })
})

describe('AgentIdentityTab — Truthful State Language & Error Handling', () => {
  it('renders truthful "Identity unlinked" when spiffe_id is absent', () => {
    const agent = createMockAgent({
      identity: {
        spiffe_id: null,
        spiffe_status: 'unlinked',
        aliases: [],
      },
    })
    render(<AgentIdentityTab agent={agent} />)

    expect(screen.getByTestId('identity-spiffe-status')).toHaveTextContent('Identity unlinked')
    expect(screen.getByTestId('identity-spiffe-id')).toHaveTextContent('—')
    expect(screen.getByTestId('identity-unlinked-banner')).toBeInTheDocument()
    expect(screen.getByTestId('identity-cert-validity')).toHaveTextContent('No active SVID')
  })

  it('renders truthful "Registry not linked" for discovered workloads without registry binding', () => {
    const agent = createMockAgent({
      record_class: 'discovered',
      is_registry_linked: false,
      owner: null,
      responsibility: {
        owner_id: null,
        owner_name: null,
        team: null,
        assignment_status: 'registry_unlinked',
      },
      identity: {
        spiffe_id: null,
        spiffe_status: 'unlinked',
        aliases: [],
      },
    })
    render(<AgentIdentityTab agent={agent} />)

    expect(screen.getByTestId('identity-spiffe-status')).toHaveTextContent('Registry not linked')
    expect(screen.getByTestId('identity-authorizing-principal')).toHaveTextContent('Registry not linked')
  })

  it('renders truthful "Unassigned" when owner metadata is absent on registered agent', () => {
    const agent = createMockAgent({
      owner: null,
      responsibility: {
        owner_id: null,
        owner_name: null,
        team: null,
        assignment_status: 'unassigned',
      },
      identity: {
        spiffe_id: 'spiffe://signalloom.demo/ns/default/sa/test-agent',
        spiffe_status: 'linked',
        aliases: [],
        authorizing_principal_id: null,
      },
    })
    render(<AgentIdentityTab agent={agent} />)

    expect(screen.getByTestId('identity-authorizing-principal')).toHaveTextContent('Unassigned')
    expect(screen.getByTestId('identity-delegation-hops')).toHaveTextContent('0 hops (Direct Workload Execution)')
  })

  it('renders truthful "Source unavailable" banner when primary collector is offline', () => {
    const agent = createMockAgent()
    const sourceHealthDetail: SourceHealthMap = {
      k8s_discovery: { status: 'healthy' },
      postgres_registry: { status: 'healthy' },
      crypto_proofs: { status: 'unavailable', message: 'SPIRE node agent offline' },
    }
    render(
      <AgentIdentityTab
        agent={agent}
        sourceHealth="unavailable"
        sourceHealthDetail={sourceHealthDetail}
      />
    )

    expect(screen.getByTestId('identity-source-health-banner')).toBeInTheDocument()
    expect(screen.getByTestId('identity-source-health-banner')).toHaveTextContent('Source unavailable')
  })

  it('renders "Revoked" certificate status when credential is in revoked state', () => {
    const agent = createMockAgent({
      credential_state: {
        status: 'revoked',
        reason: 'SPIFFE SVID compromised',
        revoked_at: '2026-09-07T08:00:00Z',
        revoked_by: 'security-sentinel',
      },
    })
    render(<AgentIdentityTab agent={agent} />)

    expect(screen.getByTestId('identity-cert-validity')).toHaveTextContent('Revoked')
  })
})

describe('AgentIdentityTab — User Interactions', () => {
  it('copies SPIFFE SVID URI to clipboard on button click', () => {
    const writeTextMock = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, {
      clipboard: {
        writeText: writeTextMock,
      },
    })

    const agent = createMockAgent()
    render(<AgentIdentityTab agent={agent} />)

    const copyBtn = screen.getByTestId('identity-copy-spiffe-id')
    fireEvent.click(copyBtn)

    expect(writeTextMock).toHaveBeenCalledWith(
      'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-order-agent'
    )
    expect(copyBtn).toHaveTextContent('Copied!')
  })
})
