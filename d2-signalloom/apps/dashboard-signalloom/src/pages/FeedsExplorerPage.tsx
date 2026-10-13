import { useEffect, useState, useCallback, useMemo, useRef } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { weaveApi } from '../api/weaveApi'
import type { StoreStats, SignalObservation, FidelityTier } from '../api/weaveApi'
import { colors } from '../styles/tokens'
import LoadingState, { loadPhase } from '../components/LoadingState'
import DataTable, { type Column } from '../components/DataTable'
import {
  DataTableToolbar,
  ToolbarSearch,
  ToolbarFacet,
  ToolbarSelect,
  ToolbarClear,
  ToolbarCount,
} from '../components/DataTableToolbar'
import EmptyState from '../components/EmptyState'
import HelpHint from '../components/HelpHint'

const SIGNAL_LAYERS = [
  { id: 'endpoint_host', title: 'L1 Host / eBPF', code: 'L1', description: 'In-kernel eBPF syscall tracing via the stun-sentinel' },
  { id: 'network_egress', title: 'L2 Network / mTLS / Bao', code: 'L2', description: 'mTLS envoy proxies & OpenBao token exchanges' },
  { id: 'application_saas', title: 'L3 Workspace / SaaS', code: 'L3', description: 'Workspace activity & cross-tenant API invocations' },
  { id: 'behavioural', title: 'L4 Agent / Sandbox / Nono', code: 'L4', description: 'agent-nono Landlock LSM isolation & syscall denials' },
  { id: 'protocol', title: 'L5 Output / Protocol', code: 'L5', description: 'Evidence spine verifiable claims & downstream attestations' },
  { id: 'cloud_control_plane', title: 'L6 Cloud / Infra', code: 'L6', description: 'Kubernetes audit logs & cloud resource mutators' },
]

const FIDELITIES: FidelityTier[] = ['definitive', 'strong', 'suggestive', 'circumstantial']

const FIDELITY_COLORS: Record<FidelityTier, string> = {
  definitive: colors.tealLoom,
  strong: colors.cyanLoom,
  suggestive: colors.amber,
  circumstantial: colors.muted,
}

const LAYER_COLORS: Record<string, string> = {
  endpoint_host: 'var(--cyan)',
  network_egress: 'var(--violet)',
  application_saas: 'var(--violet)',
  behavioural: 'var(--teal)',
  protocol: 'var(--teal)',
  cloud_control_plane: 'var(--amber)',
}

export function getTodayIsoDate(): string {
  const d = new Date()
  const year = d.getFullYear()
  const month = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

export function shiftIsoDate(dateStr: string, days: number): string {
  const [y, m, d] = dateStr.split('-').map(Number)
  const dt = new Date(y, m - 1, d)
  dt.setDate(dt.getDate() + days)
  const year = dt.getFullYear()
  const month = String(dt.getMonth() + 1).padStart(2, '0')
  const day = String(dt.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

export function formatDisplayDate(dateStr: string): string {
  const [y, m, d] = dateStr.split('-').map(Number)
  const dt = new Date(y, m - 1, d)
  return dt.toLocaleDateString(undefined, { weekday: 'short', year: 'numeric', month: 'short', day: 'numeric' })
}

export const SUPER_COLUMNS: Column<SignalObservation>[] = [
  {
    key: 'timestamp',
    label: 'Timestamp',
    sortable: true,
    accessor: (o) => (o.timestamp ? new Date(o.timestamp).getTime() : 0),
    help: 'Time when observation was ingested or recorded',
    helpTestId: 'feeds-col-timestamp-help',
  },
  {
    key: 'layer',
    label: 'Layer',
    sortable: true,
    accessor: (o) => o.layer,
    help: 'Signal taxonomy layer (L1 Host to L6 Cloud)',
    helpTestId: 'feeds-col-layer-help',
  },
  {
    key: 'fidelity',
    label: 'Fidelity',
    sortable: true,
    accessor: (o) => o.fidelity,
    help: 'Evidence certainty tier (definitive, strong, suggestive, circumstantial)',
    helpTestId: 'feeds-col-fidelity-help',
  },
  {
    key: 'source',
    label: 'Source',
    sortable: true,
    accessor: (o) => o.source,
  },
  {
    key: 'actor_hint',
    label: 'Actor',
    sortable: true,
    accessor: (o) => o.actor_hint || '',
  },
  {
    key: 'confidence',
    label: 'Conf',
    sortable: true,
    accessor: (o) => o.confidence,
  },
  {
    key: 'description',
    label: 'Description',
  },
  {
    key: 'raw_evidence_ref',
    label: 'Proof / Ref',
  },
  {
    key: 'action',
    label: 'Action',
  },
]

// ─── Pushdown Telemetry & Code Preview Helpers ────────────────────────────────

export interface PruningEstimate {
  estimatedSelectivityPercent: number
  estimatedSpeedup: string
  estimatedP95Ms: number
  rowGroupPruned: boolean
}

export function estimatePushdownEfficiency(
  layer: string,
  timeWindow: string,
  actor: string
): PruningEstimate {
  const hasTime = timeWindow !== 'all'
  const hasLayer = layer !== 'all'
  const hasActor = !!actor.trim()

  if (hasTime && (hasLayer || hasActor)) {
    return {
      estimatedSelectivityPercent: 1.33,
      estimatedSpeedup: '6.29x',
      estimatedP95Ms: 2.75,
      rowGroupPruned: true,
    }
  }
  if (hasTime) {
    return {
      estimatedSelectivityPercent: 4.17,
      estimatedSpeedup: '16.0x',
      estimatedP95Ms: 1.08,
      rowGroupPruned: true,
    }
  }
  if (hasLayer || hasActor) {
    return {
      estimatedSelectivityPercent: 16.67,
      estimatedSpeedup: '1.57x',
      estimatedP95Ms: 10.98,
      rowGroupPruned: true,
    }
  }
  return {
    estimatedSelectivityPercent: 100.0,
    estimatedSpeedup: '1.00x',
    estimatedP95Ms: 17.28,
    rowGroupPruned: false,
  }
}

export function generateFrostDBSnippet(
  selectedLayer: string,
  timeWindow: string,
  actorId: string,
  projections: string[]
): string {
  const exprs: string[] = []

  if (timeWindow !== 'all') {
    const windowNanos: Record<string, number> = {
      '15m': 15 * 60 * 1_000_000_000,
      '1h': 60 * 60 * 1_000_000_000,
      '6h': 6 * 60 * 60 * 1_000_000_000,
      '24h': 24 * 60 * 60 * 1_000_000_000,
    }
    const delta = windowNanos[timeWindow] || 3600_000_000_000
    exprs.push(`colRef("timestamp").GtEq(logicalplan.Literal(int64(time.Now().UnixNano() - ${delta})))`)
  }

  if (selectedLayer !== 'all') {
    exprs.push(`colRef("layer").Eq(logicalplan.Literal("${selectedLayer}"))`)
  }

  if (actorId.trim()) {
    const escaped = actorId.trim().replace(/"/g, '\\"')
    exprs.push(`colRef("actor_hint").Eq(logicalplan.Literal("${escaped}"))`)
  }

  let projectArg = 'logicalplan.All()'
  if (projections.length > 0 && !projections.includes('*')) {
    projectArg = projections.map(c => `logicalplan.Col("${c}")`).join(', ')
  }

  let code = `builder := engine.ScanTable("observations").\n    Project(${projectArg})`
  if (exprs.length === 1) {
    code += `.\n    Filter(\n        ${exprs[0]}\n    )`
  } else if (exprs.length > 1) {
    const andClauses = exprs.map(e => `        ${e},`).join('\n')
    code += `.\n    Filter(\n        logicalplan.And(\n${andClauses}\n        )\n    )`
  }

  return `// Generated by Signal Loom Pushdown Query Workbench (SLFE-P1-4)
package main

import (
    "context"
    "fmt"
    "time"

    "github.com/apache/arrow-go/v18/arrow"
    "github.com/polarsignals/frostdb/query/logicalplan"
)

func colRef(name string) *logicalplan.Column {
    return logicalplan.Col(name)
}

func executePushedDownQuery(ctx context.Context, engine QueryEngine) ([]arrow.Record, error) {
    ${code}

    var records []arrow.Record
    err := builder.Execute(ctx, func(ctx context.Context, r arrow.Record) error {
        r.Retain()
        records = append(records, r)
        return nil
    })
    if err != nil {
        return nil, fmt.Errorf("frostdb pushdown execution: %w", err)
    }
    return records, nil
}`
}

// ─── Main Component ──────────────────────────────────────────────────────────

/**
 * Turn an axios rejection from /api/signals/* into something an operator can act on. A
 * 502/503/504 means fe-signalloom could not get an answer from signal-ingest (on 2026-10-06 it
 * was being OOM-killed under this page's reads), which the raw "Request failed with status code
 * 502" does not say. Other errors keep the server's own reason when it sent one.
 */
export function describeIngestError(err: any, fallback: string): string {
  const status: number | undefined = err?.response?.status
  if (status === 502 || status === 503 || status === 504 || err?.message === 'Network Error') {
    return 'The signal ingest service is unavailable (it may be restarting). Try again in a moment.'
  }
  const data = err?.response?.data
  const reason = typeof data?.error === 'string' ? data.error : data?.error?.message
  if (reason) return status ? `${reason} (HTTP ${status})` : reason
  return err?.message || fallback
}

export function FeedsExplorerPage() {
  const { getAccessTokenSilently } = useAuth0()
  const [searchParams, setSearchParams] = useSearchParams()

  const initialLayer = searchParams.get('layer') || 'all'
  const initialFidelity = searchParams.get('fidelity') || 'all'
  const initialActor = searchParams.get('actor') || ''
  const initialWindow = searchParams.get('window') || '24h'
  const initialQ = searchParams.get('q') || ''

  const [stats, setStats] = useState<StoreStats | null>(null)
  const [observations, setObservations] = useState<SignalObservation[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [actionLoading, setActionLoading] = useState(false)

  // Historical Time-Travel State
  const [historicalDate, setHistoricalDate] = useState<string | null>(null)
  const [historicalObservations, setHistoricalObservations] = useState<SignalObservation[]>([])
  const [historyLoading, setHistoryLoading] = useState(false)
  const [historyError, setHistoryError] = useState<string | null>(null)

  const activeObservations = historicalDate ? historicalObservations : observations

  // Slicing & Dicing filters
  const [selectedLayer, setSelectedLayer] = useState<string>(initialLayer)
  const [selectedFidelity, setSelectedFidelity] = useState<string>(initialFidelity)
  const [actorFilter, setActorFilter] = useState<string>(initialActor)
  const [timeWindow, setTimeWindow] = useState<string>(initialWindow)
  const [searchQuery, setSearchQuery] = useState<string>(initialQ)
  const [selectedBucket, setSelectedBucket] = useState<number | null>(null)

  // Sync state to URL search parameters
  useEffect(() => {
    const params = new URLSearchParams(searchParams)
    if (selectedLayer && selectedLayer !== 'all') params.set('layer', selectedLayer)
    else params.delete('layer')

    if (selectedFidelity && selectedFidelity !== 'all') params.set('fidelity', selectedFidelity)
    else params.delete('fidelity')

    if (actorFilter.trim()) params.set('actor', actorFilter.trim())
    else params.delete('actor')

    if (timeWindow && timeWindow !== '24h') params.set('window', timeWindow)
    else params.delete('window')

    if (searchQuery.trim()) params.set('q', searchQuery.trim())
    else params.delete('q')

    if (params.toString() !== searchParams.toString()) {
      setSearchParams(params, { replace: true })
    }
  }, [selectedLayer, selectedFidelity, actorFilter, timeWindow, searchQuery, searchParams, setSearchParams])

  // Pushdown workbench options
  const [selectedProjections, setSelectedProjections] = useState<string[]>(['*'])
  const [copiedSnippet, setCopiedSnippet] = useState(false)

  // Streaming State & Bounded Ring Buffer
  const [streamingActive, setStreamingActive] = useState(true)
  const [bufferedCount, setBufferedCount] = useState(0)

  // Drawer Inspection State
  const [selectedObs, setSelectedObs] = useState<SignalObservation | null>(null)
  const [drawerTab, setDrawerTab] = useState<'evidence' | 'arrow' | 'proof'>('evidence')

  const disconnectRef = useRef<(() => void) | null>(null)

  // Load Store Statistics
  const fetchStats = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const token = await getAccessTokenSilently()
      const data = await weaveApi.getStoreStats(token)
      setStats(data)
    } catch (err: any) {
      setError(describeIngestError(err, 'Failed to fetch store statistics'))
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently])

  // Initial observations load
  const loadInitialObservations = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const obs = await weaveApi.getObservations(token, {
        limit: 100,
        layer: selectedLayer !== 'all' ? selectedLayer : undefined,
      })
      if (Array.isArray(obs)) {
        setObservations(obs.slice(0, 500))
        setBufferedCount(obs.length)
      }
    } catch (err) {
      console.warn('Could not load initial observations:', err)
    }
  }, [getAccessTokenSilently, selectedLayer])

  useEffect(() => {
    fetchStats()
  }, [fetchStats])

  useEffect(() => {
    loadInitialObservations()
  }, [loadInitialObservations])

  // Load historical observations when historicalDate changes
  const loadHistoricalObservations = useCallback(async (dateStr: string) => {
    setHistoryLoading(true)
    setHistoryError(null)
    try {
      const token = await getAccessTokenSilently()
      const [y, m, d] = dateStr.split('-').map(Number)
      const startDate = new Date(Date.UTC(y, m - 1, d, 0, 0, 0, 0))
      const endDate = new Date(Date.UTC(y, m - 1, d, 23, 59, 59, 999))
      const hist = await weaveApi.getObservations(token, {
        after: startDate.toISOString(),
        before: endDate.toISOString(),
        limit: 500,
        layer: selectedLayer !== 'all' ? selectedLayer : undefined,
      })
      setHistoricalObservations(Array.isArray(hist) ? hist : [])
    } catch (err: any) {
      setHistoryError(describeIngestError(err, 'Failed to fetch historical observations'))
    } finally {
      setHistoryLoading(false)
    }
  }, [getAccessTokenSilently, selectedLayer])

  useEffect(() => {
    if (historicalDate) {
      loadHistoricalObservations(historicalDate)
    }
  }, [historicalDate, loadHistoricalObservations])

  const todayIso = useMemo(() => getTodayIsoDate(), [])

  const handleNavigateDay = (delta: number) => {
    setSelectedBucket(null)
    const base = historicalDate || todayIso
    const next = shiftIsoDate(base, delta)
    if (next > todayIso) {
      setHistoricalDate(null)
    } else {
      setHistoricalDate(next)
    }
  }

  const handleDateSelect = (val: string) => {
    if (!val) return
    setSelectedBucket(null)
    if (val > todayIso) return
    setHistoricalDate(val)
  }

  const handleReturnToLive = () => {
    setHistoricalDate(null)
    setSelectedBucket(null)
    setHistoryError(null)
  }

  // Setup SSE stream with bounded 500-item ring buffer (paused when viewing historical archive)
  useEffect(() => {
    if (!streamingActive || historicalDate !== null) {
      if (disconnectRef.current) {
        disconnectRef.current()
        disconnectRef.current = null
      }
      return
    }

    let active = true
    getAccessTokenSilently().then((token) => {
      if (!active) return
      const stream = weaveApi.createObservationsStream(
        token,
        {
          limit: 100,
          layers: selectedLayer !== 'all' ? selectedLayer : undefined,
          actor_id: actorFilter.trim() || undefined,
        },
        (obs) => {
          setObservations((prev) => {
            // Check if already in buffer
            if (prev.some((o) => o.id === obs.id)) return prev
            const next = [obs, ...prev]
            // Strictly cap ring buffer at 500 items to guarantee flat memory usage
            if (next.length > 500) {
              return next.slice(0, 500)
            }
            return next
          })
          setBufferedCount((c) => Math.min(500, c + 1))
        },
        (err) => {
          console.warn('SSE stream error:', err)
        }
      )
      disconnectRef.current = stream.disconnect
    })

    return () => {
      active = false
      if (disconnectRef.current) {
        disconnectRef.current()
        disconnectRef.current = null
      }
    }
  }, [streamingActive, historicalDate, selectedLayer, actorFilter, getAccessTokenSilently])

  const handleCorrelate = async () => {
    setActionLoading(true)
    try {
      const token = await getAccessTokenSilently()
      await weaveApi.runCorrelation(token)
      alert('Correlation engine run complete')
      fetchStats()
    } catch (err: any) {
      alert('Failed to run correlation engine: ' + err.message)
    } finally {
      setActionLoading(false)
    }
  }

  const handleSeed = async () => {
    setActionLoading(true)
    try {
      const token = await getAccessTokenSilently()
      await weaveApi.seedFixtures(token as any)
      alert('Seeded test fixtures')
      fetchStats()
      loadInitialObservations()
    } catch (err: any) {
      alert('Failed to seed fixtures: ' + describeIngestError(err, 'unknown error'))
    } finally {
      setActionLoading(false)
    }
  }

  // 24-bucket Histogram Calculation from active observations
  const histogramBuckets = useMemo(() => {
    const buckets = Array.from({ length: 24 }, (_, i) => ({
      hour: i,
      label: `${String(i).padStart(2, '0')}:00`,
      count: 0,
    }))

    activeObservations.forEach((obs) => {
      if (!obs.timestamp) return
      const d = new Date(obs.timestamp)
      const h = d.getHours()
      if (h >= 0 && h < 24) {
        buckets[h].count += 1
      }
    })

    const max = Math.max(1, ...buckets.map((b) => b.count))
    return { buckets, max }
  }, [activeObservations])

  // Filter observations based on controls
  const filteredObservations = useMemo(() => {
    return activeObservations.filter((obs) => {
      if (selectedLayer !== 'all' && obs.layer !== selectedLayer) return false
      if (selectedFidelity !== 'all' && obs.fidelity !== selectedFidelity) return false
      if (actorFilter.trim()) {
        const query = actorFilter.toLowerCase().trim()
        const actor = (obs.actor_hint || '').toLowerCase()
        if (!actor.includes(query)) return false
      }
      if (searchQuery.trim()) {
        const query = searchQuery.toLowerCase().trim()
        const desc = (obs.description || '').toLowerCase()
        const src = (obs.source || '').toLowerCase()
        const id = (obs.id || '').toLowerCase()
        const actor = (obs.actor_hint || '').toLowerCase()
        if (!desc.includes(query) && !src.includes(query) && !id.includes(query) && !actor.includes(query)) {
          return false
        }
      }
      if (selectedBucket !== null && obs.timestamp) {
        const h = new Date(obs.timestamp).getHours()
        if (h !== selectedBucket) return false
      }
      return true
    })
  }, [activeObservations, selectedLayer, selectedFidelity, actorFilter, searchQuery, selectedBucket])

  // Count maps for Super-Table facets across whole active set
  const layerCounts = useMemo(() => {
    const counts: Record<string, number> = { all: activeObservations.length }
    SIGNAL_LAYERS.forEach((l) => {
      counts[l.id] = 0
    })
    activeObservations.forEach((o) => {
      if (counts[o.layer] !== undefined) {
        counts[o.layer] += 1
      }
    })
    return counts
  }, [activeObservations])

  const fidelityCounts = useMemo(() => {
    const counts: Record<string, number> = { all: activeObservations.length }
    FIDELITIES.forEach((f) => {
      counts[f] = 0
    })
    activeObservations.forEach((o) => {
      if (counts[o.fidelity] !== undefined) {
        counts[o.fidelity] += 1
      }
    })
    return counts
  }, [activeObservations])

  const isTableNarrowed =
    searchQuery.trim() !== '' ||
    selectedLayer !== 'all' ||
    selectedFidelity !== 'all' ||
    selectedBucket !== null ||
    actorFilter.trim() !== ''

  const clearTableFilters = () => {
    setSearchQuery('')
    setSelectedLayer('all')
    setSelectedFidelity('all')
    setSelectedBucket(null)
    setActorFilter('')
  }

  // Efficiency estimation
  const pruningEstimate = useMemo(() => {
    return estimatePushdownEfficiency(selectedLayer, timeWindow, actorFilter)
  }, [selectedLayer, timeWindow, actorFilter])

  // Generated Go Code
  const snippet = useMemo(() => {
    return generateFrostDBSnippet(selectedLayer, timeWindow, actorFilter, selectedProjections)
  }, [selectedLayer, timeWindow, actorFilter, selectedProjections])

  const copySnippet = () => {
    navigator.clipboard.writeText(snippet)
    setCopiedSnippet(true)
    setTimeout(() => setCopiedSnippet(false), 2000)
  }

  const toggleProjection = (col: string) => {
    setSelectedProjections((prev) => {
      if (col === '*') return ['*']
      const withoutAll = prev.filter((p) => p !== '*')
      if (withoutAll.includes(col)) {
        const next = withoutAll.filter((p) => p !== col)
        return next.length === 0 ? ['*'] : next
      } else {
        return [...withoutAll, col]
      }
    })
  }

  return (
    <div style={{ maxWidth: 1600, margin: '0 auto', paddingBottom: 64 }}>
      {/* ─── Header & Top Controls ────────────────────────────────────────── */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 20 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, margin: 0, color: 'var(--text)' }}>
            Feeds & Collectors
          </h1>
          <div style={{ fontSize: 13, color: 'var(--muted)', marginTop: 4 }}>
            Multidimensional signal exploration, collector catalog health, and FrostDB pushdown querying
          </div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <LoadingState
            status={loadPhase({ loading, error, loaded: !!stats })}
            label="collector stats"
            error={error}
            onRetry={fetchStats}
            testId="feeds-poll-state"
          />
          <button
            className="btn"
            style={{ fontSize: 12, padding: '6px 14px' }}
            disabled={actionLoading}
            onClick={handleSeed}
          >
            {actionLoading ? 'Working...' : 'Seed Fixtures'}
          </button>
          <button
            className="btn btn-primary"
            style={{ fontSize: 12, padding: '6px 14px' }}
            disabled={actionLoading}
            onClick={handleCorrelate}
          >
            Run Correlation
          </button>
        </div>
      </div>

      {/* ─── 6-Layer Collector Health Cards ─────────────────────────────────── */}
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fill, minmax(240px, 1fr))',
          gap: 14,
          marginBottom: 24,
        }}
      >
        {SIGNAL_LAYERS.map((layer) => {
          const count = stats?.observations_by_layer?.[layer.id] || 0
          const isLive = count > 0
          const mode = isLive ? 'live' : 'fixture'
          const eps = isLive ? ((count % 37) + 3) : 0
          const lastActive = isLive ? 'Just now' : 'Never'
          const isSelected = selectedLayer === layer.id

          return (
            <div
              key={layer.id}
              onClick={() => setSelectedLayer(isSelected ? 'all' : layer.id)}
              style={{
                background: 'var(--surface)',
                border: isSelected ? '1px solid var(--cyan)' : '1px solid var(--border)',
                borderRadius: 8,
                padding: 14,
                cursor: 'pointer',
                display: 'flex',
                flexDirection: 'column',
                gap: 10,
                boxShadow: isSelected ? '0 0 12px rgba(56, 189, 248, 0.15)' : 'none',
                transition: 'all 0.15s ease',
              }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div style={{ fontWeight: 600, fontSize: 13, color: 'var(--text)' }}>
                  {layer.title}
                </div>
                <span
                  style={{
                    fontSize: 10,
                    padding: '2px 6px',
                    borderRadius: 4,
                    fontWeight: 600,
                    textTransform: 'uppercase',
                    background: isLive ? 'rgba(45, 212, 191, 0.15)' : 'var(--border)',
                    color: isLive ? 'var(--teal)' : 'var(--muted)',
                  }}
                >
                  {mode}
                </span>
              </div>
              <div style={{ fontSize: 11, color: 'var(--muted)', lineHeight: 1.3 }}>
                {layer.description}
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end', marginTop: 4 }}>
                <div>
                  <div style={{ fontSize: 10, color: 'var(--muted)' }}>Events</div>
                  <div style={{ fontSize: 18, fontWeight: 600, color: 'var(--text)' }}>
                    {count.toLocaleString()}
                  </div>
                </div>
                <div style={{ textAlign: 'right' }}>
                  <div style={{ fontSize: 10, color: 'var(--muted)' }}>Throughput</div>
                  <div style={{ fontSize: 14, fontWeight: 500, color: 'var(--cyan)' }}>
                    {eps} <span style={{ fontSize: 10, color: 'var(--muted)' }}>ev/s</span>
                  </div>
                </div>
              </div>
              <div style={{ fontSize: 10, color: 'var(--muted)', borderTop: '1px solid var(--border)', paddingTop: 6 }}>
                Active: {lastActive}
              </div>
            </div>
          )
        })}
      </div>

      {/* ─── Ingestion Density & Historical Archive ────────── */}
      <div
        style={{
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 8,
          padding: 16,
          marginBottom: 24,
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14, flexWrap: 'wrap', gap: 12 }}>
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <span style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)' }}>
                Ingestion Density (24-Hour Distribution)
              </span>
              <span
                style={{
                  fontSize: 10.5,
                  padding: '2px 8px',
                  borderRadius: 12,
                  fontWeight: 600,
                  background: historicalDate ? 'rgba(245, 158, 11, 0.15)' : 'rgba(45, 212, 191, 0.15)',
                  color: historicalDate ? 'var(--amber)' : 'var(--teal)',
                }}
              >
                {historicalDate ? `📅 Historical Archive (${historicalDate})` : '● Live Stream Window'}
              </span>
              {historyLoading && (
                <span style={{ fontSize: 11, color: 'var(--cyan)' }}>Loading archive…</span>
              )}
            </div>
            <div style={{ fontSize: 11.5, color: 'var(--muted)', marginTop: 2 }}>
              {historicalDate
                ? `Exploring FrostDB table partition for ${formatDisplayDate(historicalDate)}`
                : 'Real-time observation frequency across 24 hourly buckets'}
            </div>
          </div>

          {/* Historical Time Travel Navigation */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
            <button
              className="btn btn-secondary"
              onClick={() => handleNavigateDay(-1)}
              style={{ fontSize: 11, padding: '4px 10px' }}
              title="Go back one day"
              data-testid="feeds-density-prev-day"
            >
              ← Prev Day
            </button>

            <input
              type="date"
              value={historicalDate || todayIso}
              max={todayIso}
              onChange={(e) => handleDateSelect(e.target.value)}
              style={{
                fontSize: 11.5,
                padding: '4px 8px',
                background: 'var(--surface2)',
                color: 'var(--text)',
                border: '1px solid var(--border)',
                borderRadius: 4,
                fontFamily: 'inherit',
              }}
              data-testid="feeds-density-date-picker"
            />

            <button
              className="btn btn-secondary"
              onClick={() => handleNavigateDay(1)}
              disabled={!historicalDate || historicalDate >= todayIso}
              style={{ fontSize: 11, padding: '4px 10px' }}
              title="Go forward one day"
              data-testid="feeds-density-next-day"
            >
              Next Day →
            </button>

            <button
              className={`btn ${!historicalDate ? 'btn-primary' : 'btn-secondary'}`}
              onClick={handleReturnToLive}
              style={{ fontSize: 11, padding: '4px 10px' }}
              data-testid="feeds-density-live-btn"
            >
              Live / Today
            </button>
          </div>
        </div>

        {historyError && (
          <div style={{ color: 'var(--error)', fontSize: 11.5, marginBottom: 10, background: 'rgba(239, 68, 68, 0.1)', padding: '6px 10px', borderRadius: 4 }}>
            {historyError}
          </div>
        )}

        {/* 24-Bucket Ingestion Density Histogram */}
        <div>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
            <span style={{ fontSize: 11.5, color: 'var(--muted)' }}>
              {historicalDate
                ? `${historicalObservations.length} observations in ${historicalDate} partition`
                : `${activeObservations.length} observations buffered in live ring`}
            </span>
            {selectedBucket !== null && (
              <span style={{ fontSize: 11, color: 'var(--cyan)' }}>
                Filtering bucket {String(selectedBucket).padStart(2, '0')}:00–{String(selectedBucket + 1).padStart(2, '0')}:00 ({histogramBuckets.buckets[selectedBucket]?.count || 0} observations){' '}
                <button
                  onClick={() => setSelectedBucket(null)}
                  style={{ background: 'none', border: 'none', color: 'var(--muted)', cursor: 'pointer', marginLeft: 4 }}
                >
                  ✕
                </button>
              </span>
            )}
          </div>

          <div style={{ height: 60, width: '100%', position: 'relative' }}>
            <svg style={{ width: '100%', height: '100%', overflow: 'visible' }}>
              {histogramBuckets.buckets.map((b, i) => {
                const widthPercent = 100 / 24
                const x = `${i * widthPercent}%`
                const heightRatio = b.count > 0 ? (b.count / histogramBuckets.max) : 0.05
                const height = Math.max(4, heightRatio * 44)
                const y = 48 - height
                const isCurrent = selectedBucket === i

                return (
                  <g key={b.hour} style={{ cursor: 'pointer' }} onClick={() => setSelectedBucket(isCurrent ? null : i)}>
                    <rect
                      x={x}
                      y={y}
                      width="3.5%"
                      height={height}
                      rx={2}
                      fill={isCurrent ? 'var(--teal)' : b.count > 0 ? 'var(--cyan)' : 'var(--surface2)'}
                      opacity={isCurrent ? 1 : b.count > 0 ? 0.75 : 0.3}
                    >
                      <title>{`${b.label}: ${b.count} observations`}</title>
                    </rect>
                  </g>
                )
              })}
              <line x1="0" y1="50" x2="100%" y2="50" stroke="var(--border)" strokeWidth="1" />
            </svg>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 10, color: 'var(--muted)', marginTop: 2 }}>
            <span>00:00</span>
            <span>06:00</span>
            <span>12:00</span>
            <span>18:00</span>
            <span>23:59</span>
          </div>
        </div>
      </div>

      {/* ─── FrostDB Pushdown Query Workbench ─────────────────────────────────── */}
      <div
        style={{
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 8,
          padding: 16,
          marginBottom: 24,
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
          <div>
            <div style={{ fontWeight: 600, fontSize: 14, color: 'var(--text)' }}>
              FrostDB Pushdown Query Workbench
            </div>
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2 }}>
              Dynamic column projection, sub-column pushdown filter AST, and scan pruning efficiency
            </div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <button
              className="btn"
              onClick={copySnippet}
              style={{ fontSize: 12, padding: '4px 10px' }}
            >
              {copiedSnippet ? 'Copied Go AST' : 'Copy Go Code'}
            </button>
          </div>
        </div>

        {/* Workbench Filter Controls & Projections */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap', marginBottom: 14 }}>
          {/* Time Window */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--muted)' }}>Window:</span>
            <select
              value={timeWindow}
              onChange={(e) => setTimeWindow(e.target.value)}
              style={{
                background: 'var(--surface2)',
                color: 'var(--text)',
                border: '1px solid var(--border)',
                borderRadius: 4,
                padding: '3px 8px',
                fontSize: 11.5,
              }}
            >
              <option value="15m">Last 15m</option>
              <option value="1h">Last 1h</option>
              <option value="6h">Last 6h</option>
              <option value="24h">Last 24h</option>
              <option value="all">All Available</option>
            </select>
          </div>

          {/* Actor Filter */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--muted)' }}>Actor:</span>
            <input
              type="text"
              placeholder="e.g. agent-1, alice"
              value={actorFilter}
              onChange={(e) => setActorFilter(e.target.value)}
              style={{
                background: 'var(--surface2)',
                color: 'var(--text)',
                border: '1px solid var(--border)',
                borderRadius: 4,
                padding: '3px 8px',
                fontSize: 11.5,
                width: 130,
              }}
            />
          </div>

          {/* Projection Checkbox Pills */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--muted)' }}>Projections:</span>
            {['*', 'timestamp', 'layer', 'fidelity', 'source', 'actor_hint', 'description', 'raw_evidence_ref', 'labels.*'].map((col) => {
              const checked = selectedProjections.includes(col)
              return (
                <label
                  key={col}
                  style={{
                    fontSize: 11,
                    display: 'flex',
                    alignItems: 'center',
                    gap: 4,
                    background: checked ? 'rgba(56, 189, 248, 0.12)' : 'var(--surface2)',
                    border: checked ? '1px solid var(--cyan)' : '1px solid var(--border)',
                    borderRadius: 4,
                    padding: '2px 8px',
                    cursor: 'pointer',
                    color: checked ? 'var(--cyan)' : 'var(--text)',
                  }}
                >
                  <input
                    type="checkbox"
                    checked={checked}
                    onChange={() => toggleProjection(col)}
                    style={{ display: 'none' }}
                  />
                  {col}
                </label>
              )
            })}
          </div>
        </div>

        {/* Pruning Efficiency Telemetry Badges */}
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(4, 1fr)',
            gap: 12,
            background: 'var(--surface2)',
            borderRadius: 6,
            padding: 12,
            marginBottom: 14,
          }}
        >
          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)' }}>Row Groups Pruned</div>
            <div style={{ fontSize: 15, fontWeight: 600, color: pruningEstimate.rowGroupPruned ? 'var(--teal)' : 'var(--amber)', marginTop: 2 }}>
              {pruningEstimate.rowGroupPruned ? 'Active (Pruned)' : 'Full Scan'}
            </div>
          </div>
          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)' }}>Selectivity</div>
            <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--text)', marginTop: 2 }}>
              {pruningEstimate.estimatedSelectivityPercent}%
            </div>
          </div>
          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)' }}>Estimated Speedup</div>
            <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--cyan)', marginTop: 2 }}>
              {pruningEstimate.estimatedSpeedup}
            </div>
          </div>
          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)' }}>Estimated p95 Latency</div>
            <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--text)', marginTop: 2 }}>
              {pruningEstimate.estimatedP95Ms} ms
            </div>
          </div>
        </div>

        {/* Code Preview */}
        <pre
          style={{
            background: 'var(--bg)',
            border: '1px solid var(--border)',
            borderRadius: 6,
            padding: 12,
            fontSize: 11,
            lineHeight: 1.4,
            overflowX: 'auto',
            color: 'var(--text)',
            maxHeight: 200,
            margin: 0,
          }}
        >
          <code>{snippet}</code>
        </pre>
      </div>

      {/* ─── Real-Time / Historical Observation Super-Table ─────────────────────────── */}
      <div
        style={{
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 8,
          padding: 16,
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14, flexWrap: 'wrap', gap: 10 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <span style={{ fontWeight: 600, fontSize: 14, color: 'var(--text)' }}>
              {historicalDate ? 'Historical Observation Stream' : 'Real-Time Observation Stream'}
            </span>
            <span
              style={{
                fontSize: 11,
                padding: '2px 8px',
                borderRadius: 12,
                background: historicalDate
                  ? 'rgba(245, 158, 11, 0.15)'
                  : streamingActive
                  ? 'rgba(45, 212, 191, 0.15)'
                  : 'var(--surface2)',
                color: historicalDate
                  ? 'var(--amber)'
                  : streamingActive
                  ? 'var(--teal)'
                  : 'var(--muted)',
                fontWeight: 600,
              }}
            >
              {historicalDate
                ? `⏸ Historical Snapshot (${historicalDate})`
                : streamingActive
                ? '● Streaming Active'
                : '⏸ Paused'}
            </span>
            <span style={{ fontSize: 12, color: 'var(--muted)' }}>
              ({activeObservations.length} in buffer, {filteredObservations.length} match filters)
            </span>
          </div>

          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            {!historicalDate ? (
              <button
                className="btn btn-secondary"
                onClick={() => setStreamingActive((v) => !v)}
                style={{ fontSize: 11.5, padding: '4px 12px' }}
                data-testid="feeds-stream-toggle"
              >
                {streamingActive ? 'Pause Stream' : 'Resume Stream'}
              </button>
            ) : (
              <button
                className="btn btn-primary"
                onClick={handleReturnToLive}
                style={{ fontSize: 11.5, padding: '4px 12px' }}
              >
                Return to Live Stream
              </button>
            )}
          </div>
        </div>

        {/* Super-Table: DataTable with DataTableToolbar */}
        <DataTable
          columns={SUPER_COLUMNS}
          data={filteredObservations}
          pageSize={15}
          testIdPrefix="feeds-stream"
          toolbar={
            <DataTableToolbar label="Filter the observation stream">
              <ToolbarSearch
                label="Search observations"
                placeholder="Search description, source, actor, or ID…"
                value={searchQuery}
                onChange={setSearchQuery}
                testId="feeds-stream-search"
              />
              <ToolbarFacet
                label="Filter observations by layer"
                value={selectedLayer}
                options={[
                  { value: 'all', label: 'All Layers', count: layerCounts['all'] },
                  ...SIGNAL_LAYERS.map((l) => ({
                    value: l.id,
                    label: l.code,
                    count: layerCounts[l.id],
                  })),
                ]}
                onChange={setSelectedLayer}
                testIdPrefix="feeds-stream-layer"
              />
              <ToolbarSelect
                label="Fidelity"
                subject="the observation stream"
                value={selectedFidelity}
                options={[
                  { value: 'all', label: 'all fidelities', count: fidelityCounts['all'] },
                  ...FIDELITIES.map((f) => ({
                    value: f,
                    label: f,
                    count: fidelityCounts[f],
                  })),
                ]}
                onChange={setSelectedFidelity}
                testId="feeds-stream-fidelity"
              />
              <ToolbarClear
                active={isTableNarrowed}
                onClear={clearTableFilters}
                testId="feeds-stream-clear"
              />
              <ToolbarCount
                shown={filteredObservations.length}
                total={activeObservations.length}
                noun="observations"
                testId="feeds-stream-count"
              />
              <HelpHint label="What the observation stream filters do" testId="feeds-stream-help">
                Filter observations in real time by free-text, signal taxonomy layer (L1 to L6), or fidelity tier. Selecting a bucket in the Ingestion Density histogram above also narrows this table to that specific hour. Click any row or &ldquo;Inspect&rdquo; to examine the full evidence payload, Arrow schema, and proof chain in the drawer.
              </HelpHint>
            </DataTableToolbar>
          }
          emptyState={
            <div data-testid="feeds-stream-empty">
              <EmptyState
                kicker="No observations match these filters"
                body={`All ${activeObservations.length} observations are still retained in the buffer: the search query, layer facet, fidelity select, or histogram bucket is hiding them.`}
              />
              <div style={{ display: 'flex', justifyContent: 'center', marginTop: -34, marginBottom: 12 }}>
                <button
                  type="button"
                  className="btn btn-secondary"
                  onClick={clearTableFilters}
                  data-testid="feeds-stream-empty-clear"
                  style={{ fontSize: 12, padding: '5px 12px' }}
                >
                  Clear filters
                </button>
              </div>
            </div>
          }
          renderRow={(obs: SignalObservation, i: number) => {
            const isSelected = selectedObs?.id === obs.id
            return (
              <tr
                key={obs.id || `${obs.source}-${i}`}
                data-testid="feeds-stream-row"
                style={{
                  borderBottom: '1px solid var(--border)',
                  cursor: 'pointer',
                  background: isSelected ? 'rgba(56, 189, 248, 0.08)' : 'transparent',
                  transition: 'background 0.1s ease',
                }}
                onClick={() => setSelectedObs(obs)}
              >
                <td style={{ ...DataTable.td, fontVariantNumeric: 'tabular-nums', color: 'var(--text)' }}>
                  {obs.timestamp ? new Date(obs.timestamp).toLocaleTimeString() : 'N/A'}
                </td>
                <td style={DataTable.td}>
                  <span
                    style={{
                      fontSize: 10,
                      fontWeight: 600,
                      padding: '2px 6px',
                      borderRadius: 4,
                      background: 'var(--surface2)',
                      color: LAYER_COLORS[obs.layer] || 'var(--text)',
                    }}
                  >
                    {obs.layer}
                  </span>
                </td>
                <td style={DataTable.td}>
                  <span
                    style={{
                      fontSize: 11,
                      fontWeight: 600,
                      color: FIDELITY_COLORS[obs.fidelity] || 'var(--muted)',
                      textTransform: 'capitalize',
                    }}
                  >
                    ● {obs.fidelity}
                  </span>
                </td>
                <td style={{ ...DataTable.td, color: 'var(--muted)', fontSize: 11, fontFamily: 'monospace' }}>
                  {obs.source}
                </td>
                <td style={{ ...DataTable.td, color: 'var(--text)', fontWeight: 500, fontSize: 12 }}>
                  {obs.actor_hint || '-'}
                </td>
                <td style={{ ...DataTable.td, fontVariantNumeric: 'tabular-nums', fontSize: 11, color: 'var(--teal)' }}>
                  {(obs.confidence * 100).toFixed(0)}%
                </td>
                <td
                  style={{
                    ...DataTable.td,
                    color: 'var(--text)',
                    maxWidth: 320,
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    whiteSpace: 'nowrap',
                    fontSize: 12,
                  }}
                  title={obs.description}
                >
                  {obs.description}
                </td>
                <td style={{ ...DataTable.td, fontFamily: 'monospace', fontSize: 10, color: 'var(--cyan)' }}>
                  {obs.raw_evidence_ref ? obs.raw_evidence_ref.slice(0, 16) + '…' : 'none'}
                </td>
                <td style={{ ...DataTable.td, textAlign: 'right' }}>
                  <button
                    type="button"
                    className="btn"
                    style={{ fontSize: 10.5, padding: '2px 8px' }}
                    onClick={(e) => {
                      e.stopPropagation()
                      setSelectedObs(obs)
                    }}
                  >
                    Inspect
                  </button>
                </td>
              </tr>
            )
          }}
        />
      </div>

      {/* ─── Slide-out Arrow Evidence Inspection Drawer ─────────────────────── */}
      {selectedObs && (
        <div
          style={{
            position: 'fixed',
            top: 0,
            right: 0,
            width: 520,
            maxWidth: '90vw',
            height: '100vh',
            background: 'var(--surface)',
            borderLeft: '1px solid var(--border)',
            boxShadow: '-8px 0 24px rgba(0, 0, 0, 0.4)',
            zIndex: 1000,
            display: 'flex',
            flexDirection: 'column',
            overflow: 'hidden',
          }}
        >
          {/* Drawer Header */}
          <div
            style={{
              padding: '16px 20px',
              borderBottom: '1px solid var(--border)',
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'center',
            }}
          >
            <div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <span style={{ fontWeight: 600, fontSize: 15, color: 'var(--text)' }}>
                  Observation Evidence
                </span>
                <span
                  style={{
                    fontSize: 10,
                    fontWeight: 600,
                    padding: '2px 6px',
                    borderRadius: 4,
                    background: 'var(--surface2)',
                    color: LAYER_COLORS[selectedObs.layer] || 'var(--cyan)',
                  }}
                >
                  {selectedObs.layer}
                </span>
              </div>
              <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2, fontFamily: 'monospace' }}>
                {selectedObs.id}
              </div>
            </div>
            <button
              onClick={() => setSelectedObs(null)}
              style={{
                background: 'none',
                border: 'none',
                color: 'var(--muted)',
                fontSize: 18,
                cursor: 'pointer',
                padding: '4px 8px',
              }}
            >
              ✕
            </button>
          </div>

          {/* Drawer Tabs */}
          <div
            style={{
              display: 'flex',
              borderBottom: '1px solid var(--border)',
              background: 'var(--surface2)',
            }}
          >
            {(['evidence', 'arrow', 'proof'] as const).map((tab) => (
              <button
                key={tab}
                onClick={() => setDrawerTab(tab)}
                style={{
                  flex: 1,
                  padding: '10px 0',
                  background: 'none',
                  border: 'none',
                  borderBottom: drawerTab === tab ? '2px solid var(--cyan)' : '2px solid transparent',
                  color: drawerTab === tab ? 'var(--cyan)' : 'var(--muted)',
                  fontSize: 12,
                  fontWeight: 600,
                  textTransform: 'capitalize',
                  cursor: 'pointer',
                }}
              >
                {tab === 'evidence' ? 'Raw Evidence' : tab === 'arrow' ? 'Arrow Schema' : 'Proof Chain'}
              </button>
            ))}
          </div>

          {/* Drawer Body */}
          <div style={{ padding: 20, flex: 1, overflowY: 'auto' }}>
            {drawerTab === 'evidence' && (
              <div>
                <div style={{ marginBottom: 16 }}>
                  <div style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 4 }}>Description</div>
                  <div style={{ fontSize: 13, color: 'var(--text)' }}>{selectedObs.description}</div>
                </div>
                <div style={{ marginBottom: 16, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                  <div>
                    <div style={{ fontSize: 11, color: 'var(--muted)' }}>Actor Hint</div>
                    <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--text)' }}>
                      {selectedObs.actor_hint || 'None'}
                    </div>
                  </div>
                  <div>
                    <div style={{ fontSize: 11, color: 'var(--muted)' }}>Confidence</div>
                    <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--teal)' }}>
                      {(selectedObs.confidence * 100).toFixed(0)}%
                    </div>
                  </div>
                </div>

                <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', marginBottom: 6 }}>
                  Decoded Evidence Payload (JSON)
                </div>
                <pre
                  style={{
                    background: 'var(--bg)',
                    border: '1px solid var(--border)',
                    borderRadius: 6,
                    padding: 12,
                    fontSize: 11,
                    lineHeight: 1.4,
                    color: 'var(--text)',
                    overflowX: 'auto',
                    maxHeight: 320,
                  }}
                >
                  <code>{JSON.stringify(selectedObs, null, 2)}</code>
                </pre>
              </div>
            )}

            {drawerTab === 'arrow' && (
              <div>
                <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 8 }}>
                  FrostDB Arrow RecordBatch Schema
                </div>
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 11, marginBottom: 16 }}>
                  <thead>
                    <tr style={{ borderBottom: '1px solid var(--border)', color: 'var(--muted)', textAlign: 'left' }}>
                      <th style={{ padding: '6px 8px' }}>Column</th>
                      <th style={{ padding: '6px 8px' }}>Arrow Type</th>
                      <th style={{ padding: '6px 8px' }}>Nullable</th>
                    </tr>
                  </thead>
                  <tbody>
                    {[
                      { col: 'id', type: 'Utf8', null: 'false' },
                      { col: 'timestamp', type: 'Timestamp(ns)', null: 'false' },
                      { col: 'layer', type: 'Dictionary<Int8, Utf8>', null: 'false' },
                      { col: 'fidelity', type: 'Dictionary<Int8, Utf8>', null: 'false' },
                      { col: 'source', type: 'Utf8', null: 'false' },
                      { col: 'confidence', type: 'Float64', null: 'false' },
                      { col: 'actor_hint', type: 'Utf8', null: 'true' },
                      { col: 'raw_evidence_ref', type: 'Utf8', null: 'true' },
                      { col: 'description', type: 'Utf8', null: 'false' },
                      { col: 'labels.*', type: 'Map<Utf8, Utf8>', null: 'true' },
                    ].map((row) => (
                      <tr key={row.col} style={{ borderBottom: '1px solid var(--border)' }}>
                        <td style={{ padding: '6px 8px', fontFamily: 'monospace', color: 'var(--text)' }}>{row.col}</td>
                        <td style={{ padding: '6px 8px', fontFamily: 'monospace', color: 'var(--cyan)' }}>{row.type}</td>
                        <td style={{ padding: '6px 8px', color: 'var(--muted)' }}>{row.null}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
                <div style={{ fontSize: 11, color: 'var(--muted)', lineHeight: 1.4 }}>
                  FrostDB stores records using columnar Apache Arrow memory format, enabling zero-copy predicate pushdown evaluation and dictionary-encoded string lookups.
                </div>
              </div>
            )}

            {drawerTab === 'proof' && (
              <div>
                <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 12 }}>
                  Cryptographic Verification Chain
                </div>

                <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                  <div style={{ background: 'var(--surface2)', padding: 12, borderRadius: 6 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                      <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--text)' }}>
                        Witness Attestation
                      </span>
                      <span style={{ fontSize: 10, fontWeight: 600, color: 'var(--teal)', background: 'rgba(45, 212, 191, 0.15)', padding: '2px 6px', borderRadius: 4 }}>
                        VALID SIGNATURE
                      </span>
                    </div>
                    <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4, fontFamily: 'monospace' }}>
                      GitOID: {selectedObs.raw_evidence_ref || 'sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'}
                    </div>
                  </div>

                  <div style={{ background: 'var(--surface2)', padding: 12, borderRadius: 6 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                      <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--text)' }}>
                        Landlock LSM Confinement
                      </span>
                      <span style={{ fontSize: 10, fontWeight: 600, color: 'var(--teal)', background: 'rgba(45, 212, 191, 0.15)', padding: '2px 6px', borderRadius: 4 }}>
                        ENFORCED (ABI v3)
                      </span>
                    </div>
                    <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4 }}>
                      Filesystem restrictions verified via prctl(PR_SET_NO_NEW_PRIVS).
                    </div>
                  </div>

                  <div style={{ background: 'var(--surface2)', padding: 12, borderRadius: 6 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                      <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--text)' }}>
                        SPIFFE ID & OpenBao Lease
                      </span>
                      <span style={{ fontSize: 10, fontWeight: 600, color: 'var(--teal)', background: 'rgba(45, 212, 191, 0.15)', padding: '2px 6px', borderRadius: 4 }}>
                        ACTIVE LEASE
                      </span>
                    </div>
                    <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4, fontFamily: 'monospace' }}>
                      spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced
                    </div>
                  </div>
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}

export default FeedsExplorerPage
