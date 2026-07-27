import { useState, useEffect, useCallback } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import type { AgentPosture, NHIAccount } from '../types/api'
import StatusBadge from '../components/StatusBadge'
import EmptyState from '../components/EmptyState'
import ErrorState from '../components/ErrorState'

const POLL_MS = 15 * 60 * 1000

function fmtDate(iso: string | null) {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })
}

function AgentCard({ agent }: { agent: AgentPosture }) {
  const passing = agent.results.filter((r) => r.status === 'pass').length
  const failing = agent.results.filter((r) => r.status === 'fail').length
  const pending = agent.results.filter((r) => r.status === 'pending' || r.status === 'reassessment_requested').length
  const total = agent.results.length
  const hasScore = agent.posture_score !== null

  return (
    <div className="card" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '14px 20px' }}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
        <span style={{ fontWeight: 600, fontSize: 14 }}>{agent.agent_name}</span>
        <span style={{ color: 'var(--muted)', fontSize: 12 }}>{agent.agent_id.split('-')[0]}…</span>
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 24 }}>
        {total > 0 ? (
          <div style={{ display: 'flex', gap: 12, fontSize: 12, color: 'var(--muted)' }}>
            <span style={{ color: 'var(--cyan)' }}>{passing} pass</span>
            {failing > 0 && <span style={{ color: 'var(--error)' }}>{failing} fail</span>}
            {pending > 0 && <span>{pending} pending</span>}
          </div>
        ) : (
          <span style={{ fontSize: 12, color: 'var(--muted)' }}>Not assessed</span>
        )}
        <div style={{ textAlign: 'right' }}>
          {hasScore ? (
            <span style={{ fontWeight: 700, fontSize: 18, color: agent.posture_score! >= 80 ? 'var(--cyan)' : agent.posture_score! >= 50 ? 'var(--warning)' : 'var(--error)' }}>
              {agent.posture_score}%
            </span>
          ) : (
            <span style={{ color: 'var(--muted)', fontSize: 13 }}>—</span>
          )}
          <div style={{ fontSize: 11, color: 'var(--muted)' }}>posture</div>
        </div>
      </div>
    </div>
  )
}

function NHICard({ account }: { account: NHIAccount }) {
  return (
    <div className="card" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '14px 20px' }}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
        <span style={{ fontWeight: 600, fontSize: 14 }}>{account.account_name}</span>
        <span style={{ color: 'var(--muted)', fontSize: 12 }}>{account.directory_source} · discovered {fmtDate(account.first_discovered_at)}</span>
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
        <StatusBadge status={account.privilege_level} variant="privilege" />
        <StatusBadge status={account.status} variant="nhi" />
      </div>
    </div>
  )
}

export default function Agents() {
  const { getAccessTokenSilently } = useAuth0()
  const [tab, setTab] = useState<'governed' | 'discovered'>('governed')

  const [governed, setGoverned] = useState<AgentPosture[]>([])
  const [govLoading, setGovLoading] = useState(true)
  const [govError, setGovError] = useState<string | null>(null)

  const [discovered, setDiscovered] = useState<NHIAccount[]>([])
  const [disLoading, setDisLoading] = useState(true)
  const [disError, setDisError] = useState<string | null>(null)

  const loadGoverned = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const data = await api.compliance.posture(token)
      setGoverned(data.agents)
      setGovError(null)
    } catch (e) {
      setGovError(e instanceof Error ? e.message : 'Failed to load agents')
    } finally {
      setGovLoading(false)
    }
  }, [getAccessTokenSilently])

  const loadDiscovered = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const data = await api.nhi.discovered(token)
      setDiscovered(data.accounts)
      setDisError(null)
    } catch (e) {
      setDisError(e instanceof Error ? e.message : 'Failed to load discovered accounts')
    } finally {
      setDisLoading(false)
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    loadGoverned()
    loadDiscovered()
    const t = setInterval(() => { loadGoverned(); loadDiscovered() }, POLL_MS)
    return () => clearInterval(t)
  }, [loadGoverned, loadDiscovered])

  const tabStyle = (active: boolean): React.CSSProperties => ({
    padding: '8px 18px',
    background: active ? 'var(--surface2)' : 'transparent',
    border: '1px solid',
    borderColor: active ? 'var(--border)' : 'transparent',
    borderRadius: 6,
    color: active ? 'var(--text)' : 'var(--muted)',
    fontSize: 13,
    fontWeight: active ? 600 : 400,
    cursor: 'pointer',
  })

  return (
    <div>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 20 }}>Agents</h1>

      {/* Tabs */}
      <div style={{ display: 'flex', gap: 6, marginBottom: 20 }}>
        <button style={tabStyle(tab === 'governed')} onClick={() => setTab('governed')}>
          Governed{governed.length > 0 && ` (${governed.length})`}
        </button>
        <button style={tabStyle(tab === 'discovered')} onClick={() => setTab('discovered')}>
          Discovered{discovered.length > 0 && ` (${discovered.length})`}
        </button>
      </div>

      {/* Governed tab */}
      {tab === 'governed' && (
        govLoading ? (
          <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 48 }}>Loading…</div>
        ) : govError ? (
          <ErrorState message={govError} onRetry={loadGoverned} />
        ) : governed.length === 0 ? (
          <EmptyState icon="🤖" title="No governed agents" body="Agents appear here after enrollment via the registry API." />
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            {governed.map((a) => <AgentCard key={a.agent_id} agent={a} />)}
          </div>
        )
      )}

      {/* Discovered tab */}
      {tab === 'discovered' && (
        disLoading ? (
          <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 48 }}>Loading…</div>
        ) : disError ? (
          <ErrorState message={disError} onRetry={loadDiscovered} />
        ) : discovered.length === 0 ? (
          <EmptyState icon="🔍" title="No discovered accounts" body="Trigger an NHI scan to discover service accounts in your directory." />
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            {discovered.map((a) => <NHICard key={a.id} account={a} />)}
          </div>
        )
      )}
    </div>
  )
}
