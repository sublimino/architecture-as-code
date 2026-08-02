import { describe, it, expect } from 'vitest'
import { projectAudit, superCredAuditEvents } from './supercredAudit'
import { SUPERCRED_AGENT_ID } from './supercredProjection'
import type { SuperCredDemoState, SuperCredPhase } from './supercredTypes'
import type { AuditListResponse } from '../types/api'

/** The event types AuditTrail.tsx already knows how to filter and colour. */
const KNOWN_EVENT_TYPES = [
  'enrollment', 'state_transition', 'violation_detected', 'compliance_check',
  'token_issued', 'token_refused', 'tenant_created', 'user_provisioned',
  'directory_connected', 'discovery_enroll_requested',
]

function stateAt(phase: SuperCredPhase, enteredAt: Partial<Record<SuperCredPhase, string>> = {}): SuperCredDemoState {
  return {
    phase,
    agent: phase === 'absent' ? null : {
      id: 'agent-cardvault',
      name: 'Cardvault Agent',
      namespace: 'fe-signalloom-agents',
      supercred: true,
      supercred_target: 'cardvault',
      state: phase === 'stunned' ? 'stunned' : null,
      stunned_at: phase === 'stunned' ? '2026-08-02T10:05:00Z' : null,
      stun_reason: phase === 'stunned' ? 'compliance-failure: securityContext not set' : null,
    },
    scan: null,
    observedAt: '2026-08-02T10:00:00Z',
    enteredAt,
  }
}

const baseAudit: AuditListResponse = {
  events: [
    { id: 'tenant-demo:evt-1', timestamp: '2026-07-27T12:00:00Z', event_type: 'agent.registered', agent_id: 'a1', agent_name: 'Inventory Agent', actor: 'demo-user', detail: {} },
  ],
  total: 1,
  page: 1,
  limit: 25,
}

describe('superCredAuditEvents', () => {
  it('emits nothing before the demo starts', () => {
    expect(superCredAuditEvents(stateAt('absent'))).toHaveLength(0)
  })

  it('accumulates one entry per step, and three for the stun', () => {
    expect(superCredAuditEvents(stateAt('deployed'))).toHaveLength(1)
    expect(superCredAuditEvents(stateAt('credentialed'))).toHaveLength(2)
    expect(superCredAuditEvents(stateAt('non-compliant'))).toHaveLength(3)
    expect(superCredAuditEvents(stateAt('stunned'))).toHaveLength(6)
  })

  it('only uses event types the Audit Trail page can filter and colour', () => {
    for (const e of superCredAuditEvents(stateAt('stunned'))) {
      expect(KNOWN_EVENT_TYPES).toContain(e.event_type)
    }
  })

  it('records the step-4 stun as a violation, a state change and a credential denial', () => {
    const types = superCredAuditEvents(stateAt('stunned')).map((e) => e.event_type)
    expect(types).toContain('violation_detected')
    expect(types).toContain('state_transition')
    expect(types).toContain('token_refused')
  })

  it('attributes every event to the SuperCred agent', () => {
    for (const e of superCredAuditEvents(stateAt('stunned'))) {
      expect(e.agent_id).toBe(SUPERCRED_AGENT_ID)
      expect(e.agent_name).toBe('Cardvault Agent')
    }
  })

  it('names the failing checks on the step-3 compliance event', () => {
    const scanEvent = superCredAuditEvents(stateAt('non-compliant'))
      .find((e) => e.event_type === 'compliance_check')!
    expect(scanEvent.detail.failed_checks).toEqual([
      'security-context-present', 'run-as-non-root', 'drop-capabilities',
    ])
  })

  it('prefers the checks an actual UI scan reported over the default set', () => {
    const state = stateAt('non-compliant')
    state.scan = { evaluated_at: '2026-08-02T10:00:00Z', compliant: false, failed_checks: ['run-as-non-root'] }
    const scanEvent = superCredAuditEvents(state).find((e) => e.event_type === 'compliance_check')!
    expect(scanEvent.detail.failed_checks).toEqual(['run-as-non-root'])
  })

  it('orders newest first, matching the baseline fixture', () => {
    const types = superCredAuditEvents(stateAt('stunned')).map((e) => e.event_type)
    expect(types[types.length - 1]).toBe('enrollment')
    expect(types[0]).toBe('token_refused')
  })

  it('uses the observed transition time when the dashboard saw it happen', () => {
    const state = stateAt('stunned', { deployed: '2026-08-02T09:00:00Z' })
    const enrollment = superCredAuditEvents(state).find((e) => e.event_type === 'enrollment')!
    expect(enrollment.timestamp).toBe('2026-08-02T09:00:00Z')
  })

  it("falls back to the cluster's own stun annotation rather than inventing a time", () => {
    const stun = superCredAuditEvents(stateAt('stunned'))
      .find((e) => e.event_type === 'state_transition')!
    expect(stun.timestamp).toBe('2026-08-02T10:05:00Z')
  })

  it('gives every event a stable, namespaced id', () => {
    const ids = superCredAuditEvents(stateAt('stunned')).map((e) => e.id)
    expect(new Set(ids).size).toBe(ids.length)
    for (const id of ids) expect(id.startsWith('supercred:')).toBe(true)
  })

  it('emits identical events for identical state — safe to poll', () => {
    const state = stateAt('stunned', { deployed: '2026-08-02T09:00:00Z' })
    expect(superCredAuditEvents(state)).toEqual(superCredAuditEvents(state))
  })
})

describe('projectAudit', () => {
  it('leaves the page untouched before the demo starts', () => {
    expect(projectAudit(baseAudit, stateAt('absent'))).toEqual(baseAudit)
  })

  it('puts the demo events above the existing trail and keeps the existing ones', () => {
    const result = projectAudit(baseAudit, stateAt('stunned'))
    expect(result.events).toHaveLength(7)
    expect(result.events[0].event_type).toBe('token_refused')
    expect(result.events[result.events.length - 1].id).toBe('tenant-demo:evt-1')
  })

  it('raises the total the page reports', () => {
    expect(projectAudit(baseAudit, stateAt('non-compliant')).total).toBe(4)
  })

  it('does not accumulate across repeated polls', () => {
    const once = projectAudit(baseAudit, stateAt('stunned'))
    const twice = projectAudit(once, stateAt('stunned'))
    expect(twice.events).toHaveLength(once.events.length)
    expect(twice.total).toBe(once.total)
  })

  it('never mutates the response it was handed', () => {
    const input: AuditListResponse = { ...baseAudit, events: [...baseAudit.events] }
    projectAudit(input, stateAt('stunned'))
    expect(input.events).toHaveLength(1)
    expect(input.total).toBe(1)
  })

  it('step 5 teardown: the demo events disappear with the agent', () => {
    const during = projectAudit(baseAudit, stateAt('stunned'))
    expect(during.events.length).toBeGreaterThan(1)
    const after = projectAudit(baseAudit, stateAt('absent'))
    expect(after.events).toHaveLength(1)
  })

  it('tolerates a malformed response', () => {
    expect(() => projectAudit(null as never, stateAt('stunned'))).not.toThrow()
    expect(() => projectAudit({ total: 0 } as never, stateAt('stunned'))).not.toThrow()
  })
})
