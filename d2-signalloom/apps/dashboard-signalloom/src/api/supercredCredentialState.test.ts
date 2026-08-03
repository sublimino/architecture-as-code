/**
 * The credential-state projection.
 *
 * The stun's whole point is that the credentials are gone. That fact has to
 * reach the governance record the main pages render, derived from the same pod
 * observation as everything else — never fabricated, and never present at a
 * phase where the cluster has not reported one.
 */
import { describe, it, expect } from 'vitest'
import { buildSuperCredAgent, SUPERCRED_AGENT_ID, projectAgentList } from './supercredProjection'
import type { SuperCredDemoState, SuperCredPhase } from './supercredTypes'
import type { AgentListResponse } from '../types/api'

function stateAt(phase: SuperCredPhase, overrides: Record<string, unknown> = {}): SuperCredDemoState {
  return {
    phase,
    agent: phase === 'absent' ? null : {
      id: 'agent-cardvault',
      name: 'Cardvault Agent',
      namespace: 'fe-signalloom-agents',
      supercred: true,
      state: phase === 'stunned' ? 'stunned' : 'active',
      stunned_at: phase === 'stunned' ? '2026-08-02T10:05:00Z' : null,
      stun_reason: phase === 'stunned' ? 'compliance-failure: securityContext not set' : null,
      ...overrides,
    },
    scan: null,
    observedAt: '2026-08-02T10:00:00Z',
  }
}

const LIVE_PHASES: SuperCredPhase[] = ['deployed', 'credentialed', 'non-compliant']

describe('credential_state — before the stun', () => {
  it.each(LIVE_PHASES)('reports credentials as active at phase %s', (phase) => {
    const agent = buildSuperCredAgent(stateAt(phase))
    expect(agent?.credential_state).toEqual({ status: 'active' })
  })

  it.each(LIVE_PHASES)('claims no revocation timestamp at phase %s', (phase) => {
    const agent = buildSuperCredAgent(stateAt(phase))
    expect(agent?.credential_state?.revoked_at).toBeUndefined()
    expect(agent?.credential_state?.reason).toBeUndefined()
  })
})

describe('credential_state — after the stun', () => {
  it('reports the credentials as revoked', () => {
    const agent = buildSuperCredAgent(stateAt('stunned'))
    expect(agent?.credential_state?.status).toBe('revoked')
  })

  it('carries the reason the cluster reported, verbatim', () => {
    const agent = buildSuperCredAgent(stateAt('stunned'))
    expect(agent?.credential_state?.reason).toBe('compliance-failure: securityContext not set')
  })

  it('carries the revocation timestamp from the pod, not the observation time', () => {
    const agent = buildSuperCredAgent(stateAt('stunned'))
    expect(agent?.credential_state?.revoked_at).toBe('2026-08-02T10:05:00Z')
  })

  it('attributes the revocation to the platform', () => {
    const agent = buildSuperCredAgent(stateAt('stunned'))
    expect(agent?.credential_state?.revoked_by).toBe('signal-loom-platform')
  })

  it('falls back to the observation time when the pod carries no stun timestamp', () => {
    // A hand-run `kubectl label` sets the state but no annotation.
    const agent = buildSuperCredAgent(stateAt('stunned', { stunned_at: null }))
    expect(agent?.credential_state?.revoked_at).toBe('2026-08-02T10:00:00Z')
  })

  it('states a truthful fallback rather than inventing a cause', () => {
    const agent = buildSuperCredAgent(stateAt('stunned', { stun_reason: null }))
    expect(agent?.credential_state?.reason).toBe('revoked by the platform kill switch')
    expect(agent?.credential_state?.reason).not.toMatch(/securityContext/)
  })

  it('still reports suspended as the lifecycle state — the two are complementary', () => {
    const agent = buildSuperCredAgent(stateAt('stunned'))
    expect(agent?.lifecycle_state).toBe('suspended')
    expect(agent?.credential_state?.status).toBe('revoked')
  })
})

describe('credential_state — teardown', () => {
  it('produces no agent at all once the demo is torn down', () => {
    expect(buildSuperCredAgent(stateAt('absent'))).toBeNull()
  })

  it('leaves the tenant agent list untouched at phase absent', () => {
    const base = { agents: [], total: 0 } as AgentListResponse
    expect(projectAgentList(base, stateAt('absent'))).toBe(base)
  })
})

describe('credential_state — through the list projection', () => {
  it('reaches the agent list a normal user reads', () => {
    const base = { agents: [], total: 0 } as AgentListResponse
    const projected = projectAgentList(base, stateAt('stunned'))
    const row = projected.agents.find((a) => a.id === SUPERCRED_AGENT_ID)
    expect(row?.credential_state?.status).toBe('revoked')
    expect(row?.credential_state?.reason).toMatch(/securityContext/)
  })

  it('does not disturb the baseline agents already in the list', () => {
    const existing = {
      id: 'agent-baseline', name: 'Invoice Bot', type: null, tenant_id: 't',
      lifecycle_state: 'active', last_transition_at: null, eu_ai_act_risk_class: null,
      compliance_summary: { total_controls: 0, passing: 0, failing: 0, pending: 0, posture_score: null },
      created_at: null,
    }
    const base = { agents: [existing], total: 1 } as unknown as AgentListResponse
    const projected = projectAgentList(base, stateAt('stunned'))
    const baseline = projected.agents.find((a) => a.id === 'agent-baseline')
    expect(baseline?.credential_state).toBeUndefined()
  })
})
