/**
 * A demo runner with a scripted emit schedule, and no cluster behind it.
 *
 * ─── Why this exists ───────────────────────────────────────────────────────
 *
 * supercred-log-streaming.spec.ts proves progressive arrival against the live
 * estate, and it is the authority. It also needs a Kind cluster, a Gateway, Dex
 * and a runner pod, which means it cannot run on a laptop, cannot run in CI
 * stage 1, and cannot be run by whoever is halfway through changing
 * StreamingLogBlock. A regression in the streaming path would therefore be
 * caught days later by the one lane expensive enough that nobody runs it twice.
 *
 * So the same assertions get a second subject: the REAL panel and the REAL log
 * block, driven by a runner whose output schedule is written down instead of
 * being whatever kubectl felt like. Everything on the browser side is the
 * shipping code — components, api/demoRunner.ts, the poll loop, the offset
 * bookkeeping. Only two things are replaced, and both are outside the component
 * under test: the OIDC token (harness/auth-stub.tsx) and the cluster itself
 * (this file).
 *
 * ─── The two modes, and why `batch` is the important one ───────────────────
 *
 *   stream  — the log grows continuously; `/log?offset=N` hands back whatever
 *             has been produced so far. This is what a fixed runner does.
 *
 *   batch   — the log is produced on exactly the same schedule but WITHHELD:
 *             `/log` returns an empty chunk until the run reaches a terminal
 *             status, and only then hands over the whole thing at once.
 *
 * `batch` is a faithful reproduction of the defect. The old runner's monitor
 * thread called `proc.stdout.read(8192)` on a BufferedReader — a fill-exactly-n
 * read that blocks until 8192 bytes exist or the pipe closes. A demo phase
 * emits a few hundred bytes a second, so the first chunk to come back was the
 * one produced by the pipe closing: the entire log, in one frame, at exit.
 *
 * It is here so the acceptance assertions can be tested rather than trusted.
 * supercred-log-streaming-harness.spec.ts runs the SAME
 * `expectProgressiveArrival()` against a `batch` run and requires it to FAIL.
 * Without that, "this test would catch a batched log" is a claim in a comment;
 * with it, weakening the assertion turns a test red.
 *
 * ─── Wire shapes ──────────────────────────────────────────────────────────
 *
 * Every response matches api/demoRunner.ts's declared types exactly —
 * DemoStep, DemoRunView, DemoRunLogChunk, DemoRunnerStatus. A harness that
 * invented a friendlier shape would let the client drift away from the real
 * runner unnoticed, which is the failure mode one directory up.
 *
 * ─── Two transports, because the app has two ──────────────────────────────
 *
 * DEFAULT — `GET /runs/{id}/log?offset=N&wait=S`. The `wait` long poll is
 * implemented here rather than answered immediately: a double that ignores it
 * turns the panel's long poll into a hot loop, and would let a real runner that
 * dropped `wait` handling pass unnoticed.
 *
 * OPT-IN — `GET /runs/{id}/stream`, Server-Sent Events. Reached only when the
 * page carries `?logTransport=sse`, which one spec case does deliberately.
 *
 * The poll stays the default because SSE cannot cover its own worst failure
 * mode: a buffering intermediary ACCEPTS the connection and then delivers
 * nothing. No error fires, no fallback triggers, and the panel sits silent —
 * indistinguishable from the batching defect this harness reproduces in
 * `batch` mode, and introduced by the fix for it.
 *
 * Worth knowing before anyone reads too much into the SSE case: a harness on
 * loopback cannot reproduce a buffering intermediary, so it proves the happy
 * path only. The silent-stall risk stays un-testable at this layer — an
 * argument for the default, not against the test.
 *
 * ─── Running it by hand ───────────────────────────────────────────────────
 *
 *   cd test/acceptance
 *   bun harness/server.ts                  # stream mode on :8791
 *   bun harness/server.ts --mode batch     # reproduce the old defect
 *   bun harness/server.ts --port 0         # ephemeral, prints the URL
 *
 * Then open the printed URL and press a phase button.
 */
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ACCEPTANCE_DIR = join(HERE, '..')
const DASHBOARD_SRC = join(ACCEPTANCE_DIR, '..', '..', 'd2-signalloom', 'apps', 'dashboard-signalloom', 'src')

export type HarnessMode = 'stream' | 'batch'

export interface HarnessOptions {
  /** `stream` for a fixed runner, `batch` to reproduce the defect. */
  mode?: HarnessMode
  /** How many lines a run emits before it succeeds. */
  lines?: number
  /** Gap between lines. lines × intervalMs is roughly the run's duration. */
  intervalMs?: number
  /** 0 asks the OS for a free port, which is what the specs use. */
  port?: number
  /** Make the run end `failed`, to exercise the failure log tail. */
  outcome?: 'succeeded' | 'failed'
  /**
   * Silence between accepting a run and its first line of output.
   *
   * 0 by default, because the poll path does not care. The SSE case does: the
   * panel opens the stream and issues a waiting read at the same moment, and
   * whichever lands second is a duplicate the cursor guard rejects. If the read
   * wins, `onChunk` returns false and the panel shuts its own stream down —
   * deliberate behaviour, documented in SuperCredInstructorPanel, and it leaves
   * the poll delivering everything while /stream still shows one request.
   *
   * A real phase never prints in its first millisecond, so a short silence is
   * the normal case rather than a thumb on the scale: the waiting read parks
   * (which is what `wait` is FOR), the stream delivers first, and the case
   * measures the transport it claims to.
   */
  startDelayMs?: number
}

export interface Harness {
  url: string
  port: number
  mode: HarnessMode
  close(): Promise<void>
}

interface Run {
  run_id: string
  step_id: string
  kind: string
  status: 'running' | 'succeeded' | 'failed'
  started_at: string
  finished_at: string | null
  exit_code: number | null
  error: string | null
  /** Everything produced so far. In `batch` mode this is invisible until done. */
  log: string
  timer: ReturnType<typeof setInterval> | null
  /**
   * Open SSE responses, notified synchronously as each line is appended.
   *
   * ─── Why synchronous, and why before the pollers ──────────────────────────
   *
   * This is ordering, not optimisation. A real runner writes to its open
   * streams from inside the emit path and only then wakes anything blocked on
   * a long poll, so a subscriber that is already attached sees a byte before a
   * poller can. Reproducing that order is the difference between the SSE case
   * measuring SSE and measuring the fallback.
   *
   * With the stream on its own timer instead, the poll won every start: both
   * wake when the first line lands, the poll loop re-checks every 10ms and the
   * stream ticked every 30ms, so the poll's response landed first, moved the
   * cursor, and the panel's own guard (`onChunk` returning false, by design)
   * shut the stream down. Measured: 93 poll requests against 1 stream request,
   * a log that filled perfectly over the fallback, and every other assertion
   * green. That is the shape of a test that proves nothing.
   */
  subscribers: Set<() => void>
}

const STEPS = [
  { step_id: '1', title: 'Deploy', description: 'the agent joins the estate as enrolled' },
  { step_id: '2', title: 'Credential chain', description: 'the SPIFFE → OpenBao chain mints its credentials' },
  { step_id: '3', title: 'Compliance scan', description: 'the scan drops the agent into the critical band' },
  { step_id: '4', title: 'Stun', description: 'the agent is suspended and its credentials revoked' },
  { step_id: '5', title: 'Teardown', description: 'the agent is gone; the record of what happened is not' },
]

/**
 * One line of scripted output, shaped like the real script's.
 *
 * scripts/supercred-demo.sh writes `\033[1;36m[supercred]\033[0m …` and marks
 * results with `\033[1;32m[supercred] ✓\033[0m`. Reproducing the escape bytes
 * matters: StreamingLogBlock strips them for display and hands the RAW string
 * to Copy, so a harness emitting clean ASCII would never exercise stripAnsi and
 * would quietly stop covering the tokeniser.
 */
function scriptedLine(step: string, n: number, total: number): string {
  const CYAN = '\u001B[1;36m'
  const GREEN = '\u001B[1;32m'
  const OFF = '\u001B[0m'
  if (n === total) return `${GREEN}[supercred] ✓${OFF} phase ${step} complete\n`
  if (n === 1) return `${CYAN}[supercred]${OFF} phase ${step}: starting\n`
  return `${CYAN}[supercred]${OFF} step ${n}/${total}: waiting for pod/agent-cardvault condition=Ready\n`
}

let cachedBundle: string | null = null

/**
 * Bundle harness/entry.tsx, and with it the real component tree.
 *
 * Two resolutions are redirected and nothing else is:
 *
 *   react, react-dom — the dashboard app has no node_modules of its own in a
 *     fresh worktree, and Bun resolves bare specifiers by walking up from the
 *     IMPORTING file. Walking up from d2-signalloom/apps/… never reaches
 *     test/acceptance/node_modules, so React has to be pointed at explicitly.
 *     The versions there are pinned to the dashboard's own (^18.3.1).
 *
 *   src/auth/oidc — see harness/auth-stub.tsx. Anchored with `/src/auth/oidc`
 *     and a `$` so it cannot also swallow, say, `./auth/oidc-config`.
 */
async function bundle(): Promise<string> {
  if (cachedBundle) return cachedBundle
  const built = await Bun.build({
    entrypoints: [join(HERE, 'entry.tsx')],
    target: 'browser',
    define: {
      // React's development build is the one that warns about the hook and key
      // mistakes this component tree could plausibly regress into, and the
      // harness has no bundle-size budget to trade against that.
      'process.env.NODE_ENV': '"development"',
      // Vite injects `import.meta.env`; Bun does not, and the dashboard reads
      // it in api/demoMode.ts and api/config.ts. Without this the whole bundle
      // dies on `Cannot read properties of undefined (reading 'VITE_SL_ENV')`
      // at module scope — which renders as an EMPTY PAGE, so the failure
      // surfaces as "[data-testid=supercred-instructor] not found" and reads
      // like a missing component rather than a build-config gap.
      //
      // Values are the ones `vite dev` would produce. VITE_API_BASE_URL is
      // deliberately absent so the api modules fall back to relative paths and
      // every request lands on this server.
      'import.meta.env': JSON.stringify({
        MODE: 'development',
        DEV: true,
        PROD: false,
        BASE_URL: '/',
        VITE_SL_ENV: 'development',
      }),
    },
    plugins: [
      {
        name: 'harness-resolve',
        setup(build) {
          build.onResolve({ filter: /^react(-dom)?(\/.*)?$/ }, (args) => {
            try {
              return { path: Bun.resolveSync(args.path, join(ACCEPTANCE_DIR, 'node_modules')) }
            } catch {
              // Bun.resolveSync THROWS rather than returning a build log, so
              // this never reaches the `built.success` check below — it escapes
              // as a bare `ResolveMessage: Cannot find package 'react'` and the
              // spec reports "harness exited before it was ready", which reads
              // as a harness bug. It is a missing install.
              //
              // Cost a full CI-adjacent run once: a checkout whose node_modules
              // predated react being added to package.json had
              // node_modules/@playwright present, the Makefile's `[ -d
              // node_modules/@playwright ] || bun install` guard short-circuited
              // on it, and the dependency never landed. The guard is now an
              // unconditional --frozen-lockfile install; this message is the
              // belt to that braces.
              throw new Error(
                `harness bundle failed: cannot resolve "${args.path}" from ` +
                  `${join(ACCEPTANCE_DIR, 'node_modules')}.\n` +
                  `The harness renders the REAL dashboard components, so it needs react and ` +
                  `react-dom. Run:\n\n    cd test/acceptance && bun install --frozen-lockfile\n\n` +
                  `(a node_modules from before react was added to package.json looks "installed" ` +
                  `to any guard that checks only for @playwright)`,
              )
            }
          })
          build.onResolve({ filter: /auth\/oidc$/ }, () => ({
            path: join(HERE, 'auth-stub.tsx'),
          }))
        },
      },
    ],
  })
  if (!built.success) {
    throw new Error(
      `harness bundle failed:\n${built.logs.map(String).join('\n')}\n` +
        `(entry.tsx imports the real panel from ${DASHBOARD_SRC}; if that moved, this breaks)`,
    )
  }
  cachedBundle = await built.outputs[0].text()
  return cachedBundle
}

/**
 * The app's own stylesheet, served from where it lives.
 *
 * ─── Why this is not optional ──────────────────────────────────────────────
 *
 * The harness used to render the panel with NO stylesheet at all, on the
 * reasoning that StreamingLogBlock styles itself inline. That reasoning was
 * wrong in one specific and expensive way: `global.css` sets the font stack,
 * the base font-size and the line-height on `html, body, #root`, and it defines
 * `.card` and `.btn`, which the panel uses by class name. Without it the page
 * inherits the browser's defaults, which is NOT what the app renders — and the
 * scroll assertions here are assertions about LAYOUT, so rendering under
 * different typography means measuring a box the app never has.
 *
 * It also removes a whole class of confusing failure. Text with no resolvable
 * font produces zero-height line boxes, an unscrollable log block, and the
 * message "the log never overflowed its box" — which reads as a component bug
 * and is not one. Serving the real stylesheet means the harness fails the same
 * way the app would, and `expectRendersText()` in the spec catches the
 * remaining environment case by name.
 *
 * Self-contained by luck and worth recording: global.css has no `@import`, no
 * `@font-face` and no `url()`, and the app's index.html loads no webfont, so
 * every family in it resolves against system fonts. Serving one file is
 * therefore the whole stylesheet, not the first of a chain.
 */
const GLOBAL_CSS = join(DASHBOARD_SRC, 'styles', 'global.css')

const INDEX_HTML = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>SuperCred streaming harness</title>
    <!-- The app's real stylesheet, not an approximation of it. See GLOBAL_CSS. -->
    <link rel="stylesheet" href="/global.css" />
  </head>
  <body>
    <!-- No cluster, no Dex, no router: one component and the runner it talks to. -->
    <div id="root"></div>
    <script type="module" src="/harness.js"></script>
  </body>
</html>
`

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  })
}

/** The public projection of a run — DemoRunView, with the log left off. */
function view(run: Run) {
  const { log: _log, timer: _timer, ...rest } = run
  return rest
}

export function startHarness(options: HarnessOptions = {}): Harness {
  const mode: HarnessMode = options.mode ?? 'stream'
  const lines = options.lines ?? 90
  const intervalMs = options.intervalMs ?? 60
  const outcome = options.outcome ?? 'succeeded'
  const startDelayMs = options.startDelayMs ?? 0

  const runs = new Map<string, Run>()
  let active: Run | null = null
  const history: Run[] = []
  let counter = 0

  function begin(stepId: string, kind: string): Run {
    const run: Run = {
      run_id: `harness-${++counter}`,
      step_id: stepId,
      kind,
      status: 'running',
      started_at: new Date().toISOString(),
      finished_at: null,
      exit_code: null,
      error: null,
      log: '',
      timer: null,
      subscribers: new Set(),
    }
    runs.set(run.run_id, run)
    history.unshift(run)
    active = run

    let emitted = 0
    const beginEmitting = () => {
      run.timer = setInterval(() => {
        emitted += 1
        run.log += scriptedLine(stepId, emitted, lines)
        // Streams first, in the same tick as the append. See Run.subscribers.
        for (const notify of run.subscribers) notify()
        if (emitted < lines) return
        if (run.timer) clearInterval(run.timer)
        run.timer = null
        run.status = outcome
        run.finished_at = new Date().toISOString()
        run.exit_code = outcome === 'succeeded' ? 0 : 1
        run.error = outcome === 'succeeded' ? null : 'scripted failure'
        if (active === run) active = null
        // Terminal too: an open stream must see the end frame without waiting
        // for a timer that may be slower than the client's patience.
        for (const notify of run.subscribers) notify()
      }, intervalMs)
    }
    // The run is `running` from the moment it is accepted either way; the delay
    // only holds back OUTPUT, which is what a real script's startup looks like.
    if (startDelayMs > 0) setTimeout(beginEmitting, startDelayMs)
    else beginEmitting()

    return run
  }

  /**
   * What `/log?offset=N` may reveal right now.
   *
   * In `batch` mode a run that has not finished reveals NOTHING, however much
   * it has produced — which is precisely what a fill-exactly-n read on a
   * BufferedReader did. The bytes exist; the client cannot have them yet.
   */
  function readable(run: Run): string {
    if (mode === 'stream') return run.log
    return run.status === 'running' ? '' : run.log
  }

  const server = Bun.serve({
    port: options.port ?? 8791,
    idleTimeout: 60,
    async fetch(request) {
      const url = new URL(request.url)
      const path = url.pathname

      if (path === '/' || path === '/index.html') {
        return new Response(INDEX_HTML, { headers: { 'content-type': 'text/html; charset=utf-8' } })
      }
      if (path === '/harness.js') {
        return new Response(await bundle(), {
          headers: { 'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'no-store' },
        })
      }
      if (path === '/global.css') {
        const css = Bun.file(GLOBAL_CSS)
        if (!(await css.exists())) {
          // Loud rather than silent: a missing stylesheet degrades to "the page
          // renders with browser defaults", which passes the streaming
          // assertions and fails the layout ones with a message about the
          // component. Serving a comment that says so puts the cause in the
          // page instead.
          return new Response(`/* harness: ${GLOBAL_CSS} not found — did the app move? */`, {
            status: 404,
            headers: { 'content-type': 'text/css; charset=utf-8' },
          })
        }
        return new Response(css, {
          headers: { 'content-type': 'text/css; charset=utf-8', 'cache-control': 'no-store' },
        })
      }

      // Phase 4 records its stun through fe-signalloom, not the demo runner.
      // Answering it keeps phase 4 drivable here; the panel treats a non-ok
      // response as a user-visible error, which would confuse a streaming
      // failure with an audit failure.
      if (path === '/api/agents/agent-cardvault/stun') return json({ ok: true })

      if (path === '/demo-api/steps') return json({ steps: STEPS })

      if (path === '/demo-api/status') {
        return json({ active: active ? view(active) : null, recent: history.map(view), script_available: true })
      }

      if (path === '/demo-api/runs' && request.method === 'POST') {
        if (active) return json({ detail: 'a run is already in flight' }, 409)
        const body = (await request.json().catch(() => ({}))) as { step?: string }
        return json(view(begin(String(body.step ?? '1'), 'step')), 202)
      }

      if (path === '/demo-api/reset' && request.method === 'POST') {
        if (active) return json({ detail: 'a run is already in flight' }, 409)
        return json(view(begin('5', 'reset')), 202)
      }

      const runMatch = path.match(/^\/demo-api\/runs\/([^/]+)(\/log|\/stream)?$/)
      if (runMatch) {
        const run = runs.get(decodeURIComponent(runMatch[1]))
        if (!run) return json({ detail: 'no such run' }, 404)

        if (runMatch[2] === '/log') {
          const offset = Number(url.searchParams.get('offset') ?? '0')

          // ── The long poll ────────────────────────────────────────────────
          //
          // `&wait=<seconds>` is what makes the DEFAULT transport feel live:
          // when the caller is already at the end of the buffer the runner
          // holds the request open until new bytes arrive, the run ends, or
          // the deadline passes, then answers normally. Delivery lands within
          // milliseconds of the script printing while the response stays an
          // ordinary short HTTP response — which is the whole reason it beats
          // SSE through a buffering intermediary.
          //
          // Implemented here rather than answered immediately because a
          // harness that ignores `wait` is not a stand-in for the transport
          // under test: it turns the panel's long poll into a hot loop, and it
          // would let a regression that drops `wait` handling on the real
          // runner pass here unnoticed. Polled rather than event-driven
          // because the scripted emitter is a setInterval and 10ms of latency
          // is an order of magnitude under the sampler's 200ms tick.
          const waitSeconds = Number(url.searchParams.get('wait') ?? '0')
          if (Number.isFinite(waitSeconds) && waitSeconds > 0) {
            const deadline = Date.now() + Math.min(waitSeconds, 30) * 1000
            while (
              Date.now() < deadline &&
              run.status === 'running' &&
              readable(run).length <= Math.max(0, offset)
            ) {
              await Bun.sleep(10)
            }
          }

          const available = readable(run)
          const from = Number.isFinite(offset) && offset >= 0 ? Math.min(offset, available.length) : 0
          const chunk = available.slice(from)
          return json({
            run_id: run.run_id,
            // Echoed back, exactly as the real runner does — the panel's
            // applyLogChunk() discards any chunk that does not begin at its
            // cursor, and that de-duplication is part of what is under test.
            offset: from,
            next_offset: from + chunk.length,
            chunk,
            truncated: false,
            eof: run.status !== 'running' && from + chunk.length >= available.length,
          })
        }

        if (runMatch[2] === '/stream') {
          // The frame contract is api/demoRunner.ts's, not one invented here.
          // It dispatches on the event NAME — `log` carries a DemoRunLogChunk,
          // `end` carries that plus `status` and `exit_code` — and a frame with
          // any other name is silently ignored. This endpoint emitted
          // `event: chunk` when it was written speculatively, before that
          // client existed, which would have produced a stream that connects,
          // delivers, and shows nothing: the exact failure the whole SSE
          // caution is about, reproduced by the test double.
          const encoder = new TextEncoder()
          const startAt = Number(url.searchParams.get('offset') ?? '0')
          let cursor = Number.isFinite(startAt) && startAt >= 0 ? startAt : 0
          // Declared out here so `cancel` can stop the emitter `start` began.
          //
          // WITHOUT THIS THE WHOLE HARNESS DIES. api/demoRunner.ts calls
          // `reader.cancel()` in a `finally`, on every exit path — the `end`
          // frame, an abort, a rejected chunk, the first-byte watchdog — which
          // closes this controller. A setInterval that keeps pushing then
          // throws `Invalid state: Controller is already closed`, and an
          // exception out of a stream callback takes the Bun PROCESS down, not
          // just the response. Every subsequent request in the run then fails
          // with net::ERR_CONNECTION_REFUSED and the spec reports a hung panel.
          //
          // Observed exactly that: the run sat on `running` for 60s while the
          // browser console filled with connection-refused errors, and the real
          // cause was four lines of stack in the harness's own stdout. A test
          // double that can die mid-run does not fail the assertion it broke —
          // it fails all of them, in a way that names nothing.
          let subscription: (() => void) | null = null
          const stop = () => {
            if (subscription !== null) run.subscribers.delete(subscription)
            subscription = null
          }

          const body = new ReadableStream({
            cancel: stop,
            start(controller) {
              // A byte immediately. STREAM_FIRST_BYTE_MS gives a stream 2s to
              // produce anything before writing it off as buffered, and a
              // harness that stays silent until its first scripted line would
              // trip that watchdog on any interval above 2s — the spec would
              // then be measuring the fallback while claiming to measure SSE.
              // `:` is an SSE comment: the client's parser drops it, which is
              // what makes it a keepalive rather than an event.
              controller.enqueue(encoder.encode(': harness stream open\n\n'))

              const push = () => {
                try {
                  emit()
                } catch {
                  // A close that raced this tick. Stop, and stay alive: the
                  // caller has gone, which is normal, and is not worth taking
                  // the server down for. `cancel` above handles the ordered
                  // case; this handles the race.
                  stop()
                }
              }

              const emit = () => {
                const available = readable(run)
                if (available.length > cursor) {
                  const chunk = available.slice(cursor)
                  const frame = {
                    run_id: run.run_id,
                    offset: cursor,
                    next_offset: cursor + chunk.length,
                    chunk,
                    truncated: false,
                    eof: false,
                  }
                  cursor += chunk.length
                  controller.enqueue(encoder.encode(`event: log\ndata: ${JSON.stringify(frame)}\n\n`))
                }
                if (run.status !== 'running' && cursor >= readable(run).length) {
                  stop()
                  const end = {
                    run_id: run.run_id,
                    offset: cursor,
                    next_offset: cursor,
                    // The contract says the end frame carries no bytes; the
                    // client passes it through its cursor guard regardless.
                    chunk: '',
                    truncated: false,
                    eof: true,
                    status: run.status,
                    exit_code: run.exit_code,
                  }
                  controller.enqueue(encoder.encode(`event: end\ndata: ${JSON.stringify(end)}\n\n`))
                  controller.close()
                }
              }
              subscription = push
              run.subscribers.add(subscription)
              // Once immediately, for the bytes that already exist at the
              // requested offset — a stream that only ever speaks on the NEXT
              // line would start a phase by withholding everything printed
              // before it connected.
              push()
            },
          })
          return new Response(body, {
            headers: {
              'content-type': 'text/event-stream',
              'cache-control': 'no-store',
              connection: 'keep-alive',
            },
          })
        }

        return json(view(run))
      }

      return json({ detail: `harness has no route for ${path}` }, 404)
    },
  })

  return {
    url: `http://127.0.0.1:${server.port}`,
    port: server.port,
    mode,
    async close() {
      for (const run of runs.values()) if (run.timer) clearInterval(run.timer)
      await server.stop(true)
    },
  }
}

/**
 * Standalone entry — and the ONLY way the specs use this file.
 *
 * `bunx playwright test` runs the test files under NODE, transpiled to CJS.
 * `Bun.serve`, `Bun.build` and `import.meta` do not exist there, so a spec that
 * `import`ed this module would die at collection with "Cannot use 'import.meta'
 * outside a module" — which Playwright then reports as `No tests found`, a
 * message that names neither this file nor the real cause. (Observed while
 * writing this; it is exactly the silent-skip shape SPEC-REGISTRY.tsv exists
 * for, one layer down.)
 *
 * So the harness is a PROCESS, not a module: the spec spawns `bun
 * harness/server.ts`, waits for the ready line below, and talks to it over
 * HTTP. That also means the harness gets its own event loop, so a busy test
 * runner cannot skew the emit schedule the timing assertions are measured
 * against.
 *
 *   bun harness/server.ts [--mode stream|batch] [--port N] [--lines N]
 *                         [--interval MS] [--outcome succeeded|failed]
 *                         [--start-delay MS]
 *
 * The bundle is built BEFORE the ready line is printed, so "ready" means the
 * page will render rather than "the socket is open and the first request will
 * take three seconds".
 */
if (import.meta.main) {
  const argv = Bun.argv.slice(2)
  const flag = (name: string): string | undefined => {
    const i = argv.indexOf(`--${name}`)
    return i >= 0 ? argv[i + 1] : undefined
  }
  const num = (name: string): number | undefined =>
    flag(name) !== undefined ? Number(flag(name)) : undefined

  await bundle()
  const harness = startHarness({
    mode: (flag('mode') as HarnessMode) ?? 'stream',
    port: num('port') ?? 8791,
    lines: num('lines'),
    intervalMs: num('interval'),
    outcome: (flag('outcome') as 'succeeded' | 'failed') ?? 'succeeded',
    startDelayMs: num('start-delay'),
  })
  // Machine-readable and on its own line: the spec matches this exact prefix.
  console.log(`HARNESS_READY ${harness.url} mode=${harness.mode}`)
}
