import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'

const demoModeMock = { on: true, production: false }

vi.mock('./demoMode', () => ({
  get isProductionEnv() { return demoModeMock.production },
  isDemoMode: () => demoModeMock.on,
  showDemoToggle: true,
}))

import {
  discoverSuperCredAgents,
  ensureSuperCredState,
  getSimulatedPhase,
  invalidateSuperCredState,
  isSuperCredEnabled,
  recordScanResult,
  resetSuperCredSource,
  scanSuperCredAgent,
  setSimulatedPhase,
  recordStunResult,
} from './supercredSource'
import { simulatedAgentIdentity } from './supercredTypes'
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

// ─── Demo actions, in both modes ─────────────────────────────────────────────

describe('discoverSuperCredAgents', () => {
  it('serves the simulated cluster in demo-data mode, with no network call', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
    setSimulatedPhase('credentialed')

    const result = await discoverSuperCredAgents()
    expect(fetchSpy).not.toHaveBeenCalled()
    expect(result.agents).toHaveLength(1)
    expect(result.agents[0].state).toBe('active')
    expect(getSuperCredState().phase).toBe('credentialed')
  })

  it('returns nothing at all before step 1 in demo-data mode', async () => {
    const result = await discoverSuperCredAgents()
    expect(result.agents).toHaveLength(0)
  })

  it('queries the proxy in live mode and records the observation', async () => {
    demoModeMock.on = false
    vi.spyOn(globalThis, 'fetch').mockResolvedValue({
      ok: true,
      json: async () => ({
        agents: [
          { id: 'other', supercred: false },
          { id: 'agent-cardvault', name: 'Cardvault Agent', supercred: true, state: 'stunned' },
        ],
        namespaces: ['fe-signalloom-agents'],
      }),
    } as Response)

    const result = await discoverSuperCredAgents()
    // The page shows every discovered agent; only the labelled one drives state.
    expect(result.agents).toHaveLength(2)
    expect(result.namespaces).toEqual(['fe-signalloom-agents'])
    expect(getSuperCredState().phase).toBe('stunned')
  })

  it('surfaces a partial discovery rather than silently reporting short', async () => {
    demoModeMock.on = false
    vi.spyOn(globalThis, 'fetch').mockResolvedValue({
      ok: true,
      json: async () => ({ agents: [], namespaces: [], namespace_errors: { 'fe-signalloom': 'forbidden' } }),
    } as Response)

    const result = await discoverSuperCredAgents()
    expect(result.error).toBe('Partial discovery failure — fe-signalloom: forbidden')
  })

  it('throws in live mode when the proxy is unreachable, so the page can show it', async () => {
    demoModeMock.on = false
    vi.spyOn(globalThis, 'fetch').mockResolvedValue({ ok: false, status: 503 } as Response)
    await expect(discoverSuperCredAgents()).rejects.toThrow(/503/)
  })
})

describe('scanSuperCredAgent', () => {
  it('reports the three real policy-engine findings in demo-data mode', async () => {
    setSimulatedPhase('credentialed')
    await discoverSuperCredAgents()

    const result = await scanSuperCredAgent('/unused', 'agent-cardvault')
    expect(result.compliant).toBe(false)
    expect(result.results.map((r) => r.check)).toEqual([
      'security-context-present', 'run-as-non-root', 'drop-capabilities',
    ])
    // The finding must reach the main pages, not just this page.
    expect(getSuperCredState().phase).toBe('non-compliant')
  })

  it('records a live scan result so step 3 moves the main pages', async () => {
    demoModeMock.on = false
    vi.spyOn(globalThis, 'fetch').mockResolvedValue({
      ok: true,
      json: async () => ({
        agents: [{ id: 'agent-cardvault', name: 'Cardvault Agent', supercred: true, state: 'active' }],
        namespaces: [],
      }),
    } as Response)
    await discoverSuperCredAgents()
    expect(getSuperCredState().phase).toBe('credentialed')

    vi.spyOn(globalThis, 'fetch').mockResolvedValue({
      ok: true,
      json: async () => ({
        agent_id: 'agent-cardvault',
        compliant: false,
        evaluated_at: '2026-08-02T10:00:00Z',
        results: [{ check: 'security-context-present', pass: false, reason: 'not set' }],
      }),
    } as Response)

    await scanSuperCredAgent('/supercred-api/agents/agent-cardvault/compliance', 'agent-cardvault')
    expect(getSuperCredState().phase).toBe('non-compliant')
  })
})

describe('recordStunResult', () => {
  it('advances the simulated cluster to stunned in demo-data mode', async () => {
    setSimulatedPhase('non-compliant')
    await discoverSuperCredAgents()

    recordStunResult()
    expect(getSuperCredState().phase).toBe('stunned')
    expect(getSimulatedPhase()).toBe('stunned')
  })

  // The regression this pins is a double stun, not a missing one. This module
  // used to POST /supercred-api/agents/{id}/stun itself; that call now belongs
  // to POST /api/agents/{id}/stun, which makes it server-side. A browser-side
  // copy would relabel the pod and revoke the lease a second time, and the
  // symptom — an agent that ends up stunned — looks exactly like success.
  it('issues no request of its own, so the pod is not stunned twice', () => {
    demoModeMock.on = false
    const fetchSpy = vi.spyOn(globalThis, 'fetch')

    recordStunResult()

    expect(fetchSpy).not.toHaveBeenCalled()
  })
})

describe('simulatedAgentIdentity', () => {
  it('reports what the proxy would have told the endpoint about the pod', () => {
    expect(simulatedAgentIdentity('agent-cardvault')).toEqual({
      name: 'Cardvault Agent',
      namespace: 'fe-signalloom-agents',
    })
  })

  it('returns null for a pod the simulated cluster does not hold', () => {
    // Falling back to the raw pod name is honest; inventing a friendly name for
    // a workload nothing has observed would put a fiction on the audit trail.
    expect(simulatedAgentIdentity('agent-unknown')).toBeNull()
  })
})
