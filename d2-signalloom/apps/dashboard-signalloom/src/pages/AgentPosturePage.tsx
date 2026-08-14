// TODO: migrate tables to DataTable (expandable accordion tables — may need DataTable extension for nested rows)
import { useState, useEffect, useCallback, useMemo } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { colors } from '../styles/tokens'
import { StatCard, Section, Table, td } from '../components/DashKit'
import StatusBadge, { tint } from '../components/StatusBadge'
import LoadingState, { loadPhase } from '../components/LoadingState'
import type { ComplianceCheck, PostureSummary } from '../types/compliance'
import { useMoney } from '../money/CurrencyContext'
import ConversionNote from '../components/ConversionNote'

interface ControlSetGroup {
  controlSet: string
  controls: ControlGroup[]
}

interface ControlGroup {
  control: string
  checks: ComplianceCheck[]
}

function groupChecks(checks: ComplianceCheck[]): ControlSetGroup[] {
  const setMap = new Map<string, Map<string, ComplianceCheck[]>>()
  for (const c of checks) {
    if (!setMap.has(c.controlSet)) setMap.set(c.controlSet, new Map())
    const ctrlMap = setMap.get(c.controlSet)!
    if (!ctrlMap.has(c.control)) ctrlMap.set(c.control, [])
    ctrlMap.get(c.control)!.push(c)
  }
  return Array.from(setMap.entries()).map(([controlSet, ctrlMap]) => ({
    controlSet,
    controls: Array.from(ctrlMap.entries()).map(([control, checks]) => ({ control, checks })),
  }))
}

export default function AgentPosturePage() {
  const { getAccessTokenSilently } = useAuth0()
  // Exposure figures are source-currency amounts converted for display;
  // `fmt` yields "Unavailable" rather than an unconverted number if no rate
  // exists, and `conversionNote` states the rate and its effective date.
  const { fmt, conversionNote } = useMoney()
  const [summary, setSummary] = useState<PostureSummary | null>(null)
  const [checks, setChecks] = useState<ComplianceCheck[]>([])
  const [error, setError] = useState<string | null>(null)
  const [frameworkFilter, setFrameworkFilter] = useState<string>('all')
  const [statusFilter, setStatusFilter] = useState<string>('all')
  const [expandedSets, setExpandedSets] = useState<Set<string>>(new Set())

  const load = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const scanResult = await api.compliancePolicy.scan(token, {
        namespace: 'default', policyVersion: 'v2.0', frameworks: [],
      })
      setSummary(scanResult.summary)
      setChecks(scanResult.checks)
      setError(null)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load posture data')
    }
  }, [getAccessTokenSilently])

  useEffect(() => { load() }, [load])

  const filteredChecks = useMemo(() => {
    let result = checks
    if (frameworkFilter !== 'all') {
      result = result.filter((c) => c.framework === frameworkFilter)
    }
    if (statusFilter !== 'all') {
      result = result.filter((c) => (statusFilter === 'pass' ? c.passed : !c.passed))
    }
    return result
  }, [checks, frameworkFilter, statusFilter])

  const grouped = useMemo(() => groupChecks(filteredChecks), [filteredChecks])
  const frameworkNames = useMemo(() => [...new Set(checks.map((c) => c.framework))], [checks])

  const passedCount = filteredChecks.filter((c) => c.passed).length
  const totalExposure = filteredChecks.reduce((s, c) => s + c.carriedGbp, 0)

  const overallPosture = summary
    ? summary.failed === 0 ? 'COMPLIANT' : summary.failed <= 3 ? 'PARTIAL' : 'NON-COMPLIANT'
    : '—'

  const postureBadgeStatus = overallPosture === 'COMPLIANT' ? 'pass' : overallPosture === 'PARTIAL' ? 'pending' : 'fail'

  function toggleSet(name: string) {
    setExpandedSets((prev) => {
      const next = new Set(prev)
      if (next.has(name)) next.delete(name)
      else next.add(name)
      return next
    })
  }

  return (
    <div>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 24 }}>
        <div style={{ flex: 1 }}>
          <h1 style={{ fontSize: 22, fontWeight: 700, color: 'var(--text)', margin: 0 }}>
            Agent Posture
          </h1>
          <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
            olly-sentinel | namespace: default
          </div>
          <ConversionNote note={conversionNote} testId="posture-conversion-note" />
        </div>
        <StatusBadge status={postureBadgeStatus} variant="compliance" />
        <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>{overallPosture}</span>
      </div>

      <div className="card" style={{ padding: 16, marginBottom: 16 }}>
        <LoadingState
          status={loadPhase({ loading: false, error, loaded: summary !== null })}
          label="posture data"
          error={error}
          onRetry={load}
          testId="agent-posture-load-state"
        />
      </div>

      {/* Summary bar */}
      <div style={{ display: 'flex', gap: 12, marginBottom: 24, flexWrap: 'wrap' }}>
        <StatCard
          label="Checks Passed"
          value={`${passedCount}/${filteredChecks.length}`}
          sub="across all frameworks"
          accent={colors.tealLoom}
        />
        <StatCard
          label="Total Exposure"
          value={fmt(totalExposure)}
          sub="carried risk from failures"
          accent={totalExposure > 0 ? colors.amber : colors.tealLoom}
        />
      </div>

      {/* Filters */}
      <div style={{ display: 'flex', gap: 12, marginBottom: 16, alignItems: 'center' }}>
        <label style={{ fontSize: 12, color: 'var(--muted)' }}>Framework:</label>
        <select
          value={frameworkFilter}
          onChange={(e) => setFrameworkFilter(e.target.value)}
          style={{ fontSize: 13 }}
        >
          <option value="all">All</option>
          {frameworkNames.map((n) => <option key={n} value={n}>{n}</option>)}
        </select>

        <label style={{ fontSize: 12, color: 'var(--muted)', marginLeft: 12 }}>Status:</label>
        <select
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)}
          style={{ fontSize: 13 }}
        >
          <option value="all">All</option>
          <option value="pass">Pass</option>
          <option value="fail">Fail</option>
        </select>
      </div>

      {/* Expandable control sets (Gemara hierarchy) */}
      {grouped.map((csg) => (
        <Section key={csg.controlSet} title={csg.controlSet} hint={`${csg.controls.length} controls`}>
          {csg.controls.map((cg) => {
            const isExpanded = expandedSets.has(`${csg.controlSet}:${cg.control}`)
            const allPassed = cg.checks.every((c) => c.passed)
            return (
              <div key={cg.control} className="card" style={{ marginBottom: 8, overflow: 'hidden' }}>
                <button
                  onClick={() => toggleSet(`${csg.controlSet}:${cg.control}`)}
                  style={{
                    width: '100%',
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    padding: '10px 14px',
                    background: 'none',
                    border: 'none',
                    cursor: 'pointer',
                    color: 'var(--text)',
                    fontSize: 13,
                    fontWeight: 600,
                    fontFamily: 'inherit',
                  }}
                >
                  <span>{cg.control} — {cg.checks[0]?.check.replace(/^\[olly-sentinel\] /, '')}</span>
                  <span style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <StatusBadge status={allPassed ? 'pass' : 'fail'} variant="compliance" />
                    <span style={{ fontSize: 11, color: 'var(--muted)' }}>{isExpanded ? '▲' : '▼'}</span>
                  </span>
                </button>
                {isExpanded && (
                  <Table headers={['Check', 'Status', 'Policy Version', 'ALE', 'VaR95']}>
                    {cg.checks.map((c, i) => (
                      <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
                        <td style={td}>{c.check}</td>
                        <td style={td}>
                          <span style={{ color: c.passed ? 'var(--teal)' : 'var(--error)', fontWeight: 700 }}>
                            {c.passed ? '\u2713' : '\u2717'}
                          </span>
                        </td>
                        <td style={td}>
                          <span className="tag" style={{
                            background: tint('var(--cyan)', 0.12),
                            color: 'var(--cyan)',
                          }}>
                            {c.policyVersion}
                          </span>
                        </td>
                        <td style={td}>{fmt(c.ale)}</td>
                        <td style={td}>{fmt(c.var95)}</td>
                      </tr>
                    ))}
                  </Table>
                )}
              </div>
            )
          })}
        </Section>
      ))}
    </div>
  )
}
