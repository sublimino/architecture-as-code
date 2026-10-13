/**
 * The live observation feed: newest first, rendered as a Super DataTable.
 *
 * What it shows is deliberately narrow: layer, source, pseudonymous actor, the
 * projected one-line description, and metadata chips. It does NOT show
 * `raw_evidence_ref`, which is a pointer into the evidence blob store and is
 * only ever dereferenced server-side behind an audited read.
 */
import { useState, useMemo } from 'react'
import type { SignalObservation, FidelityTier } from '../../api/weaveApi'
import { LabelChips, layerColor, layerLabel, timeShort, LAYER_ORDER } from './presentation'
import DataTable, { type Column } from '../DataTable'
import {
  DataTableToolbar,
  ToolbarSearch,
  ToolbarFacet,
  ToolbarSelect,
  ToolbarClear,
  ToolbarCount,
  type ToolbarOption,
} from '../DataTableToolbar'

const FIDELITY_COLORS: Record<FidelityTier, string> = {
  definitive: 'var(--teal)',
  strong: 'var(--cyan)',
  suggestive: 'var(--amber)',
  circumstantial: 'var(--muted)',
}

export interface ObservationFeedProps {
  observations: SignalObservation[]
  selectedLayer?: string | null
  onSelectLayer?: (layer: string | null) => void
  selectedFidelity?: string | null
  onSelectFidelity?: (fidelity: string | null) => void
  searchQuery?: string
  onSearchChange?: (q: string) => void
  excludeSentinel?: boolean
  onToggleSentinel?: () => void
  onClearFilters?: () => void
}

export default function ObservationFeed({
  observations,
  selectedLayer: propLayer,
  onSelectLayer,
  selectedFidelity: propFidelity,
  onSelectFidelity,
  searchQuery: propSearch,
  onSearchChange,
  excludeSentinel: propExcludeSentinel,
  onToggleSentinel,
  onClearFilters,
}: ObservationFeedProps) {
  const [localLayer, setLocalLayer] = useState<string>('all')
  const [localFidelity, setLocalFidelity] = useState<string>('all')
  const [localSearch, setLocalSearch] = useState<string>('')
  const [localExcludeSentinel, setLocalExcludeSentinel] = useState<boolean>(false)

  const activeLayer = propLayer !== undefined ? (propLayer || 'all') : localLayer
  const activeFidelity = propFidelity !== undefined ? (propFidelity || 'all') : localFidelity
  const activeSearch = propSearch !== undefined ? propSearch : localSearch
  const activeExcludeSentinel = propExcludeSentinel !== undefined ? propExcludeSentinel : localExcludeSentinel

  const handleLayerChange = (val: string) => {
    if (onSelectLayer) onSelectLayer(val === 'all' ? null : val)
    else setLocalLayer(val)
  }

  const handleFidelityChange = (val: string) => {
    if (onSelectFidelity) onSelectFidelity(val === 'all' ? null : val)
    else setLocalFidelity(val)
  }

  const handleSearchChange = (val: string) => {
    if (onSearchChange) onSearchChange(val)
    else setLocalSearch(val)
  }

  const handleToggleSentinel = () => {
    if (onToggleSentinel) onToggleSentinel()
    else setLocalExcludeSentinel((v) => !v)
  }

  const handleClear = () => {
    if (onClearFilters) {
      onClearFilters()
    } else {
      if (onSelectLayer) onSelectLayer(null)
      else setLocalLayer('all')
      if (onSelectFidelity) onSelectFidelity(null)
      else setLocalFidelity('all')
      if (onSearchChange) onSearchChange('')
      else setLocalSearch('')
      if (onToggleSentinel && activeExcludeSentinel) onToggleSentinel()
      else setLocalExcludeSentinel(false)
    }
  }

  const isSentinelObservation = (obs: SignalObservation): boolean => {
    // Only the HIGH-FREQUENCY sentinel telemetry streams are the noise this toggle
    // hides: the per-connection socket-trace flow and its gap detector
    // (network_egress). Low-frequency, high-value endpoint FINDINGS — source
    // "stun-sentinel" (live) and "sentinel.ebpf.syscall_trace" (projection) — are
    // detections, not noise, and MUST survive the toggle; matching on a broad
    // "sentinel"/"stun" substring (as this did) hid every live endpoint detection.
    const s = (obs.source || '').toLowerCase()
    return s.endsWith('socket_trace') || s.endsWith('gap_detector')
  }

  const filtered = useMemo(() => {
    return observations.filter((obs) => {
      if (activeExcludeSentinel && isSentinelObservation(obs)) {
        return false
      }
      if (activeLayer !== 'all' && obs.layer !== activeLayer) {
        return false
      }
      if (activeFidelity !== 'all' && obs.fidelity !== activeFidelity) {
        return false
      }
      if (activeSearch.trim()) {
        const q = activeSearch.toLowerCase()
        const text = `${obs.description} ${obs.source} ${obs.actor_hint || ''} ${obs.layer} ${obs.fidelity} ${Object.values(obs.labels || {}).join(' ')}`.toLowerCase()
        if (!text.includes(q)) return false
      }
      return true
    })
  }, [observations, activeLayer, activeFidelity, activeSearch, activeExcludeSentinel])

  const layerCounts = useMemo(() => {
    const map: Record<string, number> = {}
    for (const obs of observations) {
      if (activeExcludeSentinel && isSentinelObservation(obs)) continue
      map[obs.layer] = (map[obs.layer] || 0) + 1
    }
    return map
  }, [observations, activeExcludeSentinel])

  const layerOptions: ToolbarOption[] = useMemo(() => {
    const totalWithoutSentinel = activeExcludeSentinel
      ? observations.filter((o) => !isSentinelObservation(o)).length
      : observations.length

    const opts: ToolbarOption[] = [
      { value: 'all', label: 'All Layers', count: totalWithoutSentinel },
    ]
    const presentLayers = Array.from(new Set(observations.map((o) => o.layer)))
    const ordered = [
      ...LAYER_ORDER.filter((l) => presentLayers.includes(l)),
      ...presentLayers.filter((l) => !LAYER_ORDER.includes(l as any)),
    ]
    for (const layer of ordered) {
      opts.push({
        value: layer,
        label: layerLabel(layer),
        count: layerCounts[layer] || 0,
      })
    }
    return opts
  }, [observations, layerCounts, activeExcludeSentinel])

  const fidelityCounts = useMemo(() => {
    const map: Record<string, number> = {}
    for (const obs of observations) {
      map[obs.fidelity] = (map[obs.fidelity] || 0) + 1
    }
    return map
  }, [observations])

  const fidelityOptions: ToolbarOption[] = useMemo(() => [
    { value: 'all', label: 'All Fidelities', count: observations.length },
    { value: 'definitive', label: 'Definitive', count: fidelityCounts['definitive'] || 0 },
    { value: 'strong', label: 'Strong', count: fidelityCounts['strong'] || 0 },
    { value: 'suggestive', label: 'Suggestive', count: fidelityCounts['suggestive'] || 0 },
    { value: 'circumstantial', label: 'Circumstantial', count: fidelityCounts['circumstantial'] || 0 },
  ], [observations.length, fidelityCounts])

  const hasFilters =
    activeLayer !== 'all' ||
    activeFidelity !== 'all' ||
    activeSearch.trim() !== '' ||
    activeExcludeSentinel

  const columns: Column<SignalObservation>[] = [
    {
      key: 'timestamp',
      label: 'Time',
      sortable: true,
      accessor: (o) => new Date(o.timestamp).getTime(),
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
      key: 'actor_hint',
      label: 'Actor',
      sortable: true,
      accessor: (o) => o.actor_hint || '',
    },
    {
      key: 'description',
      label: 'Description & Labels',
    },
  ]

  const toolbar = (
    <DataTableToolbar label="Filter live signals feed">
      <ToolbarSearch
        label="Search live signal feed"
        placeholder="Filter descriptions, sources, actors..."
        value={activeSearch}
        onChange={handleSearchChange}
        testId="feed-toolbar-search"
      />
      <ToolbarFacet
        label="Filter by layer"
        value={activeLayer}
        options={layerOptions}
        onChange={handleLayerChange}
        testIdPrefix="feed-layer-facet"
      />
      <ToolbarSelect
        label="Fidelity"
        subject="signals"
        value={activeFidelity}
        options={fidelityOptions}
        onChange={handleFidelityChange}
        testId="feed-fidelity-select"
      />
      <button
        type="button"
        data-testid="feed-exclude-sentinel-toggle"
        aria-pressed={activeExcludeSentinel}
        onClick={handleToggleSentinel}
        title="Filter out high-frequency sentinel events"
        style={{
          fontSize: 11.5,
          padding: '4px 9px',
          borderRadius: 4,
          cursor: 'pointer',
          fontWeight: activeExcludeSentinel ? 600 : 400,
          color: activeExcludeSentinel ? 'var(--amber)' : 'var(--muted)',
          background: activeExcludeSentinel ? 'rgba(245, 158, 11, 0.12)' : 'var(--surface2)',
          border: `1px solid ${activeExcludeSentinel ? 'rgba(245, 158, 11, 0.4)' : 'var(--border)'}`,
        }}
      >
        {activeExcludeSentinel ? 'Filtering Out Sentinel Events' : 'Filter Out Sentinel Events'}
      </button>
      <ToolbarClear
        active={hasFilters}
        onClear={handleClear}
        testId="feed-toolbar-clear"
      />
      <ToolbarCount
        shown={filtered.length}
        total={observations.length}
        noun="observations"
        testId="feed-toolbar-count"
      />
    </DataTableToolbar>
  )

  const emptyState = (
    <div data-testid="observation-feed-empty" style={{ padding: '28px 0', textAlign: 'center', fontSize: 12.5, color: 'var(--muted)' }}>
      {observations.length === 0
        ? 'No observation in this window yet.'
        : 'No observations match the current filters.'}
      {hasFilters && (
        <div style={{ marginTop: 10 }}>
          <button
            type="button"
            className="btn btn-secondary"
            onClick={handleClear}
            style={{ fontSize: 12 }}
          >
            Clear filters
          </button>
        </div>
      )}
    </div>
  )

  return (
    <div className="card" data-testid="observation-feed" style={{ padding: 14 }}>
      <DataTable
        columns={columns}
        data={filtered}
        pageSize={25}
        toolbar={toolbar}
        emptyState={emptyState}
        renderRow={(obs) => (
          <tr
            key={obs.id}
            id={`observation-${obs.id}`}
            data-testid="observation-item"
            style={{ borderBottom: '1px solid var(--border)' }}
          >
            <td style={{ ...DataTable.td, fontSize: 11, color: 'var(--muted)', fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap' }}>
              {timeShort(obs.timestamp)}
            </td>
            <td style={{ ...DataTable.td, whiteSpace: 'nowrap' }}>
              <span
                data-testid="observation-layer"
                style={{
                  fontSize: 11,
                  fontWeight: 600,
                  color: layerColor(obs.layer),
                  textTransform: 'uppercase',
                  letterSpacing: '0.04em',
                }}
              >
                {layerLabel(obs.layer)}
              </span>
            </td>
            <td style={{ ...DataTable.td, fontSize: 11, textTransform: 'capitalize', whiteSpace: 'nowrap' }}>
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5 }}>
                <span
                  style={{
                    width: 6,
                    height: 6,
                    borderRadius: '50%',
                    background: FIDELITY_COLORS[obs.fidelity] ?? 'var(--muted)',
                  }}
                />
                {obs.fidelity}
              </span>
            </td>
            <td style={{ ...DataTable.td, fontFamily: 'monospace', fontSize: 11 }}>
              <span data-testid="observation-source">{obs.source}</span>
            </td>
            <td style={{ ...DataTable.td, fontSize: 11, color: 'var(--muted)' }}>
              <span data-testid="observation-actor" title="Pseudonymous actor reference">
                {obs.actor_hint ?? 'unattributed'}
              </span>
            </td>
            <td style={{ ...DataTable.td }}>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                <div style={{ fontSize: 13, color: 'var(--text)' }}>{obs.description}</div>
                <LabelChips labels={obs.labels} />
              </div>
            </td>
          </tr>
        )}
      />
    </div>
  )
}
