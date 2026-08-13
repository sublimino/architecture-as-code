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
 * `GET /demo-api/runs/{id}/stream` is served as Server-Sent Events carrying the
 * same DemoRunLogChunk JSON, for the SSE client landing on
 * feat/stream-instructor-panel. The panel on this branch does not call it, so
 * nothing in these specs depends on the frame format — see the note in
 * supercred-log-streaming-harness.spec.ts.
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
          build.onResolve({ filter: /^react(-dom)?(\/.*)?$/ }, (args) => ({
            path: Bun.resolveSync(args.path, join(ACCEPTANCE_DIR, 'node_modules')),
          }))
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

const INDEX_HTML = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>SuperCred streaming harness</title>
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
    }
    runs.set(run.run_id, run)
    history.unshift(run)
    active = run

    let emitted = 0
    run.timer = setInterval(() => {
      emitted += 1
      run.log += scriptedLine(stepId, emitted, lines)
      if (emitted < lines) return
      if (run.timer) clearInterval(run.timer)
      run.timer = null
      run.status = outcome
      run.finished_at = new Date().toISOString()
      run.exit_code = outcome === 'succeeded' ? 0 : 1
      run.error = outcome === 'succeeded' ? null : 'scripted failure'
      if (active === run) active = null
    }, intervalMs)

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
          const encoder = new TextEncoder()
          let cursor = 0
          const body = new ReadableStream({
            start(controller) {
              const push = () => {
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
                  controller.enqueue(encoder.encode(`event: chunk\ndata: ${JSON.stringify(frame)}\n\n`))
                }
                if (run.status !== 'running' && cursor >= readable(run).length) {
                  clearInterval(tick)
                  controller.enqueue(
                    encoder.encode(`event: end\ndata: ${JSON.stringify({ ...view(run), eof: true })}\n\n`),
                  )
                  controller.close()
                }
              }
              const tick = setInterval(push, Math.max(20, Math.floor(intervalMs / 2)))
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
  })
  // Machine-readable and on its own line: the spec matches this exact prefix.
  console.log(`HARNESS_READY ${harness.url} mode=${harness.mode}`)
}
