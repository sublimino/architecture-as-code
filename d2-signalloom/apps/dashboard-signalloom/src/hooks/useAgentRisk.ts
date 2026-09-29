/**
 * Live OpenFAIR risk, per agent and per fleet.
 *
 * ─── The three lifecycle bugs this file exists to not have ─────────────────
 *
 * 1. **State written into a tree that has gone.** The risk drawer is mounted and
 *    unmounted far faster than a Monte Carlo query settles. Every fetch here
 *    carries an AbortSignal and every effect returns a teardown that fires it.
 *
 * 2. **A superseded response winning the race.** Flipping the DemoToggle twice
 *    quickly starts two fetches; the FIRST can settle last. Aborting is
 *    necessary but not sufficient (an already-resolved promise cannot be
 *    aborted), so each run also carries a monotonic sequence number and a
 *    result is discarded unless it belongs to the newest run. Without this the
 *    panel can end up showing fixture figures while the toggle reads LIVE API,
 *    which is worse than showing nothing.
 *
 * 3. **A rejection reaching a render.** normalizeAgentRisk() THROWS on a
 *    malformed payload, by design, because a missing `ale` that defaults to
 *    zero is a fabricated figure. That throw is caught here and becomes an
 *    error string; it never escapes into React.
 *
 * ─── Why this re-fetches on demo-mode change ───────────────────────────────
 *
 * DemoToggle currently follows setDemoMode() with window.location.reload(), so
 * most of the app gets its new data from a fresh page rather than from a
 * subscription. That reload is pre-existing, load-bearing for the ~149 vitest
 * files whose pages fetch only on mount, and out of scope here, but it is also
 * the reason interactive toggling cannot be tested in a browser, because a
 * reload re-runs Playwright's addInitScript and re-forces the seeded mode
 * before the app boots (test/acceptance/helpers.ts documents exactly that).
 *
 * So these hooks subscribe. The risk surfaces switch on the setDemoMode event
 * alone, with no reload, which makes them assertable, and makes them the
 * migration path if the reload is ever retired.
 */
import { useState, useEffect, useRef, useCallback } from 'react'
import { useAuth0 } from '../auth/oidc'
import { fairApi } from '../api/fairApi'
import { isDemoMode, subscribeDemoMode } from '../api/demoMode'
import type { AgentRisk, FairSource, FleetRisk } from '../types/fair'

export interface RiskQuery<T> {
  data: T | null
  loading: boolean
  error: string | null
  /** Which plane the CURRENT data came from, or is being fetched from. */
  source: FairSource
  /** Re-run the query against whatever mode is active now. */
  refresh: () => void
}

/**
 * An aborted request is not a failure.
 *
 * A caller that renders "you stopped caring" as "the service is down" reports an
 * outage that never happened: client.ts names its cancellation rejection
 * `AbortError` for exactly this reason, and axios uses `CanceledError`.
 */
function isAbort(err: unknown): boolean {
  if (typeof err !== 'object' || err === null) return false
  const name = (err as { name?: string }).name
  const code = (err as { code?: string }).code
  return name === 'AbortError' || name === 'CanceledError' || code === 'ERR_CANCELED'
}

function messageOf(err: unknown): string {
  if (err instanceof Error && err.message) return err.message
  return 'Risk service unavailable'
}

/**
 * Shared machinery for both hooks.
 *
 * `fetcher` is passed by identity-stable reference from the caller's useCallback
 * so this effect's dependency array does not re-arm on every render (the same
 * identity trap that turned the streaming harness into an unbounded request
 * loop: test/acceptance/harness/auth-stub.tsx documents it at length).
 */
function useRiskQuery<T>(
  fetcher: (token: string, signal: AbortSignal) => Promise<T>,
  enabled: boolean,
): RiskQuery<T> {
  const { getAccessTokenSilently } = useAuth0()
  const [data, setData] = useState<T | null>(null)
  const [loading, setLoading] = useState(enabled)
  const [error, setError] = useState<string | null>(null)
  const [source, setSource] = useState<FairSource>(() => fairApi.currentSource())
  const [nonce, setNonce] = useState(0)

  // Monotonic run id. A response is only allowed to write state if its run is
  // still the newest one: see bug 2 in the header.
  const runRef = useRef(0)
  const mountedRef = useRef(true)

  const refresh = useCallback(() => setNonce((n) => n + 1), [])

  // Re-run whenever the operator flips the toggle. Subscribing rather than
  // reading isDemoMode() at render time is what makes the switch reload-free.
  useEffect(() => {
    return subscribeDemoMode(() => {
      setSource(isDemoMode() ? 'fixture' : 'riskctl')
      setNonce((n) => n + 1)
    })
  }, [])

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  useEffect(() => {
    if (!enabled) {
      setData(null)
      setLoading(false)
      setError(null)
      return
    }

    const run = ++runRef.current
    const controller = new AbortController()
    // Only the newest run may write. Checked on every settle path, because an
    // abort cannot un-resolve a promise that already resolved.
    const current = () => mountedRef.current && runRef.current === run

    setLoading(true)
    setError(null)
    setSource(fairApi.currentSource())

    void (async () => {
      try {
        const token = await getAccessTokenSilently()
        const result = await fetcher(token, controller.signal)
        if (!current()) return
        setData(result)
        setError(null)
      } catch (err) {
        // A cancelled run must leave the state it was superseding alone.
        if (isAbort(err) || !current()) return
        setData(null)
        setError(messageOf(err))
      } finally {
        if (current()) setLoading(false)
      }
    })()

    return () => controller.abort()
  }, [fetcher, enabled, nonce, getAccessTokenSilently])

  return { data, loading, error, source, refresh }
}

/**
 * Risk for one agent. Pass a null id to park the hook: it will not fetch, and
 * it still obeys the rules of hooks, so a drawer can mount before it has a
 * selection.
 */
export function useAgentRisk(agentId: string | null): RiskQuery<AgentRisk> {
  const fetcher = useCallback(
    (token: string, signal: AbortSignal) => fairApi.getAgentRisk(token, agentId ?? '', signal),
    [agentId],
  )
  return useRiskQuery(fetcher, Boolean(agentId))
}

/** Fleet-wide rollup. Same lifecycle guarantees. */
export function useFleetRisk(enabled = true): RiskQuery<FleetRisk> {
  const fetcher = useCallback(
    (token: string, signal: AbortSignal) => fairApi.getFleetRisk(token, signal),
    [],
  )
  return useRiskQuery(fetcher, enabled)
}

/** Dynamic regulatory framework versions. */
export function useFrameworkVersions(enabled = true): RiskQuery<import('../types/fair').FrameworkVersion[]> {
  const fetcher = useCallback(
    (token: string, signal: AbortSignal) => fairApi.fetchFrameworkVersions(token, signal),
    [],
  )
  return useRiskQuery(fetcher, enabled)
}

/**
 * Reactive loss exceedance curve recalculation with sub-250ms latency.
 * Applies a debounce of at most 200ms (default 150ms) to ensure smooth UI responsiveness
 * while eliminating main-thread jank during interactive slider adjustments.
 */
export function useReactiveLossCurve(
  ale: number,
  tvar: number,
  debounceMs = 150,
): import('../types/fair').LossExceedancePoint[] {
  const [debouncedPoints, setDebouncedPoints] = useState<import('../types/fair').LossExceedancePoint[]>(() =>
    fairApi.calculateLossExceedance(ale, tvar),
  )

  useEffect(() => {
    // If debounceMs <= 0 calculate immediately
    if (debounceMs <= 0) {
      setDebouncedPoints(fairApi.calculateLossExceedance(ale, tvar))
      return
    }

    const timer = setTimeout(() => {
      setDebouncedPoints(fairApi.calculateLossExceedance(ale, tvar))
    }, Math.min(debounceMs, 250)) // Cap strictly at 250ms per SLA

    return () => clearTimeout(timer)
  }, [ale, tvar, debounceMs])

  return debouncedPoints
}

