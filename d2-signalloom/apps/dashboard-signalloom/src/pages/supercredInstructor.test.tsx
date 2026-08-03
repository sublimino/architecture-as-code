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

// ─── The existing UI is untouched ─────────────────────────────────────────────

describe('the credential-lifecycle UI still works alongside the new controls', () => {
  it('keeps the lifecycle, credential and discovery sections rendering', async () => {
    mockRunner()
    await readyPanel()
    await userEvent.click(screen.getByRole('button', { name: /Refresh Agents/ }))

    expect(await screen.findByTestId('supercred-lifecycle')).toBeInTheDocument()
    expect(screen.getByTestId('supercred-lifecycle-steps')).toBeInTheDocument()
    expect(screen.getByTestId('supercred-credentials')).toBeInTheDocument()
    expect(screen.getByTestId('supercred-discovery-summary')).toBeInTheDocument()
    expect(screen.getByTestId('supercred-architecture')).toBeInTheDocument()
  })

  it('keeps the six lifecycle steps for a non-superadmin too', async () => {
    appCtx.superadmin = false
    mockRunner()
    await readyPanel()
    await userEvent.click(screen.getByRole('button', { name: /Refresh Agents/ }))
    await screen.findByTestId('supercred-lifecycle')
    for (let i = 1; i <= 6; i++) {
      expect(screen.getByTestId(`lifecycle-step-${i}`)).toBeInTheDocument()
    }
  })
})
