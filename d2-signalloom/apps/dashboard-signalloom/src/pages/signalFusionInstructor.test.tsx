/**
 * Running the Signal Fusion three-act demo from the browser.
 *
 * SignalFusionPage.test.tsx covers that the page fetches, starts and renders.
 * This file covers the things an instructor ON STAGE cannot recover from, and
 * they are the same things supercredInstructor.test.tsx pins for the other
 * demo — deliberately, because both panels drive the SAME runner and an
 * instructor should not have to learn two demos' worth of behaviour:
 *
 *   * an act that can be fired twice, or fired while another is in flight;
 *   * a panel with every control greyed out and nothing saying why;
 *   * raw ANSI escape bytes on a projector;
 *   * a failure reported as "something went wrong" with no exit code;
 *   * a destructive reset with no confirmation;
 *   * a page reload mid-demo that forgets which acts have already run.
 *
 * The step ids here are '1', '2', '3' because that is what the runner emits:
 * demo_runner.py's SIGNAL_FUSION_STEPS registry is keyed '1'/'2'/'3' and
 * scripts/signalfusion-demo.sh dispatches on `case "${1:-}" in 1|2|3`. An
 * earlier fixture in this suite used 'inferred'/'attested'/'issued', which the
 * server has never produced.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest'
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

import SignalFusionPage, { SIGNAL_FUSION_ACT_IDS, ACT_DESCRIPTIONS } from './SignalFusionPage'
import * as sfDemo from '../api/signalFusionDemo'
import * as weaveApiModule from '../api/weaveApi'
import { LOG_TAIL_LINES } from '../components/demoRunPresentation'
import type { DemoStep, DemoRunView, DemoRunLogChunk, DemoRunnerStatus } from '../api/signalFusionDemo'

// ─── Fixtures ───────────────────────────────────────────────────────────────

const STEPS: DemoStep[] = [
  { step_id: '1', title: 'Inferred', description: 'Deploy, seed collectors, correlate' },
  { step_id: '2', title: 'Attested', description: 'Kernel observation' },
  { step_id: '3', title: 'Issued', description: 'Promote to issued identity, revoke' },
]

function runView(overrides: Partial<DemoRunView> = {}): DemoRunView {
  return {
    run_id: 'run-1',
    step_id: '1',
    kind: 'step',
    status: 'running',
    started_at: '2026-08-23T10:00:00Z',
    finished_at: null,
    exit_code: null,
    error: null,
    ...overrides,
  }
}

function logChunk(overrides: Partial<DemoRunLogChunk> = {}): DemoRunLogChunk {
  return { run_id: 'run-1', offset: 0, next_offset: 0, chunk: '', truncated: false, eof: true, ...overrides }
}

function status(overrides: Partial<DemoRunnerStatus> = {}): DemoRunnerStatus {
  return { active: null, recent: [], script_available: true, ...overrides }
}

function renderPage() {
  return render(
    <MemoryRouter>
      <SignalFusionPage />
    </MemoryRouter>,
  )
}

/** The acts row, once the runner's steps have landed. */
async function actsReady() {
  await waitFor(() => expect(screen.getByTestId('sf-act-1')).toBeInTheDocument())
}

beforeEach(() => {
  vi.restoreAllMocks()
  getAccessTokenSilently.mockResolvedValue('test-token')
  vi.spyOn(sfDemo, 'fetchSignalFusionSteps').mockResolvedValue(STEPS)
  vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(status())
  vi.spyOn(sfDemo, 'startSignalFusionRun').mockResolvedValue(runView())
  vi.spyOn(sfDemo, 'fetchSignalFusionRun').mockResolvedValue(runView())
  vi.spyOn(sfDemo, 'fetchSignalFusionRunLog').mockResolvedValue(logChunk())
  vi.spyOn(sfDemo, 'resetSignalFusion').mockResolvedValue(runView({ kind: 'reset', step_id: '3' }))
  vi.spyOn(weaveApiModule.weaveApi, 'getActors').mockResolvedValue([])
  vi.spyOn(weaveApiModule.weaveApi, 'getCoverage').mockResolvedValue(null as never)
})

// ─── The act ids are the runner's, not a second vocabulary ──────────────────

describe('the acts this page offers are the acts the runner has', () => {
  // The map used to be keyed 'inferred'/'attested'/'issued'. Every lookup
  // against a live runner missed, so the per-act help this page exists to show
  // was structurally unreachable — silently, because the code falls back to the
  // runner's one-line description rather than throwing.
  it('describes every act the runner registry defines, keyed the way the runner keys them', () => {
    expect(SIGNAL_FUSION_ACT_IDS).toEqual(['1', '2', '3'])
    expect(Object.keys(ACT_DESCRIPTIONS).sort()).toEqual([...SIGNAL_FUSION_ACT_IDS].sort())
    for (const id of SIGNAL_FUSION_ACT_IDS) {
      expect(ACT_DESCRIPTIONS[id].hint.length, `act ${id} needs a hint`).toBeGreaterThan(40)
      expect(ACT_DESCRIPTIONS[id].title.length, `act ${id} needs a title`).toBeGreaterThan(0)
    }
  })

  // Without /demo-api the titles are unknown, but the acts are not. A blank
  // panel is indistinguishable from a broken page; three named, disabled acts
  // say "the runner is not answering" and keep the demo's shape on screen.
  it('still names the three acts when the runner is unreachable', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionSteps').mockRejectedValue(new Error('Failed to fetch'))
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockRejectedValue(new Error('Failed to fetch'))

    renderPage()
    await actsReady()

    expect(screen.getByText('Inferred')).toBeInTheDocument()
    expect(screen.getByText('Attested')).toBeInTheDocument()
    expect(screen.getByText('Issued')).toBeInTheDocument()
    // …and they cannot be pressed, because there is nothing to press them at.
    expect(screen.getByTestId('sf-act-1')).toBeDisabled()
  })
})

// ─── The runner is not reachable: say which of the three things happened ────

describe('a runner that refuses is triaged, not just reported', () => {
  it('sends a stale session to sign in again rather than to debug the network', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockRejectedValue(
      new Error('Signal Fusion status failed: 401 — invalid_token'),
    )

    renderPage()

    const banner = await screen.findByTestId('sf-runner-error')
    expect(banner.textContent).toMatch(/sign out and back in/i)
    expect(banner.textContent).not.toMatch(/not reachable/i)
  })

  it('reports a transport failure as unreachable and quotes it', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockRejectedValue(new Error('Failed to fetch'))

    renderPage()

    const banner = await screen.findByTestId('sf-runner-error')
    expect(banner.textContent).toMatch(/not reachable/i)
    expect(banner.textContent).toContain('Failed to fetch')
  })
})

// ─── One act at a time, and the button says so ──────────────────────────────

describe('the cluster is shared, so an act cannot be fired twice', () => {
  it('locks every act and the reset while one is in flight', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(status({ active: runView() }))

    renderPage()
    await actsReady()

    for (const id of SIGNAL_FUSION_ACT_IDS) {
      expect(screen.getByTestId(`sf-act-${id}`), `act ${id}`).toBeDisabled()
    }
    expect(screen.getByTestId('sf-reset-btn')).toBeDisabled()
  })

  // The button that was pressed must look different from the two that were
  // not, or an instructor cannot tell whether the click registered.
  it('shows an in-button wait on the act that is running, and only on that one', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(
      status({ active: runView({ step_id: '2' }) }),
    )

    renderPage()
    await actsReady()

    await waitFor(() => expect(screen.getByTestId('sf-act-2-wait')).toBeInTheDocument())
    expect(screen.queryByTestId('sf-act-1-wait')).not.toBeInTheDocument()
    expect(screen.queryByTestId('sf-act-3-wait')).not.toBeInTheDocument()
  })

  // Replacing a button's text with a grid of squares removes the only thing
  // that named the control. ButtonWait carries the name in a hidden span.
  it('keeps the running act button named while its text is a loader', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(
      status({ active: runView({ step_id: '2' }) }),
    )

    renderPage()
    await actsReady()

    await waitFor(() => expect(screen.getByTestId('sf-act-2-wait')).toBeInTheDocument())
    expect(screen.getByTestId('sf-act-2')).toHaveAccessibleName(/running act 2/i)
  })

  // Every control is disabled and an act can run for minutes. Without this the
  // panel is indistinguishable from one that has hung.
  it('shows a loader with the runner’s own start time while an act runs', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(
      status({ active: runView({ started_at: '2026-08-23T10:00:00Z' }) }),
    )

    renderPage()
    await actsReady()

    await waitFor(() => expect(screen.getByTestId('sf-run-progress')).toBeInTheDocument())
    expect(screen.getByTestId('sf-run-progress-label').textContent).toMatch(/act 1/i)
  })

  it('hides the loader once nothing is running', async () => {
    renderPage()
    await actsReady()
    expect(screen.queryByTestId('sf-run-progress')).not.toBeInTheDocument()
  })
})

// ─── Per-act state survives a reload, because the runner remembers ──────────

describe('per-act state comes from the runner, not from this tab', () => {
  // An instructor who refreshes mid-demo — or opens the page on a second
  // screen — must see which acts have already run. Held only in component
  // state, that history is lost on every mount and the demo looks un-started.
  it('reads act outcomes out of the runner’s recent history on first load', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(
      status({
        recent: [
          runView({ run_id: 'r2', step_id: '2', status: 'failed', exit_code: 1, finished_at: 'x' }),
          runView({ run_id: 'r1', step_id: '1', status: 'succeeded', exit_code: 0, finished_at: 'x' }),
        ],
      }),
    )

    renderPage()
    await actsReady()

    await waitFor(() =>
      expect(screen.getByTestId('sf-act-status-1').textContent).toBe('succeeded'),
    )
    expect(screen.getByTestId('sf-act-status-2').textContent).toBe('failed')
    expect(screen.getByTestId('sf-act-status-3').textContent).toBe('not run')
  })

  // The runner's reset step id is "3" — the same id as the Issued act. A
  // reset run in `recent` therefore matches act 3 by step_id alone, and act 3
  // would report the teardown's outcome as its own.
  it('does not let a reset run masquerade as the act that shares its step id', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(
      status({
        recent: [
          runView({ run_id: 'r9', step_id: '3', kind: 'reset', status: 'failed', exit_code: 2, finished_at: 'x' }),
          runView({ run_id: 'r1', step_id: '1', status: 'succeeded', exit_code: 0, finished_at: 'x' }),
        ],
      }),
    )

    renderPage()
    await actsReady()

    // A failed reset is not a verified teardown, so the earlier acts stand…
    await waitFor(() =>
      expect(screen.getByTestId('sf-act-status-1').textContent).toBe('succeeded'),
    )
    // …and act 3 has not been run, whatever the reset did.
    expect(screen.getByTestId('sf-act-status-3').textContent).toBe('not run')
  })

  // A reset is a verified teardown boundary, not a fourth act. Showing acts
  // from before it as current makes a fresh lifecycle look completed.
  it('clears the lifecycle once a reset has succeeded', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(
      status({
        recent: [
          runView({ run_id: 'r9', step_id: '3', kind: 'reset', status: 'succeeded', exit_code: 0, finished_at: 'x' }),
          runView({ run_id: 'r1', step_id: '1', status: 'succeeded', exit_code: 0, finished_at: 'x' }),
        ],
      }),
    )

    renderPage()
    await actsReady()

    await waitFor(() => expect(screen.getByTestId('sf-clean-state')).toBeInTheDocument())
    expect(screen.getByTestId('sf-act-status-1').textContent).toBe('not run')
  })
})

// ─── The log is output, not bytes ───────────────────────────────────────────

describe('the run log is readable on a projector', () => {
  // The runner emits ANSI colour. Rendered raw, the escape bytes appear as
  // visible mojibake in front of an audience.
  it('strips the ANSI the runner emits instead of printing it', async () => {
    const coloured = `\u001b[32m[ok]\u001b[0m collectors deployed\n`
    vi.spyOn(sfDemo, 'fetchSignalFusionRunLog').mockResolvedValue(
      logChunk({ chunk: coloured, next_offset: coloured.length, eof: false }),
    )
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(status({ active: runView() }))

    renderPage()
    await actsReady()

    const block = await screen.findByTestId('sf-log-output')
    await waitFor(() => expect(block.textContent).toContain('collectors deployed'))
    expect(block.textContent).not.toContain(`\u001b`)
    expect(block.textContent).not.toContain('[32m')
  })

  // The one artefact an instructor wants off this screen when an act fails.
  it('offers the raw log for copying', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(status({ active: runView() }))

    renderPage()
    await actsReady()

    await waitFor(() => expect(screen.getByTestId('sf-log-output-copy')).toBeInTheDocument())
  })

  // Mounted when the act STARTS, not when the first byte lands: act 1 can
  // spend a long time in kubectl before printing, and an empty screen with
  // every control greyed out reads as a hang.
  it('says it is waiting rather than showing nothing while the runner is quiet', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(status({ active: runView() }))

    renderPage()
    await actsReady()

    const waiting = await screen.findByTestId('sf-log-output-waiting')
    expect(waiting.textContent).toMatch(/waiting/i)
  })

  // The header must name the act being watched and carry its status word,
  // because the block outlives the run.
  it('heads the log with the act it is the log of, and that act’s status', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(
      status({ active: runView({ step_id: '2' }) }),
    )

    renderPage()
    await actsReady()

    await waitFor(() =>
      expect(screen.getByTestId('sf-log-output-title').textContent).toMatch(/act 2.*attested/i),
    )
    expect(screen.getByTestId('sf-log-output-status').textContent).toBe('running')
  })

  it('shows no log block at all before anything has run', async () => {
    renderPage()
    await actsReady()
    expect(screen.queryByTestId('sf-log-output')).not.toBeInTheDocument()
  })
})

// ─── A failure explains itself ──────────────────────────────────────────────

describe('a failed act explains itself', () => {
  it('shows the exit code and the log tail, not a generic error', async () => {
    const output = Array.from({ length: 30 }, (_, i) => `step line ${i + 1}`).join('\n')
    vi.spyOn(sfDemo, 'fetchSignalFusionRunLog').mockResolvedValue(
      logChunk({ chunk: output, next_offset: output.length, eof: true }),
    )
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(status({ active: runView() }))
    vi.spyOn(sfDemo, 'fetchSignalFusionRun').mockResolvedValue(
      runView({ status: 'failed', exit_code: 3, finished_at: '2026-08-23T10:01:00Z', error: 'correlation refused' }),
    )

    renderPage()
    await actsReady()

    const failure = await screen.findByTestId('sf-run-error', undefined, { timeout: 4000 })
    expect(within(failure).getByTestId('sf-run-exit-code').textContent).toBe('3')
    expect(failure.textContent).toContain('correlation refused')

    const tail = within(failure).getByTestId('sf-run-log-tail')
    expect(tail.textContent).toContain('step line 30')
    expect(tail.textContent).not.toContain('step line 1\n')
    expect(tail.textContent?.split('\n')).toHaveLength(LOG_TAIL_LINES)
  })

  // A run that produced nothing is a different fact from a run whose output
  // was lost, and the panel must not present an empty box as either.
  it('says so when a failing act printed nothing at all', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(status({ active: runView() }))
    vi.spyOn(sfDemo, 'fetchSignalFusionRun').mockResolvedValue(
      runView({ status: 'failed', exit_code: 1, finished_at: '2026-08-23T10:01:00Z' }),
    )

    renderPage()
    await actsReady()

    const failure = await screen.findByTestId('sf-run-error', undefined, { timeout: 4000 })
    expect(within(failure).getByTestId('sf-run-log-tail').textContent)
      .toMatch(/produced no output/i)
  })

  it('paints a timed-out act as neither succeeded nor failed', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(
      status({
        recent: [runView({ step_id: '1', status: 'timed_out', exit_code: null, finished_at: 'x' })],
      }),
    )

    renderPage()
    await actsReady()

    await waitFor(() =>
      expect(screen.getByTestId('sf-act-status-1').textContent).toBe('timed_out'),
    )
  })
})

// ─── Reset is destructive, so it asks ───────────────────────────────────────

describe('reset tears the demo down, so it confirms first', () => {
  it('does not run a reset on the first click', async () => {
    const user = userEvent.setup()
    renderPage()
    await actsReady()

    await user.click(screen.getByTestId('sf-reset-btn'))

    expect(sfDemo.resetSignalFusion).not.toHaveBeenCalled()
    expect(screen.getByTestId('sf-reset-prompt')).toBeInTheDocument()
  })

  it('runs it on confirmation', async () => {
    const user = userEvent.setup()
    renderPage()
    await actsReady()

    await user.click(screen.getByTestId('sf-reset-btn'))
    await user.click(screen.getByTestId('sf-reset-confirm'))

    await waitFor(() => expect(sfDemo.resetSignalFusion).toHaveBeenCalledWith('test-token'))
  })

  it('backs out without running anything', async () => {
    const user = userEvent.setup()
    renderPage()
    await actsReady()

    await user.click(screen.getByTestId('sf-reset-btn'))
    await user.click(screen.getByTestId('sf-reset-cancel'))

    expect(sfDemo.resetSignalFusion).not.toHaveBeenCalled()
    expect(screen.queryByTestId('sf-reset-prompt')).not.toBeInTheDocument()
  })
})

// ─── The runner is up but has no script ─────────────────────────────────────

describe('a runner with no script says what to run instead', () => {
  // SuperCred points at `make demo-signalloom-supercred-N`. Signal Fusion has
  // no make target — the runner execs scripts/signalfusion-demo.sh directly
  // (demo_runner.py's DemoConfig.default_script) — so this names the script,
  // which is a command that exists. Naming a make target that does not is how
  // an instructor with a shell ends up worse off than with no advice at all.
  // d2-signalloom/test/signalfusion-runner-contract.bats joins this string to
  // the runner's own default_script so the two cannot drift.
  it('names the shell command per act and disables the buttons', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(
      status({ script_available: false }),
    )

    renderPage()
    await actsReady()

    const notice = await screen.findByTestId('sf-script-unavailable')
    for (const id of SIGNAL_FUSION_ACT_IDS) {
      expect(notice.textContent, `act ${id} command`).toContain(`scripts/signalfusion-demo.sh ${id}`)
    }
    expect(screen.getByTestId('sf-act-1')).toBeDisabled()
  })
})

// ─── Explaining itself ──────────────────────────────────────────────────────

describe('every act says what it will do before it is pressed', () => {
  it('carries a hint beside each act button', async () => {
    renderPage()
    await actsReady()

    for (const id of SIGNAL_FUSION_ACT_IDS) {
      expect(screen.getByTestId(`sf-act-${id}-help`), `act ${id} hint`).toBeInTheDocument()
    }
  })

  it('shows the hint text on demand', async () => {
    const user = userEvent.setup()
    renderPage()
    await actsReady()

    await user.click(screen.getByTestId('sf-act-2-help'))

    expect(screen.getByText(ACT_DESCRIPTIONS['2'].hint)).toBeInTheDocument()
  })
})

// ─── Loading, before anything has arrived ───────────────────────────────────

describe('the page says it is loading rather than looking empty', () => {
  it('shows a load state for the acts and settles it once they land', async () => {
    renderPage()

    expect(screen.getByTestId('sf-acts-load-state').textContent).toMatch(/loading/i)

    await actsReady()
    await waitFor(() =>
      expect(screen.getByTestId('sf-acts-load-state').textContent).toMatch(/refreshed/i),
    )
  })
})
