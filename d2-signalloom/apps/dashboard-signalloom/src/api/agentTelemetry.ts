// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Live agent telemetry: the wire contract, its normaliser, and the stream loop.
 *
 * SLDC-P4-2. The producer is fe-signalloom's cAdvisor poller (SLDC-P4-1), which
 * was NOT on the integration branch when this was written, so the contract
 * below is the consumer's side of it and is deliberately tolerant: it accepts
 * the snake_case names Appendix D.2 uses and the camelCase names the card
 * uses, and it rejects anything it cannot read rather than guessing.
 *
 *   GET /api/telemetry/agents/{podName}   one pod, `text/event-stream`
 *   GET /api/telemetry/agents             every monitored pod, same framing
 *
 *   event: telemetry            (or no event line; SSE's default `message`)
 *   data: {"pod_name":"kusari-agent-0","namespace":"tenant-kusari",
 *          "ts":"2026-09-30T10:00:02Z","cpu_millicores":1.2,
 *          "memory_rss_bytes":44040192,"frozen":false}
 *
 *   : keepalive                 comment; never reaches React state
 *
 * WHY `frozen` IS REQUIRED FOR "STUNNED", AND CPU == 0 IS NOT ENOUGH.
 * SLDC-P4-PRE measured cAdvisor's own refresh cadence on kind-osramp at
 * p50 ~15 s (10-30 s). A 2 s rate window over a counter that has not been
 * re-sampled reads Δcpu = 0 on a perfectly healthy agent. Treating 0.000 as
 * proof of freeze would paint an idle agent STUNNED several times a minute -
 * a fabricated containment claim, the exact class of defect Fix-D forbade for
 * SVID expiry. So the containment badge keys on the sentinel's cgroup state
 * (`frozen: true` or `cgroup_state: "frozen"`), and a bare zero renders as an
 * honest "no CPU delta".
 *
 * P4-1 AS LANDED (557749f9) emits `millicores`, `memory_rss_mb`, `status` and
 * `last_updated`, all read below - EXCEPT `status: "FROZEN"`, which P4-1
 * derives from `millicores == 0.0` (every pod's first sample included). That
 * is the false zero above under another name, so it is deliberately not a
 * freeze signal. Its per-pod route streams bare `data:` frames; its estate
 * route answers JSON only, which streamTelemetry reports as `snapshot` so the
 * hook polls it instead of reconnecting forever.
 *
 * WHY fetch AND NOT EventSource. EventSource cannot set a request header, so
 * authenticating it means a bearer token in the query string - into access
 * logs, proxy logs and history. demoRunner.ts records the same decision; its
 * frame parser is reused here rather than copied.
 */
import { parseSseFrames } from './demoRunner'

/** One normalised telemetry point for one pod. */
export interface TelemetrySample {
  podName: string
  namespace?: string
  /** Epoch milliseconds. */
  ts: number
  /** CPU in millicores, never negative, never NaN. */
  cpuMillicores: number
  /** Resident set size in MiB; `null` when the producer did not send one. */
  memoryRssMiB: number | null
  /** True only on an explicit cgroup freeze signal from the producer. */
  frozen: boolean
}

export type AgentRunState = 'frozen' | 'terminated' | 'active' | 'idle'

/** Below this a CPU reading is the rate calculation's noise floor (D.2). */
export const CPU_ZERO_EPSILON = 0.0001

const MIB = 1024 * 1024

function num(v: unknown): number | null {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v)
    return Number.isFinite(n) ? n : null
  }
  return null
}

function pick(o: Record<string, unknown>, ...keys: string[]): unknown {
  for (const k of keys) if (o[k] !== undefined && o[k] !== null) return o[k]
  return undefined
}

function parseTs(v: unknown, fallback: number): number {
  const n = num(v)
  if (n !== null) return n < 1e12 ? n * 1000 : n // epoch seconds or millis
  if (typeof v === 'string') {
    const t = Date.parse(v)
    if (Number.isFinite(t)) return t
  }
  return fallback
}

/**
 * Read one wire payload into a TelemetrySample, or `null` if it is not one.
 *
 * `null` for a payload with no pod name or no CPU reading: a sample that has
 * to be guessed at is worse than a gap in the sparkline.
 */
export function normalizeSample(raw: unknown, now: number = Date.now()): TelemetrySample | null {
  if (!raw || typeof raw !== 'object') return null
  const o = raw as Record<string, unknown>

  const podName = pick(o, 'pod_name', 'podName', 'pod')
  if (typeof podName !== 'string' || podName === '') return null

  const cpu = num(pick(o, 'cpu_millicores', 'cpuMillicores', 'millicores', 'cpu_mcpu', 'mcpu'))
  if (cpu === null) return null

  let memoryRssMiB: number | null = null
  const mib = num(pick(o, 'memory_rss_mib', 'memoryRssMiB', 'memory_rss_mb', 'memoryRssMB', 'MemoryRssMB'))
  if (mib !== null) memoryRssMiB = Math.max(0, mib)
  else {
    const bytes = num(pick(o, 'memory_rss_bytes', 'memoryRssBytes', 'container_memory_rss'))
    if (bytes !== null) memoryRssMiB = Math.max(0, bytes / MIB)
  }

  const cgroupState = pick(o, 'cgroup_state', 'cgroupState', 'state')
  const frozen = o.frozen === true || cgroupState === 'frozen'

  const namespace = pick(o, 'namespace', 'ns')
  return {
    podName,
    namespace: typeof namespace === 'string' ? namespace : undefined,
    ts: parseTs(pick(o, 'ts', 'timestamp', 'last_updated', 'lastUpdated', 'time'), now),
    // A negative rate is a counter reset (container restart), not negative
    // work. Clamp to zero rather than draw below the axis.
    cpuMillicores: Math.max(0, cpu),
    memoryRssMiB,
    frozen,
  }
}

/**
 * Classify a sample. Freeze wins only on the explicit signal; RSS at zero is
 * termination (memory gone), which a freeze by definition never is.
 */
export function runStateOf(s: TelemetrySample): AgentRunState {
  if (s.frozen) return 'frozen'
  if (s.memoryRssMiB !== null && s.memoryRssMiB <= 0) return 'terminated'
  if (s.cpuMillicores >= CPU_ZERO_EPSILON) return 'active'
  return 'idle'
}

/**
 * Exactly three decimals, always. Frozen, or under the noise floor, is the
 * literal `0.000 mCPU` - never `0 mCPU`, never `0.0001 mCPU`.
 */
export function formatMillicores(cpu: number, frozen = false): string {
  if (frozen || !Number.isFinite(cpu) || cpu < CPU_ZERO_EPSILON) return '0.000 mCPU'
  return `${cpu.toFixed(3)} mCPU`
}

export function formatMiB(mib: number | null): string {
  if (mib === null || !Number.isFinite(mib)) return 'RSS unknown'
  return `${mib.toFixed(1)} MiB`
}

export type UtilisationBand = 'normal' | 'elevated' | 'critical'

/** Card bands: < 20 normal, 20-80 elevated, > 80 critical. */
export function utilisationBand(cpu: number): UtilisationBand {
  if (cpu > 80) return 'critical'
  if (cpu >= 20) return 'elevated'
  return 'normal'
}

export const TELEMETRY_BASE = '/api/telemetry/agents'

export function agentTelemetryUrl(podName: string): string {
  return `${TELEMETRY_BASE}/${encodeURIComponent(podName)}`
}

export interface TelemetryStreamOptions {
  url: string
  token?: string
  signal?: AbortSignal
  fetchImpl?: typeof fetch
  /** First byte (data or keepalive) arrived: the connection is live. */
  onOpen?: () => void
  onSample: (sample: TelemetrySample) => void
}

/**
 * The records inside one payload, whatever envelope the producer used: a bare
 * record, an array, `{"agents":[...]}`, or P4-1's estate map keyed by pod.
 */
export function payloadItems(payload: unknown): unknown[] {
  if (Array.isArray(payload)) return payload
  if (!payload || typeof payload !== 'object') return [payload]
  const o = payload as Record<string, unknown>
  if (Array.isArray(o.agents)) return o.agents
  if (normalizeSample(o) !== null) return [o]
  const values = Object.values(o)
  if (values.length > 0 && values.every((v) => v !== null && typeof v === 'object' && !Array.isArray(v))) return values
  return [payload]
}

/** How one stream attempt ended, when it ended without an error. */
export type StreamEnd = 'ended' | 'snapshot'

/**
 * Hold one SSE connection open until it ends, errors, or is aborted.
 *
 * Resolves `ended` when the server closes the stream, or `snapshot` when the
 * endpoint answered JSON instead of an event stream (its records are still
 * delivered): the caller should poll that endpoint, not reconnect to it.
 * Rejects on HTTP failure or a transport error. Reconnection is the caller's
 * job - this is one attempt. Keepalive comments produce no frame
 * (parseSseFrames drops them), so they never reach `onSample` or a render.
 */
export async function streamTelemetry(opts: TelemetryStreamOptions): Promise<StreamEnd> {
  const doFetch = opts.fetchImpl ?? fetch
  const res = await doFetch(opts.url, {
    headers: {
      Accept: 'text/event-stream',
      ...(opts.token ? { Authorization: `Bearer ${opts.token}` } : {}),
    },
    signal: opts.signal,
  })
  if (!res.ok) throw new Error(`telemetry stream HTTP ${res.status}`)

  const contentType = res.headers.get('content-type') ?? ''
  if (contentType.includes('application/json')) {
    opts.onOpen?.()
    for (const item of payloadItems(await res.json())) {
      const s = normalizeSample(item)
      if (s) opts.onSample(s)
    }
    return 'snapshot'
  }
  if (!res.body) throw new Error('telemetry stream carried no body')

  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  let opened = false
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) return 'ended'
      if (!opened) {
        opened = true
        opts.onOpen?.()
      }
      buffer += decoder.decode(value, { stream: true })
      const parsed = parseSseFrames(buffer)
      buffer = parsed.rest
      for (const frame of parsed.frames) {
        if (frame.event !== 'telemetry' && frame.event !== 'message') continue
        let payload: unknown
        try {
          payload = JSON.parse(frame.data)
        } catch {
          continue // one malformed frame is not a dead stream
        }
        for (const item of payloadItems(payload)) {
          const s = normalizeSample(item)
          if (s) opts.onSample(s)
        }
      }
    }
  } finally {
    void reader.cancel().catch(() => {})
  }
}

/** One JSON snapshot, for the polling fallback. Same payload shapes. */
export async function fetchTelemetrySnapshot(
  url: string,
  token?: string,
  fetchImpl: typeof fetch = fetch,
  signal?: AbortSignal,
): Promise<TelemetrySample[]> {
  const res = await fetchImpl(url, {
    headers: {
      Accept: 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    signal,
  })
  if (!res.ok) throw new Error(`telemetry snapshot HTTP ${res.status}`)
  return payloadItems(await res.json())
    .map((i) => normalizeSample(i))
    .filter((s): s is TelemetrySample => s !== null)
}
