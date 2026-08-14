import { useState, useEffect, useCallback, useRef } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { LIVE_POLL_MS } from '../api/pollInterval'
import type { AuditEventResponse } from '../types/api'
import DataTable from '../components/DataTable'
import EmptyState from '../components/EmptyState'
import HelpHint from '../components/HelpHint'
import LoadingState from '../components/LoadingState'

// Watched by the demo audience in a second window — see api/pollInterval.ts.
//
// This is the payoff page: the agent is gone, and the record of what happened
// to it is not. That record has to arrive while the room is still looking at
// it, so it polls at demo speed like /agents and /compliance.
const POLL_MS = LIVE_POLL_MS
const LIMIT = 50

// The undotted values are the legacy vocabulary retained by migration 007; the
// dotted ones are what api_compat._audit_log() actually writes today. Only
// 'agent.stunned' is listed from the dotted set so far — filtering for an
// enforcement action is the one the operator reaches for first. Closing the
// rest of the drift is a separate change.
//
// Adding a type here has a non-obvious test consequence, which two of us have
// now paid for independently: every entry also renders as an <option> in the
// filter <select> below, so screen.findByText('agent.stunned') matches the
// dropdown option rather than the table cell, and assertions silently target
// the wrong node. Scope audit-table queries to the tbody. See
// pages/stunReachesTimeline.test.tsx.
//
// A new type must be added to BOTH lists — one missing from EVENT_COLORS
// renders grey, one missing from EVENT_TYPES cannot be filtered at all. And a
// type the backend emits also needs a migration widening the audit_events
// CHECK constraint, or tests/test_audit_event_types.py fails.
const EVENT_TYPES = [
  'agent.stunned',
  'enrollment', 'state_transition', 'violation_detected', 'compliance_check',
  'token_issued', 'token_refused', 'tenant_created', 'user_provisioned',
  'directory_connected', 'discovery_enroll_requested',
]

const EVENT_COLORS: Record<string, string> = {
  // Isolating an agent is the most severe action the platform takes on its own.
  'agent.stunned': 'var(--error)',
  enrollment: 'var(--teal)',
  state_transition: 'var(--violet)',
  violation_detected: 'var(--error)',
  compliance_check: 'var(--cyan)',
  token_issued: 'var(--cyan)',
  token_refused: 'var(--amber)',
  tenant_created: 'var(--teal)',
  user_provisioned: 'var(--teal)',
  directory_connected: 'var(--violet)',
  discovery_enroll_requested: 'var(--amber)',
}

function fmtTs(iso: string) {
  return new Date(iso).toLocaleString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
}

function EventTag({ type, active, onClick }: { type: string; active?: boolean; onClick?: () => void }) {
  const color = EVENT_COLORS[type] ?? 'var(--muted)'
  return (
    <span
      onClick={onClick}
      role={onClick ? 'button' : undefined}
      style={{
        display: 'inline-block', padding: '2px 8px', borderRadius: 4,
        fontSize: 11, fontWeight: 600, fontFamily: 'monospace',
        background: `color-mix(in srgb, ${color} 13%, transparent)`, color,
        cursor: onClick ? 'pointer' : 'default',
        outline: active ? `1px solid ${color}` : 'none',
      }}
    >
      {type}
    </span>
  )
}

export default function AuditTrail() {
  const { getAccessTokenSilently } = useAuth0()

  const [events, setEvents] = useState<AuditEventResponse[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [loadingMore, setLoadingMore] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const [fromDate, setFromDate] = useState('')
  const [toDate, setToDate] = useState('')
  const [agentId, setAgentId] = useState('')
  const [eventType, setEventType] = useState('')
  const [exporting, setExporting] = useState(false)
  const [exportError, setExportError] = useState<string | null>(null)

  // Track active filters so polling uses same params
  const filtersRef = useRef({ fromDate, toDate, agentId, eventType })

  /**
   * @param silent Background refresh: no spinner, and a failure leaves the last
   *   good page on screen. At the old fifteen-minute cadence a poll that
   *   flipped `loading` was invisible; at demo speed it would blank the table
   *   into "Loading…" every 2.5s, and one transient error would replace the
   *   audit record with an error state in front of the room.
   */
  const fetchPage = useCallback(async (p: number, replace: boolean, silent = false) => {
    if (silent) { /* background refresh — leave the current view alone */ }
    else if (replace) setLoading(true)
    else setLoadingMore(true)
    try {
      const token = await getAccessTokenSilently()
      const f = filtersRef.current
      const data = await api.audit(token, {
        page: p, limit: LIMIT,
        from: f.fromDate || undefined,
        to: f.toDate || undefined,
        agent: f.agentId || undefined,
        type: f.eventType || undefined,
      })
      setTotal(data.total)
      setEvents(prev => replace ? data.events : [...prev, ...data.events])
      setPage(p)
      setError(null)
    } catch (e: unknown) {
      if (silent) return
      const msg = e instanceof Error ? e.message : ''
      if (msg.includes('401') || msg.includes('403')) {
        setError('Your session has expired. Please sign in again.')
      } else {
        setError('Something went wrong loading this view. Please try refreshing.')
      }
    } finally {
      if (!silent) {
        setLoading(false)
        setLoadingMore(false)
      }
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    filtersRef.current = { fromDate: '', toDate: '', agentId: '', eventType: '' }
    fetchPage(1, true)
  }, [fetchPage])

  useEffect(() => {
    // Only while the operator is on the first page. "Load More" appends pages
    // onto `events`, and a poll re-fetching page 1 replaces the lot — at
    // fifteen minutes that was a rare annoyance, at 2.5s it would make
    // pagination impossible to use. Someone reading back through the log is
    // doing archaeology, not watching a demo, so the poll waits for them.
    if (page !== 1) return
    const t = setInterval(() => fetchPage(1, true, true), POLL_MS)
    return () => clearInterval(t)
  }, [fetchPage, page])

  function applyFilters() {
    filtersRef.current = { fromDate, toDate, agentId, eventType }
    setEvents([])
    fetchPage(1, true)
  }

  function clearFilters() {
    setFromDate('')
    setToDate('')
    setAgentId('')
    setEventType('')
    filtersRef.current = { fromDate: '', toDate: '', agentId: '', eventType: '' }
    setEvents([])
    fetchPage(1, true)
  }

  function toggleTypeFilter(type: string) {
    const next = eventType === type ? '' : type
    setEventType(next)
    filtersRef.current = { ...filtersRef.current, eventType: next }
    setEvents([])
    fetchPage(1, true)
  }

  async function exportCsv() {
    setExporting(true)
    setExportError(null)
    try {
      const token = await getAccessTokenSilently()
      const f = filtersRef.current
      const csv = await api.auditExportCsv(token, {
        from: f.fromDate || undefined,
        to: f.toDate || undefined,
        agent: f.agentId || undefined,
        type: f.eventType || undefined,
      })
      const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `audit-events-${new Date().toISOString().slice(0, 10)}.csv`
      a.click()
      URL.revokeObjectURL(url)
    } catch {
      setExportError('Export failed. Please try again.')
    } finally {
      setExporting(false)
    }
  }

  const hasMore = events.length < total

  return (
    <div style={{ paddingBottom: 32 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 }}>
        {/* The hint sits beside the heading, not inside it. Nested in the `h1` it
            joins the heading's accessible name, so the page announces as "Audit
            Trail What the Audit Trail records" to a screen reader and stops
            matching an exact name query. */}
        <div style={{ display: 'flex', alignItems: 'center' }}>
          <h1 style={{ fontSize: 22, fontWeight: 700 }}>Audit Trail</h1>
          <HelpHint label="What the Audit Trail records" testId="audit-page-help">
            Every row is written by the part of the system that carried the action out, as it
            carried it out — nothing here was submitted by a browser. Rows cannot be edited or
            deleted afterwards; a correction is recorded as a further event rather than by
            changing the original.
          </HelpHint>
        </div>
        <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
          <span style={{ color: 'var(--muted)', fontSize: 13 }}>{total.toLocaleString()} events</span>
          <button
            className="btn btn-secondary"
            onClick={exportCsv}
            disabled={exporting}
            style={{ padding: '6px 14px', fontSize: 12 }}
          >
            {exporting ? 'Exporting…' : 'Export CSV'}
          </button>
        </div>
      </div>
      {exportError && (
        <div style={{ color: 'var(--error)', fontSize: 12, marginBottom: 12 }}>{exportError}</div>
      )}

      {/* Filters */}
      <div className="card" style={{ marginBottom: 20, padding: '14px 20px' }}>
        <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', alignItems: 'flex-end' }}>
          <div>
            <label style={{ fontSize: 11, color: 'var(--muted)', display: 'block', marginBottom: 4 }}>From</label>
            <input type="datetime-local" value={fromDate} onChange={e => setFromDate(e.target.value)} />
          </div>
          <div>
            <label style={{ fontSize: 11, color: 'var(--muted)', display: 'block', marginBottom: 4 }}>To</label>
            <input type="datetime-local" value={toDate} onChange={e => setToDate(e.target.value)} />
          </div>
          <div>
            <label style={{ fontSize: 11, color: 'var(--muted)', display: 'block', marginBottom: 4 }}>Agent UUID</label>
            <input
              type="text"
              value={agentId}
              onChange={e => setAgentId(e.target.value)}
              placeholder="xxxxxxxx-…"
              style={{ width: 200 }}
            />
          </div>
          <div>
            <label style={{ fontSize: 11, color: 'var(--muted)', display: 'block', marginBottom: 4 }}>Event Type</label>
            <select value={eventType} onChange={e => setEventType(e.target.value)} style={{ width: 210 }}>
              <option value="">All types</option>
              {EVENT_TYPES.map(t => <option key={t} value={t}>{t}</option>)}
            </select>
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="btn btn-primary" onClick={applyFilters} style={{ padding: '6px 14px', fontSize: 12 }}>Apply</button>
            <button className="btn btn-secondary" onClick={clearFilters} style={{ padding: '6px 14px', fontSize: 12 }}>Clear</button>
          </div>
        </div>
      </div>

      {/* Table */}
      {loading ? (
        <LoadingState variant="block" status="loading" label="audit events" testId="audit-load-state" />
      ) : error ? (
        <LoadingState variant="block" status="error" label="audit events" error={error} onRetry={() => fetchPage(1, true)} testId="audit-load-state" />
      ) : events.length === 0 ? (
        <EmptyState kicker="No events found" body="Try adjusting your filters or wait for governance actions to be recorded." />
      ) : (
        <>
          <DataTable<AuditEventResponse>
            columns={[
              { key: 'timestamp', label: 'Timestamp', sortable: true },
              { key: 'event_type', label: 'Event Type', sortable: true },
              { key: 'agent_name', label: 'Agent', sortable: true },
              {
                key: 'actor',
                label: 'Actor',
                sortable: true,
                help:
                  'Who the server saw make this happen, taken from their sign-in token — '
                  + 'usually an email address, because that is what the token carries and a '
                  + 'friendlier name would be one nobody could check it against. '
                  + '"demo-actor" means that event was recorded before actions were '
                  + 'attributed, and it names nobody.',
              },
              { key: 'event_type', label: 'Detail' },
            ]}
            data={events}
            pageSize={25}
            testIdPrefix="audit"
            renderRow={(ev, i) => (
              <tr key={ev.id} style={{ borderBottom: '1px solid var(--border)', background: i % 2 === 0 ? 'transparent' : 'rgba(255,255,255,0.01)' }}>
                <td style={{ ...DataTable.td, color: 'var(--muted)', fontFamily: 'monospace', fontSize: 11, whiteSpace: 'nowrap' }}>{fmtTs(ev.timestamp)}</td>
                <td style={DataTable.td}>
                  <EventTag
                    type={ev.event_type}
                    active={eventType === ev.event_type}
                    onClick={() => toggleTypeFilter(ev.event_type)}
                  />
                </td>
                <td style={{ ...DataTable.td, maxWidth: 160 }}>
                  {ev.agent_name ? (
                    <div>
                      <div style={{ fontWeight: 500 }}>{ev.agent_name}</div>
                      {ev.agent_id && <div style={{ color: 'var(--muted)', fontSize: 10, fontFamily: 'monospace' }}>{ev.agent_id.slice(0, 8)}…</div>}
                    </div>
                  ) : <span style={{ color: 'var(--muted)' }}>—</span>}
                </td>
                <td style={{ ...DataTable.td, color: 'var(--muted)', maxWidth: 180, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{ev.actor || '—'}</td>
                <td style={{ ...DataTable.td, maxWidth: 300 }}>
                  <code style={{ fontSize: 11, color: 'var(--muted)', background: 'var(--surface2)', padding: '2px 6px', borderRadius: 3, display: 'block', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {Object.keys(ev.detail).length > 0 ? JSON.stringify(ev.detail) : '{}'}
                  </code>
                </td>
              </tr>
            )}
          />

          {/* Load More (server-side — complements the client-side DataTable pagination) */}
          <div style={{ marginTop: 14, display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 13, color: 'var(--muted)' }}>
            <span>Loaded {events.length} of {total.toLocaleString()} events from server</span>
            {hasMore && (
              <button
                className="btn btn-secondary"
                onClick={() => fetchPage(page + 1, false)}
                disabled={loadingMore}
                style={{ padding: '6px 16px', fontSize: 12 }}
              >
                {loadingMore ? 'Loading…' : 'Load More'}
              </button>
            )}
          </div>
        </>
      )}
    </div>
  )
}
