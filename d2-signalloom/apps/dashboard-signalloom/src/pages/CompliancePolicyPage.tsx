// TODO: migrate table to DataTable (1 small framework breakdown table)
import { useState, useEffect, useCallback } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { colors } from '../styles/tokens'
import { StatCard, Section, Table, td } from '../components/DashKit'
import StatusBadge, { tint } from '../components/StatusBadge'
import LoadingState, { loadPhase } from '../components/LoadingState'
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Cell } from 'recharts'
import type { FrameworkSummary, PostureSummary } from '../types/compliance'

function fmtGbp(n: number) {
  return '£' + n.toLocaleString('en-GB')
}

function fmtPct(n: number, d: number) {
  if (d === 0) return '—'
  return `${Math.round((n / d) * 100)}%`
}

function fmtTimestamp(iso: string) {
  return new Date(iso).toLocaleString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}

function VersionPill({ version, status }: { version: string; status: 'satisfied' | 'partial' | 'not-met' }) {
  const map = {
    satisfied: { bg: tint('var(--teal)', 0.12), color: 'var(--teal)' },
    partial: { bg: tint('var(--amber)', 0.12), color: 'var(--amber)' },
    'not-met': { bg: tint('var(--error)', 0.12), color: 'var(--error)' },
  }
  const s = map[status]
  return (
    <span className="tag" style={{ background: s.bg, color: s.color, marginRight: 4 }}>
      {version}
    </span>
  )
}

export default function CompliancePolicyPage() {
  const { getAccessTokenSilently } = useAuth0()
  const [summary, setSummary] = useState<PostureSummary | null>(null)
  const [frameworks, setFrameworks] = useState<FrameworkSummary[]>([])
  const [scanning, setScanning] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const [fw, sum] = await Promise.all([
        api.compliancePolicy.frameworks(token),
        api.compliancePolicy.summary(token),
      ])
      setFrameworks(fw)
      setSummary(sum)
      setError(null)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load compliance data')
    }
  }, [getAccessTokenSilently])

  useEffect(() => { load() }, [load])

  async function handleScan() {
    setScanning(true)
    try {
      const token = await getAccessTokenSilently()
      const result = await api.compliancePolicy.scan(token, {
        namespace: 'default',
        policyVersion: 'v2.1',
        frameworks: frameworks.map((f) => f.id),
      })
      setSummary(result.summary)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Scan failed')
    } finally {
      setScanning(false)
    }
  }

  const chartData = frameworks.map((fw) => ({
    name: fw.name,
    coverage: fw.totalControls > 0 ? Math.round((fw.passedControls / fw.totalControls) * 100) : 0,
  }))

  return (
    <div>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 24 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, color: 'var(--text)', margin: 0 }}>Policy Compliance</h1>
          {summary && (
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
              Last scan: {fmtTimestamp(summary.scanTimestamp)}
            </div>
          )}
        </div>
        <button className="btn btn-primary" onClick={handleScan} disabled={scanning}>
          {scanning ? 'Scanning...' : 'Scan Now'}
        </button>
      </div>

      <div className="card" style={{ padding: 16, marginBottom: 16 }}>
        <LoadingState
          status={loadPhase({ loading: scanning, error, loaded: summary !== null })}
          label="compliance data"
          error={error}
          onRetry={load}
          testId="compliance-policy-load-state"
        />
      </div>

      {/* Stat cards */}
      {summary && (
        <div style={{ display: 'flex', gap: 12, marginBottom: 24, flexWrap: 'wrap' }}>
          <StatCard label="Total Checks" value={String(summary.totalChecks)} sub={`${summary.passed} passed`} accent={colors.cyanLoom} />
          <StatCard label="Passed" value={String(summary.passed)} sub={fmtPct(summary.passed, summary.totalChecks)} accent={colors.tealLoom} />
          <StatCard label="Failed" value={String(summary.failed)} sub={fmtPct(summary.failed, summary.totalChecks)} accent={summary.failed > 0 ? colors.red : colors.tealLoom} />
          <StatCard label="Total Exposure" value={fmtGbp(summary.totalCarriedGbp)} sub="carried risk" accent={summary.totalCarriedGbp > 0 ? colors.amber : colors.tealLoom} />
        </div>
      )}

      {/* Framework cards */}
      <Section title="Frameworks" hint={`${frameworks.length} registered`}>
        <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 16 }}>
          {frameworks.map((fw) => {
            const coverage = fw.totalControls > 0 ? Math.round((fw.passedControls / fw.totalControls) * 100) : 0
            const currentVersion = fw.versions[fw.versions.length - 1] ?? '—'
            return (
              <div key={fw.id} className="card" style={{ flex: '1 1 280px', padding: 16 }}>
                <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--text)', marginBottom: 8 }}>{fw.name}</div>
                <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 8 }}>
                  Current version: <strong style={{ color: 'var(--text)' }}>{currentVersion}</strong>
                </div>
                <div style={{ marginBottom: 8 }}>
                  {fw.versions.map((v) => {
                    const status = v === currentVersion ? 'satisfied' : coverage > 50 ? 'partial' : 'not-met'
                    return <VersionPill key={v} version={v} status={status} />
                  })}
                </div>
                <div style={{ fontSize: 12, color: 'var(--muted)' }}>
                  {fw.passedControls}/{fw.totalControls} controls passing ({coverage}%) | {fmtGbp(fw.totalExposureGbp)} exposure
                </div>
              </div>
            )
          })}
        </div>
      </Section>

      {/* Coverage chart */}
      {chartData.length > 0 && (
        <Section title="Coverage by Framework" hint="percentage of controls passing">
          <div className="card" style={{ padding: 16 }}>
            <ResponsiveContainer width="100%" height={220}>
              <BarChart data={chartData} margin={{ top: 8, right: 16, bottom: 0, left: 0 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis dataKey="name" tick={{ fill: 'var(--muted)', fontSize: 12 }} />
                <YAxis domain={[0, 100]} tick={{ fill: 'var(--muted)', fontSize: 12 }} unit="%" />
                <Tooltip
                  contentStyle={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 8 }}
                  labelStyle={{ color: 'var(--text)' }}
                  itemStyle={{ color: 'var(--muted)' }}
                />
                <Bar dataKey="coverage" radius={[4, 4, 0, 0]}>
                  {chartData.map((d, i) => (
                    <Cell key={i} fill={d.coverage >= 80 ? colors.tealLoom : d.coverage >= 50 ? colors.amber : colors.red} />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </div>
        </Section>
      )}

      {/* Framework breakdown table */}
      <Section title="Framework Breakdown" hint="per-framework detail">
        <Table headers={['Framework', 'Control Set', 'Controls', 'Passed', 'Coverage', 'Exposure']}>
          {frameworks.map((fw) => (
            <tr key={fw.id} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={td}>{fw.name}</td>
              <td style={td}>{fw.versions.join(', ')}</td>
              <td style={td}>{fw.totalControls}</td>
              <td style={td}>{fw.passedControls}</td>
              <td style={td}>
                <StatusBadge
                  status={fw.passedControls === fw.totalControls ? 'pass' : 'fail'}
                  variant="compliance"
                />
                {' '}{fmtPct(fw.passedControls, fw.totalControls)}
              </td>
              <td style={td}>{fmtGbp(fw.totalExposureGbp)}</td>
            </tr>
          ))}
        </Table>
      </Section>
    </div>
  )
}
