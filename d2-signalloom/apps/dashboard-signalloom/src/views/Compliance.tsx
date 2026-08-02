import { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { PieChart, Pie, Cell } from 'recharts'
import { api } from '../api/client'
import type { AgentResponse, FrameworkResponse, PostureResponse, AgentPosture } from '../types/api'
import { useAppContext } from '../App'
import { donutDefaults } from '../styles/tokens'
import StatusBadge from '../components/StatusBadge'
import EmptyState from '../components/EmptyState'
import ErrorState from '../components/ErrorState'

const POLL_MS = 15 * 60 * 1000

type PostureCategory = 'good' | 'warning' | 'critical' | 'pending'

function categorize(score: number | null): PostureCategory {
  if (score === null) return 'pending'
  if (score >= 80) return 'good'
  if (score >= 50) return 'warning'
  return 'critical'
}

const CAT_COLOR: Record<PostureCategory, string> = {
  good: '#10B981',
  warning: '#D97706',
  critical: '#DC2626',
  pending: '#475569',
}

const CAT_LABEL: Record<PostureCategory, string> = {
  good: 'Good',
  warning: 'Warning',
  critical: 'Critical',
  pending: 'Pending',
}

function PostureBar({ score }: { score: number | null }) {
  const pct = score ?? 0
  const color = CAT_COLOR[categorize(score)]
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, minWidth: 140 }}>
      <div style={{ flex: 1, height: 6, background: 'var(--surface2)', borderRadius: 3, overflow: 'hidden' }}>
        <div style={{ width: `${pct}%`, height: '100%', background: color, borderRadius: 3 }} />
      </div>
      <span style={{ fontSize: 11, color: 'var(--muted)', minWidth: 28, textAlign: 'right' }}>
        {score !== null ? `${score}%` : '—'}
      </span>
    </div>
  )
}

function fmtDate(iso: string | null) {
  if (!iso) return null
  return new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })
}

function agentFrameworkStatus(agent: AgentPosture, frameworkName: string): string | null {
  const results = agent.results.filter(r => r.framework_name === frameworkName)
  if (results.length === 0) return null
  if (results.some(r => r.status === 'fail')) return 'fail'
  if (results.some(r => r.status === 'reassessment_requested')) return 'reassessment_requested'
  if (results.every(r => r.status === 'pass')) return 'pass'
  return 'pending'
}

function lastAssessed(agent: AgentPosture): string | null {
  const dates = agent.results
    .map(r => r.assessed_at)
    .filter((d): d is string => d !== null)
    .sort()
  return dates.length ? dates[dates.length - 1] : null
}

export default function Compliance() {
  const navigate = useNavigate()
  const { getAccessTokenSilently } = useAuth0()
  const { setFailingControls } = useAppContext()

  const [posture, setPosture] = useState<PostureResponse | null>(null)
  const [frameworks, setFrameworks] = useState<FrameworkResponse[]>([])
  const [agentMap, setAgentMap] = useState<Map<string, AgentResponse>>(new Map())
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [filterSegment, setFilterSegment] = useState<PostureCategory | null>(null)
  const [exportOpen, setExportOpen] = useState(false)
  const [exporting, setExporting] = useState(false)
  const [exportNote, setExportNote] = useState<string | null>(null)

  const load = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const [postureRes, frameworksRes, summaryRes, agentsRes, settingsRes] = await Promise.all([
        api.compliance.posture(token),
        api.compliance.frameworks(token),
        api.compliance.summary(token),
        api.agents.list(token),
        api.settings(token),
      ])
      setPosture(postureRes)
      const sel = settingsRes?.selected_frameworks ?? []
      setFrameworks(
        sel.length > 0 ? frameworksRes.filter(fw => sel.includes(fw.id)) : frameworksRes
      )
      setFailingControls(summaryRes.controls_failing)
      const map = new Map<string, AgentResponse>()
      for (const a of agentsRes.agents) map.set(a.id, a)
      setAgentMap(map)
      setError(null)
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : ''
      if (msg.includes('401') || msg.includes('403')) {
        setError('Your session has expired. Please sign in again.')
      } else {
        setError('Something went wrong loading this view. Please try refreshing.')
      }
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently, setFailingControls])

  useEffect(() => {
    load()
    const t = setInterval(load, POLL_MS)
    return () => clearInterval(t)
  }, [load])

  async function exportJson() {
    setExporting(true)
    setExportOpen(false)
    setExportNote(null)
    try {
      const token = await getAccessTokenSilently()
      const data = await api.compliance.export(token, 'json')
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `evidence-package-${new Date().toISOString().slice(0, 10)}.json`
      a.click()
      URL.revokeObjectURL(url)
    } catch {
      setExportNote('Export failed. Please try again.')
    } finally {
      setExporting(false)
    }
  }

  if (loading) return <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 64 }}>Loading…</div>
  if (error) return <ErrorState message={error} onRetry={load} />

  const agents = posture?.agents ?? []

  const catCounts: Record<PostureCategory, number> = { good: 0, warning: 0, critical: 0, pending: 0 }
  for (const a of agents) catCounts[categorize(a.posture_score)]++

  const donutData = (['good', 'warning', 'critical', 'pending'] as PostureCategory[])
    .map(k => ({ name: CAT_LABEL[k], value: catCounts[k], key: k, color: CAT_COLOR[k] }))

  const hasData = agents.length > 0

  const filteredAgents = filterSegment
    ? agents.filter(a => categorize(a.posture_score) === filterSegment)
    : agents

  return (
    <div style={{ paddingBottom: 32 }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 20 }}>Compliance</h1>

      {/* Top row: donut + framework cards */}
      <div style={{ display: 'flex', gap: 20, marginBottom: 24, alignItems: 'flex-start' }}>

        {/* Posture donut */}
        <div className="card" style={{ flexShrink: 0, padding: '20px 16px', display: 'flex', flexDirection: 'column', alignItems: 'center', width: 220 }}>
          <div style={{ position: 'relative', width: 160, height: 160 }}>
            <PieChart width={160} height={160}>
              <Pie
                data={hasData ? donutData.filter(d => d.value > 0) : [{ name: 'No data', value: 1, key: 'pending', color: '#334155' }]}
                cx={80} cy={80}
                innerRadius={52} outerRadius={72}
                dataKey="value"
                paddingAngle={donutDefaults.paddingAngle}
                cornerRadius={donutDefaults.cornerRadius}
                stroke={donutDefaults.stroke}
                onClick={(_: unknown, index: number) => {
                  if (!hasData) return
                  const visible = donutData.filter(d => d.value > 0)
                  const key = visible[index]?.key as PostureCategory
                  if (key) setFilterSegment(prev => prev === key ? null : key)
                }}
                style={{ cursor: hasData ? 'pointer' : 'default' }}
              >
                {(hasData ? donutData.filter(d => d.value > 0) : [{ color: '#334155' }]).map((entry, i) => (
                  <Cell
                    key={i}
                    fill={entry.color}
                    opacity={filterSegment && 'key' in entry && filterSegment !== (entry as { key: string }).key ? 0.3 : 1}
                  />
                ))}
              </Pie>
            </PieChart>
            <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', pointerEvents: 'none' }}>
              <span style={{ fontSize: 43, fontWeight: 500, color: 'var(--text)', lineHeight: 1 }}>{agents.length}</span>
              <span style={{ fontSize: 10.5, fontWeight: 600, letterSpacing: '0.06em', textTransform: 'uppercase', color: 'var(--dim)', marginTop: 6 }}>agents</span>
            </div>
          </div>

          <div style={{ marginTop: 14, display: 'flex', flexDirection: 'column', gap: 5, width: '100%' }}>
            {(['good', 'warning', 'critical', 'pending'] as PostureCategory[]).map(k => (
              <button
                key={k}
                onClick={() => setFilterSegment(prev => prev === k ? null : k)}
                style={{
                  display: 'flex', alignItems: 'center', gap: 7,
                  background: filterSegment === k ? 'rgba(255,255,255,0.07)' : 'transparent',
                  border: 'none', cursor: 'pointer', borderRadius: 4, padding: '3px 6px', width: '100%',
                  opacity: filterSegment && filterSegment !== k ? 0.45 : 1,
                  transition: 'opacity 0.15s',
                }}
              >
                <span style={{ width: 10, height: 10, borderRadius: 2, background: CAT_COLOR[k], flexShrink: 0 }} />
                <span style={{ fontSize: 12, color: 'var(--text)', flex: 1, textAlign: 'left' }}>{CAT_LABEL[k]}</span>
                <span style={{ fontSize: 12, color: 'var(--muted)', fontWeight: 600 }}>{catCounts[k]}</span>
              </button>
            ))}
          </div>
        </div>

        {/* Framework cards */}
        <div style={{ flex: 1 }}>
          <h2 style={{ fontSize: 11, fontWeight: 700, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 10 }}>Active Frameworks</h2>
          {frameworks.length === 0 ? (
            <EmptyState kicker="No frameworks activated" body="Governance frameworks appear after seeding via the migration script." />
          ) : (
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(200px, 1fr))', gap: 10 }}>
              {frameworks.map(fw => {
                const allResults = agents.flatMap(a => a.results.filter(r => r.framework_name === fw.name))
                const passing = allResults.filter(r => r.status === 'pass').length
                const total = allResults.length || fw.control_count
                return (
                  <button
                    key={fw.id}
                    onClick={() => navigate(`/compliance/${fw.id}`)}
                    style={{
                      padding: '14px 16px', textAlign: 'left', cursor: 'pointer',
                      border: '1px solid var(--border)', background: 'var(--surface)',
                      borderRadius: 8, width: '100%', transition: 'border-color 0.15s',
                    }}
                    onMouseEnter={e => (e.currentTarget.style.borderColor = 'var(--cyan)')}
                    onMouseLeave={e => (e.currentTarget.style.borderColor = 'var(--border)')}
                  >
                    <div style={{ fontWeight: 600, fontSize: 14, color: 'var(--text)', marginBottom: 4 }}>{fw.name}</div>
                    {(fw.version || fw.regulatory_body) && (
                      <div style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 8 }}>
                        {[fw.version && `v${fw.version}`, fw.regulatory_body].filter(Boolean).join(' · ')}
                      </div>
                    )}
                    <div style={{ fontSize: 12 }}>
                      <span style={{ color: '#10B981', fontWeight: 600 }}>{passing}</span>
                      <span style={{ color: 'var(--muted)' }}> / {total} passing</span>
                    </div>
                    {fw.compliance_deadline && (
                      <div style={{ marginTop: 6, fontSize: 11, color: 'var(--amber)' }}>
                        Due {new Date(fw.compliance_deadline).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })}
                      </div>
                    )}
                    <div style={{ marginTop: 8, fontSize: 11, color: 'var(--cyan)' }}>View details →</div>
                  </button>
                )
              })}
            </div>
          )}
        </div>
      </div>

      {/* Table toolbar */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <h2 style={{ fontSize: 16, fontWeight: 700 }}>Agent Posture</h2>
          {filterSegment && (
            <button
              onClick={() => setFilterSegment(null)}
              style={{ fontSize: 12, color: 'var(--text)', background: 'var(--surface2)', border: 'none', borderRadius: 4, padding: '2px 8px', cursor: 'pointer' }}
            >
              {CAT_LABEL[filterSegment]} ✕
            </button>
          )}
        </div>
        <div style={{ position: 'relative' }}>
          <button
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '6px 14px' }}
            onClick={() => setExportOpen(o => !o)}
            disabled={exporting}
          >
            {exporting ? 'Exporting…' : 'Export Evidence Package ▾'}
          </button>
          {exportOpen && (
            <div
              style={{ position: 'absolute', right: 0, top: '100%', marginTop: 4, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 6, zIndex: 100, minWidth: 190, overflow: 'hidden', boxShadow: '0 4px 16px rgba(0,0,0,0.4)' }}
            >
              <button
                onClick={exportJson}
                style={{ display: 'block', width: '100%', padding: '10px 16px', background: 'none', border: 'none', color: 'var(--text)', cursor: 'pointer', textAlign: 'left', fontSize: 13 }}
                onMouseEnter={e => (e.currentTarget.style.background = 'var(--surface2)')}
                onMouseLeave={e => (e.currentTarget.style.background = 'none')}
              >
                Export JSON
              </button>
              <button
                onClick={() => { setExportOpen(false); setExportNote('PDF export available in Phase 2.') }}
                style={{ display: 'block', width: '100%', padding: '10px 16px', background: 'none', border: 'none', color: 'var(--muted)', cursor: 'not-allowed', textAlign: 'left', fontSize: 13 }}
              >
                Export PDF (coming soon)
              </button>
            </div>
          )}
        </div>
      </div>
      {exportNote && (
        <div style={{ marginBottom: 10, padding: '8px 12px', background: 'rgba(6,182,212,0.08)', border: '1px solid rgba(6,182,212,0.2)', borderRadius: 6, fontSize: 12, color: 'var(--muted)' }}>
          {exportNote}
          <button onClick={() => setExportNote(null)} style={{ marginLeft: 8, background: 'none', border: 'none', color: 'var(--muted)', cursor: 'pointer', fontSize: 13 }}>✕</button>
        </div>
      )}

      {/* Agent posture table */}
      {filteredAgents.length === 0 ? (
        <EmptyState
          kicker={filterSegment ? `No agents in ${CAT_LABEL[filterSegment]}` : 'No compliance data yet'}
          body={filterSegment ? 'Try a different filter or run an assessment.' : 'Run an assessment to populate agent posture.'}
        />
      ) : (
        <div className="card" style={{ padding: 0, overflow: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
            <thead>
              <tr style={{ background: 'var(--surface2)', borderBottom: '1px solid var(--border)' }}>
                {['Agent', 'Lifecycle', 'Posture Score', ...frameworks.map(f => f.name), 'Last Assessed'].map(h => (
                  <th key={h} style={{ padding: '10px 16px', textAlign: 'left', color: 'var(--muted)', fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em', whiteSpace: 'nowrap' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {filteredAgents.map((a, i) => {
                const agent = agentMap.get(a.agent_id)
                const assessed = lastAssessed(a)
                return (
                  <tr key={a.agent_id} style={{ borderBottom: '1px solid var(--border)', background: i % 2 === 0 ? 'transparent' : 'rgba(255,255,255,0.01)' }}>
                    <td style={{ padding: '10px 16px' }}>
                      <a
                        href={`/agents/${a.agent_id}`}
                        style={{ color: 'var(--text)', fontWeight: 500, textDecoration: 'none' }}
                        onMouseEnter={e => (e.currentTarget.style.color = 'var(--cyan)')}
                        onMouseLeave={e => (e.currentTarget.style.color = 'var(--text)')}
                      >
                        {a.agent_name}
                      </a>
                    </td>
                    <td style={{ padding: '10px 16px' }}>
                      {agent
                        ? <StatusBadge status={agent.lifecycle_state} variant="lifecycle" />
                        : <span style={{ color: 'var(--muted)' }}>—</span>}
                    </td>
                    <td style={{ padding: '10px 16px' }}>
                      <PostureBar score={a.posture_score} />
                    </td>
                    {frameworks.map(fw => {
                      const st = agentFrameworkStatus(a, fw.name)
                      return (
                        <td key={fw.id} style={{ padding: '10px 16px' }}>
                          {st ? <StatusBadge status={st} variant="compliance" /> : <span style={{ color: 'var(--muted)' }}>—</span>}
                        </td>
                      )
                    })}
                    <td style={{ padding: '10px 16px', color: 'var(--muted)', fontSize: 12, whiteSpace: 'nowrap' }}>
                      {fmtDate(assessed) ?? '—'}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
