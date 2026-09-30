// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * useAgentTelemetry / useEstateTelemetry - live cAdvisor telemetry (SLDC-P4-2).
 *
 * Connection lifecycle, shared by both hooks:
 *
 *   connecting ─open─▶ live ─drop─▶ reconnecting ─(backoff)─▶ connecting
 *        │                                  │
 *        └──── N consecutive failures ──────┴─▶ polling (HTTP snapshot)
 *
 * A drop during a freeze is the documented failure mode that leaves a stale
 * 45.2 mCPU on screen while the pod is frozen. Two defences: reconnect with
 * exponential backoff and then fall back to polling, and mark the reading
 * `stale` once nothing has arrived for `staleAfterMs`, so an old non-zero is
 * never presented as current.
 *
 * Render budget: keepalive comments never reach state (see streamTelemetry),
 * and the per-pod window is capped at `windowSize` points so a long session
 * cannot grow the DOM or the heap.
 */
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useAuth0 } from '../auth/oidc'
import {
  TELEMETRY_BASE,
  agentTelemetryUrl,
  fetchTelemetrySnapshot,
  runStateOf,
  streamTelemetry,
  type TelemetrySample,
} from '../api/agentTelemetry'

export type TelemetryConnection = 'connecting' | 'live' | 'reconnecting' | 'polling' | 'error'

export interface TelemetryHookOptions {
  /** Rolling window length: 15 samples = 30 s at the 2 s resolution. */
  windowSize?: number
  initialBackoffMs?: number
  maxBackoffMs?: number
  /** Consecutive failed stream attempts before switching to polling. */
  maxStreamFailures?: number
  pollIntervalMs?: number
  /** No sample for this long and the latest reading is flagged stale. */
  staleAfterMs?: number
  fetchImpl?: typeof fetch
  getToken?: () => Promise<string>
}

const DEFAULTS = {
  windowSize: 15,
  initialBackoffMs: 1000,
  maxBackoffMs: 30_000,
  maxStreamFailures: 3,
  pollIntervalMs: 2000,
  staleAfterMs: 10_000,
}

/** Delay before reconnect attempt `failures` (1-based): 1s, 2s, 4s … capped. */
export function backoffDelay(failures: number, initialMs: number, maxMs: number): number {
  return Math.min(maxMs, initialMs * 2 ** Math.max(0, failures - 1))
}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted) return resolve()
    const t = setTimeout(resolve, ms)
    signal.addEventListener('abort', () => { clearTimeout(t); resolve() }, { once: true })
  })
}

/**
 * The one connection loop. Calls `onSample` for every sample; owns status.
 * `url === null` means "nothing to subscribe to" and holds no connection.
 */
function useTelemetryConnection(
  url: string | null,
  onSample: (s: TelemetrySample) => void,
  options: TelemetryHookOptions,
): TelemetryConnection {
  const { getAccessTokenSilently } = useAuth0()
  const [status, setStatus] = useState<TelemetryConnection>('connecting')

  // Refs, not deps: a new token getter or handler identity must not tear down
  // a healthy stream.
  const onSampleRef = useRef(onSample)
  onSampleRef.current = onSample
  const getTokenRef = useRef(options.getToken ?? getAccessTokenSilently)
  getTokenRef.current = options.getToken ?? getAccessTokenSilently
  const fetchImpl = options.fetchImpl
  const initialBackoffMs = options.initialBackoffMs ?? DEFAULTS.initialBackoffMs
  const maxBackoffMs = options.maxBackoffMs ?? DEFAULTS.maxBackoffMs
  const maxStreamFailures = options.maxStreamFailures ?? DEFAULTS.maxStreamFailures
  const pollIntervalMs = options.pollIntervalMs ?? DEFAULTS.pollIntervalMs

  useEffect(() => {
    if (url === null) return
    const controller = new AbortController()
    const { signal } = controller
    const token = async (): Promise<string | undefined> => {
      try {
        return (await getTokenRef.current()) || undefined
      } catch {
        return undefined
      }
    }

    void (async () => {
      let failures = 0
      setStatus('connecting')
      while (!signal.aborted && failures < maxStreamFailures) {
        let opened = false
        try {
          await streamTelemetry({
            url,
            token: await token(),
            signal,
            fetchImpl,
            onOpen: () => {
              opened = true
              failures = 0
              setStatus('live')
            },
            onSample: (s) => onSampleRef.current(s),
          })
        } catch {
          // fall through to reconnect bookkeeping
        }
        if (signal.aborted) return
        // A stream that opened and then ended is a drop, not a failure to
        // connect: it does not count towards the polling threshold.
        if (!opened) failures += 1
        setStatus('reconnecting')
        await sleep(backoffDelay(Math.max(1, failures), initialBackoffMs, maxBackoffMs), signal)
      }
      if (signal.aborted) return

      setStatus('polling')
      while (!signal.aborted) {
        try {
          const samples = await fetchTelemetrySnapshot(url, await token(), fetchImpl ?? fetch, signal)
          for (const s of samples) onSampleRef.current(s)
          setStatus('polling')
        } catch {
          if (signal.aborted) return
          setStatus('error')
        }
        await sleep(pollIntervalMs, signal)
      }
    })()

    return () => controller.abort()
  }, [url, fetchImpl, initialBackoffMs, maxBackoffMs, maxStreamFailures, pollIntervalMs])

  return status
}

/** Flags the latest reading stale when nothing new arrives in time. */
function useStaleFlag(lastSampleAt: number | null, staleAfterMs: number): boolean {
  const [stale, setStale] = useState(false)
  useEffect(() => {
    if (lastSampleAt === null) return
    setStale(false)
    const t = setTimeout(() => setStale(true), staleAfterMs)
    return () => clearTimeout(t)
  }, [lastSampleAt, staleAfterMs])
  return stale
}

export interface AgentTelemetry {
  /** Oldest first, at most `windowSize` long. */
  samples: TelemetrySample[]
  latest: TelemetrySample | null
  connection: TelemetryConnection
  stale: boolean
}

/** Append and cap; exported for the window-cap test. */
export function appendWindow(prev: TelemetrySample[], s: TelemetrySample, size: number): TelemetrySample[] {
  const next = prev.length >= size ? prev.slice(prev.length - size + 1) : prev.slice()
  next.push(s)
  return next
}

export function useAgentTelemetry(podName: string | null, options: TelemetryHookOptions = {}): AgentTelemetry {
  const windowSize = options.windowSize ?? DEFAULTS.windowSize
  const [samples, setSamples] = useState<TelemetrySample[]>([])
  const [lastSampleAt, setLastSampleAt] = useState<number | null>(null)

  // A new pod is a new window; never splice two agents into one sparkline.
  useEffect(() => {
    setSamples([])
    setLastSampleAt(null)
  }, [podName])

  const onSample = useCallback(
    (s: TelemetrySample) => {
      if (s.podName !== podName) return
      setSamples((prev) => appendWindow(prev, s, windowSize))
      setLastSampleAt(Date.now())
    },
    [podName, windowSize],
  )

  const connection = useTelemetryConnection(podName ? agentTelemetryUrl(podName) : null, onSample, options)
  const stale = useStaleFlag(lastSampleAt, options.staleAfterMs ?? DEFAULTS.staleAfterMs)

  return {
    samples,
    latest: samples.length > 0 ? samples[samples.length - 1] : null,
    connection,
    stale,
  }
}

export interface EstateSummary {
  total: number
  active: number
  stunned: number
  /** Sum across every monitored pod, in millicores; frozen pods add 0. */
  totalCpuMillicores: number
}

export function summariseEstate(latest: Iterable<TelemetrySample>): EstateSummary {
  const summary: EstateSummary = { total: 0, active: 0, stunned: 0, totalCpuMillicores: 0 }
  for (const s of latest) {
    summary.total += 1
    const state = runStateOf(s)
    if (state === 'frozen') summary.stunned += 1
    else if (state === 'active' || state === 'idle') summary.active += 1
    if (state !== 'frozen') summary.totalCpuMillicores += s.cpuMillicores
  }
  return summary
}

export interface EstateTelemetry {
  /** Latest sample per pod, keyed `namespace/pod`. */
  pods: TelemetrySample[]
  summary: EstateSummary | null
  connection: TelemetryConnection
}

export function useEstateTelemetry(options: TelemetryHookOptions = {}): EstateTelemetry {
  const [byPod, setByPod] = useState<ReadonlyMap<string, TelemetrySample>>(new Map())
  const onSample = useCallback((s: TelemetrySample) => {
    setByPod((prev) => {
      const key = `${s.namespace ?? ''}/${s.podName}`
      const next = new Map(prev)
      next.set(key, s)
      return next
    })
  }, [])
  const connection = useTelemetryConnection(TELEMETRY_BASE, onSample, options)
  const pods = useMemo(() => [...byPod.values()], [byPod])
  const summary = useMemo(() => (pods.length > 0 ? summariseEstate(pods) : null), [pods])
  return { pods, summary, connection }
}
