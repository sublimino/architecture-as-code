import { describe, it, expect } from 'vitest'
import {
  SUPERCRED_CONTROLS,
  SUPERCRED_TOTAL_WEIGHT,
  STUN_CONTAINMENT_RESIDUAL,
  controlStatus,
  evaluatedControls,
  postureScore,
  carriedGbp,
  complianceTally,
} from './supercredControls'
import type { SuperCredPhase } from './supercredTypes'

const PHASES: SuperCredPhase[] = ['absent', 'deployed', 'credentialed', 'non-compliant', 'stunned']

describe('SUPERCRED_CONTROLS', () => {
  it('defines twelve controls with unique ids', () => {
    expect(SUPERCRED_CONTROLS).toHaveLength(12)
    const ids = new Set(SUPERCRED_CONTROLS.map((c) => c.id))
    expect(ids.size).toBe(12)
  })

  it('lands every control in one of the two demo frameworks', () => {
    for (const c of SUPERCRED_CONTROLS) {
      expect(['EU AI Act', 'NIST 800-53']).toContain(c.framework)
    }
  })

  it('reuses existing control sets so the customer sees their own structure move', () => {
    const sets = new Set(SUPERCRED_CONTROLS.map((c) => c.controlSet))
    expect(sets).toContain('Identification & Auth')
    expect(sets).toContain('System & Comms Protection')
    expect(sets).toContain('Human Oversight')
  })

  it('has exactly the three real policy-engine checks in the runtime group', () => {
    const runtime = SUPERCRED_CONTROLS.filter((c) => c.group === 'runtime')
    expect(runtime.map((c) => c.id).sort()).toEqual([
      'drop-capabilities',
      'run-as-non-root',
      'security-context-present',
    ])
  })

  it('totals the severity weights used by the posture score', () => {
    expect(SUPERCRED_TOTAL_WEIGHT).toBe(37)
  })
})

describe('controlStatus', () => {
  it('leaves every control pending before the agent is deployed', () => {
    for (const c of SUPERCRED_CONTROLS) {
      expect(controlStatus(c, 'absent')).toBe('pending')
    }
  })

  it('passes governance controls once the agent is deployed (step 1)', () => {
    const gov = SUPERCRED_CONTROLS.filter((c) => c.group === 'governance')
    for (const c of gov) expect(controlStatus(c, 'deployed')).toBe('pass')
    const others = SUPERCRED_CONTROLS.filter((c) => c.group !== 'governance')
    for (const c of others) expect(controlStatus(c, 'deployed')).toBe('pending')
  })

  it('passes identity controls once the credential chain runs (step 2)', () => {
    const identity = SUPERCRED_CONTROLS.filter((c) => c.group === 'identity')
    for (const c of identity) expect(controlStatus(c, 'credentialed')).toBe('pass')
  })

  it('fails the three runtime checks once the scan finds the missing securityContext (step 3)', () => {
    const runtime = SUPERCRED_CONTROLS.filter((c) => c.group === 'runtime')
    for (const c of runtime) {
      expect(controlStatus(c, 'credentialed')).toBe('pending')
      expect(controlStatus(c, 'non-compliant')).toBe('fail')
      expect(controlStatus(c, 'stunned')).toBe('fail')
    }
  })

  it('passes the response controls only once the stun proves them (step 4)', () => {
    const response = SUPERCRED_CONTROLS.filter((c) => c.group === 'response')
    for (const c of response) {
      expect(controlStatus(c, 'non-compliant')).toBe('pending')
      expect(controlStatus(c, 'stunned')).toBe('pass')
    }
  })
})

describe('evaluatedControls', () => {
  it('surfaces only controls that have actually been evaluated', () => {
    expect(evaluatedControls('absent')).toHaveLength(0)
    expect(evaluatedControls('deployed')).toHaveLength(3)
    expect(evaluatedControls('credentialed')).toHaveLength(7)
    expect(evaluatedControls('non-compliant')).toHaveLength(10)
    expect(evaluatedControls('stunned')).toHaveLength(12)
  })

  it('never returns a pending control', () => {
    for (const phase of PHASES) {
      for (const c of evaluatedControls(phase)) {
        expect(controlStatus(c, phase)).not.toBe('pending')
      }
    }
  })
})

describe('complianceTally', () => {
  it('walks passing and failing counts across the five steps', () => {
    expect(complianceTally('absent')).toEqual({ passing: 0, failing: 0, pending: 12, total: 12 })
    expect(complianceTally('deployed')).toEqual({ passing: 3, failing: 0, pending: 9, total: 12 })
    expect(complianceTally('credentialed')).toEqual({ passing: 7, failing: 0, pending: 5, total: 12 })
    expect(complianceTally('non-compliant')).toEqual({ passing: 7, failing: 3, pending: 2, total: 12 })
    expect(complianceTally('stunned')).toEqual({ passing: 9, failing: 3, pending: 0, total: 12 })
  })
})

describe('postureScore', () => {
  it('is null until the agent has been exercised', () => {
    expect(postureScore('absent')).toBeNull()
    expect(postureScore('deployed')).toBeNull()
  })

  it('drops when the scan lands and recovers when the platform contains it', () => {
    const credentialed = postureScore('credentialed')
    const nonCompliant = postureScore('non-compliant')
    const stunned = postureScore('stunned')

    expect(credentialed).not.toBeNull()
    expect(nonCompliant).not.toBeNull()
    expect(stunned).not.toBeNull()

    // Step 3 must visibly worsen posture; step 4 must visibly improve it.
    expect(nonCompliant!).toBeLessThan(credentialed!)
    expect(stunned!).toBeGreaterThan(nonCompliant!)
  })

  it('crosses from the warning band into the critical band on the scan', () => {
    // Compliance.tsx categorises <50 as critical, 50-79 warning, >=80 good.
    expect(postureScore('credentialed')!).toBeGreaterThanOrEqual(50)
    expect(postureScore('non-compliant')!).toBeLessThan(50)
    expect(postureScore('stunned')!).toBeGreaterThanOrEqual(50)
  })
})

describe('carriedGbp', () => {
  it('carries nothing while no control is failing', () => {
    expect(carriedGbp('absent')).toBe(0)
    expect(carriedGbp('deployed')).toBe(0)
    expect(carriedGbp('credentialed')).toBe(0)
  })

  it('carries the full ALE of the three failing runtime checks at step 3', () => {
    const runtimeAle = SUPERCRED_CONTROLS
      .filter((c) => c.group === 'runtime')
      .reduce((s, c) => s + c.ale, 0)
    expect(carriedGbp('non-compliant')).toBe(runtimeAle)
  })

  it('reduces carried risk to the documented residual once the agent is stunned', () => {
    const exposed = carriedGbp('non-compliant')
    const contained = carriedGbp('stunned')
    expect(contained).toBeLessThan(exposed)
    expect(contained).toBe(Math.round(exposed * STUN_CONTAINMENT_RESIDUAL))
  })

  it('keeps the residual non-zero — revocation removes capability, not the defect', () => {
    expect(carriedGbp('stunned')).toBeGreaterThan(0)
  })
})
