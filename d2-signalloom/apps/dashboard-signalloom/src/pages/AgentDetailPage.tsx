import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { useParams, useNavigate, useSearchParams } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { claimDiscoveredAgent, type AgentClaimRequest } from '../api/agentClaim'
import type {
  AgentResponse,
  AuditEventResponse,
  ViolationResponse,
  AgentComplianceResultResponse,
  TelemetryObservationModel,
} from '../types/api'
import { colors } from '../styles/tokens'
import StatusBadge from '../components/StatusBadge'
import CredentialStateNotice from '../components/CredentialStateNotice'
import EmptyState from '../components/EmptyState'
import LoadingState from '../components/LoadingState'
import CredentialActionsMenu from '../components/CredentialActionsMenu'
import AgentOverviewTab from '../components/AgentOverviewTab'
import AgentIdentityTab from '../components/AgentIdentityTab'
import AgentAccessTab from '../components/AgentAccessTab'
import AgentAssessmentsTab from '../components/AgentAssessmentsTab'
import AgentActivityTab from '../components/AgentActivityTab'

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

function buildDossierClaimRequest(agent: AgentResponse): AgentClaimRequest {
  const podName = agent.runtime?.pod_name || agent.name
  const namespace = agent.runtime?.namespace || agent.namespace || 'fe-signalloom-agents'
  const serviceAccount = agent.runtime?.service_account || agent.service_account || podName

  return {
    pod_name: podName,
    namespace,
    spiffe_id: agent.identity?.spiffe_id || `spiffe://cluster.local/ns/${namespace}/sa/${serviceAccount}`,
    harness: agent.runtime?.framework || agent.framework || agent.type || 'unknown',
    model: agent.runtime?.model || agent.model_name || 'unknown',
    declared_tools: [],
    token_budget_limit: 250000,
    agent_id: agent.id,
  }
}

interface ClaimNotification {
  kind: 'success' | 'error'
  message: string
}

// ─── Timeline ────────────────────────────────────────────────────────────────

type TimelineItem =
  | { kind: 'audit'; ts: string; event: AuditEventResponse }
  | { kind: 'violation'; ts: string; violation: ViolationResponse }

const EVENT_TYPE_COLORS: Record<string, string> = {
  enrollment:                         colors.cyanLoom,
  state_transition:                   colors.irisViolet,
  violation_detected:                 colors.red,
  compliance_check:                   'var(--cyan)',
  token_issued:                       colors.tealLoom,
  token_refused:                      colors.amber,
  tenant_created:                     colors.cyanLoom,
  user_provisioned:                   'var(--teal)',
  directory_connected:                'var(--violet)',
  discovery_enroll_requested:         colors.amber,
  // Swarm lifecycle events
  'swarm.agent.claimed':              colors.cyanLoom,
  'swarm.agent.released':             colors.muted,
  'swarm.credential.fetched':         colors.tealLoom,
  'swarm.credential.rotated':         colors.tealLoom,
  'swarm.nono.sandbox_entered':       colors.irisViolet,
  'swarm.nono.violation_blocked':     colors.red,
  'swarm.sentinel.stun_triggered':    colors.amber,
  'swarm.sentinel.stun_released':     colors.cyanLoom,
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
  'agent.created', 'agent.transitioned', 'agent.stunned',
  'agent.credential_issued', 'agent.credential_revoked',
  'violation.acknowledged', 'compliance.reassess_requested',
  // Legacy vocabulary from migration 007, retained for historical rows.
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

// ─── Lifecycle transitions ───────────────────────────────────────────────────

const VALID_NEXT_STATES: Record<string, { state: string; label: string }[]> = {
  registered: [
    { state: 'enrolled', label: 'Enrolled (enroll)' },
    { state: 'active', label: 'Active (activate)' },
  ],
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
  decommissioned: [],
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
                  <option value="low">Low: when convenient</option>
                  <option value="normal">Normal: soon</option>
                  <option value="high">High: impacting operations</option>
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

function IssueCredentialModal({ agent, onClose }: { agent: AgentResponse; onClose: () => void }) {
  const { getAccessTokenSilently } = useAuth0()
  const [phase, setPhase] = useState<'confirm' | 'issuing' | 'done'>('confirm')
  const [tokenNote, setTokenNote] = useState('')
  const [issuedToken, setIssuedToken] = useState<string | null>(null)
  const [expiresAt, setExpiresAt] = useState<string | null>(null)
  const [isSimulated, setIsSimulated] = useState<boolean>(false)
  const [error, setError] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)

  async function handleIssue() {
    setPhase('issuing')
    setError(null)
    try {
      const token = await getAccessTokenSilently()
      const res = await api.agents.issueCredential(token, agent.id, {
        token_note: tokenNote.trim() || undefined,
      })
      setIssuedToken(res.identity_token)
      setExpiresAt(res.token_expires_at)
      setIsSimulated(res.simulated ?? false)
      setPhase('done')
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Credential issuance failed')
      setPhase('confirm')
    }
  }

  function handleCopy() {
    if (!issuedToken) return
    navigator.clipboard?.writeText(issuedToken)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <div
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.53)', backdropFilter: 'blur(6px)', zIndex: 1000,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}
      onClick={e => e.target === e.currentTarget && phase !== 'issuing' && onClose()}
    >
      <div className="card slide-up" style={{ width: 480, maxWidth: '95vw', padding: 24, position: 'relative' }}>
        {phase === 'done' ? (
          <div>
            <h3 style={{ marginBottom: 6 }}>Credential Issued</h3>
            <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 14 }}>
              Copy this token now. It will not be shown again.
            </p>

            {isSimulated && (
              <div style={{
                background: 'rgba(217, 119, 6, 0.1)', border: '1px solid rgba(217, 119, 6, 0.3)',
                borderRadius: 6, padding: '10px 14px', marginBottom: 14, fontSize: 12, color: colors.amber,
              }}>
                <strong>Simulated demo credential:</strong> this token was generated for interface demonstration;
                it is not a real SPIFFE SVID and cannot authenticate any live workload.
              </div>
            )}

            <div style={{
              background: 'var(--surface2)', borderRadius: 6, padding: '12px 14px',
              fontFamily: 'monospace', fontSize: 11, wordBreak: 'break-all',
              border: '1px solid var(--border)', marginBottom: 12, maxHeight: 120, overflowY: 'auto',
            }}>
              {issuedToken}
            </div>

            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
              <span style={{ fontSize: 11, color: 'var(--muted)' }}>
                {expiresAt ? `Expires: ${fmtDate(expiresAt)}` : 'No expiration set'}
              </span>
              <button className="btn btn-secondary" onClick={handleCopy} style={{ fontSize: 11 }}>
                {copied ? 'Copied!' : 'Copy token'}
              </button>
            </div>

            <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
              <button className="btn btn-primary" onClick={onClose}>Done</button>
            </div>
          </div>
        ) : (
          <div>
            <h3 style={{ marginBottom: 6 }}>Issue Agent Credential</h3>
            <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 16, lineHeight: 1.5 }}>
              Mint an identity credential for <strong>{agent.name}</strong>.
            </p>

            <div style={{ marginBottom: 14 }}>
              <label htmlFor="token-note" style={{ display: 'block', fontSize: 12, marginBottom: 4 }}>
                Token note (optional)
              </label>
              <input
                id="token-note"
                type="text"
                value={tokenNote}
                onChange={e => setTokenNote(e.target.value)}
                placeholder="e.g. production deployment token"
                style={{ width: '100%' }}
                disabled={phase === 'issuing'}
              />
            </div>

            {error && <p style={{ color: 'var(--error)', fontSize: 12, marginBottom: 12 }}>{error}</p>}

            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
              <button className="btn btn-secondary" onClick={onClose} disabled={phase === 'issuing'}>Cancel</button>
              <button className="btn btn-primary" onClick={handleIssue} disabled={phase === 'issuing'}>
                {phase === 'issuing' ? 'Issuing…' : 'Issue Credential'}
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

// ─── Revoke Credential Modal ──────────────────────────────────────────────────

function RevokeCredentialModal({ agent, onClose }: { agent: AgentResponse; onClose: (revoked: boolean) => void }) {
  const { getAccessTokenSilently } = useAuth0()
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState(false)
  const [tokensRevoked, setTokensRevoked] = useState(0)
  const [isSimulated, setIsSimulated] = useState(false)

  async function handleRevoke() {
    setSubmitting(true)
    setError(null)
    try {
      const token = await getAccessTokenSilently()
      const res = await api.agents.revokeCredential(token, agent.id)
      setTokensRevoked(res.tokens_revoked)
      setIsSimulated(res.simulated ?? false)
      setDone(true)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Revocation failed')
      setSubmitting(false)
    }
  }

  return (
    <div
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.53)', backdropFilter: 'blur(6px)', zIndex: 1000,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}
      onClick={e => e.target === e.currentTarget && !submitting && onClose(done)}
    >
      <div className="card slide-up" style={{ width: 440, maxWidth: '95vw', padding: 24, position: 'relative' }}>
        {done ? (
          <div style={{ textAlign: 'center', padding: '12px 0' }}>
            <div style={{ fontSize: 44, marginBottom: 14 }}>🔒</div>
            <p style={{ fontWeight: 600, fontSize: 15, marginBottom: 6 }}>Credentials revoked</p>
            <p style={{ color: 'var(--muted)', fontSize: 13, marginBottom: 14 }}>
              {tokensRevoked} credential{tokensRevoked !== 1 ? 's' : ''} for <strong>{agent.name}</strong> {tokensRevoked === 1 ? 'has' : 'have'} been revoked.
            </p>
            {isSimulated && (
              <div style={{
                background: 'rgba(217, 119, 6, 0.1)', border: '1px solid rgba(217, 119, 6, 0.3)',
                borderRadius: 6, padding: '10px 14px', marginBottom: 16, fontSize: 12, color: colors.amber, textAlign: 'left',
              }}>
                <strong>Simulated demo revoke:</strong> this was recorded in the demo log; it does not revoke any live credentials outside runtime demo mode.
              </div>
            )}
            <button className="btn btn-primary" onClick={() => onClose(true)}>Close</button>
          </div>
        ) : (
          <div>
            <h3 style={{ marginBottom: 6, color: colors.red }}>Revoke All Credentials</h3>
            <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 16, lineHeight: 1.5 }}>
              This will immediately revoke all active identity credentials for <strong>{agent.name}</strong>.
            </p>
            {error && <p style={{ color: 'var(--error)', fontSize: 12, marginBottom: 12 }}>{error}</p>}
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
              <button className="btn btn-secondary" onClick={() => onClose(false)} disabled={submitting}>Cancel</button>
              <button className="btn btn-danger" onClick={handleRevoke} disabled={submitting}>
                {submitting ? 'Revoking…' : 'Revoke All Credentials'}
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

// ─── Header Component ─────────────────────────────────────────────────────────

function DossierHeader({
  agent,
  onRequestTransition,
  onIssueCredential,
  onRevokeCredential,
  onScanCompliance,
  scanning,
  lastScanTimestamp,
}: {
  agent: AgentResponse
  onRequestTransition: () => void
  onIssueCredential: () => void
  onRevokeCredential: () => void
  onScanCompliance: () => void
  scanning: boolean
  lastScanTimestamp: string | null
}) {
  const [copiedId, setCopiedId] = useState(false)
  const canTransition = (VALID_NEXT_STATES[agent.lifecycle_state] ?? []).length > 0
  const recordClass = agent.record_class || (agent.is_registry_linked === false ? 'discovered' : 'registered')
  const recordClassLabel = recordClass.charAt(0).toUpperCase() + recordClass.slice(1)

  function handleCopyId() {
    navigator.clipboard?.writeText(agent.id).catch(() => {})
    setCopiedId(true)
    setTimeout(() => setCopiedId(false), 2000)
  }

  return (
    <div className="card" style={{ marginBottom: 20, padding: '20px 24px' }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 16, flexWrap: 'wrap' }}>
        <div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8, flexWrap: 'wrap' }}>
            <h1 data-testid="dossier-agent-name" style={{ fontSize: 22, fontWeight: 700, margin: 0 }}>
              {agent.name || 'Unnamed agent'}
            </h1>
            <span
              data-testid="dossier-record-class"
              className="tag"
              style={{
                fontSize: 10,
                padding: '2px 8px',
                background: recordClass === 'discovered'
                  ? 'rgba(59, 130, 246, 0.15)'
                  : recordClass === 'resolved'
                  ? 'rgba(139, 92, 246, 0.15)'
                  : recordClass === 'fixture'
                  ? 'rgba(156, 163, 175, 0.15)'
                  : 'rgba(16, 185, 129, 0.15)',
                color: recordClass === 'discovered'
                  ? 'var(--cyan)'
                  : recordClass === 'resolved'
                  ? 'var(--violet)'
                  : recordClass === 'fixture'
                  ? 'var(--muted)'
                  : 'var(--teal)',
              }}
            >
              {recordClassLabel}
            </span>
            <StatusBadge status={agent.lifecycle_state} variant="lifecycle" testId="dossier-lifecycle-badge" />
            {agent.eu_ai_act_risk_class && (
              <span data-testid="dossier-risk-class">
                <StatusBadge status={agent.eu_ai_act_risk_class} variant="risk" />
              </span>
            )}
            {agent.type && (
              <span className="tag" style={{ fontSize: 10, padding: '2px 8px', background: 'var(--surface2)', color: 'var(--muted)' }}>
                {agent.type}
              </span>
            )}
          </div>
          <div style={{ display: 'flex', gap: 16, fontSize: 12, color: 'var(--muted)', flexWrap: 'wrap', alignItems: 'center' }}>
            <span>
              Owner:{' '}
              <span style={{ color: agent.owner ? 'var(--text)' : colors.amber, fontWeight: agent.owner ? 400 : 600 }}>
                {agent.owner ?? (recordClass === 'discovered' || agent.is_registry_linked === false ? 'Registry not linked' : 'Unassigned')}
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
              data-testid="dossier-agent-id"
              title={`Agent ID: ${agent.id}`}
              style={{ fontFamily: 'monospace', fontSize: 11 }}
            >
              ID: {agent.id}
            </span>
            <button
              data-testid="dossier-copy-id"
              type="button"
              className="btn btn-secondary"
              style={{ fontSize: 10, padding: '2px 8px' }}
              onClick={handleCopyId}
            >
              {copiedId ? 'Copied!' : 'Copy ID'}
            </button>
          </div>
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 10 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            {lastScanTimestamp && (
              <span style={{ fontSize: 11, color: 'var(--muted)' }}>
                Last scanned: {fmtRelativeMinutes(lastScanTimestamp)}
              </span>
            )}
            <button
              data-testid="dossier-scan-compliance"
              className="btn btn-secondary"
              style={{ fontSize: 12, padding: '6px 14px', whiteSpace: 'nowrap' }}
              disabled={scanning}
              onClick={onScanCompliance}
            >
              {scanning ? 'Scanning...' : 'Scan Compliance'}
            </button>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            {(agent.lifecycle_state === 'enrolled' || agent.lifecycle_state === 'active') && (
              <CredentialActionsMenu onIssue={onIssueCredential} onRevoke={onRevokeCredential} />
            )}
            {canTransition ? (
              <button
                data-testid="dossier-request-transition"
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

// ─── Dossier Tab Bar ─────────────────────────────────────────────────────────

export type DossierTabId = 'overview' | 'identity' | 'access' | 'assessments' | 'activity'

interface DossierTabConfig {
  id: DossierTabId
  label: string
  testId: string
}

const DOSSIER_TABS: DossierTabConfig[] = [
  { id: 'overview', label: 'Overview', testId: 'dossier-tab-overview' },
  { id: 'identity', label: 'Identity', testId: 'dossier-tab-identity' },
  { id: 'access', label: 'Access & Containment', testId: 'dossier-tab-access' },
  { id: 'assessments', label: 'Assessments & Controls', testId: 'dossier-tab-assessments' },
  { id: 'activity', label: 'Activity & Timeline', testId: 'dossier-tab-activity' },
]

// ─── Main Page ────────────────────────────────────────────────────────────────

export default function AgentDetailPage() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const { getAccessTokenSilently } = useAuth0()

  const [agent, setAgent] = useState<AgentResponse | null>(null)
  const [auditEvents, setAuditEvents] = useState<AuditEventResponse[]>([])
  const [violations, setViolations] = useState<ViolationResponse[]>([])
  const [complianceResults, setComplianceResults] = useState<AgentComplianceResultResponse[]>([])
  const [telemetryObservations, setTelemetryObservations] = useState<TelemetryObservationModel[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [showTransition, setShowTransition] = useState(false)
  const [showIssueCredential, setShowIssueCredential] = useState(false)
  const [showRevokeCredential, setShowRevokeCredential] = useState(false)
  const [scanning, setScanning] = useState(false)
  const [lastScanTimestamp, setLastScanTimestamp] = useState<string | null>(null)
  const [claiming, setClaiming] = useState(false)
  const [claimError, setClaimError] = useState<string | null>(null)
  const [claimNotification, setClaimNotification] = useState<ClaimNotification | null>(null)
  const [claimRefreshId, setClaimRefreshId] = useState<string | null>(null)
  const claimInFlightRef = useRef(false)
  const claimGenerationRef = useRef(0)
  const skipNextLoadIdRef = useRef<string | null>(null)
  const preserveNextClaimStateRef = useRef(false)
  const searchParamsRef = useRef(searchParams)
  searchParamsRef.current = searchParams

  // Tab State
  const tabParam = (searchParams.get('tab') as DossierTabId) || 'overview'
  const activeTab: DossierTabId = ['overview', 'identity', 'access', 'assessments', 'activity'].includes(tabParam)
    ? tabParam
    : 'overview'

  const handleSelectTab = useCallback((tabId: DossierTabId) => {
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      next.set('tab', tabId)
      return next
    })
  }, [setSearchParams])

  const load = useCallback(async () => {
    if (!id) return
    setLoading(true)
    try {
      const token = await getAccessTokenSilently()
      const [agentData, auditData, violationsData, postureData, telemetryData] = await Promise.allSettled([
        api.agents.get(token, id),
        api.audit(token, { agent: id, limit: 50 }),
        api.agents.violations(token, id),
        api.compliance.posture(token),
        typeof api.agents.telemetry === 'function'
          ? api.agents.telemetry(token, id)
          : Promise.resolve({ observations: [] }),
      ])

      if (agentData.status === 'fulfilled') setAgent(agentData.value)
      if (auditData.status === 'fulfilled') setAuditEvents(auditData.value.events)
      if (violationsData.status === 'fulfilled') setViolations(violationsData.value.violations)
      if (postureData.status === 'fulfilled') {
        const match = postureData.value?.agents?.find(a => a.agent_id === id)
        setComplianceResults(match?.results ?? [])
      }
      if (telemetryData.status === 'fulfilled') {
        setTelemetryObservations(telemetryData.value.observations || [])
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
    if (skipNextLoadIdRef.current === id) {
      skipNextLoadIdRef.current = null
      preserveNextClaimStateRef.current = true
      return
    }
    load()
  }, [id, load])

  useEffect(() => {
    if (preserveNextClaimStateRef.current) {
      preserveNextClaimStateRef.current = false
      return
    }
    claimGenerationRef.current += 1
    claimInFlightRef.current = false
    setClaiming(false)
    setClaimError(null)
    setClaimNotification(null)
    setClaimRefreshId(null)
  }, [id])

  async function handleAcknowledge(violationId: string) {
    const token = await getAccessTokenSilently()
    await api.agents.acknowledge(token, violationId)
    setViolations(prev => prev.map(v => v.id === violationId ? { ...v, status: 'acknowledged' } : v))
  }

  async function handleReassess(controlId: string) {
    if (!agent) return
    const token = await getAccessTokenSilently()
    await api.agents.reassess(token, agent.id, controlId)
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

  const refreshClaimedDossier = useCallback(async (
    token: string,
    canonicalAgentId: string,
    generation: number,
    agentName: string,
  ) => {
    const refreshedAgent = await api.agents.get(token, canonicalAgentId)
    if (generation !== claimGenerationRef.current) return
    if (refreshedAgent.is_registry_linked !== true) {
      throw new Error('Canonical dossier is not linked yet. Retry the governance refresh.')
    }

    const [auditData, violationsData, postureData, telemetryData] = await Promise.allSettled([
      api.audit(token, { agent: refreshedAgent.id, limit: 50 }),
      api.agents.violations(token, refreshedAgent.id),
      api.compliance.posture(token),
      typeof api.agents.telemetry === 'function'
        ? api.agents.telemetry(token, refreshedAgent.id)
        : Promise.resolve({ observations: [] }),
    ])
    if (generation !== claimGenerationRef.current) return

    setAgent(refreshedAgent)
    setAuditEvents(auditData.status === 'fulfilled' ? auditData.value.events : [])
    setViolations(violationsData.status === 'fulfilled' ? violationsData.value.violations : [])
    if (postureData.status === 'fulfilled') {
      const match = postureData.value?.agents?.find(item =>
        item.agent_id === canonicalAgentId || item.agent_id === refreshedAgent.id
      )
      setComplianceResults(match?.results ?? [])
    } else {
      // The canonical dossier already contains its compliance summary. A
      // supplementary posture-list failure must not repeat a successful claim.
      setComplianceResults([])
    }
    setTelemetryObservations(
      telemetryData.status === 'fulfilled' ? telemetryData.value.observations || [] : [],
    )
    setClaimRefreshId(null)
    setClaimError(null)
    setClaimNotification({
      kind: 'success',
      message: `${agentName} enrolled into governance successfully.`,
    })

    if (id !== refreshedAgent.id) {
      skipNextLoadIdRef.current = refreshedAgent.id
      const query = searchParamsRef.current.toString()
      navigate(
        `/agents/${encodeURIComponent(refreshedAgent.id)}${query ? `?${query}` : ''}`,
        { replace: true },
      )
    }
  }, [id, navigate])

  const handleClaim = useCallback(async () => {
    if (!agent || claimInFlightRef.current || agent.is_registry_linked !== false) return

    const generation = claimGenerationRef.current
    const agentName = agent.name
    claimInFlightRef.current = true
    setClaiming(true)
    setClaimError(null)
    setClaimNotification(null)

    try {
      const token = await getAccessTokenSilently()
      const result = await claimDiscoveredAgent(token, agent.id, buildDossierClaimRequest(agent))
      if (generation !== claimGenerationRef.current) return
      if (result.status !== 'granted') {
        throw new Error(`Claim was ${result.status}.`)
      }

      setClaimRefreshId(result.agent_id)
      try {
        await refreshClaimedDossier(token, result.agent_id, generation, agentName)
      } catch (error) {
        if (generation !== claimGenerationRef.current) return
        const detail = error instanceof Error ? error.message : 'Unknown refresh error'
        const message = `Claim succeeded, but refreshed governance evidence could not be loaded: ${detail}`
        setClaimError(message)
        setClaimNotification({ kind: 'error', message })
      }
    } catch (error) {
      if (generation !== claimGenerationRef.current) return
      const message = `Could not claim ${agentName}: ${error instanceof Error ? error.message : 'Unknown error'}`
      setClaimError(message)
      setClaimNotification({ kind: 'error', message })
    } finally {
      if (generation === claimGenerationRef.current) setClaiming(false)
      claimInFlightRef.current = false
    }
  }, [agent, getAccessTokenSilently, refreshClaimedDossier])

  const handleClaimRefresh = useCallback(async () => {
    if (!agent || !claimRefreshId || claimInFlightRef.current) return

    const generation = claimGenerationRef.current
    claimInFlightRef.current = true
    setClaiming(true)
    setClaimError(null)
    setClaimNotification(null)
    try {
      const token = await getAccessTokenSilently()
      await refreshClaimedDossier(token, claimRefreshId, generation, agent.name)
    } catch (error) {
      if (generation !== claimGenerationRef.current) return
      const detail = error instanceof Error ? error.message : 'Unknown refresh error'
      const message = `Claim succeeded, but refreshed governance evidence could not be loaded: ${detail}`
      setClaimError(message)
      setClaimNotification({ kind: 'error', message })
    } finally {
      if (generation === claimGenerationRef.current) setClaiming(false)
      claimInFlightRef.current = false
    }
  }, [agent, claimRefreshId, getAccessTokenSilently, refreshClaimedDossier])

  const claimAction = claimRefreshId ? handleClaimRefresh : handleClaim

  // Merge audit events + violations into a single sorted timeline (pure & side-effect free)
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
    return <LoadingState variant="block" status="loading" label="agent detail" testId="agent-detail-load-state" />
  }

  if (error || !agent) {
    return (
      <div>
        <button
          data-testid="dossier-back-btn"
          onClick={() => navigate('/agents')}
          className="btn btn-secondary"
          style={{ fontSize: 12, padding: '5px 12px', marginBottom: 20 }}
        >
          ← Back to Agents
        </button>
        <LoadingState
          variant="block"
          status="error"
          label="agent detail"
          error={error ?? 'Agent not found'}
          onRetry={load}
          testId="agent-detail-load-state"
        />
      </div>
    )
  }

  return (
    <div style={{ maxWidth: 1040, margin: '0 auto' }}>
      {claimNotification && (
        <div
          data-testid="dossier-claim-toast"
          role={claimNotification.kind === 'success' ? 'status' : 'alert'}
          aria-live={claimNotification.kind === 'success' ? 'polite' : 'assertive'}
          aria-atomic="true"
          className="card"
          style={{
            position: 'fixed',
            top: 20,
            right: 20,
            zIndex: 1200,
            maxWidth: 440,
            padding: '12px 14px',
            display: 'flex',
            alignItems: 'flex-start',
            gap: 12,
            borderColor: claimNotification.kind === 'success' ? 'var(--teal)' : 'var(--error)',
            color: claimNotification.kind === 'success' ? 'var(--teal)' : 'var(--error)',
          }}
        >
          <span>{claimNotification.message}</span>
          <button
            type="button"
            aria-label="Dismiss claim notification"
            onClick={() => setClaimNotification(null)}
            style={{ background: 'none', border: 0, color: 'inherit', cursor: 'pointer', padding: 0 }}
          >
            ×
          </button>
        </div>
      )}

      {/* ─── Back Nav ────────────────────────────────────────────────────────── */}
      <button
        data-testid="dossier-back-btn"
        onClick={() => navigate('/agents')}
        style={{
          background: 'none',
          border: 'none',
          color: 'var(--muted)',
          fontSize: 13,
          cursor: 'pointer',
          display: 'flex',
          alignItems: 'center',
          gap: 6,
          marginBottom: 16,
          padding: 0,
          fontFamily: 'inherit',
        }}
        onMouseEnter={e => (e.currentTarget.style.color = 'var(--text)')}
        onMouseLeave={e => (e.currentTarget.style.color = 'var(--muted)')}
      >
        ← Agents
      </button>

      {/* ─── Active Target Instance Banner ───────────────────────────────────── */}
      {(searchParams.get('instance') || searchParams.get('selector')) && (
        <div
          data-testid="active-target-instance-banner"
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '10px 16px',
            marginBottom: 16,
            borderRadius: 6,
            background: 'rgba(0, 210, 255, 0.08)',
            border: '1px solid var(--cyan)',
            color: 'var(--text)',
            fontSize: 13,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <span
              style={{
                display: 'inline-block',
                width: 8,
                height: 8,
                borderRadius: '50%',
                background: 'var(--cyan)',
                boxShadow: '0 0 8px var(--cyan)',
              }}
            />
            <div>
              <span
                style={{
                  color: 'var(--muted)',
                  fontSize: 11,
                  textTransform: 'uppercase',
                  letterSpacing: '0.06em',
                  fontWeight: 600,
                  display: 'block',
                  marginBottom: 2,
                }}
              >
                Target Runtime Instance
              </span>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <code
                  data-testid="target-instance-value"
                  style={{ color: 'var(--cyan)', fontWeight: 600, fontSize: 13 }}
                >
                  {searchParams.get('instance') || searchParams.get('selector')}
                </code>
                {agent.runtime?.pod_name && (
                  <span style={{ color: 'var(--muted)', fontSize: 12 }}>
                    (Pod: {agent.runtime.pod_name})
                  </span>
                )}
                {agent.runtime?.pod_uid && agent.runtime.pod_uid !== (searchParams.get('instance') || searchParams.get('selector')) && (
                  <span style={{ color: 'var(--muted)', fontSize: 12 }}>
                    UID: <code>{agent.runtime.pod_uid}</code>
                  </span>
                )}
              </div>
            </div>
          </div>
          <button
            type="button"
            data-testid="clear-target-instance-btn"
            onClick={() => {
              setSearchParams(prev => {
                const next = new URLSearchParams(prev)
                next.delete('instance')
                next.delete('selector')
                return next
              })
            }}
            className="btn btn-secondary"
            style={{ fontSize: 11, padding: '4px 10px' }}
          >
            Clear Target Filter
          </button>
        </div>
      )}

      {/* ─── Modals ──────────────────────────────────────────────────────────── */}
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

      {/* ─── Credential State Notice ─────────────────────────────────────────── */}
      <div style={{ marginBottom: 16 }}>
        <CredentialStateNotice
          credentialState={agent.credential_state}
          agentName={agent.name}
          variant="panel"
        />
      </div>

      {/* ─── Dossier Hero Header ─────────────────────────────────────────────── */}
      <DossierHeader
        agent={agent}
        onRequestTransition={() => setShowTransition(true)}
        onIssueCredential={() => setShowIssueCredential(true)}
        onRevokeCredential={() => setShowRevokeCredential(true)}
        onScanCompliance={handleComplianceScan}
        scanning={scanning}
        lastScanTimestamp={lastScanTimestamp}
      />

      {/* ─── Tab Navigation Bar ──────────────────────────────────────────────── */}
      <div
        role="tablist"
        aria-label="Agent Dossier Tabs"
        style={{
          display: 'flex',
          gap: 8,
          borderBottom: '1px solid var(--border)',
          marginBottom: 24,
          overflowX: 'auto',
        }}
      >
        {DOSSIER_TABS.map((tab) => {
          const isActive = activeTab === tab.id
          return (
            <button
              key={tab.id}
              role="tab"
              id={`dossier-tab-${tab.id}`}
              aria-selected={isActive}
              aria-controls={`dossier-tabpanel-${tab.id}`}
              data-testid={tab.testId}
              onClick={() => handleSelectTab(tab.id)}
              style={{
                background: 'none',
                border: 'none',
                borderBottom: isActive ? '2px solid var(--cyan)' : '2px solid transparent',
                padding: '10px 16px',
                fontSize: 13,
                fontWeight: isActive ? 600 : 400,
                color: isActive ? 'var(--text)' : 'var(--muted)',
                cursor: 'pointer',
                transition: 'color 0.15s, border-color 0.15s',
                whiteSpace: 'nowrap',
              }}
              onMouseEnter={e => {
                if (!isActive) e.currentTarget.style.color = 'var(--text)'
              }}
              onMouseLeave={e => {
                if (!isActive) e.currentTarget.style.color = 'var(--muted)'
              }}
            >
              {tab.label}
            </button>
          )
        })}
      </div>

      {/* ─── Tab Content Views ───────────────────────────────────────────────── */}
      {activeTab === 'overview' && (
        <AgentOverviewTab
          agent={agent}
          claiming={claiming}
          claimError={claimError}
          retryingClaimRefresh={claimRefreshId !== null}
          onClaim={claimAction}
        />
      )}

      {activeTab === 'identity' && (
        <AgentIdentityTab agent={agent} />
      )}

      {activeTab === 'access' && (
        <AgentAccessTab
          agent={agent}
          claiming={claiming}
          claimError={claimError}
          retryingClaimRefresh={claimRefreshId !== null}
          onClaim={claimAction}
        />
      )}

      {activeTab === 'assessments' && (
        <AgentAssessmentsTab
          agent={agent}
          complianceResults={complianceResults}
          openViolations={openViolations}
          onReassess={handleReassess}
          onScanCompliance={handleComplianceScan}
          isScanning={scanning}
          lastScanTimestamp={lastScanTimestamp || lastAssessed}
        />
      )}

      {activeTab === 'activity' && (
        <AgentActivityTab
          agent={agent}
          auditEvents={auditEvents}
          violations={violations}
          telemetryObservations={telemetryObservations}
          onAcknowledgeViolation={handleAcknowledge}
          onRefresh={load}
        />
      )}
    </div>
  )
}
