import { useState, useEffect, useCallback, useRef, useMemo, type CSSProperties, type ReactNode } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { LIVE_POLL_MS } from '../api/pollInterval'
import type { AuditEventResponse } from '../types/api'
import DataTable from '../components/DataTable'
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
import LoadingState from '../components/LoadingState'

// Watched by the demo audience in a second window — see api/pollInterval.ts.
//
// This is the payoff page: the agent is gone, and the record of what happened
// to it is not. That record has to arrive while the room is still looking at
// it, so it polls at demo speed like /agents and /compliance.
const POLL_MS = LIVE_POLL_MS
const LIMIT = 50

// The dotted values are what api_compat._audit_log() writes today; the undotted
// ones are the legacy vocabulary retained by migration 007 for environments
// holding historical rows.
//
// This list used to carry 'agent.stunned' plus the ten legacy values and
// nothing else, so 21 of the 22 event types the API emits had no filter option
// and ten of the eleven options on offer matched nothing the API can produce.
// An operator filtering the audit trail for a credential revoke found no way to
// ask, and one filtering for 'violation_detected' got an empty table that was
// indistinguishable from a quiet period.
//
// Both lists are now checked against the emitted set by
// fe-signalloom/src/tests/test_dashboard_audit_vocabulary.py, which derives the
// API side from the AST of _audit_log()'s call sites rather than restating it.
// Adding an emitted event type without adding it here fails that test.
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
  // Emitted by the API today.
  'agent.created', 'agent.transitioned', 'agent.stunned',
  'agent.credential_issued', 'agent.credential_revoked',
  'violation.acknowledged',
  'compliance.reassess_requested', 'compliance.scan_completed',
  'api_key.created', 'api_key.rotated',
  'nhi.enrolled', 'nhi.dismissed',
  'tenant.frameworks_updated', 'tenant.preferences_updated',
  'user.currency_updated', 'consent.accepted', 'cookie.preferences_updated',
  'support.requested',
  'onboarding_completed', 'onboarding_skipped',
  'demo.phase_run', 'demo.reset_requested',
  // Legacy vocabulary from migration 007. No call site emits these, but rows
  // using them may exist in long-lived environments, so they stay filterable.
  'enrollment', 'state_transition', 'violation_detected', 'compliance_check',
  'token_issued', 'token_refused', 'tenant_created', 'user_provisioned',
  'directory_connected', 'discovery_enroll_requested',
]

const EVENT_COLORS: Record<string, string> = {
  // Enforcement and trust withdrawal are the most severe actions the platform
  // takes on its own, so they carry the error colour.
  'agent.stunned': 'var(--error)',
  'agent.credential_revoked': 'var(--error)',
  'agent.created': 'var(--teal)',
  'agent.transitioned': 'var(--violet)',
  'agent.credential_issued': 'var(--cyan)',
  'violation.acknowledged': 'var(--amber)',
  'compliance.reassess_requested': 'var(--cyan)',
  'compliance.scan_completed': 'var(--cyan)',
  'api_key.created': 'var(--teal)',
  'api_key.rotated': 'var(--cyan)',
  'nhi.enrolled': 'var(--teal)',
  'nhi.dismissed': 'var(--amber)',
  'tenant.frameworks_updated': 'var(--violet)',
  'tenant.preferences_updated': 'var(--violet)',
  'user.currency_updated': 'var(--violet)',
  'consent.accepted': 'var(--teal)',
  'cookie.preferences_updated': 'var(--violet)',
  'support.requested': 'var(--amber)',
  onboarding_completed: 'var(--teal)',
  onboarding_skipped: 'var(--amber)',
  'demo.phase_run': 'var(--violet)',
  'demo.reset_requested': 'var(--amber)',
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

/**
 * The chip vocabulary, and the one thing on this page that is DERIVED rather
 * than declared.
 *
 * EVENT_COLORS above is already a taxonomy — the comment at its head says so
 * outright ("enforcement and trust withdrawal ... carry the error colour") —
 * it was simply one nobody could filter on. These are the same five buckets
 * with names, so the chip a reader clicks and the colour they clicked it for
 * cannot disagree: the class is looked up THROUGH the colour rather than
 * restated beside it. Adding an event type therefore classifies it
 * automatically, and the only way to get it wrong is to give it a colour that
 * is not one of the five — which lands it in `other` rather than silently in
 * the wrong bucket.
 *
 * The vocabulary is FIXED, not derived from the rows on screen. A list built
 * from the loaded events could only ever offer options that match something,
 * which is the one thing that would stop a chip being a way back out of an
 * empty result. `other` is therefore always offered and usually reads 0: an
 * unrecognised type from a newer server falls into it, and a bucket that
 * appears only once that happens is a bucket nobody would think to look in.
 *
 * `all` first, then severity descending, so the row of chips is itself a
 * ranking rather than an alphabet.
 */
const EVENT_CLASSES = ['all', 'enforcement', 'attention', 'provisioning', 'change', 'routine', 'other'] as const

type EventClass = (typeof EVENT_CLASSES)[number]

const CLASS_OF_COLOR: Record<string, EventClass> = {
  'var(--error)': 'enforcement',
  'var(--amber)': 'attention',
  'var(--teal)': 'provisioning',
  'var(--violet)': 'change',
  'var(--cyan)': 'routine',
}

/** Total by construction — an unknown type has no colour and lands in `other`. */
function classOf(type: string): EventClass {
  return CLASS_OF_COLOR[EVENT_COLORS[type] ?? ''] ?? 'other'
}

/**
 * The unfiltered query, as one frozen module-level value.
 *
 * Shared rather than rebuilt at each of its three call sites so that
 * `setApplied(NO_FILTERS)` is `Object.is`-equal to what is already there and
 * React bails out instead of re-rendering. That matters because the mount
 * effect is keyed on `fetchPage`, which is keyed in turn on
 * `getAccessTokenSilently` — a reference `auth/oidc` keeps stable with a
 * `useCallback` and a comment explaining that consumers put it in effect deps
 * and an unstable one is an infinite refetch loop. This does not fix that
 * contract, which is not this file's to fix; it declines to add a synchronous
 * re-render to the cycle if it is ever broken. Frozen so a caller cannot make
 * the shared object stop being the empty query.
 */
interface AuditQuery {
  fromDate: string
  toDate: string
  agentId: string
  eventType: string
}

const NO_FILTERS: Readonly<AuditQuery> = Object.freeze({ fromDate: '', toDate: '', agentId: '', eventType: '' })

function fmtTs(iso: string) {
  return new Date(iso).toLocaleString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
}

/**
 * A REAL `<button>` when it is clickable, and only then.
 *
 * It was a `<span role="button">` with an `onClick` and nothing else: no
 * `tabIndex`, no key handler, no pressed state. That is a control a keyboard
 * cannot reach and a screen reader announces as a button that never says
 * whether it is the one currently filtering. Promoting it to the real element
 * gets focus, Enter and Space from the platform rather than from three lines
 * of hand-rolled key handling that would then be this file's to maintain.
 *
 * `aria-pressed` is what `outline` was already saying visually, and it is the
 * same fact `ToolbarFacet` publishes for the chips in the strip above — the
 * two interactive filter surfaces on this page now announce identically.
 *
 * The visible text stays the accessible name, deliberately: no `aria-label`
 * and no added `title`. Existing tests reach these by
 * `getByRole('button', { name: 'agent.stunned' })`, and a speech-input user
 * says what they can see.
 */
function EventTag({ type, active, onClick }: { type: string; active?: boolean; onClick?: () => void }) {
  const color = EVENT_COLORS[type] ?? 'var(--muted)'
  const style: CSSProperties = {
    display: 'inline-block', padding: '2px 8px', borderRadius: 4,
    fontSize: 11, fontWeight: 600, fontFamily: 'monospace',
    background: `color-mix(in srgb, ${color} 13%, transparent)`, color,
    cursor: onClick ? 'pointer' : 'default',
    outline: active ? `1px solid ${color}` : 'none',
    border: 'none',
    lineHeight: 1.5,
  }
  if (!onClick) return <span style={style}>{type}</span>
  return (
    <button type="button" onClick={onClick} aria-pressed={!!active} style={style}>
      {type}
    </button>
  )
}

// ── Toolbar chrome that DataTableToolbar does not own ───────────────────────

/**
 * A visibly-labelled field for the three server-query controls that are not a
 * `<select>`, so `ToolbarSelect` cannot supply them.
 *
 * Wrapping rather than `htmlFor` + `id`: the association cannot drift, and
 * there is no id to collide with a second audit table on some future page.
 * Same 11.5px caption treatment `ToolbarSelect` uses, so the row reads as one
 * strip rather than as this page's controls beside the design system's.
 */
function ToolbarField({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label style={{ fontSize: 11.5, color: 'var(--muted)', display: 'flex', alignItems: 'center', gap: 6 }}>
      {label}
      {children}
    </label>
  )
}

/**
 * The server-query controls, on their own line inside the strip.
 *
 * `width: 100%` in a wrapping flex row is what puts the client-side controls
 * beneath rather than beside them, and the rule under it is the only thing on
 * screen that says the two halves reach different places: above it a control
 * re-queries the server, below it a control hides rows already in the browser.
 * On a compliance surface that distinction is the difference between "there
 * are no such events" and "there are none in the fifty I have".
 */
const SERVER_GROUP: CSSProperties = {
  display: 'flex',
  flexWrap: 'wrap',
  alignItems: 'center',
  gap: 8,
  width: '100%',
  paddingBottom: 10,
  borderBottom: '1px solid var(--border)',
}

/** Matches DataTable's own toolbar wrapper, for the states where no table renders. */
const TOOLBAR_WRAP: CSSProperties = {
  display: 'flex',
  flexWrap: 'wrap',
  alignItems: 'center',
  gap: 8,
  marginBottom: 12,
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

  // The two client-side controls. They narrow the rows ALREADY LOADED and never
  // reach the server, which is why they sit below the rule in the strip and why
  // the count beside them counts loaded events rather than the audit record.
  const [search, setSearch] = useState('')
  const [eventClass, setEventClass] = useState<EventClass>('all')

  // Track active filters so polling uses same params
  const filtersRef = useRef({ fromDate, toDate, agentId, eventType })

  /**
   * The same four values as `filtersRef`, mirrored into state.
   *
   * The ref exists so `fetchPage` can read the current filters without being
   * rebuilt on every keystroke, and a ref by definition cannot drive a render —
   * so nothing on screen could say whether what is typed in the four controls
   * is what the table is actually showing. The four inputs apply on a button,
   * so that gap is reachable simply by typing, and on a page whose whole job is
   * to be believed, a filter that looks applied and is not is the worst
   * available failure. Every write to the ref writes here too.
   */
  const [applied, setApplied] = useState<AuditQuery>(NO_FILTERS)

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
    filtersRef.current = NO_FILTERS
    setApplied(NO_FILTERS)
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

  /** The one place the ref and its mirror are written, so they cannot diverge. */
  function commit(next: AuditQuery) {
    filtersRef.current = next
    setApplied(next)
  }

  function applyFilters() {
    commit({ fromDate, toDate, agentId, eventType })
    setEvents([])
    fetchPage(1, true)
  }

  /**
   * Clears BOTH tiers — the four server filters and the two client-side ones.
   *
   * One control, because "Clear filters" naming only some of the filters is the
   * kind of half-reset that leaves an operator staring at a narrowed table
   * having already done the thing that was supposed to widen it.
   */
  function clearFilters() {
    setFromDate('')
    setToDate('')
    setAgentId('')
    setEventType('')
    setSearch('')
    setEventClass('all')
    commit(NO_FILTERS)
    setEvents([])
    fetchPage(1, true)
  }

  function toggleTypeFilter(type: string) {
    const next = eventType === type ? '' : type
    setEventType(next)
    commit({ ...filtersRef.current, eventType: next })
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

  // ── The client-side narrowing ─────────────────────────────────────────────
  //
  // The predicate lives here and not in DataTableToolbar, which is the whole
  // point of that module: it never sees a row, so this page decides what
  // "search" means for an audit event. Here it means the five things the table
  // actually renders — including the detail payload, because an operator
  // hunting a reason code is looking at the last column when they reach for the
  // box.
  //
  // Both controls default to a no-op, and that is load-bearing rather than
  // convenient: on first paint the array handed to DataTable is `events`
  // itself, in the order the server sent it, so nothing about this strip can
  // change what an untouched page shows.
  const query = search.trim().toLowerCase()

  const visibleEvents = useMemo(() => {
    if (!query && eventClass === 'all') return events
    return events.filter((ev) => {
      if (eventClass !== 'all' && classOf(ev.event_type) !== eventClass) return false
      if (!query) return true
      return (
        ev.event_type.toLowerCase().includes(query)
        || (ev.agent_name ?? '').toLowerCase().includes(query)
        || (ev.agent_id ?? '').toLowerCase().includes(query)
        || (ev.actor ?? '').toLowerCase().includes(query)
        || JSON.stringify(ev.detail ?? {}).toLowerCase().includes(query)
      )
    })
  }, [events, query, eventClass])

  // Counts of the WHOLE loaded array, never of the result. A chip reporting the
  // filtered set reads 0 for every option the reader has not chosen and stops
  // being a way back to the rows it is hiding — the reason DataTableToolbar
  // takes counts as a prop rather than computing them.
  const classCounts = useMemo(() => {
    const counts = Object.fromEntries(EVENT_CLASSES.map((c) => [c, 0])) as Record<EventClass, number>
    counts.all = events.length
    for (const ev of events) counts[classOf(ev.event_type)] += 1
    return counts
  }, [events])

  // A fact about the OTHER controls, never about the row count: an empty result
  // is exactly when the way out is needed.
  const narrowed =
    query !== '' || eventClass !== 'all'
    || fromDate !== '' || toDate !== '' || agentId !== '' || eventType !== ''
    || applied.fromDate !== '' || applied.toDate !== '' || applied.agentId !== '' || applied.eventType !== ''

  // Typed but not yet sent. See the note on `applied`.
  const pending =
    fromDate !== applied.fromDate || toDate !== applied.toDate
    || agentId !== applied.agentId || eventType !== applied.eventType

  const filterStrip = (
    <DataTableToolbar label="Filter the audit trail">
      {/* ── Tier 1: re-queries the server ─────────────────────────────────── */}
      <div role="group" aria-label="Query the audit record on the server" style={SERVER_GROUP}>
        {/* Explicit widths, because a `datetime-local` sizes itself from the
            placeholder the BROWSER chooses for the user's locale — "dd/mm/yyyy,
            --:--" here, "mm/dd/yyyy, --:-- --" for a US en, wider again for
            ja-JP. Left intrinsic, this row's wrap point is a property of the
            reader's machine, which is not a thing to discover from a support
            ticket. 172px holds every form of the placeholder these fields have
            to show. */}
        <ToolbarField label="From">
          <input
            type="datetime-local"
            aria-label="From date and time"
            value={fromDate}
            onChange={e => setFromDate(e.target.value)}
            data-testid="audit-from"
            style={{ fontSize: 12, width: 172 }}
          />
        </ToolbarField>
        <ToolbarField label="To">
          <input
            type="datetime-local"
            aria-label="To date and time"
            value={toDate}
            onChange={e => setToDate(e.target.value)}
            data-testid="audit-to"
            style={{ fontSize: 12, width: 172 }}
          />
        </ToolbarField>
        <ToolbarField label="Agent UUID">
          <input
            type="text"
            value={agentId}
            onChange={e => setAgentId(e.target.value)}
            placeholder="xxxxxxxx-…"
            data-testid="audit-agent"
            style={{ width: 172, fontSize: 12 }}
          />
        </ToolbarField>
        {/* Thirty-two options, so a select and not chips — and no counts on
            them. This control filters at the SERVER, so the only counts this
            page could put beside an option are counts of the fifty rows it
            happens to hold, which would understate every option in the list.
            An absent measurement and a measured zero are different facts. */}
        <ToolbarSelect
          label="Event type"
          subject="the audit record"
          value={eventType}
          options={[{ value: '', label: 'All types' }, ...EVENT_TYPES.map(t => ({ value: t }))]}
          onChange={setEventType}
          testId="audit-type"
        />
        {/* The action and its two annotations travel together.
            Left as three siblings of the fields, the row wraps between them at
            whatever width the fields happen to total, and what lands alone on
            the second line is a bare "?" — which then reads as a hint about
            nothing. Grouped, the wrap can only happen before the cluster, so
            the second line is either absent or the whole action. */}
        {/* `width: 100%` so this is always its own line, never sometimes.
            Sharing a line with the fields, the cluster's width changes the
            moment "not applied yet" appears — which is the first keystroke —
            and that reflow moves Apply itself. Clicking Apply then removes the
            caption and moves Apply back, under a pointer that is resting on
            it. DataTableToolbar's header comment argues exactly this about the
            clear control, and answers it by ordering the strip so that the only
            thing a control's arrival can move is a count. Here the answer is a
            line of its own: the caption grows to Apply's right and moves
            nothing, at any viewport width. */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, width: '100%' }}>
          <button
            className="btn btn-primary"
            onClick={applyFilters}
            data-testid="audit-apply"
            style={{ padding: '5px 14px', fontSize: 12 }}
          >
            Apply
          </button>
          {/* Amber text on the page ground, never a fill behind text: measured
              6.33:1 Dark, 5.02:1 Light, 7.13:1 Andy. Black on an amber fill is
              4.06:1 in Andy and fails AA. */}
          {pending && (
            <span data-testid="audit-filter-pending" style={{ fontSize: 11.5, color: 'var(--amber)' }}>
              not applied yet
            </span>
          )}
          {/* Sits with Apply and names it, because a "?" beside a button is
              read as being about that button whatever it says — proximity
              establishes the association, so the label has to agree with it. */}
          <HelpHint label="What these filters do and when they apply" testId="audit-server-filter-help">
            {'These four are sent to the server and it decides which rows exist, so they narrow the '
              + 'whole audit record and not just what is on screen. They take effect when you press '
              + 'Apply — the two controls below the line take effect as you type. Export CSV always '
              + 'uses these four, so it returns every matching event and not only the rows loaded here.'}
          </HelpHint>
        </div>
      </div>

      {/* ── Tier 2: hides rows already in the browser ─────────────────────── */}
      <ToolbarSearch
        label="Search the loaded audit events"
        placeholder="Search type, agent, actor or detail…"
        value={search}
        onChange={setSearch}
        testId="audit-search"
      />
      <ToolbarFacet
        label="Filter the loaded audit events by class"
        value={eventClass}
        options={EVENT_CLASSES.map(c => ({ value: c, count: classCounts[c] }))}
        onChange={next => setEventClass(next as EventClass)}
        testIdPrefix="audit-class"
      />
      <ToolbarClear active={narrowed} onClear={clearFilters} testId="audit-clear" />
      <ToolbarCount
        shown={visibleEvents.length}
        total={events.length}
        noun="loaded events"
        testId="audit-count"
      />
      {/* The exception DataTableToolbar's children API exists for. */}
      <HelpHint label="What the search box and class chips do" testId="audit-refine-help">
        {'These two hide rows that are already in this browser. They never ask the server for '
          + 'anything, so an empty result here means nothing matched among the events loaded so '
          + 'far — not that the audit record holds no such event. Load More, or narrow with the '
          + 'four controls above the line, to search the record itself. The number on each chip '
          + 'counts the loaded events of that class, not the ones currently on screen.'}
      </HelpHint>
    </DataTableToolbar>
  )

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
          {/* Beside the button, not inside it: nested in the `button` the hint
              joins its accessible name and `Export CSV` stops matching. */}
          <HelpHint label="What Export CSV contains" testId="audit-export-help">
            {'Every event matching the four server filters, not just the rows loaded below — the '
              + 'file is not paginated. The search box and class chips are not applied to it, '
              + 'because they hide rows rather than exclude them from the record.'}
          </HelpHint>
        </div>
      </div>
      {exportError && (
        <div style={{ color: 'var(--error)', fontSize: 12, marginBottom: 12 }}>{exportError}</div>
      )}

      {/* Table.
          The filter strip is no longer a card above this ternary — it is
          DataTable's `toolbar` slot, which renders it above the empty branch by
          construction so a filter that matches nothing can always be undone.
          The two states where no table exists at all render the same strip in
          the same wrapper, because the previous card was live during a load and
          during an error, and an operator who has just been told the fetch
          failed is very often reaching for Apply. */}
      {loading ? (
        <>
          <div data-testid="audit-toolbar" style={TOOLBAR_WRAP}>{filterStrip}</div>
          <LoadingState variant="block" status="loading" label="audit events" testId="audit-load-state" />
        </>
      ) : error ? (
        <>
          <div data-testid="audit-toolbar" style={TOOLBAR_WRAP}>{filterStrip}</div>
          <LoadingState variant="block" status="error" label="audit events" error={error} onRetry={() => fetchPage(1, true)} testId="audit-load-state" />
        </>
      ) : (
        <>
          <DataTable<AuditEventResponse>
            columns={[
              {
                key: 'timestamp',
                label: 'Timestamp',
                sortable: true,
                help:
                  'When the server recorded the event, rendered in this browser\'s time zone — '
                  + 'two people in different offices see different clock times for the same row, '
                  + 'and the exported CSV carries the original UTC value rather than either of '
                  + 'them.',
              },
              {
                key: 'event_type',
                label: 'Event Type',
                sortable: true,
                help:
                  'What happened, in the vocabulary the server writes. Click any tag in the '
                  + 'table to filter the whole record to that type, and click it again to clear '
                  + 'it — that reaches the server, unlike the class chips in the strip above.',
              },
              {
                key: 'agent_name',
                label: 'Agent',
                sortable: true,
                help:
                  'The agent the event was about, with the first eight characters of its ID '
                  + 'beneath. A dash means the event was not about a particular agent — a tenant '
                  + 'or account action rather than an agent one.',
              },
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
              {
                // `detail` rather than a second `event_type`. The column was
                // keyed to the wrong field: harmless for sorting, which it does
                // not offer, but the help test-id is derived from the key, so
                // two columns claiming `event_type` could only ever carry one
                // hint between them.
                key: 'detail',
                label: 'Detail',
                help:
                  'Everything else the server recorded about the event, verbatim and unedited. '
                  + 'Long payloads are cut to one line here — hover the value to read it in full, '
                  + 'or export the CSV, which never truncates.',
              },
            ]}
            data={visibleEvents}
            pageSize={25}
            testIdPrefix="audit"
            toolbar={filterStrip}
            emptyState={
              events.length === 0 ? (
                // Nothing came back from the server. Wording unchanged: this is
                // the branch that was here before.
                <EmptyState kicker="No events found" body="Try adjusting your filters or wait for governance actions to be recorded." />
              ) : (
                // Rows exist and are being hidden by this browser — a different
                // fact, and the only one of the two an operator can undo
                // instantly. The way out appears twice on purpose: the strip
                // survives this branch by construction, and this one is
                // reachable from where the mistake is visible.
                <div data-testid="audit-filtered-empty">
                  <EmptyState
                    kicker="Nothing matches these filters"
                    body={`All ${events.length.toLocaleString()} loaded events are still here — the search box or a class chip above is hiding them.`}
                  />
                  <div style={{ display: 'flex', justifyContent: 'center', marginTop: -34, marginBottom: 12 }}>
                    <button
                      type="button"
                      className="btn btn-secondary"
                      onClick={clearFilters}
                      data-testid="audit-empty-clear"
                      style={{ fontSize: 12, padding: '5px 12px' }}
                    >
                      Clear filters
                    </button>
                  </div>
                </div>
              )
            }
            renderRow={(ev, i) => (
              // The stripe was `rgba(255,255,255,0.01)` — white, so it did
              // nothing at all on the Light theme's white ground and the rows
              // there were unbanded. Mixing the theme's own text colour instead
              // bands every theme with one rule, and at 3% of a foreground that
              // is already AA against this surface it cannot move any cell's
              // contrast enough to matter.
              <tr key={ev.id} style={{ borderBottom: '1px solid var(--border)', background: i % 2 === 0 ? 'transparent' : 'color-mix(in srgb, var(--text) 3%, transparent)' }}>
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
                {/* Both of these cells are ellipsised, and until now the cut-off
                    text was simply gone — no way to read an actor past 180px or
                    a payload past 300px without exporting the file. `title` is
                    the browser's own affordance for exactly that and costs
                    nothing; it is not a substitute for the column hint, which
                    explains what the value IS. */}
                <td title={ev.actor || undefined} style={{ ...DataTable.td, color: 'var(--muted)', maxWidth: 180, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{ev.actor || '—'}</td>
                <td style={{ ...DataTable.td, maxWidth: 300 }}>
                  <code title={JSON.stringify(ev.detail ?? {}, null, 2)} style={{ fontSize: 11, color: 'var(--muted)', background: 'var(--surface2)', padding: '2px 6px', borderRadius: 3, display: 'block', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {Object.keys(ev.detail).length > 0 ? JSON.stringify(ev.detail) : '{}'}
                  </code>
                </td>
              </tr>
            )}
          />

          {/* Load More (server-side — complements the client-side DataTable pagination).
              Gated on there being anything loaded, which is what the old
              `events.length === 0 ? empty : table` ternary did implicitly:
              "Loaded 0 of 0 events from server" beneath a panel that already
              says no events were found is furniture restating a fact. */}
          {events.length > 0 && (
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
          )}
        </>
      )}
    </div>
  )
}
