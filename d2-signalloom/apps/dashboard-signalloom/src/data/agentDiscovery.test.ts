import { describe, it, expect } from 'vitest'
import { FAKE_SWARM_AGENTS } from '../api/fakeSwarmData'

describe('agentDiscovery — fake swarm agents', () => {
  it('has exactly 10 swarm agents', () => {
    expect(FAKE_SWARM_AGENTS).toHaveLength(10)
  })

  it('every agent has all required label fields', () => {
    for (const agent of FAKE_SWARM_AGENTS) {
      expect(agent.pod_name, `pod_name missing for ${agent.service_account}`).toBeTruthy()
      expect(agent.namespace, `namespace missing for ${agent.service_account}`).toBeTruthy()
      expect(agent.service_account, 'service_account missing').toBeTruthy()
      expect(agent.spiffe_id, `spiffe_id missing for ${agent.service_account}`).toMatch(/^spiffe:\/\//)
      expect(agent.tenant, `tenant missing for ${agent.service_account}`).toBeTruthy()
      expect(agent.project, `project missing for ${agent.service_account}`).toBeTruthy()
      expect(agent.role, `role missing for ${agent.service_account}`).toBeTruthy()
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
})
