import { useState, useMemo } from 'react'
import { Link } from 'react-router-dom'
import type { AgentResponse, AuditEventResponse, ViolationResponse, SourceHealthMap } from '../types/api'
import { colors } from '../styles/tokens'
import EmptyState from './EmptyState'

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

export interface AgentActivityTabProps {
  agent: AgentResponse
  auditEvents?: AuditEventResponse[]
  violations?: ViolationResponse[]
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
  sourceHealth = 'healthy',
  sourceHealthDetail,
  onAcknowledgeViolation,
  onRefresh,
  isLiveStreaming: initialLiveStreaming = true,
  onToggleLiveStream,
  streamEvents = [],
}: AgentActivityTabProps) {
  const [typeFilter, setTypeFilter] = useState<string>('all')
  const [actorFilter, setActorFilter] = useState<string>('all')
  const [searchQuery, setSearchQuery] = useState<string>('')
  const [liveStreaming, setLiveStreaming] = useState<boolean>(initialLiveStreaming)
  const [acknowledging, setAcknowledging] = useState<string | null>(null)
  const [expandedDetails, setExpandedDetails] = useState<Record<string, boolean>>({})

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
    ]
    return items.sort((a, b) => new Date(b.ts).getTime() - new Date(a.ts).getTime())
  }, [allAuditEvents, violations])

  // Filter items
  const filteredItems = useMemo(() => {
    return rawTimelineItems.filter(item => {
      // 1. Type Filter
      if (typeFilter !== 'all') {
        if (typeFilter === 'violations' && item.kind !== 'violation') return false
        if (typeFilter !== 'violations') {
          if (item.kind !== 'audit' || item.event.event_type !== typeFilter) return false
        }
      }

      // 2. Actor / Identity Plane Filter
      if (actorFilter !== 'all') {
        if (item.kind === 'violation') {
          if (actorFilter !== 'system') return false
        } else {
          const ev = item.event
          const hasHumanPrincipal = !!(ev.authorizing_principal_id || (ev.actor && ev.actor.includes('@')))
          const isWorkload = !!(ev.executing_actor_id || ev.spiffe_id || (ev.actor && !ev.actor.includes('@')))
          if (actorFilter === 'human' && !hasHumanPrincipal) return false
          if (actorFilter === 'workload' && !isWorkload) return false
          if (actorFilter === 'system' && (hasHumanPrincipal || ev.spiffe_id)) return false
        }
      }

      // 3. Search Query
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
  }, [rawTimelineItems, typeFilter, actorFilter, searchQuery])

  // Summary counts
  const totalEventsCount = rawTimelineItems.length
  const openViolationsCount = violations.filter(v => v.status === 'new' || v.status === 'acknowledged').length
  const attestationEventsCount = allAuditEvents.filter(
    e => e.event_type === 'agent.transitioned' || e.event_type === 'credential.issued' || !!e.spiffe_id
  ).length

  // Handlers
  const handleToggleStream = () => {
    const nextState = !liveStreaming
    setLiveStreaming(nextState)
    if (onToggleLiveStream) onToggleLiveStream(nextState)
  }

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
            {isSourceUnavailable ? 'Source unavailable' : `${allAuditEvents.length} audit · ${violations.length} violations`}
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

      {/* ─── 2. Controls, Search, and Filter Toolbar ─────────────────────────── */}
      <div className="card" style={{ padding: '12px 16px', marginBottom: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
          {/* Left Controls: Search & Dropdowns */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, flex: 1, minWidth: 300, flexWrap: 'wrap' }}>
            <input
              type="text"
              data-testid="activity-search-input"
              placeholder="Search event type, actor, rationale, payload..."
              value={searchQuery}
              onChange={e => setSearchQuery(e.target.value)}
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
              onChange={e => setTypeFilter(e.target.value)}
              style={{ padding: '6px 10px', fontSize: 12, borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)' }}
            >
              <option value="all">All Event Types</option>
              <option value="violations">Violations Only</option>
              {ALL_EVENT_TYPES.map(t => (
                <option key={t} value={t}>{t.replace(/_/g, ' ')}</option>
              ))}
            </select>

            <select
              data-testid="activity-actor-filter"
              value={actorFilter}
              onChange={e => setActorFilter(e.target.value)}
              style={{ padding: '6px 10px', fontSize: 12, borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)' }}
            >
              <option value="all">All Identity Planes</option>
              <option value="human">Human Authorizers</option>
              <option value="workload">Workload SVID Actors</option>
              <option value="system">System & Telemetry</option>
            </select>

            {(typeFilter !== 'all' || actorFilter !== 'all' || searchQuery) && (
              <button
                data-testid="activity-clear-filters"
                className="btn btn-secondary"
                onClick={() => {
                  setTypeFilter('all')
                  setActorFilter('all')
                  setSearchQuery('')
                }}
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
