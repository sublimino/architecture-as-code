// Filter interaction adapted from Beautiful UI Filter Table (MIT); see
// THIRD_PARTY_NOTICES.md. Signal Loom owns data, tokens, and semantics.
import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { useNavigate, useSearchParams, Link } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { LIVE_POLL_MS } from '../api/pollInterval'
import { claimDiscoveredAgent, type AgentClaimRequest } from '../api/agentClaim'
import type { AgentResponse, AgentListMeta, SourceHealthMap, AgentLifecycleState } from '../types/api'
import StatusBadge, { KernelStateBadge, isFrozenWithoutStun, STUN_WITHOUT_KERNEL_FREEZE } from '../components/StatusBadge'
import AgentReviewQueue from '../components/AgentReviewQueue'
import { deriveAgentReview, needsAgentReview } from '../data/agentReview'
import SignalBadge from '../components/SignalBadge'
import CredentialStateNotice from '../components/CredentialStateNotice'
import EmptyState from '../components/EmptyState'
import LoadingState, { loadPhase } from '../components/LoadingState'
import HelpHint from '../components/HelpHint'
import AgentEvidenceDrawer from '../components/AgentEvidenceDrawer'
import { useSignalSummary } from '../hooks/useSignalSummary'
import { parseAgentSelectorQuery, matchAgentByQuery, getAgentFramework, isClaudeAgent, agentMatchesIdentity } from '../data/agentQuerySelectors'
export { getAgentFramework, isClaudeAgent }
import { hasGitOpsMetadata, isAgentTenantMismatch, getSafeStorageItem } from '../data/workloadFilters'
import { getTenantIdFromToken } from '../auth/tenant'
import { useServerTenant } from '../auth/superadmin'
import { getAgentWorkloadSecurityProfile } from '../components/agents/ClaimModal'
import { CodingAgentsTab } from '../components/CodingAgentsTab'
import { CompactOperationalTable, CompactDisclosure, CompactEmail, CompactObservedTime } from '../components/CompactOperationalTable'
import { colors } from '../styles/tokens'

// Watched by the demo audience in a second window: see api/pollInterval.ts.
const POLL_MS = LIVE_POLL_MS

// ─── Register Modal ──────────────────────────────────────────────────────────

/** Prefill values for the registration form, used by Claim to pre-populate
 *  from a discovered NHI account. */
export interface AgentFormPrefill {
  name?: string
  type?: string
  description?: string
  owner?: string
  /** The NHI account ID being claimed: drives the enroll call on submit. */
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
  if (!iso) return 'N/A'
  return new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })
}

function fmtRelative(iso: string | null) {
  if (!iso) return 'N/A'
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

interface ClaimNotification {
  kind: 'success' | 'error'
  message: string
}

function buildClaimRequest(agent: AgentResponse, claimantOwner?: string): AgentClaimRequest {
  const podName = agent.runtime?.pod_name || (agent.record_class === 'discovered' ? agent.id : agent.name)
  const namespace = agent.runtime?.namespace || agent.namespace || 'fe-signalloom-agents'
  const serviceAccount = agent.runtime?.service_account || agent.service_account || podName

  return {
    pod_name: podName,
    display_name: agent.name,
    namespace,
    spiffe_id: agent.identity?.spiffe_id || `spiffe://cluster.local/ns/${namespace}/sa/${serviceAccount}`,
    harness: agent.runtime?.framework || agent.framework || agent.type || 'unknown',
    model: agent.runtime?.model || agent.model_name || 'unknown',
    declared_tools: [],
    token_budget_limit: 100000,
    agent_id: agent.id,
    owner: claimantOwner,
  }
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

export const isAgentAttentionRequired = needsAgentReview

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
  const review = deriveAgentReview(agents)
  const unconfirmedCount = review.issues.filter(issue => issue.category === 'containment-unconfirmed').length
  const attentionCount = review.affectedAgentCount

  // 2. Identity Coverage
  const registeredCount = meta?.registered_count ?? agents.filter(a => a.record_class === 'registered' || (!a.record_class && a.is_registry_linked !== false)).length
  const discoveredCount = meta?.discovered_count ?? agents.filter(a => a.record_class === 'discovered' || a.is_registry_linked === false).length
  const resolvedCount = meta?.resolved_count ?? agents.filter(a => a.record_class === 'resolved').length
  const resolvedPct = total > 0 ? Math.round(((registeredCount + resolvedCount) / total) * 100) : 0

  // 3. Observed Workloads
  const operationalCount = meta?.operational_count ?? total
  const namespaces = new Set(agents.map(a => a.runtime?.namespace || a.namespace || 'default'))
  const frameworks = new Set(agents.map(a => getAgentFramework(a)))

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

// ─── 7-Column Operational Inventory Table Row ────────────────────────────────

export const LIFECYCLE_OPTIONS: readonly ('all' | AgentLifecycleState)[] = ['all', 'Governed', 'Suspended', 'Revoked'] as const

export const LIFECYCLE_LABELS: Record<string, string> = {
  all: 'All states',
  Governed: 'Governed',
  Suspended: 'Suspended',
  Revoked: 'Revoked',
  registered: 'Governed',
  enrolled: 'Governed',
  active: 'Governed',
  suspended: 'Suspended',
  revoked: 'Revoked',
}

export const LIFECYCLE_TOOLTIP: Record<string, string> = {
  Governed: 'Active, enrolled, or registered agent governed under Signal Loom policy controls.',
  Suspended: 'Temporarily suspended or stunned agent: credentials refused and kernel containment active if enforced.',
  Revoked: 'Permanently revoked or decommissioned terminal state: credentials refused.',
  registered: 'Created in the registry and not yet enrolled: no identity has been issued.',
  enrolled: 'Enrolled with an identity but not yet activated: cannot authenticate until transitioned to active.',
  active: 'Active and authorized to operate.',
  suspended: 'Temporarily suspended: reversible, credentials refused until reinstated.',
  revoked: 'Permanently revoked: terminal state, credentials refused.',
}

export function AgentTableRow({ agent, shown, claiming, onSelect, onEdit, onClaim }: {
  agent: AgentResponse
  shown: boolean
  claiming: boolean
  onSelect: (agent: AgentResponse) => void
  onEdit: (agent: AgentResponse) => void
  onClaim: (agent: AgentResponse) => void
}) {
  const hasViolations = agent.compliance_summary.failing > 0
  const recordClass = agent.record_class || (agent.is_registry_linked === false ? 'discovered' : 'registered')
  const recordClassLabel = recordClass.charAt(0).toUpperCase() + recordClass.slice(1)
  const canClaim = recordClass === 'discovered' || agent.is_registry_linked === false
  const secProfile = getAgentWorkloadSecurityProfile(agent)

  // 1. Agent column
  const agentName = agent.name || 'Unnamed agent'
  const agentExecutionMode = agent.runtime?.execution_mode || agent.type || (agent.id ? `ID: ${agent.id.split('-')[0]}…` : 'N/A')

  // 2. Runtime column
  const namespace = agent.runtime?.namespace || agent.namespace || 'default'
  const framework = getAgentFramework(agent)
  const model = agent.runtime?.model || agent.model_name || (agent.runtime?.node ? `node: ${agent.runtime.node}` : null)

  // 3. Responsibility column (truthful language)
  const ownerName = agent.responsibility?.owner_name || agent.owner
  const team = agent.responsibility?.team

  // 4. Operational State column (with kernel telemetry)
  const isTelemetryFrozenOrDrop = agent.kernel_telemetry?.cgroup_state === 'frozen' || agent.kernel_telemetry?.traffic_control_state === 'drop'
  // Kernel frozen with no stun record: the lifecycle label and the thawed
  // telemetry tags are both stale claims, so neither is rendered.
  const splitBrainFrozen = isFrozenWithoutStun(agent)
  const isContainmentRequested = agent.lifecycle_state === 'Suspended' || agent.lifecycle_state === 'suspended' || agent.lifecycle_state === 'stunned' || agent.credential_state?.status === 'revoked'

  // 5. Attention column (truthful language)
  const isNotAssessed = (agent.compliance_summary.total_controls === 0) ||
    (agent.compliance_summary.posture_score === null && agent.compliance_summary.passing === 0 && agent.compliance_summary.failing === 0)

  // 6. Identity & Evidence column
  const isSpiffeLinked = agent.identity?.spiffe_status === 'linked' || (!!agent.identity?.spiffe_id && agent.record_class !== 'discovered' && agent.is_registry_linked !== false)

  // 7. Last Observed column
  const observedTime = agent.timestamps?.last_observed_at
  const credentialCritical = agent.credential_state?.status === 'unknown' || agent.credential_state?.status === 'revoked'
  const posture = agent.compliance_summary.posture_score
  const posturePercent = posture === null ? null : Math.round(posture <= 1 ? posture * 100 : posture)
  const attentionTone = isNotAssessed ? 'var(--muted)' : hasViolations ? 'var(--error)' : 'var(--teal)'

  return (
    <tbody
      className="sl-filter-table-row"
      aria-hidden={!shown}
      style={{ opacity: shown ? 1 : 0, visibility: shown ? 'visible' : 'collapse' }}
    >
      <tr
         data-testid={`agent-row-${agent.id}`}
         className={canClaim ? 'compact-claimable' : undefined}
        tabIndex={0}
        role="button"
        aria-label={`View evidence for ${agentName}`}
        onClick={() => onSelect(agent)}
        onKeyDown={(e) => {
          if (e.target === e.currentTarget && (e.key === 'Enter' || e.key === ' ')) {
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
            <Link
              to={`/agents/${agent.id}?tab=overview`}
              data-testid={`agent-link-${agent.id}`}
              onClick={(e) => e.stopPropagation()}
              title={`Open full dossier for ${agentName}`}
              style={{
                fontWeight: 600,
                fontSize: 13,
                color: 'var(--text)',
                textDecoration: 'none',
                 display: 'flex',
                 minWidth: 0,
                alignItems: 'center',
                gap: 4,
              }}
               className="compact-agent-name"
            >
               <span className="compact-agent-name">{agentName}</span>
              <span style={{ fontSize: 11, color: 'var(--muted)', opacity: 0.7 }} aria-hidden="true">&rarr;</span>
            </Link>
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
          <div className="compact-agent-meta">
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
            <CompactDisclosure className="compact-agent-details" label={`Agent details for ${agentName}`} summary={<span className="compact-secondary">Details</span>}>
            <div>Name: {agentName}</div>
            <div>Agent ID: {agent.id}</div>
            <span
              data-testid={`agent-security-profile-badge-${agent.id}`}
              className="tag"
              title={secProfile.description}
              style={{
                fontSize: 10,
                padding: '1px 5px',
                background: secProfile.profile === 'nono-sandboxed'
                  ? 'rgba(34, 197, 94, 0.15)'
                  : 'rgba(56, 189, 248, 0.15)',
                color: secProfile.profile === 'nono-sandboxed'
                  ? 'var(--teal)'
                  : 'var(--cyan)',
                border: `1px solid ${secProfile.profile === 'nono-sandboxed' ? 'rgba(34, 197, 94, 0.3)' : 'rgba(56, 189, 248, 0.3)'}`,
              }}
            >
              {secProfile.label}
            </span>
            {agent.tenant ? (
              <span
                data-testid={`agent-tenant-badge-${agent.id}`}
                className="tag"
                title={`Tenant: ${agent.tenant}`}
                style={{
                  fontSize: 10,
                  padding: '1px 5px',
                  background: 'rgba(139, 92, 246, 0.15)',
                  color: 'var(--violet)',
                  border: '1px solid rgba(139, 92, 246, 0.3)',
                }}
              >
                {agent.tenant}
              </span>
            ) : agent.tenant_id && agent.tenant_id !== 'undeclared' ? (
              <span
                data-testid={`agent-tenant-badge-${agent.id}`}
                className="tag"
                title={`Tenant: ${agent.tenant_id}`}
                style={{
                  fontSize: 10,
                  padding: '1px 5px',
                  background: 'rgba(139, 92, 246, 0.15)',
                  color: 'var(--violet)',
                  border: '1px solid rgba(139, 92, 246, 0.3)',
                }}
              >
                {agent.tenant_id}
              </span>
            ) : (
              <span
                data-testid={`agent-tenant-badge-${agent.id}`}
                className="tag"
                title="Tenant: Undeclared"
                style={{
                  fontSize: 10,
                  padding: '1px 5px',
                  background: 'rgba(148, 163, 184, 0.15)',
                  color: 'var(--muted)',
                  border: '1px solid rgba(148, 163, 184, 0.3)',
                }}
              >
                Undeclared
              </span>
            )}
            <span
              title={`Agent ID: ${agent.id}`}
              style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace' }}
            >
              {agentExecutionMode}
            </span>
            <div>{secProfile.description}</div>
            </CompactDisclosure>
            <CompactDisclosure className="compact-row-details" retainContent={false} label={`Inventory details for ${agentName}`} summary={<span className="compact-secondary">More</span>}>
              <div>Name: {agentName}</div>
              <div>Agent ID: {agent.id}</div>
              <div>Security profile: {secProfile.label} · {secProfile.description}</div>
              <div>Execution: {agentExecutionMode}</div>
              <div>Runtime: {namespace} / {framework}</div>
              <div>Model: {model || 'Unknown'}</div>
              <div>Owner: {ownerName ? <CompactEmail value={ownerName} /> : (canClaim ? 'Registry not linked' : 'Unassigned')}</div>
              <div>Team: {team || 'Undeclared'}</div>
              <div>Tenant: {agent.tenant || agent.tenant_id || 'Undeclared'}</div>
              <div>Identity: {isSpiffeLinked ? 'SPIFFE linked' : recordClass === 'discovered' ? 'Observed workload' : 'Identity unlinked'}</div>
              <div>SPIFFE ID: {agent.identity?.spiffe_id || 'Unknown'}</div>
              <CredentialStateNotice credentialState={agent.credential_state} agentName={agent.name} variant="inline" />
            </CompactDisclosure>
          </div>
        </td>

        {/* 2. Runtime */}
        <td style={{ padding: '11px 16px', fontSize: 12 }}>
          <CompactDisclosure label={`Runtime details for ${agentName}`} summary={<span>{framework}</span>}>
          <div>Framework: {framework}</div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span style={{ fontWeight: 500, color: 'var(--text)' }}>{namespace}</span>
            <span style={{ color: 'var(--muted)' }}>/</span>
          </div>
          {model && (
            <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
              {model}
            </div>
          )}
          </CompactDisclosure>
        </td>

        {/* 3. Responsibility */}
        <td style={{ padding: '11px 16px', fontSize: 12 }}>
          {ownerName ? (
            <div>
              <CompactDisclosure label={`Responsibility details for ${agentName}`} summary={<CompactEmail value={ownerName} />}>
              <div>Owner: <CompactEmail value={ownerName} /></div>
              {team && <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 1 }}>{team}</div>}
              <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
                Tenant: <span style={{ color: 'var(--text)' }}>{agent.tenant || (agent.tenant_id && agent.tenant_id !== 'undeclared' ? agent.tenant_id : 'Undeclared')}</span>
              </div>
              </CompactDisclosure>
            </div>
          ) : (
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
              <span style={{ color: 'var(--muted)' }}>
                {recordClass === 'discovered' || agent.is_registry_linked === false ? 'Registry not linked' : 'Unassigned'}
              </span>{' '}
              <CompactDisclosure label={`Responsibility details for ${agentName}`} summary={<span className="compact-secondary">Details</span>}>
              <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
                Tenant: <span style={{ color: 'var(--text)' }}>{agent.tenant || (agent.tenant_id && agent.tenant_id !== 'undeclared' ? agent.tenant_id : 'Undeclared')}</span>
              </div>
              </CompactDisclosure>
            </div>
          )}
        </td>

        {/* 4. Operational State */}
        <td style={{ padding: '11px 16px' }}>
          <div className="compact-state">
            <div className="compact-state-primary">
            {!splitBrainFrozen && (
              <CompactDisclosure label={`Operational state details for ${agentName}`} summary={<StatusBadge status={agent.lifecycle_state} variant="lifecycle" isFrozen={isTelemetryFrozenOrDrop} />}>
                <div>Lifecycle: {agent.lifecycle_state}</div>
                <div>{LIFECYCLE_TOOLTIP[agent.lifecycle_state] || agent.lifecycle_state}</div>
                <div>cgroup: {agent.kernel_telemetry?.cgroup_state || 'Unknown'} · TC: {agent.kernel_telemetry?.traffic_control_state || 'Unknown'}</div>
                {isContainmentRequested && !isTelemetryFrozenOrDrop && <div>Containment requested but kernel telemetry observation is unconfirmed.</div>}
              </CompactDisclosure>
            )}
            {(agent.kernel_state === 'frozen' || (agent.kernel_state === 'running' && (agent.split_brain ?? []).includes(STUN_WITHOUT_KERNEL_FREEZE))) && (
              <CompactDisclosure label={`Kernel observation details for ${agentName}`} summary={<KernelStateBadge view={agent} compact testId={`kernel-state-badge-${agent.id}`} />}>
                <KernelStateBadge view={agent} />
                <div>{splitBrainFrozen ? 'Kernel cgroup is frozen, but no stun record exists. The lifecycle label is stale.' : agent.kernel_state === 'running' ? 'A stun record exists but the kernel cgroup is not frozen.' : 'Kernel cgroup freeze confirmed by the signalloom-warden.'}</div>
                <div>Kernel state: {agent.kernel_state}</div>
                <div>Observed: {agent.kernel_observed_at || 'Unknown'}</div>
                <div>{agent.split_brain?.join('; ')}</div>
              </CompactDisclosure>
            )}
            </div>
            <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
              {splitBrainFrozen ? null : isTelemetryFrozenOrDrop ? (
                <>
                  {agent.kernel_telemetry?.cgroup_state === 'frozen' && (
                    <span
                      data-testid={`kernel-telemetry-cgroup-${agent.id}`}
                      className="tag"
                      title="cgroup.freeze: 1 (FROZEN): Processes atomically suspended by Sentinel"
                       style={{ fontSize: 10, padding: '1px 5px', background: 'color-mix(in srgb, var(--error) 15%, transparent)', color: 'var(--error)', borderColor: 'color-mix(in srgb, var(--error) 30%, transparent)' }}
                    >
                      cgroup: FROZEN
                    </span>
                  )}
                  {agent.kernel_telemetry?.traffic_control_state === 'drop' && (
                    <span
                      data-testid={`kernel-telemetry-tc-${agent.id}`}
                      className="tag"
                      title="TC matchall drop active: Network isolated by Sentinel"
                       style={{ fontSize: 10, padding: '1px 5px', background: 'color-mix(in srgb, var(--error) 15%, transparent)', color: 'var(--error)', borderColor: 'color-mix(in srgb, var(--error) 30%, transparent)' }}
                    >
                      TC: DROP
                    </span>
                  )}
                </>
              ) : isContainmentRequested ? (
                <CompactDisclosure label={`Containment outcome details for ${agentName}`} summary={
                <span
                  data-testid={`kernel-telemetry-unconfirmed-${agent.id}`}
                       className="tag compact-warning"
                       title="Containment requested but kernel telemetry observation is unconfirmed"
                   style={{ fontSize: 10, padding: '1px 5px', background: 'color-mix(in srgb, var(--amber) 15%, transparent)', color: 'var(--amber)', borderColor: 'color-mix(in srgb, var(--amber) 30%, transparent)' }}
                >
                   Unconfirmed
                </span>
                }>
                  <div>Requested (Outcome unconfirmed)</div>
                  <div>Containment requested but kernel telemetry observation is unconfirmed.</div>
                </CompactDisclosure>
              ) : (
                <>
                  {agent.kernel_telemetry?.cgroup_state === 'thawed' && (
                    <span
                      data-testid={`kernel-telemetry-cgroup-${agent.id}`}
                      className="tag"
                      title="cgroup.freeze: 0 (THAWED)"
                       style={{ fontSize: 10, padding: '1px 5px', background: 'color-mix(in srgb, var(--teal) 15%, transparent)', color: 'var(--teal)', borderColor: 'color-mix(in srgb, var(--teal) 30%, transparent)' }}
                    >
                      cgroup: THAWED
                    </span>
                  )}
                  {agent.kernel_telemetry?.traffic_control_state === 'allow' && (
                    <span
                      data-testid={`kernel-telemetry-tc-${agent.id}`}
                      className="tag"
                      title="TC drop: INACTIVE"
                       style={{ fontSize: 10, padding: '1px 5px', background: 'color-mix(in srgb, var(--teal) 15%, transparent)', color: 'var(--teal)', borderColor: 'color-mix(in srgb, var(--teal) 30%, transparent)' }}
                    >
                      TC: PASS
                    </span>
                  )}
                </>
              )}
            </div>
            {credentialCritical && agent.credential_state && <CompactDisclosure label={`Credential evidence for ${agentName}`} summary={<StatusBadge status={agent.credential_state.status} variant="credential" label={agent.credential_state.status === 'unknown' ? 'Credentials unknown' : 'Credentials revoked'} testId={`compact-credential-state-${agent.id}`} />}>
              <CredentialStateNotice credentialState={agent.credential_state} agentName={agent.name} variant="inline" />
              {agent.credential_state.status === 'unknown' && <div>No stun audit record shows the bao and spire credential planes contained.</div>}
            </CompactDisclosure>}
          </div>
        </td>

        {/* 5. Attention */}
        <td style={{ padding: '11px 16px', fontSize: 12 }}>
          <CompactDisclosure label={`Assessment details for ${agentName}`} summary={<span className="compact-attention">
            <span className="tag" style={{ color: attentionTone, background: `color-mix(in srgb, ${attentionTone} 15%, transparent)` }}>
              {isNotAssessed ? 'Unassessed' : hasViolations ? `${agent.compliance_summary.failing} failing` : `${agent.compliance_summary.passing}/${agent.compliance_summary.total_controls}`}
            </span>
            {!isNotAssessed && posturePercent !== null && <span className="compact-attention-score" style={{ color: attentionTone }}>{posturePercent}%</span>}
          </span>}>
            {isNotAssessed ? <div>Not assessed</div> : <>
              <div>{agent.compliance_summary.passing}/{agent.compliance_summary.total_controls} {hasViolations ? 'passed' : 'passing'}</div>
              <div>Failing controls: {agent.compliance_summary.failing} · Pending: {agent.compliance_summary.pending}</div>
              <div>Posture: {posturePercent === null ? 'Unknown' : `${posturePercent}%`}.</div>
            </>}
          </CompactDisclosure>
        </td>

        {/* 6. Identity & Evidence */}
        <td style={{ padding: '11px 16px', fontSize: 12 }}>
          <CompactDisclosure label={`Identity evidence for ${agentName}`} summary={isSpiffeLinked ? (
              <span style={{ color: 'var(--teal)', fontWeight: 500 }}>SPIFFE linked</span>
            ) : recordClass === 'discovered' ? (
              <span style={{ color: 'var(--cyan)' }}>Observed workload</span>
            ) : (
              <span style={{ color: 'var(--muted)' }}>Identity unlinked</span>
            )}>
              <div>Identity: {isSpiffeLinked ? 'SPIFFE linked' : recordClass === 'discovered' ? 'Observed workload' : 'Identity unlinked'}</div>
              <div>SPIFFE ID: {agent.identity?.spiffe_id || 'Unknown'}</div>
          </CompactDisclosure>
          <div style={{ marginTop: 2 }}>
            {agent.credential_state && !credentialCritical && <CompactDisclosure label={`Credential evidence for ${agentName}`} summary={<CredentialStateNotice credentialState={agent.credential_state} agentName={agent.name} variant="inline" />}>
              {agent.credential_state.status === 'revoked' ? <CredentialStateNotice credentialState={agent.credential_state} agentName={agent.name} variant="inline" /> : <div>Credential state: {agent.credential_state.status}{agent.credential_state.status === 'unknown' ? '. No stun audit record shows the bao and spire credential planes contained.' : ''}</div>}
            </CompactDisclosure>}
          </div>
        </td>

        {/* 7. Last Observed */}
         <td style={{ padding: '11px 16px', fontSize: 12, color: 'var(--muted)', whiteSpace: 'nowrap' }}>
           <span className="compact-mobile-label" aria-hidden="true">Seen</span>
           <CompactObservedTime value={observedTime} testId={`agent-full-timestamp-${agent.id}`} />
         </td>
         <td>
             <div className="compact-actions">
               {canClaim && (
                 <div className="compact-claim" style={{ order: 1 }}>
                <button
                  type="button"
                  className="btn btn-secondary"
                  data-testid="agent-auto-claim-btn"
                  data-agent-id={agent.id}
                  disabled={claiming}
                  aria-busy={claiming}
                  aria-label={`${claiming ? 'Claiming' : 'Claim'} ${agentName} into governance`}
                  title={`Enroll ${agentName} into Signal Loom governance`}
                  onClick={(e) => {
                    e.stopPropagation()
                    onClaim(agent)
                  }}
                  onKeyDown={(e) => e.stopPropagation()}
                >
                  {claiming && (
                    <svg
                      data-testid={`agent-auto-claim-spinner-${agent.id}`}
                      aria-hidden="true"
                      width="11"
                      height="11"
                      viewBox="0 0 12 12"
                       style={{ verticalAlign: '-1px', flexShrink: 0 }}
                    >
                      <circle cx="6" cy="6" r="4.5" fill="none" stroke="currentColor" strokeOpacity="0.3" />
                      <path d="M6 1.5a4.5 4.5 0 0 1 4.5 4.5" fill="none" stroke="currentColor" strokeLinecap="round">
                        <animateTransform attributeName="transform" type="rotate" from="0 6 6" to="360 6 6" dur="0.8s" repeatCount="indefinite" />
                      </path>
                    </svg>
                  )}
                  {claiming ? 'Claiming…' : 'Claim'}
                 </button>
                 </div>
              )}
              <Link
                to={`/agents/${agent.id}?tab=overview`}
                onClick={(e) => e.stopPropagation()}
                className="btn btn-secondary"
                data-testid={`agent-dossier-btn-${agent.id}`}
                style={{
                   opacity: 0.85,
                  textDecoration: 'none',
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: 3,
                }}
                title="Open full agent dossier"
              >
                <span>Dossier</span>
                <span style={{ fontSize: 10 }}>&rarr;</span>
              </Link>
              <button
                 className="btn btn-secondary"
                 style={{ opacity: 0.8 }}
                 onClick={(e) => { e.stopPropagation(); onEdit(agent) }}
                 onKeyDown={e => e.stopPropagation()}
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
  claimingAgentIds,
  onFilterChange,
  onClaim,
  onRetry,
  onReload,
  sessionTenant,
  onRegister,
}: {
  agents: AgentResponse[]
  loading: boolean
  loaded: boolean
  error: string | null
  lifecycleFilter: string
  sourceHealth?: 'healthy' | 'degraded' | 'unavailable' | null
  sourceHealthDetail?: SourceHealthMap | null
  claimingAgentIds: ReadonlySet<string>
  onFilterChange: (state: string) => void
  onClaim: (agent: AgentResponse) => void
  onRetry: () => void
  onReload: () => void
  sessionTenant?: string | null
  onRegister?: () => void
}) {
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const { getAccessTokenSilently } = useAuth0()
  // AgentsPage resolves the session tenant once and passes it down; null means
  // "not known yet", in which case no row is reported as a tenant mismatch.
  const activeSessionTenant = sessionTenant ?? null

  const resolveInitialSearch = () => {
    const s = searchParams.get('search')
    if (s) return s
    const sel = searchParams.get('selector')
    if (sel) return sel
    const selected = searchParams.get('selected')
    if (selected) return `id:${selected}`
    const id = searchParams.get('id')
    if (id) return `id:${id}`
    const sa = searchParams.get('sa')
    if (sa) return `sa:${sa}`
    const spiffe = searchParams.get('spiffe')
    if (spiffe) return `spiffe:${spiffe}`
    const inst = searchParams.get('instance')
    if (inst) return `pod:${inst}`
    return ''
  }

  const [search, setSearch] = useState(resolveInitialSearch)
  const [editingAgent, setEditingAgent] = useState<AgentResponse | null>(null)
  const [selectedAgent, setSelectedAgent] = useState<AgentResponse | null>(null)
  const [sortKey, setSortKey] = useState<string>('')
  const [sortDir, setSortDir] = useState<'asc' | 'desc' | null>(null)
  const [attentionFilter, setAttentionFilter] = useState(false)
  const [gitopsFilter, setGitopsFilter] = useState(() => searchParams.get('gitops') === 'true')
  const [tenantMismatchFilter, setTenantMismatchFilter] = useState(() => searchParams.get('mismatch') === 'true' || searchParams.get('tenant_mismatch') === 'true')
  const [unlinkedFilter, setUnlinkedFilter] = useState(() => searchParams.get('unlinked') === 'true')

  const handleSort = (key: string) => {
    if (sortKey !== key) {
      setSortKey(key)
      setSortDir('asc')
    } else if (sortDir === 'asc') {
      setSortDir('desc')
    } else {
      setSortKey('')
      setSortDir(null)
    }
  }

  // Auto-sync search from URL
  useEffect(() => {
    const s = searchParams.get('search')
    const sel = searchParams.get('selector')
    const selected = searchParams.get('selected')
    const id = searchParams.get('id')
    const sa = searchParams.get('sa')
    const spiffe = searchParams.get('spiffe')
    const inst = searchParams.get('instance')

    if (s !== null && s !== undefined) {
      setSearch(s)
    } else if (sel) {
      setSearch(sel)
    } else if (selected) {
      setSearch(`id:${selected}`)
    } else if (id) {
      setSearch(`id:${id}`)
    } else if (sa) {
      setSearch(`sa:${sa}`)
    } else if (spiffe) {
      setSearch(`spiffe:${spiffe}`)
    } else if (inst) {
      setSearch(`pod:${inst}`)
    }
  }, [searchParams])

  // The deep-link id whose direct lookup is in flight or has settled. A lookup
  // runs once per id, not once per poll, and a result only lands if its id is
  // still the current one (close, dismiss, or a list match invalidate it).
  const deepLinkLookupRef = useRef<string | null>(null)
  const [deepLinkNotice, setDeepLinkNotice] = useState<{ id: string; kind: 'not-found' | 'lookup-failed'; detail?: string } | null>(null)

  // Auto-open drawer if ?drawer=<id>, ?agent=<id>, or ?selected=<id> is in URL.
  // Exact identity only: a deep link opens the agent it names or says it was
  // not found. Never a lookalike, whether from the list or the direct lookup.
  useEffect(() => {
    const drawerId = searchParams.get('drawer') || searchParams.get('agent') || searchParams.get('selected')
    if (!drawerId) {
      deepLinkLookupRef.current = null
      setDeepLinkNotice(null)
      setSelectedAgent(prev => (prev ? null : prev))
      return
    }
    const match = agents.find(a => agentMatchesIdentity(a, drawerId))
    if (match) {
      deepLinkLookupRef.current = null
      setDeepLinkNotice(null)
      setSelectedAgent(match)
      return
    }
    // Not in the loaded list (filtered, paged, or a direct deep link): ask the
    // server for exactly this id, once, after the list has answered.
    if (!loaded || deepLinkLookupRef.current === drawerId) return
    deepLinkLookupRef.current = drawerId
    const isCurrent = () => deepLinkLookupRef.current === drawerId
    void (async () => {
      try {
        const token = await getAccessTokenSilently()
        const direct = await api.agents.get(token, drawerId)
        if (!isCurrent()) return
        if (agentMatchesIdentity(direct, drawerId)) {
          setDeepLinkNotice(null)
          setSelectedAgent(direct)
        } else {
          setDeepLinkNotice({ id: drawerId, kind: 'not-found' })
        }
      } catch (err) {
        if (!isCurrent()) return
        const e = err as { status?: number; response?: { status?: number }; message?: string }
        const status = e?.response?.status ?? e?.status
        if (status === 404) {
          setDeepLinkNotice({ id: drawerId, kind: 'not-found' })
        } else {
          setDeepLinkNotice({ id: drawerId, kind: 'lookup-failed', detail: e?.message || 'request failed' })
        }
      }
    })()
  }, [searchParams, agents, loaded, getAccessTokenSilently])

  const handleSearchChange = (val: string) => {
    setSearch(val)
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      if (val.trim()) next.set('search', val.trim())
      else next.delete('search')
      next.delete('selector')
      next.delete('id')
      next.delete('sa')
      next.delete('spiffe')
      next.delete('instance')
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

  // Every param the open-drawer effect reads. Closing must remove all of them,
  // or the effect re-reads the survivor and reopens the drawer.
  const clearDrawerParams = () => {
    deepLinkLookupRef.current = null
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      next.delete('drawer')
      next.delete('agent')
      next.delete('selected')
      return next
    }, { replace: true })
  }

  const handleCloseDrawer = () => {
    setSelectedAgent(null)
    clearDrawerParams()
  }

  const handleDismissDeepLinkNotice = () => {
    setDeepLinkNotice(null)
    clearDrawerParams()
  }

  const handleClear = () => {
    setSearch('')
    setSortKey('')
    setSortDir(null)
    setAttentionFilter(false)
    setGitopsFilter(false)
    setTenantMismatchFilter(false)
    setUnlinkedFilter(false)
    onFilterChange('all')
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      next.delete('search')
      next.delete('selector')
      next.delete('id')
      next.delete('sa')
      next.delete('spiffe')
      next.delete('instance')
      next.delete('lifecycle')
      next.delete('state')
      next.delete('drawer')
      next.delete('agent')
      next.delete('selected')
      next.delete('gitops')
      next.delete('mismatch')
      next.delete('tenant_mismatch')
      next.delete('unlinked')
      return next
    }, { replace: true })
  }

  const parsedQuery = useMemo(() => parseAgentSelectorQuery(search), [search])

  const governedAgents = useMemo(() => {
    return agents.filter(a => a.record_class !== 'discovery')
  }, [agents])

  const unlinkedCount = useMemo(
    () => governedAgents.filter((a) => a.is_registry_linked === false || a.record_class === 'discovered').length,
    [governedAgents]
  )
  const gitopsCount = useMemo(() => governedAgents.filter(hasGitOpsMetadata).length, [governedAgents])
  const tenantMismatchCount = useMemo(
    () => governedAgents.filter((a) => isAgentTenantMismatch(a, activeSessionTenant)).length,
    [governedAgents, activeSessionTenant]
  )

  const filtered = useMemo(() => {
    let list = governedAgents
    if (attentionFilter) {
      list = list.filter(isAgentAttentionRequired)
    }
    if (gitopsFilter) {
      list = list.filter(hasGitOpsMetadata)
    }
    if (tenantMismatchFilter) {
      list = list.filter((a) => isAgentTenantMismatch(a, activeSessionTenant))
    }
    if (unlinkedFilter) {
      list = list.filter((a) => a.is_registry_linked === false || a.record_class === 'discovered')
    }
    if (lifecycleFilter !== 'all') {
      const normalizedFilter = lifecycleFilter.toLowerCase()
      list = list.filter(a => {
        const s = (a.lifecycle_state || '').toLowerCase()
        return s === normalizedFilter || (
          normalizedFilter === 'governed' && (s === 'registered' || s === 'enrolled' || s === 'active' || s === 'governed')
        ) || (
          normalizedFilter === 'suspended' && (s === 'suspended' || s === 'stunned')
        ) || (
          normalizedFilter === 'revoked' && (s === 'revoked' || s === 'decommissioned')
        )
      })
    }
    if (search.trim()) {
      list = list.filter(a => matchAgentByQuery(a, parsedQuery))
    }
    return list
  }, [governedAgents, search, parsedQuery, lifecycleFilter, attentionFilter, gitopsFilter, tenantMismatchFilter, unlinkedFilter, activeSessionTenant])

  const displayAgents = useMemo(() => {
    if (!sortKey || !sortDir) return governedAgents
    const dir = sortDir === 'asc' ? 1 : -1
    return [...governedAgents].sort((a, b) => {
      if (sortKey === 'lifecycle' || sortKey === 'lifecycle_state') {
        return (a.lifecycle_state || '').localeCompare(b.lifecycle_state || '', undefined, { sensitivity: 'base' }) * dir
      }
      if (sortKey === 'last_assessed' || sortKey === 'last_observed') {
        const aTime = Date.parse(a.timestamps?.last_observed_at || '')
        const bTime = Date.parse(b.timestamps?.last_observed_at || '')
        const aValid = !Number.isNaN(aTime)
        const bValid = !Number.isNaN(bTime)
        if (!aValid && !bValid) return 0
        if (!aValid) return 1
        if (!bValid) return -1
        return (aTime - bTime) * dir
      }
      if (sortKey === 'name') {
        return (a.name || '').localeCompare(b.name || '', undefined, { sensitivity: 'base' }) * dir
      }
      if (sortKey === 'runtime') {
        const aFw = getAgentFramework(a)
        const bFw = getAgentFramework(b)
        const cmp = aFw.localeCompare(bFw, undefined, { sensitivity: 'base' })
        if (cmp !== 0) return cmp * dir
        const aNs = a.runtime?.namespace || a.namespace || 'default'
        const bNs = b.runtime?.namespace || b.namespace || 'default'
        return aNs.localeCompare(bNs, undefined, { sensitivity: 'base' }) * dir
      }
      if (sortKey === 'responsibility') {
        const aOwner = a.responsibility?.owner_name || a.owner || ''
        const bOwner = b.responsibility?.owner_name || b.owner || ''
        return aOwner.localeCompare(bOwner, undefined, { sensitivity: 'base' }) * dir
      }
      if (sortKey === 'attention') {
        const aFail = a.compliance_summary?.failing ?? 0
        const bFail = b.compliance_summary?.failing ?? 0
        return (aFail - bFail) * dir
      }
      return 0
    })
  }, [governedAgents, sortKey, sortDir])

  const lifecycleCounts = useMemo(() => Object.fromEntries(
    LIFECYCLE_OPTIONS.map((state) => {
      if (state === 'all') return [state, governedAgents.length]
      const normalizedFilter = state.toLowerCase()
      const count = governedAgents.filter((agent) => {
        const s = (agent.lifecycle_state || '').toLowerCase()
        return s === normalizedFilter || (
          normalizedFilter === 'governed' && (s === 'registered' || s === 'enrolled' || s === 'active' || s === 'governed')
        ) || (
          normalizedFilter === 'suspended' && (s === 'suspended' || s === 'stunned')
        ) || (
          normalizedFilter === 'revoked' && (s === 'revoked' || s === 'decommissioned')
        )
      }).length
      return [state, count]
    })
  ), [governedAgents])

  const phase = error ? 'error' : loadPhase({ loading: loading && !loaded, loaded })
  if (!loaded && (phase === 'loading' || phase === 'idle' || phase === 'error')) {
    return <LoadingState variant="block" status={phase} label="agents" error={error} onRetry={onRetry} testId="agents-load-state" />
  }

  const TH_STYLE: React.CSSProperties = {
    padding: '11px 16px', textAlign: 'left', color: 'var(--muted)',
    fontWeight: 600, fontSize: 11, textTransform: 'uppercase',
    letterSpacing: '0.06em', whiteSpace: 'nowrap',
  }

  return (
    <div style={{ width: '100%' }}>
      {editingAgent && <EditAgentModal agent={editingAgent} onClose={() => setEditingAgent(null)} onSaved={onReload} />}
      {selectedAgent && (
        <AgentEvidenceDrawer
          agent={selectedAgent}
          sourceHealth={sourceHealth}
          sourceHealthDetail={sourceHealthDetail}
          onClose={handleCloseDrawer}
          onOpenFullRecord={(id) => navigate(`/agents/${id}?tab=overview`)}
          onEdit={(agent) => {
            setSelectedAgent(null)
            clearDrawerParams()
            setEditingAgent(agent)
          }}
        />
      )}
      {deepLinkNotice && (
        <div
          role="status"
          data-testid={deepLinkNotice.kind === 'not-found' ? 'agent-deeplink-not-found' : 'agent-deeplink-lookup-failed'}
          style={{
            display: 'flex', alignItems: 'center', gap: 10, marginBottom: 12, padding: '10px 14px',
            border: '1px solid var(--border)', borderRadius: 8, background: 'var(--surface2)', color: 'var(--text)', fontSize: 13,
          }}
        >
          <span style={{ flex: 1 }}>
            {deepLinkNotice.kind === 'not-found'
              ? <>No agent matches <code>{deepLinkNotice.id}</code>. No drawer was opened.</>
              : <>Could not look up agent <code>{deepLinkNotice.id}</code>: {deepLinkNotice.detail}. No drawer was opened.</>}
          </span>
          <button
            type="button"
            className="btn"
            aria-label="Dismiss agent link notice"
            data-testid={deepLinkNotice.kind === 'not-found' ? 'agent-deeplink-not-found-dismiss' : 'agent-deeplink-lookup-failed-dismiss'}
            onClick={handleDismissDeepLinkNotice}
          >
            Dismiss
          </button>
        </div>
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
        {parsedQuery.isStructured && (
          <div
            data-testid="active-selector-badge"
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: 6,
              padding: '4px 8px',
              borderRadius: 4,
              background: 'rgba(0, 210, 255, 0.12)',
              border: '1px solid var(--cyan)',
              fontSize: 12,
              color: 'var(--cyan)',
            }}
          >
            <span>
              <strong>Selector:</strong> {parsedQuery.clauses.map((c) => c.raw).join(' ')}
            </span>
            <button
              type="button"
              data-testid="clear-selector-button"
              onClick={() => handleSearchChange('')}
              style={{
                background: 'transparent',
                border: 'none',
                color: 'var(--cyan)',
                cursor: 'pointer',
                padding: '0 2px',
                fontWeight: 'bold',
                lineHeight: 1,
              }}
              title="Clear selector"
              aria-label="Clear selector"
            >
              ×
            </button>
          </div>
        )}
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
        <div className="sl-filter-chips" role="group" aria-label="Filter agents by registry link, review, GitOps and tenant">
          <button
            type="button"
            className="sl-filter-chip"
            data-testid="agent-unlinked-filter-btn"
            aria-pressed={unlinkedFilter}
            onClick={() => setUnlinkedFilter((prev) => !prev)}
          >
            <span aria-hidden="true" className="sl-filter-dot sl-filter-dot--unlinked" />
            Unlinked
            <span className="sl-filter-chip__count">{unlinkedCount}</span>
          </button>
          <button
            type="button"
            className="sl-filter-chip"
            data-testid="agent-attention-filter-btn"
            aria-pressed={attentionFilter}
            onClick={() => setAttentionFilter((prev) => !prev)}
            style={attentionFilter ? { borderColor: colors.red, color: colors.red } : undefined}
          >
            <span aria-hidden="true" className="sl-filter-dot" style={{ background: colors.red }} />
            Needs review
            <span className="sl-filter-chip__count" style={attentionFilter ? { color: colors.red } : undefined}>
              {deriveAgentReview(governedAgents).affectedAgentCount}
            </span>
          </button>
          <button
            type="button"
            className="sl-filter-chip"
            data-testid="agent-gitops-filter-btn"
            aria-pressed={gitopsFilter}
            onClick={() => setGitopsFilter((prev) => !prev)}
            style={gitopsFilter ? { borderColor: colors.cyanLoom, color: colors.cyanLoom } : undefined}
          >
            <span aria-hidden="true" className="sl-filter-dot" style={{ background: colors.cyanLoom }} />
            GitOps Managed
            <span className="sl-filter-chip__count" style={gitopsFilter ? { color: colors.cyanLoom } : undefined}>
              {gitopsCount}
            </span>
          </button>
          <button
            type="button"
            className="sl-filter-chip"
            data-testid="agent-tenant-mismatch-filter-btn"
            aria-pressed={tenantMismatchFilter}
            onClick={() => setTenantMismatchFilter((prev) => !prev)}
            style={tenantMismatchFilter ? { borderColor: colors.amber, color: colors.amber } : undefined}
          >
            <span aria-hidden="true" className="sl-filter-dot" style={{ background: colors.amber }} />
            Tenant Mismatch
            <span className="sl-filter-chip__count" style={tenantMismatchFilter ? { color: colors.amber } : undefined}>
              {tenantMismatchCount}
            </span>
          </button>
        </div>
        {(search || lifecycleFilter !== 'all' || attentionFilter || gitopsFilter || tenantMismatchFilter || unlinkedFilter || sortKey) && (
          <button
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '4px 12px', borderRadius: 999 }}
            onClick={handleClear}
          >
            Clear
          </button>
        )}
      </div>

      {filtered.length === 0 ? (
        agents.length === 0 ? (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12, padding: 40 }}>
            <EmptyState
              kicker="No governed agents"
              body="Agents appear here after enrollment via the registry API."
            />
            <div style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap', justifyContent: 'center' }}>
              <button className="btn btn-primary" onClick={onRegister}>Register Agent</button>
              <Link to="/settings/help/onboard-agent" className="btn btn-secondary" style={{ textDecoration: 'none' }}>
                Help to Onboard Agent
              </Link>
              <Link to="/settings/help/deploy-sensor" className="btn btn-secondary" style={{ textDecoration: 'none' }}>
                Help to Deploy Sensor
              </Link>
            </div>
          </div>
        ) : (
          <EmptyState kicker="No agents match your filter" body="Try clearing the search or changing the state filter." />
        )
      ) : (
        <CompactOperationalTable label="Governed agents table">
            <thead>
              <tr style={{ background: 'var(--surface2)', borderBottom: '1px solid var(--border)' }}>
                <th
                  style={{ ...TH_STYLE, cursor: 'pointer', userSelect: 'none' }}
                  onClick={() => handleSort('name')}
                  data-testid="sort-header-name"
                >
                  <div style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                    <span>Agent</span>
                    <span style={{ color: sortKey === 'name' ? 'var(--cyan)' : 'var(--border)', fontSize: 10 }}>
                      {sortKey === 'name' ? (sortDir === 'asc' ? '▲' : '▼') : '⇅'}
                    </span>
                  </div>
                </th>
                <th
                  style={{ ...TH_STYLE, cursor: 'pointer', userSelect: 'none' }}
                  onClick={() => handleSort('runtime')}
                  data-testid="sort-header-runtime"
                >
                  <div style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                    <span>Runtime</span>
                    <span style={{ color: sortKey === 'runtime' ? 'var(--cyan)' : 'var(--border)', fontSize: 10 }}>
                      {sortKey === 'runtime' ? (sortDir === 'asc' ? '▲' : '▼') : '⇅'}
                    </span>
                  </div>
                </th>
                <th
                  style={{ ...TH_STYLE, cursor: 'pointer', userSelect: 'none' }}
                  onClick={() => handleSort('responsibility')}
                  data-testid="sort-header-responsibility"
                >
                  <div style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                    <span>Responsibility</span>
                    <span style={{ color: sortKey === 'responsibility' ? 'var(--cyan)' : 'var(--border)', fontSize: 10 }}>
                      {sortKey === 'responsibility' ? (sortDir === 'asc' ? '▲' : '▼') : '⇅'}
                    </span>
                  </div>
                </th>
                <th
                  style={{ ...TH_STYLE, cursor: 'pointer', userSelect: 'none' }}
                  onClick={() => handleSort('lifecycle')}
                  data-testid="sort-header-lifecycle"
                >
                  <div style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                    <span>Operational State</span>
                    <span style={{ color: sortKey === 'lifecycle' ? 'var(--cyan)' : 'var(--border)', fontSize: 10 }}>
                      {sortKey === 'lifecycle' ? (sortDir === 'asc' ? '▲' : '▼') : '⇅'}
                    </span>
                  </div>
                </th>
                <th
                  style={{ ...TH_STYLE, cursor: 'pointer', userSelect: 'none' }}
                  onClick={() => handleSort('attention')}
                  data-testid="sort-header-attention"
                >
                  <div style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                    <span>Attention</span>
                    <span style={{ color: sortKey === 'attention' ? 'var(--cyan)' : 'var(--border)', fontSize: 10 }}>
                      {sortKey === 'attention' ? (sortDir === 'asc' ? '▲' : '▼') : '⇅'}
                    </span>
                  </div>
                </th>
                <th style={TH_STYLE}>Identity & Evidence</th>
                <th
                  style={{ ...TH_STYLE, cursor: 'pointer', userSelect: 'none' }}
                  onClick={() => handleSort('last_assessed')}
                  aria-label="Observed"
                  data-testid="sort-header-last-assessed"
                >
                  <div style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                    <span>Seen</span>
                    <span style={{ color: sortKey === 'last_assessed' ? 'var(--cyan)' : 'var(--border)', fontSize: 10 }}>
                      {sortKey === 'last_assessed' ? (sortDir === 'asc' ? '▲' : '▼') : '⇅'}
                    </span>
                  </div>
                </th>
                <th style={TH_STYLE}>Actions</th>
              </tr>
            </thead>
            {displayAgents.map((a) => {
              const shown = filtered.some((agent) => agent.id === a.id)
              return (
                <AgentTableRow
                  key={a.id}
                  agent={a}
                  shown={shown}
                  claiming={claimingAgentIds.has(a.id)}
                  onSelect={handleSelectAgent}
                  onEdit={setEditingAgent}
                  onClaim={onClaim}
                />
              )
            })}
        </CompactOperationalTable>
      )}

      {filtered.length > 0 && (
        <div aria-live="polite" style={{ marginTop: 12, fontSize: 12, color: 'var(--muted)', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <span>Showing {filtered.length} of {governedAgents.length} agent{governedAgents.length !== 1 ? 's' : ''}</span>
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
  const { user, getAccessTokenSilently } = useAuth0()
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const activeMainTab = searchParams.get('tab') === 'coding-agents' ? 'coding-agents' : 'governed'

  const [sessionTenant, setSessionTenant] = useState<string | null>(null)
  const serverTenant = useServerTenant(getAccessTokenSilently)

  useEffect(() => {
    let isMounted = true
    getAccessTokenSilently()
      .then((token) => {
        if (!isMounted || !token) return
        const fromToken = getTenantIdFromToken(token)
        if (fromToken) {
          setSessionTenant(fromToken)
        }
      })
      .catch(() => {})
    return () => {
      isMounted = false
    }
  }, [getAccessTokenSilently])

  const activeSessionTenant = useMemo(() => {
    const fromUrl = searchParams.get('tenant')
    if (fromUrl) return fromUrl
    const userTenant = (user as any)?.['https://signalloom.ai/tenant_id'] ??
      (user as any)?.tenant_id ??
      (user as any)?.tenant ??
      (user as any)?.org_id
    if (userTenant) return String(userTenant)
    if (sessionTenant) return sessionTenant
    const stored = getSafeStorageItem('signalloom_tenant') ||
      getSafeStorageItem('signalloom:active-tenant')
    if (stored) return stored
    // No explicit selection: the server's tenant for this principal
    // (GET /api/v1/me, from API_SUBJECT_TENANTS). Never guessed from the email
    // domain; until the server answers the tenant is unknown (null) and no
    // row is reported as a mismatch against an invented value.
    return serverTenant
  }, [searchParams, user, sessionTenant, serverTenant])

  const [agents, setAgents] = useState<AgentResponse[]>([])

  const [meta, setMeta] = useState<AgentListMeta | null>(null)
  const [sourceHealth, setSourceHealth] = useState<'healthy' | 'degraded' | 'unavailable' | null>('healthy')
  const [sourceHealthDetail, setSourceHealthDetail] = useState<SourceHealthMap | null>(null)
  const [lastRefresh, setLastRefresh] = useState<string | null>(null)

  const [agentsLoading, setAgentsLoading] = useState(true)
  const [agentsLoaded, setAgentsLoaded] = useState(false)
  const [agentsError, setAgentsError] = useState<string | null>(null)
  const claimingIdsRef = useRef(new Set<string>())
  const mutationRevisionRef = useRef(0)
  const [claimingAgentIds, setClaimingAgentIds] = useState<ReadonlySet<string>>(new Set())
  const [claimNotification, setClaimNotification] = useState<ClaimNotification | null>(null)

  const [lifecycleFilter, setLifecycleFilter] = useState('all')
  const [showRegister, setShowRegister] = useState(false)

  const [scanning, setScanning] = useState(false)
  const [lastScanTimestamp, setLastScanTimestamp] = useState<string | null>(null)

  const loadAgents = useCallback(async () => {
    const revisionAtStart = mutationRevisionRef.current
    setAgentsLoading(true)
    try {
      const token = await getAccessTokenSilently()
      const data = await api.agents.list(token)
      if (revisionAtStart !== mutationRevisionRef.current) return
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

  const handleAutoClaim = useCallback(async (agent: AgentResponse) => {
    if (claimingIdsRef.current.has(agent.id)) return

    claimingIdsRef.current.add(agent.id)
    setClaimingAgentIds(new Set(claimingIdsRef.current))
    setClaimNotification(null)

    try {
      const token = await getAccessTokenSilently()
      const claimantOwner = user?.email || user?.name || user?.sub || undefined
      const result = await claimDiscoveredAgent(token, agent.id, buildClaimRequest(agent, claimantOwner))
      if (result.status !== 'granted') {
        throw new Error(`Claim was ${result.status}.`)
      }

      mutationRevisionRef.current += 1
      setAgents(current => current.map(item => item.id === agent.id
        ? { ...item, record_class: 'resolved', is_registry_linked: true }
        : item))
      setMeta(current => current ? {
        ...current,
        discovered_count: Math.max(0, current.discovered_count - 1),
        resolved_count: current.resolved_count + 1,
      } : current)

      let claimedAgent: AgentResponse
      try {
        claimedAgent = await api.agents.get(token, result.agent_id)
      } catch (error) {
        const detail = error instanceof Error ? error.message : 'Unknown refresh error'
        setClaimNotification({
          kind: 'error',
          message: `${agent.name} was claimed, but refreshed governance evidence could not be loaded: ${detail}`,
        })
        return
      }

      const resolvedAgent: AgentResponse = {
        ...claimedAgent,
        record_class: 'resolved',
        is_registry_linked: true,
      }
      setAgents(current => current.map(item => item.id === agent.id ? resolvedAgent : item))
      setClaimNotification({
        kind: 'success',
        message: `${agent.name} claimed into governance successfully.`,
      })
      await loadAgents()
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : 'Unknown error'
      // Instead of displaying a transient toast popup, navigate directly to the agent's onboarding tab with the claim error details
      navigate(`/agents/${encodeURIComponent(agent.id)}?tab=onboarding&claim_error=${encodeURIComponent(errorMsg)}`)
    } finally {
      claimingIdsRef.current.delete(agent.id)
      setClaimingAgentIds(new Set(claimingIdsRef.current))
    }
  }, [getAccessTokenSilently, loadAgents, user])

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

  const review = useMemo(() => deriveAgentReview(agents), [agents])

  const totalAssessed = agents.filter(a => a.compliance_summary.total_controls > 0).length

  return (
    <div>
      {showRegister && <RegisterModal onClose={() => setShowRegister(false)} onCreated={loadAgents} />}
      {claimNotification && (
        <div
          data-testid="agent-claim-toast"
          role={claimNotification.kind === 'success' ? 'status' : 'alert'}
          aria-live={claimNotification.kind === 'success' ? 'polite' : undefined}
          aria-atomic="true"
          className="card"
          style={{
            position: 'fixed',
            top: 20,
            right: 20,
            zIndex: 1200,
            maxWidth: 420,
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
            status={agentsError ? 'error' : loadPhase({ loading: agentsLoading && !agentsLoaded, loaded: agentsLoaded })}
            timestamp={!agentsError && lastRefresh ? Date.parse(lastRefresh) : undefined}
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
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '6px 14px' }}
            disabled={scanning}
            onClick={handleComplianceScan}
          >
            {scanning ? 'Scanning...' : 'Scan Compliance'}
          </button>
          <HelpHint label="About the policy scan" testId="agents-scan-help">
            Runs a live policy scan against the governed agent list and updates posture and compliance findings.
          </HelpHint>
          {activeMainTab === 'governed' && (
            <button
              type="button"
              className="btn btn-primary"
              data-testid="header-register-agent-btn"
              style={{ fontSize: 12, padding: '6px 14px' }}
              onClick={() => setShowRegister(true)}
            >
              Register Agent
            </button>
          )}
        </div>
      </div>

      {/* Subnavigation Tabs */}
      <div
        role="tablist"
        aria-label="Agent view selection"
        style={{
          display: 'flex',
          gap: 6,
          borderBottom: '1px solid var(--border)',
          marginBottom: 20,
        }}
      >
        <Link
          to="/agents"
          role="tab"
          aria-selected={activeMainTab === 'governed'}
          data-testid="tab-governed-agents"
          className={`btn btn-sm ${activeMainTab === 'governed' ? 'btn-primary' : 'btn-secondary'}`}
          onClick={() => {
            setSearchParams(prev => {
              const next = new URLSearchParams(prev)
              next.delete('tab')
              return next
            })
          }}
          style={{
            borderRadius: '6px 6px 0 0',
            borderBottom: activeMainTab === 'governed' ? '2px solid var(--cyan)' : 'none',
            fontSize: 12,
            padding: '6px 14px',
            textDecoration: 'none',
            display: 'inline-flex',
            alignItems: 'center',
          }}
        >
          Governed Workloads ({agents.length})
        </Link>

        <Link
          to="/agents?tab=coding-agents"
          role="tab"
          aria-selected={activeMainTab === 'coding-agents'}
          data-testid="tab-coding-agents"
          className={`btn btn-sm ${activeMainTab === 'coding-agents' ? 'btn-primary' : 'btn-secondary'}`}
          onClick={() => {
            setSearchParams(prev => {
              const next = new URLSearchParams(prev)
              next.set('tab', 'coding-agents')
              return next
            })
          }}
          style={{
            borderRadius: '6px 6px 0 0',
            borderBottom: activeMainTab === 'coding-agents' ? '2px solid var(--cyan)' : 'none',
            fontSize: 12,
            padding: '6px 14px',
            textDecoration: 'none',
            display: 'inline-flex',
            alignItems: 'center',
          }}
        >
          Detected Coding Agents (Host Detective)
        </Link>
      </div>

      {activeMainTab === 'coding-agents' ? (
        <CodingAgentsTab
          initialHarness={searchParams.get('harness') || undefined}
          initialTaskId={searchParams.get('task_id') || undefined}
        />
      ) : (
        <>
          {/* Top 4 StatCards */}
          {agentsLoaded && agents.length > 0 && (
            <AgentStatCards
              agents={agents}
              meta={meta}
              sourceHealth={sourceHealth}
              sourceHealthDetail={sourceHealthDetail}
            />
          )}

          <AgentReviewQueue review={review} loading={agentsLoading} loaded={agentsLoaded} error={agentsError} sourceHealth={sourceHealth} lastRefresh={lastRefresh} onRetry={loadAgents} />

          <SignalSummaryPanel />

          <GovernedTab
            agents={agents}
            loading={agentsLoading}
            loaded={agentsLoaded}
            error={agentsError}
            lifecycleFilter={lifecycleFilter}
            sourceHealth={sourceHealth}
            sourceHealthDetail={sourceHealthDetail}
            claimingAgentIds={claimingAgentIds}
            onFilterChange={setLifecycleFilter}
            onClaim={handleAutoClaim}
            onRetry={loadAgents}
            onReload={loadAgents}
            sessionTenant={activeSessionTenant}
            onRegister={() => setShowRegister(true)}
          />
        </>
      )}
    </div>
  )
}
