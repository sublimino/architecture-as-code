import { useState, useEffect, useCallback, useMemo } from 'react'
import { useSearchParams, Link } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { colors } from '../styles/tokens'
import { StatCard, Section, td } from '../components/DashKit'
import LoadingState, { loadPhase } from '../components/LoadingState'
import DataTable, { type Column } from '../components/DataTable'
import {
  DataTableToolbar,
  ToolbarSearch,
  ToolbarFacet,
  ToolbarSelect,
  ToolbarClear,
  ToolbarCount,
  type ToolbarOption,
} from '../components/DataTableToolbar'
import EmptyState from '../components/EmptyState'
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
  const [searchParams, setSearchParams] = useSearchParams()

  const initialLayer = searchParams.get('layer') || 'all'
  const initialFidelity = searchParams.get('fidelity') || 'all'
  const initialQ = searchParams.get('q') || ''

  const [selectedLayer, setSelectedLayer] = useState<string>(initialLayer)
  const [selectedFidelity, setSelectedFidelity] = useState<string>(initialFidelity)
  const [searchQuery, setSearchQuery] = useState<string>(initialQ)

  const [stats, setStats] = useState<StoreStats | null>(null)
  const [observations, setObservations] = useState<SignalObservation[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [actionLoading, setActionLoading] = useState<string | null>(null)
  const [actionResult, setActionResult] = useState<string | null>(null)

  // Sync state to URL search parameters
  useEffect(() => {
    const params = new URLSearchParams(searchParams)
    if (selectedLayer && selectedLayer !== 'all') params.set('layer', selectedLayer)
    else params.delete('layer')

    if (selectedFidelity && selectedFidelity !== 'all') params.set('fidelity', selectedFidelity)
    else params.delete('fidelity')

    if (searchQuery.trim()) params.set('q', searchQuery.trim())
    else params.delete('q')

    if (params.toString() !== searchParams.toString()) {
      setSearchParams(params, { replace: true })
    }
  }, [selectedLayer, selectedFidelity, searchQuery, searchParams, setSearchParams])

  const loadData = useCallback(async () => {
    setLoading(true)
    try {
      const token = await getAccessTokenSilently()
      const [statsResult, obsResult] = await Promise.all([
        weaveApi.getStoreStats(token),
        weaveApi.getObservations(token, {
          limit: 50,
          layer: selectedLayer && selectedLayer !== 'all' ? selectedLayer : undefined,
        }),
      ])
      setStats(statsResult)
      setObservations(Array.isArray(obsResult) ? obsResult : [])
      setError(null)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load store data')
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently, selectedLayer])

  useEffect(() => { void loadData() }, [loadData])

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
  const filteredObservations = useMemo(() => {
    return observations.filter((obs) => {
      if (selectedLayer !== 'all' && obs.layer !== selectedLayer) {
        return false
      }
      if (selectedFidelity !== 'all' && obs.fidelity !== selectedFidelity) {
        return false
      }
      if (searchQuery.trim()) {
        const q = searchQuery.toLowerCase()
        const text = `${obs.id} ${obs.description} ${obs.source} ${obs.layer} ${obs.fidelity} ${obs.actor_hint || ''}`.toLowerCase()
        if (!text.includes(q)) return false
      }
      return true
    })
  }, [observations, selectedLayer, selectedFidelity, searchQuery])

  const layerCounts = useMemo(() => {
    const map: Record<string, number> = {}
    for (const obs of observations) {
      map[obs.layer] = (map[obs.layer] || 0) + 1
    }
    return map
  }, [observations])

  const layerOptions: ToolbarOption[] = useMemo(() => {
    const opts: ToolbarOption[] = [
      { value: 'all', label: 'All Layers', count: stats?.total_observations ?? observations.length },
    ]
    const allLayers = stats?.observations_by_layer
      ? Object.keys(stats.observations_by_layer)
      : Array.from(new Set(observations.map((o) => o.layer)))
    for (const layer of allLayers) {
      opts.push({
        value: layer,
        label: LAYER_LABELS[layer] ?? layer,
        count: stats?.observations_by_layer?.[layer] ?? (layerCounts[layer] || 0),
      })
    }
    return opts
  }, [stats, observations, layerCounts])

  const fidelityCounts = useMemo(() => {
    const map: Record<string, number> = {}
    for (const obs of observations) {
      map[obs.fidelity] = (map[obs.fidelity] || 0) + 1
    }
    return map
  }, [observations])

  const fidelityOptions: ToolbarOption[] = useMemo(() => {
    const tiers: FidelityTier[] = ['definitive', 'strong', 'suggestive', 'circumstantial']
    return [
      { value: 'all', label: 'All Fidelities', count: stats?.total_observations ?? observations.length },
      ...tiers.map((tier) => ({
        value: tier,
        label: tier.charAt(0).toUpperCase() + tier.slice(1),
        count: stats?.observations_by_fidelity?.[tier] ?? (fidelityCounts[tier] || 0),
      })),
    ]
  }, [stats, observations.length, fidelityCounts])

  const hasFilters = selectedLayer !== 'all' || selectedFidelity !== 'all' || searchQuery.trim() !== ''

  const handleClearFilters = () => {
    setSelectedLayer('all')
    setSelectedFidelity('all')
    setSearchQuery('')
  }

  const observationColumns: Column<SignalObservation>[] = [
    {
      key: 'id',
      label: 'ID',
      sortable: true,
      accessor: (o) => o.id,
    },
    {
      key: 'timestamp',
      label: 'Timestamp',
      sortable: true,
      accessor: (o) => (o.timestamp ? new Date(o.timestamp).getTime() : 0),
    },
    {
      key: 'layer',
      label: 'Layer',
      sortable: true,
      accessor: (o) => o.layer,
    },
    {
      key: 'fidelity',
      label: 'Fidelity',
      sortable: true,
      accessor: (o) => o.fidelity,
    },
    {
      key: 'source',
      label: 'Source',
      sortable: true,
      accessor: (o) => o.source,
    },
    {
      key: 'confidence',
      label: 'Confidence',
      sortable: true,
      accessor: (o) => o.confidence,
    },
    {
      key: 'description',
      label: 'Description',
    },
  ]

  const toolbar = (
    <DataTableToolbar label="Filter store observations">
      <ToolbarSearch
        label="Search store observations"
        placeholder="Filter ID, description, source, layer..."
        value={searchQuery}
        onChange={setSearchQuery}
        testId="store-obs-search"
      />
      <ToolbarFacet
        label="Filter by layer"
        value={selectedLayer}
        options={layerOptions}
        onChange={setSelectedLayer}
        testIdPrefix="store-obs-layer"
      />
      <ToolbarSelect
        label="Fidelity"
        subject="observations"
        value={selectedFidelity}
        options={fidelityOptions}
        onChange={setSelectedFidelity}
        testId="store-obs-fidelity"
      />
      <ToolbarClear
        active={hasFilters}
        onClear={handleClearFilters}
        testId="store-obs-clear"
      />
      <ToolbarCount
        shown={filteredObservations.length}
        total={observations.length}
        noun="observations"
        testId="store-obs-count"
      />
    </DataTableToolbar>
  )

  const emptyState = (
    <div data-testid="store-obs-empty">
      <EmptyState
        kicker="No matching observations"
        body={
          observations.length === 0
            ? 'No observations recorded in the store yet.'
            : `All ${observations.length} observations are retained in the store: the search query, layer facet, or fidelity select is hiding them.`
        }
      />
      {hasFilters && (
        <div style={{ display: 'flex', justifyContent: 'center', marginTop: -34, marginBottom: 12 }}>
          <button
            type="button"
            className="btn btn-secondary"
            onClick={handleClearFilters}
            data-testid="store-obs-empty-clear"
            style={{ fontSize: 12, padding: '5px 12px' }}
          >
            Clear filters
          </button>
        </div>
      )}
    </div>
  )

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
        <Section title="Observations by Layer" hint="Distribution across signal observation layers: click a row to filter table below">
          {selectedLayer !== 'all' && (
            <div
              data-testid="store-active-layer-banner"
              style={{
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                padding: '8px 12px',
                marginBottom: 12,
                borderRadius: 6,
                background: 'rgba(45, 212, 191, 0.1)',
                border: '1px solid rgba(45, 212, 191, 0.3)',
                fontSize: 12,
              }}
            >
              <span>
                Filtered by layer: <strong>{LAYER_LABELS[selectedLayer] ?? selectedLayer}</strong> ({stats.observations_by_layer[selectedLayer] ?? 0} observations in store)
              </span>
              <button
                type="button"
                className="btn btn-secondary"
                data-testid="store-clear-layer-filter"
                onClick={() => setSelectedLayer('all')}
                style={{ fontSize: 11, padding: '2px 8px' }}
              >
                Clear filter
              </button>
            </div>
          )}
          <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse' }}>
              <thead>
                <tr style={{ background: 'var(--surface2)', borderBottom: '1px solid var(--border)' }}>
                  <th style={{ padding: '9px 14px', textAlign: 'left', color: 'var(--muted)', fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em' }}>Layer</th>
                  <th style={{ padding: '9px 14px', textAlign: 'right', color: 'var(--muted)', fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em', width: 80 }}>Count</th>
                  <th style={{ padding: '9px 14px', textAlign: 'left', color: 'var(--muted)', fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em' }}>Distribution</th>
                  <th style={{ padding: '9px 14px', textAlign: 'right', color: 'var(--muted)', fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em', width: 140 }}>Explore</th>
                </tr>
              </thead>
              <tbody>
                {sortedLayers.map(([layer, count]) => {
                  const pct = stats.total_observations > 0 ? (count / stats.total_observations) * 100 : 0
                  const isSelected = selectedLayer === layer
                  return (
                    <tr
                      key={layer}
                      data-testid={`store-layer-row-${layer}`}
                      onClick={() => setSelectedLayer(isSelected ? 'all' : layer)}
                      style={{
                        borderBottom: '1px solid var(--border)',
                        cursor: 'pointer',
                        background: isSelected ? 'rgba(45, 212, 191, 0.08)' : undefined,
                        transition: 'background 0.15s',
                      }}
                      role="button"
                      tabIndex={0}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter' || e.key === ' ') {
                          e.preventDefault()
                          setSelectedLayer(isSelected ? 'all' : layer)
                        }
                      }}
                    >
                      <td style={{ ...td }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                          {isSelected && (
                            <span
                              style={{
                                width: 6,
                                height: 6,
                                borderRadius: '50%',
                                background: colors.tealLoom,
                              }}
                            />
                          )}
                          <span style={{ fontWeight: isSelected ? 600 : 400 }}>
                            {LAYER_LABELS[layer] ?? layer}
                          </span>
                        </div>
                      </td>
                      <td style={{ ...td, textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>{count}</td>
                      <td style={{ ...td, paddingRight: 24 }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                          <div style={{ flex: 1, height: 6, background: 'var(--surface2)', borderRadius: 3, overflow: 'hidden' }}>
                            <div style={{ width: `${pct}%`, height: '100%', background: colors.tealLoom, borderRadius: 3 }} />
                          </div>
                          <span style={{ fontSize: 11, color: 'var(--muted)', fontVariantNumeric: 'tabular-nums', minWidth: 36, textAlign: 'right' }}>{pct.toFixed(0)}%</span>
                        </div>
                      </td>
                      <td style={{ ...td, textAlign: 'right', whiteSpace: 'nowrap' }} onClick={(e) => e.stopPropagation()}>
                        <div style={{ display: 'inline-flex', gap: 8, fontSize: 11 }}>
                          <Link
                            to={`/signals?layer=${encodeURIComponent(layer)}`}
                            style={{ color: colors.tealLoom, textDecoration: 'none' }}
                            title={`View ${LAYER_LABELS[layer] ?? layer} in Live Signals`}
                          >
                            Live Signals
                          </Link>
                          <span style={{ color: 'var(--border)' }}>|</span>
                          <Link
                            to={`/feeds?layer=${encodeURIComponent(layer)}`}
                            style={{ color: colors.tealLoom, textDecoration: 'none' }}
                            title={`View ${LAYER_LABELS[layer] ?? layer} in Feeds Explorer`}
                          >
                            Feeds
                          </Link>
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
          <div className="card" data-testid="raw-observations-super-table" style={{ padding: 14 }}>
            <DataTable
              columns={observationColumns}
              data={filteredObservations}
              pageSize={10}
              toolbar={toolbar}
              emptyState={emptyState}
              renderRow={(o) => (
                <tr key={o.id} style={{ borderBottom: '1px solid var(--border)' }}>
                  <td
                    style={{
                      ...DataTable.td,
                      fontFamily: 'monospace',
                      fontSize: 11,
                      wordBreak: 'break-all',
                      whiteSpace: 'normal',
                      lineHeight: 1.35,
                      maxWidth: 220,
                    }}
                  >
                    {o.id}
                  </td>
                  <td style={{ ...DataTable.td, fontSize: 12, fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap' }}>
                    {formatTimestamp(o.timestamp)}
                  </td>
                  <td style={{ ...DataTable.td, whiteSpace: 'nowrap' }}>{LAYER_LABELS[o.layer] ?? o.layer}</td>
                  <td style={{ ...DataTable.td, whiteSpace: 'nowrap' }}>
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                      <span
                        style={{
                          width: 6,
                          height: 6,
                          borderRadius: '50%',
                          background: FIDELITY_COLORS[o.fidelity] ?? colors.muted,
                        }}
                      />
                      {o.fidelity}
                    </span>
                  </td>
                  <td style={{ ...DataTable.td, fontFamily: 'monospace', fontSize: 11, wordBreak: 'break-all', whiteSpace: 'normal' }}>
                    {o.source}
                  </td>
                  <td style={{ ...DataTable.td, fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap' }}>
                    {(o.confidence * 100).toFixed(0)}%
                  </td>
                  <td style={{ ...DataTable.td, whiteSpace: 'normal', wordBreak: 'break-word', fontSize: 12, lineHeight: 1.4 }}>
                    {o.description}
                  </td>
                </tr>
              )}
            />
          </div>
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
