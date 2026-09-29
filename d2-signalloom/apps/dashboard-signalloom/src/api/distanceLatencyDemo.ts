/**
 * Client for the Distance Latency demo runner API.
 *
 * The Distance Latency demo has four acts:
 *   1. Spatial Topology Discovery (intra-cluster vs cross-domain distance matrix)
 *   2. eBPF Kernel Probes (sub-microsecond socket/packet latency measurement)
 *   3. FrostDB Columnar Telemetry Stream (31-column Arrow vector ingestion & CEL evaluation)
 *   4. Quarantine Cascade (distance-weighted stun and isolation enforcement)
 *
 * Routes through /demo-api/distancelatency/ (proxied by nginx to the demo-runner pod).
 */
import type { DemoStep, DemoRunView, DemoRunLogChunk, DemoRunnerStatus } from './demoRunner'

export type { DemoStep, DemoRunView, DemoRunLogChunk, DemoRunnerStatus }

const DL_DEMO_API = '/demo-api/distancelatency'

export function shellCommandForAct(stepId: string): string {
  return `./scripts/distancelatency-demo.sh ${stepId}`
}

function authHeaders(token?: string): HeadersInit | undefined {
  return token ? { Authorization: `Bearer ${token}` } : undefined
}

async function describeFailure(res: Response): Promise<string> {
  const body = await res.text().catch(() => '')
  return `${res.status}${body ? `: ${body.slice(0, 200)}` : ''}`
}

async function getJson<T>(path: string, what: string, token?: string): Promise<T> {
  const res = await fetch(`${DL_DEMO_API}${path}`, { headers: authHeaders(token) })
  if (!res.ok) throw new Error(`${what} failed: ${await describeFailure(res)}`)
  return (await res.json()) as T
}

async function postJson<T>(path: string, what: string, body?: unknown, token?: string): Promise<T> {
  const res = await fetch(`${DL_DEMO_API}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders(token) },
    body: JSON.stringify(body ?? {}),
  })
  if (!res.ok) throw new Error(`${what} failed: ${await describeFailure(res)}`)
  return (await res.json()) as T
}

export async function fetchDistanceLatencySteps(token?: string): Promise<DemoStep[]> {
  const data = await getJson<{ steps?: DemoStep[] }>('/steps', 'Distance Latency steps', token)
  return Array.isArray(data.steps) ? data.steps : []
}

export async function fetchDistanceLatencyStatus(token?: string): Promise<DemoRunnerStatus> {
  const data = await getJson<Partial<DemoRunnerStatus>>('/status', 'Distance Latency status', token)
  return {
    active: data.active ?? null,
    recent: Array.isArray(data.recent) ? data.recent : [],
    script_available: data.script_available === true,
  }
}

export async function startDistanceLatencyRun(stepId: string, token?: string): Promise<DemoRunView> {
  return postJson<DemoRunView>('/runs', `Distance Latency act ${stepId}`, { step: stepId }, token)
}

export async function fetchDistanceLatencyRun(runId: string, token?: string): Promise<DemoRunView> {
  return getJson<DemoRunView>(`/runs/${encodeURIComponent(runId)}`, 'Run status', token)
}

export async function fetchDistanceLatencyRunLog(
  runId: string,
  offset: number = 0,
  wait?: number,
  token?: string,
): Promise<DemoRunLogChunk> {
  const params = new URLSearchParams()
  if (offset > 0) params.set('offset', String(offset))
  if (wait != null && wait > 0) params.set('wait', String(wait))
  const qs = params.toString()
  return getJson<DemoRunLogChunk>(
    `/runs/${encodeURIComponent(runId)}/log${qs ? `?${qs}` : ''}`,
    'Run log',
    token,
  )
}

export async function resetDistanceLatency(token?: string): Promise<DemoRunView> {
  return postJson<DemoRunView>('/reset', 'Distance Latency reset', undefined, token)
}
