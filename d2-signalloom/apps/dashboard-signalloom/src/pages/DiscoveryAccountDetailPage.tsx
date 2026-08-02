import { useState, useEffect, useCallback } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import type { NHIAccountDetail } from '../types/api'
import { colors } from '../styles/tokens'
import StatusBadge from '../components/StatusBadge'
import TriageMenu, { type TriageAction } from '../components/TriageMenu'
import ErrorState from '../components/ErrorState'

function fmtDate(iso: string | null) {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 4 }}>
        {label}
      </div>
      <div style={{ fontSize: 13 }}>{children}</div>
    </div>
  )
}

export default function DiscoveryAccountDetailPage() {
  const { accountId } = useParams<{ accountId: string }>()
  const navigate = useNavigate()
  const { getAccessTokenSilently } = useAuth0()

  const [account, setAccount] = useState<NHIAccountDetail | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    if (!accountId) return
    setLoading(true)
    try {
      const token = await getAccessTokenSilently()
      const data = await api.nhi.getAccount(token, accountId)
      setAccount(data)
      setError(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load account details')
    } finally {
      setLoading(false)
    }
  }, [accountId, getAccessTokenSilently])

  useEffect(() => {
    load()
  }, [load])

  async function handleAction(action: TriageAction, id: string) {
    try {
      const token = await getAccessTokenSilently()
      if (action === 'enroll') await api.nhi.enrollAccount(token, id)
      else if (action === 'dismiss') await api.nhi.dismissAccount(token, id)
      await load()
    } catch (e) {
      alert(`Action failed: ${e instanceof Error ? e.message : String(e)}`)
    }
  }

  if (loading) {
    return <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 64 }}>Loading…</div>
  }

  if (error || !account) {
    return (
      <div>
        <button onClick={() => navigate('/discovery')} className="btn btn-secondary" style={{ fontSize: 12, padding: '5px 12px', marginBottom: 20 }}>
          ← Back to Discovery
        </button>
        <ErrorState message={error ?? 'Account not found'} onRetry={load} />
      </div>
    )
  }

  const isDismissed = account.status === 'dismissed'
  const findings = Array.isArray(account.findings) ? account.findings : []

  return (
    <div style={{ maxWidth: 800 }}>
      {/* Back nav */}
      <button
        onClick={() => navigate('/discovery')}
        style={{
          background: 'none', border: 'none', color: 'var(--muted)', fontSize: 13,
          cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 6,
          marginBottom: 16, padding: 0, fontFamily: 'inherit',
        }}
        onMouseEnter={e => (e.currentTarget.style.color = 'var(--text)')}
        onMouseLeave={e => (e.currentTarget.style.color = 'var(--muted)')}
      >
        ← Discovery
      </button>

      {/* Header */}
      <div className="card" style={{ padding: 20, marginBottom: 20 }}>
        <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 16, flexWrap: 'wrap' }}>
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8, flexWrap: 'wrap' }}>
              <h1 style={{ fontSize: 20, fontWeight: 700, margin: 0 }}>{account.account_name}</h1>
              <StatusBadge status={account.status} variant="nhi" />
              <StatusBadge status={account.privilege_level || 'standard'} variant="privilege" />
            </div>
            <div
              title={`Account ID: ${account.id}`}
              style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace' }}
            >
              ID: {account.id}
            </div>
          </div>
          <div>
            {isDismissed ? (
              <button className="btn btn-secondary" style={{ fontSize: 12, padding: '6px 14px' }} onClick={() => handleAction('enroll', account.id)}>
                Enroll
              </button>
            ) : (
              <TriageMenu accountId={account.id} onAction={handleAction} />
            )}
          </div>
        </div>
      </div>

      {/* Discovery details */}
      <section className="card" style={{ padding: 20, marginBottom: 20 }}>
        <h2 style={{ fontSize: 15, fontWeight: 700, marginBottom: 16 }}>Discovery Details</h2>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 16 }}>
          <Field label="Discovered via">
            <StatusBadge status={account.directory_source.replace(/[_\s]+/g, '_').toLowerCase()} variant="nhi" />
          </Field>
          <Field label="Discovery date">{fmtDate(account.first_discovered_at)}</Field>
          <Field label="Last seen">{fmtDate(account.last_seen_at)}</Field>
          <Field label="Seen in scans">{account.scan_count}</Field>
          <Field label="Owner">
            {account.owner_email ? (
              account.owner_email
            ) : (
              <span style={{ color: colors.red, fontWeight: 600 }}>Unowned</span>
            )}
          </Field>
          <Field label="Last credential rotation">
            {account.last_rotated ? (
              fmtDate(account.last_rotated)
            ) : (
              <span style={{ color: colors.amber, fontWeight: 600 }}>Never</span>
            )}
          </Field>
        </div>
      </section>

      {/* Findings */}
      <section className="card" style={{ padding: 20, marginBottom: 20 }}>
        <h2 style={{ fontSize: 15, fontWeight: 700, marginBottom: 16 }}>Findings</h2>
        {findings.length === 0 ? (
          <span style={{ color: 'var(--muted)', fontSize: 13 }}>No findings recorded for this account.</span>
        ) : (
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            {findings.map((f, i) => (
              <span key={i} style={{
                fontSize: 12, padding: '4px 10px', borderRadius: 4,
                background: 'rgba(139,92,246,0.15)', color: colors.irisViolet,
                fontWeight: 600,
              }}>{String(f)}</span>
            ))}
          </div>
        )}
      </section>

      {/* Enrollment / dismissal state */}
      <section className="card" style={{ padding: 20 }}>
        <h2 style={{ fontSize: 15, fontWeight: 700, marginBottom: 16 }}>Status</h2>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 16 }}>
          <Field label="Current state"><StatusBadge status={account.status} variant="nhi" /></Field>
          {isDismissed && (
            <>
              <Field label="Dismissed">{fmtDate(account.dismissed_at)}</Field>
              <Field label="Dismissed by">{account.dismissed_by ?? '—'}</Field>
              <Field label="Dismiss reason">{account.dismiss_reason ?? '—'}</Field>
            </>
          )}
        </div>
      </section>
    </div>
  )
}
