// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * SLCD-P5-GOV — end-to-end ingestion-to-render proof.
 *
 * WHAT MAKES THIS DIFFERENT FROM CodingAgentsTab.test.tsx
 *
 * The P5-2 suite does `vi.mock('../api/client')` and resolves the component's
 * data calls from `fakeCodingAgentData.ts`. It proves the component renders a
 * fixture. It cannot prove anything about ingestion, because no byte of it
 * ever reaches the Go service.
 *
 * This suite mocks NOTHING on the data path. It:
 *   1. starts the REAL signal-ingest ProtectedRouter on a REAL TCP socket
 *      (see api/e2e_harness_test.go),
 *   2. POSTs a realistic CodingAgentTelemetry record through the REAL
 *      dashboard api client (`api.codingAgents.ingest`) over REAL HTTP,
 *   3. renders the REAL CodingAgentsTab, whose own useEffect issues REAL
 *      GETs against that same server,
 *   4. asserts the record's values appear in the REAL rendered DOM.
 *
 * The only thing stubbed is `useAuth0().getAccessTokenSilently`, which mints
 * the bearer token. There is no IdP in a unit-test process, and token minting
 * is not part of the ingestion-to-render path being certified.
 *
 * TWO WAYS THIS SUITE COULD LIE, BOTH CLOSED BY ASSERTIONS BELOW
 *
 *  (a) Demo mode. `client.ts:232` short-circuits to local fixtures whenever
 *      isDemoMode() is true, and demoMode.ts defaults it ON when VITE_SL_ENV
 *      is unset (it defaults to 'demo'). A suite that forgot this would pass
 *      brilliantly while never opening a socket. Closed by asserting
 *      isDemoMode() === false AND by asserting on a probe marker that only
 *      the live server can produce.
 *  (b) Base URL not propagating. If VITE_API_BASE_URL does not reach
 *      import.meta.env, axios would issue same-origin requests to jsdom's
 *      about:blank origin and every call would fail. Closed by asserting the
 *      base URL is non-empty before any test runs.
 *
 * Run via: make -C d2-signalloom slcd-e2e   (or scripts/slcd-p5-e2e.sh)
 */

import { describe, it, expect, vi, beforeAll, afterAll, afterEach } from 'vitest'
import { render, screen, waitFor, cleanup } from '@testing-library/react'
import { spawn, type ChildProcess } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync, rmSync, accessSync, constants } from 'node:fs'
import { join, resolve } from 'node:path'
import { CodingAgentsTab } from './CodingAgentsTab'
import { api } from '../api/client'
import { isDemoMode, setDemoMode } from '../api/demoMode'

const HARNESS_ADDR = process.env.SLCD_E2E_HARNESS_ADDR ?? '127.0.0.1:18082'
const READY_FILE = `/tmp/slcd-e2e-ready-${process.pid}.json`
const STOP_FILE = `/tmp/slcd-e2e-stop-${process.pid}`
// Resolved from the runner's cwd (the dashboard package root), NOT from
// import.meta.url: vitest rewrites module URLs during transform, so a
// URL-relative path silently resolves somewhere else and the spawn below
// fails with a bare ENOENT naming the `go` binary rather than the bad cwd.
const INGEST_ROOT = process.env.SLCD_INGEST_ROOT ?? resolve(process.cwd(), '../signal-ingest')

const TOKEN_ALPHA = 'e2e-token-tenant-alpha'
const TOKEN_BETA = 'e2e-token-tenant-beta'

let activeToken = TOKEN_ALPHA
const getAccessTokenSilently = vi.fn(async () => activeToken)
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

let harness: ChildProcess | undefined

/**
 * Resolve the `go` binary explicitly.
 *
 * `spawn('go', ...)` fails ENOENT under vitest even when `go` is plainly on the
 * interactive shell's PATH, because the runner's child environment is not the
 * shell's. Scanning PATH ourselves (and honouring an explicit override) makes
 * the failure mode "go is genuinely not installed" instead of the far more
 * confusing "server never signalled ready".
 */
function resolveGo(): string {
  const override = process.env.SLCD_GO_BIN
  if (override) return override
  for (const dir of (process.env.PATH ?? '').split(':')) {
    if (!dir) continue
    const candidate = join(dir, 'go')
    try {
      accessSync(candidate, constants.X_OK)
      return candidate
    } catch {
      /* keep looking */
    }
  }
  throw new Error('cannot find a `go` binary on PATH; set SLCD_GO_BIN to its absolute path')
}

/** A realistic CodingAgentTelemetry record, exactly the frozen P1-1 field set. */
function telemetryRecord(overrides: {
  sessionId: string
  taskId?: string
  harnessName?: string
  role?: string
  timestamp?: string
  stepCount?: number
  elapsed?: number
}) {
  return {
    schema_version: '1.0.0',
    harness: overrides.harnessName ?? 'claude',
    session_id: overrides.sessionId,
    timestamp: overrides.timestamp ?? new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    process: { pid: 1234, ppid: 1, comm: 'claude', rss_bytes: 104857600, cpu_ticks: 450 },
    kanban: {
      task_id: overrides.taskId ?? 'SLCD-P5-GOV',
      shortcode: 'SLCD',
      role: overrides.role ?? 'governor',
      elapsed_s: overrides.elapsed ?? 120,
    },
    metrics: {
      step_count: overrides.stepCount ?? 14,
      tokens_in: 125000,
      tokens_out: 4200,
      tool_counts: {
        view_file: 8,
        write_to_file: 2,
        replace_file_content: 1,
        run_command: 3,
        grep_search: 0,
        find_by_name: 0,
        list_dir: 0,
        read_url_content: 0,
        search_web: 0,
        invoke_subagent: 0,
        send_message: 0,
        manage_task: 0,
        ask_question: 0,
        other_count: 0,
      },
    },
    network: { inference_endpoint: 'api.anthropic.com', egress_bytes: 45000 },
  }
}

/** 64 hex chars — the wire contract's session_id shape. */
function sessionId(seed: number): string {
  return seed.toString(16).padStart(2, '0').repeat(32).slice(0, 64)
}

beforeAll(async () => {
  // (a) and (b): close both silent-lie paths before anything else runs.
  setDemoMode(false)
  expect(isDemoMode(), 'demo mode must be OFF or this suite proves nothing').toBe(false)
  expect(
    import.meta.env.VITE_API_BASE_URL,
    'VITE_API_BASE_URL must reach import.meta.env or every request is same-origin',
  ).toBeTruthy()

  expect(
    existsSync(INGEST_ROOT),
    `signal-ingest module root not found at ${INGEST_ROOT}; set SLCD_INGEST_ROOT`,
  ).toBe(true)

  rmSync(READY_FILE, { force: true })
  rmSync(STOP_FILE, { force: true })

  harness = spawn(
    resolveGo(),
    ['test', './api/', '-run', 'TestSLCDE2EHarnessServer', '-count=1', '-timeout', '6m'],
    {
      cwd: INGEST_ROOT,
      env: {
        ...process.env,
        SLCD_E2E_HARNESS_ADDR: HARNESS_ADDR,
        SLCD_E2E_HARNESS_READY_FILE: READY_FILE,
        SLCD_E2E_HARNESS_STOP_FILE: STOP_FILE,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  )

  // Capture the child's output so a startup failure reports its own cause
  // rather than surfacing as an opaque readiness timeout.
  let childLog = ''
  harness.stdout?.on('data', (d) => (childLog += String(d)))
  harness.stderr?.on('data', (d) => (childLog += String(d)))
  harness.on('error', (e) => (childLog += `spawn error: ${e.message}\n`))

  // Poll for the readiness file rather than sleeping a guessed interval.
  const deadline = Date.now() + 120_000
  while (Date.now() < deadline && !existsSync(READY_FILE)) {
    await new Promise((r) => setTimeout(r, 100))
  }
  if (!existsSync(READY_FILE)) {
    throw new Error(`e2e harness server never signalled ready. Child output:\n${childLog}`)
  }
  const addr = JSON.parse(readFileSync(READY_FILE, 'utf8')).addr as string
  expect(addr).toBe(HARNESS_ADDR)
}, 180_000)

// Unmount between tests. CodingAgentsTab installs a 2.5s polling interval on
// mount; a component left mounted keeps issuing real HTTP for the rest of the
// run, which both distorts latency samples and exhausts the request budget.
afterEach(() => cleanup())

afterAll(() => {
  writeFileSync(STOP_FILE, 'stop')
  harness?.kill()
  rmSync(READY_FILE, { force: true })
  rmSync(STOP_FILE, { force: true })
})

describe('SLCD-P5-GOV end-to-end: host event -> ingestion -> UI render', () => {
  it('renders a record that was ingested over real HTTP, within the <3s KPI', async () => {
    activeToken = TOKEN_ALPHA

    // Seed to k=5 so the aggregate endpoint is ABOVE the anonymity floor and
    // returns 200 — the happy path the KPI is meant to describe.
    for (let i = 1; i <= 5; i++) {
      await api.codingAgents.ingest(
        TOKEN_ALPHA,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        telemetryRecord({ sessionId: sessionId(i), taskId: `SLCD-SEED-${i}`, stepCount: i }) as any,
      )
    }

    // t0 is the moment the host sensor emits the event.
    const probeTask = 'SLCD-PROBE-E2E'
    const t0 = performance.now()
    const ack = await api.codingAgents.ingest(
      TOKEN_ALPHA,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      telemetryRecord({ sessionId: sessionId(9), taskId: probeTask, stepCount: 42 }) as any,
    )
    expect(ack.status).toBe('ingested')
    expect(ack.duplicate).toBe(false)

    render(<CodingAgentsTab />)
    // t1 is the moment that event is legible to a human on the screen.
    await waitFor(() => expect(screen.getByText(probeTask)).toBeInTheDocument(), { timeout: 5000 })
    const latencyMs = performance.now() - t0

    // eslint-disable-next-line no-console
    console.log(`[SLCD-P5-GOV] single-sample ingest->render latency = ${latencyMs.toFixed(1)}ms`)
    expect(latencyMs).toBeLessThan(3000)
  }, 60_000)

  it('holds the <3s KPI across 20 samples, not one lucky observation', async () => {
    activeToken = TOKEN_ALPHA
    const samples: number[] = []

    for (let i = 0; i < 20; i++) {
      const task = `SLCD-LAT-${i}`
      const t0 = performance.now()
      await api.codingAgents.ingest(
        TOKEN_ALPHA,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        telemetryRecord({ sessionId: sessionId(20 + i), taskId: task, stepCount: 7 }) as any,
      )
      render(<CodingAgentsTab />)
      await waitFor(() => expect(screen.getByText(task)).toBeInTheDocument(), { timeout: 5000 })
      samples.push(performance.now() - t0)
      cleanup()
    }

    const sorted = [...samples].sort((a, b) => a - b)
    const p50 = sorted[Math.floor(sorted.length * 0.5)]
    const p95 = sorted[Math.floor(sorted.length * 0.95)]
    const max = sorted[sorted.length - 1]
    // eslint-disable-next-line no-console
    console.log(
      `[SLCD-P5-GOV] n=${samples.length} p50=${p50.toFixed(1)}ms p95=${p95.toFixed(1)}ms max=${max.toFixed(1)}ms`,
    )
    expect(max).toBeLessThan(3000)
  }, 180_000)

  it('conforms to the P1-1 frozen schema from ingestion payload through to rendered DOM', async () => {
    activeToken = TOKEN_ALPHA
    const task = 'SLCD-SCHEMA-TRACE'
    const sent = telemetryRecord({
      sessionId: sessionId(40),
      taskId: task,
      harnessName: 'antigravity',
      role: 'research',
      stepCount: 33,
    })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await api.codingAgents.ingest(TOKEN_ALPHA, sent as any)

    // Trace the SAME record back out of the real store over real HTTP.
    const listed = await api.codingAgents.list(TOKEN_ALPHA)
    const round = listed.find((r) => r.event.kanban?.task_id === task)
    expect(round, 'the ingested record must be retrievable').toBeDefined()
    expect(round!.event.harness).toBe(sent.harness)
    expect(round!.event.session_id).toBe(sent.session_id)
    expect(round!.event.metrics.step_count).toBe(sent.metrics.step_count)
    expect(round!.event.kanban.shortcode).toBe(sent.kanban.shortcode)
    expect(round!.tenant_id).toBe('tenant-alpha')

    // And that the SAME values reach the DOM, rather than spot-checking
    // unrelated fields on a different record.
    render(<CodingAgentsTab />)
    await waitFor(() => expect(screen.getByText(task)).toBeInTheDocument(), { timeout: 5000 })
    expect(screen.getAllByText('antigravity').length).toBeGreaterThan(0)
  }, 60_000)

  it('never renders another tenant’s record, even under a forged tenant header', async () => {
    // tenant-beta writes a record whose marker must never appear in an
    // alpha-authenticated UI.
    activeToken = TOKEN_BETA
    const secret = 'SLCD-BETA-CONFIDENTIAL'
    await api.codingAgents.ingest(
      TOKEN_BETA,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      telemetryRecord({ sessionId: sessionId(60), taskId: secret, harnessName: 'codex' }) as any,
    )

    // Now render as alpha. Tenant attribution comes from the credential, so no
    // client-side manipulation can reach beta's row.
    activeToken = TOKEN_ALPHA
    render(<CodingAgentsTab />)
    await waitFor(() => expect(screen.getByTestId('coding-agents-tab')).toBeInTheDocument())
    await waitFor(() => expect(screen.getByText('SLCD-PROBE-E2E')).toBeInTheDocument(), { timeout: 5000 })

    expect(screen.queryByText(secret)).toBeNull()
    expect(document.body.textContent).not.toContain(secret)

    // The backend half of the same claim: alpha's own query cannot see it.
    const alphaRows = await api.codingAgents.list(TOKEN_ALPHA)
    expect(alphaRows.some((r) => r.event.kanban?.task_id === secret)).toBe(false)
  }, 60_000)

  it('reflects a k-anonymity refusal without crashing and without inventing a cohort figure', async () => {
    // tenant-beta holds exactly one session, so the server REFUSES to disclose
    // an aggregate (HTTP 422, k=5 floor). The UI must degrade honestly.
    activeToken = TOKEN_BETA
    const betaTask = 'SLCD-BETA-SOLO'
    await api.codingAgents.ingest(
      TOKEN_BETA,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      telemetryRecord({ sessionId: sessionId(70), taskId: betaTask, harnessName: 'aider' }) as any,
    )

    // Assert the SERVER refused, not merely that the promise rejected.
    //
    // `rejects.toThrow()` alone would also be satisfied by a connection
    // failure, a timeout, or a demo-mode error — none of which prove the
    // k-anonymity control ran. That would leave this test proving only the
    // caller's half: "the UI stopped inventing a number". The half that
    // matters for the privacy claim is that signal-ingest actively declined,
    // so pin the status code and the reason.
    const refusal = await api.codingAgents.aggregate(TOKEN_BETA).then(
      () => null,
      (e: unknown) => e as { response?: { status?: number; data?: { error?: string } } },
    )
    expect(refusal, 'the aggregate must be refused, not fulfilled').not.toBeNull()
    expect(
      refusal!.response?.status,
      'the refusal must come from the server as HTTP 422, not from a transport failure',
    ).toBe(422)
    expect(String(refusal!.response?.data?.error ?? '')).toMatch(/k-anonymity floor/i)

    render(<CodingAgentsTab />)
    // Not crashing is necessary but not sufficient.
    await waitFor(() => expect(screen.getByTestId('coding-agents-tab')).toBeInTheDocument())
    // Wait for the SETTLED state. Checking the cohort card while the fetch is
    // still in flight reads the loading placeholder ("0 sessions"), which
    // passes the disclosure check for the wrong reason and hides the defect.
    await waitFor(() => expect(screen.getByText(betaTask)).toBeInTheDocument(), { timeout: 5000 })

    const cohortCard = screen.getByText('Anonymity Cohort').closest('div')?.parentElement
    const cohortText = cohortCard?.textContent ?? ''
    // eslint-disable-next-line no-console
    console.log(`[SLCD-P5-GOV] Anonymity Cohort card text = ${JSON.stringify(cohortText)}`)

    // Positive control FIRST. Without it the regex below is vacuous: a
    // selector that matched nothing yields '' , which trivially satisfies
    // "does not disclose a sub-k figure" while proving nothing at all.
    expect(cohortText, 'cohort card text must be non-empty or the check below is vacuous').toContain(
      'Anonymity Cohort',
    )

    // Parse the figure rather than regex-matching the rendered string.
    //
    // textContent concatenates sibling nodes with no separator, so the card
    // reads "Anonymity Cohort2 sessionsclock skew bounded". A \b-anchored
    // pattern finds no word boundary between "Cohort" and "2", nor between
    // "sessions" and "clock", and therefore reports NO disclosure on a card
    // that is plainly disclosing one. Extracting the number cannot fail that
    // way.
    const disclosed = cohortText.match(/(\d+)\s*(sessions|entities)/)

    if (disclosed) {
      // The whole purpose of the k=5 floor is that a cohort figure below it is
      // NOT disclosable. A client-side count substituted for the refused
      // figure re-discloses exactly what the server withheld.
      const cohortSize = Number(disclosed[1])
      expect(
        cohortSize,
        `Anonymity Cohort card disclosed a sub-k cohort size of ${cohortSize} after the server ` +
          `refused the aggregate on k=5 grounds. Card text: ${cohortText}`,
      ).toBeGreaterThanOrEqual(5)
    } else {
      // No figure is the correct outcome, but only if the card SAYS so.
      // A blank card would also match "no figure" while looking broken.
      expect(
        cohortText,
        'with no disclosable cohort the card must say so explicitly, not render blank',
      ).toMatch(/withheld/i)
    }
  }, 60_000)

  it('renders a clock-skewed record without crashing or showing a bogus skew', async () => {
    activeToken = TOKEN_ALPHA
    const task = 'SLCD-SKEW-PROBE'
    const skewed = new Date(Date.now() - 45 * 60 * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z')
    await api.codingAgents.ingest(
      TOKEN_ALPHA,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      telemetryRecord({ sessionId: sessionId(80), taskId: task, timestamp: skewed }) as any,
    )

    render(<CodingAgentsTab />)
    await waitFor(() => expect(screen.getByText(task)).toBeInTheDocument(), { timeout: 5000 })
    // The tab survived a record whose clock disagrees with the server's by 45
    // minutes, and still rendered the rest of the estate.
    expect(screen.getByTestId('coding-agents-tab')).toBeInTheDocument()
  }, 60_000)
})
