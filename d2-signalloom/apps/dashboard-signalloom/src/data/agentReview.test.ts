import { describe, expect, it } from 'vitest'
import type { AgentResponse } from '../types/api'
import { deriveAgentReview, needsAgentReview } from './agentReview'

const agent = (overrides: Partial<AgentResponse> = {}): AgentResponse => ({
  id: 'a', name: 'Alpha', type: null, tenant_id: 't', lifecycle_state: 'active',
  last_transition_at: null, eu_ai_act_risk_class: null, created_at: null,
  compliance_summary: { total_controls: 5, passing: 5, failing: 0, pending: 0, posture_score: 1 },
  ...overrides,
})

describe('agent review public model', () => {
  it('keeps independently requested network and credential planes unresolved despite confirmed freeze', () => {
    const partial = agent({ kernel_state: 'frozen', operational_state: { runtime_status: 'stopped', containment: {
      process_freeze: 'active', network_isolation: 'requested', credential_revocation: 'requested', source: 'sentinel-annotation', credential_source: 'stun-audit',
    } } })
    const issue = deriveAgentReview([partial]).issues[0]
    expect(issue).toMatchObject({ category: 'containment-unconfirmed' })
    expect(issue.description).toContain('Network isolation')
    expect(issue.description).toContain('Credential revocation')
    expect(issue.description).not.toContain('Process freeze')
    expect(needsAgentReview({ ...partial, kernel_telemetry: { cgroup_state: 'frozen', traffic_control_state: 'drop' } })).toBe(true)
    expect(needsAgentReview({ ...partial, kernel_telemetry: { cgroup_state: 'frozen', traffic_control_state: 'drop' }, operational_state: { runtime_status: 'stopped', containment: {
      ...partial.operational_state!.containment, credential_revocation: 'active', credential_source: 'registry',
    } } })).toBe(false)
  })
  it('does not let confirmed network or credentials resolve explicitly requested freeze', () => {
    const partial = agent({ operational_state: { runtime_status: 'running', containment: {
      process_freeze: 'requested', network_isolation: 'active', credential_revocation: 'active', source: 'sentinel-annotation', credential_source: 'registry',
    } } })
    expect(deriveAgentReview([partial]).issues[0]?.description).toContain('Process freeze')
    expect(needsAgentReview({ ...partial, kernel_state: 'frozen' })).toBe(false)
  })
  it('does not invent an incident for unknown credentials with no request', () => {
    expect(needsAgentReview(agent({ operational_state: { runtime_status: 'unknown', containment: {
      process_freeze: 'inactive', network_isolation: 'inactive', credential_revocation: 'unknown', source: 'unavailable', credential_source: 'unavailable',
    } } }))).toBe(false)
  })
  it.each(['warning', 'critical'] as const)('retains otherwise unrepresented server %s findings and their context', level => {
    const finding = agent({ attention: { level, highest_issue: 'Missing SBOM attestation' } })
    expect(deriveAgentReview([finding]).issues[0]).toMatchObject({ category: 'server-attention', severity: level, description: 'Missing SBOM attestation' })
    expect(needsAgentReview(finding)).toBe(true)
    expect(deriveAgentReview([agent({ attention: { level, highest_issue: null } })]).issues[0]?.category).toBe('server-attention')
  })
  it('retains contextless server warning alongside critical posture: the API may report errored controls', () => {
    const warned = agent({ attention: { level: 'warning', highest_issue: null }, compliance_summary: { total_controls: 5, passing: 5, failing: 0, pending: 0, posture_score: 0.2 } })
    expect(deriveAgentReview([warned]).issues.map(issue => issue.category)).toEqual(['critical-posture', 'server-attention'])
  })
  it('deduplicates server-generated failing controls and split-brain findings, not unrelated context', () => {
    const failing = agent({ compliance_summary: { total_controls: 5, passing: 3, failing: 2, pending: 0, posture_score: 0.6 }, attention: { level: 'critical', highest_issue: '2 failing controls' } })
    expect(deriveAgentReview([failing]).issues.map(i => i.category)).toEqual(['failing-controls'])
    expect(deriveAgentReview([{ ...failing, attention: { level: 'warning', highest_issue: 'Missing SBOM attestation' } }]).issues.map(i => i.category)).toEqual(['failing-controls', 'server-attention'])
    expect(deriveAgentReview([agent({ kernel_state: 'frozen', split_brain: ['kernel frozen without stun record'], attention: { level: 'critical', highest_issue: 'kernel frozen without stun record' } })]).issues.map(i => i.category)).toEqual(['kernel-split-brain'])
    expect(needsAgentReview(agent({ lifecycle_state: 'Suspended', attention: { level: 'critical', highest_issue: 'Agent state is Suspended' } }))).toBe(false)
  })
  it('does not duplicate server stun-without-freeze context already represented by the unresolved process plane', () => {
    const partial = agent({ kernel_state: 'running', split_brain: ['stun record without kernel freeze'], attention: { level: 'critical', highest_issue: 'stun record without kernel freeze' }, operational_state: { runtime_status: 'running', containment: {
      process_freeze: 'requested', network_isolation: 'active', credential_revocation: 'active', source: 'sentinel-annotation', credential_source: 'registry',
    } } })
    expect(deriveAgentReview([partial]).issues.map(issue => issue.category)).toEqual(['containment-unconfirmed'])
    expect(deriveAgentReview([partial]).issues[0].severity).toBe('critical')
  })
  it('separates overlapping issues from unique affected agents with stable ordering and IDs', () => {
    const a = agent({ compliance_summary: { total_controls: 5, passing: 1, failing: 4, pending: 0, posture_score: 0.2 } })
    const b = agent({ id: 'b', lifecycle_state: 'stunned' })
    const review = deriveAgentReview([b, a, a])
    expect(review.affectedAgentCount).toBe(2)
    expect(review.issues.map(i => i.id)).toEqual(['a:failing-controls', 'a:critical-posture', 'b:containment-unconfirmed'])
    expect(deriveAgentReview([a, b]).issues).toEqual(review.issues)
    expect(needsAgentReview(a)).toBe(true)
  })

  it.each([0, 0.2, 20, 49.9])('accepts critical posture %s on either supported scale', score => {
    expect(deriveAgentReview([agent({ compliance_summary: { total_controls: 5, passing: 5, failing: 0, pending: 0, posture_score: score } })]).issues[0]?.category).toBe('critical-posture')
  })
  it.each([null, NaN, Infinity, -1, 101, 0.5, 1, 50, 100])('does not turn invalid or healthy posture %s into an issue', score => {
    expect(needsAgentReview(agent({ compliance_summary: { total_controls: 5, passing: 5, failing: 0, pending: 0, posture_score: score } }))).toBe(false)
  })

  it('requires stopped/requested containment or revoked credentials, not ordinary lifecycle labels', () => {
    const agents = [
      agent({ id: 'clean', lifecycle_state: 'Suspended' }),
      agent({ id: 'revoked', lifecycle_state: 'Revoked' }),
      agent({ id: 'enrolled', lifecycle_state: 'enrolled' }),
      agent({ id: 'stopped', operational_state: { runtime_status: 'Stopped', containment: { process_freeze: 'inactive', network_isolation: 'inactive', credential_revocation: 'inactive' } } }),
      agent({ id: 'credential', credential_state: { status: ' REVOKED ' } as unknown as AgentResponse['credential_state'] }),
      agent({ id: 'confirmed', lifecycle_state: 'STUNNED', kernel_state: 'frozen' }),
      agent({ id: 'network', lifecycle_state: 'stunned', kernel_telemetry: { cgroup_state: 'thawed', traffic_control_state: 'drop' } }),
    ]
    expect(deriveAgentReview(agents).issues.map(i => i.agentId)).toEqual(['credential', 'stopped'])
  })
  it('includes frozen-without-stun evidence and only its meaningful observation timestamp', () => {
    const review = deriveAgentReview([agent({ kernel_state: 'frozen', split_brain: ['kernel frozen without stun record'], kernel_observed_at: '2026-10-13T10:00:00Z' })])
    expect(review.issues[0]).toMatchObject({ category: 'kernel-split-brain', evidenceAt: '2026-10-13T10:00:00Z', detailTab: 'access' })
    expect(deriveAgentReview([agent({ lifecycle_state: 'stunned', created_at: '2026-01-01T00:00:00Z' })]).issues[0].evidenceAt).toBeUndefined()
  })
  it('distinguishes observed containment from unverified active claims', () => {
    const containment = { process_freeze: 'active' as const, network_isolation: 'inactive' as const, credential_revocation: 'active' as const }
    const stopped = { runtime_status: 'stopped', containment }
    expect(needsAgentReview(agent({ operational_state: stopped }))).toBe(true)
    expect(needsAgentReview(agent({ operational_state: { ...stopped, containment: { ...containment, source: 'sentinel-annotation' } } }))).toBe(false)
    const requested = agent({ operational_state: { runtime_status: 'running', containment: { ...containment, process_freeze: 'requested' } } })
    expect(deriveAgentReview([requested]).issues[0].category).toBe('containment-unconfirmed')
  })
})
