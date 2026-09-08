import { describe, it, expect } from 'vitest'
import { findMatchingAgent } from './agentMatching'
import type { AgentResponse } from '../types/api'

function mockAgent(overrides: Partial<AgentResponse> = {}): AgentResponse {
  return {
    id: 'agent-1',
    name: 'agent-billing-sync',
    type: 'Signal Loom Built',
    tenant_id: 'tenant-1',
    lifecycle_state: 'active',
    last_transition_at: null,
    eu_ai_act_risk_class: null,
    compliance_summary: {
      total_controls: 10,
      passing: 8,
      failing: 2,
      pending: 0,
      posture_score: 80,
    },
    created_at: null,
    ...overrides,
  }
}

describe('findMatchingAgent', () => {
  const agents: AgentResponse[] = [
    mockAgent({ id: 'agent-sir-lancelot', name: 'agent-sir-lancelot', owner: 'alice@acme.com' }),
    mockAgent({ id: 'kagent-chaos-prober', name: 'kagent-chaos-prober', service_account: 'kagent-chaos-prober' }),
    mockAgent({ id: 'agent-billing-sync', name: 'Billing Synchronizer', service_account: 'svc-billing-sync' }),
    mockAgent({ id: 'agent-4', name: 'salesforce-exporter', owner: 'bob@acme.com' }),
  ]

  it('returns undefined if agents list is empty', () => {
    expect(findMatchingAgent({ account_name: 'svc-billing-sync' }, [])).toBeUndefined()
  })

  it('matches by exact ID', () => {
    const match = findMatchingAgent({ account_name: 'anything', id: 'agent-sir-lancelot' }, agents)
    expect(match?.id).toBe('agent-sir-lancelot')
  })

  it('matches by exact service_account', () => {
    const match = findMatchingAgent({ account_name: 'svc-billing-sync' }, agents)
    expect(match?.id).toBe('agent-billing-sync')
  })

  it('matches by normalized slug stripping svc- / agent- prefixes', () => {
    const match = findMatchingAgent({ account_name: 'svc-sir-lancelot' }, agents)
    expect(match?.id).toBe('agent-sir-lancelot')
  })

  it('matches by unique owner email when name does not match', () => {
    const match = findMatchingAgent({ account_name: 'unmatched-account', owner_email: 'bob@acme.com' }, agents)
    expect(match?.id).toBe('agent-4')
  })

  it('matches by id: prefix in target ID', () => {
    const match = findMatchingAgent({ account_name: 'anything', id: 'id:agent-sir-lancelot' }, agents)
    expect(match?.id).toBe('agent-sir-lancelot')
  })

  it('matches by sa: prefix in account name', () => {
    const match = findMatchingAgent({ account_name: 'sa:svc-billing-sync' }, agents)
    expect(match?.id).toBe('agent-billing-sync')
  })

  it('returns undefined when no agent matches', () => {
    const match = findMatchingAgent({ account_name: 'completely-unknown-svc', owner_email: 'unknown@example.com' }, agents)
    expect(match).toBeUndefined()
  })
})

