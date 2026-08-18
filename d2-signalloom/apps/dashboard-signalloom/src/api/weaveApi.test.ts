/**
 * Tests for the Signal Weave API client.
 *
 * Validates that weaveApi constructs the correct paths, that the demo-mode
 * resolver returns fixture data for every route via fakeData.ts's resolveFake,
 * and that live-mode calls go through client.ts's req().
 */
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { fakeWeaveData } from './fakeWeaveData'
import { resolveFake, hasFakeRoute } from './fakeData'

// ─── Live-mode endpoint tests ────────────────────────────────────────────────
// weaveApi now delegates to req() from client.ts. We mock the req export to
// verify the correct path + method + token reach it without hitting the network.

const mockReq = vi.fn().mockResolvedValue({})

vi.mock('./client', () => ({
  req: (...args: unknown[]) => mockReq(...args),
  api: {},
}))

describe('weaveApi live-mode endpoints', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('getObservations calls req with /signals/observations', async () => {
    const { weaveApi } = await import('./weaveApi')
    await weaveApi.getObservations('tok')
    expect(mockReq).toHaveBeenCalledWith('/signals/observations', 'tok')
  })

  it('getObservations appends layer and limit query params', async () => {
    const { weaveApi } = await import('./weaveApi')
    await weaveApi.getObservations('tok', { layer: 'network_egress', limit: 50 })
    const path = mockReq.mock.calls[0][0] as string
    expect(path).toContain('/signals/observations?')
    expect(path).toContain('layer=network_egress')
    expect(path).toContain('limit=50')
  })

  it('getActors calls req with /signals/actors', async () => {
    const { weaveApi } = await import('./weaveApi')
    await weaveApi.getActors('tok')
    expect(mockReq).toHaveBeenCalledWith('/signals/actors', 'tok')
  })

  it('getActor calls req with /signals/actors/:id', async () => {
    const { weaveApi } = await import('./weaveApi')
    await weaveApi.getActor('tok', 'actor-001')
    expect(mockReq).toHaveBeenCalledWith('/signals/actors/actor-001', 'tok')
  })

  it('getCoverage calls req with /signals/coverage', async () => {
    const { weaveApi } = await import('./weaveApi')
    await weaveApi.getCoverage('tok')
    expect(mockReq).toHaveBeenCalledWith('/signals/coverage', 'tok')
  })

  it('promoteActor calls req with POST /signals/actors/:id/promote', async () => {
    const { weaveApi } = await import('./weaveApi')
    await weaveApi.promoteActor('tok', 'actor-001')
    expect(mockReq).toHaveBeenCalledWith(
      '/signals/actors/actor-001/promote',
      'tok',
      { method: 'POST' },
    )
  })

  it('runCorrelation calls req with POST /signals/correlate', async () => {
    const { weaveApi } = await import('./weaveApi')
    await weaveApi.runCorrelation('tok')
    expect(mockReq).toHaveBeenCalledWith(
      '/signals/correlate',
      'tok',
      { method: 'POST' },
    )
  })

  it('seedFixtures calls req with POST /signals/collectors/seed', async () => {
    const { weaveApi } = await import('./weaveApi')
    await weaveApi.seedFixtures('tok')
    expect(mockReq).toHaveBeenCalledWith(
      '/signals/collectors/seed',
      'tok',
      { method: 'POST' },
    )
  })

  it('passes the token as second argument to req', async () => {
    const { weaveApi } = await import('./weaveApi')
    await weaveApi.getActors('my-secret-token')
    expect(mockReq.mock.calls[0][1]).toBe('my-secret-token')
  })
})

// ─── Demo-mode resolver tests ────────────────────────────────────────────────
// Weave routes are now registered in fakeData.ts's ROUTES array via the
// WEAVE_ROUTES export from fakeWeaveData.ts. These tests verify that
// resolveFake correctly resolves every weave route.

describe('weave routes in fakeData resolveFake', () => {
  it('resolves GET /signals/observations', () => {
    const result = resolveFake('GET', '/signals/observations')
    expect(result).toBeDefined()
    expect(Array.isArray(result)).toBe(true)
    const observations = result as unknown[]
    expect(observations.length).toBeGreaterThan(0)
  })

  it('resolves GET /signals/actors', () => {
    const result = resolveFake('GET', '/signals/actors')
    expect(result).toBeDefined()
    expect(Array.isArray(result)).toBe(true)
  })

  it('resolves GET /signals/actors/:id', () => {
    const result = resolveFake('GET', '/signals/actors/actor-shadow-llm-001')
    expect(result).toBeDefined()
    expect(typeof result).toBe('object')
  })

  it('resolves POST /signals/actors/:id/promote', () => {
    const result = resolveFake('POST', '/signals/actors/actor-shadow-llm-001/promote')
    expect(result).toEqual({ status: 'promoted' })
  })

  it('resolves GET /signals/coverage', () => {
    const result = resolveFake('GET', '/signals/coverage')
    expect(result).toBeDefined()
    const cov = result as { covered_layers: string[]; blind_spots: unknown[] }
    expect(cov.covered_layers).toContain('network_egress')
    expect(cov.blind_spots.length).toBeGreaterThan(0)
  })

  it('resolves POST /signals/correlate', () => {
    const result = resolveFake('POST', '/signals/correlate')
    expect(result).toEqual({ status: 'correlation_complete' })
  })

  it('resolves POST /signals/collectors/seed', () => {
    const result = resolveFake('POST', '/signals/collectors/seed')
    expect(result).toBeDefined()
    expect(typeof (result as { seeded: number }).seeded).toBe('number')
  })

  it('returns undefined for unknown signal routes', () => {
    const result = resolveFake('GET', '/signals/nonexistent')
    expect(result).toBeUndefined()
  })

  it('hasFakeRoute returns true for weave routes', () => {
    expect(hasFakeRoute('GET', '/signals/observations')).toBe(true)
    expect(hasFakeRoute('GET', '/signals/actors')).toBe(true)
    expect(hasFakeRoute('GET', '/signals/coverage')).toBe(true)
    expect(hasFakeRoute('POST', '/signals/correlate')).toBe(true)
    expect(hasFakeRoute('POST', '/signals/collectors/seed')).toBe(true)
  })

  it('strips /api prefix before matching', () => {
    const result = resolveFake('GET', '/api/signals/observations')
    expect(result).toBeDefined()
    expect(Array.isArray(result)).toBe(true)
  })

  it('strips query string before matching', () => {
    const result = resolveFake('GET', '/signals/observations?layer=network_egress&limit=10')
    expect(result).toBeDefined()
  })
})

describe('fakeWeaveData fixture integrity', () => {
  it('every observation has required fields', () => {
    for (const obs of fakeWeaveData.observations) {
      expect(obs.id).toBeTruthy()
      expect(obs.timestamp).toBeTruthy()
      expect(obs.layer).toBeTruthy()
      expect(obs.fidelity).toBeTruthy()
      expect(obs.source).toBeTruthy()
      expect(typeof obs.confidence).toBe('number')
      expect(obs.confidence).toBeGreaterThanOrEqual(0)
      expect(obs.confidence).toBeLessThanOrEqual(1)
      expect(obs.description).toBeTruthy()
      expect(obs.raw_evidence_ref).toBeTruthy()
    }
  })

  it('every actor has a non-empty evidence chain', () => {
    for (const actor of fakeWeaveData.actors) {
      expect(actor.id).toBeTruthy()
      expect(actor.evidence_chain.length).toBeGreaterThan(0)
      expect(typeof actor.confidence).toBe('number')
      expect(['provisional', 'actionable', 'promoted', 'dismissed']).toContain(actor.status)
    }
  })

  it('coverage statement lists at least one blind spot', () => {
    expect(fakeWeaveData.coverage.blind_spots.length).toBeGreaterThan(0)
    expect(fakeWeaveData.coverage.covered_layers.length).toBeGreaterThan(0)
  })

  it('closeable_by_issuance references valid blind spot IDs', () => {
    const ids = new Set(fakeWeaveData.coverage.blind_spots.map((b) => b.id))
    for (const ref of fakeWeaveData.coverage.closeable_by_issuance) {
      expect(ids.has(ref)).toBe(true)
    }
  })
})

describe('list responses are coerced to arrays', () => {
  // Regression for the crash reported from the deployed bundle:
  //   Uncaught TypeError: Cannot read properties of null (reading 'length')
  //   at WeavePage-Cv9_K1nn.js:1:6411
  // signal-ingest marshalled a nil slice as `null`, req<T[]> cast it without
  // checking, setObservations(null) landed in state, and WeavePage line 149
  // (`observations.length === 0 && actors.length === 0`) dereferenced it.
  it('getObservations returns [] when the service sends null', async () => {
    mockReq.mockResolvedValueOnce(null)
    const { weaveApi } = await import('./weaveApi')
    const result = await weaveApi.getObservations('tok')
    expect(Array.isArray(result)).toBe(true)
    expect(result).toEqual([])
    // The assertion that actually matters: the expression that crashed.
    expect(() => result.length === 0).not.toThrow()
  })

  it('getActors returns [] when the service sends null', async () => {
    mockReq.mockResolvedValueOnce(null)
    const { weaveApi } = await import('./weaveApi')
    const result = await weaveApi.getActors('tok')
    expect(result).toEqual([])
    expect(() => result.length === 0).not.toThrow()
  })

  it('getObservations passes a real list through unchanged', async () => {
    // Paired positive. Without it, a coercion that returned [] for EVERYTHING
    // would satisfy both tests above while silently emptying the page.
    const rows = [{ id: 'obs-1' }, { id: 'obs-2' }]
    mockReq.mockResolvedValueOnce(rows)
    const { weaveApi } = await import('./weaveApi')
    const result = await weaveApi.getObservations('tok')
    expect(result).toHaveLength(2)
    expect(result).toBe(rows)
  })
})
