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

/**
 * Every demo-runner call must go through this prefix — nothing may hardcode
 * `/api/demo/supercred`.
 *
 * The two look interchangeable and are not. nginx routes `/demo-api/` to the
 * supercred-demo-runner pod (rewriting it back to `/api/demo/supercred$1`),
 * because that pod is the only one carrying kubectl, the repo scripts and the
 * cluster-mutating RBAC. `/api/` goes to fe-signalloom-api, which deliberately
 * has none of them.
 *
 * The credential-evidence module used the `/api/demo/supercred` form directly.
 * The router is mounted in BOTH pods, so the call was accepted rather than
 * 404'd — and then died in fe-signalloom with `IndexError: 4`, because
 * `_repo_root()` resolves `parents[4]` of `/app/demo_runner.py`, which has two.
 * The browser saw a bare HTTP 500 and the Credential Lifecycle card rendered
 * empty. Exported so there is one spelling of this prefix in the codebase.
 */
export const DEMO_API = '/demo-api'

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

function authHeaders(token?: string): HeadersInit | undefined {
  return token ? { Authorization: `Bearer ${token}` } : undefined
}

async function getJson<T>(path: string, what: string, token?: string): Promise<T> {
  const res = await fetch(`${DEMO_API}${path}`, { headers: authHeaders(token) })
  if (!res.ok) throw new Error(`${what} failed: ${await describeFailure(res)}`)
  return (await res.json()) as T
}

async function postJson<T>(path: string, what: string, body?: unknown, token?: string): Promise<T> {
  const res = await fetch(`${DEMO_API}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders(token) },
    body: JSON.stringify(body ?? {}),
  })
  if (!res.ok) throw new Error(`${what} failed: ${await describeFailure(res)}`)
  return (await res.json()) as T
}

export async function fetchDemoSteps(token?: string): Promise<DemoStep[]> {
  const data = await getJson<{ steps?: DemoStep[] }>('/steps', 'Demo steps', token)
  return Array.isArray(data.steps) ? data.steps : []
}

export async function fetchDemoStatus(token?: string): Promise<DemoRunnerStatus> {
  const data = await getJson<Partial<DemoRunnerStatus>>('/status', 'Demo status', token)
  return {
    active: data.active ?? null,
    recent: Array.isArray(data.recent) ? data.recent : [],
    // A missing flag means the runner cannot answer the question, and the only
    // honest reading of that is "do not offer the button".
    script_available: data.script_available === true,
  }
}

/** POST /demo-api/runs — 202 with the run that was accepted. */
export async function startDemoRun(stepId: string, token?: string): Promise<DemoRunView> {
  return postJson<DemoRunView>('/runs', `Demo step ${stepId}`, { step: stepId }, token)
}

export async function fetchDemoRun(runId: string, token?: string): Promise<DemoRunView> {
  return getJson<DemoRunView>(`/runs/${encodeURIComponent(runId)}`, 'Run status', token)
}

/**
 * Incremental log read — pass the previous chunk's `next_offset`.
 *
 * `waitSeconds` turns it into a long poll: when the caller is already at the
 * end of the buffer the runner holds the request open until new bytes arrive,
 * the run finishes, or the deadline passes, then answers normally. Delivery is
 * then within milliseconds of the script printing, while the request stays an
 * ordinary short HTTP response — which is the entire point. Every layer
 * between the browser and the runner can silently swallow an event-stream
 * (nginx buffers proxied responses by default, gzip fills blocks before
 * flushing, an HTTP/1.0 upstream cannot chunk, ngrok's inspector reassembles,
 * venue wifi runs a transparent proxy); none of them can swallow a response
 * that simply took a while to come back.
 *
 * The parameter is optional on both sides. A runner image that predates it
 * ignores an unknown query parameter and answers immediately, which is exactly
 * today's behaviour — so this can never make the log worse, only slower.
 */
export async function fetchDemoRunLog(
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

/** POST /demo-api/reset — the runner implements reset as demo step 5. */
export async function resetDemo(token?: string): Promise<DemoRunView> {
  return postJson<DemoRunView>('/reset', 'Demo reset', undefined, token)
}

// ─── Live log stream (SSE) — OPT-IN, NOT THE DEFAULT ──────────────────────────
//
// GET /demo-api/runs/{id}/stream pushes the same chunks the log endpoint
// serves, as they are written. It is real, it is tested, and it is deliberately
// NOT how the panel reads the log. The waiting read above is.
//
// WHY IT LOST. The failure this whole exercise exists to prevent is a blank log
// on stage, and SSE's characteristic failure produces exactly that with no
// error to react to. Any intermediary that buffers — nginx (proxy_buffering is
// ON by default and the /demo-api/ block does not turn it off), a Kubernetes
// Gateway compressor filter, ngrok, venue wifi running a transparent proxy —
// accepts the connection, answers the headers, and then holds every byte until
// the response completes. Nothing errors. `onerror` never fires. The log sits
// empty for the length of the phase and the panel has no way to know. A
// waiting read cannot fail that way: it is an ordinary short response, so a
// buffering proxy has nothing to buffer.
//
// So the stream is kept behind `sseLogStreamEnabled()` for deliberate use —
// the pattern is worth being able to demonstrate and judge — and it carries a
// first-byte watchdog rather than trusting an error that will not come.
//
// WHY NOT EventSource, for two reasons. It cannot set a single request header,
// so authenticating it means putting the bearer token in the query string —
// into the nginx access log, into every proxy log in between, and into the
// browser's own history, three places that outlive the session the token
// belongs to. It also cannot send `ngrok-skip-browser-warning`, which the free
// tier requires and which is how the demo is published. `fetch()` carries both
// headers properly; the cost is framing the byte stream ourselves.
//
// PAYLOADS ARE JSON, always. SSE treats a bare CR as a line terminator, so raw
// text in a `data:` field would be silently mangled by any progress bar or
// spinner the runner's kubectl output contains. The parser below is written
// against JSON payloads only and nothing else is a valid frame.

/**
 * Whether this browser has asked for the SSE log transport.
 *
 * Two ways in, both deliberate and neither reachable by accident:
 *   * `?logTransport=sse` on the page URL — one demo, no residue;
 *   * `localStorage['signalloom.logTransport'] = 'sse'` — sticky for a machine.
 *
 * There is no UI for this and there should not be. An instructor picking a
 * transport mid-demo is a decision they cannot evaluate; the waiting read is
 * the one that works everywhere and it is what they get.
 */
export function sseLogStreamEnabled(): boolean {
  try {
    if (new URLSearchParams(window.location.search).get('logTransport') === 'sse') return true
    return window.localStorage.getItem('signalloom.logTransport') === 'sse'
  } catch {
    // localStorage throws outright under some privacy settings, and a panel
    // that cannot read a preference has plainly not been opted in.
    return false
  }
}

/**
 * How long a stream may deliver nothing at all before it is written off.
 *
 * This is the buffering detector. A proxy holding the response produces zero
 * bytes; a healthy connection produces the runner's banner or its keepalive
 * comment. Two seconds is long enough to cross a tunnel and short enough that
 * an instructor never sees the difference, and the penalty for being wrong is
 * only that a working stream is dropped in favour of a working poll.
 */
export const STREAM_FIRST_BYTE_MS = 2000

/** One decoded `field: value` frame off the wire. */
export interface SseFrame {
  /** The event name; SSE's default for a frame that omits one is `message`. */
  event: string
  data: string
}

/**
 * Split whatever has been read so far into whole frames, plus the remainder.
 *
 * A network read is not a frame. One read can carry several events, half an
 * event, or nothing but the `:` keepalive comment the runner emits every ~15s
 * to stop an idle proxy closing the connection. So this is a pure, incremental
 * parser: everything after the last blank line is handed back as `rest` for the
 * caller to prepend to the next read, and a frame is only emitted once its
 * terminating blank line has actually arrived.
 */
export function parseSseFrames(buffer: string): { frames: SseFrame[]; rest: string } {
  // A trailing CR may be the first half of a CRLF that the next read finishes.
  // Normalising it now would end a line that has not ended, and every frame
  // after it would be misparsed — so it is held back verbatim.
  const heldCarriageReturn = buffer.endsWith('\r')
  const body = heldCarriageReturn ? buffer.slice(0, -1) : buffer
  const parts = body.replace(/\r\n|\r/g, '\n').split('\n\n')
  const rest = (parts.pop() ?? '') + (heldCarriageReturn ? '\r' : '')

  const frames: SseFrame[] = []
  for (const part of parts) {
    let event = 'message'
    const data: string[] = []
    for (const line of part.split('\n')) {
      if (line === '' || line.startsWith(':')) continue
      const colon = line.indexOf(':')
      const field = colon === -1 ? line : line.slice(0, colon)
      const raw = colon === -1 ? '' : line.slice(colon + 1)
      const value = raw.startsWith(' ') ? raw.slice(1) : raw
      if (field === 'event') event = value
      else if (field === 'data') data.push(value)
      // id and retry are the remaining spec fields and neither is used here:
      // reconnection is the polling path's job, not a Last-Event-ID replay.
    }
    // A block with no data line is a keepalive, not an event. Reporting it as
    // one would hand the caller a frame with nothing to parse.
    if (data.length > 0) frames.push({ event, data: data.join('\n') })
  }
  return { frames, rest }
}

/** The `end` frame: a final (empty) chunk plus the run's terminal outcome. */
export interface DemoRunStreamEnd extends DemoRunLogChunk {
  status: DemoRunStatus
  exit_code: number | null
}

export interface DemoRunStreamHandlers {
  /**
   * A `log` frame.
   *
   * Return false to say the chunk did not begin at the caller's cursor. Unlike
   * a poll, a stream cannot be re-asked for a different offset, so that is
   * unrecoverable here and the stream is torn down — see the throw below.
   */
  onChunk: (chunk: DemoRunLogChunk) => boolean | void
  onEnd?: (end: DemoRunStreamEnd) => void
}

/**
 * Follow a run's log over SSE until it ends, the caller aborts, or it breaks.
 *
 * Rejects on anything that means "this transport is not usable" — a runner with
 * no /stream route, a response with no body, a malformed frame, a chunk the
 * caller could not place. The caller is expected to answer every one of those
 * the same way: say nothing to the user and fall back to polling. There is no
 * failure mode here worth an error banner, because there is nothing the
 * instructor could do about it and the log arrives either way.
 */
export async function streamDemoRunLog(
  runId: string,
  offset: number,
  handlers: DemoRunStreamHandlers,
  token?: string,
  signal?: AbortSignal,
  firstByteMs: number = STREAM_FIRST_BYTE_MS,
): Promise<void> {
  const res = await fetch(
    `${DEMO_API}/runs/${encodeURIComponent(runId)}/stream?offset=${encodeURIComponent(String(offset))}`,
    {
      headers: {
        Accept: 'text/event-stream',
        // The published demo runs through ngrok's free tier, which serves an
        // interstitial to any request without this header. EventSource cannot
        // send it; that is the second reason this is a fetch().
        'ngrok-skip-browser-warning': 'true',
        ...authHeaders(token),
      },
      signal,
    },
  )
  if (!res.ok) throw new Error(`Run log stream failed: ${await describeFailure(res)}`)
  if (!res.body) throw new Error('Run log stream failed: the response carried no body')

  // Note there is deliberately no "the stream is open" callback, and the
  // watchdog below is not an error handler. An open response proves nothing
  // about whether bytes will flow: a buffering intermediary answers the
  // headers immediately, emits NO error of any kind, and then holds every
  // frame until the run ends. Waiting for `onerror` would mean waiting
  // forever, with a blank log on screen. The only honest evidence that this
  // transport works is a byte arriving, so that is what is timed.
  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  let firstByteTimer: ReturnType<typeof setTimeout> | undefined
  const starved = firstByteMs > 0
    ? new Promise<never>((_, reject) => {
        firstByteTimer = setTimeout(
          () => reject(new Error(
            `Run log stream failed: nothing arrived within ${firstByteMs}ms — an intermediary is buffering it`,
          )),
          firstByteMs,
        )
      })
    : null
  // Keeps the rejection handled in the paths that never race it, so a stream
  // that ends normally does not trip an unhandled-rejection warning. The race
  // below still sees the original promise reject.
  starved?.catch(() => {})

  try {
    for (;;) {
      const pending = reader.read()
      const { done, value } = starved && firstByteTimer !== undefined
        ? await Promise.race([pending, starved])
        : await pending
      if (firstByteTimer !== undefined) {
        clearTimeout(firstByteTimer)
        firstByteTimer = undefined
      }
      if (done) return
      // `stream: true` so a multi-byte character split across two reads is
      // held rather than decoded into a replacement character — the runner's
      // output contains ✓ and ✗, which are three bytes each.
      buffer += decoder.decode(value, { stream: true })
      const parsed = parseSseFrames(buffer)
      buffer = parsed.rest
      for (const frame of parsed.frames) {
        if (frame.event === 'log') {
          if (handlers.onChunk(JSON.parse(frame.data) as DemoRunLogChunk) === false) {
            throw new Error('Run log stream failed: chunk did not match the log cursor')
          }
        } else if (frame.event === 'end') {
          const end = JSON.parse(frame.data) as DemoRunStreamEnd
          // Passed through the same guard as every other chunk, so there is one
          // path into the log. Its verdict is ignored: the contract says this
          // frame carries no bytes, and if a future runner puts the tail here,
          // a rejection at the very end is repaired by the caller's post-run
          // drain rather than being worth failing the whole stream over.
          handlers.onChunk(end)
          handlers.onEnd?.(end)
          return
        }
      }
    }
  } finally {
    if (firstByteTimer !== undefined) clearTimeout(firstByteTimer)
    // Without this the response body stays open on every early return — the
    // `end` frame, an abort, a rejected chunk, the watchdog — and a demo that
    // runs five phases leaks five readers.
    void reader.cancel().catch(() => {})
  }
}
