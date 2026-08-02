import { useState, useEffect, useCallback, useMemo } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { colors } from '../styles/tokens'
import { StatCard, Section, Table, td } from '../components/DashKit'
import { tint } from '../components/StatusBadge'
import { AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts'
import type { PostureSummary } from '../types/compliance'

function fmtGbp(n: number) {
  return '£' + n.toLocaleString('en-GB')
}

/** Simulate a loss-exceedance curve from aggregate risk numbers. */
function buildExceedanceCurve(ale: number, var95: number, tvar: number) {
  const points = []
  const steps = 20
  for (let i = 0; i <= steps; i++) {
    const probability = 1 - (i / steps)
    // Exponential interpolation from ALE (high probability) to TVaR (low probability)
    const t = i / steps
    const loss = Math.round(ale + (tvar - ale) * Math.pow(t, 1.8))
    points.push({
      probability: Math.round(probability * 100),
      loss,
      label: `${Math.round(probability * 100)}%`,
    })
  }
  return points
}

const VERSIONS = ['v1.0', 'v2.0', 'v2.1']

export default function RiskExposurePage() {
  const { getAccessTokenSilently } = useAuth0()
  const [summary, setSummary] = useState<PostureSummary | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [selectedVersion, setSelectedVersion] = useState('v2.0')
  const [loading, setLoading] = useState(false)

  const loadSummary = useCallback(async (version: string) => {
    setLoading(true)
    try {
      const token = await getAccessTokenSilently()
      const result = await api.compliancePolicy.scan(token, {
        namespace: 'default',
        policyVersion: version,
        frameworks: [],
      })
      setSummary(result.summary)
      setError(null)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load risk data')
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently])

  useEffect(() => { loadSummary(selectedVersion) }, [loadSummary, selectedVersion])

  const exceedanceCurve = useMemo(() => {
    if (!summary) return []
    return buildExceedanceCurve(summary.totalAle, summary.totalVar95, summary.totalTvar)
  }, [summary])

  function handleVersionChange(e: React.ChangeEvent<HTMLSelectElement>) {
    setSelectedVersion(e.target.value)
  }

  return (
    <div>
      {/* Header */}
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 22, fontWeight: 700, color: 'var(--text)', margin: 0 }}>Risk Exposure</h1>
        <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
          What does a breach cost? Quantified risk across all frameworks.
        </div>
      </div>

      {error && (
        <div className="card" style={{ padding: 16, marginBottom: 16, color: 'var(--error)' }}>
          {error}
        </div>
      )}

      {/* Big stat cards */}
      {summary && (
        <div style={{ display: 'flex', gap: 12, marginBottom: 24, flexWrap: 'wrap' }}>
          <div className="card" style={{ flex: 1, minWidth: 180, padding: '16px 18px' }}>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>Total ALE</div>
            <div style={{ fontSize: 28, fontWeight: 700, color: colors.amber, lineHeight: 1 }}>{fmtGbp(summary.totalAle)}</div>
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6 }}>
              Annualised Loss Expectancy
              <span className="tag" style={{ background: tint('var(--cyan)', 0.12), color: 'var(--cyan)', marginLeft: 8 }}>
                industry-indicative
              </span>
            </div>
          </div>
          <div className="card" style={{ flex: 1, minWidth: 180, padding: '16px 18px' }}>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>Total VaR&#x2089;&#x2085;</div>
            <div style={{ fontSize: 28, fontWeight: 700, color: colors.red, lineHeight: 1 }}>{fmtGbp(summary.totalVar95)}</div>
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6 }}>
              95th percentile Value at Risk
              <span className="tag" style={{ background: tint('var(--cyan)', 0.12), color: 'var(--cyan)', marginLeft: 8 }}>
                industry-indicative
              </span>
            </div>
          </div>
          <div className="card" style={{ flex: 1, minWidth: 180, padding: '16px 18px' }}>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>Total TVaR</div>
            <div style={{ fontSize: 28, fontWeight: 700, color: colors.red, lineHeight: 1 }}>{fmtGbp(summary.totalTvar)}</div>
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6 }}>
              Tail Value at Risk (expected shortfall)
              <span className="tag" style={{ background: tint('var(--cyan)', 0.12), color: 'var(--cyan)', marginLeft: 8 }}>
                industry-indicative
              </span>
            </div>
          </div>
          <div className="card" style={{ flex: 1, minWidth: 180, padding: '16px 18px' }}>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>Carried Risk</div>
            <div style={{ fontSize: 28, fontWeight: 700, color: summary.totalCarriedGbp > 0 ? colors.amber : colors.tealLoom, lineHeight: 1 }}>{fmtGbp(summary.totalCarriedGbp)}</div>
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6 }}>
              residual from failing controls
              <span className="tag" style={{ background: tint('var(--cyan)', 0.12), color: 'var(--cyan)', marginLeft: 8 }}>
                industry-indicative
              </span>
            </div>
          </div>
        </div>
      )}

      {/* Loss exceedance curve */}
      {exceedanceCurve.length > 0 && (
        <Section title="Loss Exceedance Curve" hint="simulated from aggregate posture data">
          <div className="card" style={{ padding: 16 }}>
            <ResponsiveContainer width="100%" height={280}>
              <AreaChart data={exceedanceCurve} margin={{ top: 8, right: 16, bottom: 0, left: 16 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis
                  dataKey="probability"
                  reversed
                  tick={{ fill: 'var(--muted)', fontSize: 12 }}
                  label={{ value: 'Probability (%)', position: 'insideBottom', offset: -4, fill: 'var(--muted)', fontSize: 11 }}
                />
                <YAxis
                  tick={{ fill: 'var(--muted)', fontSize: 12 }}
                  tickFormatter={(v: number) => `£${(v / 1000).toFixed(0)}k`}
                  label={{ value: 'Loss (£)', angle: -90, position: 'insideLeft', fill: 'var(--muted)', fontSize: 11 }}
                />
                <Tooltip
                  contentStyle={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 8 }}
                  labelStyle={{ color: 'var(--text)' }}
                  formatter={(value) => [fmtGbp(Number(value)), 'Loss']}
                  labelFormatter={(label) => `Probability: ${label}%`}
                />
                <Area
                  type="monotone"
                  dataKey="loss"
                  stroke={colors.red}
                  fill={colors.red}
                  fillOpacity={0.15}
                  strokeWidth={2}
                />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        </Section>
      )}

      {/* Per-framework breakdown */}
      {summary && (
        <Section title="Framework Breakdown" hint="risk by regulatory framework">
          <Table headers={['Framework', 'ALE', 'VaR95', 'TVaR', 'Carried']}>
            {summary.frameworks.map((fw) => (
              <tr key={fw.id} style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={td}>{fw.name}</td>
                <td style={td}>{fmtGbp(fw.totalControls > 0 ? Math.round(summary.totalAle * (fw.totalControls / summary.totalChecks)) : 0)}</td>
                <td style={td}>{fmtGbp(fw.totalControls > 0 ? Math.round(summary.totalVar95 * (fw.totalControls / summary.totalChecks)) : 0)}</td>
                <td style={td}>{fmtGbp(fw.totalControls > 0 ? Math.round(summary.totalTvar * (fw.totalControls / summary.totalChecks)) : 0)}</td>
                <td style={td}>{fmtGbp(fw.totalExposureGbp)}</td>
              </tr>
            ))}
          </Table>
        </Section>
      )}

      {/* What-if section */}
      <Section title="What If" hint="switch policy version to see impact on risk">
        <div className="card" style={{ padding: 16 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 16 }}>
            <label style={{ fontSize: 13, color: 'var(--text)' }}>Policy Version:</label>
            <select
              value={selectedVersion}
              onChange={handleVersionChange}
              style={{ fontSize: 13 }}
              data-testid="version-select"
            >
              {VERSIONS.map((v) => <option key={v} value={v}>{v}</option>)}
            </select>
            {loading && <span style={{ fontSize: 12, color: 'var(--muted)' }}>Loading...</span>}
          </div>
          {summary && (
            <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
              <StatCard label="ALE" value={fmtGbp(summary.totalAle)} sub={`at ${selectedVersion}`} accent={colors.amber} />
              <StatCard label="VaR95" value={fmtGbp(summary.totalVar95)} sub={`at ${selectedVersion}`} accent={colors.red} />
              <StatCard label="TVaR" value={fmtGbp(summary.totalTvar)} sub={`at ${selectedVersion}`} accent={colors.red} />
              <StatCard label="Carried" value={fmtGbp(summary.totalCarriedGbp)} sub={`at ${selectedVersion}`} accent={summary.totalCarriedGbp > 0 ? colors.amber : colors.tealLoom} />
            </div>
          )}
        </div>
      </Section>
    </div>
  )
}
