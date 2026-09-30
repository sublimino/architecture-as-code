// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Scripted cAdvisor telemetry streams for the cockpit harness (SLDC-P4-2).
 *
 * Stands in for fe-signalloom's /api/telemetry/agents SSE endpoints (the P4-1
 * producer), so the REAL dashboard components can be driven through
 * idle -> provocation spike -> cgroup freeze without a cluster. The spec moves
 * the scripted agent between phases over the /harness control plane and
 * asserts what the browser renders.
 *
 * Emission cadence is 250 ms rather than the producer's 2 s so a transition is
 * visible well inside the spec's 3 s budget; the payload shape is the one
 * documented in dashboard src/api/agentTelemetry.ts.
 *
 *   bun harness/cockpit-telemetry-server.ts [--port N]
 *
 * Same shape as coding-agents-server.ts, for the reasons its header gives:
 * Playwright runs specs under Node, so this is a process, not an import.
 */
import { join } from 'node:path'

const HERE = import.meta.dir
const ACCEPTANCE_DIR = join(HERE, '..')
const REPO_ROOT = join(ACCEPTANCE_DIR, '..', '..')
const DASHBOARD_SRC = join(REPO_ROOT, 'd2-signalloom', 'apps', 'dashboard-signalloom', 'src')
const GLOBAL_CSS = join(DASHBOARD_SRC, 'styles', 'global.css')

export const SCRIPTED_POD = 'kusari-agent-0'
export const BYSTANDER_POD = 'kusari-agent-1'
const NAMESPACE = 'tenant-kusari'
const MIB = 1024 * 1024
const EMIT_MS = 250
const KEEPALIVE_MS = 1000

type Phase = 'idle' | 'spike' | 'frozen' | 'terminated'

/** What the scripted agent reports in each phase. RSS is held across freeze. */
function reading(phase: Phase): { cpu_millicores: number; memory_rss_bytes: number; frozen: boolean } {
  switch (phase) {
    case 'idle':
      return { cpu_millicores: 1.2, memory_rss_bytes: 42 * MIB, frozen: false }
    case 'spike':
      return { cpu_millicores: 98.4, memory_rss_bytes: 42 * MIB, frozen: false }
    case 'frozen':
      // A residual float from the rate calculation, as D.2 warns about. The
      // UI must still print exactly 0.000.
      return { cpu_millicores: 0.00031, memory_rss_bytes: 42 * MIB, frozen: true }
    case 'terminated':
      return { cpu_millicores: 0, memory_rss_bytes: 0, frozen: false }
  }
}

interface RequestLog {
  streams: number
  perPodStreams: number
  estateStreams: number
  unauthenticated: number
  tokenInUrl: number
  unmatched: string[]
}

function emptyLog(): RequestLog {
  return { streams: 0, perPodStreams: 0, estateStreams: 0, unauthenticated: 0, tokenInUrl: 0, unmatched: [] }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
}

let cachedBundle: string | null = null

async function bundle(): Promise<string> {
  if (cachedBundle) return cachedBundle
  const built = await Bun.build({
    entrypoints: [join(HERE, 'cockpit-telemetry-entry.tsx')],
    target: 'browser',
    define: {
      'process.env.NODE_ENV': '"development"',
      // Vite injects import.meta.env and Bun does not; see coding-agents-server.ts.
      'import.meta.env': JSON.stringify({ MODE: 'development', DEV: true, PROD: false, BASE_URL: '/', VITE_SL_ENV: 'development' }),
    },
    plugins: [
      {
        name: 'cockpit-harness-resolve',
        setup(build) {
          build.onResolve({ filter: /^react(-dom)?(\/.*)?$/ }, (args) => {
            try {
              return { path: Bun.resolveSync(args.path, join(ACCEPTANCE_DIR, 'node_modules')) }
            } catch {
              throw new Error(
                `cockpit harness bundle failed: cannot resolve "${args.path}". Run:\n\n    cd test/acceptance && bun install --frozen-lockfile\n`,
              )
            }
          })
          build.onResolve({ filter: /auth\/oidc$/ }, () => ({ path: join(HERE, 'auth-stub.tsx') }))
        },
      },
    ],
  })
  if (!built.success) {
    throw new Error(`cockpit harness bundle failed:\n${built.logs.map(String).join('\n')}`)
  }
  cachedBundle = await built.outputs[0].text()
  return cachedBundle
}

const INDEX_HTML = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Cockpit telemetry harness</title>
    <link rel="stylesheet" href="/global.css" />
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/cockpit-harness.js"></script>
  </body>
</html>
`

export function startCockpitHarness(options: { port?: number } = {}) {
  let phase: Phase = 'idle'
  let log = emptyLog()
  const open = new Set<ReadableStreamDefaultController<Uint8Array>>()
  const enc = new TextEncoder()

  function frameFor(pod: string): string {
    const r = pod === SCRIPTED_POD ? reading(phase) : reading('idle')
    const payload = { pod_name: pod, namespace: NAMESPACE, ts: new Date().toISOString(), ...r }
    return `event: telemetry\ndata: ${JSON.stringify(payload)}\n\n`
  }

  function sse(pods: string[]): Response {
    let emit: ReturnType<typeof setInterval> | undefined
    let keepalive: ReturnType<typeof setInterval> | undefined
    let self: ReadableStreamDefaultController<Uint8Array> | undefined
    const stop = () => {
      clearInterval(emit)
      clearInterval(keepalive)
      if (self) open.delete(self)
    }
    const body = new ReadableStream<Uint8Array>({
      start(c) {
        self = c
        open.add(c)
        const push = (s: string) => {
          try {
            c.enqueue(enc.encode(s))
          } catch {
            stop()
          }
        }
        push(': connected\n\n')
        const tick = () => pods.forEach((p) => push(frameFor(p)))
        tick()
        emit = setInterval(tick, EMIT_MS)
        keepalive = setInterval(() => push(': keepalive\n\n'), KEEPALIVE_MS)
      },
      cancel: stop,
    })
    return new Response(body, {
      headers: { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' },
    })
  }

  const server = Bun.serve({
    port: options.port ?? 8793,
    idleTimeout: 0,
    async fetch(request) {
      const url = new URL(request.url)
      const path = url.pathname

      if (path === '/' || path === '/index.html') {
        return new Response(INDEX_HTML, { headers: { 'content-type': 'text/html; charset=utf-8' } })
      }
      if (path === '/cockpit-harness.js') {
        return new Response(await bundle(), { headers: { 'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'no-store' } })
      }
      if (path === '/favicon.ico') return new Response(null, { status: 204 })
      if (path === '/global.css') {
        const css = Bun.file(GLOBAL_CSS)
        if (!(await css.exists())) return new Response(`/* ${GLOBAL_CSS} not found */`, { status: 404 })
        return new Response(css, { headers: { 'content-type': 'text/css; charset=utf-8' } })
      }

      // ─── Control plane ───────────────────────────────────────────────
      if (path === '/harness/reset' && request.method === 'POST') {
        phase = 'idle'
        log = emptyLog()
        return json({ ok: true, phase })
      }
      if (path === '/harness/phase' && request.method === 'POST') {
        const body = (await request.json().catch(() => null)) as { phase?: Phase } | null
        if (!body?.phase || !['idle', 'spike', 'frozen', 'terminated'].includes(body.phase)) {
          return json({ detail: 'phase must be idle|spike|frozen|terminated' }, 400)
        }
        phase = body.phase
        return json({ ok: true, phase })
      }
      if (path === '/harness/drop' && request.method === 'POST') {
        // Sever every open stream, as a proxy restart or network blip would.
        const n = open.size
        for (const c of [...open]) {
          try {
            c.error(new Error('harness drop'))
          } catch {
            /* already closed */
          }
          open.delete(c)
        }
        return json({ ok: true, dropped: n })
      }
      if (path === '/harness/state') return json({ phase, open: open.size })
      if (path === '/harness/requests') return json(log)

      // ─── Telemetry ───────────────────────────────────────────────────
      if (path === '/api/telemetry/agents' || path.startsWith('/api/telemetry/agents/')) {
        log.streams += 1
        if ([...url.searchParams.keys()].some((k) => /token/i.test(k))) log.tokenInUrl += 1
        if (!/^Bearer \S+/.test(request.headers.get('authorization') ?? '')) {
          log.unauthenticated += 1
          return json({ detail: 'Bearer token required' }, 401)
        }
        if (path === '/api/telemetry/agents') {
          log.estateStreams += 1
          return sse([SCRIPTED_POD, BYSTANDER_POD])
        }
        const pod = decodeURIComponent(path.slice('/api/telemetry/agents/'.length))
        log.perPodStreams += 1
        return sse([pod])
      }

      log.unmatched.push(`${request.method} ${path}`)
      return json({ detail: `cockpit harness has no route for ${path}` }, 404)
    },
  })

  return {
    url: `http://127.0.0.1:${server.port}`,
    port: server.port,
    async close() {
      await server.stop(true)
    },
  }
}

if (import.meta.main) {
  const argv = Bun.argv.slice(2)
  const i = argv.indexOf('--port')
  await bundle()
  const harness = startCockpitHarness({ port: Number(i >= 0 ? argv[i + 1] : 8793) })
  // Own ready prefix; the spec matches exactly this line.
  console.log(`COCKPIT_TELEMETRY_HARNESS_READY ${harness.url}`)
}
