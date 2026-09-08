import { describe, it, expect } from 'vitest'
import {
  parseAgentSelectorQuery,
  matchAgentByQuery,
  resolveAgentOrInstance,
} from './agentQuerySelectors'
import type { AgentResponse } from '../types/api'

const mockAgents: AgentResponse[] = [
  {
    id: 'UUID-23-1245-124',
    name: 'Sir Lancelot',
    type: 'Signal Loom Built',
    owner: 'alice@acme.com',
    tenant_id: 'tenant-acme',
    lifecycle_state: 'active',
    last_transition_at: '2026-08-01T10:00:00Z',
    eu_ai_act_risk_class: 'low',
    compliance_summary: { total_controls: 10, passing: 10, failing: 0, pending: 0, posture_score: 1.0 },
    created_at: '2026-08-01T09:00:00Z',
    namespace: 'fe-signalloom-agents',
    service_account: 'agent-sir-lancelot-sa',
    pod_uid: 'uid-lancelot-999',
    runtime: {
      cluster_id: 'kind-osramp',
      namespace: 'fe-signalloom-agents',
      pod_name: 'agent-sir-lancelot-6f8b5d-xyz',
      pod_uid: 'uid-lancelot-999',
      service_account: 'agent-sir-lancelot-sa',
      framework: 'langchain',
      model: 'claude-3-5-sonnet',
    },
    identity: {
      spiffe_id: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-sir-lancelot-sa',
      spiffe_status: 'linked',
      aliases: ['lancelot'],
      selectors: ['k8s:ns:fe-signalloom-agents', 'k8s:sa:agent-sir-lancelot-sa', 'app=lancelot'],
    },
  },
  {
    id: 'agent-cardvault',
    name: 'CardVault Agent',
    type: 'Custom',
    owner: 'bob@acme.com',
    tenant_id: 'tenant-acme',
    lifecycle_state: 'suspended',
    last_transition_at: '2026-08-01T10:00:00Z',
    eu_ai_act_risk_class: 'high',
    compliance_summary: { total_controls: 12, passing: 8, failing: 4, pending: 0, posture_score: 0.67 },
    created_at: '2026-08-01T09:00:00Z',
    namespace: 'fe-signalloom-agents',
    service_account: 'cardvault-agent',
    pod_uid: 'uid-cardvault-001',
    runtime: {
      cluster_id: 'kind-osramp',
      namespace: 'fe-signalloom-agents',
      pod_name: 'cardvault-agent-777-abc',
      pod_uid: 'uid-cardvault-001',
      service_account: 'cardvault-agent',
      framework: 'autogen',
      model: 'gpt-4o',
    },
    identity: {
      spiffe_id: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent',
      spiffe_status: 'linked',
      aliases: ['cardvault'],
      selectors: ['k8s:ns:fe-signalloom-agents', 'k8s:sa:cardvault-agent', 'app=cardvault', 'tier=vault'],
    },
  },
  {
    id: 'agent-trust-planner',
    name: 'planner',
    type: 'Signal Loom Built',
    owner: 'ops@acme.com',
    tenant_id: 'acme',
    lifecycle_state: 'active',
    last_transition_at: '2026-08-02T10:00:00Z',
    eu_ai_act_risk_class: null,
    compliance_summary: { total_controls: 5, passing: 5, failing: 0, pending: 0, posture_score: 1.0 },
    created_at: '2026-08-02T09:00:00Z',
    namespace: 'agent-trust-acme-payments',
    service_account: 'agent-trust-planner',
    runtime: {
      namespace: 'agent-trust-acme-payments',
      service_account: 'agent-trust-planner',
    },
    identity: {
      spiffe_id: 'spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/planner',
      spiffe_status: 'linked',
      aliases: ['planner'],
      selectors: ['k8s:ns:agent-trust-acme-payments', 'k8s:sa:agent-trust-planner'],
    },
  },
]

describe('parseAgentSelectorQuery', () => {
  it('handles empty or whitespace strings', () => {
    const res = parseAgentSelectorQuery('   ')
    expect(res.raw).toBe('')
    expect(res.clauses).toHaveLength(0)
    expect(res.isStructured).toBe(false)
  })

  it('parses id: and uuid: prefixes', () => {
    const q1 = parseAgentSelectorQuery('id:UUID-23-1245-124')
    expect(q1.isStructured).toBe(true)
    expect(q1.clauses[0]).toEqual({
      prefix: 'id',
      value: 'UUID-23-1245-124',
      raw: 'id:UUID-23-1245-124',
      isInstanceSelector: false,
    })

    const q2 = parseAgentSelectorQuery('uuid:some-uuid-456')
    expect(q2.clauses[0].prefix).toBe('id')
    expect(q2.clauses[0].value).toBe('some-uuid-456')
  })

  it('parses sa: and serviceaccount: prefixes', () => {
    const q = parseAgentSelectorQuery('sa:cardvault-agent')
    expect(q.clauses[0]).toEqual({
      prefix: 'sa',
      value: 'cardvault-agent',
      raw: 'sa:cardvault-agent',
      isInstanceSelector: false,
    })
  })

  it('parses spiffe: prefix', () => {
    const q = parseAgentSelectorQuery('spiffe:signalloom.demo')
    expect(q.clauses[0].prefix).toBe('spiffe')
    expect(q.clauses[0].value).toBe('signalloom.demo')
    expect(q.hasInstanceSelector).toBe(true)
  })

  it('parses pod: and pod_uid: prefixes as instance selectors', () => {
    const q = parseAgentSelectorQuery('pod:agent-cardvault-777-abc')
    expect(q.clauses[0].prefix).toBe('pod')
    expect(q.hasInstanceSelector).toBe(true)
  })

  it('parses Kubernetes label key=value syntax', () => {
    const q1 = parseAgentSelectorQuery('app=cardvault')
    expect(q1.clauses[0]).toEqual({
      prefix: 'label',
      key: 'app',
      value: 'cardvault',
      raw: 'app=cardvault',
      isInstanceSelector: true,
    })

    const q2 = parseAgentSelectorQuery('label:tier=vault')
    expect(q2.clauses[0]).toEqual({
      prefix: 'label',
      key: 'tier',
      value: 'vault',
      raw: 'label:tier=vault',
      isInstanceSelector: true,
    })
  })

  it('parses k8s: selector prefixes', () => {
    const q = parseAgentSelectorQuery('k8s:sa:agent-trust-planner')
    expect(q.clauses[0].prefix).toBe('k8s')
    expect(q.clauses[0].value).toBe('k8s:sa:agent-trust-planner')
    expect(q.hasInstanceSelector).toBe(true)
  })

  it('parses compound queries with multiple terms', () => {
    const q = parseAgentSelectorQuery('ns:fe-signalloom-agents sa:cardvault-agent app=cardvault')
    expect(q.clauses).toHaveLength(3)
    expect(q.clauses[0].prefix).toBe('ns')
    expect(q.clauses[1].prefix).toBe('sa')
    expect(q.clauses[2].prefix).toBe('label')
    expect(q.hasInstanceSelector).toBe(true)
  })

  it('handles comma-separated selectors', () => {
    const q = parseAgentSelectorQuery('k8s:ns:fe-signalloom-agents,k8s:sa:cardvault-agent')
    expect(q.clauses).toHaveLength(2)
  })
})

describe('matchAgentByQuery', () => {
  it('matches exact id with id: prefix', () => {
    expect(matchAgentByQuery(mockAgents[0], 'id:UUID-23-1245-124')).toBe(true)
    expect(matchAgentByQuery(mockAgents[1], 'id:UUID-23-1245-124')).toBe(false)
  })

  it('matches service account with sa: prefix', () => {
    expect(matchAgentByQuery(mockAgents[1], 'sa:cardvault-agent')).toBe(true)
    expect(matchAgentByQuery(mockAgents[0], 'sa:cardvault-agent')).toBe(false)
  })

  it('matches SPIFFE URI substring with spiffe: prefix', () => {
    expect(matchAgentByQuery(mockAgents[2], 'spiffe:tenant/acme')).toBe(true)
    expect(matchAgentByQuery(mockAgents[0], 'spiffe:tenant/acme')).toBe(false)
  })

  it('matches pod UID with pod: prefix', () => {
    expect(matchAgentByQuery(mockAgents[0], 'pod:uid-lancelot-999')).toBe(true)
    expect(matchAgentByQuery(mockAgents[1], 'pod:uid-lancelot-999')).toBe(false)
  })

  it('matches label selectors', () => {
    expect(matchAgentByQuery(mockAgents[1], 'tier=vault')).toBe(true)
    expect(matchAgentByQuery(mockAgents[0], 'tier=vault')).toBe(false)
  })

  it('matches k8s selectors', () => {
    expect(matchAgentByQuery(mockAgents[2], 'k8s:sa:agent-trust-planner')).toBe(true)
    expect(matchAgentByQuery(mockAgents[0], 'k8s:sa:agent-trust-planner')).toBe(false)
  })

  it('enforces AND semantics on compound queries', () => {
    expect(matchAgentByQuery(mockAgents[1], 'ns:fe-signalloom-agents sa:cardvault-agent')).toBe(true)
    expect(matchAgentByQuery(mockAgents[1], 'ns:wrong-namespace sa:cardvault-agent')).toBe(false)
  })

  it('preserves backward-compatible plain text search', () => {
    expect(matchAgentByQuery(mockAgents[0], 'lancelot')).toBe(true)
    expect(matchAgentByQuery(mockAgents[0], 'alice@acme.com')).toBe(true)
    expect(matchAgentByQuery(mockAgents[1], 'cardvault')).toBe(true)
    expect(matchAgentByQuery(mockAgents[2], 'payments')).toBe(true)
    expect(matchAgentByQuery(mockAgents[2], 'nonexistent-query')).toBe(false)
  })

  it('handles case-insensitive prefixes and values', () => {
    expect(matchAgentByQuery(mockAgents[0], 'ID:UUID-23-1245-124')).toBe(true)
    expect(matchAgentByQuery(mockAgents[1], 'SA:CARDVAULT-AGENT')).toBe(true)
    expect(matchAgentByQuery(mockAgents[2], 'K8S:SA:AGENT-TRUST-PLANNER')).toBe(true)
    expect(matchAgentByQuery(mockAgents[0], 'NS:FE-SIGNALLOOM-AGENTS')).toBe(true)
    expect(matchAgentByQuery(mockAgents[0], 'CLUSTER:KIND-OSRAMP')).toBe(true)
    expect(matchAgentByQuery(mockAgents[0], 'FRAMEWORK:LANGCHAIN')).toBe(true)
    expect(matchAgentByQuery(mockAgents[0], 'MODEL:CLAUDE')).toBe(true)
  })

  it('handles agents with missing or nullish runtime and identity fields gracefully', () => {
    const minimalAgent: AgentResponse = {
      id: 'agent-minimal',
      name: 'Minimal Agent',
      type: 'Custom',
      owner: 'dev@acme.com',
      tenant_id: 'acme',
      lifecycle_state: 'active',
      last_transition_at: '2026-08-01T00:00:00Z',
      eu_ai_act_risk_class: null,
      compliance_summary: { total_controls: 0, passing: 0, failing: 0, pending: 0, posture_score: 0 },
      created_at: '2026-08-01T00:00:00Z',
    }

    expect(matchAgentByQuery(minimalAgent, 'id:agent-minimal')).toBe(true)
    expect(matchAgentByQuery(minimalAgent, 'sa:nonexistent')).toBe(false)
    expect(matchAgentByQuery(minimalAgent, 'pod:nonexistent')).toBe(false)
    expect(matchAgentByQuery(minimalAgent, 'spiffe:nonexistent')).toBe(false)
    expect(matchAgentByQuery(minimalAgent, 'app=nonexistent')).toBe(false)
    expect(matchAgentByQuery(minimalAgent, 'minimal')).toBe(true)
  })

  it('handles null, undefined, and empty string queries safely', () => {
    // Empty query matches all agents
    expect(matchAgentByQuery(mockAgents[0], '')).toBe(true)
    expect(matchAgentByQuery(mockAgents[0], '   ')).toBe(true)
  })
})

describe('resolveAgentOrInstance', () => {
  it('resolves an exact agent instance with instance selector', () => {
    const res = resolveAgentOrInstance(mockAgents, 'pod:uid-lancelot-999')
    expect(res.matchedAgent?.id).toBe('UUID-23-1245-124')
    expect(res.isExactInstance).toBe(true)
    expect(res.matchedInstanceDetails?.podUid).toBe('uid-lancelot-999')
  })

  it('resolves logical agent when queried by id', () => {
    const res = resolveAgentOrInstance(mockAgents, 'id:agent-trust-planner')
    expect(res.matchedAgent?.id).toBe('agent-trust-planner')
    expect(res.allMatches).toHaveLength(1)
  })

  it('returns empty result when no agent matches', () => {
    const res = resolveAgentOrInstance(mockAgents, 'id:non-existent-agent-id')
    expect(res.matchedAgent).toBeUndefined()
    expect(res.allMatches).toHaveLength(0)
  })

  it('handles empty agent list and null query without error', () => {
    const res1 = resolveAgentOrInstance([], 'id:some-id')
    expect(res1.matchedAgent).toBeUndefined()
    expect(res1.allMatches).toHaveLength(0)

    const res2 = resolveAgentOrInstance(mockAgents, '')
    expect(res2.allMatches).toHaveLength(0)
    expect(res2.matchedAgent).toBeUndefined()
    expect(res2.isExactInstance).toBe(false)
  })
})
