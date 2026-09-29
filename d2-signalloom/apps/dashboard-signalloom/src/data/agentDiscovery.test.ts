import { describe, it, expect } from 'vitest'
import { FAKE_SWARM_AGENTS } from '../api/fakeSwarmData'
import {
  AGENT_LABELS,
  proxyRecordToDiscovery,
  isKernelContained,
  type ProxyAgentRecord,
} from './agentDiscovery'

describe('agentDiscovery — fake swarm agents', () => {
  it('has exactly 10 swarm agents', () => {
    expect(FAKE_SWARM_AGENTS).toHaveLength(10)
  })

  it('every agent has all required orthogonal label fields', () => {
    for (const agent of FAKE_SWARM_AGENTS) {
      expect(agent.pod_name, `pod_name missing for ${agent.service_account}`).toBeTruthy()
      expect(agent.namespace, `namespace missing for ${agent.service_account}`).toBeTruthy()
      expect(agent.service_account, 'service_account missing').toBeTruthy()
      expect(agent.spiffe_id, `spiffe_id missing for ${agent.service_account}`).toMatch(/^spiffe:\/\//)
      expect(agent.tenant, `tenant missing for ${agent.service_account}`).toBeTruthy()
      expect(agent.project, `project missing for ${agent.service_account}`).toBeTruthy()
      expect(agent.role, `role missing for ${agent.service_account}`).toBeTruthy()
      expect(agent.framework, `framework missing for ${agent.service_account}`).toBeTruthy()
      expect(agent.state, `state missing for ${agent.service_account}`).toBeTruthy()
      expect(agent.kernel_telemetry, `kernel_telemetry missing for ${agent.service_account}`).toBeDefined()
      expect(agent.provenance).toBe('demo')
    }
  })

  it('all agents are in the fe-signalloom-agents namespace', () => {
    for (const agent of FAKE_SWARM_AGENTS) {
      expect(agent.namespace).toBe('fe-signalloom-agents')
    }
  })

  it('each agent has a unique service account', () => {
    const sas = FAKE_SWARM_AGENTS.map((a) => a.service_account)
    expect(new Set(sas).size).toBe(sas.length)
  })

  it('each agent has a unique pod name', () => {
    const pods = FAKE_SWARM_AGENTS.map((a) => a.pod_name)
    expect(new Set(pods).size).toBe(pods.length)
  })

  it('all agents have a created_at timestamp', () => {
    for (const agent of FAKE_SWARM_AGENTS) {
      expect(agent.created_at).toBeTruthy()
      expect(() => new Date(agent.created_at!)).not.toThrow()
    }
  })

  it('declares the unified orthogonal label ontology keys', () => {
    expect(AGENT_LABELS.agent).toBe('signalloom.ai/agent')
    expect(AGENT_LABELS.framework).toBe('signalloom.ai/framework')
    expect(AGENT_LABELS.harness).toBe('signalloom.ai/harness')
    expect(AGENT_LABELS.role).toBe('signalloom.ai/role')
    expect(AGENT_LABELS.tenant).toBe('signalloom.ai/tenant')
    expect(AGENT_LABELS.state).toBe('signalloom.ai/state')
  })

  it('normalizes live proxy records with orthogonal labels and Sentinel telemetry', () => {
    const raw: ProxyAgentRecord = {
      id: 'kagent-incident-responder',
      name: 'kagent-incident-responder-pod-1',
      namespace: 'fe-signalloom-agents',
      service_account: 'kagent-incident-responder',
      labels: {
        'signalloom.ai/agent': 'true',
        'signalloom.ai/framework': 'kagent',
        'signalloom.ai/harness': 'kagent-runtime',
        'signalloom.ai/role': 'responder',
        'signalloom.ai/tenant': 'controlplane',
        'signalloom.ai/state': 'stunned',
      },
      // The sentinel annotation, as the proxy carries it. The stun label alone
      // no longer implies a frozen cgroup.
      kernel_state: 'frozen',
    }
    const record = proxyRecordToDiscovery(raw, 'live')
    expect(record.framework).toBe('kagent')
    expect(record.harness).toBe('kagent-runtime')
    expect(record.role).toBe('responder')
    expect(record.tenant).toBe('controlplane')
    expect(record.state).toBe('stunned')
    expect(record.kernel_telemetry?.cgroup_frozen).toBe(true)
    expect(record.kernel_telemetry?.cgroup_state).toBe('frozen')
    // Nothing observed TC, so nothing is claimed about it.
    expect(record.kernel_telemetry?.tc_drop_active).toBeNull()
    expect(isKernelContained(record)).toBe(true)
  })

  it('reports active agent with thawed cgroup and passing TC filter', () => {
    const raw: ProxyAgentRecord = {
      id: 'triage-ci-worker',
      labels: {
        'signalloom.ai/agent': 'true',
        'signalloom.ai/framework': 'custom',
        'signalloom.ai/role': 'triage',
        'signalloom.ai/state': 'active',
      },
      kernel_state: 'running',
    }
    const record = proxyRecordToDiscovery(raw, 'live')
    expect(record.kernel_telemetry?.cgroup_frozen).toBe(false)
    expect(record.kernel_telemetry?.cgroup_state).toBe('thawed')
    expect(record.kernel_telemetry?.tc_drop_active).toBeNull()
    expect(isKernelContained(record)).toBe(false)
  })
})
