import { useState, useEffect, useCallback } from 'react'
import { useParams, useNavigate, Link } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import type { NHIAccountDetail, AgentResponse } from '../types/api'
import { colors } from '../styles/tokens'
import StatusBadge from '../components/StatusBadge'
import TriageMenu, { type TriageAction } from '../components/TriageMenu'
import LoadingState from '../components/LoadingState'
import { findMatchingAgent } from '../data/agentMatching'

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
  const [agents, setAgents] = useState<AgentResponse[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    if (!accountId) return
    setLoading(true)
    try {
      const token = await getAccessTokenSilently()
      const [data, agentsData] = await Promise.all([
        api.nhi.getAccount(token, accountId),
        api.agents?.list
          ? api.agents.list(token).catch(() => ({ agents: [] as AgentResponse[] }))
          : Promise.resolve({ agents: [] as AgentResponse[] }),
      ])
      setAccount(data)
      if (agentsData && 'agents' in agentsData && Array.isArray(agentsData.agents)) {
        setAgents(agentsData.agents)
      }
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
    return <LoadingState variant="block" status="loading" label="account detail" testId="account-detail-load-state" />
  }

  if (error || !account) {
    return (
      <div>
        <button onClick={() => navigate('/discovery')} className="btn btn-secondary" style={{ fontSize: 12, padding: '5px 12px', marginBottom: 20 }}>
          ← Back to Discovery
        </button>
        <LoadingState
          variant="block"
          status="error"
          label="account detail"
          error={error ?? 'Account not found'}
          onRetry={load}
          testId="account-detail-load-state"
        />
      </div>
    )
  }

  const isDismissed = account.status === 'dismissed'
  const findings = Array.isArray(account.findings) ? account.findings : []
  const matchedAgent = account ? findMatchingAgent(account, agents) : undefined

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

      {/* Associated Agent Dossier */}
      {matchedAgent ? (
        <section
          className="card"
          data-testid="associated-agent-dossier"
          style={{
            padding: 20,
            marginBottom: 20,
            background: 'color-mix(in srgb, var(--cyan) 5%, var(--surface))',
            border: '1px solid color-mix(in srgb, var(--cyan) 30%, var(--border))',
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 16, flexWrap: 'wrap' }}>
            <div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6 }}>
                <span style={{ fontSize: 11, fontWeight: 700, color: 'var(--cyan)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>
                  Associated Agent Dossier
                </span>
                <StatusBadge status={matchedAgent.lifecycle_state} variant="lifecycle" />
              </div>
              <h2 style={{ fontSize: 16, fontWeight: 700, margin: '0 0 6px', color: 'var(--text)' }}>
                {matchedAgent.name}
              </h2>
              <div style={{ fontSize: 12, color: 'var(--muted)' }}>
                <span>ID: <code style={{ color: 'var(--cyan)' }}>{matchedAgent.id}</code></span>
                {matchedAgent.owner && <span> · Owner: {matchedAgent.owner}</span>}
                {matchedAgent.compliance_summary?.posture_score !== null && matchedAgent.compliance_summary?.posture_score !== undefined && (
                  <span> · Posture Score: {matchedAgent.compliance_summary.posture_score}%</span>
                )}
              </div>
            </div>
            <div>
              <Link
                to={`/agents/${matchedAgent.id}?tab=overview`}
                className="btn btn-primary"
                data-testid="view-agent-dossier-btn"
                style={{ fontSize: 12, padding: '7px 16px', textDecoration: 'none', display: 'inline-flex', alignItems: 'center', gap: 6 }}
              >
                View Agent Dossier ↗
              </Link>
            </div>
          </div>
        </section>
      ) : (
        <section
          className="card"
          data-testid="associated-agent-search"
          style={{
            padding: '14px 20px',
            marginBottom: 20,
            background: 'var(--surface2)',
            border: '1px solid var(--border)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            gap: 16,
            flexWrap: 'wrap',
          }}
        >
          <div style={{ fontSize: 12, color: 'var(--muted)' }}>
            Looking for associated agent activity in the registry?
          </div>
          <Link
            to={`/agents?search=${encodeURIComponent(account.account_name)}`}
            className="btn btn-secondary"
            data-testid="search-agent-registry-btn"
            style={{ fontSize: 12, padding: '5px 12px', textDecoration: 'none', display: 'inline-flex', alignItems: 'center', gap: 6 }}
          >
            Search Agent Registry ↗
          </Link>
        </section>
      )}

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
