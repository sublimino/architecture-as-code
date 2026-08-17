/**
 * Tests for useSignalSummary — the cross-page signal data hook.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { clearSignalSummaryCache, useSignalSummary } from './useSignalSummary'
import { fakeWeaveData } from '../api/fakeWeaveData'
import type { SignalObservation, ProvisionalActor } from '../api/weaveApi'

// ── Mocks ────────────────────────────────────────────────────────────────────

const { getAccessTokenSilently, mockWeaveApi } = vi.hoisted(() => ({
  getAccessTokenSilently: vi.fn().mockResolvedValue('test-token'),
  mockWeaveApi: {
    getObservations: vi.fn(),
    getActors: vi.fn(),
    getCoverage: vi.fn(),
    getActor: vi.fn(),
    promoteActor: vi.fn(),
    runCorrelation: vi.fn(),
  },
}))

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

vi.mock('../api/weaveApi', () => ({
  weaveApi: mockWeaveApi,
}))

// ── Helpers ─────────────────────────────────────────────────────────────────

function waitForLoaded(result: { current: { loading: boolean } }) {
  return waitFor(() => expect(result.current.loading).toBe(false))
}

// ── Tests ───────────────────────────────────────────────────────────────────

describe('useSignalSummary', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
  })

  it('returns loading state initially', () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)

    const { result } = renderHook(() => useSignalSummary())
    expect(result.current.loading).toBe(true)
    expect(result.current.totalObservations).toBe(0)
  })

  it('fetches observations and actors and computes summary', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)

    const { result } = renderHook(() => useSignalSummary())
    await waitForLoaded(result)

    expect(result.current.totalObservations).toBe(fakeWeaveData.observations.length)
    expect(result.current.totalActors).toBe(fakeWeaveData.actors.length)
    expect(result.current.error).toBeNull()
    expect(result.current.loading).toBe(false)
  })

  it('computes observations by layer', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)

    const { result } = renderHook(() => useSignalSummary())
    await waitForLoaded(result)

    // Fixture has 2 network_egress observations
    expect(result.current.observationsByLayer.network_egress).toBe(2)
    // Fixture has 2 identity_authorization observations
    expect(result.current.observationsByLayer.identity_authorization).toBe(2)
    // Fixture has 2 behavioural observations
    expect(result.current.observationsByLayer.behavioural).toBe(2)
  })

  it('computes actors by status', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)

    const { result } = renderHook(() => useSignalSummary())
    await waitForLoaded(result)

    expect(result.current.actorsByStatus.actionable).toBe(1)
    expect(result.current.actorsByStatus.provisional).toBe(1)
    expect(result.current.actorsByStatus.promoted).toBe(1)
  })

  it('determines the highest fidelity from observations', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)

    const { result } = renderHook(() => useSignalSummary())
    await waitForLoaded(result)

    // Fixture has a definitive observation (obs-id-001)
    expect(result.current.highestFidelity).toBe('definitive')
  })

  it('counts unique layers', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)

    const { result } = renderHook(() => useSignalSummary())
    await waitForLoaded(result)

    // Fixture covers 5 layers
    expect(result.current.layerCount).toBe(5)
  })

  it('handles API error gracefully — returns zeros and error message', async () => {
    mockWeaveApi.getObservations.mockRejectedValue(new Error('Service unavailable'))
    mockWeaveApi.getActors.mockRejectedValue(new Error('Service unavailable'))

    const { result } = renderHook(() => useSignalSummary())
    await waitForLoaded(result)

    expect(result.current.totalObservations).toBe(0)
    expect(result.current.totalActors).toBe(0)
    expect(result.current.highestFidelity).toBeNull()
    expect(result.current.error).toBe('Service unavailable')
    expect(result.current.loading).toBe(false)
  })

  it('handles empty data without errors', async () => {
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])

    const { result } = renderHook(() => useSignalSummary())
    await waitForLoaded(result)

    expect(result.current.totalObservations).toBe(0)
    expect(result.current.totalActors).toBe(0)
    expect(result.current.highestFidelity).toBeNull()
    expect(result.current.layerCount).toBe(0)
    expect(result.current.error).toBeNull()
  })

  it('caches results across multiple hook instances', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)

    const { result: r1 } = renderHook(() => useSignalSummary())
    await waitForLoaded(r1)

    // Second render should use cache, not re-fetch
    const { result: r2 } = renderHook(() => useSignalSummary())
    expect(r2.current.loading).toBe(false)
    expect(r2.current.totalObservations).toBe(fakeWeaveData.observations.length)

    // Only one round of API calls
    expect(mockWeaveApi.getObservations).toHaveBeenCalledTimes(1)
    expect(mockWeaveApi.getActors).toHaveBeenCalledTimes(1)
  })
})
