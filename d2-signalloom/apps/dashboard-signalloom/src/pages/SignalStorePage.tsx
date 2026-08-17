import { useState, useEffect, useCallback } from 'react'
import { useAuth0 } from '../auth/oidc'
import { colors } from '../styles/tokens'
import { StatCard, Section, Table, td } from '../components/DashKit'
import LoadingState, { loadPhase } from '../components/LoadingState'
import { weaveApi } from '../api/weaveApi'
import type { StoreStats, SignalObservation, FidelityTier } from '../api/weaveApi'

const FIDELITY_COLORS: Record<FidelityTier, string> = {
  definitive: colors.tealLoom,
  strong: colors.cyanLoom,
  suggestive: colors.amber,
  circumstantial: colors.muted,
}

const LAYER_LABELS: Record<string, string> = {
  network_egress: 'Network Egress',
  identity_authorization: 'Identity & Authorization',
  application_saas: 'Application / SaaS',
  endpoint_host: 'Endpoint / Host',
  behavioural: 'Behavioural',
  cloud_control_plane: 'Cloud Control Plane',
  protocol: 'Protocol',
}

function formatTimestamp(ts: string | null): string {
  if (!ts) return 'Never'
  const d = new Date(ts)
  return d.toLocaleString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
}

export default function SignalStorePage() {
  const { getAccessTokenSilently } = useAuth0()
  const [stats, setStats] = useState<StoreStats | null>(null)
  const [observations, setObservations] = useState<SignalObservation[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [actionLoading, setActionLoading] = useState<string | null>(null)
  const [actionResult, setActionResult] = useState<string | null>(null)

  const loadData = useCallback(async () => {
    setLoading(true)
    try {
      const token = await getAccessTokenSilently()
      const [statsResult, obsResult] = await Promise.all([
        weaveApi.getStoreStats(token),
        weaveApi.getObservations(token, { limit: 50 }),
      ])
      setStats(statsResult)
      setObservations(Array.isArray(obsResult) ? obsResult : [])
      setError(null)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load store data')
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently])

  useEffect(() => { loadData() }, [loadData])

  async function handleAction(action: 'correlate' | 'seed') {
    setActionLoading(action)
    setActionResult(null)
    try {
      const token = await getAccessTokenSilently()
      if (action === 'correlate') {
        await weaveApi.runCorrelation(token)
        setActionResult('Correlation engine run complete')
      } else {
        const result = await weaveApi.seedFixtures(token)
        setActionResult(`Seeded ${result.seeded ?? 'fixture'} observations`)
      }
      // Refresh data after action
      await loadData()
    } catch (err) {
      setActionResult(`Error: ${err instanceof Error ? err.message : 'action failed'}`)
    } finally {
      setActionLoading(null)
    }
  }

  const sortedLayers = stats
    ? Object.entries(stats.observations_by_layer).sort((a, b) => b[1] - a[1])
    : []

  const sortedFidelity: [string, number][] = stats
    ? (['definitive', 'strong', 'suggestive', 'circumstantial'] as const)
        .filter(f => (stats.observations_by_fidelity[f] ?? 0) > 0)
        .map(f => [f, stats.observations_by_fidelity[f]] as [string, number])
    : []

  return (
    <div>
      {/* Header */}
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 22, fontWeight: 700, color: 'var(--text)', margin: 0 }}>Signal Store</h1>
        <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
          FrostDB observation store diagnostics
        </div>
      </div>

      <div className="card" style={{ padding: 16, marginBottom: 16 }}>
        <LoadingState
          status={loadPhase({ loading, error, loaded: stats !== null })}
          label="store data"
          error={error}
          onRetry={loadData}
          testId="store-load-state"
        />
      </div>

      {/* Stat cards */}
      {stats && (
        <div style={{ display: 'flex', gap: 12, marginBottom: 24, flexWrap: 'wrap' }}>
          <StatCard
            label="Total Observations"
            value={String(stats.total_observations)}
            sub="Across all signal layers"
            accent={colors.tealLoom}
          />
          <StatCard
            label="Active Actors"
            value={String(stats.actor_count)}
            sub="Provisional + actionable + promoted"
            accent={colors.cyanLoom}
          />
          <StatCard
            label="Store Type"
            value={stats.store_type.replace(/^\*store\./, '')}
            sub="Columnar signal store backend"
            accent="var(--text)"
          />
          <StatCard
            label="Last Ingestion"
            value={stats.last_ingestion ? new Date(stats.last_ingestion).toLocaleTimeString('en-GB') : 'Never'}
            sub={stats.last_ingestion ? formatTimestamp(stats.last_ingestion) : 'No observations ingested'}
            accent={colors.amber}
          />
        </div>
      )}

      {/* Observations by Layer */}
      {stats && sortedLayers.length > 0 && (
        <Section title="Observations by Layer" hint="Distribution across signal observation layers">
          <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse' }}>
              <thead>
                <tr style={{ background: 'var(--surface2)', borderBottom: '1px solid var(--border)' }}>
                  <th style={{ padding: '9px 14px', textAlign: 'left', color: 'var(--muted)', fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em' }}>Layer</th>
                  <th style={{ padding: '9px 14px', textAlign: 'right', color: 'var(--muted)', fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em', width: 80 }}>Count</th>
                  <th style={{ padding: '9px 14px', textAlign: 'left', color: 'var(--muted)', fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em' }}>Distribution</th>
                </tr>
              </thead>
              <tbody>
                {sortedLayers.map(([layer, count]) => {
                  const pct = stats.total_observations > 0 ? (count / stats.total_observations) * 100 : 0
                  return (
                    <tr key={layer} style={{ borderBottom: '1px solid var(--border)' }}>
                      <td style={{ ...td }}>{LAYER_LABELS[layer] ?? layer}</td>
                      <td style={{ ...td, textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>{count}</td>
                      <td style={{ ...td, paddingRight: 24 }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                          <div style={{ flex: 1, height: 6, background: 'var(--surface2)', borderRadius: 3, overflow: 'hidden' }}>
                            <div style={{ width: `${pct}%`, height: '100%', background: colors.tealLoom, borderRadius: 3 }} />
                          </div>
                          <span style={{ fontSize: 11, color: 'var(--muted)', fontVariantNumeric: 'tabular-nums', minWidth: 36, textAlign: 'right' }}>{pct.toFixed(0)}%</span>
                        </div>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        </Section>
      )}

      {/* Fidelity Breakdown */}
      {stats && sortedFidelity.length > 0 && (
        <Section title="Observations by Fidelity" hint="Structural quality of evidence tiers">
          <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
            {sortedFidelity.map(([tier, count]) => {
              const color = FIDELITY_COLORS[tier as FidelityTier] ?? colors.muted
              return (
                <div key={tier} className="card" style={{ flex: 1, minWidth: 140, padding: '14px 16px' }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
                    <span style={{ width: 8, height: 8, borderRadius: '50%', background: color, flexShrink: 0 }} />
                    <span style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>{tier}</span>
                  </div>
                  <div style={{ fontSize: 24, fontWeight: 700, color, lineHeight: 1 }}>{count}</div>
                </div>
              )
            })}
          </div>
        </Section>
      )}

      {/* Actors by Status */}
      {stats && stats.actor_count > 0 && (
        <Section title="Actors by Status" hint="Provisional actor lifecycle distribution">
          <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
            {(['provisional', 'actionable', 'promoted'] as const).map((status) => {
              const count = stats.actors_by_status[status] ?? 0
              const statusColors: Record<string, string> = {
                provisional: colors.amber,
                actionable: colors.cyanLoom,
                promoted: colors.tealLoom,
              }
              return (
                <div key={status} className="card" style={{ flex: 1, minWidth: 140, padding: '14px 16px' }}>
                  <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>{status}</div>
                  <div style={{ fontSize: 24, fontWeight: 700, color: statusColors[status] ?? 'var(--text)', lineHeight: 1 }}>{count}</div>
                </div>
              )
            })}
          </div>
        </Section>
      )}

      {/* Raw Observations Browser */}
      {observations.length > 0 && (
        <Section title="Raw Observations" hint={`Last ${observations.length} observations from the store`}>
          <Table headers={['ID', 'Timestamp', 'Layer', 'Fidelity', 'Source', 'Confidence', 'Description']}>
            {observations.map((o) => (
              <tr key={o.id} style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={{ ...td, fontFamily: 'monospace', fontSize: 11 }}>{o.id}</td>
                <td style={{ ...td, fontSize: 12, fontVariantNumeric: 'tabular-nums' }}>{formatTimestamp(o.timestamp)}</td>
                <td style={{ ...td }}>{LAYER_LABELS[o.layer] ?? o.layer}</td>
                <td style={{ ...td }}>
                  <span style={{
                    display: 'inline-flex', alignItems: 'center', gap: 6,
                  }}>
                    <span style={{
                      width: 6, height: 6, borderRadius: '50%',
                      background: FIDELITY_COLORS[o.fidelity] ?? colors.muted,
                    }} />
                    {o.fidelity}
                  </span>
                </td>
                <td style={{ ...td, fontFamily: 'monospace', fontSize: 11 }}>{o.source}</td>
                <td style={{ ...td, fontVariantNumeric: 'tabular-nums' }}>{(o.confidence * 100).toFixed(0)}%</td>
                <td style={{ ...td, whiteSpace: 'normal', maxWidth: 300, fontSize: 12 }}>{o.description}</td>
              </tr>
            ))}
          </Table>
        </Section>
      )}

      {/* Actions */}
      <Section title="Actions" hint="Store management operations">
        <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
          <button
            type="button"
            data-testid="action-correlate"
            onClick={() => handleAction('correlate')}
            disabled={actionLoading !== null}
            style={{
              padding: '10px 20px',
              background: colors.cyanLoom,
              color: '#000',
              border: 'none',
              borderRadius: 6,
              fontSize: 13,
              fontWeight: 600,
              cursor: actionLoading !== null ? 'not-allowed' : 'pointer',
              opacity: actionLoading !== null ? 0.6 : 1,
            }}
          >
            {actionLoading === 'correlate' ? 'Running...' : 'Run Correlation'}
          </button>
          <button
            type="button"
            data-testid="action-seed"
            onClick={() => handleAction('seed')}
            disabled={actionLoading !== null}
            style={{
              padding: '10px 20px',
              background: colors.amber,
              color: '#000',
              border: 'none',
              borderRadius: 6,
              fontSize: 13,
              fontWeight: 600,
              cursor: actionLoading !== null ? 'not-allowed' : 'pointer',
              opacity: actionLoading !== null ? 0.6 : 1,
            }}
          >
            {actionLoading === 'seed' ? 'Seeding...' : 'Seed Fixtures'}
          </button>
        </div>
        {actionResult && (
          <div
            data-testid="action-result"
            style={{
              marginTop: 12,
              padding: '8px 14px',
              borderRadius: 6,
              background: 'var(--surface2)',
              color: actionResult.startsWith('Error') ? 'var(--error)' : 'var(--teal)',
              fontSize: 13,
            }}
          >
            {actionResult}
          </div>
        )}
      </Section>
    </div>
  )
}
