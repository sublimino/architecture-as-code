import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'

const demoModeMock = { on: true, production: false }

vi.mock('./demoMode', () => ({
  get isProductionEnv() { return demoModeMock.production },
  isDemoMode: () => demoModeMock.on,
  showDemoToggle: true,
}))

import {
  ensureSuperCredState,
  getSimulatedPhase,
  invalidateSuperCredState,
  isSuperCredEnabled,
  recordScanResult,
  resetSuperCredSource,
  setSimulatedPhase,
} from './supercredSource'
import { getSuperCredState, resetSuperCredState } from './supercredState'
import { installMemoryStorage } from '../test-utils/memoryStorage'

beforeEach(() => {
  demoModeMock.on = true
  demoModeMock.production = false
  installMemoryStorage()
  resetSuperCredState()
  resetSuperCredSource()
  vi.restoreAllMocks()
})

afterEach(() => {
  resetSuperCredSource()
})

describe('demo-data mode — the simulated cluster', () => {
  it('starts with the demo not running', async () => {
    const state = await ensureSuperCredState()
    expect(state.phase).toBe('absent')
    expect(state.agent).toBeNull()
  })

  it('walks all five steps and returns to a clean state', async () => {
    setSimulatedPhase('deployed')
    expect((await ensureSuperCredState()).phase).toBe('deployed')

    setSimulatedPhase('credentialed')
    expect((await ensureSuperCredState()).phase).toBe('credentialed')

    setSimulatedPhase('non-compliant')
    expect((await ensureSuperCredState()).phase).toBe('non-compliant')

    setSimulatedPhase('stunned')
    const stunned = await ensureSuperCredState()
    expect(stunned.phase).toBe('stunned')
    expect(stunned.agent?.stunned_at).toBeTruthy()

    // Step 5 teardown.
    setSimulatedPhase('absent')
    const after = await ensureSuperCredState()
    expect(after.phase).toBe('absent')
    expect(after.agent).toBeNull()
  })

  it('produces the same state labels the demo script writes onto the pod', async () => {
    setSimulatedPhase('credentialed')
    expect((await ensureSuperCredState()).agent?.state).toBe('active')

    setSimulatedPhase('non-compliant')
    expect((await ensureSuperCredState()).agent?.state).toBe('non-compliant')

    setSimulatedPhase('stunned')
    expect((await ensureSuperCredState()).agent?.state).toBe('stunned')
  })

  it('persists the simulated phase so a page reload keeps the demo where it was', () => {
    const storage = installMemoryStorage()
    resetSuperCredSource()
    setSimulatedPhase('non-compliant')
    expect(getSimulatedPhase()).toBe('non-compliant')
    expect(storage.getItem('sl_supercred_demo_phase')).toBe('non-compliant')
  })

  it('still advances when localStorage is unavailable', () => {
    // Node's experimental Web Storage global is inert and shadows jsdom's, so
    // the simulated demo must not depend on storage working.
    Object.defineProperty(globalThis, 'localStorage', {
      value: {
        getItem() { throw new Error('unavailable') },
        setItem() { throw new Error('unavailable') },
        removeItem() { throw new Error('unavailable') },
      },
      writable: true,
      configurable: true,
    })

    setSimulatedPhase('stunned')
    expect(getSimulatedPhase()).toBe('stunned')
    expect(getSuperCredState().phase).toBe('stunned')
  })

  it('never calls the network in demo-data mode', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
    setSimulatedPhase('credentialed')
    await ensureSuperCredState()
    expect(fetchSpy).not.toHaveBeenCalled()
  })
})

describe('live mode — observing the cluster through the proxy', () => {
  beforeEach(() => {
    demoModeMock.on = false
  })

  function mockDiscovery(agents: unknown[]) {
    return vi.spyOn(globalThis, 'fetch').mockResolvedValue({
      ok: true,
      json: async () => ({ agents }),
    } as Response)
  }

  it('picks the SuperCred-labelled agent out of discovery', async () => {
    mockDiscovery([
      { id: 'other-agent', name: 'Other', supercred: false, state: 'active' },
      { id: 'agent-cardvault', name: 'Cardvault Agent', supercred: true, state: 'active' },
    ])
    const state = await ensureSuperCredState()
    expect(state.phase).toBe('credentialed')
    expect(state.agent?.id).toBe('agent-cardvault')
  })

  it('reports the demo as not running when no agent carries the label', async () => {
    mockDiscovery([{ id: 'other-agent', supercred: false }])
    expect((await ensureSuperCredState()).phase).toBe('absent')
  })

  it('derives the stunned phase from the pod label the proxy reports', async () => {
    mockDiscovery([
      { id: 'agent-cardvault', name: 'Cardvault Agent', supercred: true, state: 'stunned', stunned_at: '2026-08-02T10:05:00Z' },
    ])
    expect((await ensureSuperCredState()).phase).toBe('stunned')
  })

  it('fails open when there is no SuperCred proxy at all', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('ECONNREFUSED'))
    const state = await ensureSuperCredState()
    expect(state.phase).toBe('absent')
  })

  it('fails open on a non-OK response', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue({ ok: false, status: 502 } as Response)
    expect((await ensureSuperCredState()).phase).toBe('absent')
  })

  it('clears a previously observed agent when the proxy goes away', async () => {
    mockDiscovery([{ id: 'agent-cardvault', supercred: true, state: 'active', name: 'Cardvault Agent' }])
    expect((await ensureSuperCredState()).phase).toBe('credentialed')

    invalidateSuperCredState()
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('ECONNREFUSED'))
    expect((await ensureSuperCredState()).phase).toBe('absent')
  })

  it('caches within the TTL so one page render does not fan out into many calls', async () => {
    const spy = mockDiscovery([{ id: 'agent-cardvault', supercred: true, state: 'active', name: 'Cardvault Agent' }])
    await ensureSuperCredState()
    await ensureSuperCredState()
    await ensureSuperCredState()
    expect(spy).toHaveBeenCalledTimes(1)
  })

  it('coalesces concurrent refreshes into a single in-flight request', async () => {
    const spy = mockDiscovery([{ id: 'agent-cardvault', supercred: true, state: 'active', name: 'Cardvault Agent' }])
    await Promise.all([ensureSuperCredState(), ensureSuperCredState(), ensureSuperCredState()])
    expect(spy).toHaveBeenCalledTimes(1)
  })

  it('re-observes after an invalidation', async () => {
    const spy = mockDiscovery([{ id: 'agent-cardvault', supercred: true, state: 'active', name: 'Cardvault Agent' }])
    await ensureSuperCredState()
    invalidateSuperCredState()
    await ensureSuperCredState()
    expect(spy).toHaveBeenCalledTimes(2)
  })

  it('does not let the simulated phase leak into live mode', async () => {
    demoModeMock.on = true
    setSimulatedPhase('stunned')
    demoModeMock.on = false
    invalidateSuperCredState()

    mockDiscovery([])
    expect((await ensureSuperCredState()).phase).toBe('absent')
  })
})

describe('production gating', () => {
  it('is disabled in uat and prod', async () => {
    demoModeMock.production = true
    expect(isSuperCredEnabled()).toBe(false)

    const fetchSpy = vi.spyOn(globalThis, 'fetch')
    const state = await ensureSuperCredState()
    expect(state.phase).toBe('absent')
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('is enabled in demo and dev', () => {
    demoModeMock.production = false
    expect(isSuperCredEnabled()).toBe(true)
  })
})

describe('recordScanResult — the UI-driven step 3', () => {
  it('advances an active agent to non-compliant when checks fail', async () => {
    setSimulatedPhase('credentialed')
    await ensureSuperCredState()

    recordScanResult({
      agent_id: 'agent-cardvault',
      compliant: false,
      evaluated_at: '2026-08-02T10:00:00Z',
      results: [
        { check: 'security-context-present', pass: false, reason: 'securityContext not set' },
        { check: 'run-as-non-root', pass: false, reason: 'runAsNonRoot not set' },
        { check: 'drop-capabilities', pass: true, reason: 'capabilities dropped' },
      ],
    })

    expect(getSuperCredState().phase).toBe('non-compliant')
    expect(getSuperCredState().scan?.failed_checks).toEqual([
      'security-context-present',
      'run-as-non-root',
    ])
  })

  it('leaves a compliant agent where it was', async () => {
    setSimulatedPhase('credentialed')
    await ensureSuperCredState()

    recordScanResult({
      agent_id: 'agent-cardvault',
      compliant: true,
      evaluated_at: '2026-08-02T10:00:00Z',
      results: [{ check: 'security-context-present', pass: true, reason: 'ok' }],
    })

    expect(getSuperCredState().phase).toBe('credentialed')
  })

  it('tolerates a response with no results array', async () => {
    setSimulatedPhase('credentialed')
    await ensureSuperCredState()
    expect(() =>
      recordScanResult({
        agent_id: 'agent-cardvault',
        compliant: false,
        evaluated_at: '2026-08-02T10:00:00Z',
        results: undefined as never,
      }),
    ).not.toThrow()
  })
})
