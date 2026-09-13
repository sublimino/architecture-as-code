import { useState, useMemo, useEffect, useCallback } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import type { AgentResponse, AuditEventResponse, ViolationResponse, SourceHealthMap, TelemetryObservationModel, ExternalEvidenceItem } from '../types/api'
import { colors } from '../styles/tokens'
import EmptyState from './EmptyState'
import { getAgentWorkloadSecurityProfile } from './agents/ClaimModal'

// ─── Helpers ────────────────────────────────────────────────────────────────

function fmtTs(iso: string | null | undefined): string {
  if (!iso) return '—'
  try {
    const d = new Date(iso)
    if (isNaN(d.getTime())) return iso
    return d.toISOString().replace('T', ' ').substring(0, 19) + ' UTC'
  } catch {
    return iso || '—'
  }
}

function fmtRelative(iso: string | null | undefined): string {
  if (!iso) return '—'
  try {
    const diff = Date.now() - new Date(iso).getTime()
    if (isNaN(diff)) return '—'
    const mins = Math.floor(diff / 60000)
    if (mins < 1) return 'just now'
    if (mins === 1) return '1m ago'
    if (mins < 60) return `${mins}m ago`
    const hours = Math.floor(mins / 60)
    if (hours === 1) return '1h ago'
    if (hours < 24) return `${hours}h ago`
    const days = Math.floor(diff / 86400000)
    if (days === 0) return 'Today'
    if (days === 1) return 'Yesterday'
    if (days < 30) return `${days}d ago`
    return fmtTs(iso)
  } catch {
    return '—'
  }
}

const EVENT_TYPE_COLORS: Record<string, string> = {
  'agent.created': colors.tealLoom,
  'agent.transitioned': colors.cyanLoom,
  'agent.stunned': colors.amber,
  'compliance.reassess_requested': colors.tealLoom,
  'credential.issued': colors.irisViolet,
  'credential.revoked': colors.red,
  'telemetry.ebpf_event': colors.cyanLoom,
  'policy.violation': colors.red,
  'violation': colors.red,
}

const ALL_EVENT_TYPES = [
  'agent.created',
  'agent.transitioned',
  'agent.stunned',
  'compliance.reassess_requested',
  'credential.issued',
  'credential.revoked',
  'telemetry.ebpf_event',
]

export type AttributableTimelineItem =
  | { kind: 'audit'; id: string; ts: string; event: AuditEventResponse }
  | { kind: 'violation'; id: string; ts: string; violation: ViolationResponse }
  | { kind: 'telemetry'; id: string; ts: string; observation: TelemetryObservationModel }
  | { kind: 'external_evidence'; id: string; ts: string; evidence: ExternalEvidenceItem }

export interface AgentActivityTabProps {
  agent: AgentResponse
  auditEvents?: AuditEventResponse[]
  violations?: ViolationResponse[]
  telemetryObservations?: TelemetryObservationModel[]
  externalEvidence?: ExternalEvidenceItem[]
  sourceHealth?: 'healthy' | 'degraded' | 'unavailable' | null
  sourceHealthDetail?: SourceHealthMap | null
  onAcknowledgeViolation?: (violationId: string) => Promise<void>
  onRefresh?: () => Promise<void>
  isLiveStreaming?: boolean
  onToggleLiveStream?: (active: boolean) => void
  streamEvents?: AuditEventResponse[]
}

export default function AgentActivityTab({
  agent,
  auditEvents = [],
  violations = [],
  telemetryObservations = [],
  externalEvidence = [],
  sourceHealth = 'healthy',
  sourceHealthDetail,
  onAcknowledgeViolation,
  onRefresh,
  isLiveStreaming: initialLiveStreaming = true,
  onToggleLiveStream,
  streamEvents = [],
}: AgentActivityTabProps) {
  const [searchParams, setSearchParams] = useSearchParams()
  const initialType = searchParams.get('type') || searchParams.get('event_type') || 'all'
  const initialActor = searchParams.get('actor') || searchParams.get('actor_plane') || 'all'
  const initialLayer = searchParams.get('layer') || 'all'
  const initialSource = searchParams.get('source') || 'all'
  const initialSearch = searchParams.get('search') || ''
  const initialLive = searchParams.get('live') !== 'false'

  const [typeFilter, setTypeFilter] = useState<string>(initialType)
  const [actorFilter, setActorFilter] = useState<string>(initialActor)
  const [layerFilter, setLayerFilter] = useState<string>(initialLayer)
  const [sourceFilter, setSourceFilter] = useState<string>(initialSource)
  const [searchQuery, setSearchQuery] = useState<string>(initialSearch)
  const [liveStreaming, setLiveStreaming] = useState<boolean>(initialLive)
  const [acknowledging, setAcknowledging] = useState<string | null>(null)
  const [expandedDetails, setExpandedDetails] = useState<Record<string, boolean>>({})

  useEffect(() => {
    const t = searchParams.get('type') || searchParams.get('event_type') || 'all'
    const a = searchParams.get('actor') || searchParams.get('actor_plane') || 'all'
    const l = searchParams.get('layer') || 'all'
    const s = searchParams.get('source') || 'all'
    const q = searchParams.get('search') || ''
    const live = searchParams.get('live') !== 'false'
    setTypeFilter(t)
    setActorFilter(a)
    setLayerFilter(l)
    setSourceFilter(s)
    setSearchQuery(q)
    setLiveStreaming(live)
  }, [searchParams])

  const handleTypeChange = useCallback((val: string) => {
    setTypeFilter(val)
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      if (val && val !== 'all') next.set('type', val)
      else next.delete('type')
      return next
    }, { replace: true })
  }, [setSearchParams])

  const handleActorChange = useCallback((val: string) => {
    setActorFilter(val)
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      if (val && val !== 'all') next.set('actor', val)
      else next.delete('actor')
      return next
    }, { replace: true })
  }, [setSearchParams])

  const handleLayerChange = useCallback((val: string) => {
    setLayerFilter(val)
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      if (val && val !== 'all') next.set('layer', val)
      else next.delete('layer')
      return next
    }, { replace: true })
  }, [setSearchParams])

  const handleSourceChange = useCallback((val: string) => {
    setSourceFilter(val)
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      if (val && val !== 'all') next.set('source', val)
      else next.delete('source')
      return next
    }, { replace: true })
  }, [setSearchParams])

  const handleSearchChange = useCallback((val: string) => {
    setSearchQuery(val)
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      if (val.trim()) next.set('search', val.trim())
      else next.delete('search')
      return next
    }, { replace: true })
  }, [setSearchParams])

  const handleClearFilters = useCallback(() => {
    setTypeFilter('all')
    setActorFilter('all')
    setLayerFilter('all')
    setSourceFilter('all')
    setSearchQuery('')
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      next.delete('type')
      next.delete('event_type')
      next.delete('actor')
      next.delete('actor_plane')
      next.delete('layer')
      next.delete('source')
      next.delete('search')
      return next
    }, { replace: true })
  }, [setSearchParams])

  const handleToggleStream = useCallback(() => {
    const nextState = !liveStreaming
    setLiveStreaming(nextState)
    onToggleLiveStream?.(nextState)
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      if (!nextState) next.set('live', 'false')
      else next.delete('live')
      return next
    }, { replace: true })
  }, [liveStreaming, onToggleLiveStream, setSearchParams])

  // Merge static audit events and any live stream events (deduping by id)
  const allAuditEvents = useMemo(() => {
    const map = new Map<string, AuditEventResponse>()
    for (const ev of auditEvents) {
      map.set(ev.id, ev)
    }
    for (const ev of streamEvents) {
      map.set(ev.id, ev)
    }
    return Array.from(map.values())
  }, [auditEvents, streamEvents])

  // Build unified sorted timeline
  const rawTimelineItems: AttributableTimelineItem[] = useMemo(() => {
    const items: AttributableTimelineItem[] = [
      ...allAuditEvents.map(e => ({
        kind: 'audit' as const,
        id: e.id,
        ts: e.timestamp,
        event: e,
      })),
      ...violations.map(v => ({
        kind: 'violation' as const,
        id: v.id,
        ts: v.created_at ?? '',
        violation: v,
      })),
      ...telemetryObservations.map(o => ({
        kind: 'telemetry' as const,
        id: o.id,
        ts: o.observed_at,
        observation: o,
      })),
      ...externalEvidence.map(ev => ({
        kind: 'external_evidence' as const,
        id: ev.id,
        ts: ev.observed_at,
        evidence: ev,
      })),
    ]
    return items.sort((a, b) => new Date(b.ts).getTime() - new Date(a.ts).getTime())
  }, [allAuditEvents, violations, telemetryObservations, externalEvidence])

  // Filter items
  const filteredItems = useMemo(() => {
    return rawTimelineItems.filter(item => {
      // 1. Type Filter
      if (typeFilter !== 'all') {
        if (typeFilter === 'violations') return item.kind === 'violation'
        if (typeFilter === 'telemetry') return item.kind === 'telemetry'
        if (typeFilter === 'evidence') return item.kind === 'external_evidence'
        if (typeFilter.startsWith('evidence:')) {
          const evType = typeFilter.split(':')[1]
          return item.kind === 'external_evidence' && item.evidence.evidence_type === evType
        }
        if (item.kind !== 'audit' || item.event.event_type !== typeFilter) return false
      }

      // 2. Actor / Identity Plane Filter
      if (actorFilter !== 'all') {
        if (item.kind === 'violation') {
          if (actorFilter !== 'system') return false
        } else if (item.kind === 'telemetry') {
          if (actorFilter !== 'system' && actorFilter !== 'workload') return false
        } else if (item.kind === 'external_evidence') {
          if (actorFilter !== 'workload') return false
        } else {
          const ev = item.event
          const hasHumanPrincipal = !!(ev.authorizing_principal_id || (ev.actor && ev.actor.includes('@')))
          const isWorkload = !!(ev.executing_actor_id || ev.spiffe_id || (ev.actor && !ev.actor.includes('@')))
          if (actorFilter === 'human' && !hasHumanPrincipal) return false
          if (actorFilter === 'workload' && !isWorkload) return false
          if (actorFilter === 'system' && (hasHumanPrincipal || ev.spiffe_id)) return false
        }
      }

      // 3. Layer Filter
      if (layerFilter !== 'all') {
        if (item.kind === 'telemetry') {
          if (item.observation.layer.toLowerCase() !== layerFilter.toLowerCase()) return false
        } else if (item.kind === 'external_evidence') {
          if (layerFilter.toLowerCase() !== 'kernel' && layerFilter.toLowerCase() !== 'host') return false
        } else {
          return false
        }
      }

      // 4. Source Filter
      if (sourceFilter !== 'all') {
        if (item.kind === 'telemetry') {
          if (!item.observation.source.toLowerCase().includes(sourceFilter.toLowerCase())) return false
        } else if (item.kind === 'external_evidence') {
          if (!item.evidence.source.toLowerCase().includes(sourceFilter.toLowerCase())) return false
        } else if (item.kind === 'audit') {
          const s = (item.event.actor || '') + ' ' + JSON.stringify(item.event.detail || {})
          if (!s.toLowerCase().includes(sourceFilter.toLowerCase())) return false
        } else {
          return false
        }
      }

      // 5. Search Query
      if (searchQuery.trim()) {
        const q = searchQuery.toLowerCase()
        if (item.kind === 'violation') {
          const v = item.violation
          const match =
            (v.violation_type || '').toLowerCase().includes(q) ||
            (v.analysis || '').toLowerCase().includes(q) ||
            (v.recommended_action || '').toLowerCase().includes(q) ||
            (v.severity || '').toLowerCase().includes(q)
          if (!match) return false
        } else if (item.kind === 'telemetry') {
          const o = item.observation
          const detailStr = JSON.stringify(o.details || {}).toLowerCase()
          const match =
            (o.action || '').toLowerCase().includes(q) ||
            (o.layer || '').toLowerCase().includes(q) ||
            (o.source || '').toLowerCase().includes(q) ||
            (o.actor_id || '').toLowerCase().includes(q) ||
            (o.principal_id || '').toLowerCase().includes(q) ||
            detailStr.includes(q)
          if (!match) return false
        } else if (item.kind === 'external_evidence') {
          const ev = item.evidence
          const attrStr = JSON.stringify(ev.attributes || {}).toLowerCase()
          const match =
            (ev.evidence_type || '').toLowerCase().includes(q) ||
            (ev.source || '').toLowerCase().includes(q) ||
            (ev.session_id || '').toLowerCase().includes(q) ||
            (ev.observation_state || '').toLowerCase().includes(q) ||
            (ev.integrity_state || '').toLowerCase().includes(q) ||
            (ev.hash_chain_digest || '').toLowerCase().includes(q) ||
            (ev.spiffe_id || '').toLowerCase().includes(q) ||
            attrStr.includes(q)
          if (!match) return false
        } else {
          const ev = item.event
          const detailStr = JSON.stringify(ev.detail || {}).toLowerCase()
          const match =
            (ev.event_type || '').toLowerCase().includes(q) ||
            (ev.actor || '').toLowerCase().includes(q) ||
            (ev.agent_name || '').toLowerCase().includes(q) ||
            (ev.authorizing_principal_id || '').toLowerCase().includes(q) ||
            (ev.executing_actor_id || '').toLowerCase().includes(q) ||
            (ev.spiffe_id || '').toLowerCase().includes(q) ||
            (ev.attribution_rationale || '').toLowerCase().includes(q) ||
            (ev.evidence_ref || '').toLowerCase().includes(q) ||
            detailStr.includes(q)
          if (!match) return false
        }
      }

      return true
    })
  }, [rawTimelineItems, typeFilter, actorFilter, layerFilter, sourceFilter, searchQuery])

  // Summary counts
  const totalEventsCount = rawTimelineItems.length
  const openViolationsCount = violations.filter(v => v.status === 'new' || v.status === 'acknowledged').length
  const attestationEventsCount = allAuditEvents.filter(
    e => e.event_type === 'agent.transitioned' || e.event_type === 'credential.issued' || !!e.spiffe_id
  ).length

  // Handlers
  const handleAcknowledge = async (violationId: string) => {
    if (!onAcknowledgeViolation) return
    setAcknowledging(violationId)
    try {
      await onAcknowledgeViolation(violationId)
    } finally {
      setAcknowledging(null)
    }
  }

  const toggleDetail = (id: string) => {
    setExpandedDetails(prev => ({ ...prev, [id]: !prev[id] }))
  }

  // Source health check
  const isSourceUnavailable = sourceHealth === 'unavailable' || sourceHealthDetail?.postgres_registry?.status === 'unavailable'
  const secProfile = getAgentWorkloadSecurityProfile(agent)

  return (
    <div data-testid="dossier-panel-activity" role="tabpanel" id="dossier-tabpanel-activity" aria-labelledby="dossier-tab-activity">
      {/* ─── 1. Summary StatCards (4 StatCards) ──────────────────────────────── */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 12, marginBottom: 20 }}>
        {/* Card 1: Total Events */}
        <div
          className="card"
          data-testid="activity-card-total-events"
          style={{ padding: '14px 16px', borderLeft: `3px solid ${colors.cyanLoom}` }}
        >
          <span style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em', fontWeight: 600 }}>
            Recorded Events
          </span>
          <div data-testid="activity-total-events" style={{ fontSize: 22, fontWeight: 700, marginTop: 4, color: 'var(--text)' }}>
            {isSourceUnavailable ? '—' : totalEventsCount}
          </div>
          <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
            {isSourceUnavailable ? 'Source unavailable' : `${allAuditEvents.length} audit · ${violations.length} violations${telemetryObservations.length > 0 ? ` · ${telemetryObservations.length} telemetry` : ''}${externalEvidence.length > 0 ? ` · ${externalEvidence.length} evidence` : ''}`}
          </div>
        </div>

        {/* Card 2: Open Policy Violations */}
        <div
          className="card"
          data-testid="activity-card-violations"
          style={{ padding: '14px 16px', borderLeft: `3px solid ${openViolationsCount > 0 ? colors.red : colors.tealLoom}` }}
        >
          <span style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em', fontWeight: 600 }}>
            Policy Violations
          </span>
          <div data-testid="activity-violations-count" style={{ fontSize: 22, fontWeight: 700, marginTop: 4, color: openViolationsCount > 0 ? colors.red : colors.tealLoom }}>
            {isSourceUnavailable ? '—' : openViolationsCount}
          </div>
          <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
            {isSourceUnavailable ? 'Source unavailable' : openViolationsCount === 0 ? 'Zero active violations' : `${openViolationsCount} require acknowledgment`}
          </div>
        </div>

        {/* Card 3: SVID & Attestation Events */}
        <div
          className="card"
          data-testid="activity-card-attestations"
          style={{ padding: '14px 16px', borderLeft: `3px solid ${colors.irisViolet}` }}
        >
          <span style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em', fontWeight: 600 }}>
            Attestations & SVIDs
          </span>
          <div data-testid="activity-attestations-count" style={{ fontSize: 22, fontWeight: 700, marginTop: 4, color: 'var(--text)' }}>
            {isSourceUnavailable ? '—' : attestationEventsCount}
          </div>
          <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
            {agent.identity?.spiffe_id ? 'SPIFFE linked' : 'Registry not linked'}
          </div>
        </div>

        {/* Card 4: Live Stream Status */}
        <div
          className="card"
          data-testid="activity-card-stream-status"
          style={{ padding: '14px 16px', borderLeft: `3px solid ${liveStreaming ? colors.tealLoom : colors.amber}` }}
        >
          <span style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em', fontWeight: 600 }}>
            Real-Time SSE Stream
          </span>
          <div data-testid="activity-stream-status" style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 6 }}>
            <span style={{
              display: 'inline-block',
              width: 8,
              height: 8,
              borderRadius: '50%',
              background: isSourceUnavailable ? colors.red : liveStreaming ? colors.tealLoom : colors.amber,
              boxShadow: liveStreaming && !isSourceUnavailable ? `0 0 6px ${colors.tealLoom}` : 'none',
            }} />
            <span style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>
              {isSourceUnavailable ? 'Source unavailable' : liveStreaming ? 'Stream Active' : 'Stream Paused'}
            </span>
          </div>
          <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4 }}>
            {isSourceUnavailable ? 'Collector offline' : liveStreaming ? 'Push SSE enabled' : 'Polling fallback'}
          </div>
        </div>
      </div>

      {/* ─── 1b. Comparative Workload Security & Telemetry Banner ─────────────── */}
      <div
        className="card"
        data-testid="security-profile-telemetry-banner"
        style={{
          padding: '14px 18px',
          marginBottom: 16,
          background: secProfile.profile === 'nono-sandboxed'
            ? 'linear-gradient(90deg, rgba(34, 197, 94, 0.08) 0%, rgba(22, 26, 35, 0.95) 100%)'
            : 'linear-gradient(90deg, rgba(56, 189, 248, 0.08) 0%, rgba(22, 26, 35, 0.95) 100%)',
          borderLeft: `3px solid ${secProfile.profile === 'nono-sandboxed' ? colors.tealLoom : colors.cyanLoom}`,
          borderTop: '1px solid var(--border)',
          borderRight: '1px solid var(--border)',
          borderBottom: '1px solid var(--border)',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 10 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span
              data-testid={secProfile.profile === 'nono-sandboxed' ? 'nono-verification-badge' : 'tetragon-flow-badge'}
              style={{
                fontSize: 11,
                fontWeight: 600,
                padding: '2px 8px',
                borderRadius: 4,
                background: secProfile.profile === 'nono-sandboxed' ? 'rgba(34, 197, 94, 0.15)' : 'rgba(56, 189, 248, 0.15)',
                color: secProfile.profile === 'nono-sandboxed' ? colors.tealLoom : colors.cyanLoom,
                border: `1px solid ${secProfile.profile === 'nono-sandboxed' ? 'rgba(34, 197, 94, 0.3)' : 'rgba(56, 189, 248, 0.3)'}`,
              }}
            >
              {secProfile.label}
            </span>
            <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>
              {secProfile.profile === 'nono-sandboxed'
                ? 'Cryptographically Verified Nono Audit Event Trails'
                : 'Live Tetragon eBPF Kernel Flow Events'}
            </span>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, fontSize: 11, color: 'var(--muted)', flexWrap: 'wrap' }}>
            {secProfile.profile === 'nono-sandboxed' ? (
              <>
                <span data-testid="nono-lsm-profile" style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                  <span style={{ color: colors.tealLoom }}>🛡️</span> Linux Landlock LSM Active
                </span>
                <span data-testid="nono-hash-chain-status" style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                  <span style={{ color: colors.tealLoom }}>⛓️</span> SHA-256 Hash Chained
                </span>
                <span data-testid="nono-signature-status" style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                  <span style={{ color: colors.irisViolet }}>🔏</span> Detached SVID Signed
                </span>
              </>
            ) : (
              <>
                <span data-testid="tetragon-kernel-sensor" style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                  <span style={{ color: colors.cyanLoom }}>⚡</span> eBPF Kernel Sensor
                </span>
                <span data-testid="tetragon-tracepoints" style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                  <span style={{ color: colors.cyanLoom }}>📡</span> Tracepoints: sys_execve, sys_connect
                </span>
                <span data-testid="tetragon-flow-status" style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                  <span style={{ color: colors.tealLoom }}>🟢</span> Real-Time Flow Stream
                </span>
              </>
            )}
          </div>
        </div>
      </div>

      {/* ─── 2. Controls, Search, and Filter Toolbar ─────────────────────────── */}
      <div className="card" style={{ padding: '12px 16px', marginBottom: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
          {/* Left Controls: Search & Dropdowns */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, flex: 1, minWidth: 300, flexWrap: 'wrap' }}>
            <input
              type="text"
              data-testid="activity-search-input"
              placeholder="Search by rationale, actor, evidence type, digest…"
              value={searchQuery}
              onChange={e => handleSearchChange(e.target.value)}
              style={{
                padding: '6px 10px',
                fontSize: 12,
                borderRadius: 4,
                border: '1px solid var(--border)',
                background: 'var(--surface2)',
                color: 'var(--text)',
                minWidth: 220,
              }}
            />

            <select
              data-testid="activity-type-filter"
              value={typeFilter}
              onChange={e => handleTypeChange(e.target.value)}
              style={{ padding: '6px 10px', fontSize: 12, borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)' }}
            >
              <option value="all">All Event Types</option>
              <option value="violations">Violations Only</option>
              <option value="telemetry">Telemetry Observations</option>
              <option value="evidence">External Evidence (All)</option>
              <option value="evidence:process">Evidence: Process Lifecycle</option>
              <option value="evidence:artifact">Evidence: Artifact Hashes</option>
              <option value="evidence:network">Evidence: Network Egress</option>
              <option value="evidence:collection-limit">Evidence: Limit / Quarantined</option>
              {ALL_EVENT_TYPES.map(t => (
                <option key={t} value={t}>{t.replace(/_/g, ' ')}</option>
              ))}
            </select>

            <select
              data-testid="activity-actor-filter"
              value={actorFilter}
              onChange={e => handleActorChange(e.target.value)}
              style={{ padding: '6px 10px', fontSize: 12, borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)' }}
            >
              <option value="all">All Identity Planes</option>
              <option value="human">Human Authorizers</option>
              <option value="workload">Workload SVID Actors</option>
              <option value="system">System & Telemetry</option>
            </select>

            <select
              data-testid="activity-layer-filter"
              value={layerFilter}
              onChange={e => handleLayerChange(e.target.value)}
              style={{ padding: '6px 10px', fontSize: 12, borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)' }}
            >
              <option value="all">All Telemetry Layers</option>
              <option value="LayerNetworkEgress">LayerNetworkEgress</option>
              <option value="LayerKernelSocket">LayerKernelSocket</option>
              <option value="LayerCgroup">LayerCgroup</option>
              <option value="kernel">Kernel (Landlock / LSM)</option>
              <option value="host">Host Sensor</option>
            </select>

            <select
              data-testid="activity-source-filter"
              value={sourceFilter}
              onChange={e => handleSourceChange(e.target.value)}
              style={{ padding: '6px 10px', fontSize: 12, borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)' }}
            >
              <option value="all">All Sources</option>
              <option value="frostdb-columnar">FrostDB Columnar</option>
              <option value="ebpf-sentinel">eBPF Sentinel</option>
              <option value="tc-ebpf">TC eBPF</option>
              <option value="nono-0.73.0">Nono Sandbox (0.73.0)</option>
              <option value="host-sensor-v1">Host Sensor (v1)</option>
            </select>

            {(typeFilter !== 'all' || actorFilter !== 'all' || layerFilter !== 'all' || sourceFilter !== 'all' || searchQuery) && (
              <button
                data-testid="activity-clear-filters"
                className="btn btn-secondary"
                onClick={handleClearFilters}
                style={{ fontSize: 11, padding: '4px 8px' }}
              >
                Clear
              </button>
            )}
          </div>

          {/* Right Controls: Stream Toggle & Deep-Links */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
            <button
              data-testid="activity-stream-toggle"
              className="btn btn-secondary"
              onClick={handleToggleStream}
              style={{ fontSize: 12, padding: '6px 12px', display: 'flex', alignItems: 'center', gap: 6 }}
            >
              <span style={{
                width: 6,
                height: 6,
                borderRadius: '50%',
                background: liveStreaming ? colors.tealLoom : colors.muted,
              }} />
              {liveStreaming ? 'Pause Stream' : 'Resume Stream'}
            </button>

            {onRefresh && (
              <button
                data-testid="activity-refresh-btn"
                className="btn btn-secondary"
                onClick={onRefresh}
                style={{ fontSize: 12, padding: '6px 10px' }}
                title="Refresh timeline events"
              >
                ↻
              </button>
            )}

            {/* Scoped Deep-Link Navigation */}
            <Link
              to={`/audit?agent=${encodeURIComponent(agent.id)}`}
              data-testid="activity-deeplink-audit"
              className="btn btn-secondary"
              style={{ fontSize: 11, padding: '6px 10px', textDecoration: 'none', color: 'var(--text)' }}
            >
              Audit Trail ↗
            </Link>

            <Link
              to={`/signal-fusion?actor=${encodeURIComponent(agent.id)}`}
              data-testid="activity-deeplink-signal-fusion"
              className="btn btn-secondary"
              style={{ fontSize: 11, padding: '6px 10px', textDecoration: 'none', color: 'var(--text)' }}
            >
              Signal Fusion ↗
            </Link>

            <Link
              to={`/weave?actor=${encodeURIComponent(agent.id)}`}
              data-testid="activity-deeplink-weave"
              className="btn btn-secondary"
              style={{ fontSize: 11, padding: '6px 10px', textDecoration: 'none', color: 'var(--text)' }}
            >
              Weave ↗
            </Link>
          </div>
        </div>
      </div>

      {/* ─── 3. Truthful Timeline Content ────────────────────────────────────── */}
      {isSourceUnavailable ? (
        <div data-testid="activity-source-unavailable" className="card" style={{ padding: 24, textAlign: 'center' }}>
          <div style={{ fontSize: 16, fontWeight: 600, color: colors.amber, marginBottom: 6 }}>
            Source unavailable
          </div>
          <div style={{ fontSize: 13, color: 'var(--muted)' }}>
            Audit and telemetry collector is currently offline or unreachable. Returning explicit degraded status rather than synthetic records.
          </div>
        </div>
      ) : totalEventsCount === 0 ? (
        <div data-testid="activity-empty-state">
          <EmptyState
            kicker="No activity recorded"
            body="Governance actions and verified audit events for this agent will appear here as they occur."
          />
        </div>
      ) : filteredItems.length === 0 ? (
        <div data-testid="activity-no-matches" className="card" style={{ padding: 24, textAlign: 'center' }}>
          <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}>
            No matching events found
          </div>
          <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 12 }}>
            Try adjusting your event type, identity plane, or text search filters.
          </div>
          <button
            className="btn btn-secondary"
            onClick={() => {
              setTypeFilter('all')
              setActorFilter('all')
              setSearchQuery('')
            }}
            style={{ fontSize: 12, padding: '4px 12px' }}
          >
            Reset Filters
          </button>
        </div>
      ) : (
        <div data-testid="activity-timeline-list" className="card" style={{ padding: 16 }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {filteredItems.map((item, idx) => {
              if (item.kind === 'violation') {
                const v = item.violation
                const isNew = v.status === 'new'
                return (
                  <div
                    key={`v-${v.id}`}
                    data-testid={`activity-violation-${v.id}`}
                    style={{
                      display: 'flex',
                      gap: 14,
                      padding: '12px 0',
                      borderBottom: idx < filteredItems.length - 1 ? '1px solid var(--border)' : 'none',
                    }}
                  >
                    <div style={{
                      width: 3,
                      background: isNew ? colors.red : colors.slateGray,
                      borderRadius: 2,
                      flexShrink: 0,
                      minHeight: 48,
                    }} />
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', marginBottom: 4 }}>
                        <span style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace', flexShrink: 0 }}>
                          {fmtTs(v.created_at)}
                        </span>
                        <span style={{
                          fontSize: 11,
                          fontWeight: 600,
                          padding: '2px 8px',
                          borderRadius: 3,
                          background: 'rgba(220,38,38,0.15)',
                          color: colors.red,
                        }}>
                          POLICY VIOLATION
                        </span>
                        <span style={{
                          fontSize: 10,
                          padding: '1px 6px',
                          borderRadius: 3,
                          background: isNew ? 'rgba(239, 68, 68, 0.15)' : 'rgba(156, 163, 175, 0.15)',
                          color: isNew ? colors.red : colors.slateGray,
                          textTransform: 'uppercase',
                        }}>
                          {v.status || 'new'}
                        </span>
                        {v.severity && (
                          <span style={{ fontSize: 11, color: 'var(--muted)' }}>
                            {v.severity} severity
                          </span>
                        )}
                      </div>
                      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 4 }}>
                        {v.violation_type ?? 'Policy Violation'}
                      </div>
                      {v.analysis && (
                        <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 4 }}>
                          {v.analysis}
                        </div>
                      )}
                      {v.recommended_action && (
                        <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 6 }}>
                          <span style={{ color: 'var(--text)', fontWeight: 500 }}>Recommended: </span>
                          {v.recommended_action}
                        </div>
                      )}
                      {isNew && onAcknowledgeViolation && (
                        <button
                          data-testid={`acknowledge-violation-${v.id}`}
                          className="btn btn-secondary"
                          style={{ fontSize: 11, padding: '4px 12px' }}
                          disabled={acknowledging === v.id}
                          onClick={() => handleAcknowledge(v.id)}
                        >
                          {acknowledging === v.id ? 'Acknowledging…' : 'Acknowledge'}
                        </button>
                      )}
                      {v.status === 'acknowledged' && v.acknowledged_by && (
                        <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4 }}>
                          Acknowledged by {v.acknowledged_by} · {fmtTs(v.acknowledged_at)}
                        </div>
                      )}
                    </div>
                  </div>
                )
              }

              if (item.kind === 'telemetry') {
                const obs = item.observation
                const isExpanded = !!expandedDetails[obs.id]
                return (
                  <div
                    key={`tel-${obs.id}`}
                    data-testid={`activity-telemetry-${obs.id}`}
                    style={{
                      display: 'flex',
                      gap: 14,
                      padding: '12px 0',
                      borderBottom: idx < filteredItems.length - 1 ? '1px solid var(--border)' : 'none',
                    }}
                  >
                    <div style={{
                      width: 3,
                      background: colors.cyanLoom,
                      borderRadius: 2,
                      flexShrink: 0,
                      minHeight: 48,
                    }} />
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', marginBottom: 4 }}>
                        <span style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace', flexShrink: 0 }}>
                          {fmtTs(obs.observed_at)}
                        </span>
                        <span style={{
                          fontSize: 11,
                          fontWeight: 600,
                          padding: '2px 8px',
                          borderRadius: 3,
                          background: 'rgba(0, 196, 204, 0.15)',
                          color: colors.cyanLoom,
                        }}>
                          TELEMETRY: {obs.action}
                        </span>
                        <span style={{
                          fontSize: 10,
                          padding: '1px 6px',
                          borderRadius: 3,
                          background: 'var(--surface2)',
                          color: 'var(--text)',
                          border: '1px solid var(--border)',
                        }}>
                          Layer: {obs.layer}
                        </span>
                        <span style={{
                          fontSize: 10,
                          padding: '1px 6px',
                          borderRadius: 3,
                          background: 'var(--surface2)',
                          color: 'var(--muted)',
                        }}>
                          Source: {obs.source}
                        </span>
                        {obs.confidence !== undefined && (
                          <span style={{
                            fontSize: 10,
                            padding: '1px 6px',
                            borderRadius: 3,
                            background: 'rgba(16, 185, 129, 0.15)',
                            color: colors.tealLoom,
                            fontWeight: 500,
                          }}>
                            {Math.round(obs.confidence * 100)}% confidence
                          </span>
                        )}
                      </div>

                      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 4 }}>
                        {obs.action}
                      </div>

                      <div style={{ display: 'flex', gap: 16, fontSize: 12, color: 'var(--muted)', flexWrap: 'wrap', marginBottom: 6 }}>
                        <span>Actor ID: <code style={{ color: 'var(--text)' }}>{obs.actor_id}</code></span>
                        {obs.principal_id && (
                          <span>Principal ID: <code style={{ color: 'var(--text)' }}>{obs.principal_id}</code></span>
                        )}
                      </div>

                      {obs.details && Object.keys(obs.details).length > 0 && (
                        <div style={{ marginTop: 4 }}>
                          <button
                            data-testid={`toggle-telemetry-detail-${obs.id}`}
                            className="btn btn-secondary"
                            onClick={() => toggleDetail(obs.id)}
                            style={{ fontSize: 11, padding: '2px 8px' }}
                          >
                            {isExpanded ? 'Hide Observation Payload' : 'View Observation Payload'}
                          </button>
                          {isExpanded && (
                            <pre
                              data-testid={`activity-telemetry-payload-${obs.id}`}
                              style={{
                                marginTop: 8,
                                padding: 10,
                                background: 'var(--surface2)',
                                borderRadius: 4,
                                fontSize: 11,
                                overflowX: 'auto',
                                border: '1px solid var(--border)',
                              }}
                            >
                              {JSON.stringify(obs.details, null, 2)}
                            </pre>
                          )}
                        </div>
                      )}
                    </div>
                  </div>
                )
              }

              if (item.kind === 'external_evidence') {
                const ev = item.evidence
                const isExpanded = !!expandedDetails[ev.id]

                // Left border color: green for integrity-verified, amber for unobserved, red for tampered / denied
                let lineColor = colors.tealLoom
                if (ev.integrity_state === 'tampered' || ev.observation_state === 'denied') {
                  lineColor = colors.red
                } else if (ev.observation_state === 'unobserved' || ev.integrity_state === 'not-integrity-verified') {
                  lineColor = colors.amber
                } else if (ev.integrity_state === 'integrity-verified') {
                  lineColor = colors.tealLoom
                }

                // Integrity Badge styling
                const isTampered = ev.integrity_state === 'tampered'
                const isVerified = ev.integrity_state === 'integrity-verified'
                const integrityLabel = isVerified ? 'INTEGRITY VERIFIED' : isTampered ? 'TAMPERED HASH CHAIN' : 'UNVERIFIED'
                const integrityBg = isVerified ? 'rgba(16, 185, 129, 0.15)' : isTampered ? 'rgba(239, 68, 68, 0.15)' : 'rgba(245, 158, 11, 0.15)'
                const integrityColor = isVerified ? colors.tealLoom : isTampered ? colors.red : colors.amber

                // Observation state styling
                const isDenied = ev.observation_state === 'denied'
                const isObserved = ev.observation_state === 'observed'
                const obsLabel = (ev.observation_state || 'UNOBSERVED').toUpperCase()
                const obsBg = isDenied ? 'rgba(239, 68, 68, 0.15)' : isObserved ? 'rgba(16, 185, 129, 0.15)' : 'rgba(245, 158, 11, 0.15)'
                const obsColor = isDenied ? colors.red : isObserved ? colors.tealLoom : colors.amber

                return (
                  <div
                    key={`ev-${ev.id}`}
                    data-testid={`activity-external-evidence-${ev.id}`}
                    style={{
                      display: 'flex',
                      gap: 14,
                      padding: '12px 0',
                      borderBottom: idx < filteredItems.length - 1 ? '1px solid var(--border)' : 'none',
                    }}
                  >
                    <div style={{
                      width: 3,
                      background: lineColor,
                      borderRadius: 2,
                      flexShrink: 0,
                      minHeight: 48,
                    }} />
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', marginBottom: 4 }}>
                        <span style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace', flexShrink: 0 }}>
                          {fmtTs(ev.observed_at)}
                        </span>
                        <span style={{
                          fontSize: 11,
                          fontWeight: 600,
                          padding: '2px 8px',
                          borderRadius: 3,
                          background: 'rgba(59, 130, 246, 0.15)',
                          color: '#3b82f6',
                        }}>
                          EVIDENCE: {ev.evidence_type}
                        </span>
                        <span style={{
                          fontSize: 10,
                          padding: '1px 6px',
                          borderRadius: 3,
                          background: 'var(--surface2)',
                          color: 'var(--muted)',
                          border: '1px solid var(--border)',
                        }}>
                          Source: {ev.source}
                        </span>
                        <span style={{
                          fontSize: 10,
                          padding: '1px 6px',
                          borderRadius: 3,
                          background: obsBg,
                          color: obsColor,
                          fontWeight: 600,
                        }}>
                          {obsLabel}
                        </span>
                        <span style={{
                          fontSize: 10,
                          padding: '1px 6px',
                          borderRadius: 3,
                          background: integrityBg,
                          color: integrityColor,
                          fontWeight: 600,
                        }}>
                          {integrityLabel}
                        </span>
                        {ev.session_id && (
                          <span style={{
                            fontSize: 10,
                            padding: '1px 6px',
                            borderRadius: 3,
                            background: 'var(--surface2)',
                            color: 'var(--muted)',
                            fontFamily: 'monospace',
                          }}>
                            Session: {ev.session_id.slice(0, 8)}…
                          </span>
                        )}
                      </div>

                      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 4 }}>
                        {ev.evidence_type === 'process' && `Process Lifecycle (${ev.attributes?.health_status || 'running'})`}
                        {ev.evidence_type === 'artifact' && `Artifact Digest (${ev.attributes?.root_path || 'workspace'})`}
                        {ev.evidence_type === 'network' && `Network Egress (${ev.attributes?.decision || ev.observation_state})`}
                        {ev.evidence_type === 'collection-limit' && `Collection Limit (${ev.attributes?.reason_code || 'quarantine'})`}
                        {!['process', 'artifact', 'network', 'collection-limit'].includes(ev.evidence_type) && `${ev.evidence_type} Observation`}
                      </div>

                      <div style={{ display: 'flex', gap: 16, fontSize: 12, color: 'var(--muted)', flexWrap: 'wrap', marginBottom: 6 }}>
                        {ev.evidence_type === 'process' && (
                          <>
                            {ev.attributes?.health_status && <span>Health: <strong style={{ color: 'var(--text)' }}>{ev.attributes.health_status}</strong></span>}
                            {ev.attributes?.cpu_pct !== undefined && <span>CPU: <code style={{ color: 'var(--text)' }}>{ev.attributes.cpu_pct}%</code></span>}
                            {ev.attributes?.memory_rss_bytes !== undefined && <span>RSS: <code style={{ color: 'var(--text)' }}>{Math.round(ev.attributes.memory_rss_bytes / (1024 * 1024))} MB</code></span>}
                            {ev.attributes?.exit_code !== undefined && <span>Exit: <code style={{ color: 'var(--text)' }}>{ev.attributes.exit_code}</code></span>}
                          </>
                        )}
                        {ev.evidence_type === 'artifact' && (
                          <>
                            {ev.attributes?.root_path && <span>Root: <code style={{ color: 'var(--text)' }}>{ev.attributes.root_path}</code></span>}
                            {ev.attributes?.sha256 && (
                              <span>SHA-256: <code style={{ color: 'var(--text)' }} title={ev.attributes.sha256}>{ev.attributes.sha256.slice(0, 12)}…</code></span>
                            )}
                            {ev.attributes?.size_bytes !== undefined && <span>Size: <code style={{ color: 'var(--text)' }}>{ev.attributes.size_bytes} B</code></span>}
                            {ev.attributes?.mtime_ns !== undefined && <span>Mtime: <code style={{ color: 'var(--text)' }}>{ev.attributes.mtime_ns}</code></span>}
                          </>
                        )}
                        {ev.evidence_type === 'network' && (
                          <>
                            {ev.attributes?.destination && <span>Destination: <code style={{ color: 'var(--text)' }}>{ev.attributes.destination}</code></span>}
                            {ev.attributes?.decision && <span>Decision: <strong style={{ color: 'var(--text)' }}>{ev.attributes.decision}</strong></span>}
                          </>
                        )}
                        {ev.evidence_type === 'collection-limit' && (
                          <>
                            {ev.attributes?.reason_code && <span>Reason: <code style={{ color: 'var(--text)' }}>{ev.attributes.reason_code}</code></span>}
                            {ev.attributes?.window && <span>Window: <code style={{ color: 'var(--text)' }}>{ev.attributes.window}</code></span>}
                          </>
                        )}

                        {ev.hash_chain_digest && (
                          <span>Hash Chain: <code style={{ color: 'var(--text)' }} title={ev.hash_chain_digest}>{ev.hash_chain_digest.slice(0, 10)}…</code></span>
                        )}
                        {ev.landlock_abi !== null && ev.landlock_abi !== undefined && (
                          <span>Landlock ABI: <code style={{ color: 'var(--text)' }}>v{ev.landlock_abi}</code></span>
                        )}
                        {ev.spiffe_id && (
                          <span>SPIFFE ID: <code style={{ color: 'var(--text)' }}>{ev.spiffe_id}</code></span>
                        )}
                      </div>

                      {ev.attributes && Object.keys(ev.attributes).length > 0 && (
                        <div style={{ marginTop: 4 }}>
                          <button
                            data-testid={`toggle-external-evidence-detail-${ev.id}`}
                            className="btn btn-secondary"
                            onClick={() => toggleDetail(ev.id)}
                            style={{ fontSize: 11, padding: '2px 8px' }}
                          >
                            {isExpanded ? 'Hide Allowlisted Attributes' : 'View Allowlisted Attributes'}
                          </button>
                          {isExpanded && (
                            <pre
                              data-testid={`activity-external-evidence-payload-${ev.id}`}
                              style={{
                                marginTop: 8,
                                padding: 10,
                                background: 'var(--surface2)',
                                borderRadius: 4,
                                fontSize: 11,
                                overflowX: 'auto',
                                border: '1px solid var(--border)',
                              }}
                            >
                              {JSON.stringify(ev.attributes, null, 2)}
                            </pre>
                          )}
                        </div>
                      )}
                    </div>
                  </div>
                )
              }

              // Audit Event item
              const ev = item.event
              const lineColor = EVENT_TYPE_COLORS[ev.event_type] ?? colors.cyanLoom
              const isExpanded = !!expandedDetails[ev.id]

              // Identity plane separation
              const humanAuthorizer = ev.authorizing_principal_id || (ev.actor && ev.actor.includes('@') ? ev.actor : null)
              const detailObj = ev.detail && typeof ev.detail === 'object' ? (ev.detail as Record<string, unknown>) : null
              const spiffeId = ev.spiffe_id || (detailObj && typeof detailObj.spiffe_id === 'string' ? detailObj.spiffe_id : null)
              const workloadActor = ev.executing_actor_id || (!ev.actor?.includes('@') ? ev.actor : null) || spiffeId || agent.name
              const rationale = ev.attribution_rationale || (detailObj && typeof detailObj.attribution_rationale === 'string' ? detailObj.attribution_rationale : null)
              const evidenceRef = ev.evidence_ref || (detailObj && typeof detailObj.evidence_ref === 'string' ? detailObj.evidence_ref : null)
              const kernelRef = ev.kernel_telemetry_ref || (detailObj && typeof detailObj.kernel_telemetry_ref === 'string' ? detailObj.kernel_telemetry_ref : null)

              return (
                <div
                  key={`e-${ev.id}`}
                  data-testid={`activity-event-${ev.id}`}
                  style={{
                    display: 'flex',
                    gap: 14,
                    padding: '12px 0',
                    borderBottom: idx < filteredItems.length - 1 ? '1px solid var(--border)' : 'none',
                  }}
                >
                  <div style={{
                    width: 3,
                    background: lineColor,
                    borderRadius: 2,
                    flexShrink: 0,
                    minHeight: 48,
                    opacity: 0.85,
                  }} />
                  <div style={{ flex: 1, minWidth: 0 }}>
                    {/* Header Row: Timestamp & Event Type Badge */}
                    <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', marginBottom: 4 }}>
                      <span style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace', flexShrink: 0 }}>
                        {fmtTs(ev.timestamp)}
                      </span>
                      <span style={{
                        fontSize: 11,
                        fontWeight: 600,
                        padding: '2px 8px',
                        borderRadius: 3,
                        background: 'rgba(6, 182, 212, 0.12)',
                        color: lineColor,
                        textTransform: 'uppercase',
                        letterSpacing: '0.04em',
                      }}>
                        {ev.event_type}
                      </span>
                      <span style={{ fontSize: 11, color: 'var(--muted)' }}>
                        {fmtRelative(ev.timestamp)}
                      </span>
                    </div>

                    {/* Attribution & Identity Planes Row */}
                    <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', fontSize: 12, marginTop: 4, marginBottom: 4 }}>
                      {/* Workload Executor */}
                      <div>
                        <span style={{ color: 'var(--muted)' }}>Executing Actor: </span>
                        <span data-testid="activity-executing-actor" style={{ fontFamily: 'monospace', color: 'var(--text)', fontWeight: 500 }}>
                          {workloadActor || '—'}
                        </span>
                      </div>

                      {/* Human Authorizing Principal (Separation of planes) */}
                      <div>
                        <span style={{ color: 'var(--muted)' }}>Authorized By: </span>
                        <span data-testid="activity-authorizing-principal" style={{ color: humanAuthorizer ? colors.tealLoom : 'var(--muted)' }}>
                          {humanAuthorizer || 'Unassigned'}
                        </span>
                      </div>

                      {/* Workload SVID */}
                      {spiffeId && (
                        <div>
                          <span style={{ color: 'var(--muted)' }}>SVID: </span>
                          <span data-testid="activity-spiffe-id" style={{ fontFamily: 'monospace', fontSize: 11, color: colors.irisViolet }}>
                            {spiffeId}
                          </span>
                        </div>
                      )}
                    </div>

                    {/* Attribution Rationale */}
                    {rationale && (
                      <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2, marginBottom: 4 }}>
                        <span style={{ color: 'var(--text)', fontWeight: 500 }}>Rationale: </span>
                        <span data-testid="activity-attribution-rationale">{rationale}</span>
                      </div>
                    )}

                    {/* Evidence and Kernel Telemetry References */}
                    <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', fontSize: 11, marginTop: 2 }}>
                      {evidenceRef && (
                        <div style={{ background: 'var(--surface2)', padding: '2px 6px', borderRadius: 3 }}>
                          <span style={{ color: 'var(--muted)' }}>Proof Ref: </span>
                          <span data-testid="activity-evidence-ref" style={{ fontFamily: 'monospace', color: colors.tealLoom }}>{evidenceRef}</span>
                        </div>
                      )}
                      {kernelRef && (
                        <div style={{ background: 'var(--surface2)', padding: '2px 6px', borderRadius: 3 }}>
                          <span style={{ color: 'var(--muted)' }}>Kernel Telemetry: </span>
                          <span data-testid="activity-kernel-telemetry-ref" style={{ fontFamily: 'monospace', color: colors.cyanLoom }}>{kernelRef}</span>
                        </div>
                      )}
                    </div>

                    {/* Detail Payload Inspector */}
                    {Object.keys(ev.detail || {}).length > 0 && (
                      <div style={{ marginTop: 6 }}>
                        <button
                          onClick={() => toggleDetail(ev.id)}
                          style={{
                            background: 'none',
                            border: 'none',
                            padding: 0,
                            fontSize: 11,
                            color: 'var(--cyan)',
                            cursor: 'pointer',
                            display: 'flex',
                            alignItems: 'center',
                            gap: 4,
                          }}
                        >
                          {isExpanded ? '▼ Hide payload detail' : '▶ View payload detail'}
                        </button>
                        {isExpanded && (
                          <pre
                            data-testid={`activity-payload-${ev.id}`}
                            style={{
                              marginTop: 6,
                              padding: 8,
                              fontSize: 11,
                              borderRadius: 4,
                              background: 'var(--surface2)',
                              border: '1px solid var(--border)',
                              overflowX: 'auto',
                              color: 'var(--text)',
                            }}
                          >
                            {JSON.stringify(ev.detail, null, 2)}
                          </pre>
                        )}
                      </div>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        </div>
      )}
    </div>
  )
}
