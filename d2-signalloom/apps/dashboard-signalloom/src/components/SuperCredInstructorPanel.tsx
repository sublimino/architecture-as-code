// Instructor controls for the SuperCredential demo.
//
// The demo used to be drivable only from a shell: `make demo-signalloom-
// supercred-N` against a cluster the audience cannot see. This panel puts the
// same five phases behind buttons, streams the script's output back, and points
// at the customer page where each phase's effect actually lands — so the whole
// demo can be run from the browser with the audience watching.
//
// Two audiences, one component:
//   * everyone sees the phase status and the "Show this on →" links;
//   * only superadmins see the buttons that mutate the cluster.
// Superadmin here is the same VISIBILITY control the sidebar uses (see
// auth/superadmin.ts) — the route stays reachable by direct URL either way, so
// this is presentation, not authorization. The runner enforces its own access.

import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react'
import { colors } from '../styles/tokens'
import HelpHint from './HelpHint'
import PixelLoader from './PixelLoader'
import StreamingLogBlock from './StreamingLogBlock'
// These four were defined here. Signal Fusion needed all four, so they moved to
// a module both panels import rather than becoming a second copy that drifts —
// see demoRunPresentation.ts. Behaviour is unchanged; the definitions are the
// same ones, relocated.
import {
  RUN_STATUS_COLORS,
  describeRunnerError,
  logTail,
  runStartedAt,
} from './demoRunPresentation'
import { useAuth0 } from '../auth/oidc'
import { invalidateSuperCredState } from '../api/supercredSource'
import {
  fetchDemoRun,
  fetchDemoRunLog,
  fetchDemoStatus,
  fetchDemoSteps,
  isRunActive,
  isRunFailure,
  makeCommandForStep,
  resetDemo,
  sseLogStreamEnabled,
  startDemoRun,
  streamDemoRunLog,
  type DemoRunLogChunk,
  type DemoRunView,
  type DemoRunnerStatus,
  type DemoStep,
} from '../api/demoRunner'

/**
 * A control and the "?" that explains it, bound into one flex item.
 *
 * `nowrap` is the load-bearing part: the controls row wraps, and a wrap landing
 * between a button and its hint would put the "?" at the head of the next line
 * beside a control it has nothing to do with — the confusion this grouping
 * exists to remove.
 */
const CONTROL_WITH_HINT: CSSProperties = {
  display: 'inline-flex', alignItems: 'center', gap: 6, flexWrap: 'nowrap',
}

/**
 * Where each phase's effect shows up for a customer.
 *
 * Derived from what scripts/supercred-demo.sh actually does at each step:
 *   1 deploys the agent, SPIRE entry and OpenBao secrets → it joins the estate;
 *   2 runs SPIFFE → OpenBao → cardvault and labels the pod `state=active`;
 *   3 scans and labels it `state=non-compliant`;
 *   4 revokes and labels it `state=stunned`;
 *   5 tears the agent down — after which the only surviving evidence is the
 *     audit record, which is the point.
 */
const STEP_TARGETS: Record<string, { to: string; label: string; effect: string }> = {
  '1': { to: '/agents', label: 'Agents', effect: 'the agent joins the estate as enrolled' },
  '2': { to: '/credential-inventory', label: 'Credential Inventory', effect: 'the SPIFFE → OpenBao chain mints its credentials' },
  '3': { to: '/compliance', label: 'Compliance', effect: 'the scan drops the agent into the critical band' },
  '4': { to: '/agents', label: 'Agents', effect: 'the agent is suspended and its credentials revoked' },
  '5': { to: '/audit', label: 'Audit Trail', effect: 'the agent is gone; the record of what happened is not' },
}

/**
 * What each phase DOES to the cluster, in plain words, plus what the audience
 * should watch change.
 *
 * `step.description` comes from the runner and is a one-line effect ("the agent
 * joins the estate as enrolled"). That is the right length for a button title
 * and the wrong length for someone deciding whether to press a control that
 * mutates a shared cluster in front of a room. These strings say the mechanism
 * and the visible consequence, so an instructor who has never run the demo — and
 * an executive reading over their shoulder — both know what is about to happen.
 *
 * Written from what scripts/supercred-demo.sh actually executes, not from the
 * phase titles, so they cannot drift into describing an intention the script
 * does not carry out.
 */
const STEP_HELP: Record<string, string> = {
  '1': 'Deletes anything left from a previous run, then deploys the Cardvault agent with its SPIRE registration entry and its OpenBao secrets. Watch a new agent appear on Agents — enrolled, but holding no credentials yet.',
  '2': 'Runs the agent for real: it presents its SPIFFE identity to OpenBao, exchanges it for a short-lived credential and uses that to read the cardvault secret. Watch Credential Inventory fill with the SVID, the OpenBao lease and the service token.',
  '3': 'Reads the running pod’s spec and evaluates it against policy. The agent fails on a missing securityContext and is labelled non-compliant. Nothing is revoked here — watch it drop into the critical band on Compliance.',
  '4': 'Destructive. Deletes the agent’s OpenBao secret and its login role, marks the pod stunned, then re-runs the credential chain to prove it now fails. The pod keeps running but can no longer authenticate to anything. Watch Agents, then Audit Trail.',
  '5': 'Destructive. Deletes the agent pod, its jobs and its SPIRE entry from every namespace they can land in. Watch it disappear everywhere except Audit Trail, which still holds the record of what happened — that is the point.',
}

/** How often an in-flight run's STATUS is re-read. Fast enough to feel live. */
const POLL_MS = 500

/**
 * How long a log read may block waiting for output before answering empty.
 *
 * This is the transport of record and it is not a compromise: the response
 * comes back within milliseconds of the script printing, so it is as live as a
 * stream, while remaining an ordinary short HTTP response that no proxy,
 * compressor or tunnel can silently sit on. Chosen against the 300s
 * `proxy_read_timeout` on the `/demo-api/` nginx location — three seconds
 * leaves two orders of magnitude of headroom, so the boring failure (the
 * deadline passes, an empty chunk comes back, the loop re-arms) is the only
 * one available.
 */
const LOG_WAIT_SECONDS = 3

/**
 * Floor between two log reads when the runner answered immediately.
 *
 * Only reachable against a runner image that predates `wait` and therefore
 * drops it: an unknown query parameter is not an error, so the read returns at
 * once with nothing in it and an unpaced loop would spin hot. 300ms rather
 * than the old 500ms because the loop is now self-rescheduling — it cannot
 * issue a read while one is outstanding, so the request stacking that caused
 * the 2026-08-03 duplication is structurally impossible and the interval no
 * longer has to be conservative enough to outrun a slow round trip.
 */
const LOG_IDLE_FLOOR_MS = 300

/** Bound on the post-run log drain, so a runner that never reports eof cannot spin. */
const MAX_DRAIN_READS = 20

// recordStunAudit() used to live here. It POSTed the audit event from the
// browser after phase 4 succeeded, which made the record of a cluster-mutating
// action contingent on things that have nothing to do with the cluster: a tab
// staying open, a token staying valid across a Dex restart (routine — Dex runs
// storage: memory and `make public` restarts it), and the operator using this
// panel rather than calling the endpoint directly.
//
// Worse, it was not a record of what happened but a client-side assertion that
// it had. agent_name, namespace and reason were string literals in this file,
// so it would have written "compliance-failure: securityContext not set"
// whether or not that was the reason.
//
// The demo runner now writes the event server-side, before it spawns the
// process, from what it actually observed: which step, which superadmin
// principal, when. See _record_privileged_invocation in demo_runner.py.
//
// The trail therefore says "superadmin X ran privileged phase 4" rather than
// "agent stunned". That is less rich and more true; the runner cannot see the
// pod relabel or the OpenBao lease revocation, which belong to the SuperCred
// proxy, and claiming them here is what made the old row a fabrication.

interface Props {
  /** Same visibility flag the sidebar uses — gates the mutating controls only. */
  superadmin: boolean
  /** Re-query live agent state. Wired to the page's own discovery call. */
  onRefreshClients: () => void | Promise<void>
}

export default function SuperCredInstructorPanel({ superadmin, onRefreshClients }: Props) {
  const { getAccessTokenSilently } = useAuth0()
  const [steps, setSteps] = useState<DemoStep[]>([])
  const [status, setStatus] = useState<DemoRunnerStatus | null>(null)
  const [activeRun, setActiveRun] = useState<DemoRunView | null>(null)
  const [log, setLog] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [runnerError, setRunnerError] = useState<string | null>(null)
  const [resetArmed, setResetArmed] = useState(false)
  const [refreshing, setRefreshing] = useState(false)

  // Log offsets are a stream cursor, not render state — advancing them must not
  // schedule a render, and the poll loop must read the latest value.
  const offsetRef = useRef(0)
  /**
   * Whether the SSE stream currently owns the log.
   *
   * Exactly one transport reads the log at a time. Both are safe to display —
   * `applyLogChunk` guarantees that — but they are not safe to interleave: a
   * poll response landing between two stream frames advances the cursor past
   * where the stream is, every later frame is then refused, and the stream
   * quietly stops contributing. So the poll skips its log read while the
   * stream is live, and resumes the instant it is not. A ref rather than
   * state: the poll tick reads it at fire time and flipping it must not
   * re-render, which would tear down and rebuild both effects mid-run.
   */
  const streamLiveRef = useRef(false)

  const loadStatus = useCallback(async () => {
    try {
      const next = await fetchDemoStatus(await getAccessTokenSilently())
      setStatus(next)
      setRunnerError(null)
      // Adopt a run another instructor (or a previous page load) started, so two
      // browsers watching the same demo agree about what is happening.
      setActiveRun(current => (current && !isRunActive(current) ? current : next.active))
      return next
    } catch (err) {
      setRunnerError(err instanceof Error ? err.message : 'Demo runner unavailable')
      setStatus(null)
      return null
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    let cancelled = false
    void (async () => {
      const token = await getAccessTokenSilently()
      const [stepResult, statusResult] = await Promise.allSettled([fetchDemoSteps(token), fetchDemoStatus(token)])
      if (cancelled) return
      if (stepResult.status === 'fulfilled') setSteps(stepResult.value)
      if (statusResult.status === 'fulfilled') {
        setStatus(statusResult.value)
        setActiveRun(statusResult.value.active)
        setRunnerError(null)
      } else {
        setRunnerError(
          statusResult.reason instanceof Error ? statusResult.reason.message : 'Demo runner unavailable',
        )
      }
    })()
    return () => {
      cancelled = true
    }
  }, [getAccessTokenSilently])

  /**
   * Append a chunk to the log, but only if it starts exactly at the cursor.
   *
   * Two readers share `offsetRef`: the 500ms poll below and `drainLog`. Neither
   * holds a lock, the poll has no in-flight guard, and the cursor only advances
   * when a response LANDS — so a response can easily arrive that no longer
   * describes the cursor's position:
   *
   *   * a tick fires while the previous tick is still outstanding (any round
   *     trip over 500ms, which is routine through a tunnel), both ask for the
   *     same offset, and both append the same bytes;
   *   * a slow earlier response lands after a fast later one and assigns its
   *     older `next_offset`, dragging the cursor BACKWARDS, so the next read
   *     re-fetches output already on screen;
   *   * `drainLog` runs concurrently with a tick that has not come back yet.
   *
   * Observed 2026-08-03: the reset banner rendered twice from a script that
   * printed it once, and the request trace showed `offset=0`, `offset=0`,
   * `offset=69`, `offset=0`. This corrupts every step's log, not just reset.
   *
   * The server already echoes the `offset` it served, so the check is exact and
   * needs no locking: a chunk that does not begin at the cursor is a duplicate
   * or an out-of-order straggler, and discarding it is always correct — the
   * bytes it carries are either already displayed or will be re-requested.
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
        const chunk = await fetchDemoRunLog(runId, before, await getAccessTokenSilently())
        // A rejected chunk means a concurrent poll moved the cursor while this
        // read was in flight. Re-read from wherever it got to rather than
        // breaking, so the tail is not truncated. MAX_DRAIN_READS bounds it.
        if (!applyLogChunk(chunk)) continue
        if (offsetRef.current === before) break
        if (chunk.eof) break
      }
    } catch {
      /* the tail is best effort — the run status is the authoritative outcome */
    }
  }, [applyLogChunk, getAccessTokenSilently])

  const finishRun = useCallback(
    async (run: DemoRunView) => {
      // No audit call here any more: the runner records the invocation itself,
      // server-side, so the record no longer depends on this component being
      // alive to make it. The de-duplication ref that guarded against double
      // POSTs goes with it — one request now produces exactly one row.
      await drainLog(run.run_id)
      // The run changed the cluster, so every projection above it is stale.
      invalidateSuperCredState()
      await onRefreshClients()
      await loadStatus()
    },
    [drainLog, loadStatus, onRefreshClients],
  )

  const runId = activeRun?.run_id ?? null
  const running = isRunActive(activeRun)

  /**
   * Read the log with a waiting request, re-issuing as each one returns.
   *
   * This is the live path. A self-rescheduling loop rather than a setInterval,
   * and that difference is the point: the old interval fired every 500ms
   * whether or not the previous read had come back, so any read slower than
   * the interval overlapped the next one, both sent the same offset, and the
   * server honestly returned the same bytes twice — the 2026-08-03 duplicated
   * reset banner. A loop that only issues a read when the last one has landed
   * cannot stack requests at all. `applyLogChunk` still guards every chunk,
   * because `drainLog` and the opt-in stream are also writers.
   */
  useEffect(() => {
    if (!running || !runId) return
    let stopped = false
    const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))

    void (async () => {
      while (!stopped) {
        // The opt-in stream, once proven live, owns the log. Yield to it and
        // keep checking, so the moment it stops — watchdog, break, divergence
        // — this loop is already the one reading.
        if (streamLiveRef.current) {
          await sleep(LOG_IDLE_FLOOR_MS)
          continue
        }
        const startedAt = Date.now()
        try {
          const chunk = await fetchDemoRunLog(
            runId, offsetRef.current, await getAccessTokenSilently(), LOG_WAIT_SECONDS,
          )
          if (stopped) return
          // Progress means bytes that actually reached the screen. A read can
          // fail to make progress two ways and both must be paced: an empty
          // chunk (a runner that ignored `wait` and answered at once, since an
          // unknown query parameter is not an error), or a chunk `applyLogChunk`
          // refused because it did not start at the cursor — a straggler from
          // `drainLog` or the opt-in stream. Pacing on "nothing new appeared"
          // rather than on "the chunk was empty" is what stops a refused chunk
          // becoming a hot loop; a runner that honours `wait` makes progress
          // every time and therefore never sleeps.
          const advanced = applyLogChunk(chunk) && chunk.chunk !== ''
          if (!advanced) {
            const elapsed = Date.now() - startedAt
            if (elapsed < LOG_IDLE_FLOOR_MS) await sleep(LOG_IDLE_FLOOR_MS - elapsed)
          }
        } catch {
          // The run status poll below is the authoritative account of what
          // happened; a failed log read is not worth a banner. Pace and retry.
          if (stopped) return
          await sleep(LOG_IDLE_FLOOR_MS)
        }
      }
    })()

    return () => {
      stopped = true
    }
  }, [running, runId, applyLogChunk, getAccessTokenSilently])

  /**
   * Follow the log over SSE — only when this browser has explicitly asked for it.
   *
   * Off by default. The waiting read above is what an instructor gets, because
   * it cannot fail the way a stream fails: a buffering intermediary accepts an
   * SSE connection, raises no error, and then delivers nothing until the run
   * ends, which is a blank log on stage with no signal that anything is wrong.
   * This path exists so the streaming pattern can be exercised and judged, and
   * it carries a first-byte watchdog precisely because the failure it guards
   * against is silent.
   *
   * One attempt per run, deliberately: the effect's dependencies are stable for
   * a run's lifetime, so a stream that 404s, breaks, starves or diverges from
   * the cursor is not retried. The loop above simply carries on.
   *
   * Every chunk goes through `applyLogChunk`, so the exact-offset guard covers
   * this transport too — and it is what makes the handover safe in both
   * directions if a waiting read is still outstanding when a frame lands.
   */
  useEffect(() => {
    if (!running || !runId || !sseLogStreamEnabled()) return
    const controller = new AbortController()
    let stopped = false
    void (async () => {
      try {
        await streamDemoRunLog(
          runId,
          offsetRef.current,
          {
            onChunk: chunk => {
              if (stopped) return false
              // The stream counts as live only once a frame has actually
              // arrived, never merely because the response opened. nginx
              // buffers proxied responses by default, and a buffering proxy
              // opens the response at once and then holds every frame until
              // the run ends — so trusting the open would silence the poll for
              // the whole phase and leave the panel emptier than it was
              // before any of this existed.
              streamLiveRef.current = true
              // Returning false hands the stream its own shutdown: the cursor
              // moved under it (a poll response still in flight when it
              // opened) and SSE cannot re-ask for a different offset.
              return applyLogChunk(chunk)
            },
          },
          await getAccessTokenSilently(),
          controller.signal,
        )
      } catch {
        /* silent by design — see the note above */
      } finally {
        streamLiveRef.current = false
      }
    })()
    return () => {
      stopped = true
      streamLiveRef.current = false
      // Unmounting mid-phase, or the run reaching a terminal state, closes the
      // response body rather than leaving a reader attached to a dead panel.
      controller.abort()
    }
  }, [running, runId, applyLogChunk, getAccessTokenSilently])

  // The run's STATUS only. The log is read by the waiting loop above, which
  // paces itself against the runner rather than against a clock — leaving this
  // interval to do the one job it is actually good at: noticing, within half a
  // second, that the run has reached a terminal state.
  useEffect(() => {
    if (!running || !runId) return
    let stopped = false
    const timer = setInterval(() => {
      void (async () => {
        try {
          const run = await fetchDemoRun(runId, await getAccessTokenSilently())
          if (stopped) return
          if (!isRunActive(run)) {
            if (run.step_id === '4' && run.status === 'succeeded') {
              // Phase 4 is not complete until the transactional audit record
              // exists; do not publish success before that durable effect.
              await finishRun(run)
              if (stopped) return
            } else {
              setActiveRun(run)
              await finishRun(run)
              return
            }
          }
          setActiveRun(run)
        } catch (err) {
          if (stopped) return
          setError(err instanceof Error ? err.message : 'Lost track of the running step')
        }
      })()
    }, POLL_MS)
    return () => {
      stopped = true
      clearInterval(timer)
    }
  }, [running, runId, finishRun, applyLogChunk, getAccessTokenSilently])

  const startRun = useCallback(
    async (start: () => Promise<DemoRunView>) => {
      setError(null)
      setLog('')
      offsetRef.current = 0
      try {
        const run = await start()
        if (!isRunActive(run) && !(run.step_id === '4' && run.status === 'succeeded')) setActiveRun(run)
        if (!isRunActive(run)) await finishRun(run)
        setActiveRun(run)
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Could not start the step')
      }
    },
    [finishRun],
  )

  const refreshClients = useCallback(async () => {
    setRefreshing(true)
    setError(null)
    try {
      invalidateSuperCredState()
      await onRefreshClients()
      await loadStatus()
    } finally {
      setRefreshing(false)
    }
  }, [loadStatus, onRefreshClients])

  const scriptAvailable = status?.script_available === true
  // Reset and the phase buttons both execute the script; refreshing the estate
  // does not, so it stays usable when the runner cannot run anything.
  const runsBlocked = running || !scriptAvailable

  // A reset is a verified teardown boundary, not a sixth demo phase. The
  // runner intentionally retains its history for auditability, but presenting
  // history from before its newest reset as the current phase state makes a
  // fresh lifecycle look completed. `recent` is newest-first: only entries
  // before the latest reset belong to the current lifecycle.
  const latestRun = activeRun ?? status?.recent[0] ?? null
  const resetVerified = latestRun?.kind === 'reset' && latestRun.status === 'succeeded'
  const latestResetIndex = status?.recent.findIndex(run => run.kind === 'reset') ?? -1
  const currentLifecycleRuns = latestResetIndex >= 0
    ? status!.recent.slice(0, latestResetIndex)
    : status?.recent ?? []

  /** The most recent run for a step — active first, then the runner's history. */
  function runForStep(stepId: string): DemoRunView | null {
    if (resetVerified) return null
    if (activeRun?.step_id === stepId) return activeRun
    // `recent` is newest-first, so the first match is the latest attempt.
    return currentLifecycleRuns.find(r => r.step_id === stepId) ?? null
  }

  const displaySteps: DemoStep[] =
    steps.length > 0
      ? steps
      : ['1', '2', '3', '4', '5'].map(id => ({
          step_id: id,
          title: `Phase ${id}`,
          // Without /demo-api the titles are unknown, but the targets are not —
          // the "Show this on →" links must survive an absent runner.
          description: STEP_TARGETS[id]?.effect ?? '',
        }))

  const failed = isRunFailure(activeRun)

  // What the in-flight indicator says. A reset is not a phase, so it does not
  // get a phase number; a step whose title the runner never returned still
  // gets its number, which is the part the instructor is watching for.
  const runningStep = displaySteps.find(step => step.step_id === activeRun?.step_id)
  const runningLabel =
    activeRun?.kind === 'reset'
      ? 'Resetting the demo'
      : `Phase ${activeRun?.step_id ?? '?'}${runningStep ? ` · ${runningStep.title}` : ''}`

  // What the log block's header names. Present tense is wrong here in a way it
  // is not for the in-flight indicator above: this header outlives the run, so
  // "Resetting the demo" would still be claiming a teardown is under way
  // minutes after it finished. The status word beside it carries the tense.
  const logTitle = activeRun
    ? activeRun.kind === 'reset'
      ? 'Reset'
      : `Phase ${activeRun.step_id}${runningStep ? ` · ${runningStep.title}` : ''}`
    : undefined

  return (
    <>
      {/* Phase status + where to look — rendered for every role */}
      <div data-testid="supercred-phase-status" className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
        <h2 style={{ fontSize: 15, fontWeight: 600, marginBottom: 4 }}>Demo Phases</h2>
        <p style={{ fontSize: 12, color: 'var(--muted)', margin: '0 0 12px', lineHeight: 1.5 }}>
          Each phase changes what a customer sees. Follow the link to the page where its effect lands.
        </p>
        {resetVerified && (
          <p data-testid="supercred-clean-state" style={{ fontSize: 12, color: colors.tealLoom, margin: '0 0 12px', lineHeight: 1.5 }}>
            Clean state verified — teardown completed; no demo phase is currently active.
          </p>
        )}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {displaySteps.map(step => {
            const run = runForStep(step.step_id)
            const target = STEP_TARGETS[step.step_id]
            return (
              <div
                key={step.step_id}
                data-testid={`supercred-phase-${step.step_id}`}
                style={{
                  display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between',
                  gap: 12, padding: '10px 14px', borderRadius: 6,
                  background: 'var(--surface)', border: '1px solid var(--border)',
                }}
              >
                <div style={{ flex: 1 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <span style={{ fontWeight: 600, fontSize: 13 }}>
                      {step.step_id} · {step.title}
                    </span>
                    <span
                      data-testid={`supercred-phase-status-${step.step_id}`}
                      style={{
                        fontSize: 10, fontWeight: 600, textTransform: 'uppercase',
                        padding: '1px 6px', borderRadius: 3,
                        border: `1px solid ${run ? RUN_STATUS_COLORS[run.status] ?? 'var(--border)' : 'var(--border)'}`,
                        color: run ? RUN_STATUS_COLORS[run.status] ?? 'var(--muted)' : 'var(--muted)',
                      }}
                    >
                      {run ? run.status : 'not run'}
                    </span>
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2, lineHeight: 1.4 }}>
                    {step.description}
                  </div>
                </div>
                {target && (
                  <a
                    data-testid={`supercred-show-on-${step.step_id}`}
                    href={target.to}
                    target="_blank"
                    rel="noopener noreferrer"
                    title={`On ${target.label}, ${target.effect}`}
                    style={{ color: 'var(--cyan)', fontSize: 12, whiteSpace: 'nowrap', marginTop: 2 }}
                  >
                    Show this on {target.label} →
                  </a>
                )}
              </div>
            )
          })}
        </div>
      </div>

      {/* Instructor controls — superadmin only */}
      {superadmin && (
        <div data-testid="supercred-instructor" className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
          <h2 style={{ fontSize: 15, fontWeight: 600, marginBottom: 4 }}>Instructor Controls</h2>
          <p style={{ fontSize: 12, color: 'var(--muted)', margin: '0 0 12px', lineHeight: 1.5 }}>
            Run the demo from here. Steps mutate a shared cluster, so they run one at a time —
            every control is locked while a step is in flight.
          </p>

          {/* Gap here is deliberately wider than CONTROL_WITH_HINT's: the two
              distances are what tell an instructor which "?" belongs to which
              button, so the inter-control gap has to beat the intra-pair one. */}
          <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 12 }}>
            <div data-testid="supercred-refresh-clients-group" style={CONTROL_WITH_HINT}>
              <button
                className="btn btn-primary"
                data-testid="supercred-refresh-clients"
                onClick={() => void refreshClients()}
                disabled={running || refreshing}
                style={{ fontSize: 12, padding: '6px 14px' }}
              >
                {refreshing ? 'Refreshing…' : 'Refresh clients'}
              </button>
              <HelpHint
                label="About the client-and-status refresh"
                testId="supercred-refresh-clients-help"
              >
                Refreshes the SuperCred agent list and current demo-runner phase status. It also clears cached SuperCred state before querying live services.
              </HelpHint>
            </div>
            {!resetArmed && (
              <div data-testid="supercred-reset-group" style={CONTROL_WITH_HINT}>
                <button
                  className="btn btn-secondary"
                  data-testid="supercred-reset"
                  onClick={() => setResetArmed(true)}
                  disabled={runsBlocked}
                  style={{ fontSize: 12, padding: '6px 14px', color: colors.red, borderColor: colors.red }}
                >
                  Reset demo
                </button>
                <HelpHint label="What Reset demo does" testId="supercred-reset-help" tone={colors.red}>
                  Runs the verified teardown and clears the current lifecycle display. Historical run records remain available in runner history.
                </HelpHint>
              </div>
            )}
            {resetArmed && (
              <>
                <span data-testid="supercred-reset-prompt" style={{ fontSize: 12, color: colors.amber, alignSelf: 'center' }}>
                  Reset tears the demo down and returns the estate to a clean state. Sure?
                </span>
                {/* The hint follows the destructive button in this state too —
                    that is the button it describes. Cancel stays outside the
                    group so the "?" is not stranded between the two. */}
                <div data-testid="supercred-reset-group" style={CONTROL_WITH_HINT}>
                  <button
                    className="btn btn-secondary"
                    data-testid="supercred-reset-confirm"
                    onClick={() => {
                      setResetArmed(false)
                      void startRun(async () => resetDemo(await getAccessTokenSilently()))
                    }}
                    disabled={runsBlocked}
                    style={{ fontSize: 12, padding: '6px 14px', color: colors.red, borderColor: colors.red }}
                  >
                    Yes, reset the demo
                  </button>
                  <HelpHint label="What Reset demo does" testId="supercred-reset-help" tone={colors.red}>
                    Runs the verified teardown and clears the current lifecycle display. Historical run records remain available in runner history.
                  </HelpHint>
                </div>
                <button
                  className="btn btn-secondary"
                  data-testid="supercred-reset-cancel"
                  onClick={() => setResetArmed(false)}
                  style={{ fontSize: 12, padding: '6px 14px' }}
                >
                  Cancel
                </button>
              </>
            )}
          </div>

          <div data-testid="supercred-run-steps" style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            {displaySteps.map(step => (
              // Button and hint are wrapped together so `flexWrap` can never
              // break the row between them and leave a "?" explaining the phase
              // on the line above it.
              <span key={step.step_id} style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                <button
                  className="btn btn-secondary"
                  data-testid={`supercred-run-step-${step.step_id}`}
                  title={step.description}
                  onClick={() => void startRun(async () => startDemoRun(step.step_id, await getAccessTokenSilently()))}
                  disabled={runsBlocked}
                  style={{
                    fontSize: 12, padding: '6px 12px',
                    borderColor: activeRun?.step_id === step.step_id && running ? 'var(--cyan)' : undefined,
                    color: activeRun?.step_id === step.step_id && running ? 'var(--cyan)' : undefined,
                  }}
                >
                  {step.step_id} · {step.title}
                </button>
                {STEP_HELP[step.step_id] && (
                  <HelpHint
                    label={`What phase ${step.step_id} does to the cluster`}
                    testId={`supercred-run-step-${step.step_id}-help`}
                  >
                    {STEP_HELP[step.step_id]}
                  </HelpHint>
                )}
              </span>
            ))}
          </div>

          {/* Every control above is now disabled and a phase can run for
              minutes. Without this the panel is indistinguishable from a
              panel that has hung — which, on stage, is the moment an
              instructor starts clicking things. Presentation only: it reads
              `running` and the runner's start stamp and drives nothing. */}
          {running && activeRun && (
            <div style={{ marginTop: 12 }}>
              <PixelLoader
                testId="supercred-run-progress"
                label={runningLabel}
                startedAt={runStartedAt(activeRun)}
              />
            </div>
          )}

          {!scriptAvailable && (
            <div
              data-testid="supercred-script-unavailable"
              style={{
                marginTop: 12, padding: '10px 14px', borderRadius: 6, fontSize: 12, lineHeight: 1.7,
                background: 'rgba(245,158,11,0.10)', border: '1px solid rgba(245,158,11,0.35)', color: colors.amber,
              }}
            >
              <div>
                {runnerError
                  ? describeRunnerError(runnerError)
                  : 'The demo runner is up but the demo script is not available to it.'}{' '}
                Run the phases from a shell instead:
              </div>
              <ul style={{ margin: '6px 0 0', paddingLeft: 18, fontFamily: 'monospace', color: 'var(--muted)' }}>
                {displaySteps.map(step => (
                  <li key={step.step_id} data-testid={`supercred-make-command-${step.step_id}`}>
                    {makeCommandForStep(step.step_id)}
                  </li>
                ))}
              </ul>
            </div>
          )}

          {activeRun && (
            <div
              data-testid="supercred-run-status"
              style={{ marginTop: 12, fontSize: 12, color: 'var(--muted)', lineHeight: 1.6 }}
            >
              Step <strong>{activeRun.step_id}</strong> ({activeRun.kind}) —{' '}
              <strong style={{ color: RUN_STATUS_COLORS[activeRun.status] ?? 'var(--muted)' }}>
                {activeRun.status}
              </strong>
              {activeRun.started_at && <> · started {activeRun.started_at}</>}
              {activeRun.finished_at && <> · finished {activeRun.finished_at}</>}
            </div>
          )}

          {failed && activeRun && (
            <div
              data-testid="supercred-run-error"
              style={{
                marginTop: 12, padding: '10px 14px', borderRadius: 6, fontSize: 12, lineHeight: 1.6,
                background: 'rgba(220,38,38,0.08)', border: '1px solid rgba(220,38,38,0.35)', color: colors.red,
              }}
            >
              <div>
                Step {activeRun.step_id} {activeRun.status} with exit code{' '}
                <strong data-testid="supercred-run-exit-code">{activeRun.exit_code ?? 'unknown'}</strong>
                {activeRun.error ? ` — ${activeRun.error}` : ''}
              </div>
              <pre
                data-testid="supercred-run-log-tail"
                style={{
                  margin: '8px 0 0', padding: '8px 10px', borderRadius: 4, maxHeight: 200, overflow: 'auto',
                  background: 'var(--surface)', color: 'var(--muted)', fontSize: 11, whiteSpace: 'pre-wrap',
                }}
              >
                {logTail(log) || 'The runner produced no output before it stopped.'}
              </pre>
            </div>
          )}

          {/* The RAW log goes in, escape bytes and all — the block strips them
              for display and hands the untouched string to its Copy button,
              which is the one artefact an instructor actually wants off this
              screen when a phase fails. `running` drives only the caret; the
              lines themselves appear when their chunk lands and never before.

              Mounted as soon as a run is live, not when the first byte lands.
              Phase 1 can spend a long time in kubectl before it prints
              anything, and until it did, the instructor was looking at a panel
              with every control greyed out and no log surface at all — which
              is indistinguishable from a panel that has hung. The block says
              it is waiting rather than showing an empty bordered box, and it
              does not invent a line, a timestamp or a progress figure to fill
              the space: PixelLoader above already carries "time is passing",
              and anything more here would be reporting progress the runner has
              not made. */}
          {(running || log !== '') && (
            <StreamingLogBlock
              testId="supercred-run-log"
              label="Run log"
              title={logTitle}
              status={activeRun?.status}
              statusTone={activeRun ? RUN_STATUS_COLORS[activeRun.status] ?? 'var(--muted)' : undefined}
              log={log}
              streaming={running}
              placeholder="Waiting for the runner's first output…"
              style={{ marginTop: 12 }}
            />
          )}

          {error && (
            <div
              data-testid="supercred-run-control-error"
              style={{ marginTop: 12, fontSize: 12, color: colors.red, lineHeight: 1.6 }}
            >
              {error}
            </div>
          )}
        </div>
      )}
    </>
  )
}
