/**
 * SignalFusionPage — the Signal Fusion three-act demo page.
 *
 * Built on the same vocabulary as SuperCredInstructorPanel, because both pages
 * drive the SAME demo runner through the same shapes and an instructor should
 * not have to learn two demos' worth of behaviour: HelpHint beside every
 * control that mutates the cluster, PixelLoader while an act is in flight,
 * ButtonWait inside the act that is running, StreamingLogBlock for output, and
 * the shared presentation rules in components/demoRunPresentation.ts.
 *
 * Three acts, driven by scripts/signalfusion-demo.sh:
 *   1. Inferred  — deploy, seed collectors, correlate
 *   2. Attested  — kernel observation, detect what upper layers cannot see
 *   3. Issued    — promote to issued identity, revoke, close the gap
 *
 * Two things are deliberately NOT copied from SuperCred:
 *
 *   * the superadmin split. SuperCred renders a phase-status list for everyone
 *     and the mutating controls only for superadmins. Adding that here would
 *     change who can run this demo, which is an access decision and not a
 *     design-system one — and the runner enforces its own access regardless.
 *     So there is one act list carrying both the state and the control.
 *   * the opt-in SSE log transport. It exists in SuperCred so the streaming
 *     pattern can be exercised and judged; it is off by default there, has a
 *     first-byte watchdog for a failure mode that is silent, and duplicating
 *     that machinery to leave it switched off would be cost without a reader.
 *     The waiting read below is the transport of record for both demos.
 */
import { useState, useCallback, useEffect, useRef, type CSSProperties } from 'react'
import { colors } from '../styles/tokens'
import { Section, StatCard, Pill } from '../components/DashKit'
import HelpHint from '../components/HelpHint'
import PixelLoader from '../components/PixelLoader'
import ButtonWait from '../components/ButtonWait'
import LoadingState from '../components/LoadingState'
import StreamingLogBlock from '../components/StreamingLogBlock'
import {
  RUN_STATUS_COLORS,
  describeRunnerError,
  logTail,
  runStartedAt,
  runStatusTone,
} from '../components/demoRunPresentation'
import { useAuth0 } from '../auth/oidc'
import {
  fetchSignalFusionSteps,
  fetchSignalFusionStatus,
  fetchSignalFusionRun,
  fetchSignalFusionRunLog,
  startSignalFusionRun,
  resetSignalFusion,
  shellCommandForAct,
} from '../api/signalFusionDemo'
import type {
  DemoStep,
  DemoRunView,
  DemoRunLogChunk,
  DemoRunnerStatus,
} from '../api/signalFusionDemo'
import { weaveApi } from '../api/weaveApi'
import type {
  ProvisionalActor,
  CoverageStatement,
  FidelityTier,
} from '../api/weaveApi'
import { isRunActive, isRunFailure } from '../api/demoRunner'

// ─── Constants ──────────────────────────────────────────────────────────────

export const SIGNAL_FUSION_PAGE_TITLE = 'Signal Fusion Demo'

/**
 * The acts, keyed the way the RUNNER keys them.
 *
 * These used to read 'inferred' / 'attested' / 'issued'. demo_runner.py's
 * SIGNAL_FUSION_STEPS registry is keyed '1' / '2' / '3', and
 * scripts/signalfusion-demo.sh dispatches on `case "${1:-}" in 1) 2) 3)`, so
 * every lookup missed against a live runner and the per-act help below was
 * structurally unreachable. It failed silently rather than loudly, because the
 * code falls back to the runner's one-line description — which is the right
 * length for a tooltip and the wrong length for someone about to press a
 * control that mutates a shared cluster in front of a room.
 *
 * signalFusionInstructor.test.tsx pins these keys against this list, and
 * d2-signalloom/test/signalfusion-runner-contract.bats joins the list to the
 * runner's registry, so neither end can be re-keyed on its own.
 */
export const SIGNAL_FUSION_ACT_IDS = ['1', '2', '3'] as const

export interface ActDescription {
  /** Fallback name, used when /demo-api is not answering with the real titles. */
  title: string
  subtitle: string
  /** What the act DOES, and what the audience should watch change. */
  hint: string
}

export const ACT_DESCRIPTIONS: Record<string, ActDescription> = {
  '1': {
    title: 'Inferred',
    subtitle: 'Deploy, seed collectors, correlate — surface an actor no single layer identified',
    hint: 'Deploys signal collectors across the estate, ingests observations from multiple layers, and runs correlation to surface provisional actors. Watch the actors panel for new entries with cross-layer evidence chains.',
  },
  '2': {
    title: 'Attested',
    subtitle: 'Kernel observation — detect the agent the network and application layers cannot see',
    hint: 'Activates eBPF-based kernel observation to detect behaviours invisible to network and application layers. The coverage panel updates to show the newly covered layer, and actor confidence scores rise as kernel evidence corroborates existing signals.',
  },
  '3': {
    title: 'Issued',
    subtitle: 'Promote to issued identity, revoke — close the detection gap with accountability',
    hint: 'Promotes the highest-confidence provisional actor to an issued identity in the agent registry, then revokes its credentials. The actor moves from "actionable" to "promoted" and the coverage statement updates to reflect the closed gap.',
  },
}

const FIDELITY_COLORS: Record<FidelityTier, string> = {
  definitive: 'var(--teal)',
  strong: 'var(--cyan)',
  suggestive: 'var(--amber)',
  circumstantial: 'var(--muted)',
}

/** How often we poll the run status while active. */
const POLL_MS = 500

/** How long the log read may block waiting for new output. */
const LOG_WAIT_SECONDS = 3

/** Floor between log reads when the runner answers immediately. */
const LOG_IDLE_FLOOR_MS = 300

/** Max reads during post-run drain. */
const MAX_DRAIN_READS = 20

// ─── Styles ─────────────────────────────────────────────────────────────────

/**
 * A control and the "?" that explains it, bound into one flex item.
 *
 * `nowrap` is load-bearing, exactly as it is in SuperCredInstructorPanel: a
 * wrap landing between a button and its hint puts the "?" beside a control it
 * has nothing to do with.
 */
const CONTROL_WITH_HINT: CSSProperties = {
  display: 'inline-flex', alignItems: 'center', gap: 6, flexWrap: 'nowrap',
}

const actRow: CSSProperties = {
  display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between',
  gap: 12, padding: '10px 14px', borderRadius: 6,
  background: 'var(--surface)', border: '1px solid var(--border)',
}

const noticeStyle: CSSProperties = {
  marginTop: 12, padding: '10px 14px', borderRadius: 6, fontSize: 12, lineHeight: 1.7,
  background: 'color-mix(in srgb, var(--amber) 10%, transparent)',
  border: '1px solid color-mix(in srgb, var(--amber) 35%, transparent)',
  color: colors.amber,
}

const errorBanner: CSSProperties = {
  background: 'color-mix(in srgb, var(--error) 10%, transparent)',
  border: '1px solid color-mix(in srgb, var(--error) 30%, transparent)',
  borderRadius: 8, padding: '12px 16px', marginBottom: 16,
  color: 'var(--text)', fontSize: 13,
}

/**
 * Reserved width on the act buttons.
 *
 * ButtonWait replaces the button's text with a fixed-width loader, so without
 * a floor here the control shrinks the moment it is pressed and drags the row
 * sideways — which reads to a room as a fault. See ButtonWait's decision 2.
 */
const ACT_BUTTON: CSSProperties = {
  fontSize: 12, padding: '6px 12px', minWidth: 104,
  display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
}

// ─── Component ──────────────────────────────────────────────────────────────

export default function SignalFusionPage() {
  const { getAccessTokenSilently } = useAuth0()

  // ─ Demo runner state
  const [steps, setSteps] = useState<DemoStep[]>([])
  const [status, setStatus] = useState<DemoRunnerStatus | null>(null)
  const [activeRun, setActiveRun] = useState<DemoRunView | null>(null)
  const [log, setLog] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [runnerError, setRunnerError] = useState<string | null>(null)
  const [loadPhase, setLoadPhase] = useState<'loading' | 'success' | 'error'>('loading')
  const [resetArmed, setResetArmed] = useState(false)

  // The log cursor is a stream position, not render state: advancing it must
  // not schedule a render, and the poll loop must read the latest value.
  const offsetRef = useRef(0)

  // ─ Results state
  const [actors, setActors] = useState<ProvisionalActor[]>([])
  const [coverage, setCoverage] = useState<CoverageStatement | null>(null)

  // ─── Runner status ──────────────────────────────────────────────────────

  /**
   * Re-read the runner's own account of what is happening.
   *
   * A terminal run already on screen is NOT replaced by whatever `status`
   * reports as active: the run that just failed is the thing the instructor is
   * reading, and dropping it for a fresher record erases the exit code and the
   * log tail mid-sentence.
   */
  const loadStatus = useCallback(async () => {
    try {
      const next = await fetchSignalFusionStatus(await getAccessTokenSilently())
      setStatus(next)
      setRunnerError(null)
      // Adopt a run another instructor (or a previous page load) started, so
      // two browsers watching the same demo agree about what is happening.
      setActiveRun(current => (current && !isRunActive(current) ? current : next.active))
      return next
    } catch (err) {
      setRunnerError(err instanceof Error ? err.message : 'Signal Fusion runner unavailable')
      return null
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    let cancelled = false
    void (async () => {
      try {
        const token = await getAccessTokenSilently()
        const [stepResult, statusResult] = await Promise.allSettled([
          fetchSignalFusionSteps(token),
          fetchSignalFusionStatus(token),
        ])
        if (cancelled) return
        if (stepResult.status === 'fulfilled') setSteps(stepResult.value)
        if (statusResult.status === 'fulfilled') {
          setStatus(statusResult.value)
          setActiveRun(statusResult.value.active)
          setRunnerError(null)
          setLoadPhase('success')
        } else {
          setRunnerError(
            statusResult.reason instanceof Error ? statusResult.reason.message : 'Failed to fetch',
          )
          setLoadPhase('error')
        }
      } catch (err) {
        if (cancelled) return
        setRunnerError(err instanceof Error ? err.message : 'Failed to fetch')
        setLoadPhase('error')
      }
    })()
    return () => { cancelled = true }
  }, [getAccessTokenSilently])

  // ─── Results ────────────────────────────────────────────────────────────

  const loadResults = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const [actorResult, coverageResult] = await Promise.allSettled([
        weaveApi.getActors(token),
        weaveApi.getCoverage(token),
      ])
      if (actorResult.status === 'fulfilled') setActors(actorResult.value)
      if (coverageResult.status === 'fulfilled') setCoverage(coverageResult.value)
    } catch {
      // Results are supplementary — a failure here should not block the demo.
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    void loadResults()
  }, [loadResults])

  // ─── Log chunk handler ──────────────────────────────────────────────────

  /**
   * Append a chunk, but only if it starts exactly at the cursor.
   *
   * Two readers share `offsetRef` — the waiting loop and `drainLog` — and
   * neither holds a lock, so a response can land that no longer describes the
   * cursor's position: a straggler assigning an older `next_offset` drags the
   * cursor backwards and the same bytes are printed twice. The server echoes
   * the offset it served, so the check is exact and needs no locking.
   */
  const applyLogChunk = useCallback((chunk: DemoRunLogChunk): boolean => {
    if (chunk.offset !== offsetRef.current) return false
    if (chunk.chunk) setLog(prev => prev + chunk.chunk)
    offsetRef.current = chunk.next_offset
    return true
  }, [])

  /**
   * Read whatever output landed after the run finished.
   *
   * The last poll almost always lands before the script's final lines are
   * flushed, and those lines are exactly the ones that explain a failure.
   */
  const drainLog = useCallback(async (runId: string) => {
    try {
      for (let read = 0; read < MAX_DRAIN_READS; read++) {
        const before = offsetRef.current
        const chunk = await fetchSignalFusionRunLog(runId, before, await getAccessTokenSilently())
        // A rejected chunk means a concurrent read moved the cursor while this
        // one was in flight. Re-read rather than break, so the tail is not
        // truncated; MAX_DRAIN_READS bounds it.
        if (!applyLogChunk(chunk)) continue
        if (offsetRef.current === before) break
        if (chunk.eof) break
      }
    } catch {
      /* the tail is best effort — the run status is the authoritative outcome */
    }
  }, [applyLogChunk, getAccessTokenSilently])

  const finishRun = useCallback(async (run: DemoRunView) => {
    await drainLog(run.run_id)
    // The act changed the cluster, so the projections below it are stale.
    await loadResults()
    await loadStatus()
  }, [drainLog, loadResults, loadStatus])

  const runId = activeRun?.run_id ?? null
  const running = isRunActive(activeRun)

  /**
   * Read the log with a waiting request, re-issuing as each one returns.
   *
   * A self-rescheduling loop rather than a setInterval, and that difference is
   * the point: an interval that fires whether or not the previous read came
   * back overlaps its own reads, both send the same offset, and the server
   * honestly returns the same bytes twice.
   */
  useEffect(() => {
    if (!running || !runId) return
    let stopped = false
    const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))

    void (async () => {
      while (!stopped) {
        const startedAt = Date.now()
        try {
          const chunk = await fetchSignalFusionRunLog(
            runId, offsetRef.current, await getAccessTokenSilently(), LOG_WAIT_SECONDS,
          )
          if (stopped) return
          // Progress means bytes that reached the screen. A read can fail to
          // make progress two ways and both must be paced: an empty chunk (a
          // runner that ignored `wait`, since an unknown query parameter is not
          // an error), or a chunk refused for not starting at the cursor.
          const advanced = applyLogChunk(chunk) && chunk.chunk !== ''
          if (!advanced) {
            const elapsed = Date.now() - startedAt
            if (elapsed < LOG_IDLE_FLOOR_MS) await sleep(LOG_IDLE_FLOOR_MS - elapsed)
          }
        } catch {
          if (stopped) return
          await sleep(LOG_IDLE_FLOOR_MS)
        }
      }
    })()

    return () => { stopped = true }
  }, [running, runId, applyLogChunk, getAccessTokenSilently])

  // The run's STATUS only. The log is read by the waiting loop above, leaving
  // this interval to do the one job it is good at: noticing, within half a
  // second, that the run has reached a terminal state.
  useEffect(() => {
    if (!running || !runId) return
    let stopped = false
    const timer = setInterval(() => {
      void (async () => {
        try {
          const run = await fetchSignalFusionRun(runId, await getAccessTokenSilently())
          if (stopped) return
          setActiveRun(run)
          if (!isRunActive(run)) await finishRun(run)
        } catch (err) {
          if (stopped) return
          setError(err instanceof Error ? err.message : 'Lost track of the running act')
        }
      })()
    }, POLL_MS)
    return () => {
      stopped = true
      clearInterval(timer)
    }
  }, [running, runId, finishRun, getAccessTokenSilently])

  // ─── Starting something ─────────────────────────────────────────────────

  const startRun = useCallback(async (start: () => Promise<DemoRunView>) => {
    setError(null)
    setLog('')
    offsetRef.current = 0
    try {
      const run = await start()
      setActiveRun(run)
      // A run that came back already terminal never gets a poll tick, so its
      // output would never be drained and its outcome never recorded.
      if (!isRunActive(run)) await finishRun(run)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not start the act')
    }
  }, [finishRun])

  // ─── Page title ─────────────────────────────────────────────────────────

  useEffect(() => {
    const previous = document.title
    document.title = SIGNAL_FUSION_PAGE_TITLE
    return () => { document.title = previous }
  }, [])

  // ─── Derived act state ──────────────────────────────────────────────────

  const scriptAvailable = status?.script_available === true
  // Both the acts and the reset execute the script, so both are blocked while
  // one is in flight and while the runner has nothing to execute.
  const runsBlocked = running || !scriptAvailable

  /**
   * The steps to render — the runner's, or the three we know exist.
   *
   * Without /demo-api the titles are unknown but the acts are not, and a blank
   * panel is indistinguishable from a broken page.
   */
  const displaySteps: DemoStep[] = steps.length > 0
    ? steps
    : SIGNAL_FUSION_ACT_IDS.map(id => ({
        step_id: id,
        title: ACT_DESCRIPTIONS[id].title,
        description: ACT_DESCRIPTIONS[id].subtitle,
      }))

  // A reset is a verified teardown boundary, not a fourth act. The runner keeps
  // its history for auditability, but presenting acts from before the newest
  // reset as current state makes a fresh lifecycle look completed.
  const latestRun = activeRun ?? status?.recent[0] ?? null
  const resetVerified = latestRun?.kind === 'reset' && latestRun.status === 'succeeded'
  // A SUCCEEDED reset, specifically. SuperCred's equivalent cuts at the latest
  // reset of any outcome, which discards the acts before a teardown that did
  // not happen — so an instructor whose reset failed sees a demo that looks
  // un-started while the estate still carries everything act 1 deployed. The
  // badge states a fact about run history ("the last run of act 1 succeeded"),
  // which stays true whatever the failed reset did or did not remove.
  const latestResetIndex =
    status?.recent.findIndex(run => run.kind === 'reset' && run.status === 'succeeded') ?? -1
  const currentLifecycleRuns = latestResetIndex >= 0
    ? status!.recent.slice(0, latestResetIndex)
    : status?.recent ?? []

  /**
   * The most recent run for an act — active first, then the runner's history.
   *
   * `kind !== 'reset'` is not belt-and-braces here the way it would be for
   * SuperCred: demo_runner.py sets SIGNAL_FUSION_RESET_STEP_ID = "3", the same
   * step id as the Issued act, so a reset matches act 3 on step_id alone and
   * act 3 would report the teardown's outcome as its own.
   */
  function runForAct(stepId: string): DemoRunView | null {
    if (resetVerified) return null
    if (activeRun && activeRun.kind !== 'reset' && activeRun.step_id === stepId) return activeRun
    // `recent` is newest-first, so the first match is the latest attempt.
    return currentLifecycleRuns.find(r => r.kind !== 'reset' && r.step_id === stepId) ?? null
  }

  const failed = isRunFailure(activeRun)

  // What the in-flight indicator says. A reset is not an act, so it gets no
  // act number; an act whose title the runner never returned still gets its
  // number, which is the part the instructor is watching for.
  const runningStep = displaySteps.find(step => step.step_id === activeRun?.step_id)
  const runningLabel = activeRun?.kind === 'reset'
    ? 'Resetting the demo'
    : `Act ${activeRun?.step_id ?? '?'}${runningStep ? ` · ${runningStep.title}` : ''}`

  // What the log block's header names. Present tense would be wrong here in a
  // way it is not above: this header outlives the run, so "Resetting the demo"
  // would still claim a teardown is under way minutes after it finished. The
  // status word beside it carries the tense.
  const logTitle = activeRun
    ? activeRun.kind === 'reset'
      ? 'Reset'
      : `Act ${activeRun.step_id}${runningStep ? ` · ${runningStep.title}` : ''}`
    : undefined

  // ─── Render ─────────────────────────────────────────────────────────────

  return (
    <div style={{ margin: '0 auto', padding: '32px 24px' }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 6 }}>{SIGNAL_FUSION_PAGE_TITLE}</h1>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 16, lineHeight: 1.6, maxWidth: 760 }}>
        Multi-layer signal correlation: converge observations from network, identity, application,
        and kernel layers to surface actors no single layer can see alone.
      </p>

      {/* A failed runner call has three very different causes, and reporting
          all of them as "not reachable" sends the instructor to debug a network
          that is fine. describeRunnerError is shared with SuperCred. */}
      {runnerError && (
        <div data-testid="sf-runner-error" style={errorBanner}>
          {describeRunnerError(runnerError)}
        </div>
      )}

      {error && (
        <div data-testid="sf-error" style={errorBanner}>
          {error}
        </div>
      )}

      {/* Instructor controls — three acts */}
      <div data-testid="sf-instructor" className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
          <h2 style={{ fontSize: 15, fontWeight: 600, marginBottom: 4 }}>Demo Acts</h2>
          <LoadingState
            status={loadPhase}
            label="demo acts"
            error={runnerError}
            testId="sf-acts-load-state"
          />
        </div>
        <p style={{ fontSize: 12, color: 'var(--muted)', margin: '0 0 12px', lineHeight: 1.5 }}>
          Each act builds on the previous. They mutate a shared cluster, so they run one at a
          time — every control is locked while an act is in flight.
        </p>

        {resetVerified && (
          <p data-testid="sf-clean-state" style={{ fontSize: 12, color: colors.tealLoom, margin: '0 0 12px', lineHeight: 1.5 }}>
            Clean state verified — teardown completed; no act is currently active.
          </p>
        )}

        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {displaySteps.map(step => {
            const run = runForAct(step.step_id)
            const desc = ACT_DESCRIPTIONS[step.step_id]
            const thisActRunning = running && activeRun?.kind !== 'reset' && activeRun?.step_id === step.step_id

            return (
              <div key={step.step_id} data-testid={`sf-act-row-${step.step_id}`} style={actRow}>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                    <span style={{ fontSize: 11, color: 'var(--muted)', letterSpacing: '0.05em' }}>
                      Act {step.step_id}
                    </span>
                    {/* The title is its own node so it is addressable on its
                        own — an act's name is what an instructor says out loud. */}
                    <span style={{ fontWeight: 600, fontSize: 13 }}>{step.title}</span>
                    <span
                      data-testid={`sf-act-status-${step.step_id}`}
                      style={{
                        fontSize: 10, fontWeight: 600, textTransform: 'uppercase',
                        padding: '1px 6px', borderRadius: 3,
                        border: `1px solid ${run ? RUN_STATUS_COLORS[run.status] ?? 'var(--border)' : 'var(--border)'}`,
                        color: run ? runStatusTone(run.status) : 'var(--muted)',
                      }}
                    >
                      {run ? run.status : 'not run'}
                    </span>
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2, lineHeight: 1.4 }}>
                    {desc?.subtitle ?? step.description}
                  </div>
                </div>

                {/* Button and hint are one flex item so a wrap can never leave
                    the "?" on the line above the control it explains. */}
                <span style={CONTROL_WITH_HINT}>
                  <button
                    className="btn btn-secondary"
                    data-testid={`sf-act-${step.step_id}`}
                    title={desc?.hint ?? step.description}
                    onClick={() => void startRun(async () =>
                      startSignalFusionRun(step.step_id, await getAccessTokenSilently()))}
                    disabled={runsBlocked}
                    style={{
                      ...ACT_BUTTON,
                      borderColor: thisActRunning ? 'var(--cyan)' : undefined,
                      color: thisActRunning ? 'var(--cyan)' : undefined,
                    }}
                  >
                    {thisActRunning
                      ? <ButtonWait testId={`sf-act-${step.step_id}-wait`} label={`Running act ${step.step_id}`} />
                      : `Run act ${step.step_id}`}
                  </button>
                  {desc && (
                    <HelpHint
                      label={`What act ${step.step_id} does to the cluster`}
                      testId={`sf-act-${step.step_id}-help`}
                    >
                      {desc.hint}
                    </HelpHint>
                  )}
                </span>
              </div>
            )
          })}
        </div>

        {/* Reset is destructive, so it arms before it fires. Gap is wider than
            CONTROL_WITH_HINT's: those two distances are what tell an instructor
            which "?" belongs to which button. */}
        <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', alignItems: 'center', marginTop: 12 }}>
          {!resetArmed && (
            <span style={CONTROL_WITH_HINT}>
              <button
                className="btn btn-secondary"
                data-testid="sf-reset-btn"
                onClick={() => setResetArmed(true)}
                disabled={runsBlocked}
                style={{ fontSize: 12, padding: '6px 14px', color: colors.red, borderColor: colors.red }}
              >
                Reset demo
              </button>
              <HelpHint label="What Reset demo does" testId="sf-reset-help" tone={colors.red}>
                Runs the Signal Fusion teardown and clears the current lifecycle display. Historical run records remain available in runner history.
              </HelpHint>
            </span>
          )}
          {resetArmed && (
            <>
              <span data-testid="sf-reset-prompt" style={{ fontSize: 12, color: colors.amber, alignSelf: 'center' }}>
                Reset tears the demo down and returns the estate to a clean state. Sure?
              </span>
              <span style={CONTROL_WITH_HINT}>
                <button
                  className="btn btn-secondary"
                  data-testid="sf-reset-confirm"
                  onClick={() => {
                    setResetArmed(false)
                    void startRun(async () => resetSignalFusion(await getAccessTokenSilently()))
                  }}
                  disabled={runsBlocked}
                  style={{ fontSize: 12, padding: '6px 14px', color: colors.red, borderColor: colors.red }}
                >
                  Yes, reset the demo
                </button>
                <HelpHint label="What Reset demo does" testId="sf-reset-confirm-help" tone={colors.red}>
                  Runs the Signal Fusion teardown and clears the current lifecycle display. Historical run records remain available in runner history.
                </HelpHint>
              </span>
              {/* Cancel stays outside the group so the "?" is not stranded
                  between the two buttons. */}
              <button
                className="btn btn-secondary"
                data-testid="sf-reset-cancel"
                onClick={() => setResetArmed(false)}
                style={{ fontSize: 12, padding: '6px 14px' }}
              >
                Cancel
              </button>
            </>
          )}
        </div>

        {/* Every control above is disabled and an act can run for minutes.
            Without this the panel is indistinguishable from one that has hung —
            which, on stage, is the moment an instructor starts clicking things.
            Presentation only: it reads `running` and the runner's start stamp. */}
        {running && activeRun && (
          <div style={{ marginTop: 12 }}>
            <PixelLoader
              testId="sf-run-progress"
              label={runningLabel}
              startedAt={runStartedAt(activeRun)}
            />
          </div>
        )}

        {!scriptAvailable && (
          <div data-testid="sf-script-unavailable" style={noticeStyle}>
            <div>
              {runnerError
                ? describeRunnerError(runnerError)
                : 'The demo runner is up but the Signal Fusion script is not available to it.'}{' '}
              Run the acts from a shell instead:
            </div>
            <ul style={{ margin: '6px 0 0', paddingLeft: 18, fontFamily: 'monospace', color: 'var(--muted)' }}>
              {displaySteps.map(step => (
                <li key={step.step_id} data-testid={`sf-shell-command-${step.step_id}`}>
                  {shellCommandForAct(step.step_id)}
                </li>
              ))}
            </ul>
          </div>
        )}

        {activeRun && (
          <div data-testid="sf-run-status" style={{ marginTop: 12, fontSize: 12, color: 'var(--muted)', lineHeight: 1.6 }}>
            {activeRun.kind === 'reset' ? 'Reset' : `Act ${activeRun.step_id}`} —{' '}
            <strong style={{ color: runStatusTone(activeRun.status) }}>{activeRun.status}</strong>
            {activeRun.started_at && <> · started {activeRun.started_at}</>}
            {activeRun.finished_at && <> · finished {activeRun.finished_at}</>}
          </div>
        )}

        {failed && activeRun && (
          <div
            data-testid="sf-run-error"
            style={{
              marginTop: 12, padding: '10px 14px', borderRadius: 6, fontSize: 12, lineHeight: 1.6,
              background: 'color-mix(in srgb, var(--error) 8%, transparent)',
              border: '1px solid color-mix(in srgb, var(--error) 35%, transparent)',
              color: colors.red,
            }}
          >
            <div>
              {activeRun.kind === 'reset' ? 'Reset' : `Act ${activeRun.step_id}`} {activeRun.status} with exit code{' '}
              <strong data-testid="sf-run-exit-code">{activeRun.exit_code ?? 'unknown'}</strong>
              {activeRun.error ? ` — ${activeRun.error}` : ''}
            </div>
            <pre
              data-testid="sf-run-log-tail"
              style={{
                margin: '8px 0 0', padding: '8px 10px', borderRadius: 4, maxHeight: 200, overflow: 'auto',
                background: 'var(--surface)', color: 'var(--muted)', fontSize: 11, whiteSpace: 'pre-wrap',
              }}
            >
              {logTail(log) || 'The runner produced no output before it stopped.'}
            </pre>
          </div>
        )}

        {/* The RAW log goes in, escape bytes and all — the block strips them for
            display and hands the untouched string to its Copy button, which is
            the one artefact an instructor wants off this screen when an act
            fails. Mounted as soon as a run is live rather than when the first
            byte lands: act 1 can spend a long time in kubectl before it prints
            anything, and until it did the panel had every control greyed out
            and no log surface at all. The block says it is waiting rather than
            inventing a line, a timestamp or a progress figure. */}
        {(running || log !== '') && (
          <StreamingLogBlock
            testId="sf-log-output"
            label="Run log"
            title={logTitle}
            status={activeRun?.status}
            statusTone={activeRun ? runStatusTone(activeRun.status) : undefined}
            log={log}
            streaming={running}
            placeholder="Waiting for the runner's first output…"
            style={{ marginTop: 12 }}
          />
        )}
      </div>

      {/* Results Panel */}
      <div data-testid="sf-results-panel">
        {/* Coverage statement */}
        {coverage && (
          <section data-testid="sf-coverage" style={{ marginBottom: 16 }}>
            <Section title="Signal Coverage" hint={coverage.deployment_coverage}>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12, marginBottom: 12 }}>
                <StatCard
                  label="Covered Layers"
                  value={String(coverage.covered_layers.length)}
                  sub={`of 7 signal layers`}
                  accent={colors.tealLoom}
                />
                <StatCard
                  label="Blind Spots"
                  value={String(coverage.blind_spots.length)}
                  sub="uncovered layers"
                  accent={coverage.blind_spots.length > 0 ? colors.amber : colors.tealLoom}
                />
                <StatCard
                  label="Closeable by Issuance"
                  value={String(coverage.closeable_by_issuance.length)}
                  sub="gaps closeable"
                  accent={colors.cyanLoom}
                />
              </div>
              {coverage.blind_spots.length > 0 && (
                <div className="card" style={{ padding: '12px 16px' }}>
                  <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 6 }}>Blind Spots</div>
                  {coverage.blind_spots.map(bs => (
                    <div key={bs.id} style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.6 }}>
                      <Pill label={bs.layer.replace(/_/g, ' ')} />{' '}
                      <span>{bs.description}</span>
                    </div>
                  ))}
                </div>
              )}
            </Section>
          </section>
        )}

        {/* Discovered Actors */}
        {actors.length > 0 && (
          <section style={{ marginBottom: 16 }}>
            <Section title="Discovered Actors" hint={`${actors.length} actor${actors.length !== 1 ? 's' : ''} correlated`}>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                {actors.map(actor => (
                  <div
                    key={actor.id}
                    data-testid={`sf-actor-${actor.id}`}
                    className="card"
                    style={{ padding: '14px 18px' }}
                  >
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 8 }}>
                      <div>
                        <div style={{ fontWeight: 600, fontSize: 14 }}>
                          {actor.display_name ?? actor.id}
                        </div>
                        <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
                          {actor.correlation_keys.join(' | ')}
                        </div>
                      </div>
                      <div style={{ textAlign: 'right' }}>
                        <div style={{ fontSize: 22, fontWeight: 700, color: confidenceColor(actor.confidence) }}>
                          {Math.round(actor.confidence * 100)}%
                        </div>
                        <Pill label={actor.status} />
                      </div>
                    </div>

                    {/* Evidence chain */}
                    {actor.evidence_chain.length > 0 && (
                      <div style={{ borderTop: '1px solid var(--border)', paddingTop: 8 }}>
                        <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', marginBottom: 4, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                          Evidence Chain ({actor.evidence_chain.length})
                        </div>
                        {actor.evidence_chain.map((link, i) => (
                          <div key={`${link.observation_id}-${i}`} style={{
                            display: 'flex', gap: 8, alignItems: 'center',
                            fontSize: 12, color: 'var(--text)', lineHeight: 1.6,
                          }}>
                            <span style={{ color: FIDELITY_COLORS[link.fidelity], fontWeight: 600, fontSize: 10, textTransform: 'uppercase', minWidth: 80 }}>
                              {link.fidelity}
                            </span>
                            <Pill label={link.layer.replace(/_/g, ' ')} />
                            <span style={{ color: 'var(--muted)' }}>{link.contribution}</span>
                          </div>
                        ))}
                      </div>
                    )}
                  </div>
                ))}
              </div>
            </Section>
          </section>
        )}
      </div>
    </div>
  )
}

// ─── Helpers ────────────────────────────────────────────────────────────────

function confidenceColor(confidence: number): string {
  if (confidence >= 0.8) return 'var(--teal)'
  if (confidence >= 0.5) return 'var(--amber)'
  return 'var(--muted)'
}
