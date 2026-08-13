/**
 * Running the whole SuperCredential demo from the browser.
 *
 * The demo used to need a shell: five `make demo-signalloom-supercred-N`
 * invocations against a cluster the audience never sees. These tests drive the
 * same five phases through the instructor panel and pin down the things an
 * instructor on stage cannot recover from — a button that fires twice, a
 * failure reported as "something went wrong", a reset with no confirmation, and
 * a runner that is simply not there.
 *
 * They exercise the LIVE path, so demo-data mode is mocked off: SL_ENV defaults
 * to 'demo' under test, and a test file whose behaviour depends on an env
 * default is a trap. The simulated path is covered by supercredSource.test.ts.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

vi.mock('../api/demoMode', () => ({
  isDemoMode: () => false,
  isProductionEnv: false,
  showDemoToggle: false,
}))

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

// Superadmin is the visibility flag the sidebar sets; the page reads it from
// AppContext. Hoisted and mutable so a test can render either audience without
// re-mocking the module.
const appCtx = vi.hoisted(() => ({ superadmin: true }))
vi.mock('../App', () => ({
  useAppContext: () => ({
    superadmin: appCtx.superadmin,
    setSuperadmin: vi.fn(),
    failingControls: 0,
    setFailingControls: vi.fn(),
    setHelpOpen: vi.fn(),
  }),
}))

import SuperCredPage from './SuperCredPage'
import { colors } from '../styles/tokens'
import type { DemoRunLogChunk, DemoRunView, DemoStep } from '../api/demoRunner'

const FLUX_NS = 'fe-signalloom'

const STEPS: DemoStep[] = [
  { step_id: '1', title: 'Deploy', description: 'services + agent + OpenBao secrets' },
  { step_id: '2', title: 'Credential chain', description: 'SPIFFE SVID to OpenBao to cardvault' },
  { step_id: '3', title: 'Compliance scan', description: 'finds the missing securityContext' },
  { step_id: '4', title: 'Stun', description: 'revoke credentials, isolate the agent' },
  { step_id: '5', title: 'Teardown', description: 'remove the agent, clean estate' },
]

function cardvault() {
  return {
    id: 'agent-cardvault',
    name: 'Cardvault Agent',
    namespace: FLUX_NS,
    type: 'supercred-demo',
    framework: 'langchain',
    model: 'gpt-4',
    state: 'idle',
    phase: 'Running',
    supercred: true,
  }
}

function runView(overrides: Partial<DemoRunView> = {}): DemoRunView {
  return {
    run_id: 'run-1',
    step_id: '3',
    kind: 'step',
    status: 'running',
    started_at: '2026-08-02T10:00:00Z',
    finished_at: null,
    exit_code: null,
    error: null,
    ...overrides,
  }
}

function logChunk(overrides: Partial<DemoRunLogChunk> = {}): DemoRunLogChunk {
  return { run_id: 'run-1', offset: 0, next_offset: 0, chunk: '', truncated: false, eof: true, ...overrides }
}

interface Recorded {
  url: string
  method: string
  body: unknown
}

interface RunnerFixture {
  steps?: DemoStep[] | 'unreachable'
  scriptAvailable?: boolean
  statusUnreachable?: boolean
  /** Fail GET /demo-api/status with a specific code+body (auth cases, not transport). */
  statusFailure?: { code: number; body: unknown }
  recent?: DemoRunView[]
  activeOnLoad?: DemoRunView | null
  /** Successive GET /runs/{id} answers; the last one repeats. */
  pollRuns?: DemoRunView[]
  /** Successive GET /runs/{id}/log answers; the last one repeats. */
  pollLogs?: DemoRunLogChunk[]
  startResponse?: DemoRunView
  startStatus?: number
  agents?: ReturnType<typeof cardvault>[]
  /** A live SSE body for GET /runs/{id}/stream. Absent means the route 404s. */
  sse?: SseServer
}

/**
 * An SSE response body a test pushes frames into, one at a time.
 *
 * The point is that a test can assert what the panel has rendered BETWEEN
 * frames. Every streaming test that existed before this one handed over its
 * whole log and asserted the final text, which is why a transport that
 * delivered nothing until the process exited passed them all.
 */
function sseServer() {
  let controller: ReadableStreamDefaultController<Uint8Array> | null = null
  const encoder = new TextEncoder()
  const body = new ReadableStream<Uint8Array>({
    start(c) {
      controller = c
    },
  })
  const settle = () => new Promise(resolve => setTimeout(resolve, 0))
  return {
    body,
    /** Push a `log` frame carrying exactly the chunk the /log endpoint would. */
    async send(chunk: Partial<DemoRunLogChunk>) {
      controller?.enqueue(encoder.encode(`event: log\ndata: ${JSON.stringify(logChunk({ eof: false, ...chunk }))}\n\n`))
      await settle()
    },
    /** The ~15s keepalive comment. Carries no event and must change nothing. */
    async keepalive() {
      controller?.enqueue(encoder.encode(': keepalive\n\n'))
      await settle()
    },
    async end(offset: number, status: DemoRunView['status'], exitCode: number | null) {
      controller?.enqueue(encoder.encode(
        `event: end\ndata: ${JSON.stringify({
          ...logChunk({ offset, next_offset: offset, eof: true }), status, exit_code: exitCode,
        })}\n\n`,
      ))
      await settle()
      controller?.close()
      await settle()
    },
  }
}

type SseServer = ReturnType<typeof sseServer>

function streamingResponse(sse: SseServer): Response {
  return {
    ok: true,
    status: 200,
    body: sse.body,
    json: async () => ({}),
    text: async () => '',
  } as unknown as Response
}

let calls: Recorded[] = []

/** Route by URL so a test only declares the endpoints it cares about. */
function mockRunner(fixture: RunnerFixture = {}) {
  const pollRuns = [...(fixture.pollRuns ?? [runView({ status: 'succeeded', exit_code: 0 })])]
  const pollLogs = [...(fixture.pollLogs ?? [logChunk()])]
  const agents = fixture.agents ?? [cardvault()]

  const respond = (payload: unknown, status = 200) =>
    ({
      ok: status >= 200 && status < 300,
      status,
      json: async () => payload,
      text: async () => (typeof payload === 'string' ? payload : ''),
    }) as Response

  globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input)
    const method = (init?.method ?? 'GET').toUpperCase()
    calls.push({ url, method, body: init?.body ? JSON.parse(String(init.body)) : undefined })

    if (url === '/demo-api/steps') {
      if (fixture.steps === 'unreachable') return respond('no runner', 502)
      return respond({ steps: fixture.steps ?? STEPS })
    }
    if (url === '/demo-api/status') {
      if (fixture.statusFailure) return respond(fixture.statusFailure.body, fixture.statusFailure.code)
      if (fixture.statusUnreachable) return respond('no runner', 502)
      return respond({
        active: fixture.activeOnLoad ?? null,
        recent: fixture.recent ?? [],
        script_available: fixture.scriptAvailable ?? true,
      })
    }
    // The panel opens an SSE stream first and falls back to polling when it
    // cannot. Unless a fixture says otherwise this answers as a runner image
    // from before /stream existed, which keeps every test below on the polling
    // path it was written for — and makes the fallback itself load-bearing in
    // all of them rather than only in the one test that names it.
    if (url.startsWith('/demo-api/runs/') && url.includes('/stream')) {
      if (!fixture.sse) return respond('no stream endpoint', 404)
      return streamingResponse(fixture.sse)
    }
    if (url.startsWith('/demo-api/runs/') && url.includes('/log')) {
      return respond(pollLogs.length > 1 ? pollLogs.shift() : pollLogs[0])
    }
    if (url.startsWith('/demo-api/runs/')) {
      return respond(pollRuns.length > 1 ? pollRuns.shift() : pollRuns[0])
    }
    if (url === '/demo-api/runs') {
      const status = fixture.startStatus ?? 202
      if (status >= 300) return respond('a run is already active', status)
      const body = JSON.parse(String(init?.body ?? '{}')) as { step?: string }
      return respond(fixture.startResponse ?? runView({ step_id: body.step ?? '1' }), status)
    }
    if (url === '/demo-api/reset') {
      return respond(fixture.startResponse ?? runView({ step_id: '5', kind: 'reset' }), 202)
    }
    if (url === '/api/agents/agent-cardvault/stun' && method === 'POST') {
      return respond({ event_type: 'agent.stunned' }, 200)
    }

    // /supercred-api — the estate the existing page already renders.
    return respond({ agents, namespaces: [FLUX_NS] })
  }) as unknown as typeof fetch
}

function renderPage() {
  return render(
    <MemoryRouter>
      <SuperCredPage />
    </MemoryRouter>,
  )
}

/** Settle the panel's mount-time /demo-api/steps + /demo-api/status fetches. */
async function readyPanel() {
  renderPage()
  await screen.findByTestId('supercred-phase-status')
  await waitFor(() => expect(calls.some(c => c.url === '/demo-api/status')).toBe(true))
}

const demoApiCalls = (predicate: (c: Recorded) => boolean) => calls.filter(predicate)

beforeEach(() => {
  calls = []
  appCtx.superadmin = true
  getAccessTokenSilently.mockResolvedValue('test-token')
})

afterEach(() => {
  vi.unstubAllGlobals()
})

// ─── Naming ───────────────────────────────────────────────────────────────────

describe('SuperCredential Demo naming', () => {
  it('titles the page SuperCredential Demo in the h1', async () => {
    mockRunner()
    await readyPanel()
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('SuperCredential Demo')
  })

  it('sets the document title so a projected browser tab names the demo', async () => {
    mockRunner()
    await readyPanel()
    expect(document.title).toBe('SuperCredential Demo')
  })

  it('restores the previous document title when the page unmounts', async () => {
    document.title = 'Signal Loom — Agent Governance'
    mockRunner()
    const { unmount } = renderPage()
    await screen.findByTestId('supercred-phase-status')
    unmount()
    expect(document.title).toBe('Signal Loom — Agent Governance')
  })
})

// ─── Who sees what ────────────────────────────────────────────────────────────

describe('instructor controls are superadmin-only', () => {
  it('shows the control block to a superadmin', async () => {
    mockRunner()
    await readyPanel()
    expect(screen.getByTestId('supercred-instructor')).toBeInTheDocument()
    expect(screen.getByTestId('supercred-refresh-clients')).toBeInTheDocument()
    expect(screen.getByTestId('supercred-reset')).toBeInTheDocument()
    expect(screen.getByTestId('supercred-run-step-1')).toBeInTheDocument()
  })

  it('hides every run and reset control from a non-superadmin', async () => {
    appCtx.superadmin = false
    mockRunner()
    await readyPanel()
    expect(screen.queryByTestId('supercred-instructor')).not.toBeInTheDocument()
    expect(screen.queryByTestId('supercred-refresh-clients')).not.toBeInTheDocument()
    expect(screen.queryByTestId('supercred-reset')).not.toBeInTheDocument()
    for (const id of ['1', '2', '3', '4', '5']) {
      expect(screen.queryByTestId(`supercred-run-step-${id}`)).not.toBeInTheDocument()
    }
  })

  it('still shows a non-superadmin the phase status and the links', async () => {
    appCtx.superadmin = false
    mockRunner({ recent: [runView({ step_id: '3', status: 'succeeded', exit_code: 0 })] })
    await readyPanel()
    await waitFor(() => expect(screen.getByTestId('supercred-phase-status-3')).toHaveTextContent('succeeded'))
    expect(screen.getByTestId('supercred-show-on-3')).toHaveAttribute('href', '/compliance')
  })
})

describe('reset clean-state boundary', () => {
  it('shows phases as not run after a successful latest reset', async () => {
    mockRunner({
      recent: [
        runView({ step_id: '5', kind: 'reset', status: 'succeeded', exit_code: 0 }),
        ...['5', '4', '3', '2', '1'].map(step_id => runView({ step_id, status: 'succeeded', exit_code: 0 })),
      ],
    })
    await readyPanel()

    expect(screen.getByTestId('supercred-clean-state')).toHaveTextContent(/Clean state verified.*teardown completed/i)
    for (const id of ['1', '2', '3', '4', '5']) {
      expect(screen.getByTestId(`supercred-phase-status-${id}`)).toHaveTextContent('not run')
      expect(screen.getByTestId(`supercred-run-step-${id}`)).toBeEnabled()
    }
  })

  it('shows new phase progress after reset without discarding run history', async () => {
    mockRunner({
      recent: [
        runView({ step_id: '1', status: 'succeeded', exit_code: 0 }),
        runView({ step_id: '5', kind: 'reset', status: 'succeeded', exit_code: 0 }),
      ],
    })
    await readyPanel()

    expect(screen.queryByTestId('supercred-clean-state')).not.toBeInTheDocument()
    expect(screen.getByTestId('supercred-phase-status-1')).toHaveTextContent('succeeded')
  })

  it('does not present prior-cycle phases as completed after starting deployment', async () => {
    mockRunner({
      recent: [
        runView({ step_id: '1', status: 'running' }),
        runView({ step_id: '5', kind: 'reset', status: 'succeeded', exit_code: 0 }),
        ...['5', '4', '3', '2', '1'].map(step_id => runView({ step_id, status: 'succeeded', exit_code: 0 })),
      ],
    })
    await readyPanel()

    expect(screen.getByTestId('supercred-phase-status-1')).toHaveTextContent('running')
    for (const id of ['2', '3', '4', '5']) {
      expect(screen.getByTestId(`supercred-phase-status-${id}`)).toHaveTextContent('not run')
    }
  })
})

// ─── Where each phase lands ───────────────────────────────────────────────────

describe('"Show this on →" points at the page each phase moves', () => {
  it.each([
    ['1', '/agents'],
    ['2', '/credential-inventory'],
    ['3', '/compliance'],
    ['4', '/agents'],
    ['5', '/audit'],
  ])('phase %s links to %s', async (step, href) => {
    mockRunner()
    await readyPanel()
    expect(screen.getByTestId(`supercred-show-on-${step}`)).toHaveAttribute('href', href)
  })

  it('names the destination in the link text, not just the arrow', async () => {
    mockRunner()
    await readyPanel()
    expect(screen.getByTestId('supercred-show-on-3')).toHaveTextContent('Show this on Compliance →')
    expect(screen.getByTestId('supercred-show-on-4')).toHaveTextContent('Show this on Agents →')
  })

  it('keeps the links when the runner cannot be reached at all', async () => {
    // The targets are a property of the demo, not of the runner. An instructor
    // driving it from a shell still needs to know where to look.
    mockRunner({ steps: 'unreachable', statusUnreachable: true })
    await readyPanel()
    expect(screen.getByTestId('supercred-show-on-5')).toHaveAttribute('href', '/audit')
  })
})

// ─── Phase buttons ────────────────────────────────────────────────────────────

describe('phase buttons come from GET /demo-api/steps', () => {
  it('renders one button per advertised step, labelled by the runner', async () => {
    mockRunner()
    await readyPanel()
    await waitFor(() => expect(screen.getByTestId('supercred-run-step-2')).toHaveTextContent('Credential chain'))
    for (const step of STEPS) {
      expect(screen.getByTestId(`supercred-run-step-${step.step_id}`)).toBeInTheDocument()
    }
  })

  it('POSTs the step id the button carries', async () => {
    mockRunner()
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-4'))
    await waitFor(() =>
      expect(demoApiCalls(c => c.url === '/demo-api/runs' && c.method === 'POST')).toHaveLength(1),
    )
    expect(demoApiCalls(c => c.url === '/demo-api/runs')[0].body).toEqual({ step: '4' })
  })

  it('renders the active run status while the step is in flight', async () => {
    mockRunner({ startResponse: runView({ step_id: '2', status: 'running' }), pollRuns: [runView({ step_id: '2' })] })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-2'))
    const status = await screen.findByTestId('supercred-run-status')
    expect(status).toHaveTextContent('running')
    expect(status).toHaveTextContent('Step 2')
  })
})

// ─── Self-describing phase controls ───────────────────────────────────────────

// Every phase button mutates a shared cluster in front of a live audience. The
// runner's own one-line description is a button title, not a briefing: it says
// what the phase is FOR, never what it will delete. These tests pin the "?" that
// says what actually happens, and pin the two phases whose consequence is
// irreversible to the wording that admits it.
describe('each phase says what it will do to the cluster before you press it', () => {
  it('gives every phase button a keyboard-reachable, named "?"', async () => {
    mockRunner()
    await readyPanel()
    await screen.findByTestId('supercred-run-step-1')

    for (const step of STEPS) {
      const hint = screen.getByRole('button', { name: `What phase ${step.step_id} does to the cluster` })
      hint.focus()
      expect(document.activeElement).toBe(hint)
    }
  })

  it('names the mechanism and the page the audience should watch', async () => {
    mockRunner()
    await readyPanel()
    await screen.findByTestId('supercred-run-step-2')

    await userEvent.hover(screen.getByTestId('supercred-run-step-2-help'))
    const tooltip = await screen.findByRole('tooltip')
    expect(tooltip).toHaveTextContent('OpenBao')
    expect(tooltip).toHaveTextContent('Credential Inventory')
  })

  it('warns that stun and teardown are destructive, and says what survives', async () => {
    mockRunner()
    await readyPanel()
    await screen.findByTestId('supercred-run-step-4')

    // Stun: the audience must know the pod keeps running but loses its identity.
    await userEvent.hover(screen.getByTestId('supercred-run-step-4-help'))
    const stun = await screen.findByRole('tooltip')
    expect(stun).toHaveTextContent('Destructive')
    expect(stun.textContent).toMatch(/no longer authenticate/i)
    await userEvent.unhover(screen.getByTestId('supercred-run-step-4-help'))

    // Teardown: the whole point of the demo is that the audit record outlives it.
    await userEvent.hover(screen.getByTestId('supercred-run-step-5-help'))
    const teardown = await screen.findByRole('tooltip')
    expect(teardown).toHaveTextContent('Destructive')
    expect(teardown).toHaveTextContent('Audit Trail')
  })

  it('keeps the hint beside its button, so wrapping cannot separate them', async () => {
    mockRunner()
    await readyPanel()
    const container = await screen.findByTestId('supercred-run-steps')
    const button = await screen.findByTestId('supercred-run-step-3')
    const hint = screen.getByTestId('supercred-run-step-3-help')

    // The row is `flex-wrap`, so button and hint must share a wrapper INSIDE
    // it. Siblings directly in the wrapping row can be split across lines,
    // stranding a bare "?" above the phase it explains.
    const pair = button.parentElement
    expect(pair).not.toBe(container)
    expect(pair).toBe(hint.closest('span[style]')?.parentElement)
    expect(pair?.parentElement).toBe(container)
  })
})

// ─── One run at a time ────────────────────────────────────────────────────────

describe('the cluster is shared, so controls lock while a run is active', () => {
  it('disables every phase button and reset while a step runs', async () => {
    mockRunner({ startResponse: runView({ status: 'running' }), pollRuns: [runView({ status: 'running' })] })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-1'))

    await waitFor(() => expect(screen.getByTestId('supercred-run-step-1')).toBeDisabled())
    for (const id of ['2', '3', '4', '5']) {
      expect(screen.getByTestId(`supercred-run-step-${id}`)).toBeDisabled()
    }
    expect(screen.getByTestId('supercred-reset')).toBeDisabled()
    expect(screen.getByTestId('supercred-refresh-clients')).toBeDisabled()
  })

  it('re-enables the controls once the run reaches a terminal state', async () => {
    mockRunner({
      startResponse: runView({ status: 'running' }),
      pollRuns: [runView({ status: 'succeeded', exit_code: 0, finished_at: '2026-08-02T10:01:00Z' })],
    })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-1'))
    await waitFor(() => expect(screen.getByTestId('supercred-run-step-1')).toBeDisabled())
    await waitFor(() => expect(screen.getByTestId('supercred-run-step-1')).toBeEnabled(), { timeout: 4000 })
    expect(screen.getByTestId('supercred-run-status')).toHaveTextContent('succeeded')
  })

  it('locks the controls for a run another instructor already started', async () => {
    mockRunner({ activeOnLoad: runView({ step_id: '2', status: 'running' }), pollRuns: [runView({ status: 'running' })] })
    await readyPanel()
    await waitFor(() => expect(screen.getByTestId('supercred-run-step-3')).toBeDisabled())
    expect(screen.getByTestId('supercred-run-status')).toHaveTextContent('Step 2')
  })
})

// ─── Log streaming ────────────────────────────────────────────────────────────

describe('the run log streams in incrementally', () => {
  it('records one durable audit event after a successful phase-four run', async () => {
    mockRunner({
      startResponse: runView({ step_id: '4', status: 'running' }),
      pollRuns: [runView({ step_id: '4', status: 'succeeded', exit_code: 0 })],
    })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-4'))

    await waitFor(() => expect(demoApiCalls(c => c.url === '/api/agents/agent-cardvault/stun')).toHaveLength(1))
    expect(demoApiCalls(c => c.url === '/api/agents/agent-cardvault/stun')[0].body).toMatchObject({ outcome: 'stunned' })
  })

  it('strips terminal color sequences from browser log output', async () => {
    mockRunner({
      startResponse: runView({ status: 'running' }),
      pollRuns: [runView({ status: 'succeeded', exit_code: 0 })],
      pollLogs: [
        logChunk({ offset: 0, next_offset: 42, chunk: '\u001b[1;36m[supercred]\u001b[0m tearing down\n', eof: true }),
      ],
    })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-5'))

    await waitFor(() => expect(screen.getByTestId('supercred-run-log')).toHaveTextContent('[supercred] tearing down'))
    expect(screen.getByTestId('supercred-run-log')).not.toHaveTextContent('\u001b[')
  })

  // The panel strips the runner's escape bytes for DISPLAY only. What it must
  // hand the block is the raw stream: the clipboard is where a failed run goes
  // when it leaves this screen — into a terminal, an issue, or a message to us
  // — and the bytes the runner actually emitted are the honest artefact. A
  // panel that passes its own stripped display text instead loses that quietly
  // and looks identical on screen.
  it('gives Copy the raw runner bytes, not the stripped text on screen', async () => {
    const writeText = vi.fn(async () => {})
    Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true })
    const raw = '\u001B[1;36m[supercred]\u001B[0m tearing down\n'
    mockRunner({
      startResponse: runView({ status: 'running' }),
      pollRuns: [runView({ status: 'succeeded', exit_code: 0 })],
      pollLogs: [logChunk({ offset: 0, next_offset: 42, chunk: raw, eof: true })],
    })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-5'))

    // The block is mounted when the run STARTS now, so its Copy button exists
    // before any bytes do. Wait for the output rather than for the button, or
    // this asserts on the empty log the waiting state legitimately holds.
    await waitFor(() => expect(screen.getByTestId('supercred-run-log')).toHaveTextContent('tearing down'), {
      timeout: 4000,
    })
    await userEvent.click(screen.getByTestId('supercred-run-log-copy'))

    expect(writeText).toHaveBeenCalledWith(raw)
  })

  it('heads the log with the phase it is the log OF, and that phase\'s status', async () => {
    // Projected on a wall, an unlabelled log is output from nowhere. The
    // runner's own step title is the honest label — and it must not be stuck
    // in the present tense, because this header outlives the run.
    //
    // Phase 2, not phase 4: phase 4 alone clears `activeRun` on success (its
    // audit branch lets the poll effect tear down mid-await, so the
    // `setActiveRun(run)` after `finishRun` never runs), which takes the whole
    // run status line down with it. Pre-existing, unrelated to the log block,
    // and not this change's to fix.
    mockRunner({
      startResponse: runView({ step_id: '2', status: 'running' }),
      pollRuns: [runView({ step_id: '2', status: 'succeeded', exit_code: 0 })],
      pollLogs: [logChunk({ offset: 0, next_offset: 20, chunk: 'minting the SVID\n', eof: true })],
    })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-2'))

    await waitFor(
      () => expect(screen.getByTestId('supercred-run-log-title')).toHaveTextContent('Phase 2 · Credential chain'),
      { timeout: 4000 },
    )
    await waitFor(() => expect(screen.getByTestId('supercred-run-log-status')).toHaveTextContent('succeeded'), {
      timeout: 4000,
    })
  })

  it('heads a reset with "Reset" rather than a phase number', async () => {
    mockRunner({
      startResponse: runView({ step_id: '5', kind: 'reset', status: 'running' }),
      pollRuns: [runView({ step_id: '5', kind: 'reset', status: 'succeeded', exit_code: 0 })],
      pollLogs: [logChunk({ offset: 0, next_offset: 20, chunk: 'tearing down\n', eof: true })],
    })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-reset'))
    await userEvent.click(await screen.findByTestId('supercred-reset-confirm'))

    const title = await screen.findByTestId('supercred-run-log-title', {}, { timeout: 4000 })
    await waitFor(() => expect(title).toHaveTextContent('Reset'))
    expect(title).not.toHaveTextContent('Phase')
  })

  it('marks the log live while the phase runs and settles it when the phase ends', async () => {
    // The caret is the only thing on the block that says "more is coming". It
    // has to track the run, not the presence of output — a finished log wearing
    // a caret tells an instructor to keep waiting for a script that has exited.
    mockRunner({
      startResponse: runView({ status: 'running' }),
      pollRuns: [runView({ status: 'running' }), runView({ status: 'succeeded', exit_code: 0 })],
      pollLogs: [
        logChunk({ offset: 0, next_offset: 14, chunk: 'step 1: deploy\n', eof: false }),
        logChunk({ offset: 14, next_offset: 14, chunk: '', eof: true }),
      ],
    })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-1'))

    await waitFor(() => expect(screen.getByTestId('supercred-run-log-caret')).toBeInTheDocument(), {
      timeout: 4000,
    })
    await waitFor(() => expect(screen.queryByTestId('supercred-run-log-caret')).toBeNull(), { timeout: 4000 })
  })

  it('appends each chunk and advances the offset it asks for next', async () => {
    mockRunner({
      startResponse: runView({ status: 'running' }),
      pollRuns: [runView({ status: 'running' }), runView({ status: 'succeeded', exit_code: 0 })],
      pollLogs: [
        logChunk({ offset: 0, next_offset: 14, chunk: 'step 1: deploy\n', eof: false }),
        logChunk({ offset: 14, next_offset: 40, chunk: 'applying NetworkPolicy\n', eof: false }),
        logChunk({ offset: 40, next_offset: 40, chunk: '', eof: true }),
      ],
    })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-1'))

    await waitFor(() => expect(screen.getByTestId('supercred-run-log')).toHaveTextContent('step 1: deploy'), {
      timeout: 4000,
    })
    await waitFor(() => expect(screen.getByTestId('supercred-run-log')).toHaveTextContent('applying NetworkPolicy'), {
      timeout: 4000,
    })

    const logCalls = demoApiCalls(c => c.url.includes('/log'))
    expect(logCalls[0].url).toContain('offset=0')
    // The second read must resume where the first stopped, or the panel is
    // re-reading (duplicated output) or skipping (lost output).
    expect(logCalls[1].url).toContain('offset=14')
  })

  // Two readers share the log cursor — the 500ms poll and the post-run drain —
  // and neither takes a lock or guards against a tick that is still in flight.
  // So the panel receives responses that no longer describe the cursor. The
  // server echoes back the offset it served, which makes those responses
  // identifiable; the panel used to ignore that field and append regardless.
  //
  // Observed 2026-08-03 on a live reset: the banner appeared twice from a
  // script that printed it once. Not cosmetic — it corrupts the log display of
  // every step, and duplicated output during a failure is precisely when an
  // instructor is trying to read it.
  it('discards a duplicate chunk instead of printing the same line twice', async () => {
    const banner = '[supercred] step 5: tearing down supercred demo resources\n'
    mockRunner({
      startResponse: runView({ step_id: '5', kind: 'reset', status: 'running' }),
      pollRuns: [runView({ status: 'running' }), runView({ status: 'failed', exit_code: 1 })],
      pollLogs: [
        logChunk({ offset: 0, next_offset: 58, chunk: banner, eof: false }),
        // The overlapping tick: issued before the response above landed, so it
        // asked for offset 0 too and carries bytes already on screen.
        logChunk({ offset: 0, next_offset: 58, chunk: banner, eof: false }),
        logChunk({ offset: 58, next_offset: 58, chunk: '', eof: true }),
      ],
    })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-1'))

    await waitFor(() => expect(screen.getByTestId('supercred-run-log')).toHaveTextContent('tearing down'), {
      timeout: 4000,
    })
    await waitFor(
      () => expect(demoApiCalls(c => c.url.includes('/log')).length).toBeGreaterThanOrEqual(3),
      { timeout: 4000 },
    )

    const rendered = screen.getByTestId('supercred-run-log').textContent ?? ''
    const occurrences = rendered.split('tearing down supercred demo resources').length - 1
    expect(occurrences).toBe(1)
  })

  it('never rewinds the cursor when an out-of-order chunk lands', async () => {
    // A slow earlier response arriving after a fast later one used to assign
    // its own stale next_offset, dragging the cursor backwards — after which
    // the panel re-read and re-printed output already displayed. The live
    // trace showed exactly this: offset=0, offset=0, offset=69, offset=0.
    mockRunner({
      startResponse: runView({ status: 'running' }),
      pollRuns: [runView({ status: 'running' }), runView({ status: 'running' }), runView({ status: 'succeeded', exit_code: 0 })],
      pollLogs: [
        logChunk({ offset: 0, next_offset: 30, chunk: 'registering SPIRE entry\n', eof: false }),
        // The straggler: describes the stream from 0, but the cursor is at 30.
        logChunk({ offset: 0, next_offset: 0, chunk: '', eof: false }),
        logChunk({ offset: 30, next_offset: 55, chunk: 'entry registered\n', eof: false }),
        logChunk({ offset: 55, next_offset: 55, chunk: '', eof: true }),
      ],
    })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-1'))

    await waitFor(() => expect(screen.getByTestId('supercred-run-log')).toHaveTextContent('entry registered'), {
      timeout: 4000,
    })

    const offsets = demoApiCalls(c => c.url.includes('/log')).map(c =>
      Number(new URL(c.url, 'http://x').searchParams.get('offset')),
    )
    // Monotonic. A single backwards step means output is about to be repeated.
    for (let i = 1; i < offsets.length; i++) {
      expect(offsets[i]).toBeGreaterThanOrEqual(offsets[i - 1])
    }
  })
})

// ─── Failure reporting ────────────────────────────────────────────────────────

describe('a failed run explains itself', () => {
  it('shows the exit code and the log tail, not a generic error', async () => {
    mockRunner({
      startResponse: runView({ status: 'running' }),
      pollRuns: [
        runView({ status: 'failed', exit_code: 17, finished_at: '2026-08-02T10:01:00Z', error: 'script exited non-zero' }),
      ],
      pollLogs: [
        logChunk({ offset: 0, next_offset: 60, chunk: 'registering SPIRE entry\nError: no such entry\n', eof: false }),
        logChunk({ offset: 60, next_offset: 60, chunk: '', eof: true }),
      ],
    })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-1'))

    const failure = await screen.findByTestId('supercred-run-error', {}, { timeout: 4000 })
    expect(within(failure).getByTestId('supercred-run-exit-code')).toHaveTextContent('17')
    expect(within(failure).getByTestId('supercred-run-log-tail')).toHaveTextContent('Error: no such entry')
    expect(failure).toHaveTextContent('script exited non-zero')
  })

  it('reports a timed-out run as a failure with its exit code', async () => {
    mockRunner({
      startResponse: runView({ status: 'running' }),
      pollRuns: [runView({ status: 'timed_out', exit_code: 124 })],
      pollLogs: [logChunk({ offset: 0, next_offset: 20, chunk: 'waiting for agent job\n', eof: true })],
    })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-2'))
    const failure = await screen.findByTestId('supercred-run-error', {}, { timeout: 4000 })
    expect(failure).toHaveTextContent('timed_out')
    expect(within(failure).getByTestId('supercred-run-exit-code')).toHaveTextContent('124')
  })

  it('surfaces a refused start, including the runner reason', async () => {
    mockRunner({ startStatus: 409 })
    await readyPanel()
    await userEvent.click(await screen.findByTestId('supercred-run-step-1'))
    expect(await screen.findByTestId('supercred-run-control-error')).toHaveTextContent(/409/)
  })
})

// ─── Script unavailable ───────────────────────────────────────────────────────

describe('when the runner cannot execute the script', () => {
  it('disables the phase buttons and reset', async () => {
    mockRunner({ scriptAvailable: false })
    await readyPanel()
    await waitFor(() => expect(screen.getByTestId('supercred-run-step-1')).toBeDisabled())
    for (const id of ['2', '3', '4', '5']) {
      expect(screen.getByTestId(`supercred-run-step-${id}`)).toBeDisabled()
    }
    expect(screen.getByTestId('supercred-reset')).toBeDisabled()
  })

  it('shows the equivalent make target for every phase', async () => {
    mockRunner({ scriptAvailable: false })
    await readyPanel()
    const note = await screen.findByTestId('supercred-script-unavailable')
    expect(note).toBeInTheDocument()
    for (const id of ['1', '2', '3', '4', '5']) {
      expect(screen.getByTestId(`supercred-make-command-${id}`)).toHaveTextContent(
        `make demo-signalloom-supercred-${id}`,
      )
    }
  })

  it('leaves Refresh clients usable — reading the estate needs no script', async () => {
    mockRunner({ scriptAvailable: false })
    await readyPanel()
    expect(screen.getByTestId('supercred-refresh-clients')).toBeEnabled()
  })

  it('says the runner is unreachable when /demo-api/status itself fails', async () => {
    mockRunner({ statusUnreachable: true, steps: 'unreachable' })
    await readyPanel()
    const note = await screen.findByTestId('supercred-script-unavailable')
    expect(note).toHaveTextContent(/not reachable/i)
    expect(note).toHaveTextContent('502')
    expect(screen.getByTestId('supercred-make-command-3')).toHaveTextContent('make demo-signalloom-supercred-3')
  })

  // Reported from a live demo: clicking Refresh clients after Dex had restarted
  // rendered "The demo runner is not reachable", sending the instructor to debug
  // the network. The runner was healthy — the browser's token was signed by keys
  // Dex discarded on restart (storage: memory). Reachability and authorisation
  // are different failures and must not share a message.
  it('blames the expired session, not the network, on a 401 from /demo-api/status', async () => {
    mockRunner({
      steps: 'unreachable',
      statusFailure: {
        code: 401,
        body: { error: { code: 'invalid_token', message: 'Bearer token is invalid' } },
      },
    })
    await readyPanel()
    const note = await screen.findByTestId('supercred-script-unavailable')
    expect(note).toHaveTextContent(/session is no longer valid/i)
    expect(note).toHaveTextContent(/sign out and back in/i)
    expect(note).not.toHaveTextContent(/not reachable/i)
  })

  it('names the missing superadmin role on a 403 from /demo-api/status', async () => {
    mockRunner({
      steps: 'unreachable',
      statusFailure: { code: 403, body: { error: { code: 'superadmin_required' } } },
    })
    await readyPanel()
    const note = await screen.findByTestId('supercred-script-unavailable')
    expect(note).toHaveTextContent(/not a superadmin/i)
    expect(note).not.toHaveTextContent(/not reachable/i)
  })
})

// ─── Refresh clients ──────────────────────────────────────────────────────────

describe('Refresh clients re-queries live agent state', () => {
  it('re-runs discovery and re-reads the runner status', async () => {
    mockRunner()
    await readyPanel()
    const discoveryBefore = demoApiCalls(c => c.url.startsWith('/supercred-api/agents')).length
    const statusBefore = demoApiCalls(c => c.url === '/demo-api/status').length

    await userEvent.click(screen.getByTestId('supercred-refresh-clients'))

    await waitFor(() =>
      expect(demoApiCalls(c => c.url.startsWith('/supercred-api/agents')).length).toBeGreaterThan(discoveryBefore),
    )
    await waitFor(() =>
      expect(demoApiCalls(c => c.url === '/demo-api/status').length).toBeGreaterThan(statusBefore),
    )
  })

  it('updates the estate with what discovery returned', async () => {
    mockRunner()
    await readyPanel()
    await userEvent.click(screen.getByTestId('supercred-refresh-clients'))
    expect((await screen.findAllByText('Cardvault Agent')).length).toBeGreaterThanOrEqual(1)
    expect(await screen.findByTestId('discovery-supercred')).toHaveTextContent('1')
  })
})

// ─── Reset ────────────────────────────────────────────────────────────────────

describe('Reset demo is behind a confirmation', () => {
  it('does not POST on the first press', async () => {
    mockRunner()
    await readyPanel()
    await userEvent.click(screen.getByTestId('supercred-reset'))
    expect(await screen.findByTestId('supercred-reset-confirm')).toBeInTheDocument()
    expect(demoApiCalls(c => c.url === '/demo-api/reset')).toHaveLength(0)
  })

  it('POSTs /demo-api/reset once confirmed', async () => {
    mockRunner()
    await readyPanel()
    await userEvent.click(screen.getByTestId('supercred-reset'))
    await userEvent.click(await screen.findByTestId('supercred-reset-confirm'))
    await waitFor(() =>
      expect(demoApiCalls(c => c.url === '/demo-api/reset' && c.method === 'POST')).toHaveLength(1),
    )
  })

  it('cancelling disarms it and sends nothing', async () => {
    mockRunner()
    await readyPanel()
    await userEvent.click(screen.getByTestId('supercred-reset'))
    await userEvent.click(await screen.findByTestId('supercred-reset-cancel'))
    expect(screen.queryByTestId('supercred-reset-confirm')).not.toBeInTheDocument()
    expect(screen.getByTestId('supercred-reset')).toBeInTheDocument()
    expect(demoApiCalls(c => c.url === '/demo-api/reset')).toHaveLength(0)
  })
})

// ─── Which "?" explains which control ─────────────────────────────────────────

/**
 * The two hints used to sit side by side in the middle of the row —
 * `[Refresh clients] [?] [?] [Reset demo]` — so the second "?" explained a
 * button it appeared to the left of, and both were cyan while Reset demo is
 * red. An instructor mid-demo cannot afford to guess. Each "?" now follows its
 * own control inside a nowrap group, and carries that control's colour.
 */
describe('each help hint sits with the control it explains', () => {
  /** True when `first` precedes `second` in document order. */
  function precedes(first: Element, second: Element) {
    return Boolean(first.compareDocumentPosition(second) & Node.DOCUMENT_POSITION_FOLLOWING)
  }

  it('pairs each "?" with its own button and nothing else', async () => {
    mockRunner()
    await readyPanel()

    const refresh = screen.getByTestId('supercred-refresh-clients-group')
    expect(within(refresh).getByTestId('supercred-refresh-clients')).toBeInTheDocument()
    expect(within(refresh).getByTestId('supercred-refresh-clients-help')).toBeInTheDocument()
    expect(within(refresh).queryByTestId('supercred-reset-help')).not.toBeInTheDocument()

    const reset = screen.getByTestId('supercred-reset-group')
    expect(within(reset).getByTestId('supercred-reset')).toBeInTheDocument()
    expect(within(reset).getByTestId('supercred-reset-help')).toBeInTheDocument()
    expect(within(reset).queryByTestId('supercred-refresh-clients-help')).not.toBeInTheDocument()
  })

  it('puts each "?" after the button it explains, never before it', async () => {
    mockRunner()
    await readyPanel()

    const refreshButton = screen.getByTestId('supercred-refresh-clients')
    const refreshHelp = screen.getByTestId('supercred-refresh-clients-help')
    const resetButton = screen.getByTestId('supercred-reset')
    const resetHelp = screen.getByTestId('supercred-reset-help')

    // The row reads [Refresh clients][?] [Reset demo][?].
    expect(precedes(refreshButton, refreshHelp)).toBe(true)
    expect(precedes(refreshHelp, resetButton)).toBe(true)
    expect(precedes(resetButton, resetHelp)).toBe(true)
  })

  it('keeps a pair on one line when the row wraps', async () => {
    mockRunner()
    await readyPanel()

    // Without this the row can wrap between a button and its "?", which puts
    // the hint at the start of the next line beside an unrelated control.
    for (const id of ['supercred-refresh-clients-group', 'supercred-reset-group']) {
      expect(screen.getByTestId(id).style.flexWrap).toBe('nowrap')
    }
  })

  it('colours each "?" like the button it belongs to', async () => {
    mockRunner()
    await readyPanel()

    const resetHelp = screen.getByTestId('supercred-reset-help')
    expect(resetHelp.style.color).toBe(colors.red)
    expect(resetHelp.style.borderColor).toBe(colors.red)

    // The refresh hint belongs to a primary button and stays on the default.
    expect(screen.getByTestId('supercred-refresh-clients-help').style.color).toBe('var(--cyan)')
  })

  it('keeps the reset hint with the destructive button once reset is armed', async () => {
    mockRunner()
    await readyPanel()
    await userEvent.click(screen.getByTestId('supercred-reset'))

    const confirm = await screen.findByTestId('supercred-reset-confirm')
    const group = screen.getByTestId('supercred-reset-group')
    const help = within(group).getByTestId('supercred-reset-help')

    expect(within(group).getByTestId('supercred-reset-confirm')).toBe(confirm)
    expect(precedes(confirm, help)).toBe(true)
    // Cancel is not destructive and gets no hint of its own.
    expect(precedes(help, screen.getByTestId('supercred-reset-cancel'))).toBe(true)
    expect(help.style.color).toBe(colors.red)
  })

  it('names the control each "?" explains, so the two are never interchangeable', async () => {
    mockRunner()
    await readyPanel()

    const refresh = screen.getByTestId('supercred-refresh-clients-help').getAttribute('aria-label') ?? ''
    const reset = screen.getByTestId('supercred-reset-help').getAttribute('aria-label') ?? ''

    expect(refresh).toMatch(/refresh/i)
    expect(reset).toMatch(/reset/i)
    expect(refresh).not.toBe(reset)
  })
})

// ─── The existing UI is untouched ─────────────────────────────────────────────

describe('the credential-lifecycle UI still works alongside the new controls', () => {
  it('keeps the lifecycle, credential and discovery sections rendering', async () => {
    mockRunner()
    await readyPanel()
    await userEvent.click(screen.getByRole('button', { name: /Refresh Agents/ }))

    expect(await screen.findByTestId('supercred-lifecycle')).toBeInTheDocument()
    // The card is the evidence panel now; its rows come from the evidence
    // endpoint rather than from agent state, so assert the card renders.
    expect(screen.getByTestId('credential-evidence-panel')).toBeInTheDocument()
    expect(screen.getByTestId('supercred-credentials')).toBeInTheDocument()
    expect(screen.getByTestId('supercred-discovery-summary')).toBeInTheDocument()
    expect(screen.getByTestId('supercred-architecture')).toBeInTheDocument()
  })

  it('keeps the lifecycle card visible for a non-superadmin too', async () => {
    appCtx.superadmin = false
    mockRunner()
    await readyPanel()
    await userEvent.click(screen.getByRole('button', { name: /Refresh Agents/ }))
    await screen.findByTestId('supercred-lifecycle')
    // Visibility is the property that matters for a non-superadmin: the evidence
    // card is read-only, so it renders for them exactly as for an instructor.
    expect(screen.getByTestId('credential-evidence-panel')).toBeInTheDocument()
  })
})

// ─── The log cursor ───────────────────────────────────────────────────────────

/**
 * A runner that serves its log the way the real one does: from a byte buffer,
 * sliced at the offset the caller asked for.
 *
 * The fixtures above hand back the next scripted chunk on every call regardless
 * of the requested offset, which makes a re-read at a stale cursor invisible —
 * the panel asks twice and is handed two different chunks, so the bug looks
 * like correct streaming. Serving from a real buffer is what makes duplicated
 * output observable, so this is the fixture the cursor tests use.
 *
 * `logLatencyMs` models the thing that actually triggered it: a log read that
 * takes longer than POLL_MS. Over a published tunnel (`make public`) that is
 * the normal case, not the pathological one.
 */
function mockRunnerServingRealLog(opts: {
  logBuffer: string
  logLatencyMs?: number
  runningPolls?: number
  finalStatus?: DemoRunView['status']
}) {
  const { logBuffer, logLatencyMs = 0, runningPolls = 2, finalStatus = 'failed' } = opts
  let runPolls = 0

  const respond = (payload: unknown, status = 200) =>
    ({
      ok: status >= 200 && status < 300,
      status,
      json: async () => payload,
      text: async () => (typeof payload === 'string' ? payload : ''),
    }) as Response

  const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))

  globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input)
    const method = (init?.method ?? 'GET').toUpperCase()
    calls.push({ url, method, body: init?.body ? JSON.parse(String(init.body)) : undefined })

    if (url === '/demo-api/steps') return respond({ steps: STEPS })
    if (url === '/demo-api/status') {
      return respond({ active: null, recent: [], script_available: true })
    }
    // No /stream route: this fixture exists to exercise the polling cursor
    // against a runner that serves its log from a real byte buffer, and the
    // fallback is what puts the panel on that path.
    if (url.startsWith('/demo-api/runs/') && url.includes('/stream')) {
      return respond('no stream endpoint', 404)
    }
    if (url.startsWith('/demo-api/runs/') && url.includes('/log')) {
      const offset = Number(new URL(url, 'http://x').searchParams.get('offset') ?? 0)
      if (logLatencyMs) await sleep(logLatencyMs)
      // Exactly the server's semantics: slice from the requested offset.
      const chunk = logBuffer.slice(offset)
      return respond({
        run_id: 'run-1',
        offset,
        next_offset: logBuffer.length,
        chunk,
        truncated: false,
        eof: runPolls > runningPolls,
      })
    }
    if (url.startsWith('/demo-api/runs/')) {
      runPolls += 1
      return respond(
        runPolls > runningPolls
          ? runView({ status: finalStatus, exit_code: 1 })
          : runView({ status: 'running' }),
      )
    }
    if (url === '/demo-api/runs') return respond(runView({ status: 'running' }), 202)
    if (url === '/demo-api/reset') return respond(runView({ step_id: '5', kind: 'reset' }), 202)
    return respond({ agents: [cardvault()], namespaces: [FLUX_NS] })
  }) as unknown as typeof fetch
}

function occurrences(haystack: string, needle: string): number {
  return haystack.split(needle).length - 1
}

describe('the run log is not duplicated when the runner is slower than the poll', () => {
  // Andy's reset, 2026-08-03: the script emits its banner exactly once, but the
  // instructor panel showed it twice.
  //
  //   [supercred] step 5: tearing down supercred demo resources
  //   [supercred] step 5: tearing down supercred demo resources
  //
  // setInterval does not wait for the previous tick, and the cursor advances
  // only once a response comes back. Any read slower than POLL_MS therefore
  // overlaps the next one, both ticks send the same offset, the server honestly
  // returns the same bytes twice, and both append.
  const BANNER = '[supercred] step 5: tearing down supercred demo resources\n'

  it('shows a line once even when each log read outlives the poll interval', async () => {
    mockRunnerServingRealLog({ logBuffer: BANNER, logLatencyMs: 800, runningPolls: 3 })
    await readyPanel()
    // Let the page's own discovery settle first. While it is still in flight the
    // parent re-renders, which tears down and rebuilds the poll effect -- and the
    // rebuilt effect's `stopped` flag happens to swallow the duplicate append.
    // On a quiescent page (an instructor who loaded the tab and then pressed a
    // button) nothing tears the effect down, and the duplicate lands. That is
    // the case an instructor is actually in, so it is the case under test.
    await new Promise(resolve => setTimeout(resolve, 400))
    await userEvent.click(await screen.findByTestId('supercred-run-step-5'))

    await waitFor(
      () => expect(screen.getByTestId('supercred-run-log')).toHaveTextContent('tearing down'),
      { timeout: 8000 },
    )
    // Let every overlapping in-flight read land before counting.
    await new Promise(resolve => setTimeout(resolve, 2500))

    const shown = screen.getByTestId('supercred-run-log').textContent ?? ''
    expect(occurrences(shown, 'tearing down supercred demo resources')).toBe(1)
  }, 20000)
})
