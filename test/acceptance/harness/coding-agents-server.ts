// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * A coding-agent telemetry store with a scripted state, and no cluster behind
 * it.
 *
 * ─── Why this exists ───────────────────────────────────────────────────────
 *
 * SLCD-P6-3 has to prove SIX rendered states of P5-2's CodingAgentsTab:
 * detected-agent cards, harness classification (including `unknown`), the
 * k-anonymity WITHHELD aggregate, the empty state, the error state, and
 * cross-tenant isolation in the DOM. Five of those six are not reachable
 * against the live demo cluster:
 *
 *   * EMPTY needs a tenant with zero records. The demo estate is seeded.
 *   * ERROR needs signal-ingest to fail the list call on demand.
 *   * WITHHELD needs the aggregate refused with 422 — i.e. a cohort under the
 *     k=5 floor, which is a property of the estate's data, not a switch.
 *   * UNKNOWN needs a record whose harness did not classify.
 *   * CROSS-TENANT needs two Dex identities in two different tenants.
 *
 * Producing any of them on the shared cluster means mutating an estate other
 * specs are asserting against, and `retries: 0` on every project that touches
 * it records what the repository already thinks of that.
 *
 * And the sixth would not work either. `make demo-signalloom-up` deploys the
 * published dashboard IMAGE, and SPEC-REGISTRY.tsv's row for
 * agentmaxxing-demo-console.spec.ts records the same trap being measured on
 * 2026-09-15: the served bundle carried zero matches for a page that App.tsx
 * registers in source, because the image predates it. CodingAgentsTab is newer
 * than that page.
 *
 * So the same shape as harness/server.ts, one directory over: the REAL
 * component tree, driven by a store whose contents are STATED rather than
 * discovered.
 *
 * ─── What is real here and what is not ─────────────────────────────────────
 *
 * REAL: CodingAgentsTab, CodingAgentCard, EmptyState, LoadingState,
 * ErrorState, DashKit's StatCard, api/client.ts (including its `/api` path
 * prefixing, its Bearer header and its in-flight GET coalescing), the 2500ms
 * poll from api/pollInterval.ts, styles/global.css, and React 18 at the
 * dashboard's own major.
 *
 * NOT REAL: the OIDC token (coding-agents-auth-stub.tsx) and signal-ingest
 * (this file). That split is deliberate and it is the whole value: the
 * component's existing vitest suite replaces `api/client` itself with
 * `vi.mock`, so it asserts the component against a mock of its own data layer
 * and can never see an HTTP-shaped defect. Here the client is the shipping one
 * and only the far end of the wire is scripted.
 *
 * ─── The demo-mode trap, and why the request log exists ────────────────────
 *
 * api/fakeData.ts:927-928 registers fake routes for
 * `/v1/telemetry/coding-agents` and `/v1/telemetry/coding-agents/aggregate`.
 * If demo mode were ON in this bundle, `req()` would short-circuit to those
 * fixtures and NEVER issue an HTTP request — and because the fixtures are
 * populated and plausible, every card assertion in the spec would still PASS.
 * The spec would be green and would be testing nothing.
 *
 * Demo mode is off here because `import.meta.env.VITE_SL_ENV` is defined as
 * `development` in the bundle below, and api/demoMode.ts only defaults the
 * toggle ON when SL_ENV is exactly `demo`. That is one string in one define,
 * and it would be silently reversible.
 *
 * So `GET /harness/requests` reports what this process actually received, and
 * the spec asserts a non-zero count before it trusts a single card. A bundle
 * that regressed into demo mode fails there, naming the cause, instead of
 * passing on fixtures.
 *
 * ─── Running it by hand ───────────────────────────────────────────────────
 *
 *   cd test/acceptance
 *   bun harness/coding-agents-server.ts             # then open the printed URL
 *   bun harness/coding-agents-server.ts --port 8792 --seed
 *
 * `--seed` installs the same demonstration state the spec's first case uses,
 * so the page renders something without a control-plane call.
 *
 * ─── Wire shapes ──────────────────────────────────────────────────────────
 *
 * Every response matches types/codingAgent.ts exactly — StoredRecord,
 * AggregateResult. A harness that invented a friendlier shape would let the
 * component drift away from the real ingest contract unnoticed, which is the
 * failure mode this file exists to close rather than to reproduce.
 */
import { join } from 'node:path'

const HERE = import.meta.dir
const ACCEPTANCE_DIR = join(HERE, '..')
const REPO_ROOT = join(ACCEPTANCE_DIR, '..', '..')
const DASHBOARD_SRC = join(REPO_ROOT, 'd2-signalloom', 'apps', 'dashboard-signalloom', 'src')
const GLOBAL_CSS = join(DASHBOARD_SRC, 'styles', 'global.css')

/**
 * The paths api/client.ts really requests.
 *
 * `req()` does `path.startsWith('/api') ? path : ` + '`/api${path}`' + `, so the
 * declared route `/v1/telemetry/coding-agents` arrives here as
 * `/api/v1/telemetry/coding-agents`. Serving the undecorated form would 404
 * every call and the spec would report an error state it did not seed — which
 * reads as a component defect. Both are accepted, and the request log records
 * whichever was used.
 */
const LIST_PATHS = ['/api/v1/telemetry/coding-agents', '/v1/telemetry/coding-agents']
const AGGREGATE_PATHS = [
  '/api/v1/telemetry/coding-agents/aggregate',
  '/v1/telemetry/coding-agents/aggregate',
]

export interface TenantState {
  /** StoredRecord[] as types/codingAgent.ts declares it. */
  records: unknown[]
  /**
   * AggregateResult, or null.
   *
   * null is NOT "empty" — it is the k-anonymity refusal. signal-ingest answers
   * 422 when the cohort is under k=5 (codingagent/store.go:268), and
   * CodingAgentsTab's `Promise.allSettled` lands that rejection as a null
   * aggregate with NO error set. P5-GOV hardened the resulting card to read
   * "Withheld" rather than falling back to a client-side count, so this is the
   * state that regression test needs.
   */
  aggregate: unknown | null
  /** HTTP status for the list call. Anything but 200 drives the error state. */
  listStatus: number
}

interface RequestLog {
  total: number
  list: number
  aggregate: number
  /** tenant -> count, so cross-tenant tests can prove BOTH sides were asked. */
  byTenant: Record<string, number>
  /** Paths that matched no route. A non-empty array is a contract drift. */
  unmatched: string[]
}

function emptyLog(): RequestLog {
  return { total: 0, list: 0, aggregate: 0, byTenant: {}, unmatched: [] }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json',
      'cache-control': 'no-store',
      // The spec drives two browser contexts at one origin, so CORS never
      // fires — but the control plane is also called from the Playwright
      // process via `request`, and a stray preflight answered with a 404 would
      // read as "the harness has no control plane".
      'access-control-allow-origin': '*',
      'access-control-allow-headers': 'authorization,content-type',
      'access-control-allow-methods': 'GET,POST,OPTIONS',
    },
  })
}

/**
 * `Authorization: Bearer harness-token:<tenant>` -> `<tenant>`.
 *
 * Returns null for anything else, which the routes answer with 401. An
 * unauthenticated request must NOT fall through to some default tenant: that
 * would make the cross-tenant assertions pass for the wrong reason.
 */
function tenantOf(request: Request): string | null {
  const header = request.headers.get('authorization') ?? ''
  const match = header.match(/^Bearer\s+harness-token:(.+)$/)
  return match ? match[1] : null
}

let cachedBundle: string | null = null

/**
 * Bundle coding-agents-entry.tsx, and with it the real component tree.
 *
 * Two resolutions are redirected and nothing else is, matching
 * harness/server.ts for the reasons its comment gives:
 *
 *   react, react-dom — the dashboard app has no node_modules of its own in a
 *     fresh worktree, and Bun resolves bare specifiers by walking up from the
 *     IMPORTING file, which never reaches test/acceptance/node_modules.
 *
 *   src/auth/oidc — see coding-agents-auth-stub.tsx. The filter is anchored on
 *     `auth/oidc$` so it cannot also swallow, say, `./auth/oidc-config`.
 */
async function bundle(): Promise<string> {
  if (cachedBundle) return cachedBundle
  const built = await Bun.build({
    entrypoints: [join(HERE, 'coding-agents-entry.tsx')],
    target: 'browser',
    define: {
      'process.env.NODE_ENV': '"development"',
      // Vite injects `import.meta.env`; Bun does not, and the dashboard reads
      // it in api/demoMode.ts and api/client.ts. Without this the whole bundle
      // dies at module scope and the page renders EMPTY, which surfaces as
      // "[data-testid=coding-agents-tab] not found" — a missing-component
      // message for a build-config gap.
      //
      // VITE_SL_ENV is 'development' and NOT 'demo', and that is load-bearing:
      // see the demo-mode note in this file's header. VITE_API_BASE_URL is
      // deliberately absent so api/client.ts falls back to relative paths and
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
        name: 'coding-agents-harness-resolve',
        setup(build) {
          build.onResolve({ filter: /^react(-dom)?(\/.*)?$/ }, (args) => {
            try {
              return { path: Bun.resolveSync(args.path, join(ACCEPTANCE_DIR, 'node_modules')) }
            } catch {
              // Bun.resolveSync THROWS rather than returning a build log, so
              // this escapes as a bare ResolveMessage and the spec reports
              // "harness exited before it was ready" — which reads as a harness
              // bug and is a missing install.
              throw new Error(
                `coding-agents harness bundle failed: cannot resolve "${args.path}" from ` +
                  `${join(ACCEPTANCE_DIR, 'node_modules')}.\n` +
                  `The harness renders the REAL dashboard components, so it needs react and ` +
                  `react-dom. Run:\n\n    cd test/acceptance && bun install --frozen-lockfile\n`,
              )
            }
          })
          build.onResolve({ filter: /auth\/oidc$/ }, () => ({
            path: join(HERE, 'coding-agents-auth-stub.tsx'),
          }))
        },
      },
    ],
  })
  if (!built.success) {
    throw new Error(
      `coding-agents harness bundle failed:\n${built.logs.map(String).join('\n')}\n` +
        `(coding-agents-entry.tsx imports the real tab from ${DASHBOARD_SRC}; if that moved, this breaks)`,
    )
  }
  cachedBundle = await built.outputs[0].text()
  return cachedBundle
}

const INDEX_HTML = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Coding agent topology harness</title>
    <!-- The app's real stylesheet, not an approximation of it. CodingAgentCard
         uses .card and .tag by class name and EmptyState uses .kicker; without
         this the page inherits browser defaults and is not the app. -->
    <link rel="stylesheet" href="/global.css" />
  </head>
  <body>
    <!-- No cluster, no Dex, no router: one tab and the store it talks to. -->
    <div id="root"></div>
    <script type="module" src="/coding-agents-harness.js"></script>
  </body>
</html>
`

export interface CodingAgentsHarness {
  url: string
  port: number
  close(): Promise<void>
}

export function startCodingAgentsHarness(options: { port?: number } = {}): CodingAgentsHarness {
  const tenants = new Map<string, TenantState>()
  let log = emptyLog()

  function stateFor(tenant: string): TenantState {
    return tenants.get(tenant) ?? { records: [], aggregate: null, listStatus: 200 }
  }

  const server = Bun.serve({
    port: options.port ?? 8792,
    idleTimeout: 60,
    async fetch(request) {
      const url = new URL(request.url)
      const path = url.pathname

      if (request.method === 'OPTIONS') return json({ ok: true })

      // ─── Static ────────────────────────────────────────────────────────
      if (path === '/' || path === '/index.html') {
        return new Response(INDEX_HTML, {
          headers: { 'content-type': 'text/html; charset=utf-8' },
        })
      }
      if (path === '/coding-agents-harness.js') {
        return new Response(await bundle(), {
          headers: {
            'content-type': 'text/javascript; charset=utf-8',
            'cache-control': 'no-store',
          },
        })
      }
      if (path === '/global.css') {
        const css = Bun.file(GLOBAL_CSS)
        if (!(await css.exists())) {
          // Loud rather than silent: a missing stylesheet degrades to "renders
          // with browser defaults", which passes every text assertion here and
          // would only surface later as an inexplicable layout complaint.
          return new Response(`/* harness: ${GLOBAL_CSS} not found — did the app move? */`, {
            status: 404,
            headers: { 'content-type': 'text/css; charset=utf-8' },
          })
        }
        return new Response(css, {
          headers: { 'content-type': 'text/css; charset=utf-8', 'cache-control': 'no-store' },
        })
      }

      // ─── Control plane ─────────────────────────────────────────────────
      //
      // Namespaced under /harness so it can never collide with a path
      // api/client.ts might one day request, and so a stray call shows up in
      // `unmatched` rather than being absorbed by a telemetry route.
      if (path === '/harness/reset' && request.method === 'POST') {
        tenants.clear()
        log = emptyLog()
        return json({ ok: true, tenants: 0 })
      }

      if (path === '/harness/state' && request.method === 'POST') {
        const body = (await request.json().catch(() => null)) as {
          tenant?: string
          records?: unknown[]
          aggregate?: unknown | null
          listStatus?: number
        } | null
        if (!body?.tenant) return json({ detail: 'body.tenant is required' }, 400)
        tenants.set(body.tenant, {
          records: body.records ?? [],
          aggregate: body.aggregate ?? null,
          listStatus: body.listStatus ?? 200,
        })
        return json({ ok: true, tenant: body.tenant, records: (body.records ?? []).length })
      }

      if (path === '/harness/state' && request.method === 'GET') {
        return json(
          Object.fromEntries(
            [...tenants.entries()].map(([t, s]) => [
              t,
              { records: s.records.length, aggregate: s.aggregate !== null, listStatus: s.listStatus },
            ]),
          ),
        )
      }

      if (path === '/harness/requests') return json(log)

      // ─── Telemetry ─────────────────────────────────────────────────────
      const isList = LIST_PATHS.includes(path)
      const isAggregate = AGGREGATE_PATHS.includes(path)

      if (isList || isAggregate) {
        const tenant = tenantOf(request)
        log.total += 1
        if (isList) log.list += 1
        else log.aggregate += 1
        if (tenant) log.byTenant[tenant] = (log.byTenant[tenant] ?? 0) + 1

        if (!tenant) {
          // Never a default tenant. A request with no usable identity that got
          // answered with somebody's data would make the isolation assertions
          // pass for exactly the wrong reason.
          return json({ detail: 'missing or malformed Bearer harness-token:<tenant>' }, 401)
        }

        const state = stateFor(tenant)

        if (isList) {
          if (state.listStatus !== 200) {
            return json({ detail: `scripted list failure for ${tenant}` }, state.listStatus)
          }
          return json(state.records)
        }

        // 422, not 404 and not an empty object: signal-ingest refuses to
        // COMPUTE the aggregate below the k=5 floor. CodingAgentsTab reads that
        // rejection as a null aggregate and must render "Withheld".
        if (state.aggregate === null) {
          return json({ detail: 'cohort below k=5 anonymity floor' }, 422)
        }
        return json(state.aggregate)
      }

      log.unmatched.push(`${request.method} ${path}`)
      return json({ detail: `coding-agents harness has no route for ${path}` }, 404)
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

/**
 * Standalone entry — and the ONLY way the spec uses this file.
 *
 * `bunx playwright test` runs the test files under NODE. `Bun.serve`,
 * `Bun.build` and `import.meta` do not exist there, so a spec that `import`ed
 * this module would die at COLLECTION, which Playwright reports as
 * "No tests found" — a green-looking exit that names neither this file nor the
 * cause. harness/server.ts records the same thing being hit for real.
 *
 * So the harness is a PROCESS: the spec spawns it, waits for the ready line
 * below, and drives it over HTTP.
 *
 *   bun harness/coding-agents-server.ts [--port N] [--seed]
 *
 * The bundle is built BEFORE the ready line, so "ready" means the page will
 * render rather than "the socket is open and the first request takes four
 * seconds".
 */
if (import.meta.main) {
  const argv = Bun.argv.slice(2)
  const flag = (name: string): string | undefined => {
    const i = argv.indexOf(`--${name}`)
    return i >= 0 ? argv[i + 1] : undefined
  }

  await bundle()
  const harness = startCodingAgentsHarness({ port: Number(flag('port') ?? 8792) })

  if (argv.includes('--seed')) {
    // Convenience only, for poking at the page by hand. The spec always seeds
    // through the control plane so its fixtures live beside its assertions.
    const { DEMO_SEED } = await import('./coding-agents-fixtures')
    for (const [tenant, state] of Object.entries(DEMO_SEED)) {
      await fetch(`${harness.url}/harness/state`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ tenant, ...state }),
      })
    }
  }

  // Machine-readable and on its own line: the spec matches this exact prefix.
  // Deliberately NOT the string harness/server.ts prints — a spec that matched
  // the wrong ready line would attach to the wrong process.
  console.log(`CODING_AGENTS_HARNESS_READY ${harness.url}`)
}
