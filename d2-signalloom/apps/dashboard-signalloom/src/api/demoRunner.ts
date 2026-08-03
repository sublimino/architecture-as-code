// Client for the SuperCredential demo runner API.
//
// The runner workload executes scripts/supercred-demo.sh inside the cluster and
// exposes each execution as a run resource under /demo-api. Only one run exists
// at a time — the demo mutates a shared cluster, so the workload serialises them
// — which is why every control on the instructor panel is disabled while a run
// is active rather than queueing behind it.
//
// Distinct from /supercred-api (fake-integration-proxy, read + stun) and from
// /api (fe-signalloom). This module is the only thing that talks to /demo-api.

export type DemoRunStatus = 'running' | 'succeeded' | 'failed' | 'cancelled' | 'timed_out'

/** One phase of the demo, as advertised by GET /demo-api/steps. */
export interface DemoStep {
  step_id: string
  title: string
  description: string
}

export interface DemoRunView {
  run_id: string
  step_id: string
  kind: string
  status: DemoRunStatus
  started_at?: string | null
  finished_at?: string | null
  exit_code?: number | null
  error?: string | null
}

export interface DemoRunLogChunk {
  run_id: string
  offset: number
  next_offset: number
  chunk: string
  truncated: boolean
  eof: boolean
}

export interface DemoRunnerStatus {
  active: DemoRunView | null
  recent: DemoRunView[]
  /**
   * Whether the runner can actually execute the demo script.
   *
   * False when the workload is up but the script is not mounted — the runner
   * answers, but pressing a phase button would fail. The panel disables the
   * controls and shows the equivalent make target instead.
   */
  script_available: boolean
}

const DEMO_API = '/demo-api'

/** A run in any state other than `running` is terminal and will not change. */
export function isRunActive(run: DemoRunView | null | undefined): boolean {
  return run?.status === 'running'
}

/** True once the run reached a state the instructor should read as "went wrong". */
export function isRunFailure(run: DemoRunView | null | undefined): boolean {
  return run != null && (run.status === 'failed' || run.status === 'timed_out' || run.status === 'cancelled')
}

/**
 * The CLI equivalent of a phase button.
 *
 * Shown whenever the runner cannot execute, so an instructor with a shell is
 * never left without a way to drive the demo.
 */
export function makeCommandForStep(stepId: string): string {
  return `make demo-signalloom-supercred-${stepId}`
}

async function describeFailure(res: Response): Promise<string> {
  const body = await res.text().catch(() => '')
  return `${res.status}${body ? ` — ${body.slice(0, 200)}` : ''}`
}

async function getJson<T>(path: string, what: string): Promise<T> {
  const res = await fetch(`${DEMO_API}${path}`)
  if (!res.ok) throw new Error(`${what} failed: ${await describeFailure(res)}`)
  return (await res.json()) as T
}

async function postJson<T>(path: string, what: string, body?: unknown): Promise<T> {
  const res = await fetch(`${DEMO_API}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body ?? {}),
  })
  if (!res.ok) throw new Error(`${what} failed: ${await describeFailure(res)}`)
  return (await res.json()) as T
}

export async function fetchDemoSteps(): Promise<DemoStep[]> {
  const data = await getJson<{ steps?: DemoStep[] }>('/steps', 'Demo steps')
  return Array.isArray(data.steps) ? data.steps : []
}

export async function fetchDemoStatus(): Promise<DemoRunnerStatus> {
  const data = await getJson<Partial<DemoRunnerStatus>>('/status', 'Demo status')
  return {
    active: data.active ?? null,
    recent: Array.isArray(data.recent) ? data.recent : [],
    // A missing flag means the runner cannot answer the question, and the only
    // honest reading of that is "do not offer the button".
    script_available: data.script_available === true,
  }
}

/** POST /demo-api/runs — 202 with the run that was accepted. */
export async function startDemoRun(stepId: string): Promise<DemoRunView> {
  return postJson<DemoRunView>('/runs', `Demo step ${stepId}`, { step: stepId })
}

export async function fetchDemoRun(runId: string): Promise<DemoRunView> {
  return getJson<DemoRunView>(`/runs/${encodeURIComponent(runId)}`, 'Run status')
}

/** Incremental log read — pass the previous chunk's `next_offset`. */
export async function fetchDemoRunLog(runId: string, offset: number): Promise<DemoRunLogChunk> {
  return getJson<DemoRunLogChunk>(
    `/runs/${encodeURIComponent(runId)}/log?offset=${encodeURIComponent(String(offset))}`,
    'Run log',
  )
}

/** POST /demo-api/reset — the runner implements reset as demo step 5. */
export async function resetDemo(): Promise<DemoRunView> {
  return postJson<DemoRunView>('/reset', 'Demo reset')
}
