import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { PieChart, Pie, Cell, Label } from 'recharts'
import { api } from '../api/client'
import type { AgentResponse, NHIAccount, NHIScan } from '../types/api'
import { colors } from '../styles/tokens'
import StatusBadge from '../components/StatusBadge'
import EmptyState from '../components/EmptyState'
import ErrorState from '../components/ErrorState'

const POLL_MS = 15 * 60 * 1000

// ─── Register Modal ──────────────────────────────────────────────────────────

function RegisterModal({ onClose, onCreated }: { onClose: () => void, onCreated: () => void }) {
  const { getAccessTokenSilently } = useAuth0()
  const [name, setName] = useState('')
  const [type, setType] = useState('')
  const [description, setDescription] = useState('')
  const [owner, setOwner] = useState('')
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

  return (
    <div style={{
      position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.7)', zIndex: 1000,
      display: 'flex', alignItems: 'center', justifyContent: 'center'
    }} onClick={e => e.target === e.currentTarget && onClose()}>
      <div className="card" style={{ width: 400, padding: 24, position: 'relative' }}>
        <h3 style={{ marginBottom: 16 }}>Register New Agent</h3>
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
              {submitting ? 'Registering…' : 'Register Agent'}
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
    { name: 'active',    label: 'Active',    value: counts.active    ?? 0, color: colors.tealLoom },
    { name: 'enrolled',  label: 'Enrolled',  value: counts.enrolled  ?? 0, color: colors.cyanLoom },
    { name: 'suspended', label: 'Suspended', value: counts.suspended ?? 0, color: colors.amber },
    { name: 'revoked',   label: 'Revoked',   value: counts.revoked   ?? 0, color: colors.red },
  ]
  const data = palette.filter(d => d.value > 0)
  const total = agents.length
  const empty = [{ name: 'none', value: 1, color: '#334155', label: '' }]

  const renderCenter = ({ viewBox }: { viewBox?: unknown }) => {
    const vb = viewBox as { cx?: number; cy?: number } | undefined
    const cx = vb?.cx ?? 90
    const cy = vb?.cy ?? 90
    return (
      <g>
        <text x={cx} y={cy - 6} textAnchor="middle" fill={colors.electricWhite}
          fontSize={22} fontWeight={700} fontFamily="Arial, sans-serif">{total}</text>
        <text x={cx} y={cy + 13} textAnchor="middle" fill={colors.muted}
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
          stroke="none"
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
  tab: 'governed' | 'discovered'
  filterKey?: string
}

function AttentionPanel({ alerts, onAlert }: {
  alerts: AlertItem[]
  onAlert: (tab: 'governed' | 'discovered', filterKey?: string) => void
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
          background: colors.red, color: '#fff', borderRadius: 99,
          fontSize: 10, fontWeight: 700, padding: '1px 7px',
        }}>{alerts.length}</span>
      </div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
        {alerts.map((a) => (
          <button
            key={a.id}
            onClick={() => onAlert(a.tab, a.filterKey)}
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
              color: '#fff', borderRadius: 99, fontSize: 10,
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

function AgentTableRow({ agent, onNavigate }: { agent: AgentResponse; onNavigate: (id: string) => void }) {
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
        <StatusBadge status={agent.lifecycle_state} variant="lifecycle" />
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
    </tr>
  )
}

function GovernedTab({ agents, loading, error, onRetry, onReload }: {
  agents: AgentResponse[]
  loading: boolean
  error: string | null
  onRetry: () => void
  onReload: () => void
}) {
  const navigate = useNavigate()
  const [search, setSearch] = useState('')
  const [lifecycleFilter, setLifecycleFilter] = useState('all')
  const [showRegister, setShowRegister] = useState(false)

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

  if (loading) return <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 64 }}>Loading…</div>
  if (error) return <ErrorState message={error} onRetry={onRetry} />

  const TH_STYLE: React.CSSProperties = {
    padding: '9px 16px', textAlign: 'left', color: 'var(--muted)',
    fontWeight: 600, fontSize: 11, textTransform: 'uppercase',
    letterSpacing: '0.05em', whiteSpace: 'nowrap',
  }

  return (
    <div style={{ display: 'flex', gap: 20, alignItems: 'flex-start' }}>
      {showRegister && <RegisterModal onClose={() => setShowRegister(false)} onCreated={onReload} />}

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
        <div style={{ display: 'flex', gap: 10, marginBottom: 14, alignItems: 'center' }}>
          <input
            type="text"
            placeholder="Search agents…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            style={{ flex: 1, maxWidth: 280 }}
          />
          <select
            value={lifecycleFilter}
            onChange={(e) => setLifecycleFilter(e.target.value)}
            style={{ width: 140 }}
          >
            {LIFECYCLE_OPTIONS.map(o => (
              <option key={o} value={o}>
                {o === 'all' ? 'All states' : o.charAt(0).toUpperCase() + o.slice(1)}
              </option>
            ))}
          </select>
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
                title="No governed agents"
                body="Agents appear here after enrollment via the registry API."
              />
              <button className="btn btn-primary" onClick={() => setShowRegister(true)}>Register Agent</button>
            </div>
          ) : (
            <EmptyState title="No agents match your filter" body="Try clearing the search or changing the state filter." />
          )
        ) : (
          <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
              <thead>
                <tr style={{ background: 'var(--surface2)', borderBottom: '1px solid var(--border)' }}>
                  <th style={TH_STYLE}>Name</th>
                  <th style={TH_STYLE}>Type</th>
                  <th style={TH_STYLE}>Owner</th>
                  <th style={TH_STYLE}>State</th>
                  <th style={TH_STYLE}>Compliance</th>
                  <th style={TH_STYLE}>Posture</th>
                  <th style={TH_STYLE}>Last Activity</th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((a) => (
                  <AgentTableRow key={a.id} agent={a} onNavigate={(id) => navigate(`/agents/${id}`)} />
                ))}
              </tbody>
            </table>
          </div>
        )}

        {filtered.length > 0 && (
          <div style={{ marginTop: 10, fontSize: 12, color: 'var(--muted)' }}>
            Showing {filtered.length} of {agents.length} agents
          </div>
        )}
      </div>
    </div>
  )
}

// ─── Discovered Tab ──────────────────────────────────────────────────────────

function ScanStatusCard({ scan }: { scan: NHIScan | null }) {
  if (!scan) {
    return (
      <div className="card" style={{ marginBottom: 14, padding: '14px 20px' }}>
        <span style={{ color: 'var(--muted)', fontSize: 13 }}>No scans have been run yet. Scans are triggered by your Signal Loom operator.</span>
      </div>
    )
  }

  const duration = scan.completed_at && scan.started_at
    ? Math.round((new Date(scan.completed_at).getTime() - new Date(scan.started_at).getTime()) / 1000)
    : null

  return (
    <div className="card" style={{ marginBottom: 14, padding: '14px 20px' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 20, flexWrap: 'wrap' }}>
        <div>
          <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 3 }}>Last Scan</div>
          <div style={{ fontSize: 13, fontWeight: 500 }}>{fmtRelative(scan.started_at)}</div>
        </div>
        <div>
          <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 3 }}>Source</div>
          <div style={{ fontSize: 13 }}>{scan.scan_source === 'ad_entra' ? 'Entra ID / AD' : scan.scan_source}</div>
        </div>
        {duration !== null && (
          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 3 }}>Duration</div>
            <div style={{ fontSize: 13 }}>{duration}s</div>
          </div>
        )}
        {scan.service_accounts_found !== null && (
          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 3 }}>Accounts Found</div>
            <div style={{ fontSize: 13, fontWeight: 600, color: colors.cyanLoom }}>{scan.service_accounts_found}</div>
          </div>
        )}
        <StatusBadge status={scan.status} />
      </div>
    </div>
  )
}

interface FindingCounts {
  unowned: number
  noRotation: number
  stale: number
  excessivePrivilege: number
}

function FindingsSummary({ counts, onFilter, activeFilter }: {
  counts: FindingCounts
  onFilter: (key: string) => void
  activeFilter: string
}) {
  const chips = [
    { key: 'unowned', label: 'Ownership Gaps', count: counts.unowned, color: colors.red },
    { key: 'no_rotation', label: 'No Rotation', count: counts.noRotation, color: colors.amber },
    { key: 'stale', label: 'Stale Account', count: counts.stale, color: colors.amber },
    { key: 'excessive_privilege', label: 'Excessive Privilege', count: counts.excessivePrivilege, color: colors.irisViolet },
  ].filter(c => c.count > 0)

  if (chips.length === 0) return null

  return (
    <div className="card" style={{ marginBottom: 14, padding: '12px 18px' }}>
      <div style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 10, textTransform: 'uppercase', letterSpacing: '0.06em' }}>
        Discovery Findings
      </div>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        {chips.map(c => (
          <button
            key={c.key}
            onClick={() => onFilter(activeFilter === c.key ? 'all' : c.key)}
            style={{
              display: 'flex', alignItems: 'center', gap: 7,
              background: activeFilter === c.key ? `${c.color}22` : 'var(--surface2)',
              border: `1px solid ${activeFilter === c.key ? c.color + '55' : 'var(--border-subtle)'}`,
              borderRadius: 6, padding: '5px 12px',
              color: activeFilter === c.key ? c.color : 'var(--text)',
              fontSize: 12, fontWeight: 500, cursor: 'pointer', fontFamily: 'inherit',
            }}
          >
            <span style={{ background: c.color, color: '#fff', borderRadius: 99, fontSize: 10, fontWeight: 700, padding: '0 5px' }}>{c.count}</span>
            {c.label}
          </button>
        ))}
      </div>
    </div>
  )
}

function TriageMenu({ accountId, onAction }: { accountId: string; onAction: (action: 'enroll' | 'dismiss' | 'review', id: string) => void }) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    function handle(e: MouseEvent) {
      if (!ref.current?.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', handle)
    return () => document.removeEventListener('mousedown', handle)
  }, [open])

  const item: React.CSSProperties = {
    display: 'block', width: '100%', padding: '8px 14px',
    background: 'none', border: 'none', textAlign: 'left',
    fontSize: 13, cursor: 'pointer', fontFamily: 'inherit',
    color: 'var(--text)', transition: 'background 0.1s',
  }

  return (
    <div ref={ref} style={{ position: 'relative', display: 'inline-block' }}>
      <button
        className="btn btn-secondary"
        style={{ fontSize: 11, padding: '4px 10px', gap: 4 }}
        onClick={() => setOpen(!open)}
      >
        Actions ▾
      </button>
      {open && (
        <div style={{
          position: 'absolute', right: 0, top: '100%', marginTop: 4,
          background: 'var(--surface)', border: '1px solid var(--border-subtle)',
          borderRadius: 8, zIndex: 100, minWidth: 170,
          boxShadow: '0 8px 24px rgba(0,0,0,0.4)',
          overflow: 'hidden',
        }}>
          <button style={item} onClick={() => { onAction('review', accountId); setOpen(false) }}
            onMouseEnter={e => (e.currentTarget.style.background = 'var(--surface2)')}
            onMouseLeave={e => (e.currentTarget.style.background = 'none')}>
            Mark as Reviewed
          </button>
          <button style={item} onClick={() => { onAction('enroll', accountId); setOpen(false) }}
            onMouseEnter={e => (e.currentTarget.style.background = 'var(--surface2)')}
            onMouseLeave={e => (e.currentTarget.style.background = 'none')}>
            Request Enrollment
          </button>
          <button
            style={{ ...item, color: colors.amber, borderTop: '1px solid var(--border)' }}
            onClick={() => { onAction('dismiss', accountId); setOpen(false) }}
            onMouseEnter={e => (e.currentTarget.style.background = 'var(--surface2)')}
            onMouseLeave={e => (e.currentTarget.style.background = 'none')}
          >
            Dismiss
          </button>
        </div>
      )}
    </div>
  )
}

function NHIAccountRow({ account, onAction }: {
  account: NHIAccount
  onAction: (action: 'enroll' | 'dismiss' | 'review', id: string) => void
}) {
  const isDismissed = account.status === 'dismissed'
  const rowStyle: React.CSSProperties = {
    borderBottom: '1px solid var(--border)',
    opacity: isDismissed ? 0.65 : 1,
  }
  const td: React.CSSProperties = { padding: '10px 14px', fontSize: 13 }

  const findings = Array.isArray(account.findings) ? account.findings : []

  return (
    <tr style={rowStyle}>
      {/* Account name */}
      <td style={td}>
        <div style={{ fontWeight: 500 }}>{account.account_name}</div>
        {isDismissed && (
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 3, flexWrap: 'wrap' }}>
            <span style={{
              fontSize: 10, fontWeight: 700, padding: '1px 6px', borderRadius: 3,
              background: 'var(--border-subtle)', color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.04em',
            }}>Dismissed</span>
            {account.dismissed_at && (
              <span style={{ fontSize: 11, color: 'var(--muted)' }}>{fmtDate(account.dismissed_at)}</span>
            )}
            {account.dismissed_by && (
              <span style={{ fontSize: 11, color: 'var(--muted)' }}>by {account.dismissed_by}</span>
            )}
            {account.changes_since_dismissal && (
              <span style={{ fontSize: 11, color: colors.amber, fontWeight: 600 }}>Changed since dismissal</span>
            )}
          </div>
        )}
        {account.scan_count !== null && account.scan_count > 1 && (
          <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
            Seen in {account.scan_count} scans
          </div>
        )}
      </td>

      {/* Directory source */}
      <td style={td}>
        <StatusBadge status={account.directory_source.replace(/[_\s]+/g, '_').toLowerCase()} variant="nhi" />
      </td>

      {/* Owner */}
      <td style={td}>
        {account.owner_email ? (
          <span style={{ fontSize: 12 }}>{account.owner_email}</span>
        ) : (
          <span style={{ color: colors.red, fontSize: 12, fontWeight: 600 }}>Unowned</span>
        )}
      </td>

      {/* Last rotation */}
      <td style={td}>
        {account.last_credential_rotation ? (
          <span style={{ fontSize: 12, color: 'var(--muted)' }}>{fmtDate(account.last_credential_rotation)}</span>
        ) : (
          <span style={{ color: colors.amber, fontSize: 12, fontWeight: 600 }}>Never</span>
        )}
      </td>

      {/* Privilege */}
      <td style={td}>
        <StatusBadge status={account.privilege_level || 'standard'} variant="privilege" />
      </td>

      {/* Findings badges */}
      <td style={td}>
        <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
          {findings.length === 0 ? (
            <span style={{ color: 'var(--muted)', fontSize: 12 }}>—</span>
          ) : (
            findings.slice(0, 3).map((f, i) => (
              <span key={i} style={{
                fontSize: 10, padding: '2px 7px', borderRadius: 4,
                background: 'rgba(139,92,246,0.15)', color: colors.irisViolet,
                fontWeight: 600,
              }}>{String(f)}</span>
            ))
          )}
          {findings.length > 3 && (
            <span style={{ fontSize: 11, color: 'var(--muted)' }}>+{findings.length - 3}</span>
          )}
        </div>
      </td>

      {/* Actions */}
      <td style={{ ...td, textAlign: 'right' }}>
        {isDismissed ? (
          <button
            className="btn btn-secondary"
            style={{ fontSize: 11, padding: '4px 10px' }}
            onClick={() => onAction('enroll', account.id)}
          >
            Enroll
          </button>
        ) : (
          <TriageMenu accountId={account.id} onAction={onAction} />
        )}
      </td>
    </tr>
  )
}

function DiscoveredTab({ accounts, loading, error, latestScan, summary, onRetry, onAction }: {
  accounts: NHIAccount[]
  loading: boolean
  error: string | null
  latestScan: NHIScan | null
  summary: { total_discovered: number; needs_triage: number; previously_dismissed: number } | null
  onRetry: () => void
  onAction: (action: 'enroll' | 'dismiss' | 'review', id: string) => void
}) {
  const [nhiFilter, setNhiFilter] = useState<'all' | 'triage' | 'dismissed' | string>('all')

  const activeAccounts = useMemo(() => accounts.filter(a => a.status !== 'dismissed'), [accounts])

  const findingCounts: FindingCounts = useMemo(() => ({
    unowned: activeAccounts.filter(a => !a.owner_email).length,
    noRotation: activeAccounts.filter(a => !a.last_credential_rotation).length,
    stale: activeAccounts.filter(a => {
      if (!a.last_credential_rotation) return false
      const days = (Date.now() - new Date(a.last_credential_rotation).getTime()) / 86400000
      return days > 90
    }).length,
    excessivePrivilege: activeAccounts.filter(a =>
      ['elevated', 'domain_admin', 'enterprise_admin'].includes(a.privilege_level)
    ).length,
  }), [activeAccounts])

  const filtered = useMemo(() => {
    if (nhiFilter === 'all') return accounts
    if (nhiFilter === 'triage') return accounts.filter(a => a.status !== 'dismissed')
    if (nhiFilter === 'dismissed') return accounts.filter(a => a.status === 'dismissed')
    // findings filter
    if (nhiFilter === 'unowned') return accounts.filter(a => a.status !== 'dismissed' && !a.owner_email)
    if (nhiFilter === 'no_rotation') return accounts.filter(a => a.status !== 'dismissed' && !a.last_credential_rotation)
    if (nhiFilter === 'stale') return accounts.filter(a => {
      if (a.status === 'dismissed' || !a.last_credential_rotation) return false
      return (Date.now() - new Date(a.last_credential_rotation).getTime()) / 86400000 > 90
    })
    if (nhiFilter === 'excessive_privilege') return accounts.filter(a =>
      a.status !== 'dismissed' && ['elevated', 'domain_admin', 'enterprise_admin'].includes(a.privilege_level)
    )
    return accounts
  }, [accounts, nhiFilter])

  function exportJson() {
    const blob = new Blob([JSON.stringify({ accounts, exported_at: new Date().toISOString() }, null, 2)], { type: 'application/json' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `nhi-discovered-${new Date().toISOString().split('T')[0]}.json`
    a.click()
    URL.revokeObjectURL(url)
  }

  if (loading) return <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 64 }}>Loading…</div>
  if (error) return <ErrorState message={error} onRetry={onRetry} />

  const TH: React.CSSProperties = {
    padding: '9px 14px', textAlign: 'left', color: 'var(--muted)',
    fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em',
  }
  const tabBtn = (active: boolean): React.CSSProperties => ({
    padding: '6px 14px', borderRadius: 6, border: '1px solid',
    borderColor: active ? 'var(--border-subtle)' : 'transparent',
    background: active ? 'var(--surface2)' : 'transparent',
    color: active ? 'var(--text)' : 'var(--muted)',
    fontSize: 12, fontWeight: active ? 600 : 400, cursor: 'pointer', fontFamily: 'inherit',
  })

  return (
    <div>
      <ScanStatusCard scan={latestScan} />
      <FindingsSummary counts={findingCounts} onFilter={setNhiFilter} activeFilter={nhiFilter} />

      {/* Filter bar */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10, flexWrap: 'wrap', gap: 10 }}>
        <div style={{ display: 'flex', gap: 6 }}>
          <button style={tabBtn(nhiFilter === 'all')} onClick={() => setNhiFilter('all')}>All</button>
          <button style={tabBtn(nhiFilter === 'triage')} onClick={() => setNhiFilter('triage')}>Needs Triage</button>
          <button style={tabBtn(nhiFilter === 'dismissed')} onClick={() => setNhiFilter('dismissed')}>Dismissed</button>
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          <button
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '5px 12px' }}
            onClick={() => alert('PDF export is available in the Enterprise tier.')}
          >
            Export PDF
          </button>
          <button
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '5px 12px' }}
            onClick={exportJson}
          >
            Export JSON
          </button>
        </div>
      </div>

      {/* Summary bar */}
      <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 14 }}>
        <span style={{ color: 'var(--text)', fontWeight: 500 }}>{summary?.total_discovered ?? accounts.length}</span> discovered
        {' · '}
        <span style={{ color: colors.amber, fontWeight: 500 }}>{summary?.needs_triage ?? activeAccounts.length}</span> need triage
        {' · '}
        <span style={{ fontWeight: 500 }}>{summary?.previously_dismissed ?? accounts.filter(a => a.status === 'dismissed').length}</span> previously dismissed
      </div>

      {filtered.length === 0 ? (
        <EmptyState title="No accounts found" body="Trigger a discovery scan from your operator to populate this list." />
      ) : (
        <div className="card" style={{ padding: 0, overflow: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
            <thead>
              <tr style={{ background: 'var(--surface2)', borderBottom: '1px solid var(--border)' }}>
                <th style={TH}>Account</th>
                <th style={TH}>Source</th>
                <th style={TH}>Owner</th>
                <th style={TH}>Last Rotation</th>
                <th style={TH}>Privilege</th>
                <th style={TH}>Findings</th>
                <th style={{ ...TH, textAlign: 'right' }}>Actions</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((a) => (
                <NHIAccountRow key={a.id} account={a} onAction={onAction} />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

// ─── Main Page ───────────────────────────────────────────────────────────────

export default function AgentsPage() {
  const { getAccessTokenSilently } = useAuth0()
  const [tab, setTab] = useState<'governed' | 'discovered'>('governed')

  // Governed
  const [agents, setAgents] = useState<AgentResponse[]>([])
  const [agentsLoading, setAgentsLoading] = useState(true)
  const [agentsError, setAgentsError] = useState<string | null>(null)

  // Discovered
  const [accounts, setAccounts] = useState<NHIAccount[]>([])
  const [nhiSummary, setNhiSummary] = useState<{ total_discovered: number; needs_triage: number; previously_dismissed: number } | null>(null)
  const [latestScan, setLatestScan] = useState<NHIScan | null>(null)
  const [nhiLoading, setNhiLoading] = useState(true)
  const [nhiError, setNhiError] = useState<string | null>(null)

  const loadAgents = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const data = await api.agents.list(token)
      setAgents(data.agents)
      setAgentsError(null)
    } catch (e) {
      setAgentsError(e instanceof Error ? e.message : 'Failed to load agents')
    } finally {
      setAgentsLoading(false)
    }
  }, [getAccessTokenSilently])

  const loadNhi = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const [discovered, scansData] = await Promise.all([
        api.nhi.discovered(token),
        api.nhi.scans(token).catch(() => ({ scans: [] as NHIScan[] })),
      ])
      setAccounts(discovered.accounts)
      setNhiSummary(discovered.summary)
      const scans = scansData.scans
      setLatestScan(scans.length > 0 ? scans[0] : null)
      setNhiError(null)
    } catch (e) {
      setNhiError(e instanceof Error ? e.message : 'Failed to load discovery data')
    } finally {
      setNhiLoading(false)
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    loadAgents()
    loadNhi()
    const t1 = setInterval(loadAgents, POLL_MS)
    const t2 = setInterval(loadNhi, POLL_MS)
    return () => { clearInterval(t1); clearInterval(t2) }
  }, [loadAgents, loadNhi])

  // Attention Required alerts
  const alerts: AlertItem[] = useMemo(() => {
    const items: AlertItem[] = []
    const nonDismissed = accounts.filter(a => a.status !== 'dismissed')

    const enrolledInactive = agents.filter(a => a.lifecycle_state === 'enrolled')
    if (enrolledInactive.length > 0)
      items.push({ id: 'enrolled', label: 'enrolled agents not activated', count: enrolledInactive.length, severity: 'warning', tab: 'governed', filterKey: 'enrolled' })

    const withViolations = agents.filter(a => a.compliance_summary.failing > 0)
    if (withViolations.length > 0)
      items.push({ id: 'violations', label: 'agents with new violations', count: withViolations.length, severity: 'critical', tab: 'governed' })

    const suspended = agents.filter(a => a.lifecycle_state === 'suspended')
    if (suspended.length > 0)
      items.push({ id: 'suspended', label: 'suspended agents', count: suspended.length, severity: 'warning', tab: 'governed', filterKey: 'suspended' })

    const critical = agents.filter(a => a.compliance_summary.posture_score !== null && a.compliance_summary.posture_score < 50)
    if (critical.length > 0)
      items.push({ id: 'critical', label: 'agents with critical posture', count: critical.length, severity: 'critical', tab: 'governed' })

    const unowned = nonDismissed.filter(a => !a.owner_email)
    if (unowned.length > 0)
      items.push({ id: 'unowned', label: 'unowned accounts', count: unowned.length, severity: 'critical', tab: 'discovered', filterKey: 'unowned' })

    const noRotation = nonDismissed.filter(a => !a.last_credential_rotation)
    if (noRotation.length > 0)
      items.push({ id: 'no_rotation', label: 'accounts with no rotation', count: noRotation.length, severity: 'warning', tab: 'discovered', filterKey: 'no_rotation' })

    const excessivePriv = nonDismissed.filter(a =>
      ['elevated', 'domain_admin', 'enterprise_admin'].includes(a.privilege_level)
    )
    if (excessivePriv.length > 0)
      items.push({ id: 'excessive_priv', label: 'accounts with excessive privilege', count: excessivePriv.length, severity: 'warning', tab: 'discovered', filterKey: 'excessive_privilege' })

    return items
  }, [agents, accounts])

  async function handleNhiAction(action: 'enroll' | 'dismiss' | 'review', accountId: string) {
    try {
      const token = await getAccessTokenSilently()
      if (action === 'enroll') await api.nhi.enrollAccount(token, accountId)
      else if (action === 'dismiss') await api.nhi.dismissAccount(token, accountId)
      await loadNhi()
    } catch (e) {
      alert(`Action failed: ${e instanceof Error ? e.message : String(e)}`)
    }
  }

  const tabStyle = (active: boolean): React.CSSProperties => ({
    padding: '8px 18px',
    background: active ? 'var(--surface2)' : 'transparent',
    border: '1px solid',
    borderColor: active ? 'var(--border-subtle)' : 'transparent',
    borderRadius: 6,
    color: active ? 'var(--text)' : 'var(--muted)',
    fontSize: 13,
    fontWeight: active ? 600 : 400,
    cursor: 'pointer',
    fontFamily: 'inherit',
  })

  return (
    <div>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 18 }}>Agents</h1>

      <AttentionPanel
        alerts={alerts}
        onAlert={(alertTab, filterKey) => {
          setTab(alertTab)
          // filterKey is used by sub-tab state — handled within each tab
          void filterKey
        }}
      />

      <div style={{ display: 'flex', gap: 6, marginBottom: 20 }}>
        <button style={tabStyle(tab === 'governed')} onClick={() => setTab('governed')}>
          Governed{agents.length > 0 ? ` (${agents.length})` : ''}
        </button>
        <button style={tabStyle(tab === 'discovered')} onClick={() => setTab('discovered')}>
          Discovered{accounts.length > 0 ? ` (${accounts.length})` : ''}
        </button>
      </div>

      {tab === 'governed' ? (
        <GovernedTab
          agents={agents}
          loading={agentsLoading}
          error={agentsError}
          onRetry={loadAgents}
          onReload={loadAgents}
        />
      ) : (
        <DiscoveredTab
          accounts={accounts}
          loading={nhiLoading}
          error={nhiError}
          latestScan={latestScan}
          summary={nhiSummary}
          onRetry={loadNhi}
          onAction={handleNhiAction}
        />
      )}
    </div>
  )
}
