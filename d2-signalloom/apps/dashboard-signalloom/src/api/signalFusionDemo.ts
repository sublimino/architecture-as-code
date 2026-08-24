/**
 * Client for the Signal Fusion demo runner API.
 *
 * The Signal Fusion demo has three acts (Inferred, Attested, Issued) exposed
 * through /demo-api/signalfusion/ — routed by nginx to the same demo-runner
 * pod as SuperCred. The runner serialises all demo types against the same
 * cluster, so only one demo (of any type) runs at a time.
 *
 * Reuses the same types as the SuperCred demo runner since the API shape is
 * identical — only the step registry and script differ.
 */
import type { DemoStep, DemoRunView, DemoRunLogChunk, DemoRunnerStatus } from './demoRunner'

export type { DemoStep, DemoRunView, DemoRunLogChunk, DemoRunnerStatus }

/**
 * All signal-fusion demo calls go through this prefix.
 *
 * nginx routes `/demo-api/signalfusion/` to the demo-runner pod (rewriting to
 * `/api/demo/signalfusion$1`).
 *
 * This constant used to read `/api/demo/signalfusion` — the runner's internal
 * mount — while the comment above described the proxy. That is not a cosmetic
 * disagreement: the gateway's signalloom-api HTTPRoute matches PathPrefix /api
 * and hands it to fe-signalloom, so every act was answered by the Discovery
 * Portal, whose image carries no scripts/ tree and neither kubectl nor curl.
 * All three returned 503 demo_root_unresolved on a live lane.
 *
 * It must stay browser-facing. Pointing it back at /api/ does not fail loudly
 * — it silently re-targets the wrong pod, which is why
 * d2-signalloom/test/signalfusion-runner-contract.bats asserts the prefix here
 * against the rewrite in nginx.conf rather than trusting either alone.
 */
const SF_DEMO_API = '/demo-api/signalfusion'

/**
 * What to type when the runner cannot execute the demo itself.
 *
 * SuperCred's equivalent names a make target (`make demo-signalloom-supercred-N`).
 * Signal Fusion has none: demo_runner.py's DemoConfig for this demo carries
 * `default_script="scripts/signalfusion-demo.sh"` and execs it directly, and
 * the script dispatches on its first argument. Naming a make target that does
 * not exist would leave an instructor with a shell worse off than with no
 * advice at all.
 *
 * d2-signalloom/test/signalfusion-runner-contract.bats joins this string to the
 * runner's own `default_script`, so the two cannot drift apart.
 */
export function shellCommandForAct(stepId: string): string {
  return `./scripts/signalfusion-demo.sh ${stepId}`
}

function authHeaders(token?: string): HeadersInit | undefined {
  return token ? { Authorization: `Bearer ${token}` } : undefined
}

async function describeFailure(res: Response): Promise<string> {
  const body = await res.text().catch(() => '')
  return `${res.status}${body ? ` — ${body.slice(0, 200)}` : ''}`
}

async function getJson<T>(path: string, what: string, token?: string): Promise<T> {
  const res = await fetch(`${SF_DEMO_API}${path}`, { headers: authHeaders(token) })
  if (!res.ok) throw new Error(`${what} failed: ${await describeFailure(res)}`)
  return (await res.json()) as T
}

async function postJson<T>(path: string, what: string, body?: unknown, token?: string): Promise<T> {
  const res = await fetch(`${SF_DEMO_API}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders(token) },
    body: JSON.stringify(body ?? {}),
  })
  if (!res.ok) throw new Error(`${what} failed: ${await describeFailure(res)}`)
  return (await res.json()) as T
}

export async function fetchSignalFusionSteps(token?: string): Promise<DemoStep[]> {
  const data = await getJson<{ steps?: DemoStep[] }>('/steps', 'Signal Fusion steps', token)
  return Array.isArray(data.steps) ? data.steps : []
}

export async function fetchSignalFusionStatus(token?: string): Promise<DemoRunnerStatus> {
  const data = await getJson<Partial<DemoRunnerStatus>>('/status', 'Signal Fusion status', token)
  return {
    active: data.active ?? null,
    recent: Array.isArray(data.recent) ? data.recent : [],
    script_available: data.script_available === true,
  }
}

export async function startSignalFusionRun(stepId: string, token?: string): Promise<DemoRunView> {
  return postJson<DemoRunView>('/runs', `Signal Fusion act ${stepId}`, { step: stepId }, token)
}

export async function fetchSignalFusionRun(runId: string, token?: string): Promise<DemoRunView> {
  return getJson<DemoRunView>(`/runs/${encodeURIComponent(runId)}`, 'Run status', token)
}

export async function fetchSignalFusionRunLog(
  runId: string,
  offset: number,
  token?: string,
  waitSeconds?: number,
): Promise<DemoRunLogChunk> {
  const wait = waitSeconds === undefined ? '' : `&wait=${encodeURIComponent(String(waitSeconds))}`
  return getJson<DemoRunLogChunk>(
    `/runs/${encodeURIComponent(runId)}/log?offset=${encodeURIComponent(String(offset))}${wait}`,
    'Run log', token,
  )
}

export async function resetSignalFusion(token?: string): Promise<DemoRunView> {
  return postJson<DemoRunView>('/reset', 'Signal Fusion reset', undefined, token)
}
