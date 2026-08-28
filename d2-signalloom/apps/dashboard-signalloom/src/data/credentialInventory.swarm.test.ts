import { describe, it, expect } from 'vitest'
import {
  CONFIG_REGISTRATION_ENTRIES,
  TRUST_DOMAIN,
  spiffeId,
} from './credentialInventory'
import { FAKE_SWARM_CREDENTIALS } from '../api/fakeSwarmData'

const SWARM_NS = 'fe-signalloom-agents'

const ALL_SWARM_AGENTS = [
  'prompt-commit-summarizer',
  'triage-ci-worker',
  'zulip-chat-agent',
  'cpai-engineer',
  'hosted-daytona-coder',
  'swarm-governor',
  'prod-deploy-gate',
  'agent-cardvault',
  'nono-containment-probe',
  'signalloom-stun-sentinel',
]

const CREDENTIALED_AGENTS = [
  'prompt-commit-summarizer',
  'triage-ci-worker',
  'zulip-chat-agent',
  'cpai-engineer',
  'swarm-governor',
  'prod-deploy-gate',
  'agent-cardvault',
]

describe('credentialInventory — swarm registration entries', () => {
  // Filter to swarm-convention entries (carry the agent discovery selector),
  // excluding legacy entries like the original cardvault-agent.
  const swarmEntries = CONFIG_REGISTRATION_ENTRIES.filter(
    (e) => e.namespace === SWARM_NS && e.selectors.includes('k8s:pod-label:signalloom.ai/agent:true'),
  )

  it('has registration entries for all 10 swarm agents', () => {
    const sas = swarmEntries.map((e) => e.serviceAccount).sort()
    for (const agent of ALL_SWARM_AGENTS) {
      expect(sas, `missing registration entry for ${agent}`).toContain(agent)
    }
  })

  it('every swarm entry uses the correct trust domain', () => {
    for (const entry of swarmEntries) {
      expect(entry.spiffeId).toMatch(new RegExp(`^spiffe://${TRUST_DOMAIN}/`))
    }
  })

  it('every swarm entry uses the correct namespace in the SPIFFE ID', () => {
    for (const entry of swarmEntries) {
      expect(entry.spiffeId).toBe(spiffeId(SWARM_NS, entry.serviceAccount))
    }
  })

  it('every swarm entry carries the agent discovery selector', () => {
    for (const entry of swarmEntries) {
      expect(entry.selectors).toContain('k8s:pod-label:signalloom.ai/agent:true')
    }
  })

  it('every swarm entry targets the openbao-supercredential audience', () => {
    for (const entry of swarmEntries) {
      expect(entry.audience).toBe('openbao-supercredential')
    }
  })

  it('every swarm entry uses the signalloom-agent-generic baoRole', () => {
    for (const entry of swarmEntries) {
      expect(entry.baoRole).toBe('signalloom-agent-generic')
    }
  })
})

describe('credentialInventory — swarm credential records', () => {
  it('has CredentialRecords for the 7 credentialed agents', () => {
    const creds = FAKE_SWARM_CREDENTIALS.map((c) => c.workload).sort()
    for (const agent of CREDENTIALED_AGENTS) {
      expect(creds, `missing credential for ${agent}`).toContain(agent)
    }
  })

  it('all credential records use openbao-lease kind', () => {
    for (const cred of FAKE_SWARM_CREDENTIALS) {
      expect(cred.kind).toBe('openbao-lease')
    }
  })

  it('all credential records use the correct trust domain in SPIFFE ID', () => {
    for (const cred of FAKE_SWARM_CREDENTIALS) {
      expect(cred.spiffeId).toMatch(new RegExp(`^spiffe://${TRUST_DOMAIN}/`))
    }
  })

  it('no credentials exist for non-credentialed agents', () => {
    const nonCredentialed = ['hosted-daytona-coder', 'nono-containment-probe', 'signalloom-stun-sentinel']
    const credWorkloads = FAKE_SWARM_CREDENTIALS.map((c) => c.workload)
    for (const agent of nonCredentialed) {
      expect(credWorkloads).not.toContain(agent)
    }
  })
})
