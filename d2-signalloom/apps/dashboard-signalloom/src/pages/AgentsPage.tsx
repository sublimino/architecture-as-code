// Filter interaction adapted from Beautiful UI Filter Table (MIT); see
// THIRD_PARTY_NOTICES.md. Signal Loom owns data, tokens, and semantics.
// TODO: migrate table to DataTable (1 table with search/lifecycle filtering)
import { useState, useEffect, useCallback, useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { PieChart, Pie, Cell, Label } from 'recharts'
import { api } from '../api/client'
import { LIVE_POLL_MS } from '../api/pollInterval'
import type { AgentResponse } from '../types/api'
import { colors, donutDefaults } from '../styles/tokens'
import StatusBadge from '../components/StatusBadge'
import CredentialStateNotice from '../components/CredentialStateNotice'
import EmptyState from '../components/EmptyState'
import LoadingState, { loadPhase } from '../components/LoadingState'
import HelpHint from '../components/HelpHint'

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
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Update failed.')
      setSubmitting(false)
    }
  }

  return (
    <div style={{
      position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.7)', zIndex: 1000,
      display: 'flex', alignItems: 'center', justifyContent: 'center'
    }} onClick={e => e.target === e.currentTarget && onClose()}>
      <div className="card" style={{ width: 440, padding: 24, position: 'relative' }}>
        <h3 style={{ marginBottom: 6 }}>Edit Agent</h3>
        <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 16, lineHeight: 1.5 }}>
          Update this agent's metadata. Name and type are read-only after registration.
        </p>
        <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          <div>
            <label style={{ display: 'block', fontSize: 12, marginBottom: 4, color: 'var(--muted)' }}>Name</label>
            <input value={agent.name} disabled style={{ width: '100%', opacity: 0.6 }} />
          </div>
          <div>
            <label style={{ display: 'block', fontSize: 12, marginBottom: 4, color: 'var(--muted)' }}>Type</label>
            <input value={agent.type ?? ''} disabled style={{ width: '100%', opacity: 0.6 }} />
          </div>
          <div>
            <label style={{ display: 'block', fontSize: 12, marginBottom: 4, color: 'var(--muted)' }}>State</label>
            <StatusBadge status={agent.lifecycle_state} variant="lifecycle" />
          </div>
          <div>
            <label style={{ display: 'block', fontSize: 12, marginBottom: 4 }}>Owner (email or name)</label>
            <input value={owner} onChange={e => setOwner(e.target.value)} style={{ width: '100%' }} />
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

function agentComplianceStatus(a: AgentResponse): string {
  const { failing, passing, posture_score } = a.compliance_summary
  if (failing > 0) return 'non_compliant'
  if (passing > 0 && posture_score !== null) return 'compliant'
  return 'pending'
}

// ─── PostureBar ──────────────────────────────────────────────────────────────

function PostureBar({ score }: { score: number | null }) {
  if (score === null) return <span style={{ color: 'var(--muted)', fontSize: 12 }}>—</span>
  const color = score >= 80 ? colors.tealLoom : score >= 50 ? colors.amber : colors.red
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      <div style={{ width: 72, height: 5, background: 'var(--border-subtle)', borderRadius: 3, overflow: 'hidden' }}>
        <div style={{ width: `${score}%`, height: '100%', background: color, borderRadius: 3, transition: 'width 0.4s' }} />
      </div>
      <span style={{ fontSize: 12, color, fontWeight: 600, minWidth: 28 }}>{score}%</span>
    </div>
  )
}

// ─── Lifecycle Donut (Recharts) ───────────────────────────────────────────────

interface PieEntry { name: string; label: string; value: number; color: string }

export const DONUT_COLORS = {
  active: 'var(--teal)',
  enrolled: 'var(--cyan)',
  suspended: 'var(--amber)',
  revoked: 'var(--error)',
  empty: 'var(--border-subtle)',
  centreLabel: 'var(--text)',
  caption: 'var(--muted)',
} as const

function LifecyclePieChart({ agents, activeFilter, onFilter }: {
  agents: AgentResponse[]
  activeFilter: string
  onFilter: (state: string) => void
}) {
  const counts = useMemo(() => {
    const c: Record<string, number> = {}
    for (const a of agents) {
      const s = a.lifecycle_state
      c[s] = (c[s] ?? 0) + 1
    }
    return c
  }, [agents])

  const palette: PieEntry[] = [
    { name: 'active',    label: 'Active',    value: counts.active    ?? 0, color: DONUT_COLORS.active },
    { name: 'enrolled',  label: 'Enrolled',  value: counts.enrolled  ?? 0, color: DONUT_COLORS.enrolled },
    { name: 'suspended', label: 'Suspended', value: counts.suspended ?? 0, color: DONUT_COLORS.suspended },
    { name: 'revoked',   label: 'Revoked',   value: counts.revoked   ?? 0, color: DONUT_COLORS.revoked },
  ]
  const data = palette.filter(d => d.value > 0)
  const total = agents.length
  const empty = [{ name: 'none', value: 1, color: DONUT_COLORS.empty, label: '' }]

  const renderCenter = ({ viewBox }: { viewBox?: unknown }) => {
    const vb = viewBox as { cx?: number; cy?: number } | undefined
    const cx = vb?.cx ?? 90
    const cy = vb?.cy ?? 90
    return (
      <g>
        <text x={cx} y={cy - 6} textAnchor="middle" fill={DONUT_COLORS.centreLabel}
          fontSize={22} fontWeight={700} fontFamily="Arial, sans-serif">{total}</text>
        <text x={cx} y={cy + 13} textAnchor="middle" fill={DONUT_COLORS.caption}
          fontSize={11} fontFamily="Arial, sans-serif">agents</text>
      </g>
    )
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14 }}>
      <PieChart width={180} height={180}>
        <Pie
          data={data.length > 0 ? data : empty}
          cx={90} cy={90}
          innerRadius={54} outerRadius={78}
          dataKey="value"
          paddingAngle={donutDefaults.paddingAngle}
          cornerRadius={donutDefaults.cornerRadius}
          stroke={donutDefaults.stroke}
          onClick={data.length > 0 ? (entry: unknown) => {
            const e = entry as PieEntry
            onFilter(activeFilter === e.name ? 'all' : e.name)
          } : undefined}
          style={{ cursor: data.length > 0 ? 'pointer' : 'default' }}
        >
          {(data.length > 0 ? data : empty).map((entry, i) => (
            <Cell
              key={i}
              fill={entry.color}
              opacity={activeFilter === 'all' || activeFilter === entry.name ? 1 : 0.35}
            />
          ))}
          <Label content={renderCenter} position="center" />
        </Pie>
      </PieChart>

      <div style={{ width: '100%', display: 'flex', flexDirection: 'column', gap: 4 }}>
        {palette.filter(d => d.value > 0).map((d) => (
          <button
            key={d.name}
            onClick={() => onFilter(activeFilter === d.name ? 'all' : d.name)}
            style={{
              display: 'flex', alignItems: 'center', gap: 8,
              background: activeFilter === d.name ? 'rgba(255,255,255,0.06)' : 'none',
              border: 'none', cursor: 'pointer', fontSize: 12, color: 'var(--muted)',
              padding: '4px 8px', borderRadius: 6, width: '100%',
              transition: 'background 0.12s',
            }}
          >
            <span style={{ width: 10, height: 10, borderRadius: 2, background: d.color, flexShrink: 0 }} />
            <span style={{ flex: 1, textAlign: 'left' }}>{d.label}</span>
            <span style={{ color: d.color, fontWeight: 700 }}>{d.value}</span>
          </button>
        ))}
      </div>
    </div>
  )
}

// ─── Attention Required ──────────────────────────────────────────────────────

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
        <span style={{ fontSize: 13, fontWeight: 700, color: colors.red }}>Attention Required</span>
        <span style={{
          background: colors.red, color: 'var(--on-accent)', borderRadius: 99,
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
              color: a.severity === 'critical' ? colors.red : colors.amber,
              fontSize: 12, fontWeight: 500, cursor: 'pointer',
              fontFamily: 'inherit', transition: 'opacity 0.15s',
            }}
          >
            <span style={{
              background: a.severity === 'critical' ? colors.red : colors.amber,
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

// ─── Governed Tab ────────────────────────────────────────────────────────────

const LIFECYCLE_OPTIONS = ['all', 'active', 'enrolled', 'suspended', 'revoked']

const LIFECYCLE_LABELS: Record<string, string> = {
  all: 'All states',
  active: 'Active',
  enrolled: 'Enrolled',
  suspended: 'Suspended',
  revoked: 'Revoked',
}

const LIFECYCLE_TOOLTIP: Record<string, string> = {
  enrolled: 'Registered but not yet activated — cannot authenticate until transitioned to active.',
  active: 'Active and authorized to operate.',
  suspended: 'Temporarily suspended — reversible; credentials refused until reinstated.',
  revoked: 'Permanently revoked — terminal state; credentials refused.',
}

function AgentTableRow({ agent, onNavigate, onEdit }: {
  agent: AgentResponse
  onNavigate: (id: string) => void
  onEdit: (agent: AgentResponse) => void
}) {
  const hasViolations = agent.compliance_summary.failing > 0
  const compStatus = agentComplianceStatus(agent)

  return (
    <tr
      onClick={() => onNavigate(agent.id)}
      style={{ borderBottom: '1px solid var(--border)', cursor: 'pointer', transition: 'background 0.1s' }}
      onMouseEnter={(e) => (e.currentTarget.style.background = 'rgba(255,255,255,0.03)')}
      onMouseLeave={(e) => (e.currentTarget.style.background = 'transparent')}
    >
      <td style={{ padding: '11px 16px', maxWidth: 200 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 0 }}>
          <span style={{ fontWeight: 500, fontSize: 13 }}>{agent.name || 'Unnamed agent'}</span>
          {hasViolations && (
            <span
              title="Unacknowledged violation"
              style={{
                display: 'inline-block', width: 7, height: 7,
                background: colors.red, borderRadius: '50%', marginLeft: 7, flexShrink: 0,
              }}
            />
          )}
        </div>
        <div
          title={`Agent ID: ${agent.id}`}
          style={{ fontSize: 11, color: 'var(--muted)', marginTop: 1, fontFamily: 'monospace' }}
        >
          ID: {agent.id.split('-')[0]}…
        </div>
      </td>
      <td style={{ padding: '11px 16px', fontSize: 12, color: 'var(--muted)' }}>
        {agent.type ?? '—'}
      </td>
      <td style={{ padding: '11px 16px', fontSize: 12, color: 'var(--muted)' }}>
        {agent.owner ?? '—'}
      </td>
      <td style={{ padding: '11px 16px' }}>
        <span title={LIFECYCLE_TOOLTIP[agent.lifecycle_state] ?? undefined}>
          <StatusBadge status={agent.lifecycle_state} variant="lifecycle" />
        </span>
      </td>
      <td style={{ padding: '11px 16px' }}>
        {/* "suspended" is a governance verdict; this says what it means. */}
        <CredentialStateNotice
          credentialState={agent.credential_state}
          agentName={agent.name}
          variant="inline"
        />
      </td>
      <td style={{ padding: '11px 16px' }}>
        {agent.eu_ai_act_risk_class ? (
          <StatusBadge status={agent.eu_ai_act_risk_class} variant="risk" />
        ) : (
          <span style={{ fontSize: 12, color: 'var(--muted)' }}>—</span>
        )}
      </td>
      <td style={{ padding: '11px 16px' }}>
        <StatusBadge status={compStatus} variant="compliance" />
      </td>
      <td style={{ padding: '11px 16px' }}>
        <PostureBar score={agent.compliance_summary.posture_score} />
      </td>
      <td style={{ padding: '11px 16px', fontSize: 12, color: 'var(--muted)', whiteSpace: 'nowrap' }}>
        {fmtRelative(agent.last_transition_at)}
      </td>
      <td style={{ padding: '11px 16px', textAlign: 'right' }}>
        <button
          className="btn btn-secondary"
          style={{ fontSize: 11, padding: '4px 10px' }}
          onClick={(e) => { e.stopPropagation(); onEdit(agent) }}
        >
          Edit
        </button>
      </td>
    </tr>
  )
}

function GovernedTab({ agents, loading, loaded, error, onRetry, onReload }: {
  agents: AgentResponse[]
  loading: boolean
  loaded: boolean
  error: string | null
  onRetry: () => void
  onReload: () => void
}) {
  const navigate = useNavigate()
  const [search, setSearch] = useState('')
  const [lifecycleFilter, setLifecycleFilter] = useState('all')
  const [showRegister, setShowRegister] = useState(false)
  const [editingAgent, setEditingAgent] = useState<AgentResponse | null>(null)

  const filtered = useMemo(() => {
    let list = agents
    if (lifecycleFilter !== 'all') list = list.filter(a => a.lifecycle_state === lifecycleFilter)
    if (search.trim()) {
      const q = search.toLowerCase()
      list = list.filter(a =>
        (a.name ?? '').toLowerCase().includes(q) ||
        a.id.toLowerCase().includes(q) ||
        (a.type ?? '').toLowerCase().includes(q) ||
        (a.owner ?? '').toLowerCase().includes(q)
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
    padding: '9px 16px', textAlign: 'left', color: 'var(--muted)',
    fontWeight: 600, fontSize: 11, textTransform: 'uppercase',
    letterSpacing: '0.05em', whiteSpace: 'nowrap',
  }

  return (
    <div style={{ display: 'flex', gap: 20, alignItems: 'flex-start' }}>
      {showRegister && <RegisterModal onClose={() => setShowRegister(false)} onCreated={onReload} />}
      {editingAgent && <EditAgentModal agent={editingAgent} onClose={() => setEditingAgent(null)} onSaved={onReload} />}

      {/* Donut + legend */}
      <div className="card" style={{ width: 210, minWidth: 210, padding: '20px 16px', flexShrink: 0 }}>
        <LifecyclePieChart
          agents={agents}
          activeFilter={lifecycleFilter}
          onFilter={setLifecycleFilter}
        />
      </div>

      {/* Table */}
      <div style={{ flex: 1, minWidth: 0 }}>
        {/* Filter bar */}
        <div style={{ display: 'flex', gap: 10, marginBottom: 14, alignItems: 'center', flexWrap: 'wrap' }}>
          <input
            type="text"
            aria-label="Search agents"
            placeholder="Search agents…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            style={{ flex: 1, maxWidth: 280 }}
          />
          <div className="sl-filter-chips" role="group" aria-label="Filter agents by lifecycle state">
            {LIFECYCLE_OPTIONS.map((state) => (
              <button
                key={state}
                type="button"
                className="sl-filter-chip"
                data-testid={`agent-lifecycle-filter-${state}`}
                aria-pressed={lifecycleFilter === state}
                onClick={() => setLifecycleFilter(state)}
              >
                {LIFECYCLE_LABELS[state]}
                <span className="sl-filter-chip__count">{lifecycleCounts[state]}</span>
              </button>
            ))}
          </div>
          {(search || lifecycleFilter !== 'all') && (
            <button
              className="btn btn-secondary"
              style={{ fontSize: 12, padding: '5px 12px' }}
              onClick={() => { setSearch(''); setLifecycleFilter('all') }}
            >
              Clear
            </button>
          )}
          <button className="btn btn-primary" style={{ marginLeft: 'auto', fontSize: 12, padding: '5px 12px' }} onClick={() => setShowRegister(true)}>
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
          <div className="card" role="region" aria-label="Governed agents table" tabIndex={0} style={{ padding: 0, overflow: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
              <thead>
                <tr style={{ background: 'var(--surface2)', borderBottom: '1px solid var(--border)' }}>
                  <th style={TH_STYLE}>Name</th>
                  <th style={TH_STYLE}>Type</th>
                  <th style={TH_STYLE}>Owner</th>
                  <th style={TH_STYLE}>State</th>
                  <th style={TH_STYLE}>Credentials</th>
                  <th style={TH_STYLE}>EU AI Act</th>
                  <th style={TH_STYLE}>Compliance</th>
                  <th style={TH_STYLE}>Posture</th>
                  <th style={TH_STYLE}>Last Activity</th>
                  <th style={{ ...TH_STYLE, textAlign: 'right' }}>Actions</th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((a) => (
                  <AgentTableRow key={a.id} agent={a} onNavigate={(id) => navigate(`/agents/${id}`)} onEdit={setEditingAgent} />
                ))}
              </tbody>
            </table>
          </div>
        )}

        {filtered.length > 0 && (
          <div aria-live="polite" style={{ marginTop: 10, fontSize: 12, color: 'var(--muted)' }}>
            Showing {filtered.length} of {agents.length} agents
          </div>
        )}
      </div>
    </div>
  )
}

// ─── Main Page ───────────────────────────────────────────────────────────────

export default function AgentsPage() {
  const { getAccessTokenSilently } = useAuth0()

  const [agents, setAgents] = useState<AgentResponse[]>([])
  const [agentsLoading, setAgentsLoading] = useState(true)
  // Distinct from `agents.length > 0`: a tenant with genuinely zero agents has
  // still loaded, and must not be shown the never-loaded state.
  const [agentsLoaded, setAgentsLoaded] = useState(false)
  const [agentsError, setAgentsError] = useState<string | null>(null)

  const [scanning, setScanning] = useState(false)
  const [lastScanTimestamp, setLastScanTimestamp] = useState<string | null>(null)

  const loadAgents = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const data = await api.agents.list(token)
      setAgents(data.agents)
      setAgentsError(null)
      setAgentsLoaded(true)
    } catch (e) {
      setAgentsError(e instanceof Error ? e.message : 'Failed to load agents')
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

    const enrolledInactive = agents.filter(a => a.lifecycle_state === 'enrolled')
    if (enrolledInactive.length > 0)
      items.push({ id: 'enrolled', label: 'enrolled agents not activated', count: enrolledInactive.length, severity: 'warning', filterKey: 'enrolled' })

    const withViolations = agents.filter(a => a.compliance_summary.failing > 0)
    if (withViolations.length > 0)
      items.push({ id: 'violations', label: 'agents with new violations', count: withViolations.length, severity: 'critical' })

    const suspended = agents.filter(a => a.lifecycle_state === 'suspended')
    if (suspended.length > 0)
      items.push({ id: 'suspended', label: 'suspended agents', count: suspended.length, severity: 'warning', filterKey: 'suspended' })

    const critical = agents.filter(a => a.compliance_summary.posture_score !== null && a.compliance_summary.posture_score < 50)
    if (critical.length > 0)
      items.push({ id: 'critical', label: 'agents with critical posture', count: critical.length, severity: 'critical' })

    return items
  }, [agents])

  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 18 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <h1 style={{ fontSize: 22, fontWeight: 700, margin: 0 }}>Agents</h1>
          <HelpHint label="About governed agents" testId="agents-governed-help">Live registry records for governed workloads. During SuperCred, Cardvault appears as one enriched record rather than a duplicate.</HelpHint>
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
            <HelpHint label="About agent refresh timing" testId="agents-refresh-help">The list polls live registry state automatically. Use Scan Compliance to run an immediate policy evaluation.</HelpHint>
          </div>
          <button
            className="btn btn-primary"
            style={{ fontSize: 12, padding: '6px 14px' }}
            disabled={scanning}
            onClick={handleComplianceScan}
          >
            {scanning ? 'Scanning...' : 'Scan Compliance'}
          </button>
          <HelpHint label="About the policy scan" testId="agents-scan-help">Runs a live policy scan against the governed agent list and updates posture and compliance findings.</HelpHint>
        </div>
      </div>

      <AttentionPanel alerts={alerts} onAlert={() => undefined} />

      <GovernedTab
        agents={agents}
        loading={agentsLoading}
        loaded={agentsLoaded}
        error={agentsError}
        onRetry={loadAgents}
        onReload={loadAgents}
      />
    </div>
  )
}
