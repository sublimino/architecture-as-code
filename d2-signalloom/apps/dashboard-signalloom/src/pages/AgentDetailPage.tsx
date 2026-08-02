import { useState, useEffect, useCallback, useMemo } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import type {
  AgentResponse,
  AuditEventResponse,
  ViolationResponse,
  AgentComplianceResultResponse,
} from '../types/api'
import { colors } from '../styles/tokens'
import StatusBadge from '../components/StatusBadge'
import EmptyState from '../components/EmptyState'
import ErrorState from '../components/ErrorState'
import CredentialActionsMenu from '../components/CredentialActionsMenu'

// ─── Helpers ────────────────────────────────────────────────────────────────

function fmtTs(iso: string | null) {
  if (!iso) return '—'
  return new Date(iso).toLocaleString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}

function fmtDate(iso: string | null) {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })
}

// ─── Timeline ────────────────────────────────────────────────────────────────

type TimelineItem =
  | { kind: 'audit'; ts: string; event: AuditEventResponse }
  | { kind: 'violation'; ts: string; violation: ViolationResponse }

const EVENT_TYPE_COLORS: Record<string, string> = {
  enrollment:                  colors.cyanLoom,
  state_transition:            colors.irisViolet,
  violation_detected:          colors.red,
  compliance_check:            'var(--cyan)',
  token_issued:                colors.tealLoom,
  token_refused:               colors.amber,
  tenant_created:              colors.cyanLoom,
  user_provisioned:            'var(--teal)',
  directory_connected:         'var(--violet)',
  discovery_enroll_requested:  colors.amber,
}

function EventTypeTag({ type }: { type: string }) {
  const color = EVENT_TYPE_COLORS[type] ?? colors.muted
  return (
    <span style={{
      display: 'inline-block', padding: '2px 8px', borderRadius: 4,
      fontSize: 11, fontWeight: 600, fontFamily: 'monospace',
      background: color + '22', color,
    }}>
      {type}
    </span>
  )
}

function ViolationBadge({ status }: { status: string }) {
  return <StatusBadge status={status} variant="violation" />
}

const EVENT_TYPES = [
  'enrollment', 'state_transition', 'violation_detected', 'compliance_check',
  'token_issued', 'token_refused',
]

function Timeline({ items, onAcknowledge }: {
  items: TimelineItem[]
  onAcknowledge: (violationId: string) => Promise<void>
}) {
  const [typeFilter, setTypeFilter] = useState<string>('all')
  const [acknowledging, setAcknowledging] = useState<string | null>(null)

  const filtered = useMemo(() => {
    if (typeFilter === 'all') return items
    if (typeFilter === 'violations') return items.filter(i => i.kind === 'violation')
    return items.filter(i => i.kind === 'audit' && i.event.event_type === typeFilter)
  }, [items, typeFilter])

  async function handleAcknowledge(violationId: string) {
    setAcknowledging(violationId)
    try {
      await onAcknowledge(violationId)
    } finally {
      setAcknowledging(null)
    }
  }

  return (
    <section style={{ marginBottom: 28 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 14 }}>
        <h2 style={{ fontSize: 15, fontWeight: 700 }}>Activity Timeline</h2>
        <select
          value={typeFilter}
          onChange={(e) => setTypeFilter(e.target.value)}
          style={{ width: 180, fontSize: 12 }}
        >
          <option value="all">All events</option>
          <option value="violations">Violations only</option>
          {EVENT_TYPES.map(t => (
            <option key={t} value={t}>{t.replace(/_/g, ' ')}</option>
          ))}
        </select>
      </div>

      {filtered.length === 0 ? (
        <EmptyState kicker="No events recorded" body="Governance actions for this agent will appear here." />
      ) : (
        <div style={{ maxHeight: 480, overflowY: 'auto', paddingRight: 4 }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 0 }}>
            {filtered.map((item, idx) => {
              if (item.kind === 'violation') {
                const v = item.violation
                const isNew = v.status === 'new'
                return (
                  <div key={`v-${v.id}`} style={{
                    display: 'flex', gap: 14, padding: '12px 0',
                    borderBottom: idx < filtered.length - 1 ? '1px solid var(--border)' : 'none',
                  }}>
                    <div style={{ width: 2, background: isNew ? colors.red : colors.slateGray, borderRadius: 2, flexShrink: 0, minHeight: 36 }} />
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', marginBottom: 4 }}>
                        <span style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace', flexShrink: 0 }}>{fmtTs(v.created_at)}</span>
                        <span style={{
                          fontSize: 11, fontWeight: 600, padding: '1px 6px', borderRadius: 3,
                          background: 'rgba(220,38,38,0.12)', color: colors.red,
                        }}>VIOLATION</span>
                        <ViolationBadge status={v.status} />
                        {v.severity && (
                          <span style={{ fontSize: 11, color: 'var(--muted)' }}>{v.severity} severity</span>
                        )}
                      </div>
                      <div style={{ fontSize: 13, fontWeight: 500, marginBottom: 4 }}>
                        {v.violation_type ?? 'Policy Violation'}
                      </div>
                      {v.analysis && (
                        <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 4 }}>{v.analysis}</div>
                      )}
                      {v.recommended_action && (
                        <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 6 }}>
                          <span style={{ color: 'var(--text)', fontWeight: 500 }}>Recommended: </span>
                          {v.recommended_action}
                        </div>
                      )}
                      {isNew && (
                        <button
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
                          Acknowledged by {v.acknowledged_by} · {fmtDate(v.acknowledged_at)}
                        </div>
                      )}
                    </div>
                  </div>
                )
              }

              const ev = item.event
              const lineColor = EVENT_TYPE_COLORS[ev.event_type] ?? 'var(--border-subtle)'
              return (
                <div key={`e-${ev.id}`} style={{
                  display: 'flex', gap: 14, padding: '10px 0',
                  borderBottom: idx < filtered.length - 1 ? '1px solid var(--border)' : 'none',
                }}>
                  <div style={{ width: 2, background: lineColor, borderRadius: 2, flexShrink: 0, minHeight: 28, opacity: 0.5 }} />
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', marginBottom: 3 }}>
                      <span style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace', flexShrink: 0 }}>{fmtTs(ev.timestamp)}</span>
                      <EventTypeTag type={ev.event_type} />
                    </div>
                    <div style={{ display: 'flex', gap: 12, fontSize: 12, color: 'var(--muted)' }}>
                      {ev.actor && <span>Actor: <span style={{ color: 'var(--text)' }}>{ev.actor}</span></span>}
                      {Object.keys(ev.detail).length > 0 && (
                        <code style={{
                          fontSize: 11, color: 'var(--muted)', background: 'var(--surface2)',
                          padding: '2px 6px', borderRadius: 3, maxWidth: 400,
                          overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', display: 'block',
                        }}>
                          {JSON.stringify(ev.detail)}
                        </code>
                      )}
                    </div>
                  </div>
                </div>
              )
            })}
          </div>
        </div>
      )}
    </section>
  )
}

// ─── Compliance Summary ───────────────────────────────────────────────────────

function ComplianceSummarySection({ posture, openViolations, lastAssessed }: {
  posture: number | null
  openViolations: number
  lastAssessed: string | null
}) {
  const scoreColor = posture === null
    ? colors.muted
    : posture >= 80 ? colors.tealLoom
    : posture >= 50 ? colors.amber
    : colors.red

  return (
    <section style={{ marginBottom: 28 }}>
      <h2 style={{ fontSize: 15, fontWeight: 700, marginBottom: 14 }}>Compliance</h2>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 14 }}>
        <div className="card" style={{ textAlign: 'center', padding: '20px 16px' }}>
          <div style={{ fontSize: 42, fontWeight: 800, color: scoreColor, lineHeight: 1 }}>
            {posture !== null ? `${posture}%` : '—'}
          </div>
          <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 8, textTransform: 'uppercase', letterSpacing: '0.06em' }}>
            Posture Score
          </div>
          {posture === null && (
            <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4 }}>Pending assessment</div>
          )}
        </div>
        <div className="card" style={{ textAlign: 'center', padding: '20px 16px' }}>
          <div style={{ fontSize: 42, fontWeight: 800, color: openViolations > 0 ? colors.red : colors.tealLoom, lineHeight: 1 }}>
            {openViolations}
          </div>
          <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 8, textTransform: 'uppercase', letterSpacing: '0.06em' }}>
            Open Violations
          </div>
        </div>
        <div className="card" style={{ padding: '20px 16px' }}>
          <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>
            Last Assessed
          </div>
          <div style={{ fontSize: 14, fontWeight: 500 }}>
            {lastAssessed ? fmtDate(lastAssessed) : '—'}
          </div>
          {!lastAssessed && (
            <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4 }}>Run an assessment to populate this</div>
          )}
        </div>
      </div>
    </section>
  )
}

// ─── Framework Controls ───────────────────────────────────────────────────────

interface FrameworkGroup {
  name: string
  controls: AgentComplianceResultResponse[]
}

function FrameworkControlsSection({ results, onReassess }: {
  results: AgentComplianceResultResponse[]
  onReassess: (controlId: string) => Promise<void>
}) {
  const [requesting, setRequesting] = useState<string | null>(null)
  const [requested, setRequested] = useState<Set<string>>(new Set())

  const frameworks: FrameworkGroup[] = useMemo(() => {
    const map: Record<string, AgentComplianceResultResponse[]> = {}
    for (const r of results) {
      if (!map[r.framework_name]) map[r.framework_name] = []
      map[r.framework_name].push(r)
    }
    return Object.entries(map).map(([name, controls]) => ({ name, controls }))
  }, [results])

  async function handleReassess(controlId: string) {
    setRequesting(controlId)
    try {
      await onReassess(controlId)
      setRequested(prev => new Set(prev).add(controlId))
    } catch (e) {
      alert(`Reassessment request failed: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setRequesting(null)
    }
  }

  if (frameworks.length === 0) {
    return (
      <section>
        <h2 style={{ fontSize: 15, fontWeight: 700, marginBottom: 14 }}>Framework Controls</h2>
        <EmptyState kicker="No assessment results" body="Compliance controls will appear here after the first assessment run." />
      </section>
    )
  }

  const statusIcon: Record<string, string> = {
    pass: '✓',
    fail: '✗',
    pending: '○',
    reassessment_requested: '↻',
  }
  const statusColor: Record<string, string> = {
    pass: colors.tealLoom,
    fail: colors.red,
    pending: colors.muted,
    reassessment_requested: colors.amber,
  }

  return (
    <section>
      <h2 style={{ fontSize: 15, fontWeight: 700, marginBottom: 14 }}>Framework Controls</h2>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        {frameworks.map((fw) => {
          const passing = fw.controls.filter(c => c.status === 'pass').length
          const failing = fw.controls.filter(c => c.status === 'fail').length
          return (
            <div key={fw.name} className="card" style={{ padding: 0, overflow: 'hidden' }}>
              {/* Framework header */}
              <div style={{
                display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                padding: '14px 20px', borderBottom: '1px solid var(--border)',
                background: 'var(--surface2)',
              }}>
                <span style={{ fontWeight: 600, fontSize: 14 }}>{fw.name}</span>
                <div style={{ display: 'flex', gap: 12, fontSize: 12 }}>
                  <span style={{ color: colors.tealLoom }}>{passing} passing</span>
                  {failing > 0 && <span style={{ color: colors.red }}>{failing} failing</span>}
                  <span style={{ color: 'var(--muted)' }}>{fw.controls.length} controls</span>
                </div>
              </div>

              {/* Controls list */}
              <div>
                {fw.controls.map((c, i) => {
                  const isFail = c.status === 'fail'
                  const alreadyRequested = requested.has(c.control_id) || c.status === 'reassessment_requested'
                  return (
                    <div
                      key={c.control_id}
                      style={{
                        display: 'flex', alignItems: 'center', gap: 14,
                        padding: '10px 20px',
                        borderBottom: i < fw.controls.length - 1 ? '1px solid var(--border)' : 'none',
                        background: isFail ? 'rgba(220,38,38,0.03)' : 'transparent',
                      }}
                    >
                      {/* Status icon */}
                      <span style={{
                        fontSize: 15, fontWeight: 700, flexShrink: 0,
                        color: statusColor[c.status] ?? colors.muted,
                        width: 18, textAlign: 'center',
                      }}>
                        {statusIcon[c.status] ?? '?'}
                      </span>

                      {/* Control name */}
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontSize: 13, fontWeight: isFail ? 500 : 400 }}>{c.control_name}</div>
                        {c.assessed_at && (
                          <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 1 }}>
                            Assessed {fmtDate(c.assessed_at)}
                          </div>
                        )}
                      </div>

                      {/* Status badge */}
                      <StatusBadge status={c.status} variant="compliance" />

                      {/* Reassess button for failed controls */}
                      {isFail && (
                        <button
                          className="btn btn-secondary"
                          style={{ fontSize: 11, padding: '4px 12px', flexShrink: 0 }}
                          disabled={alreadyRequested || requesting === c.control_id}
                          onClick={() => handleReassess(c.control_id)}
                        >
                          {requesting === c.control_id
                            ? 'Requesting…'
                            : alreadyRequested
                            ? 'Requested'
                            : 'Request Reassessment'}
                        </button>
                      )}
                    </div>
                  )
                })}
              </div>
            </div>
          )
        })}
      </div>
    </section>
  )
}

// ─── Lifecycle transitions (mirrors agent_registry VALID_TRANSITIONS) ─────────
// Source of truth: services/agent_registry/routers/lifecycle.py
// Transitions are operator-mediated: the direct POST /agents/{id}/transition is
// Entra-only and the api-gateway proxy returns 403 for dashboard (customer) users.
// So the dashboard submits a *request* via the /support channel for an operator
// to action — it does NOT call the transition endpoint directly.

const VALID_NEXT_STATES: Record<string, { state: string; label: string }[]> = {
  enrolled: [{ state: 'active', label: 'Active (activate)' }],
  active: [
    { state: 'suspended', label: 'Suspended (suspend)' },
    { state: 'revoked', label: 'Revoked (decommission)' },
  ],
  suspended: [
    { state: 'active', label: 'Active (reinstate)' },
    { state: 'revoked', label: 'Revoked (decommission)' },
  ],
  revoked: [],
}

// ─── Request Transition Modal ─────────────────────────────────────────────────

function RequestTransitionModal({ agent, onClose }: { agent: AgentResponse; onClose: () => void }) {
  const { getAccessTokenSilently } = useAuth0()
  const options = VALID_NEXT_STATES[agent.lifecycle_state] ?? []
  const [toState, setToState] = useState(options[0]?.state ?? '')
  const [urgency, setUrgency] = useState<'low' | 'normal' | 'high' | 'critical'>('normal')
  const [reason, setReason] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState(false)

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    const trimmedReason = reason.trim()
    if (!toState) {
      setError('Select a target state.')
      return
    }
    if (!trimmedReason) {
      setError('A reason is required so your operator can action the request.')
      return
    }
    setSubmitting(true)
    setError(null)
    try {
      const token = await getAccessTokenSilently()
      const targetLabel = options.find(o => o.state === toState)?.label ?? toState
      await api.support(token, {
        subject: `Lifecycle transition request: ${agent.name} → ${toState}`,
        urgency,
        message:
          `Transition request submitted from the dashboard.\n\n` +
          `Agent: ${agent.name}\n` +
          `Agent ID: ${agent.id}\n` +
          `Current state: ${agent.lifecycle_state}\n` +
          `Requested state: ${targetLabel}\n\n` +
          `Reason:\n${trimmedReason}`,
      })
      setSuccess(true)
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Request failed. Please try again.')
      setSubmitting(false)
    }
  }

  return (
    <div
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.53)', backdropFilter: 'blur(6px)', zIndex: 1000,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}
      onClick={e => e.target === e.currentTarget && !submitting && onClose()}
    >
      <div className="card slide-up" style={{ width: 440, maxWidth: '95vw', padding: 24, position: 'relative' }}>
        {success ? (
          <div style={{ textAlign: 'center', padding: '12px 0' }}>
            <div style={{ fontSize: 44, marginBottom: 14 }}>✅</div>
            <p style={{ fontWeight: 600, fontSize: 15, marginBottom: 6 }}>Transition requested</p>
            <p style={{ color: 'var(--muted)', fontSize: 13, marginBottom: 24 }}>
              Your Signal Loom operator will review and apply the change. It will appear in this
              agent's activity timeline once actioned.
            </p>
            <button className="btn btn-primary" onClick={onClose}>Close</button>
          </div>
        ) : (
          <>
            <h3 style={{ marginBottom: 6 }}>Request Lifecycle Transition</h3>
            <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 16, lineHeight: 1.5 }}>
              Lifecycle changes are applied by your Signal Loom operator. This sends them a request
              to action — the agent's state changes once they apply it.
            </p>
            <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              <div>
                <span style={{ display: 'block', fontSize: 12, marginBottom: 4, color: 'var(--muted)' }}>Current state</span>
                <StatusBadge status={agent.lifecycle_state} variant="lifecycle" />
              </div>
              <div>
                <label htmlFor="rt-target" style={{ display: 'block', fontSize: 12, marginBottom: 4 }}>Requested state *</label>
                <select
                  id="rt-target"
                  value={toState}
                  onChange={e => setToState(e.target.value)}
                  required
                  style={{ width: '100%' }}
                >
                  {options.map(o => (
                    <option key={o.state} value={o.state}>{o.label}</option>
                  ))}
                </select>
              </div>
              <div>
                <label htmlFor="rt-urgency" style={{ display: 'block', fontSize: 12, marginBottom: 4 }}>Urgency</label>
                <select
                  id="rt-urgency"
                  value={urgency}
                  onChange={e => setUrgency(e.target.value as typeof urgency)}
                  style={{ width: '100%' }}
                >
                  <option value="low">Low — when convenient</option>
                  <option value="normal">Normal — soon</option>
                  <option value="high">High — impacting operations</option>
                  <option value="critical">Critical — security or data risk</option>
                </select>
              </div>
              <div>
                <label htmlFor="rt-reason" style={{ display: 'block', fontSize: 12, marginBottom: 4 }}>Reason *</label>
                <textarea
                  id="rt-reason"
                  value={reason}
                  onChange={e => setReason(e.target.value)}
                  required
                  maxLength={5000}
                  rows={4}
                  placeholder="Why is this transition needed?"
                  style={{ width: '100%', resize: 'vertical' }}
                />
              </div>
              {error && <p style={{ color: 'var(--error)', fontSize: 12 }}>{error}</p>}
              <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, marginTop: 8 }}>
                <button type="button" className="btn btn-secondary" onClick={onClose} disabled={submitting}>Cancel</button>
                <button type="submit" className="btn btn-primary" disabled={submitting || !toState || !reason.trim()}>
                  {submitting ? 'Submitting…' : 'Submit Request'}
                </button>
              </div>
            </form>
          </>
        )}
      </div>
    </div>
  )
}

// ─── Issue Credential Modal ───────────────────────────────────────────────────
// Step 2 of register-then-issue (EHD-E3-001): mint an identity credential for an
// existing agent record. Self-serve — the customer calls the endpoint directly
// (unlike transitions, which are operator-mediated). The returned token is shown
// exactly once and held only in React state; it is NEVER written to localStorage
// or any browser storage (no-localStorage token policy). Server-side only its
// SHA-256 hash is persisted. Re-issuing appends a new token (rotation).

function IssueCredentialModal({ agent, onClose }: { agent: AgentResponse; onClose: () => void }) {
  const { getAccessTokenSilently } = useAuth0()
  const [phase, setPhase] = useState<'confirm' | 'issuing' | 'done'>('confirm')
  const [token, setToken] = useState<string | null>(null)
  const [expiresAt, setExpiresAt] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)

  async function handleIssue() {
    setPhase('issuing')
    setError(null)
    try {
      const accessToken = await getAccessTokenSilently()
      const res = await api.agents.issueCredential(accessToken, agent.id)
      setToken(res.identity_token)
      setExpiresAt(res.token_expires_at)
      setPhase('done')
    } catch (err: unknown) {
      const status = err && typeof err === 'object' && 'response' in err
        ? (err as { response?: { status?: number } }).response?.status
        : undefined
      if (status === 403) {
        setError(
          `A credential can't be issued while this agent is ${agent.lifecycle_state}. ` +
          `Reinstate it to active first.`
        )
      } else {
        setError(err instanceof Error ? err.message : 'Failed to issue credential.')
      }
      setPhase('confirm')
    }
  }

  async function handleCopy() {
    if (token && navigator.clipboard) {
      try {
        await navigator.clipboard.writeText(token)
        setCopied(true)
        setTimeout(() => setCopied(false), 2000)
      } catch (err) {
        console.error('Failed to copy token:', err)
      }
    }
  }

  function dismiss() {
    // Drop the token from memory as the dialog closes — it is never persisted.
    setToken(null)
    onClose()
  }

  return (
    <div
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.53)', backdropFilter: 'blur(6px)', zIndex: 2000,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}
      onClick={e => e.target === e.currentTarget && phase === 'confirm' && dismiss()}
    >
      <div
        className="card slide-up"
        style={{ width: 520, maxWidth: '95vw', padding: 28, position: 'relative' }}
        role="dialog"
        aria-modal="true"
        aria-labelledby="issue-cred-title"
      >
        {phase === 'done' && token ? (
          <>
            <h2 id="issue-cred-title" style={{ fontSize: 17, fontWeight: 700, marginBottom: 8 }}>
              Identity credential for {agent.name}
            </h2>
            <p style={{ fontSize: 13, fontWeight: 600, color: 'var(--warning, #f59e0b)', marginBottom: 20 }}>
              This is the only time this token will be shown — store it securely now.
              It cannot be retrieved again after you dismiss this dialog.
            </p>
            <div style={{
              background: 'var(--surface2)', border: '1px solid var(--border)',
              borderRadius: 6, padding: '12px 14px',
              fontFamily: 'monospace', fontSize: 13,
              wordBreak: 'break-all', lineHeight: 1.6,
              color: 'var(--text)', marginBottom: 16, userSelect: 'all',
            }}>
              {token}
            </div>
            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end', marginBottom: 12 }}>
              <button className="btn btn-primary" onClick={handleCopy} style={{ minWidth: 120 }}>
                {copied ? 'Copied!' : 'Copy token'}
              </button>
              <button className="btn btn-secondary" onClick={dismiss}>
                I've saved it — dismiss
              </button>
            </div>
            <p style={{ fontSize: 11, color: 'var(--muted)', textAlign: 'center' }}>
              Expires {fmtTs(expiresAt)}
            </p>
          </>
        ) : (
          <>
            <h3 id="issue-cred-title" style={{ marginBottom: 6 }}>Issue Identity Credential</h3>
            <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 16, lineHeight: 1.5 }}>
              This mints a fresh identity token so <strong>{agent.name}</strong> can authenticate to the
              platform. The token is shown once, here in this dialog — it is never stored in your browser
              and cannot be retrieved again. Any existing tokens for this agent keep working until they
              expire or are revoked.
            </p>
            {error && <p style={{ color: 'var(--error)', fontSize: 12, marginBottom: 12 }}>{error}</p>}
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
              <button type="button" className="btn btn-secondary" onClick={dismiss} disabled={phase === 'issuing'}>
                Cancel
              </button>
              <button type="button" className="btn btn-primary" onClick={handleIssue} disabled={phase === 'issuing'}>
                {phase === 'issuing' ? 'Issuing…' : 'Issue credential'}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  )
}

// ─── Revoke Credential Modal ──────────────────────────────────────────────────
// Self-serve counterpart to Issue Credential (ClickUp 86cak75u7): revokes ALL
// active tokens for the agent. There is nothing narrower to target — issuance
// is show-once, so the dashboard never has individual token IDs to revoke by.

function RevokeCredentialModal({ agent, onClose }: { agent: AgentResponse; onClose: (revoked?: boolean) => void }) {
  const { getAccessTokenSilently } = useAuth0()
  const [phase, setPhase] = useState<'confirm' | 'revoking' | 'done'>('confirm')
  const [revokedCount, setRevokedCount] = useState<number | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function handleRevoke() {
    setPhase('revoking')
    setError(null)
    try {
      const accessToken = await getAccessTokenSilently()
      const res = await api.agents.revokeCredential(accessToken, agent.id)
      setRevokedCount(res.tokens_revoked)
      setPhase('done')
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to revoke credentials.')
      setPhase('confirm')
    }
  }

  return (
    <div
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.8)', zIndex: 2000,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}
      onClick={e => e.target === e.currentTarget && phase === 'confirm' && onClose()}
    >
      <div
        className="card"
        style={{ width: 480, maxWidth: '95vw', padding: 28, position: 'relative' }}
        role="dialog"
        aria-modal="true"
        aria-labelledby="revoke-cred-title"
      >
        {phase === 'done' ? (
          <>
            <h2 id="revoke-cred-title" style={{ fontSize: 17, fontWeight: 700, marginBottom: 8 }}>
              Credentials revoked
            </h2>
            <p style={{ fontSize: 13, color: 'var(--text)', marginBottom: 20, lineHeight: 1.5 }}>
              {revokedCount === 0 ? (
                <>No active credentials for <strong>{agent.name}</strong> — nothing to revoke.</>
              ) : (
                <>
                  {revokedCount} credential{revokedCount === 1 ? '' : 's'} for <strong>{agent.name}</strong>{' '}
                  {revokedCount === 1 ? 'has' : 'have'} been revoked. {agent.name} will no longer be able to
                  authenticate with any previously-issued token.
                </>
              )}
            </p>
            <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
              <button className="btn btn-secondary" onClick={() => onClose(true)}>Close</button>
            </div>
          </>
        ) : (
          <>
            <h3 id="revoke-cred-title" style={{ marginBottom: 6 }}>Revoke Identity Credentials</h3>
            <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 16, lineHeight: 1.5 }}>
              This immediately revokes <strong>every</strong> active identity token issued for{' '}
              <strong>{agent.name}</strong>. Any system currently using one of those tokens will lose access
              right away. This cannot be undone — a new credential must be issued afterward if{' '}
              {agent.name} needs to authenticate again.
            </p>
            {error && <p style={{ color: 'var(--error)', fontSize: 12, marginBottom: 12 }}>{error}</p>}
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
              <button type="button" className="btn btn-secondary" onClick={() => onClose()} disabled={phase === 'revoking'}>
                Cancel
              </button>
              <button type="button" className="btn btn-danger" onClick={handleRevoke} disabled={phase === 'revoking'}>
                {phase === 'revoking' ? 'Revoking…' : 'Revoke all credentials'}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  )
}

// ─── Agent Header ─────────────────────────────────────────────────────────────

function fmtRelativeMinutes(iso: string | null) {
  if (!iso) return null
  const diff = Date.now() - new Date(iso).getTime()
  const mins = Math.floor(diff / 60000)
  if (mins < 1) return 'just now'
  if (mins === 1) return '1 minute ago'
  if (mins < 60) return `${mins} minutes ago`
  const hours = Math.floor(mins / 60)
  if (hours === 1) return '1 hour ago'
  if (hours < 24) return `${hours} hours ago`
  return fmtDate(iso)
}

function AgentHeader({ agent, onRequestTransition, onIssueCredential, onRevokeCredential, onScanCompliance, scanning, lastScanTimestamp }: {
  agent: AgentResponse
  onRequestTransition: () => void
  onIssueCredential: () => void
  onRevokeCredential: () => void
  onScanCompliance: () => void
  scanning: boolean
  lastScanTimestamp: string | null
}) {
  const canTransition = (VALID_NEXT_STATES[agent.lifecycle_state] ?? []).length > 0
  return (
    <div className="card" style={{ marginBottom: 24, padding: '20px 24px' }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 16, flexWrap: 'wrap' }}>
        <div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 8, flexWrap: 'wrap' }}>
            <h1 style={{ fontSize: 20, fontWeight: 700, margin: 0 }}>{agent.name || 'Unnamed agent'}</h1>
            {agent.type && <StatusBadge status={agent.type.toLowerCase()} />}
            <StatusBadge status={agent.lifecycle_state} variant="lifecycle" />
            {agent.eu_ai_act_risk_class && (
              <StatusBadge status={agent.eu_ai_act_risk_class} variant="risk" />
            )}
          </div>
          <div style={{ display: 'flex', gap: 20, fontSize: 12, color: 'var(--muted)', flexWrap: 'wrap' }}>
            <span>
              Owner:{' '}
              <span style={{ color: agent.owner ? 'var(--text)' : colors.amber, fontWeight: agent.owner ? 400 : 600 }}>
                {agent.owner ?? 'Unassigned'}
              </span>
            </span>
            {agent.last_transition_at && (
              <span>
                Since{' '}
                <span style={{ color: 'var(--text)' }}>{fmtDate(agent.last_transition_at)}</span>
                {agent.last_transition_by && (
                  <> · Changed by <span style={{ color: 'var(--text)' }}>{agent.last_transition_by}</span></>
                )}
              </span>
            )}
            <span
              title={navigator.clipboard ? `Agent ID: ${agent.id} (click to copy)` : `Agent ID: ${agent.id}`}
              style={{ fontFamily: 'monospace', fontSize: 11, cursor: navigator.clipboard ? 'pointer' : 'default' }}
              onClick={() => {
                navigator.clipboard?.writeText(agent.id).catch(() => {
                  // clipboard permission denied or unavailable — ID remains visible/selectable as a fallback
                })
              }}
            >
              ID: {agent.id}
            </span>
          </div>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 14 }}>
          {agent.compliance_summary.posture_score !== null && (
            <div style={{ textAlign: 'right' }}>
              <div style={{
                fontSize: 28, fontWeight: 800,
                color: agent.compliance_summary.posture_score >= 80 ? colors.tealLoom
                  : agent.compliance_summary.posture_score >= 50 ? colors.amber
                  : colors.red,
                lineHeight: 1,
              }}>
                {agent.compliance_summary.posture_score}%
              </div>
              <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4 }}>posture</div>
            </div>
          )}
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 8 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              {lastScanTimestamp && (
                <span style={{ fontSize: 11, color: 'var(--muted)' }}>
                  Last scanned: {fmtRelativeMinutes(lastScanTimestamp)}
                </span>
              )}
              <button
                className="btn btn-secondary"
                style={{ fontSize: 12, padding: '6px 14px', whiteSpace: 'nowrap' }}
                disabled={scanning}
                onClick={onScanCompliance}
              >
                {scanning ? 'Scanning...' : 'Scan Compliance'}
              </button>
            </div>
            <span style={{ fontSize: 10, color: 'var(--muted)', opacity: 0.7 }}>
              Auto-scan every 15 minutes
            </span>
            {(agent.lifecycle_state === 'enrolled' || agent.lifecycle_state === 'active') && (
              <CredentialActionsMenu onIssue={onIssueCredential} onRevoke={onRevokeCredential} />
            )}
            {canTransition ? (
              <button
                className="btn btn-primary"
                style={{ fontSize: 12, padding: '6px 14px', whiteSpace: 'nowrap' }}
                onClick={onRequestTransition}
              >
                Request Transition
              </button>
            ) : (
              <span
                title="Revoked is a terminal state — no further transitions are possible."
                style={{ fontSize: 11, color: 'var(--muted)' }}
              >
                No transitions available
              </span>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}

// ─── Main Page ────────────────────────────────────────────────────────────────

export default function AgentDetailPage() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const { getAccessTokenSilently } = useAuth0()

  const [agent, setAgent] = useState<AgentResponse | null>(null)
  const [auditEvents, setAuditEvents] = useState<AuditEventResponse[]>([])
  const [violations, setViolations] = useState<ViolationResponse[]>([])
  const [complianceResults, setComplianceResults] = useState<AgentComplianceResultResponse[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [showTransition, setShowTransition] = useState(false)
  const [showIssueCredential, setShowIssueCredential] = useState(false)
  const [showRevokeCredential, setShowRevokeCredential] = useState(false)
  const [scanning, setScanning] = useState(false)
  const [lastScanTimestamp, setLastScanTimestamp] = useState<string | null>(null)

  const load = useCallback(async () => {
    if (!id) return
    setLoading(true)
    try {
      const token = await getAccessTokenSilently()
      const [agentData, auditData, violationsData, postureData] = await Promise.allSettled([
        api.agents.get(token, id),
        api.audit(token, { agent: id, limit: 50 }),
        api.agents.violations(token, id),
        api.compliance.posture(token),
      ])

      if (agentData.status === 'fulfilled') setAgent(agentData.value)
      if (auditData.status === 'fulfilled') setAuditEvents(auditData.value.events)
      if (violationsData.status === 'fulfilled') setViolations(violationsData.value.violations)
      if (postureData.status === 'fulfilled') {
        const match = postureData.value.agents.find(a => a.agent_id === id)
        setComplianceResults(match?.results ?? [])
      }

      if (agentData.status === 'rejected') {
        throw new Error((agentData.reason as Error).message ?? 'Failed to load agent')
      }
      setError(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load agent details')
    } finally {
      setLoading(false)
    }
  }, [id, getAccessTokenSilently])

  useEffect(() => {
    load()
  }, [load])

  async function handleAcknowledge(violationId: string) {
    const token = await getAccessTokenSilently()
    await api.agents.acknowledge(token, violationId)
    setViolations(prev => prev.map(v => v.id === violationId ? { ...v, status: 'acknowledged' } : v))
  }

  async function handleReassess(controlId: string) {
    if (!id) return
    const token = await getAccessTokenSilently()
    await api.agents.reassess(token, id, controlId)
    setComplianceResults(prev =>
      prev.map(r => r.control_id === controlId ? { ...r, status: 'reassessment_requested' } : r)
    )
  }

  const handleComplianceScan = useCallback(async () => {
    setScanning(true)
    try {
      const token = await getAccessTokenSilently()
      const result = await api.compliancePolicy.scan(token, {
        namespace: 'default',
        policyVersion: 'v2.0',
        frameworks: ['eu-ai-act', 'nist-800-53'],
      })
      setLastScanTimestamp(result.summary.scanTimestamp)
      await load()
    } catch (e) {
      console.error('Compliance scan failed:', e)
    } finally {
      setScanning(false)
    }
  }, [getAccessTokenSilently, load])

  // Merge audit events + violations into a single sorted timeline
  const timelineItems: TimelineItem[] = useMemo(() => {
    const items: TimelineItem[] = [
      ...auditEvents.map(e => ({ kind: 'audit' as const, ts: e.timestamp, event: e })),
      ...violations.map(v => ({ kind: 'violation' as const, ts: v.created_at ?? '', violation: v })),
    ]
    return items.sort((a, b) => new Date(b.ts).getTime() - new Date(a.ts).getTime())
  }, [auditEvents, violations])

  const openViolations = violations.filter(v => v.status === 'new' || v.status === 'acknowledged').length
  const lastAssessed = complianceResults.reduce<string | null>((latest, r) => {
    if (!r.assessed_at) return latest
    if (!latest) return r.assessed_at
    return r.assessed_at > latest ? r.assessed_at : latest
  }, null)

  if (loading) {
    return <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 64 }}>Loading…</div>
  }

  if (error || !agent) {
    return (
      <div>
        <button onClick={() => navigate('/agents')} className="btn btn-secondary" style={{ fontSize: 12, padding: '5px 12px', marginBottom: 20 }}>
          ← Back to Agents
        </button>
        <ErrorState message={error ?? 'Agent not found'} onRetry={load} />
      </div>
    )
  }

  return (
    <div style={{ maxWidth: 960 }}>
      {/* Back nav */}
      <button
        onClick={() => navigate('/agents')}
        style={{
          background: 'none', border: 'none', color: 'var(--muted)', fontSize: 13,
          cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 6,
          marginBottom: 16, padding: 0, fontFamily: 'inherit',
        }}
        onMouseEnter={e => (e.currentTarget.style.color = 'var(--text)')}
        onMouseLeave={e => (e.currentTarget.style.color = 'var(--muted)')}
      >
        ← Agents
      </button>

      {showTransition && (
        <RequestTransitionModal agent={agent} onClose={() => setShowTransition(false)} />
      )}

      {showIssueCredential && (
        <IssueCredentialModal agent={agent} onClose={() => setShowIssueCredential(false)} />
      )}

      {showRevokeCredential && (
        <RevokeCredentialModal
          agent={agent}
          onClose={(revoked) => {
            setShowRevokeCredential(false)
            if (revoked) load()
          }}
        />
      )}

      {/* 1. Header */}
      <AgentHeader
        agent={agent}
        onRequestTransition={() => setShowTransition(true)}
        onIssueCredential={() => setShowIssueCredential(true)}
        onRevokeCredential={() => setShowRevokeCredential(true)}
        onScanCompliance={handleComplianceScan}
        scanning={scanning}
        lastScanTimestamp={lastScanTimestamp}
      />

      {/* 2. Activity Timeline */}
      <Timeline
        items={timelineItems}
        onAcknowledge={handleAcknowledge}
      />

      {/* 3. Compliance Summary */}
      <ComplianceSummarySection
        posture={agent.compliance_summary.posture_score}
        openViolations={openViolations}
        lastAssessed={lastAssessed}
      />

      {/* 4. Framework Controls */}
      <FrameworkControlsSection
        results={complianceResults}
        onReassess={handleReassess}
      />
    </div>
  )
}
