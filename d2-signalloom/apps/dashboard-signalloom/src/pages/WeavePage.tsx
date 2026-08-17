/**
 * WeavePage — "The Weave" dashboard.
 *
 * Visualises signal observations converging on provisional actors, with
 * confidence scores, evidence chains, and a coverage honesty panel stating
 * the product's own blind spots. The honesty panel is the strongest sales
 * asset — it tells a CISO exactly where the product cannot see.
 */
import { useState, useEffect, useCallback, useRef } from 'react'
import { useAuth0 } from '../auth/oidc'
import { weaveApi } from '../api/weaveApi'
import { isDemoMode } from '../api/demoMode'
import type {
  SignalObservation,
  ProvisionalActor,
  CoverageStatement,
  SignalLayer,
  FidelityTier,
} from '../api/weaveApi'
import { Section, StatCard } from '../components/DashKit'
import LoadingState, { loadPhase } from '../components/LoadingState'
import EvidenceDrawer, { LAYER_LABELS, LAYER_COLORS } from '../components/EvidenceDrawer'
import {
  fetchSignalFusionSteps,
  startSignalFusionRun,
  fetchSignalFusionRunLog,
} from '../api/signalFusionDemo'
import type { DemoStep, DemoRunView, DemoRunLogChunk } from '../api/signalFusionDemo'

// ─── Constants ───────────────────────────────────────────────────────────────

const DISPLAY_LAYERS: SignalLayer[] = [
  'network_egress',
  'identity_authorization',
  'application_saas',
  'endpoint_host',
  'behavioural',
]

const ALL_LAYERS: SignalLayer[] = [
  ...DISPLAY_LAYERS,
  'cloud_control_plane',
  'protocol',
]

const STATUS_COLORS: Record<string, string> = {
  provisional: 'var(--dim)',
  actionable: 'var(--amber)',
  promoted: 'var(--teal)',
  dismissed: 'var(--muted)',
}

const FIDELITY_SIZES: Record<FidelityTier, number> = {
  definitive: 14,
  strong: 11,
  suggestive: 8,
  circumstantial: 6,
}

// ─── Page ────────────────────────────────────────────────────────────────────

/** True when the error message looks like the signal-ingest service is down. */
function isServiceUnreachable(msg: string): boolean {
  return /Network Error|ERR_CONNECTION_REFUSED|ECONNREFUSED|upstream_unavailable|status code 502|status code 503/i.test(msg)
}

export default function WeavePage() {
  const { getAccessTokenSilently } = useAuth0()

  const [observations, setObservations] = useState<SignalObservation[]>([])
  const [actors, setActors] = useState<ProvisionalActor[]>([])
  const [coverage, setCoverage] = useState<CoverageStatement | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [selectedActor, setSelectedActor] = useState<ProvisionalActor | null>(null)
  const [seeding, setSeeding] = useState(false)
  const [seedResult, setSeedResult] = useState<string | null>(null)

  const fetchData = useCallback(async () => {
    try {
      setLoading(true)
      const token = await getAccessTokenSilently()
      const [obs, act, cov] = await Promise.all([
        weaveApi.getObservations(token),
        weaveApi.getActors(token),
        weaveApi.getCoverage(token),
      ])
      setObservations(obs)
      setActors(act)
      setCoverage(cov)
      setError(null)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load signal data.')
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    void fetchData()
  }, [fetchData])

  const handleSeed = useCallback(async () => {
    try {
      setSeeding(true)
      setSeedResult(null)
      const token = await getAccessTokenSilently()
      const result = await weaveApi.seedFixtures(token)
      setSeedResult(`Seeded ${result.seeded} observations. Refreshing...`)
      // Re-fetch data after seeding
      await fetchData()
    } catch (err) {
      setSeedResult(err instanceof Error ? err.message : 'Seed failed.')
    } finally {
      setSeeding(false)
    }
  }, [getAccessTokenSilently, fetchData])

  if (loading) {
    return <LoadingState status={loadPhase({ loading, error })} label="Loading signal data" />
  }

  if (error) {
    const unreachable = !isDemoMode() && isServiceUnreachable(error)

    if (unreachable) {
      return (
        <div data-testid="weave-load-state" data-status="error" style={{ padding: 32 }}>
          <h2 style={{ fontSize: 18, fontWeight: 700, color: 'var(--error)', marginBottom: 8 }}>
            Signal Ingest Service Unreachable
          </h2>
          <p style={{ fontSize: 13, color: 'var(--text)', lineHeight: 1.6, maxWidth: 560, marginBottom: 16 }}>
            The signal-ingest service is not responding. Start it with{' '}
            <code style={{ fontSize: 12, padding: '2px 6px', background: 'var(--surface2)', borderRadius: 4 }}>
              make signal-ingest-up
            </code>{' '}
            or switch to demo mode using the toggle in the sidebar.
          </p>
          <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 4 }}>
            {error}
          </p>
        </div>
      )
    }

    return <LoadingState variant="block" status="error" label="signal data" error={error} testId="weave-load-state" />
  }

  const isEmpty = observations.length === 0 && actors.length === 0

  const closeableCount = coverage?.closeable_by_issuance.length ?? 0
  const totalBlindSpots = coverage?.blind_spots.length ?? 0

  return (
    <div data-testid="weave-page">
      {/* Page Header */}
      <div style={{ marginBottom: 24 }}>
        <h1 className="display" style={{ fontSize: 22, fontWeight: 700, color: 'var(--text)', marginBottom: 4 }}>
          The Weave
        </h1>
        <p style={{ fontSize: 13, color: 'var(--muted)', maxWidth: 640 }}>
          Signal observations from {DISPLAY_LAYERS.length} active layers, converging on provisional actors.
          Confidence scores are derived from multi-layer evidence correlation.
        </p>
      </div>

      {/* Stat Cards */}
      <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 24 }}>
        <StatCard label="Observations" value={String(observations.length)} sub="Across all layers" accent="var(--cyan)" />
        <StatCard label="Provisional Actors" value={String(actors.length)} sub={`${actors.filter((a) => a.status === 'actionable').length} actionable`} accent="var(--amber)" />
        <StatCard label="Active Layers" value={String(coverage?.covered_layers.length ?? 0)} sub={`of ${ALL_LAYERS.length} total`} accent="var(--teal)" />
        <StatCard label="Blind Spots" value={String(totalBlindSpots)} sub={`${closeableCount} closeable by issuance`} accent="var(--error)" />
      </div>

      {/* Empty state with seed button */}
      {isEmpty && (
        <div
          className="card"
          data-testid="weave-empty-state"
          style={{
            padding: '32px 24px',
            textAlign: 'center',
            marginBottom: 24,
          }}
        >
          <p style={{ fontSize: 14, color: 'var(--muted)', marginBottom: 16 }}>
            No signal observations or provisional actors found.
            {!isDemoMode() && ' The signal-ingest store may be empty.'}
          </p>
          {!isDemoMode() && (
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8 }}>
              <button
                data-testid="seed-fixtures-btn"
                disabled={seeding}
                onClick={() => void handleSeed()}
                style={{
                  padding: '8px 20px',
                  fontSize: 13,
                  fontWeight: 600,
                  borderRadius: 'var(--radius-sm, 6px)',
                  border: 'none',
                  background: seeding ? 'var(--surface2)' : 'var(--teal)',
                  color: seeding ? 'var(--muted)' : 'var(--on-accent, #fff)',
                  cursor: seeding ? 'not-allowed' : 'pointer',
                  opacity: seeding ? 0.6 : 1,
                }}
              >
                {seeding ? 'Seeding...' : 'Seed Fixtures'}
              </button>
              {seedResult && (
                <p data-testid="seed-result" style={{ fontSize: 12, color: 'var(--muted)', margin: 0 }}>
                  {seedResult}
                </p>
              )}
            </div>
          )}
        </div>
      )}

      {/* Signal Threads Panel */}
      <Section title="Signal Threads" hint="Observations by layer and fidelity">
        <div className="card" style={{ padding: '20px 24px' }} data-testid="signal-threads">
          {DISPLAY_LAYERS.map((layer) => {
            const layerObs = observations.filter((o) => o.layer === layer)
            return (
              <SignalThread
                key={layer}
                layer={layer}
                observations={layerObs}
              />
            )
          })}
        </div>
      </Section>

      {/* Actors Panel */}
      <Section title="Provisional Actors" hint="Entities correlated from multi-layer signals">
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(340, 1fr))', gap: 14 }} data-testid="actors-panel">
          {actors.map((actor) => (
            <ActorCard
              key={actor.id}
              actor={actor}
              onViewEvidence={() => setSelectedActor(actor)}
            />
          ))}
        </div>
      </Section>

      {/* Coverage Honesty Panel */}
      {coverage && <CoverageHonestyPanel coverage={coverage} />}

      {/* Signal Fusion Demo Controls */}
      <SignalFusionDemoControls />

      {/* Evidence Drawer */}
      <EvidenceDrawer actor={selectedActor} onClose={() => setSelectedActor(null)} />
    </div>
  )
}

// ─── Signal Thread Row ───────────────────────────────────────────────────────

function SignalThread({ layer, observations }: { layer: SignalLayer; observations: SignalObservation[] }) {
  const color = LAYER_COLORS[layer]
  const label = LAYER_LABELS[layer]

  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '8px 0', borderBottom: '1px solid var(--border)' }}>
      <div style={{
        width: 120,
        fontSize: 11,
        fontWeight: 600,
        color,
        textTransform: 'uppercase',
        letterSpacing: '0.04em',
        flexShrink: 0,
      }}>
        {label}
      </div>
      <div style={{ flex: 1, display: 'flex', alignItems: 'center', gap: 8, minHeight: 28 }}>
        {observations.length === 0 ? (
          <span style={{ fontSize: 11, color: 'var(--dim)', fontStyle: 'italic' }}>No signals</span>
        ) : (
          observations.map((obs) => (
            <div
              key={obs.id}
              title={obs.description}
              style={{
                width: FIDELITY_SIZES[obs.fidelity],
                height: FIDELITY_SIZES[obs.fidelity],
                borderRadius: '50%',
                background: color,
                opacity: 0.4 + obs.confidence * 0.6,
                cursor: 'help',
                flexShrink: 0,
              }}
            />
          ))
        )}
      </div>
      <div style={{ fontSize: 11, color: 'var(--muted)', width: 24, textAlign: 'right', flexShrink: 0 }}>
        {observations.length}
      </div>
    </div>
  )
}

// ─── Actor Card ──────────────────────────────────────────────────────────────

function ActorCard({ actor, onViewEvidence }: { actor: ProvisionalActor; onViewEvidence: () => void }) {
  const layerCount = new Set(actor.evidence_chain.map((e) => e.layer)).size
  const statusColor = STATUS_COLORS[actor.status] ?? 'var(--dim)'
  const confidencePct = Math.round(actor.confidence * 100)
  const barColor = actor.confidence >= 0.7 ? 'var(--teal)' : actor.confidence >= 0.5 ? 'var(--amber)' : 'var(--error)'

  return (
    <div
      className="card"
      data-testid="actor-card"
      style={{ padding: '16px 20px', display: 'flex', flexDirection: 'column', gap: 12 }}
    >
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div>
          <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--text)' }}>
            {actor.display_name ?? actor.id}
          </div>
          <div style={{ fontSize: 11, color: 'var(--dim)', marginTop: 2 }}>
            {actor.id}
          </div>
        </div>
        <span
          data-testid="actor-status-badge"
          style={{
            fontSize: 10,
            fontWeight: 700,
            textTransform: 'uppercase',
            letterSpacing: '0.06em',
            padding: '2px 8px',
            borderRadius: 4,
            color: statusColor,
            background: `${statusColor}1A`,
          }}
        >
          {actor.status}
        </span>
      </div>

      {/* Confidence bar */}
      <div>
        <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11, color: 'var(--muted)', marginBottom: 4 }}>
          <span>Confidence</span>
          <span style={{ fontWeight: 600, color: barColor }}>{confidencePct}%</span>
        </div>
        <div style={{ height: 6, background: 'var(--surface2)', borderRadius: 3, overflow: 'hidden' }}>
          <div style={{ height: '100%', width: `${confidencePct}%`, background: barColor, borderRadius: 3, transition: 'width 0.3s' }} />
        </div>
      </div>

      {/* Metadata row */}
      <div style={{ display: 'flex', gap: 16, fontSize: 11, color: 'var(--muted)' }}>
        <span>{actor.evidence_chain.length} observations</span>
        <span>{layerCount} layers</span>
        {actor.promoted_at && <span>Promoted</span>}
      </div>

      {/* Actions */}
      <div style={{ display: 'flex', gap: 8, marginTop: 'auto' }}>
        <button
          onClick={onViewEvidence}
          data-testid="view-evidence-btn"
          style={{
            flex: 1,
            padding: '7px 14px',
            fontSize: 12,
            fontWeight: 600,
            borderRadius: 'var(--radius-sm)',
            border: '1px solid var(--border-subtle)',
            background: 'var(--surface2)',
            color: 'var(--text)',
            cursor: 'pointer',
          }}
        >
          View Evidence
        </button>
        {actor.status === 'actionable' && (
          <button
            data-testid="promote-actor-btn"
            style={{
              padding: '7px 14px',
              fontSize: 12,
              fontWeight: 600,
              borderRadius: 'var(--radius-sm)',
              border: 'none',
              background: 'var(--teal)',
              color: 'var(--on-accent)',
              cursor: 'pointer',
            }}
          >
            Promote
          </button>
        )}
      </div>
    </div>
  )
}

// ─── Coverage Honesty Panel ──────────────────────────────────────────────────

function CoverageHonestyPanel({ coverage }: { coverage: CoverageStatement }) {
  const blindSpotsByLayer = new Map<SignalLayer, string[]>()
  for (const bs of coverage.blind_spots) {
    const existing = blindSpotsByLayer.get(bs.layer) ?? []
    existing.push(bs.description)
    blindSpotsByLayer.set(bs.layer, existing)
  }

  const closeableCount = coverage.closeable_by_issuance.length
  const totalBlindSpots = coverage.blind_spots.length

  return (
    <section style={{ marginBottom: 26 }} data-testid="coverage-panel">
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 10 }}>
        <h2 style={{ fontSize: 16, fontWeight: 700, color: 'var(--text)' }}>Coverage Honesty</h2>
        <span style={{ fontSize: 12, color: 'var(--muted)' }}>What this product can and cannot see</span>
      </div>

      <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead>
            <tr style={{ borderBottom: '1px solid var(--border)' }}>
              <th style={thStyle}>Layer</th>
              <th style={thStyle}>Status</th>
              <th style={thStyle}>Blind Spots</th>
            </tr>
          </thead>
          <tbody>
            {ALL_LAYERS.map((layer) => {
              const isActive = coverage.covered_layers.includes(layer)
              const spots = blindSpotsByLayer.get(layer) ?? []
              return (
                <tr key={layer} style={{ borderBottom: '1px solid var(--border)' }}>
                  <td style={tdStyle}>
                    <span style={{ color: LAYER_COLORS[layer], fontWeight: 600 }}>
                      {LAYER_LABELS[layer]}
                    </span>
                  </td>
                  <td style={tdStyle}>
                    {isActive ? (
                      <span data-testid="layer-status-active" style={{ color: 'var(--teal)', fontWeight: 600, fontSize: 12 }}>
                        &#10003; Active
                      </span>
                    ) : (
                      <span data-testid="layer-status-inactive" style={{ color: 'var(--error)', fontWeight: 600, fontSize: 12 }}>
                        &#10007; Not Deployed
                      </span>
                    )}
                  </td>
                  <td style={tdStyle}>
                    {spots.length > 0 ? (
                      <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                        {spots.map((desc, i) => (
                          <span key={i} style={{
                            fontSize: 12,
                            color: 'var(--amber)',
                            background: 'var(--amber-bg)',
                            padding: '2px 8px',
                            borderRadius: 4,
                            display: 'inline-block',
                          }}>
                            {desc}
                          </span>
                        ))}
                      </div>
                    ) : !isActive ? (
                      <span style={{ fontSize: 12, color: 'var(--error)', fontStyle: 'italic' }}>
                        All signals in this layer
                      </span>
                    ) : (
                      <span style={{ fontSize: 12, color: 'var(--dim)' }}>---</span>
                    )}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>

        {/* Closeable by issuance callout */}
        {closeableCount > 0 && (
          <div
            data-testid="closeable-callout"
            style={{
              padding: '14px 20px',
              background: 'var(--amber-bg)',
              borderTop: '1px solid var(--amber-border)',
              fontSize: 13,
              color: 'var(--text)',
              lineHeight: 1.6,
            }}
          >
            <strong style={{ color: 'var(--amber-base, var(--amber))' }}>
              {closeableCount} of {totalBlindSpots} blind spots are closeable by credential issuance
            </strong>
            {' '}&mdash; an agent with its own issued identity is no longer a detection problem
            at the identity or network layer.
          </div>
        )}
      </div>
    </section>
  )
}

const thStyle: React.CSSProperties = {
  padding: '10px 16px',
  textAlign: 'left',
  color: 'var(--muted)',
  fontWeight: 600,
  fontSize: 11,
  textTransform: 'uppercase',
  letterSpacing: '0.05em',
  whiteSpace: 'nowrap',
}

const tdStyle: React.CSSProperties = {
  padding: '10px 16px',
  fontSize: 13,
  color: 'var(--text)',
  verticalAlign: 'top',
}

// ─── Signal Fusion Demo Controls ────────────────────────────────────────────

type DemoRunState = 'idle' | 'running' | 'succeeded' | 'failed'

function SignalFusionDemoControls() {
  const { getAccessTokenSilently } = useAuth0()
  const [steps, setSteps] = useState<DemoStep[]>([])
  const [runState, setRunState] = useState<DemoRunState>('idle')
  const [activeRunId, setActiveRunId] = useState<string | null>(null)
  const [logOutput, setLogOutput] = useState('')
  const [loadError, setLoadError] = useState<string | null>(null)
  const logRef = useRef<HTMLPreElement>(null)
  const pollRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Load steps on mount
  useEffect(() => {
    let cancelled = false
    void (async () => {
      try {
        const token = await getAccessTokenSilently()
        const s = await fetchSignalFusionSteps(token)
        if (!cancelled) setSteps(s)
      } catch (err) {
        if (!cancelled) setLoadError(err instanceof Error ? err.message : 'Failed to load demo steps')
      }
    })()
    return () => { cancelled = true }
  }, [getAccessTokenSilently])

  // Poll log when a run is active
  useEffect(() => {
    if (!activeRunId || runState !== 'running') return
    let offset = 0
    let cancelled = false

    async function poll() {
      if (cancelled) return
      try {
        const token = await getAccessTokenSilently()
        const chunk: DemoRunLogChunk = await fetchSignalFusionRunLog(activeRunId!, offset, token, 2)
        if (cancelled) return
        if (chunk.chunk) {
          setLogOutput(prev => prev + chunk.chunk)
          offset = chunk.next_offset
        }
        if (chunk.eof) {
          setRunState('succeeded')
          return
        }
      } catch {
        // Keep polling on transient errors
      }
      if (!cancelled) {
        pollRef.current = setTimeout(poll, 500)
      }
    }

    void poll()
    return () => {
      cancelled = true
      if (pollRef.current) clearTimeout(pollRef.current)
    }
  }, [activeRunId, runState, getAccessTokenSilently])

  // Auto-scroll log
  useEffect(() => {
    if (logRef.current) {
      logRef.current.scrollTop = logRef.current.scrollHeight
    }
  }, [logOutput])

  const handleRun = async (stepId: string) => {
    try {
      setRunState('running')
      setLogOutput('')
      const token = await getAccessTokenSilently()
      const run: DemoRunView = await startSignalFusionRun(stepId, token)
      setActiveRunId(run.run_id)
    } catch (err) {
      setRunState('failed')
      setLogOutput(err instanceof Error ? err.message : 'Failed to start demo run')
    }
  }

  if (loadError) return null
  if (steps.length === 0) return null

  const isRunning = runState === 'running'

  return (
    <Section title="Signal Fusion Demo" hint="Run the three-act demo lifecycle">
      <div className="card" style={{ padding: '20px 24px' }} data-testid="sf-demo-controls">
        <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', marginBottom: logOutput ? 14 : 0 }}>
          {steps.map(step => (
            <button
              key={step.step_id}
              data-testid={`sf-demo-act-${step.step_id}`}
              disabled={isRunning}
              onClick={() => void handleRun(step.step_id)}
              style={{
                padding: '8px 16px',
                fontSize: 12,
                fontWeight: 600,
                borderRadius: 'var(--radius-sm, 6px)',
                border: '1px solid var(--border-subtle, var(--border))',
                background: isRunning ? 'var(--surface2)' : 'var(--teal)',
                color: isRunning ? 'var(--muted)' : 'var(--on-accent, #fff)',
                cursor: isRunning ? 'not-allowed' : 'pointer',
                opacity: isRunning ? 0.6 : 1,
              }}
              title={step.description}
            >
              Act {step.step_id}: {step.title}
            </button>
          ))}
          {runState === 'running' && (
            <span style={{ fontSize: 12, color: 'var(--amber)', alignSelf: 'center', fontWeight: 600 }}>
              Running...
            </span>
          )}
          {runState === 'succeeded' && (
            <span style={{ fontSize: 12, color: 'var(--teal)', alignSelf: 'center', fontWeight: 600 }}>
              Completed
            </span>
          )}
          {runState === 'failed' && (
            <span style={{ fontSize: 12, color: 'var(--error)', alignSelf: 'center', fontWeight: 600 }}>
              Failed
            </span>
          )}
        </div>

        {logOutput && (
          <pre
            ref={logRef}
            data-testid="sf-demo-log"
            style={{
              maxHeight: 320,
              overflow: 'auto',
              padding: '12px 16px',
              fontSize: 11,
              fontFamily: 'monospace',
              lineHeight: 1.6,
              background: 'var(--surface, #111)',
              color: 'var(--text)',
              borderRadius: 'var(--radius-sm, 6px)',
              border: '1px solid var(--border)',
              margin: 0,
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-all',
            }}
          >
            {logOutput}
          </pre>
        )}
      </div>
    </Section>
  )
}
