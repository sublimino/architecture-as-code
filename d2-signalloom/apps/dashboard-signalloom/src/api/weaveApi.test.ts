/**
 * Tests for the Signal Weave API client.
 *
 * Validates that weaveApi constructs the correct paths and that the demo-mode
 * resolver returns fixture data for every route.
 */
import { describe, expect, it } from 'vitest'
import { fakeWeaveData } from './fakeWeaveData'

describe('fakeWeaveData.resolve', () => {
  it('resolves GET /signals/observations', () => {
    const result = fakeWeaveData.resolve('GET', '/signals/observations')
    expect(result).toBeDefined()
    expect(Array.isArray(result)).toBe(true)
    const observations = result as unknown[]
    expect(observations.length).toBeGreaterThan(0)
  })

  it('resolves GET /signals/actors', () => {
    const result = fakeWeaveData.resolve('GET', '/signals/actors')
    expect(result).toBeDefined()
    expect(Array.isArray(result)).toBe(true)
  })

  it('resolves GET /signals/actors/:id', () => {
    const result = fakeWeaveData.resolve('GET', '/signals/actors/actor-shadow-llm-001')
    expect(result).toBeDefined()
    expect(typeof result).toBe('object')
  })

  it('resolves POST /signals/actors/:id/promote', () => {
    const result = fakeWeaveData.resolve('POST', '/signals/actors/actor-shadow-llm-001/promote')
    expect(result).toEqual({ status: 'promoted' })
  })

  it('resolves GET /signals/coverage', () => {
    const result = fakeWeaveData.resolve('GET', '/signals/coverage')
    expect(result).toBeDefined()
    const cov = result as { covered_layers: string[]; blind_spots: unknown[] }
    expect(cov.covered_layers).toContain('network_egress')
    expect(cov.blind_spots.length).toBeGreaterThan(0)
  })

  it('resolves POST /signals/correlate', () => {
    const result = fakeWeaveData.resolve('POST', '/signals/correlate')
    expect(result).toEqual({ status: 'correlation_complete' })
  })

  it('returns undefined for unknown routes', () => {
    const result = fakeWeaveData.resolve('GET', '/signals/nonexistent')
    expect(result).toBeUndefined()
  })

  it('strips /api prefix before matching', () => {
    const result = fakeWeaveData.resolve('GET', '/api/signals/observations')
    expect(result).toBeDefined()
    expect(Array.isArray(result)).toBe(true)
  })

  it('strips query string before matching', () => {
    const result = fakeWeaveData.resolve('GET', '/signals/observations?layer=network_egress&limit=10')
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
