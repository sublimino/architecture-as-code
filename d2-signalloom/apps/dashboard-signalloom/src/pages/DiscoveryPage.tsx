// TODO: migrate table to DataTable (already has server-side pagination — complement with client-side sorting)
import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import type { NHIAccount, NHIScan } from '../types/api'
import { colors } from '../styles/tokens'
import StatusBadge from '../components/StatusBadge'
import TriageMenu, { type TriageAction } from '../components/TriageMenu'
import EmptyState from '../components/EmptyState'
import LoadingState from '../components/LoadingState'

const POLL_MS = 15 * 60 * 1000
const PAGE_SIZE = 50

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

// ─── Attention Panel (discovery-scoped) ──────────────────────────────────────

interface AlertItem {
  id: string
  label: string
  count: number
  severity: 'warning' | 'critical'
  filterKey: string
}

function AttentionPanel({ alerts, onAlert }: { alerts: AlertItem[]; onAlert: (filterKey: string) => void }) {
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

// ─── Connect CTA ──────────────────────────────────────────────────────────────

function ConnectDirectoryCta() {
  const navigate = useNavigate()
  return (
    <div className="card" style={{
      marginBottom: 20, padding: '16px 20px', display: 'flex',
      alignItems: 'center', justifyContent: 'space-between', gap: 16, flexWrap: 'wrap',
    }}>
      <div>
        <div style={{ fontSize: 14, fontWeight: 600, marginBottom: 3 }}>Connect a directory</div>
        <div style={{ fontSize: 12, color: 'var(--muted)' }}>
          Link Entra ID or another directory source to start discovering non-human identities automatically.
        </div>
      </div>
      <button className="btn btn-primary" style={{ fontSize: 12, padding: '7px 16px', whiteSpace: 'nowrap' }} onClick={() => navigate('/onboarding')}>
        Connect a directory
      </button>
    </div>
  )
}

// ─── Scan status ──────────────────────────────────────────────────────────────

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

// ─── Findings summary ─────────────────────────────────────────────────────────

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
            <span style={{ background: c.color, color: 'var(--on-accent)', borderRadius: 99, fontSize: 10, fontWeight: 700, padding: '0 5px' }}>{c.count}</span>
            {c.label}
          </button>
        ))}
      </div>
    </div>
  )
}

// ─── Filter menu ──────────────────────────────────────────────────────────────
// Single dropdown for all list-level filters — same chrome as TriageMenu's
// "Actions ▾" pattern, so filter and row-action controls read as one
// interaction model instead of accumulating standalone buttons/checkboxes
// as filters get added over time.

type StatusFilter = 'all' | 'triage' | 'dismissed'

function FilterMenu({
  statusFilter,
  onStatusFilterChange,
  showDisconnected,
  onToggleShowDisconnected,
}: {
  // nhiFilter is a superset string type (finding-chip keys like 'unowned' are
  // also valid values, set from AttentionPanel/FindingsSummary elsewhere on
  // the page) — this menu only owns the three base status options below.
  statusFilter: string
  onStatusFilterChange: (f: StatusFilter) => void
  showDisconnected: boolean
  onToggleShowDisconnected: () => void
}) {
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

  const STATUS_LABELS: Record<StatusFilter, string> = {
    all: 'All',
    triage: 'Needs Triage',
    dismissed: 'Dismissed',
  }
  const currentLabel = (STATUS_LABELS as Record<string, string>)[statusFilter] ?? 'Custom'

  const item: React.CSSProperties = {
    display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8,
    width: '100%', padding: '8px 14px',
    background: 'none', border: 'none', textAlign: 'left',
    fontSize: 13, cursor: 'pointer', fontFamily: 'inherit',
    color: 'var(--text)', transition: 'background 0.1s',
  }

  return (
    <div ref={ref} style={{ position: 'relative', display: 'inline-block' }}>
      <button
        className="btn btn-secondary"
        style={{ fontSize: 12, padding: '6px 14px', gap: 4 }}
        onClick={() => setOpen(!open)}
      >
        Filter: {currentLabel}{showDisconnected ? ' + Disconnected' : ''} ▾
      </button>
      {open && (
        <div style={{
          position: 'absolute', left: 0, top: '100%', marginTop: 4,
          background: 'var(--surface)', border: '1px solid var(--border-subtle)',
          borderRadius: 8, zIndex: 100, minWidth: 200,
          boxShadow: '0 8px 24px rgba(0,0,0,0.4)',
          overflow: 'hidden',
        }}>
          {(Object.keys(STATUS_LABELS) as StatusFilter[]).map((key) => (
            <button
              key={key}
              style={item}
              onClick={() => { onStatusFilterChange(key); setOpen(false) }}
              onMouseEnter={(e) => (e.currentTarget.style.background = 'var(--surface2)')}
              onMouseLeave={(e) => (e.currentTarget.style.background = 'none')}
            >
              {STATUS_LABELS[key]}
              {statusFilter === key && <span style={{ color: colors.cyanLoom }}>✓</span>}
            </button>
          ))}
          <button
            style={{ ...item, borderTop: '1px solid var(--border)' }}
            onClick={() => onToggleShowDisconnected()}
            onMouseEnter={(e) => (e.currentTarget.style.background = 'var(--surface2)')}
            onMouseLeave={(e) => (e.currentTarget.style.background = 'none')}
          >
            Show disconnected sources
            {showDisconnected && <span style={{ color: colors.cyanLoom }}>✓</span>}
          </button>
        </div>
      )}
    </div>
  )
}

// ─── Account row ──────────────────────────────────────────────────────────────

function NHIAccountRow({ account, onAction, onOpen }: {
  account: NHIAccount
  onAction: (action: TriageAction, id: string) => void
  onOpen: (id: string) => void
}) {
  const isDismissed = account.status === 'dismissed'
  const rowStyle: React.CSSProperties = {
    borderBottom: '1px solid var(--border)',
    opacity: isDismissed || account.source_removed ? 0.65 : 1,
  }
  const td: React.CSSProperties = { padding: '10px 14px', fontSize: 13 }

  const findings = Array.isArray(account.findings) ? account.findings : []

  return (
    <tr style={rowStyle}>
      {/* Account name */}
      <td style={td}>
        <button
          onClick={() => onOpen(account.id)}
          style={{
            background: 'none', border: 'none', padding: 0, fontFamily: 'inherit',
            fontWeight: 500, fontSize: 13, color: 'var(--text)', cursor: 'pointer', textAlign: 'left',
          }}
          onMouseEnter={e => (e.currentTarget.style.textDecoration = 'underline')}
          onMouseLeave={e => (e.currentTarget.style.textDecoration = 'none')}
        >
          {account.account_name}
        </button>
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
        {account.source_removed && (
          <div style={{ marginTop: 3 }}>
            <span style={{
              fontSize: 10, fontWeight: 700, padding: '1px 6px', borderRadius: 3,
              background: 'rgba(215,119,6,0.15)', color: colors.amber, textTransform: 'uppercase', letterSpacing: '0.04em',
            }}>Source disconnected</span>
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

// ─── Main Page ───────────────────────────────────────────────────────────────

export default function DiscoveryPage() {
  const { getAccessTokenSilently } = useAuth0()
  const navigate = useNavigate()

  const [accounts, setAccounts] = useState<NHIAccount[]>([])
  const [nhiSummary, setNhiSummary] = useState<{ total_discovered: number; needs_triage: number; previously_dismissed: number } | null>(null)
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [latestScan, setLatestScan] = useState<NHIScan | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [nhiFilter, setNhiFilter] = useState<'all' | 'triage' | 'dismissed' | string>('all')
  const [showDisconnected, setShowDisconnected] = useState(false)

  const loadNhi = useCallback(async (targetPage: number, includeDisconnected: boolean) => {
    try {
      const token = await getAccessTokenSilently()
      const [discovered, scansData] = await Promise.all([
        api.nhi.discovered(token, targetPage, PAGE_SIZE, undefined, includeDisconnected),
        api.nhi.scans(token).catch(() => ({ scans: [] as NHIScan[] })),
      ])
      setAccounts(discovered.accounts)
      setNhiSummary(discovered.summary)
      setTotal(discovered.total)
      const scans = scansData.scans
      setLatestScan(scans.length > 0 ? scans[0] : null)
      setError(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load discovery data')
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    loadNhi(page, showDisconnected)
    const t = setInterval(() => loadNhi(page, showDisconnected), POLL_MS)
    return () => clearInterval(t)
  }, [loadNhi, page, showDisconnected])

  async function handleNhiAction(action: TriageAction, accountId: string) {
    try {
      const token = await getAccessTokenSilently()
      if (action === 'enroll') await api.nhi.enrollAccount(token, accountId)
      else if (action === 'dismiss') await api.nhi.dismissAccount(token, accountId)
      await loadNhi(page, showDisconnected)
    } catch (e) {
      alert(`Action failed: ${e instanceof Error ? e.message : String(e)}`)
    }
  }

  const activeAccounts = useMemo(() => accounts.filter(a => a.status !== 'dismissed'), [accounts])

  const alerts: AlertItem[] = useMemo(() => {
    const items: AlertItem[] = []
    const unowned = activeAccounts.filter(a => !a.owner_email)
    if (unowned.length > 0)
      items.push({ id: 'unowned', label: 'unowned accounts', count: unowned.length, severity: 'critical', filterKey: 'unowned' })

    const noRotation = activeAccounts.filter(a => !a.last_credential_rotation)
    if (noRotation.length > 0)
      items.push({ id: 'no_rotation', label: 'accounts with no rotation', count: noRotation.length, severity: 'warning', filterKey: 'no_rotation' })

    const excessivePriv = activeAccounts.filter(a =>
      ['elevated', 'domain_admin', 'enterprise_admin'].includes(a.privilege_level)
    )
    if (excessivePriv.length > 0)
      items.push({ id: 'excessive_priv', label: 'accounts with excessive privilege', count: excessivePriv.length, severity: 'warning', filterKey: 'excessive_privilege' })

    return items
  }, [activeAccounts])

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

  const TH: React.CSSProperties = {
    padding: '9px 14px', textAlign: 'left', color: 'var(--muted)',
    fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em',
  }

  return (
    <div>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 18 }}>Discovery</h1>

      <ConnectDirectoryCta />

      <AttentionPanel alerts={alerts} onAlert={setNhiFilter} />

      {loading ? (
        <LoadingState variant="block" status="loading" label="discovery data" testId="discovery-load-state" />
      ) : error ? (
        <LoadingState
          variant="block"
          status="error"
          label="discovery data"
          error={error}
          onRetry={() => loadNhi(page, showDisconnected)}
          testId="discovery-load-state"
        />
      ) : (
        <>
          <ScanStatusCard scan={latestScan} />
          <FindingsSummary counts={findingCounts} onFilter={setNhiFilter} activeFilter={nhiFilter} />

          {/* Filter bar */}
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10, flexWrap: 'wrap', gap: 10 }}>
            <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
              <FilterMenu
                statusFilter={nhiFilter}
                onStatusFilterChange={setNhiFilter}
                showDisconnected={showDisconnected}
                onToggleShowDisconnected={() => { setPage(1); setShowDisconnected((v) => !v) }}
              />
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
            <span style={{ color: 'var(--text)', fontWeight: 500 }}>{nhiSummary?.total_discovered ?? accounts.length}</span> discovered
            {' · '}
            <span style={{ color: colors.amber, fontWeight: 500 }}>{nhiSummary?.needs_triage ?? activeAccounts.length}</span> need triage
            {' · '}
            <span style={{ fontWeight: 500 }}>{nhiSummary?.previously_dismissed ?? accounts.filter(a => a.status === 'dismissed').length}</span> previously dismissed
          </div>

          {filtered.length === 0 ? (
            <EmptyState kicker="No accounts found" body="Trigger a discovery scan from your operator to populate this list." />
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
                    <NHIAccountRow
                      key={a.id}
                      account={a}
                      onAction={handleNhiAction}
                      onOpen={(id) => navigate(`/discovery/accounts/${id}`)}
                    />
                  ))}
                </tbody>
              </table>
            </div>
          )}

          {total > PAGE_SIZE && (
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 14, fontSize: 12, color: 'var(--muted)' }}>
              <span>
                Showing {(page - 1) * PAGE_SIZE + 1}–{Math.min(page * PAGE_SIZE, total)} of {total}
              </span>
              <div style={{ display: 'flex', gap: 8 }}>
                <button
                  className="btn btn-secondary"
                  style={{ fontSize: 12, padding: '5px 12px' }}
                  disabled={page <= 1}
                  onClick={() => setPage((p) => Math.max(1, p - 1))}
                >
                  Previous
                </button>
                <button
                  className="btn btn-secondary"
                  style={{ fontSize: 12, padding: '5px 12px' }}
                  disabled={page * PAGE_SIZE >= total}
                  onClick={() => setPage((p) => p + 1)}
                >
                  Next
                </button>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  )
}
