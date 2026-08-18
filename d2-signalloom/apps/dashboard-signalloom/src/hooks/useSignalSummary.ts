/**
 * useSignalSummary — fetches and caches signal observation + actor data for
 * the session. Used by pages that show cross-cutting signal indicators
 * without being the Signal Weave page itself.
 *
 * Graceful degradation: if signal-ingest is down, returns zeros and a null
 * highestFidelity so the host page still renders without an error state.
 */
import { useState, useEffect, useRef } from 'react'
import { useAuth0 } from '../auth/oidc'
import { weaveApi } from '../api/weaveApi'
import type {
  SignalObservation,
  ProvisionalActor,
  SignalLayer,
  FidelityTier,
  CoverageStatement,
} from '../api/weaveApi'

// ─── Types ──────────────────────────────────────────────────────────────────

export interface SignalSummary {
  totalObservations: number
  totalActors: number
  actorsByStatus: Record<string, number>
  observationsByLayer: Partial<Record<SignalLayer, number>>
  /**
   * Observation count per fidelity tier.
   *
   * `highestFidelity` is a maximum, and a maximum hides its own distribution:
   * one definitive observation among seven circumstantial ones reports the same
   * tier as seven definitive ones. Consumers that price the evidence rather
   * than just badge it need the spread.
   */
  observationsByFidelity: Partial<Record<FidelityTier, number>>
  highestFidelity: FidelityTier | null
  layerCount: number
  /**
   * The service's own coverage statement — which layers have a collector
   * deployed and which are blind spots.
   *
   * Null when signal-ingest does not answer for it. Coverage degrades
   * INDEPENDENTLY of observations and actors: it is supplementary to data that
   * is itself supplementary, so a coverage failure must not blank a section
   * that has perfectly good observations to show.
   */
  coverage: CoverageStatement | null
  observations: SignalObservation[]
  actors: ProvisionalActor[]
  loading: boolean
  error: string | null
}

// ─── Fidelity Ordering ──────────────────────────────────────────────────────

const FIDELITY_RANK: Record<FidelityTier, number> = {
  definitive: 4,
  strong: 3,
  suggestive: 2,
  circumstantial: 1,
}

function highestFidelity(observations: SignalObservation[]): FidelityTier | null {
  if (observations.length === 0) return null
  let best: FidelityTier = observations[0].fidelity
  for (const obs of observations) {
    if (FIDELITY_RANK[obs.fidelity] > FIDELITY_RANK[best]) {
      best = obs.fidelity
    }
  }
  return best
}

// ─── Session Cache ──────────────────────────────────────────────────────────

// Module-level cache so multiple components mounting in the same session
// don't re-fetch. Cleared on page reload (which is the intended granularity).
let cachedSummary: SignalSummary | null = null
let fetchPromise: Promise<void> | null = null

export function clearSignalSummaryCache() {
  cachedSummary = null
  fetchPromise = null
}

// ─── Hook ───────────────────────────────────────────────────────────────────

const EMPTY: SignalSummary = {
  totalObservations: 0,
  totalActors: 0,
  actorsByStatus: {},
  observationsByLayer: {},
  observationsByFidelity: {},
  highestFidelity: null,
  layerCount: 0,
  coverage: null,
  observations: [],
  actors: [],
  loading: true,
  error: null,
}

export function useSignalSummary(): SignalSummary {
  const { getAccessTokenSilently } = useAuth0()
  const [summary, setSummary] = useState<SignalSummary>(cachedSummary ?? EMPTY)
  const mounted = useRef(true)

  useEffect(() => {
    mounted.current = true

    // Already cached — serve immediately
    if (cachedSummary) {
      setSummary(cachedSummary)
      return
    }

    // Deduplicate concurrent mounts
    if (!fetchPromise) {
      fetchPromise = (async () => {
        try {
          const token = await getAccessTokenSilently()

          // Coverage is fetched alongside but NOT inside the Promise.all: it is
          // allowed to fail on its own without taking observations and actors
          // down with it. `Promise.resolve().then()` rather than a bare call so
          // a synchronous throw lands in the catch too.
          const coveragePromise = Promise.resolve()
            .then(() => weaveApi.getCoverage(token))
            .catch(() => null)

          const [observations, actors] = await Promise.all([
            weaveApi.getObservations(token),
            weaveApi.getActors(token),
          ])
          const coverage = (await coveragePromise) ?? null

          const observationsByLayer: Partial<Record<SignalLayer, number>> = {}
          for (const obs of observations) {
            observationsByLayer[obs.layer] = (observationsByLayer[obs.layer] ?? 0) + 1
          }

          const observationsByFidelity: Partial<Record<FidelityTier, number>> = {}
          for (const obs of observations) {
            observationsByFidelity[obs.fidelity] = (observationsByFidelity[obs.fidelity] ?? 0) + 1
          }

          const actorsByStatus: Record<string, number> = {}
          for (const actor of actors) {
            actorsByStatus[actor.status] = (actorsByStatus[actor.status] ?? 0) + 1
          }

          const layers = new Set(observations.map((o) => o.layer))

          cachedSummary = {
            totalObservations: observations.length,
            totalActors: actors.length,
            actorsByStatus,
            observationsByLayer,
            observationsByFidelity,
            highestFidelity: highestFidelity(observations),
            layerCount: layers.size,
            coverage,
            observations,
            actors,
            loading: false,
            error: null,
          }
        } catch (err) {
          // Graceful degradation — signal data is supplementary
          cachedSummary = {
            ...EMPTY,
            loading: false,
            error: err instanceof Error ? err.message : 'Signal data unavailable',
          }
        }
      })()
    }

    fetchPromise.then(() => {
      if (mounted.current && cachedSummary) {
        setSummary(cachedSummary)
      }
    })

    return () => {
      mounted.current = false
    }
  }, [getAccessTokenSilently])

  return summary
}
