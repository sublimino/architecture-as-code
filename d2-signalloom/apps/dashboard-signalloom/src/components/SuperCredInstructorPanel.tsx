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

import { useCallback, useEffect, useRef, useState } from 'react'
import { colors } from '../styles/tokens'
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
  startDemoRun,
  type DemoRunView,
  type DemoRunnerStatus,
  type DemoStep,
} from '../api/demoRunner'

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

const RUN_STATUS_COLORS: Record<string, string> = {
  running: colors.cyanLoom,
  succeeded: colors.tealLoom,
  failed: colors.red,
  timed_out: colors.amber,
  cancelled: colors.amber,
}

/** How often an in-flight run is re-read. Fast enough to feel live on stage. */
const POLL_MS = 500

/** Bound on the post-run log drain, so a runner that never reports eof cannot spin. */
const MAX_DRAIN_READS = 20

/** Lines of output kept on screen when a run fails. */
const LOG_TAIL_LINES = 12

function logTail(log: string): string {
  return log.split('\n').filter(line => line.trim() !== '').slice(-LOG_TAIL_LINES).join('\n')
}

interface Props {
  /** Same visibility flag the sidebar uses — gates the mutating controls only. */
  superadmin: boolean
  /** Re-query live agent state. Wired to the page's own discovery call. */
  onRefreshClients: () => void | Promise<void>
}

// A failed status call has three very different causes, and reporting all of
// them as "not reachable" sends the instructor to debug the network when the
// actual answer is "sign in again".
//
// The 401 case is not hypothetical and not rare. Dex runs `storage: memory`, so
// it regenerates its signing keys on every restart — and it restarts whenever
// the published origin changes, which is exactly what `make public` does. Any
// browser tab open across that boundary holds a token signed by keys that no
// longer exist, so the API rejects it. The demo runner is perfectly healthy;
// the session is stale. Telling the instructor it is "not reachable" during a
// live demo is the worst possible moment to be wrong about which.
function describeRunnerError(runnerError: string): string {
  if (/\b401\b|invalid_token|token is invalid/i.test(runnerError)) {
    return 'Your session is no longer valid, so the demo runner rejected the request '
      + '(the demo runner itself is fine). This happens when Dex restarts — publishing '
      + 'or tearing down a public URL does exactly that. Sign out and back in, then retry.'
  }
  if (/\b403\b|superadmin_required|forbidden/i.test(runnerError)) {
    return 'You are signed in, but this account is not a superadmin, so the run controls '
      + 'are refused by the server.'
  }
  return `The demo runner is not reachable (${runnerError}).`
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
   * Read whatever output landed after the run finished.
   *
   * The last poll almost always lands before the script's final lines are
   * flushed, and those lines are exactly the ones that explain a failure.
   */
  const drainLog = useCallback(async (runId: string) => {
    try {
      for (let read = 0; read < MAX_DRAIN_READS; read++) {
        const chunk = await fetchDemoRunLog(runId, offsetRef.current, await getAccessTokenSilently())
        if (chunk.chunk) setLog(prev => prev + chunk.chunk)
        if (chunk.next_offset === offsetRef.current) break
        offsetRef.current = chunk.next_offset
        if (chunk.eof) break
      }
    } catch {
      /* the tail is best effort — the run status is the authoritative outcome */
    }
  }, [getAccessTokenSilently])

  const finishRun = useCallback(
    async (runId: string) => {
      await drainLog(runId)
      // The run changed the cluster, so every projection above it is stale.
      invalidateSuperCredState()
      await onRefreshClients()
      await loadStatus()
    },
    [drainLog, loadStatus, onRefreshClients],
  )

  const runId = activeRun?.run_id ?? null
  const running = isRunActive(activeRun)

  useEffect(() => {
    if (!running || !runId) return
    let stopped = false
    const timer = setInterval(() => {
      void (async () => {
        try {
          const [run, chunk] = await Promise.all([
            fetchDemoRun(runId, await getAccessTokenSilently()),
            fetchDemoRunLog(runId, offsetRef.current, await getAccessTokenSilently()).catch(() => null),
          ])
          if (stopped) return
          if (chunk) {
            if (chunk.chunk) setLog(prev => prev + chunk.chunk)
            offsetRef.current = chunk.next_offset
          }
          setActiveRun(run)
          if (!isRunActive(run)) await finishRun(runId)
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
  }, [running, runId, finishRun, getAccessTokenSilently])

  const startRun = useCallback(
    async (start: () => Promise<DemoRunView>) => {
      setError(null)
      setLog('')
      offsetRef.current = 0
      try {
        const run = await start()
        setActiveRun(run)
        if (!isRunActive(run)) await finishRun(run.run_id)
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

  /** The most recent run for a step — active first, then the runner's history. */
  function runForStep(stepId: string): DemoRunView | null {
    if (activeRun?.step_id === stepId) return activeRun
    // `recent` is newest-first, so the first match is the latest attempt.
    return status?.recent.find(r => r.step_id === stepId) ?? null
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

  return (
    <>
      {/* Phase status + where to look — rendered for every role */}
      <div data-testid="supercred-phase-status" className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
        <h2 style={{ fontSize: 15, fontWeight: 600, marginBottom: 4 }}>Demo Phases</h2>
        <p style={{ fontSize: 12, color: 'var(--muted)', margin: '0 0 12px', lineHeight: 1.5 }}>
          Each phase changes what a customer sees. Follow the link to the page where its effect lands.
        </p>
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

          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 12 }}>
            <button
              className="btn btn-primary"
              data-testid="supercred-refresh-clients"
              onClick={() => void refreshClients()}
              disabled={running || refreshing}
              style={{ fontSize: 12, padding: '6px 14px' }}
            >
              {refreshing ? 'Refreshing…' : 'Refresh clients'}
            </button>
            {!resetArmed && (
              <button
                className="btn btn-secondary"
                data-testid="supercred-reset"
                onClick={() => setResetArmed(true)}
                disabled={runsBlocked}
                style={{ fontSize: 12, padding: '6px 14px', color: colors.red, borderColor: colors.red }}
              >
                Reset demo
              </button>
            )}
            {resetArmed && (
              <>
                <span data-testid="supercred-reset-prompt" style={{ fontSize: 12, color: colors.amber, alignSelf: 'center' }}>
                  Reset tears the demo down and returns the estate to a clean state. Sure?
                </span>
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
              <button
                key={step.step_id}
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
            ))}
          </div>

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

          {log !== '' && (
            <pre
              data-testid="supercred-run-log"
              style={{
                marginTop: 12, padding: '10px 12px', borderRadius: 6, maxHeight: 260, overflow: 'auto',
                background: 'var(--surface)', border: '1px solid var(--border)',
                fontSize: 11, lineHeight: 1.5, whiteSpace: 'pre-wrap', color: 'var(--text)',
              }}
            >
              {log}
            </pre>
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
