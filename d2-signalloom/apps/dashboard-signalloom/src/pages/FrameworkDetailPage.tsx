import { useState, useEffect, useCallback } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import type { FrameworkResponse, PostureResponse } from '../types/api'
import EmptyState from '../components/EmptyState'
import ErrorState from '../components/ErrorState'

interface ReassessTarget {
  agentId: string
  agentName: string
  controlId: string
  controlName: string
}

const CELL_BG: Record<string, string> = {
  pass: 'rgba(16,185,129,0.12)',
  fail: 'rgba(220,38,38,0.12)',
  reassessment_requested: 'rgba(217,119,6,0.12)',
  pending: 'rgba(71,85,105,0.10)',
}

const CELL_COLOR: Record<string, string> = {
  pass: '#10B981',
  fail: '#DC2626',
  reassessment_requested: '#D97706',
  pending: '#94A3B8',
}

const CELL_ICON: Record<string, string> = {
  pass: '✓',
  fail: '✗',
  reassessment_requested: '↻',
  pending: '○',
}

export default function FrameworkDetailPage() {
  const { frameworkId } = useParams<{ frameworkId: string }>()
  const navigate = useNavigate()
  const { getAccessTokenSilently } = useAuth0()

  const [framework, setFramework] = useState<FrameworkResponse | null>(null)
  const [posture, setPosture] = useState<PostureResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [reassessTarget, setReassessTarget] = useState<ReassessTarget | null>(null)
  const [reassessing, setReassessing] = useState(false)
  const [requestedKeys, setRequestedKeys] = useState<Set<string>>(new Set())

  const load = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const [frameworksRes, postureRes] = await Promise.all([
        api.compliance.frameworks(token),
        api.compliance.posture(token),
      ])
      const fw = frameworksRes.find(f => f.id === frameworkId)
      if (!fw) throw new Error('not_found')
      setFramework(fw)
      setPosture(postureRes)
      setError(null)
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : ''
      if (msg === 'not_found') setError('Framework not found.')
      else if (msg.includes('401') || msg.includes('403')) setError('Your session has expired. Please sign in again.')
      else setError('Something went wrong loading this view. Please try refreshing.')
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently, frameworkId])

  useEffect(() => { load() }, [load])

  async function submitReassess() {
    if (!reassessTarget) return
    setReassessing(true)
    try {
      const token = await getAccessTokenSilently()
      await api.agents.reassess(token, reassessTarget.agentId, reassessTarget.controlId)
      setRequestedKeys(prev => new Set([...prev, `${reassessTarget.agentId}:${reassessTarget.controlId}`]))
      setReassessTarget(null)
    } catch {
      // silent — cell reverts on next poll
    } finally {
      setReassessing(false)
    }
  }

  if (loading) return <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 64 }}>Loading…</div>
  if (error) return <ErrorState message={error} onRetry={load} />
  if (!framework) return <EmptyState title="Framework not found" body="The requested framework does not exist." />

  const agents = posture?.agents ?? []
  const controls = [...framework.controls].sort((a, b) => a.control_order - b.control_order)

  // Build lookup: agentId → controlId → status
  const statusLookup = new Map<string, Map<string, string>>()
  for (const agent of agents) {
    const inner = new Map<string, string>()
    for (const r of agent.results) {
      if (r.framework_name === framework.name) {
        inner.set(r.control_id, r.status)
      }
    }
    statusLookup.set(agent.agent_id, inner)
  }

  return (
    <div style={{ paddingBottom: 32 }}>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12, marginBottom: 24 }}>
        <button
          onClick={() => navigate('/compliance')}
          className="btn btn-secondary"
          style={{ fontSize: 12, padding: '5px 12px', flexShrink: 0, marginTop: 2 }}
        >
          ← Back
        </button>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700 }}>{framework.name}</h1>
          <div style={{ fontSize: 13, color: 'var(--muted)', marginTop: 3 }}>
            {[
              framework.version && `v${framework.version}`,
              framework.regulatory_body,
              `${framework.control_count} controls`,
            ].filter(Boolean).join(' · ')}
          </div>
        </div>
      </div>

      {/* Stats row */}
      <div style={{ display: 'flex', gap: 10, marginBottom: 20 }}>
        {(['pass', 'fail', 'reassessment_requested', 'pending'] as const).map(st => {
          const count = agents.reduce((n, agent) => {
            const inner = statusLookup.get(agent.agent_id) ?? new Map()
            return n + controls.filter(c => inner.get(c.id) === st).length
          }, 0)
          return (
            <div key={st} className="card" style={{ padding: '10px 16px', minWidth: 80 }}>
              <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 4 }}>
                {st === 'reassessment_requested' ? 'Reassessment' : st.charAt(0).toUpperCase() + st.slice(1)}
              </div>
              <div style={{ fontSize: 22, fontWeight: 700, color: CELL_COLOR[st] }}>{count}</div>
            </div>
          )
        })}
      </div>

      {/* Matrix */}
      {agents.length === 0 ? (
        <EmptyState icon="📊" title="No assessment data" body="Run an assessment to populate the agent × controls matrix." />
      ) : (
        <div className="card" style={{ padding: 0, overflow: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
            <thead>
              <tr style={{ background: 'var(--surface2)', borderBottom: '1px solid var(--border)' }}>
                <th style={{ padding: '10px 16px', textAlign: 'left', color: 'var(--muted)', fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em', whiteSpace: 'nowrap', minWidth: 160 }}>
                  Agent
                </th>
                {controls.map(c => (
                  <th
                    key={c.id}
                    title={c.description ?? c.name}
                    style={{ padding: '8px 6px', textAlign: 'center', color: 'var(--muted)', fontWeight: 500, fontSize: 10, maxWidth: 90, wordBreak: 'break-word', lineHeight: 1.3 }}
                  >
                    {c.name}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {agents.map((agent, i) => {
                const inner = statusLookup.get(agent.agent_id) ?? new Map()
                return (
                  <tr
                    key={agent.agent_id}
                    style={{ borderBottom: '1px solid var(--border)', background: i % 2 === 0 ? 'transparent' : 'rgba(255,255,255,0.01)' }}
                  >
                    <td style={{ padding: '10px 16px', fontWeight: 500, whiteSpace: 'nowrap', color: 'var(--text)' }}>
                      <a
                        href={`/agents/${agent.agent_id}`}
                        style={{ color: 'inherit', textDecoration: 'none' }}
                        onMouseEnter={e => (e.currentTarget.style.color = 'var(--cyan)')}
                        onMouseLeave={e => (e.currentTarget.style.color = 'inherit')}
                      >
                        {agent.agent_name}
                      </a>
                      {agent.posture_score !== null && (
                        <span style={{ marginLeft: 8, fontSize: 11, color: 'var(--muted)' }}>{agent.posture_score}%</span>
                      )}
                    </td>
                    {controls.map(c => {
                      const key = `${agent.agent_id}:${c.id}`
                      const status = requestedKeys.has(key) ? 'reassessment_requested' : (inner.get(c.id) ?? undefined)
                      const isFail = status === 'fail'
                      return (
                        <td
                          key={c.id}
                          title={status ? `${status} — ${isFail ? 'Click to request reassessment' : ''}` : 'No data'}
                          onClick={isFail ? () => setReassessTarget({ agentId: agent.agent_id, agentName: agent.agent_name, controlId: c.id, controlName: c.name }) : undefined}
                          style={{
                            padding: '10px 6px', textAlign: 'center',
                            background: status ? CELL_BG[status] : 'transparent',
                            cursor: isFail ? 'pointer' : 'default',
                            fontSize: 15,
                            color: status ? CELL_COLOR[status] : 'var(--border)',
                            transition: 'opacity 0.1s',
                          }}
                          onMouseEnter={e => { if (isFail) e.currentTarget.style.opacity = '0.75' }}
                          onMouseLeave={e => { if (isFail) e.currentTarget.style.opacity = '1' }}
                        >
                          {status ? CELL_ICON[status] : '—'}
                        </td>
                      )
                    })}
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* Legend */}
      <div style={{ marginTop: 12, display: 'flex', gap: 18, flexWrap: 'wrap', fontSize: 12, color: 'var(--muted)' }}>
        {[
          ['✓', 'pass', 'Pass'],
          ['✗', 'fail', 'Fail — click cell to request reassessment'],
          ['↻', 'reassessment_requested', 'Reassessment requested'],
          ['○', 'pending', 'Pending'],
        ].map(([sym, key, label]) => (
          <span key={key} style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
            <span style={{ color: CELL_COLOR[key], fontSize: 14 }}>{sym}</span>
            {label}
          </span>
        ))}
      </div>

      {/* Reassessment modal */}
      {reassessTarget && (
        <div
          style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.65)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1000 }}
          onClick={e => { if (e.target === e.currentTarget) setReassessTarget(null) }}
        >
          <div className="card" style={{ maxWidth: 420, width: '100%', margin: 24, padding: 28 }}>
            <h2 style={{ fontSize: 17, fontWeight: 700, marginBottom: 12 }}>Request Reassessment</h2>
            <p style={{ fontSize: 13, color: 'var(--muted)', lineHeight: 1.6, marginBottom: 8 }}>
              Submit a reassessment request for{' '}
              <strong style={{ color: 'var(--text)' }}>{reassessTarget.agentName}</strong>{' '}
              on control{' '}
              <strong style={{ color: 'var(--text)' }}>{reassessTarget.controlName}</strong>?
            </p>
            <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 24 }}>
              This triggers a new OPA evaluation. Results update within 24 hours.
            </p>
            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
              <button
                className="btn btn-secondary"
                onClick={() => setReassessTarget(null)}
                disabled={reassessing}
              >
                Cancel
              </button>
              <button
                className="btn btn-primary"
                onClick={submitReassess}
                disabled={reassessing}
              >
                {reassessing ? 'Requesting…' : 'Request Reassessment'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
