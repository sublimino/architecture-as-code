/**
 * SignalFusionPage — the Signal Fusion three-act demo page.
 *
 * Modelled on SuperCredPage's instructor pattern: act buttons with status
 * indicators, SSE-style streaming log output, and a results panel showing
 * discovered actors with confidence scores and coverage statements.
 *
 * Three acts:
 *   1. Inferred  — deploy, seed collectors, correlate
 *   2. Attested  — kernel observation, detect what upper layers cannot see
 *   3. Issued    — promote to issued identity, revoke, close the gap
 *
 * The demo runner backend (demo_runner.py) supports `demo_type=signalfusion`
 * and the API client (signalFusionDemo.ts) wraps the same run/log/status
 * shape as the SuperCred runner.
 */
import { useState, useCallback, useEffect, useRef, type CSSProperties } from 'react'
import { colors } from '../styles/tokens'
import { Section, StatCard, Pill } from '../components/DashKit'
import { useAuth0 } from '../auth/oidc'
import {
  fetchSignalFusionSteps,
  fetchSignalFusionStatus,
  fetchSignalFusionRun,
  fetchSignalFusionRunLog,
  startSignalFusionRun,
  resetSignalFusion,
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

/** Human-readable act descriptions for the instructor. */
const ACT_DESCRIPTIONS: Record<string, { subtitle: string; hint: string }> = {
  inferred: {
    subtitle: 'Deploy, seed collectors, correlate — surface an actor no single layer identified',
    hint: 'Deploys signal collectors across the estate, ingests observations from multiple layers, and runs correlation to surface provisional actors. Watch the actors panel for new entries with cross-layer evidence chains.',
  },
  attested: {
    subtitle: 'Kernel observation — detect the agent network and application layers cannot see',
    hint: 'Activates eBPF-based kernel observation to detect behaviours invisible to network and application layers. The coverage panel updates to show the newly covered layer, and actor confidence scores rise as kernel evidence corroborates existing signals.',
  },
  issued: {
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

const STATUS_COLORS: Record<string, string> = {
  provisional: 'var(--dim)',
  actionable: 'var(--amber)',
  promoted: 'var(--teal)',
  dismissed: 'var(--muted)',
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

const codeStyle: CSSProperties = {
  background: 'var(--surface)',
  padding: '2px 6px',
  borderRadius: 3,
  fontSize: 12,
}

const logPanelStyle: CSSProperties = {
  background: 'var(--bg)',
  border: '1px solid var(--border)',
  borderRadius: 8,
  padding: '12px 16px',
  fontFamily: 'monospace',
  fontSize: 12,
  lineHeight: 1.6,
  maxHeight: 400,
  overflowY: 'auto',
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-all',
  color: 'var(--text)',
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
  const [actStatuses, setActStatuses] = useState<Record<string, 'pending' | 'running' | 'completed' | 'failed'>>({})
  const offsetRef = useRef(0)

  // ─ Results state
  const [actors, setActors] = useState<ProvisionalActor[]>([])
  const [coverage, setCoverage] = useState<CoverageStatement | null>(null)

  // ─── Load steps and status on mount ─────────────────────────────────────

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
        } else {
          setRunnerError(
            statusResult.reason instanceof Error ? statusResult.reason.message : 'Signal Fusion runner unavailable',
          )
        }
      } catch (err) {
        setRunnerError(err instanceof Error ? err.message : 'Failed to load Signal Fusion state')
      }
    })()
    return () => { cancelled = true }
  }, [getAccessTokenSilently])

  // ─── Load results data on mount ─────────────────────────────────────────

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

  const applyLogChunk = useCallback((chunk: DemoRunLogChunk): boolean => {
    if (chunk.offset !== offsetRef.current) return false
    if (chunk.chunk) setLog(prev => prev + chunk.chunk)
    offsetRef.current = chunk.next_offset
    return true
  }, [])

  // ─── Post-run log drain ─────────────────────────────────────────────────

  const drainLog = useCallback(async (runId: string) => {
    try {
      for (let read = 0; read < MAX_DRAIN_READS; read++) {
        const before = offsetRef.current
        const chunk = await fetchSignalFusionRunLog(runId, before, await getAccessTokenSilently())
        if (!applyLogChunk(chunk)) continue
        if (offsetRef.current === before) break
        if (chunk.eof) break
      }
    } catch {
      /* tail is best effort */
    }
  }, [applyLogChunk, getAccessTokenSilently])

  // ─── Log polling loop ───────────────────────────────────────────────────

  const runId = activeRun?.run_id ?? null
  const running = isRunActive(activeRun)

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

  // ─── Run status polling ─────────────────────────────────────────────────

  useEffect(() => {
    if (!running || !runId) return
    const id = setInterval(async () => {
      try {
        const run = await fetchSignalFusionRun(runId, await getAccessTokenSilently())
        setActiveRun(run)
        if (!isRunActive(run)) {
          // Run finished — update act status and drain remaining log
          setActStatuses(prev => ({
            ...prev,
            [run.step_id]: isRunFailure(run) ? 'failed' : 'completed',
          }))
          await drainLog(run.run_id)
          // Reload results to pick up any new actors/coverage
          await loadResults()
          // Reload status
          try {
            const st = await fetchSignalFusionStatus(await getAccessTokenSilently())
            setStatus(st)
          } catch { /* non-critical */ }
        }
      } catch {
        /* status poll failure is non-critical */
      }
    }, POLL_MS)
    return () => clearInterval(id)
  }, [running, runId, getAccessTokenSilently, drainLog, loadResults])

  // ─── Start an act ───────────────────────────────────────────────────────

  const startAct = useCallback(async (stepId: string) => {
    setError(null)
    setLog('')
    offsetRef.current = 0
    setActStatuses(prev => ({ ...prev, [stepId]: 'running' }))
    try {
      const token = await getAccessTokenSilently()
      const run = await startSignalFusionRun(stepId, token)
      setActiveRun(run)
    } catch (err) {
      setError(err instanceof Error ? err.message : `Failed to start act ${stepId}`)
      setActStatuses(prev => ({ ...prev, [stepId]: 'failed' }))
    }
  }, [getAccessTokenSilently])

  // ─── Reset ──────────────────────────────────────────────────────────────

  const handleReset = useCallback(async () => {
    setError(null)
    setLog('')
    offsetRef.current = 0
    setActStatuses({})
    try {
      const token = await getAccessTokenSilently()
      await resetSignalFusion(token)
      setActiveRun(null)
      const st = await fetchSignalFusionStatus(token)
      setStatus(st)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Reset failed')
    }
  }, [getAccessTokenSilently])

  // ─── Page title ─────────────────────────────────────────────────────────

  useEffect(() => {
    const previous = document.title
    document.title = SIGNAL_FUSION_PAGE_TITLE
    return () => { document.title = previous }
  }, [])

  // ─── Render ─────────────────────────────────────────────────────────────

  const anyRunning = running || Object.values(actStatuses).some(s => s === 'running')

  return (
    <div style={{ margin: '0 auto', padding: '32px 24px' }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 6 }}>{SIGNAL_FUSION_PAGE_TITLE}</h1>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 16, lineHeight: 1.6, maxWidth: 760 }}>
        Multi-layer signal correlation: converge observations from network, identity, application,
        and kernel layers to surface actors no single layer can see alone.
      </p>

      {/* Error banners */}
      {runnerError && (
        <div data-testid="sf-runner-error" style={{
          background: 'color-mix(in srgb, var(--error) 10%, transparent)',
          border: '1px solid color-mix(in srgb, var(--error) 30%, transparent)',
          borderRadius: 8, padding: '12px 16px', marginBottom: 16,
          color: 'var(--text)', fontSize: 13,
        }}>
          {runnerError}
        </div>
      )}

      {error && (
        <div data-testid="sf-error" style={{
          background: 'color-mix(in srgb, var(--error) 10%, transparent)',
          border: '1px solid color-mix(in srgb, var(--error) 30%, transparent)',
          borderRadius: 8, padding: '12px 16px', marginBottom: 16,
          color: 'var(--text)', fontSize: 13,
        }}>
          {error}
        </div>
      )}

      {/* Instructor Controls — three acts */}
      <div className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
        <h2 style={{ fontSize: 15, fontWeight: 600, marginBottom: 8 }}>Demo Acts</h2>
        <p style={{ fontSize: 12, color: 'var(--muted)', margin: '0 0 12px', lineHeight: 1.5 }}>
          Each act builds on the previous. Run them in sequence to walk the audience through
          the full signal fusion lifecycle.
        </p>
        <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
          {steps.map((step) => {
            const actStatus = actStatuses[step.step_id] ?? 'pending'
            const desc = ACT_DESCRIPTIONS[step.step_id]
            const statusColor =
              actStatus === 'running' ? colors.cyanLoom
              : actStatus === 'completed' ? colors.tealLoom
              : actStatus === 'failed' ? colors.red
              : 'var(--border)'

            return (
              <button
                key={step.step_id}
                data-testid={`sf-act-${step.step_id}`}
                className="btn btn-secondary"
                title={desc?.hint ?? step.description}
                disabled={anyRunning}
                onClick={() => startAct(step.step_id)}
                style={{
                  fontSize: 12,
                  padding: '10px 16px',
                  minWidth: 180,
                  textAlign: 'left',
                  borderColor: statusColor,
                  borderWidth: 2,
                  position: 'relative',
                }}
              >
                <div style={{ fontWeight: 600, marginBottom: 2 }}>{step.title}</div>
                <div style={{ fontSize: 11, color: 'var(--muted)', lineHeight: 1.4 }}>
                  {desc?.subtitle ?? step.description}
                </div>
                {actStatus !== 'pending' && (
                  <div style={{
                    position: 'absolute', top: 4, right: 8,
                    fontSize: 9, fontWeight: 700, textTransform: 'uppercase',
                    color: statusColor,
                  }}>
                    {actStatus}
                  </div>
                )}
              </button>
            )
          })}
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 12, alignItems: 'center' }}>
          <button
            data-testid="sf-reset-btn"
            className="btn btn-secondary"
            onClick={handleReset}
            disabled={anyRunning}
            style={{ fontSize: 12, padding: '6px 14px' }}
          >
            Reset
          </button>
          {status && !status.script_available && (
            <span style={{ fontSize: 11, color: 'var(--amber)' }}>
              Runner has no script mounted. Use <code style={codeStyle}>make demo-signalfusion</code> from shell.
            </span>
          )}
        </div>
      </div>

      {/* Log output panel */}
      {log && (
        <div style={{ marginBottom: 16 }}>
          <h2 style={{ fontSize: 15, fontWeight: 600, marginBottom: 8 }}>Output</h2>
          <div data-testid="sf-log-output" style={logPanelStyle}>
            {log}
          </div>
        </div>
      )}

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
