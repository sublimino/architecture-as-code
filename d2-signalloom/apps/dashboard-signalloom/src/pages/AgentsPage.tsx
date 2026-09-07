// Filter interaction adapted from Beautiful UI Filter Table (MIT); see
// THIRD_PARTY_NOTICES.md. Signal Loom owns data, tokens, and semantics.
import { useState, useEffect, useCallback, useMemo } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { LIVE_POLL_MS } from '../api/pollInterval'
import type { AgentResponse, AgentListMeta, SourceHealthMap } from '../types/api'
import StatusBadge from '../components/StatusBadge'
import SignalBadge from '../components/SignalBadge'
import CredentialStateNotice from '../components/CredentialStateNotice'
import EmptyState from '../components/EmptyState'
import LoadingState, { loadPhase } from '../components/LoadingState'
import HelpHint from '../components/HelpHint'
import AgentEvidenceDrawer from '../components/AgentEvidenceDrawer'
import { useSignalSummary } from '../hooks/useSignalSummary'

// Watched by the demo audience in a second window — see api/pollInterval.ts.
const POLL_MS = LIVE_POLL_MS

// ─── Register Modal ──────────────────────────────────────────────────────────

/** Prefill values for the registration form — used by Claim to pre-populate
 *  from a discovered NHI account. */
export interface AgentFormPrefill {
  name?: string
  type?: string
  description?: string
  owner?: string
  /** The NHI account ID being claimed — drives the enroll call on submit. */
  nhiAccountId?: string
}

function RegisterModal({ onClose, onCreated, prefill, mode = 'register' }: {
  onClose: () => void
  onCreated: () => void
  prefill?: AgentFormPrefill
  mode?: 'register' | 'claim'
}) {
  const { getAccessTokenSilently } = useAuth0()
  const [name, setName] = useState(prefill?.name ?? '')
  const [type, setType] = useState(prefill?.type ?? '')
  const [description, setDescription] = useState(prefill?.description ?? '')
  const [owner, setOwner] = useState(prefill?.owner ?? '')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    const trimmedName = name.trim()
    if (!trimmedName) {
      setError('Name cannot be empty or whitespace only.')
      return
    }
    setSubmitting(true)
    setError(null)
    try {
      const token = await getAccessTokenSilently()
      await api.agents.register(token, {
        name: trimmedName,
        type,
        description: description.trim() || null,
        owner: owner.trim() || null,
      })
      // If claiming a discovered account, also enroll it
      if (mode === 'claim' && prefill?.nhiAccountId) {
        await api.nhi.enrollAccount(token, prefill.nhiAccountId)
      }
      onCreated()
      onClose()
    } catch (err: unknown) {
      if (err && typeof err === 'object' && 'response' in err && (err as { response?: { status?: number } }).response?.status === 409) {
        setError("An agent with that name already exists.")
      } else {
        setError(err instanceof Error ? err.message : 'Registration failed.')
      }
      setSubmitting(false)
    }
  }

  const title = mode === 'claim' ? 'Claim Discovered Agent' : 'Register New Agent'
  const submitLabel = mode === 'claim'
    ? (submitting ? 'Claiming…' : 'Claim Agent')
    : (submitting ? 'Registering…' : 'Register Agent')

  return (
    <div style={{
      position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.53)', backdropFilter: 'blur(6px)', zIndex: 1000,
      display: 'flex', alignItems: 'center', justifyContent: 'center'
    }} onClick={e => e.target === e.currentTarget && onClose()}>
      <div className="card slide-up" style={{ width: 400, padding: 24, position: 'relative' }}>
        <h3 style={{ marginBottom: 16 }}>{title}</h3>
        {mode === 'claim' && (
          <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 14, lineHeight: 1.5 }}>
            This account was found during a discovery scan. Review and adjust the details below,
            then claim it to bring it under governance.
          </p>
        )}
        <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          <div>
            <label style={{ display: 'block', fontSize: 12, marginBottom: 4 }}>Name *</label>
            <input value={name} onChange={e => setName(e.target.value)} required maxLength={200} style={{ width: '100%' }} />
          </div>
          <div>
            <label style={{ display: 'block', fontSize: 12, marginBottom: 4 }}>Type *</label>
            <select value={type} onChange={e => setType(e.target.value)} required style={{ width: '100%' }}>
              <option value="">Select a type…</option>
              <option value="Signal Loom Built">Signal Loom Built</option>
              <option value="COTS">COTS</option>
              <option value="Custom">Custom</option>
            </select>
          </div>
          <div>
            <label style={{ display: 'block', fontSize: 12, marginBottom: 4 }}>Description</label>
            <textarea value={description} onChange={e => setDescription(e.target.value)} style={{ width: '100%' }} />
          </div>
          <div>
            <label style={{ display: 'block', fontSize: 12, marginBottom: 4 }}>Owner (email or name)</label>
            <input value={owner} onChange={e => setOwner(e.target.value)} style={{ width: '100%' }} />
          </div>
          {error && <p style={{ color: 'var(--error)', fontSize: 12 }}>{error}</p>}
          <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, marginTop: 12 }}>
            <button type="button" className="btn btn-secondary" onClick={onClose}>Cancel</button>
            <button type="submit" className="btn btn-primary" disabled={submitting || !name.trim() || !type}>
              {submitLabel}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

// ─── Edit Agent Modal ────────────────────────────────────────────────────────

function EditAgentModal({ agent, onClose, onSaved }: {
  agent: AgentResponse
  onClose: () => void
  onSaved: () => void
}) {
  const { getAccessTokenSilently } = useAuth0()
  const [description, setDescription] = useState('')
  const [owner, setOwner] = useState(agent.owner ?? '')
  const [tags, setTags] = useState('')
  const [policyVersion, setPolicyVersion] = useState('v2.0')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setSubmitting(true)
    setError(null)
    try {
      const token = await getAccessTokenSilently()
      await api.agents.update(token, agent.id, {
        description: description.trim() || null,
        owner: owner.trim() || null,
      })
      onSaved()
      onClose()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Update failed.')
      setSubmitting(false)
    }
  }

  return (
    <div style={{
      position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.53)', backdropFilter: 'blur(6px)', zIndex: 1000,
      display: 'flex', alignItems: 'center', justifyContent: 'center'
    }} onClick={e => e.target === e.currentTarget && onClose()}>
      <div className="card slide-up" style={{ width: 440, padding: 24, position: 'relative' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 16 }}>
          <div>
            <h3 style={{ margin: 0, fontSize: 16 }}>Edit Agent</h3>
            <span style={{ fontSize: 12, color: 'var(--muted)' }}>{agent.name}</span>
          </div>
          <span style={{ fontSize: 11, fontFamily: 'monospace', color: 'var(--muted)' }}>
            {agent.id.slice(0, 8)}…
          </span>
        </div>
        <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          <div>
            <label style={{ display: 'block', fontSize: 12, marginBottom: 4 }}>Owner</label>
            <input
              value={owner}
              onChange={e => setOwner(e.target.value)}
              placeholder="e.g. security-team@signal-loom.ai"
              style={{ width: '100%' }}
            />
          </div>
          <div>
            <label style={{ display: 'block', fontSize: 12, marginBottom: 4 }}>Description</label>
            <textarea
              value={description}
              onChange={e => setDescription(e.target.value)}
              placeholder="Update the agent description…"
              rows={3}
              style={{ width: '100%', resize: 'vertical' }}
            />
          </div>
          <div>
            <label style={{ display: 'block', fontSize: 12, marginBottom: 4 }}>Tags (comma separated)</label>
            <input
              value={tags}
              onChange={e => setTags(e.target.value)}
              placeholder="e.g. production, billing, eu-region"
              style={{ width: '100%' }}
            />
          </div>
          <div>
            <label style={{ display: 'block', fontSize: 12, marginBottom: 4 }}>Policy Version</label>
            <select value={policyVersion} onChange={e => setPolicyVersion(e.target.value)} style={{ width: '100%' }}>
              <option value="v2.0">v2.0 (current)</option>
              <option value="v1.0">v1.0 (legacy)</option>
            </select>
          </div>
          {error && <p style={{ color: 'var(--error)', fontSize: 12 }}>{error}</p>}
          <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, marginTop: 8 }}>
            <button type="button" className="btn btn-secondary" onClick={onClose}>Cancel</button>
            <button type="submit" className="btn btn-primary" disabled={submitting}>
              {submitting ? 'Saving…' : 'Save Changes'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

// ─── Helpers ────────────────────────────────────────────────────────────────

function fmtDate(iso: string | null) {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })
}

function fmtRelative(iso: string | null) {
  if (!iso) return '—'
  const diff = Date.now() - new Date(iso).getTime()
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
  return fmtDate(iso)
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
  return fmtRelative(iso)
}

// ─── Theme Colors ────────────────────────────────────────────────────────────

export const DONUT_COLORS = {
  active: 'var(--teal)',
  enrolled: 'var(--cyan)',
  suspended: 'var(--amber)',
  revoked: 'var(--error)',
  empty: 'var(--border-subtle)',
  centreLabel: 'var(--text)',
  caption: 'var(--muted)',
} as const

// ─── 4 StatCards (Matching Spec Section 3) ──────────────────────────────────

function AgentStatCards({
  agents,
  meta,
  sourceHealth,
  sourceHealthDetail,
}: {
  agents: AgentResponse[]
  meta?: AgentListMeta | null
  sourceHealth?: 'healthy' | 'degraded' | 'unavailable' | null
  sourceHealthDetail?: SourceHealthMap | null
}) {
  const total = agents.length

  // 1. Needs Attention
  const failingControlsCount = agents.reduce((sum, a) => sum + a.compliance_summary.failing, 0)
  const unconfirmedCount = agents.filter(a =>
    (a.lifecycle_state === 'suspended' || a.lifecycle_state === 'stunned' || a.credential_state?.status === 'revoked') &&
    !(a.kernel_telemetry?.cgroup_state === 'frozen' || a.kernel_telemetry?.traffic_control_state === 'drop')
  ).length
  const attentionCount = agents.filter(a =>
    a.compliance_summary.failing > 0 ||
    a.attention?.level === 'critical' ||
    a.attention?.level === 'warning' ||
    (a.lifecycle_state === 'suspended' || a.lifecycle_state === 'stunned' || a.credential_state?.status === 'revoked') ||
    (a.compliance_summary.posture_score !== null &&
      (a.compliance_summary.posture_score <= 1.0 ? a.compliance_summary.posture_score < 0.5 : a.compliance_summary.posture_score < 50))
  ).length

  // 2. Identity Coverage
  const registeredCount = meta?.registered_count ?? agents.filter(a => a.record_class === 'registered' || (!a.record_class && a.is_registry_linked !== false)).length
  const discoveredCount = meta?.discovered_count ?? agents.filter(a => a.record_class === 'discovered' || a.is_registry_linked === false).length
  const resolvedCount = meta?.resolved_count ?? agents.filter(a => a.record_class === 'resolved').length
  const resolvedPct = total > 0 ? Math.round(((registeredCount + resolvedCount) / total) * 100) : 0

  // 3. Observed Workloads
  const operationalCount = meta?.operational_count ?? total
  const namespaces = new Set(agents.map(a => a.runtime?.namespace || a.namespace || 'default'))
  const frameworks = new Set(agents.map(a => a.runtime?.framework || a.framework || a.type || 'Custom'))

  // 4. Evidence Coverage
  const k8sStatus = sourceHealthDetail?.k8s_discovery?.status ?? (sourceHealth === 'unavailable' ? 'unavailable' : 'healthy')
  const dbStatus = sourceHealthDetail?.postgres_registry?.status ?? (sourceHealth === 'unavailable' ? 'unavailable' : 'healthy')
  const cryptoStatus = sourceHealthDetail?.crypto_proofs?.status ?? (sourceHealth === 'unavailable' ? 'unavailable' : 'healthy')

  const effectiveSourceHealth = sourceHealth || 'healthy'
  const sourceHealthText = effectiveSourceHealth === 'unavailable' ? 'Unavailable' : (effectiveSourceHealth.charAt(0).toUpperCase() + effectiveSourceHealth.slice(1))
  const sourceHealthColor = effectiveSourceHealth === 'healthy' ? 'var(--teal)' : effectiveSourceHealth === 'degraded' ? 'var(--amber)' : 'var(--error)'

  return (
    <div style={{
      display: 'grid',
      gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))',
      gap: 14,
      marginBottom: 18,
    }}>
      {/* 1. Needs Attention */}
      <div className="card" data-testid="statcard-attention" style={{ padding: '16px 18px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
        <div>
          <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>
            Needs Attention
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
            <span style={{
              fontSize: 26,
              fontWeight: 700,
              lineHeight: 1,
              color: attentionCount > 0 ? 'var(--error)' : 'var(--teal)',
            }}>
              {attentionCount}
            </span>
            <span style={{ fontSize: 12, color: 'var(--muted)' }}>
              {attentionCount === 1 ? 'workload requiring review' : 'workloads requiring review'}
            </span>
          </div>
        </div>
        <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', fontSize: 11, color: 'var(--muted)' }}>
          {failingControlsCount > 0 ? `${failingControlsCount} failing control${failingControlsCount > 1 ? 's' : ''}` : 'Zero failing controls'}
          {unconfirmedCount > 0 ? ` · ${unconfirmedCount} unconfirmed containment` : ''}
        </div>
      </div>

      {/* 2. Identity Coverage */}
      <div className="card" data-testid="statcard-identity" style={{ padding: '16px 18px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
        <div>
          <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>
            Identity Coverage
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
            <span style={{ fontSize: 26, fontWeight: 700, lineHeight: 1, color: 'var(--cyan)' }}>
              {resolvedPct}%
            </span>
            <span style={{ fontSize: 12, color: 'var(--muted)' }}>governed resolution</span>
          </div>
        </div>
        <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', fontSize: 11, color: 'var(--muted)' }}>
          {registeredCount} registered · {discoveredCount} discovered{resolvedCount > 0 ? ` · ${resolvedCount} resolved` : ''}
        </div>
      </div>

      {/* 3. Observed Workloads */}
      <div className="card" data-testid="statcard-workloads" style={{ padding: '16px 18px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
        <div>
          <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>
            Observed Workloads
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
            <span style={{ fontSize: 26, fontWeight: 700, lineHeight: 1, color: 'var(--teal)' }}>
              {operationalCount}
            </span>
            <span style={{ fontSize: 12, color: 'var(--muted)' }}>active workloads</span>
          </div>
        </div>
        <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', fontSize: 11, color: 'var(--muted)' }}>
          {namespaces.size} namespace{namespaces.size !== 1 ? 's' : ''} · {frameworks.size} framework{frameworks.size !== 1 ? 's' : ''}
        </div>
      </div>

      {/* 4. Evidence Coverage */}
      <div className="card" data-testid="statcard-evidence" style={{ padding: '16px 18px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
        <div>
          <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>
            Evidence Coverage
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
            <span style={{
              fontSize: 26,
              fontWeight: 700,
              lineHeight: 1,
              color: sourceHealthColor,
            }}>
              {sourceHealthText}
            </span>
            <span style={{ fontSize: 12, color: 'var(--muted)' }}>source status</span>
          </div>
        </div>
        <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', fontSize: 11, color: 'var(--muted)' }}>
          K8s: {k8sStatus} · Registry: {dbStatus} · Proofs: {cryptoStatus}
        </div>
      </div>
    </div>
  )
}

// ─── Attention Required Panel ────────────────────────────────────────────────

interface AlertItem {
  id: string
  label: string
  count: number
  severity: 'warning' | 'critical'
  filterKey?: string
}

function AttentionPanel({ alerts, onAlert }: {
  alerts: AlertItem[]
  onAlert: (filterKey?: string) => void
}) {
  if (alerts.length === 0) return null
  return (
    <div style={{
      background: 'rgba(220,38,38,0.07)',
      border: '1px solid rgba(220,38,38,0.25)',
      borderRadius: 8,
      padding: '14px 18px',
      marginBottom: 20,
      display: 'flex',
      flexDirection: 'column',
      gap: 10,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 2 }}>
        <span style={{ fontSize: 13, fontWeight: 700, color: 'var(--error)' }}>Attention Required</span>
        <span style={{
          background: 'var(--error)', color: 'var(--on-accent)', borderRadius: 99,
          fontSize: 10, fontWeight: 700, padding: '1px 7px',
        }}>{alerts.length}</span>
      </div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
        {alerts.map((a) => (
          <button
            key={a.id}
            onClick={() => onAlert(a.filterKey)}
            style={{
              display: 'flex', alignItems: 'center', gap: 6,
              background: a.severity === 'critical'
                ? 'rgba(220,38,38,0.12)'
                : 'rgba(215,119,6,0.12)',
              border: `1px solid ${a.severity === 'critical' ? 'rgba(220,38,38,0.3)' : 'rgba(215,119,6,0.3)'}`,
              borderRadius: 6, padding: '5px 12px',
              color: a.severity === 'critical' ? 'var(--error)' : 'var(--amber)',
              fontSize: 12, fontWeight: 500, cursor: 'pointer',
              fontFamily: 'inherit', transition: 'opacity 0.15s',
            }}
          >
            <span style={{
              background: a.severity === 'critical' ? 'var(--error)' : 'var(--amber)',
              color: 'var(--on-accent)', borderRadius: 99, fontSize: 10,
              fontWeight: 700, padding: '0px 6px', minWidth: 20, textAlign: 'center',
            }}>{a.count}</span>
            {a.label}
          </button>
        ))}
      </div>
    </div>
  )
}

// ─── 7-Column Operational Inventory Table Row ────────────────────────────────

const LIFECYCLE_OPTIONS = ['all', 'registered', 'enrolled', 'active', 'suspended', 'revoked'] as const

const LIFECYCLE_LABELS: Record<string, string> = {
  all: 'All states',
  registered: 'Registered',
  enrolled: 'Enrolled',
  active: 'Active',
  suspended: 'Suspended',
  revoked: 'Revoked',
}

const LIFECYCLE_TOOLTIP: Record<string, string> = {
  registered: 'Created in the registry and not yet enrolled — no identity has been issued.',
  enrolled: 'Enrolled with an identity but not yet activated — cannot authenticate until transitioned to active.',
  active: 'Active and authorized to operate.',
  suspended: 'Temporarily suspended — reversible; credentials refused until reinstated.',
  revoked: 'Permanently revoked — terminal state; credentials refused.',
}

function AgentTableRow({ agent, shown, onSelect, onEdit }: {
  agent: AgentResponse
  shown: boolean
  onSelect: (agent: AgentResponse) => void
  onEdit: (agent: AgentResponse) => void
}) {
  const hasViolations = agent.compliance_summary.failing > 0
  const recordClass = agent.record_class || (agent.is_registry_linked === false ? 'discovered' : 'registered')
  const recordClassLabel = recordClass.charAt(0).toUpperCase() + recordClass.slice(1)

  // 1. Agent column
  const agentName = agent.name || 'Unnamed agent'
  const agentExecutionMode = agent.runtime?.execution_mode || agent.type || (agent.id ? `ID: ${agent.id.split('-')[0]}…` : '—')

  // 2. Runtime column
  const namespace = agent.runtime?.namespace || agent.namespace || 'default'
  const framework = agent.runtime?.framework || agent.framework || agent.type || 'Custom'
  const model = agent.runtime?.model || agent.model_name || (agent.runtime?.node ? `node: ${agent.runtime.node}` : null)

  // 3. Responsibility column (truthful language)
  const ownerName = agent.responsibility?.owner_name || agent.owner
  const team = agent.responsibility?.team

  // 4. Operational State column (with kernel telemetry)
  const isTelemetryFrozenOrDrop = agent.kernel_telemetry?.cgroup_state === 'frozen' || agent.kernel_telemetry?.traffic_control_state === 'drop'
  const isContainmentRequested = agent.lifecycle_state === 'suspended' || agent.lifecycle_state === 'stunned' || agent.credential_state?.status === 'revoked'

  // 5. Attention column (truthful language)
  const isNotAssessed = (agent.assessment_summary?.status === 'not_assessed') ||
    (agent.compliance_summary.total_controls === 0) ||
    (agent.compliance_summary.posture_score === null && agent.compliance_summary.passing === 0 && agent.compliance_summary.failing === 0)

  // 6. Identity & Evidence column
  const isSpiffeLinked = agent.identity?.spiffe_status === 'linked' || (!!agent.identity?.spiffe_id && agent.record_class !== 'discovered' && agent.is_registry_linked !== false)

  // 7. Last Observed column
  const observedTime = agent.timestamps?.last_observed_at || agent.last_transition_at || agent.created_at

  return (
    <tbody
      className="sl-filter-table-row"
      aria-hidden={!shown}
      style={{ opacity: shown ? 1 : 0, visibility: shown ? 'visible' : 'collapse' }}
    >
      <tr
        data-testid={`agent-row-${agent.id}`}
        tabIndex={0}
        role="button"
        aria-label={`View evidence for ${agentName}`}
        onClick={() => onSelect(agent)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault()
            onSelect(agent)
          }
        }}
        style={{ borderBottom: '1px solid var(--border)', cursor: 'pointer', transition: 'background 0.1s' }}
        onMouseEnter={(e) => (e.currentTarget.style.background = 'rgba(255,255,255,0.03)')}
        onMouseLeave={(e) => (e.currentTarget.style.background = 'transparent')}
      >
        {/* 1. Agent */}
        <td style={{ padding: '11px 16px', maxWidth: 220 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span style={{ fontWeight: 600, fontSize: 13, color: 'var(--text)' }}>{agentName}</span>
            {hasViolations && (
              <span
                title="Unacknowledged violation"
                style={{
                  display: 'inline-block', width: 7, height: 7,
                  background: 'var(--error)', borderRadius: '50%', flexShrink: 0,
                }}
              />
            )}
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 3 }}>
            <span
              className="tag"
              style={{
                fontSize: 10,
                padding: '1px 5px',
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
            <span
              title={`Agent ID: ${agent.id}`}
              style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace' }}
            >
              {agentExecutionMode}
            </span>
          </div>
        </td>

        {/* 2. Runtime */}
        <td style={{ padding: '11px 16px', fontSize: 12 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span style={{ fontWeight: 500, color: 'var(--text)' }}>{namespace}</span>
            <span style={{ color: 'var(--muted)' }}>/</span>
            <span style={{ color: 'var(--muted)' }}>{framework}</span>
          </div>
          {model && (
            <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
              {model}
            </div>
          )}
        </td>

        {/* 3. Responsibility */}
        <td style={{ padding: '11px 16px', fontSize: 12 }}>
          {ownerName ? (
            <div>
              <span style={{ color: 'var(--text)', fontWeight: 500 }}>{ownerName}</span>
              {team && <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 1 }}>{team}</div>}
            </div>
          ) : (
            <span style={{ color: 'var(--muted)' }}>
              {recordClass === 'discovered' || agent.is_registry_linked === false ? 'Registry not linked' : 'Unassigned'}
            </span>
          )}
        </td>

        {/* 4. Operational State */}
        <td style={{ padding: '11px 16px' }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            <span title={LIFECYCLE_TOOLTIP[agent.lifecycle_state] ?? undefined}>
              <StatusBadge status={agent.lifecycle_state} variant="lifecycle" />
            </span>
            <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
              {isTelemetryFrozenOrDrop ? (
                <>
                  <span
                    data-testid={`kernel-telemetry-cgroup-${agent.id}`}
                    className="tag"
                    title="cgroup.freeze: 1 (FROZEN) — Processes atomically suspended by Sentinel"
                    style={{ fontSize: 9, padding: '1px 5px', background: 'color-mix(in srgb, var(--error) 15%, transparent)', color: 'var(--error)', borderColor: 'color-mix(in srgb, var(--error) 30%, transparent)' }}
                  >
                    cgroup: FROZEN
                  </span>
                  <span
                    data-testid={`kernel-telemetry-tc-${agent.id}`}
                    className="tag"
                    title="TC matchall drop active — Network isolated by Sentinel"
                    style={{ fontSize: 9, padding: '1px 5px', background: 'color-mix(in srgb, var(--error) 15%, transparent)', color: 'var(--error)', borderColor: 'color-mix(in srgb, var(--error) 30%, transparent)' }}
                  >
                    TC: DROP
                  </span>
                </>
              ) : isContainmentRequested ? (
                <span
                  data-testid={`kernel-telemetry-unconfirmed-${agent.id}`}
                  className="tag"
                  title="Containment requested but kernel telemetry observation is unconfirmed"
                  style={{ fontSize: 9, padding: '1px 5px', background: 'color-mix(in srgb, var(--amber) 15%, transparent)', color: 'var(--amber)', borderColor: 'color-mix(in srgb, var(--amber) 30%, transparent)' }}
                >
                  Requested (Outcome unconfirmed)
                </span>
              ) : (
                <>
                  <span
                    data-testid={`kernel-telemetry-cgroup-${agent.id}`}
                    className="tag"
                    title="cgroup.freeze: 0 (THAWED)"
                    style={{ fontSize: 9, padding: '1px 5px', background: 'color-mix(in srgb, var(--teal) 15%, transparent)', color: 'var(--teal)', borderColor: 'color-mix(in srgb, var(--teal) 30%, transparent)' }}
                  >
                    cgroup: THAWED
                  </span>
                  <span
                    data-testid={`kernel-telemetry-tc-${agent.id}`}
                    className="tag"
                    title="TC drop: INACTIVE"
                    style={{ fontSize: 9, padding: '1px 5px', background: 'color-mix(in srgb, var(--teal) 15%, transparent)', color: 'var(--teal)', borderColor: 'color-mix(in srgb, var(--teal) 30%, transparent)' }}
                  >
                    TC: PASS
                  </span>
                </>
              )}
            </div>
          </div>
        </td>

        {/* 5. Attention */}
        <td style={{ padding: '11px 16px', fontSize: 12 }}>
          {isNotAssessed ? (
            <span className="tag" style={{ background: 'rgba(156, 163, 175, 0.15)', color: 'var(--muted)', fontSize: 11 }}>
              Not assessed
            </span>
          ) : agent.compliance_summary.failing > 0 ? (
            <div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <span className="tag" style={{ background: 'color-mix(in srgb, var(--error) 15%, transparent)', color: 'var(--error)', fontSize: 11 }}>
                  {agent.compliance_summary.failing} failing
                </span>
                {agent.compliance_summary.posture_score !== null && (
                  <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--error)' }}>
                    {Math.round(agent.compliance_summary.posture_score <= 1.0 ? agent.compliance_summary.posture_score * 100 : agent.compliance_summary.posture_score)}%
                  </span>
                )}
              </div>
              <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
                {agent.compliance_summary.passing}/{agent.compliance_summary.total_controls} passed
              </div>
            </div>
          ) : (
            <div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <span className="tag" style={{ background: 'color-mix(in srgb, var(--teal) 15%, transparent)', color: 'var(--teal)', fontSize: 11 }}>
                  {agent.compliance_summary.passing}/{agent.compliance_summary.total_controls} passing
                </span>
                {agent.compliance_summary.posture_score !== null && (
                  <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--teal)' }}>
                    {Math.round(agent.compliance_summary.posture_score <= 1.0 ? agent.compliance_summary.posture_score * 100 : agent.compliance_summary.posture_score)}%
                  </span>
                )}
              </div>
            </div>
          )}
        </td>

        {/* 6. Identity & Evidence */}
        <td style={{ padding: '11px 16px', fontSize: 12 }}>
          <div>
            {isSpiffeLinked ? (
              <span style={{ color: 'var(--teal)', fontWeight: 500 }}>SPIFFE linked</span>
            ) : recordClass === 'discovered' ? (
              <span style={{ color: 'var(--cyan)' }}>Observed workload</span>
            ) : (
              <span style={{ color: 'var(--muted)' }}>Identity unlinked</span>
            )}
          </div>
          <div style={{ marginTop: 2 }}>
            <CredentialStateNotice
              credentialState={agent.credential_state}
              agentName={agent.name}
              variant="inline"
            />
          </div>
        </td>

        {/* 7. Last Observed */}
        <td style={{ padding: '11px 16px', fontSize: 12, color: 'var(--muted)', whiteSpace: 'nowrap' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
            <div>
              <div style={{ color: 'var(--text)', fontSize: 12 }}>
                {fmtRelative(observedTime)}
              </div>
              <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 1 }}>
                {agent.timestamps?.last_observed_at ? 'Observed' : (agent.last_transition_at ? 'Transitioned' : 'Created')}
              </div>
            </div>
            <button
              className="btn btn-secondary"
              style={{ fontSize: 11, padding: '3px 8px', opacity: 0.8 }}
              onClick={(e) => { e.stopPropagation(); onEdit(agent) }}
              title="Edit agent settings"
            >
              Edit
            </button>
          </div>
        </td>
      </tr>
    </tbody>
  )
}

// ─── Governed Tab ────────────────────────────────────────────────────────────

function GovernedTab({
  agents,
  loading,
  loaded,
  error,
  lifecycleFilter,
  sourceHealth,
  sourceHealthDetail,
  onFilterChange,
  onRetry,
  onReload,
}: {
  agents: AgentResponse[]
  loading: boolean
  loaded: boolean
  error: string | null
  lifecycleFilter: string
  sourceHealth?: 'healthy' | 'degraded' | 'unavailable' | null
  sourceHealthDetail?: SourceHealthMap | null
  onFilterChange: (state: string) => void
  onRetry: () => void
  onReload: () => void
}) {
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const initialSearch = searchParams.get('search') || ''
  const [search, setSearch] = useState(initialSearch)
  const [showRegister, setShowRegister] = useState(false)
  const [editingAgent, setEditingAgent] = useState<AgentResponse | null>(null)
  const [selectedAgent, setSelectedAgent] = useState<AgentResponse | null>(null)

  // Auto-sync search from URL
  useEffect(() => {
    const q = searchParams.get('search') || ''
    setSearch(q)
  }, [searchParams])

  // Auto-open drawer if ?drawer=<id> or ?agent=<id> is in URL
  useEffect(() => {
    const drawerId = searchParams.get('drawer') || searchParams.get('agent')
    if (drawerId && agents.length > 0) {
      const match = agents.find(a => a.id === drawerId || a.name === drawerId)
      if (match) {
        setSelectedAgent(match)
      }
    } else if (!drawerId && selectedAgent) {
      setSelectedAgent(null)
    }
  }, [searchParams, agents])

  const handleSearchChange = (val: string) => {
    setSearch(val)
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      if (val.trim()) next.set('search', val.trim())
      else next.delete('search')
      return next
    }, { replace: true })
  }

  const handleSelectAgent = (agent: AgentResponse) => {
    setSelectedAgent(agent)
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      next.set('drawer', agent.id)
      return next
    }, { replace: true })
  }

  const handleCloseDrawer = () => {
    setSelectedAgent(null)
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      next.delete('drawer')
      next.delete('agent')
      return next
    }, { replace: true })
  }

  const handleClear = () => {
    setSearch('')
    onFilterChange('all')
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      next.delete('search')
      next.delete('lifecycle')
      next.delete('state')
      next.delete('drawer')
      next.delete('agent')
      return next
    }, { replace: true })
  }

  const filtered = useMemo(() => {
    let list = agents
    if (lifecycleFilter !== 'all') list = list.filter(a => a.lifecycle_state === lifecycleFilter)
    if (search.trim()) {
      const q = search.toLowerCase()
      list = list.filter(a =>
        (a.name ?? '').toLowerCase().includes(q) ||
        a.id.toLowerCase().includes(q) ||
        (a.type ?? '').toLowerCase().includes(q) ||
        (a.owner ?? '').toLowerCase().includes(q) ||
        (a.runtime?.namespace ?? a.namespace ?? '').toLowerCase().includes(q) ||
        (a.runtime?.framework ?? a.framework ?? '').toLowerCase().includes(q) ||
        (a.responsibility?.owner_name ?? '').toLowerCase().includes(q) ||
        (a.responsibility?.team ?? '').toLowerCase().includes(q) ||
        (a.identity?.spiffe_id ?? '').toLowerCase().includes(q)
      )
    }
    return list
  }, [agents, search, lifecycleFilter])

  const lifecycleCounts = useMemo(() => Object.fromEntries(
    LIFECYCLE_OPTIONS.map((state) => [
      state,
      state === 'all' ? agents.length : agents.filter((agent) => agent.lifecycle_state === state).length,
    ])
  ), [agents])

  const phase = loadPhase({ loading, error, loaded })
  if (phase === 'loading' || phase === 'idle' || phase === 'error') {
    return <LoadingState variant="block" status={phase} label="agents" error={error} onRetry={onRetry} testId="agents-load-state" />
  }

  const TH_STYLE: React.CSSProperties = {
    padding: '11px 16px', textAlign: 'left', color: 'var(--muted)',
    fontWeight: 600, fontSize: 11, textTransform: 'uppercase',
    letterSpacing: '0.06em', whiteSpace: 'nowrap',
  }

  return (
    <div style={{ width: '100%' }}>
      {showRegister && <RegisterModal onClose={() => setShowRegister(false)} onCreated={onReload} />}
      {editingAgent && <EditAgentModal agent={editingAgent} onClose={() => setEditingAgent(null)} onSaved={onReload} />}
      {selectedAgent && (
        <AgentEvidenceDrawer
          agent={selectedAgent}
          sourceHealth={sourceHealth}
          sourceHealthDetail={sourceHealthDetail}
          onClose={handleCloseDrawer}
          onOpenFullRecord={(id) => navigate(`/agents/${id}`)}
          onEdit={(agent) => {
            setSelectedAgent(null)
            setEditingAgent(agent)
          }}
        />
      )}

      {/* Filter bar */}
      <div style={{ display: 'flex', gap: 10, marginBottom: 14, alignItems: 'center', flexWrap: 'wrap' }}>
        <input
          type="text"
          aria-label="Search agents"
          placeholder="Search agents (name, ID, namespace, framework, owner, SPIFFE)…"
          value={search}
          onChange={(e) => handleSearchChange(e.target.value)}
          style={{ flex: 1, minWidth: 220, maxWidth: 360 }}
        />
        <div className="sl-filter-chips" role="group" aria-label="Filter agents by lifecycle state">
          {LIFECYCLE_OPTIONS.map((state) => (
            <button
              key={state}
              type="button"
              className="sl-filter-chip"
              data-testid={`agent-lifecycle-filter-${state}`}
              aria-pressed={lifecycleFilter === state}
              onClick={() => onFilterChange(state)}
            >
              {state !== 'all' && <span aria-hidden="true" className={`sl-filter-dot sl-filter-dot--${state}`} />}
              {LIFECYCLE_LABELS[state]}
              <span className="sl-filter-chip__count">{lifecycleCounts[state]}</span>
            </button>
          ))}
        </div>
        {(search || lifecycleFilter !== 'all') && (
          <button
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '5px 12px' }}
            onClick={handleClear}
          >
            Clear
          </button>
        )}
        <button className="btn btn-primary" style={{ marginLeft: 'auto', fontSize: 12, padding: '5px 14px' }} onClick={() => setShowRegister(true)}>
          Register Agent
        </button>
      </div>

      {filtered.length === 0 ? (
        agents.length === 0 ? (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12, padding: 40 }}>
            <EmptyState
              kicker="No governed agents"
              body="Agents appear here after enrollment via the registry API."
            />
            <button className="btn btn-primary" onClick={() => setShowRegister(true)}>Register Agent</button>
          </div>
        ) : (
          <EmptyState kicker="No agents match your filter" body="Try clearing the search or changing the state filter." />
        )
      ) : (
        <div className="card" role="region" aria-label="Governed agents table" tabIndex={0} style={{ padding: 0, overflow: 'auto', width: '100%' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
            <thead>
              <tr style={{ background: 'var(--surface2)', borderBottom: '1px solid var(--border)' }}>
                <th style={TH_STYLE}>Agent</th>
                <th style={TH_STYLE}>Runtime</th>
                <th style={TH_STYLE}>Responsibility</th>
                <th style={TH_STYLE}>Operational State</th>
                <th style={TH_STYLE}>Attention</th>
                <th style={TH_STYLE}>Identity & Evidence</th>
                <th style={TH_STYLE}>Last Observed</th>
              </tr>
            </thead>
            {agents.map((a) => {
              const shown = filtered.some((agent) => agent.id === a.id)
              return (
                <AgentTableRow
                  key={a.id}
                  agent={a}
                  shown={shown}
                  onSelect={handleSelectAgent}
                  onEdit={setEditingAgent}
                />
              )
            })}
          </table>
        </div>
      )}

      {filtered.length > 0 && (
        <div aria-live="polite" style={{ marginTop: 12, fontSize: 12, color: 'var(--muted)', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <span>Showing {filtered.length} of {agents.length} agent{agents.length !== 1 ? 's' : ''}</span>
          {lifecycleFilter !== 'all' && (
            <span style={{ fontSize: 11, color: 'var(--muted)', opacity: 0.8 }}>
              Filtered by: <strong>{LIFECYCLE_LABELS[lifecycleFilter]}</strong>
            </span>
          )}
        </div>
      )}
    </div>
  )
}

// ─── Signal Summary Panel ──────────────────────────────────────────────────

function SignalSummaryPanel() {
  const navigate = useNavigate()
  const signal = useSignalSummary()

  if (signal.loading || signal.error || signal.totalObservations === 0) return null

  const provisionalCount = signal.actorsByStatus['provisional'] ?? 0
  const actionableCount = signal.actorsByStatus['actionable'] ?? 0

  return (
    <div
      data-testid="signal-summary-panel"
      className="card"
      style={{
        padding: '12px 18px',
        marginBottom: 16,
        display: 'flex',
        alignItems: 'center',
        gap: 14,
        fontSize: 13,
      }}
    >
      <SignalBadge
        observationCount={signal.totalObservations}
        highestFidelity={signal.highestFidelity!}
        layerCount={signal.layerCount}
        onClick={() => navigate('/weave')}
        testId="agents-signal-badge"
      />
      <span style={{ color: 'var(--muted)', fontSize: 12 }}>
        across {signal.layerCount} signal layer{signal.layerCount !== 1 ? 's' : ''}
      </span>
      {(provisionalCount > 0 || actionableCount > 0) && (
        <span style={{ color: 'var(--text)', fontSize: 12, marginLeft: 'auto' }}>
          {actionableCount > 0 && (
            <span
              title={`${actionableCount} actor${actionableCount !== 1 ? 's' : ''} with sufficient evidence for investigation`}
              style={{ color: 'var(--amber)', fontWeight: 600 }}
            >
              {actionableCount} actionable
            </span>
          )}
          {actionableCount > 0 && provisionalCount > 0 && (
            <span style={{ color: 'var(--muted)' }}> · </span>
          )}
          {provisionalCount > 0 && (
            <span
              title={`${provisionalCount} provisional actor${provisionalCount !== 1 ? 's' : ''} under correlation`}
              style={{ color: 'var(--muted)' }}
            >
              {provisionalCount} provisional
            </span>
          )}
          <span style={{ color: 'var(--muted)' }}> actor{(provisionalCount + actionableCount) !== 1 ? 's' : ''} detected</span>
        </span>
      )}
      <button
        className="btn btn-secondary"
        style={{ fontSize: 11, padding: '4px 10px', marginLeft: provisionalCount === 0 && actionableCount === 0 ? 'auto' : undefined }}
        onClick={() => navigate('/weave')}
        title="View full Signal Weave correlation dashboard"
      >
        View Weave
      </button>
    </div>
  )
}

// ─── Main Page ───────────────────────────────────────────────────────────────

export default function AgentsPage() {
  const { getAccessTokenSilently } = useAuth0()

  const [agents, setAgents] = useState<AgentResponse[]>([])
  const [meta, setMeta] = useState<AgentListMeta | null>(null)
  const [sourceHealth, setSourceHealth] = useState<'healthy' | 'degraded' | 'unavailable' | null>('healthy')
  const [sourceHealthDetail, setSourceHealthDetail] = useState<SourceHealthMap | null>(null)
  const [lastRefresh, setLastRefresh] = useState<string | null>(null)

  const [agentsLoading, setAgentsLoading] = useState(true)
  const [agentsLoaded, setAgentsLoaded] = useState(false)
  const [agentsError, setAgentsError] = useState<string | null>(null)

  const [lifecycleFilter, setLifecycleFilter] = useState('all')

  const [scanning, setScanning] = useState(false)
  const [lastScanTimestamp, setLastScanTimestamp] = useState<string | null>(null)

  const loadAgents = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const data = await api.agents.list(token)
      setAgents(data.agents || data.data || [])
      setMeta(data.meta || null)
      setSourceHealth(data.source_health || 'healthy')
      setSourceHealthDetail(data.source_health_detail || null)
      setLastRefresh(new Date().toISOString())
      setAgentsError(null)
      setAgentsLoaded(true)
    } catch (e) {
      setAgentsError(e instanceof Error ? e.message : 'Failed to load agents')
      setSourceHealth('unavailable')
    } finally {
      setAgentsLoading(false)
    }
  }, [getAccessTokenSilently])

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
      await loadAgents()
    } catch (e) {
      console.error('Compliance scan failed:', e)
    } finally {
      setScanning(false)
    }
  }, [getAccessTokenSilently, loadAgents])

  useEffect(() => {
    loadAgents()
    const t = setInterval(loadAgents, POLL_MS)
    return () => clearInterval(t)
  }, [loadAgents])

  const alerts: AlertItem[] = useMemo(() => {
    const items: AlertItem[] = []

    const withViolations = agents.filter(a => a.compliance_summary.failing > 0)
    if (withViolations.length > 0)
      items.push({ id: 'violations', label: 'agents with new violations', count: withViolations.length, severity: 'critical' })

    const unconfirmed = agents.filter(a =>
      (a.lifecycle_state === 'suspended' || a.lifecycle_state === 'stunned' || a.credential_state?.status === 'revoked') &&
      !(a.kernel_telemetry?.cgroup_state === 'frozen' || a.kernel_telemetry?.traffic_control_state === 'drop')
    )
    if (unconfirmed.length > 0)
      items.push({ id: 'unconfirmed', label: 'containment unconfirmed', count: unconfirmed.length, severity: 'warning', filterKey: 'suspended' })

    const enrolledInactive = agents.filter(a => a.lifecycle_state === 'enrolled')
    if (enrolledInactive.length > 0)
      items.push({ id: 'enrolled', label: 'enrolled agents not activated', count: enrolledInactive.length, severity: 'warning', filterKey: 'enrolled' })

    const suspended = agents.filter(a => a.lifecycle_state === 'suspended')
    if (suspended.length > 0)
      items.push({ id: 'suspended', label: 'suspended agents', count: suspended.length, severity: 'warning', filterKey: 'suspended' })

    const critical = agents.filter(a =>
      a.compliance_summary.posture_score !== null &&
      (a.compliance_summary.posture_score <= 1.0 ? a.compliance_summary.posture_score < 0.5 : a.compliance_summary.posture_score < 50)
    )
    if (critical.length > 0)
      items.push({ id: 'critical', label: 'agents with critical posture', count: critical.length, severity: 'critical' })

    return items
  }, [agents])

  const totalAssessed = agents.filter(a => a.compliance_summary.total_controls > 0).length

  return (
    <div>
      {/* Header & Subtitle */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 18 }}>
        <div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <h1 style={{ fontSize: 22, fontWeight: 700, margin: 0 }}>Agents</h1>
            <HelpHint label="About governed agents" testId="agents-governed-help">
              Live registry records for governed workloads. During SuperCred, Cardvault appears as one enriched record rather than a duplicate.
            </HelpHint>
          </div>
          <div style={{ fontSize: 13, color: 'var(--muted)', marginTop: 2 }}>
            Runtime identities and their security evidence
          </div>
          <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4 }}>
            Inventory refreshed {lastRefresh ? fmtRelativeMinutes(lastRefresh) ?? 'just now' : 'just now'} · Source health:{' '}
            <span style={{
              color: sourceHealth === 'healthy' ? 'var(--teal)' : sourceHealth === 'degraded' ? 'var(--amber)' : 'var(--error)',
              fontWeight: 600,
              textTransform: 'capitalize',
            }}>
              {sourceHealth === 'unavailable' ? 'Source unavailable' : (sourceHealth || 'healthy')}
            </span>
            {' '}· Assessments:{' '}
            <span style={{ color: 'var(--text)', fontWeight: 500 }}>
              {totalAssessed > 0 ? `${totalAssessed} evaluated` : 'Not assessed'}
            </span>
          </div>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <LoadingState
            status={loadPhase({ loading: agentsLoading, error: agentsError, loaded: agentsLoaded })}
            label="agents"
            error={agentsError}
            onRetry={loadAgents}
            testId="agents-poll-state"
          />
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            {lastScanTimestamp && (
              <span style={{ fontSize: 11, color: 'var(--muted)' }}>
                Last scanned: {fmtRelativeMinutes(lastScanTimestamp)}
              </span>
            )}
            <span style={{ fontSize: 11, color: 'var(--muted)', opacity: 0.7 }}>
              Auto-scan every 15 minutes
            </span>
            <HelpHint label="About agent refresh timing" testId="agents-refresh-help">
              The list polls live registry state automatically. Use Scan Compliance to run an immediate policy evaluation.
            </HelpHint>
          </div>
          <button
            className="btn btn-primary"
            style={{ fontSize: 12, padding: '6px 14px' }}
            disabled={scanning}
            onClick={handleComplianceScan}
          >
            {scanning ? 'Scanning...' : 'Scan Compliance'}
          </button>
          <HelpHint label="About the policy scan" testId="agents-scan-help">
            Runs a live policy scan against the governed agent list and updates posture and compliance findings.
          </HelpHint>
        </div>
      </div>

      {/* Top 4 StatCards */}
      {agentsLoaded && agents.length > 0 && (
        <AgentStatCards
          agents={agents}
          meta={meta}
          sourceHealth={sourceHealth}
          sourceHealthDetail={sourceHealthDetail}
        />
      )}

      <AttentionPanel alerts={alerts} onAlert={(key) => key && setLifecycleFilter(key)} />

      <SignalSummaryPanel />

      <GovernedTab
        agents={agents}
        loading={agentsLoading}
        loaded={agentsLoaded}
        error={agentsError}
        lifecycleFilter={lifecycleFilter}
        sourceHealth={sourceHealth}
        sourceHealthDetail={sourceHealthDetail}
        onFilterChange={setLifecycleFilter}
        onRetry={loadAgents}
        onReload={loadAgents}
      />
    </div>
  )
}
