import { describe, it, expect, beforeEach, vi } from 'vitest'
import {
  derivePhase,
  getSuperCredState,
  recordObservation,
  recordScan,
  resetSuperCredState,
  subscribeSuperCredState,
} from './supercredState'
import type { SuperCredAgentObservation } from './supercredTypes'

function agent(overrides: Partial<SuperCredAgentObservation> = {}): SuperCredAgentObservation {
  return {
    id: 'agent-cardvault',
    name: 'Cardvault Agent',
    namespace: 'fe-signalloom-agents',
    supercred: true,
    state: null,
    phase: 'Running',
    ...overrides,
  }
}

beforeEach(() => {
  resetSuperCredState()
})

describe('derivePhase', () => {
  it('is absent with no agent — before step 1 and after step 5 teardown', () => {
    expect(derivePhase(null, null)).toBe('absent')
  })

  it('is deployed when the pod exists with no state label (step 1)', () => {
    expect(derivePhase(agent({ state: null }), null)).toBe('deployed')
    expect(derivePhase(agent({ state: '' }), null)).toBe('deployed')
  })

  it('is credentialed on signalloom.ai/state=active (step 2)', () => {
    expect(derivePhase(agent({ state: 'active' }), null)).toBe('credentialed')
  })

  it('is non-compliant on signalloom.ai/state=non-compliant (step 3, CLI path)', () => {
    expect(derivePhase(agent({ state: 'non-compliant' }), null)).toBe('non-compliant')
  })

  it('is non-compliant when a UI scan found failures but the pod is unlabelled (step 3, UI path)', () => {
    const scan = { evaluated_at: '2026-08-02T10:00:00Z', compliant: false, failed_checks: ['security-context-present'] }
    expect(derivePhase(agent({ state: 'active' }), scan)).toBe('non-compliant')
  })

  it('does not regress to non-compliant when the UI scan passed', () => {
    const scan = { evaluated_at: '2026-08-02T10:00:00Z', compliant: true, failed_checks: [] }
    expect(derivePhase(agent({ state: 'active' }), scan)).toBe('credentialed')
  })

  it('is stunned on signalloom.ai/state=stunned (step 4)', () => {
    expect(derivePhase(agent({ state: 'stunned', stunned_at: '2026-08-02T10:05:00Z' }), null)).toBe('stunned')
  })

  it('keeps stunned as terminal even when a scan observation is present', () => {
    const scan = { evaluated_at: '2026-08-02T10:00:00Z', compliant: false, failed_checks: ['security-context-present'] }
    expect(derivePhase(agent({ state: 'stunned' }), scan)).toBe('stunned')
  })

  it('ignores a stale scan once the agent is gone', () => {
    const scan = { evaluated_at: '2026-08-02T10:00:00Z', compliant: false, failed_checks: ['security-context-present'] }
    expect(derivePhase(null, scan)).toBe('absent')
  })

  it('treats an unrecognised state label as merely deployed rather than guessing', () => {
    expect(derivePhase(agent({ state: 'something-new' }), null)).toBe('deployed')
  })
})

describe('the state store', () => {
  it('starts absent', () => {
    expect(getSuperCredState().phase).toBe('absent')
    expect(getSuperCredState().agent).toBeNull()
  })

  it('advances through all five demo steps as observations arrive', () => {
    recordObservation(agent({ state: null }))
    expect(getSuperCredState().phase).toBe('deployed')

    recordObservation(agent({ state: 'active' }))
    expect(getSuperCredState().phase).toBe('credentialed')

    recordScan({ evaluated_at: '2026-08-02T10:00:00Z', compliant: false, failed_checks: ['security-context-present'] })
    expect(getSuperCredState().phase).toBe('non-compliant')

    recordObservation(agent({ state: 'stunned', stunned_at: '2026-08-02T10:05:00Z' }))
    expect(getSuperCredState().phase).toBe('stunned')

    // Step 5 — teardown removes the pod, so discovery returns nothing.
    recordObservation(null)
    expect(getSuperCredState().phase).toBe('absent')
  })

  it('clears the scan observation on teardown so a re-run starts clean', () => {
    recordObservation(agent({ state: 'active' }))
    recordScan({ evaluated_at: '2026-08-02T10:00:00Z', compliant: false, failed_checks: ['security-context-present'] })
    expect(getSuperCredState().phase).toBe('non-compliant')

    recordObservation(null)
    expect(getSuperCredState().scan).toBeNull()

    // A fresh step-1 deploy must not inherit the previous run's finding.
    recordObservation(agent({ state: null }))
    expect(getSuperCredState().phase).toBe('deployed')
  })

  it('stamps observedAt when an observation lands', () => {
    expect(getSuperCredState().observedAt).toBeNull()
    recordObservation(agent())
    expect(getSuperCredState().observedAt).not.toBeNull()
  })

  it('notifies subscribers when the phase changes', () => {
    const listener = vi.fn()
    subscribeSuperCredState(listener)

    recordObservation(agent({ state: null }))
    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener.mock.calls[0][0].phase).toBe('deployed')

    recordObservation(agent({ state: 'active' }))
    expect(listener).toHaveBeenCalledTimes(2)
  })

  it('does not notify when an observation leaves the phase unchanged', () => {
    recordObservation(agent({ state: 'active' }))
    const listener = vi.fn()
    subscribeSuperCredState(listener)

    recordObservation(agent({ state: 'active' }))
    expect(listener).not.toHaveBeenCalled()
  })

  it('stops notifying after unsubscribe', () => {
    const listener = vi.fn()
    const unsubscribe = subscribeSuperCredState(listener)
    unsubscribe()
    recordObservation(agent({ state: 'active' }))
    expect(listener).not.toHaveBeenCalled()
  })
})
