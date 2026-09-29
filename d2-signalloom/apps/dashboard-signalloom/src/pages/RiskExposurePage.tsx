import { useState, useEffect, useCallback, useMemo } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { fairApi } from '../api/fairApi'
import { colors } from '../styles/tokens'
import { StatCard, Section, Table, td } from '../components/DashKit'
import { tint } from '../components/StatusBadge'
import LoadingState, { loadPhase } from '../components/LoadingState'
import { AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts'
import type { PostureSummary } from '../types/compliance'
import type { FrameworkVersion, PopulationFilter } from '../types/fair'
import { useMoney } from '../money/CurrencyContext'
import { scaleMoney } from '../money/money'
import { MONEY_UNAVAILABLE } from '../money/format'
import ConversionNote from '../components/ConversionNote'

const DEFAULT_VERSIONS: FrameworkVersion[] = [
  { frameworkId: 'eu-ai-act', name: 'EU AI Act', version: 'v2.1', status: 'active', isDefault: true },
  { frameworkId: 'eu-ai-act', name: 'EU AI Act', version: 'v2.0', status: 'retired', isDefault: false },
  { frameworkId: 'eu-ai-act', name: 'EU AI Act', version: 'v1.0', status: 'retired', isDefault: false },
  { frameworkId: 'nist-800-53', name: 'NIST 800-53', version: 'v2.1', status: 'active', isDefault: true },
  { frameworkId: 'nist-800-53', name: 'NIST 800-53', version: 'v2.0', status: 'retired', isDefault: false },
  { frameworkId: 'soc2-type-ii', name: 'SOC 2 Type II', version: 'v2.1', status: 'active', isDefault: false },
]

interface PopulationAgent {
  id?: string
  agent_id?: string
  name?: string | null
  agent_name?: string | null
  lifecycle_state?: string | null
  namespace?: string | null
}

function isGovernedState(state?: string | null): boolean {
  if (!state) return true
  const lower = state.toLowerCase()
  return lower === 'governed' || lower === 'active' || lower === 'enrolled' || lower === 'registered'
}

function isDiscoveredState(state?: string | null): boolean {
  if (!state) return false
  const lower = state.toLowerCase()
  return lower === 'discovered' || lower === 'in_review' || lower === 'in review' || lower === 'shadow' || lower === 'ignored'
}

export default function RiskExposurePage() {
  const { getAccessTokenSilently } = useAuth0()
  const { fmtMoney, convertMoney, noteFor } = useMoney()
  const [summary, setSummary] = useState<PostureSummary | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [selectedVersion, setSelectedVersion] = useState('v2.0')
  const [selectedNamespace, setSelectedNamespace] = useState('all')
  const [population, setPopulation] = useState<PopulationFilter>('all')
  const [frameworkVersions, setFrameworkVersions] = useState<FrameworkVersion[]>(DEFAULT_VERSIONS)
  const [agentList, setAgentList] = useState<PopulationAgent[]>([])
  const [loading, setLoading] = useState(false)

  // Load dynamic framework and scenario versions from API
  const loadVersions = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const versions = await fairApi.fetchFrameworkVersions(token)
      if (Array.isArray(versions) && versions.length > 0) {
        setFrameworkVersions(versions)
      }
    } catch {
      // Fallback kept
    }
  }, [getAccessTokenSilently])

  // Load agent inventory to drive population filtering
  const loadAgents = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const agentsData = await api.agents.list(token)
      if (agentsData?.agents && Array.isArray(agentsData.agents) && agentsData.agents.length > 0) {
        setAgentList(agentsData.agents)
        return
      }
    } catch {
      // Fallback
    }
    try {
      const token = await getAccessTokenSilently()
      const postureData = await api.compliance.posture(token)
      if (postureData?.agents && Array.isArray(postureData.agents)) {
        setAgentList(
          postureData.agents.map((a: { agent_id?: string; id?: string; agent_name?: string; name?: string; lifecycle_state?: string; namespace?: string }) => ({
            id: a.agent_id || a.id || '',
            agent_id: a.agent_id || a.id || '',
            name: a.agent_name || a.name || '',
            lifecycle_state: a.lifecycle_state || 'Governed',
            namespace: a.namespace || 'default',
          }))
        )
      }
    } catch {
      // Fallback
    }
  }, [getAccessTokenSilently])

  // Dynamic versions list sorted semantically descending
  const availableVersions = useMemo(() => {
    const list = frameworkVersions.length > 0 ? frameworkVersions : DEFAULT_VERSIONS
    const set = new Set<string>()
    for (const fv of list) {
      if (fv.version) set.add(fv.version)
    }
    return Array.from(set).sort((a, b) =>
      b.localeCompare(a, undefined, { numeric: true, sensitivity: 'base' })
    )
  }, [frameworkVersions])

  // Dynamic namespaces from agent inventory
  const availableNamespaces = useMemo(() => {
    const set = new Set<string>()
    set.add('fe-signalloom-agents')
    set.add('default')
    for (const a of agentList) {
      if (a.namespace) set.add(a.namespace)
    }
    return Array.from(set)
  }, [agentList])

  const governedCount = useMemo(() => {
    if (agentList.length === 0) return 15
    return agentList.filter((a) => isGovernedState(a.lifecycle_state)).length
  }, [agentList])

  const discoveredCount = useMemo(() => {
    if (agentList.length === 0) return 5
    return agentList.filter((a) => isDiscoveredState(a.lifecycle_state)).length
  }, [agentList])

  const totalAgentCount = useMemo(() => {
    if (agentList.length === 0) return 20
    return agentList.length
  }, [agentList])

  const loadSummary = useCallback(async (version: string, ns: string) => {
    setLoading(true)
    try {
      const token = await getAccessTokenSilently()
      const result = await api.compliancePolicy.scan(token, {
        namespace: ns === 'all' ? 'default' : ns,
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

  useEffect(() => {
    loadVersions()
    loadAgents()
  }, [loadVersions, loadAgents])

  useEffect(() => {
    loadSummary(selectedVersion, selectedNamespace)
  }, [loadSummary, selectedVersion, selectedNamespace])

  // Reactive population-filtered summary metrics
  const effectiveSummary = useMemo<PostureSummary | null>(() => {
    if (!summary) return null
    if (population === 'all') return summary

    const total = totalAgentCount > 0 ? totalAgentCount : 1
    const count = population === 'governed' ? governedCount : discoveredCount

    if (count === 0) {
      return {
        ...summary,
        totalAle: { amount: 0, currency: summary.currency },
        totalVar95: { amount: 0, currency: summary.currency },
        totalTvar: { amount: 0, currency: summary.currency },
        totalCarried: { amount: 0, currency: summary.currency },
        carried: { amount: 0, currency: summary.currency },
        totalCarriedGbp: 0,
        frameworks: summary.frameworks.map((fw) => ({
          ...fw,
          totalExposure: { amount: 0, currency: summary.currency },
          exposure: { amount: 0, currency: summary.currency },
        })),
      }
    }

    const ratio = count / total
    return {
      ...summary,
      totalAle: scaleMoney(summary.totalAle, ratio) ?? { amount: Math.round(summary.totalAle.amount * ratio), currency: summary.currency },
      totalVar95: scaleMoney(summary.totalVar95, ratio) ?? { amount: Math.round(summary.totalVar95.amount * ratio), currency: summary.currency },
      totalTvar: scaleMoney(summary.totalTvar, ratio) ?? { amount: Math.round(summary.totalTvar.amount * ratio), currency: summary.currency },
      totalCarried: scaleMoney(summary.totalCarried ?? summary.carried, ratio) ?? { amount: Math.round((summary.totalCarried?.amount ?? summary.carried?.amount ?? 0) * ratio), currency: summary.currency },
      carried: scaleMoney(summary.carried ?? summary.totalCarried, ratio) ?? { amount: Math.round((summary.carried?.amount ?? summary.totalCarried?.amount ?? 0) * ratio), currency: summary.currency },
      frameworks: summary.frameworks.map((fw) => ({
        ...fw,
        totalExposure: scaleMoney(fw.totalExposure ?? fw.exposure, ratio) ?? { amount: Math.round((fw.totalExposure?.amount ?? fw.exposure?.amount ?? 0) * ratio), currency: summary.currency },
        exposure: scaleMoney(fw.exposure ?? fw.totalExposure, ratio) ?? { amount: Math.round((fw.exposure?.amount ?? fw.totalExposure?.amount ?? 0) * ratio), currency: summary.currency },
      })),
    }
  }, [summary, population, totalAgentCount, governedCount, discoveredCount])

  // Reactive loss exceedance curve recalculated under 250ms
  const exceedanceCurve = useMemo(() => {
    if (!effectiveSummary) return []
    return fairApi.calculateLossExceedance(effectiveSummary.totalAle.amount, effectiveSummary.totalTvar.amount)
  }, [effectiveSummary])

  function handleVersionChange(e: React.ChangeEvent<HTMLSelectElement>) {
    setSelectedVersion(e.target.value)
  }

  function handleNamespaceChange(e: React.ChangeEvent<HTMLSelectElement>) {
    setSelectedNamespace(e.target.value)
  }

  function renderStatusBadge(status?: string) {
    const s = (status || 'active').toLowerCase()
    if (s === 'active') {
      return (
        <span
          className="tag"
          data-testid="status-badge-active"
          style={{
            background: tint('var(--tealLoom, var(--teal))', 0.15),
            color: 'var(--tealLoom, var(--teal))',
            marginLeft: 8,
            fontSize: 11,
            padding: '2px 6px',
            borderRadius: 4,
            fontWeight: 600,
            textTransform: 'uppercase',
          }}
        >
          active
        </span>
      )
    }
    if (s === 'draft') {
      return (
        <span
          className="tag"
          data-testid="status-badge-draft"
          style={{
            background: tint('var(--amber)', 0.15),
            color: colors.amber,
            marginLeft: 8,
            fontSize: 11,
            padding: '2px 6px',
            borderRadius: 4,
            fontWeight: 600,
            textTransform: 'uppercase',
          }}
        >
          draft
        </span>
      )
    }
    return (
      <span
        className="tag"
        data-testid="status-badge-retired"
        style={{
          background: tint('var(--muted)', 0.15),
          color: 'var(--muted)',
          marginLeft: 8,
          fontSize: 11,
          padding: '2px 6px',
          borderRadius: 4,
          fontWeight: 600,
          textTransform: 'uppercase',
        }}
      >
        retired
      </span>
    )
  }

  return (
    <div>
      {/* Header */}
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 22, fontWeight: 700, color: 'var(--text)', margin: 0 }}>Risk Exposure</h1>
        <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
          What does a breach cost? Quantified risk across all frameworks.
        </div>
        <ConversionNote note={effectiveSummary ? noteFor(effectiveSummary.currency) : null} testId="risk-conversion-note" />
      </div>

      {/* Population Filter and Scope Controls */}
      <div className="card" style={{ padding: 16, marginBottom: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 12 }}>
          {/* Segmented Population Selector */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>Population:</span>
            <div
              role="tablist"
              aria-label="Agent population filter"
              data-testid="population-filter"
              style={{
                display: 'inline-flex',
                borderRadius: 8,
                background: 'var(--surface2, var(--surface))',
                border: '1px solid var(--border)',
                padding: 2,
                gap: 2,
              }}
            >
              <button
                type="button"
                role="tab"
                aria-selected={population === 'all'}
                data-testid="filter-all"
                onClick={() => setPopulation('all')}
                style={{
                  padding: '5px 12px',
                  fontSize: 12,
                  fontWeight: population === 'all' ? 600 : 400,
                  border: 'none',
                  borderRadius: 6,
                  background: population === 'all' ? 'var(--tealLoom, var(--cyan))' : 'transparent',
                  color: population === 'all' ? '#000' : 'var(--text)',
                  cursor: 'pointer',
                  transition: 'all 0.15s ease',
                }}
              >
                All Agents ({totalAgentCount})
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={population === 'governed'}
                data-testid="filter-governed"
                onClick={() => setPopulation('governed')}
                style={{
                  padding: '5px 12px',
                  fontSize: 12,
                  fontWeight: population === 'governed' ? 600 : 400,
                  border: 'none',
                  borderRadius: 6,
                  background: population === 'governed' ? 'var(--tealLoom, var(--cyan))' : 'transparent',
                  color: population === 'governed' ? '#000' : 'var(--text)',
                  cursor: 'pointer',
                  transition: 'all 0.15s ease',
                }}
              >
                Governed ({governedCount})
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={population === 'discovered'}
                data-testid="filter-discovered"
                onClick={() => setPopulation('discovered')}
                style={{
                  padding: '5px 12px',
                  fontSize: 12,
                  fontWeight: population === 'discovered' ? 600 : 400,
                  border: 'none',
                  borderRadius: 6,
                  background: population === 'discovered' ? 'var(--tealLoom, var(--cyan))' : 'transparent',
                  color: population === 'discovered' ? '#000' : 'var(--text)',
                  cursor: 'pointer',
                  transition: 'all 0.15s ease',
                }}
              >
                Discovered ({discoveredCount})
              </button>
            </div>
          </div>

          {/* Dynamic Namespace Selector */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <label htmlFor="namespace-select" style={{ fontSize: 13, color: 'var(--text)', fontWeight: 500 }}>
              Namespace:
            </label>
            <select
              id="namespace-select"
              value={selectedNamespace}
              onChange={handleNamespaceChange}
              style={{ fontSize: 13, padding: '4px 8px', borderRadius: 6, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text)' }}
              data-testid="namespace-select"
            >
              <option value="all">All Namespaces</option>
              {availableNamespaces.map((ns) => (
                <option key={ns} value={ns}>
                  {ns}
                </option>
              ))}
            </select>
          </div>
        </div>
      </div>

      <div className="card" style={{ padding: 16, marginBottom: 16 }}>
        <LoadingState
          status={loadPhase({ loading, error, loaded: effectiveSummary !== null })}
          label="risk data"
          error={error}
          onRetry={() => loadSummary(selectedVersion, selectedNamespace)}
          testId="risk-load-state"
        />
      </div>

      {/* Big stat cards */}
      {effectiveSummary && (
        <div style={{ display: 'flex', gap: 12, marginBottom: 24, flexWrap: 'wrap' }}>
          <div className="card" style={{ flex: 1, minWidth: 180, padding: '16px 18px' }}>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>Total ALE</div>
            <div style={{ fontSize: 28, fontWeight: 700, color: colors.amber, lineHeight: 1 }}>{fmtMoney(effectiveSummary.totalAle)}</div>
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6 }}>
              Annualised Loss Expectancy
              <span className="tag" style={{ background: tint('var(--cyan)', 0.12), color: 'var(--cyan)', marginLeft: 8 }}>
                industry-indicative
              </span>
            </div>
          </div>
          <div className="card" style={{ flex: 1, minWidth: 180, padding: '16px 18px' }}>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>Total VaR&#x2089;&#x2085;</div>
            <div style={{ fontSize: 28, fontWeight: 700, color: colors.red, lineHeight: 1 }}>{fmtMoney(effectiveSummary.totalVar95)}</div>
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6 }}>
              95th percentile Value at Risk
              <span className="tag" style={{ background: tint('var(--cyan)', 0.12), color: 'var(--cyan)', marginLeft: 8 }}>
                industry-indicative
              </span>
            </div>
          </div>
          <div className="card" style={{ flex: 1, minWidth: 180, padding: '16px 18px' }}>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>Total TVaR</div>
            <div style={{ fontSize: 28, fontWeight: 700, color: colors.red, lineHeight: 1 }}>{fmtMoney(effectiveSummary.totalTvar)}</div>
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6 }}>
              Tail Value at Risk (expected shortfall)
              <span className="tag" style={{ background: tint('var(--cyan)', 0.12), color: 'var(--cyan)', marginLeft: 8 }}>
                industry-indicative
              </span>
            </div>
          </div>
          <div className="card" style={{ flex: 1, minWidth: 180, padding: '16px 18px' }}>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>Carried Risk</div>
            <div style={{ fontSize: 28, fontWeight: 700, color: (effectiveSummary.totalCarried?.amount ?? effectiveSummary.carried?.amount ?? 0) > 0 ? colors.amber : colors.tealLoom, lineHeight: 1 }}>{fmtMoney(effectiveSummary.totalCarried ?? effectiveSummary.carried)}</div>
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
      {exceedanceCurve.length > 0 && effectiveSummary && (
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
                  tickFormatter={(v: number) => fmtMoney({ amount: v, currency: effectiveSummary.currency }, { compact: true, compactThreshold: 0 })}
                  label={{ value: `Loss (${convertMoney(effectiveSummary.totalAle)?.currency ?? effectiveSummary.currency})`, angle: -90, position: 'insideLeft', fill: 'var(--muted)', fontSize: 11 }}
                />
                <Tooltip
                  contentStyle={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 8 }}
                  labelStyle={{ color: 'var(--text)' }}
                  formatter={(value) => [fmtMoney({ amount: Number(value), currency: effectiveSummary.currency }), 'Loss']}
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

      {/* Per-framework breakdown with status badges */}
      {effectiveSummary && (
        <Section title="Framework Breakdown" hint="risk by regulatory framework">
          <Table headers={['Framework', 'ALE', 'VaR95', 'TVaR', 'Carried']}>
            {effectiveSummary.frameworks.map((fw) => {
              const matchedVersion = frameworkVersions.find(
                (v) =>
                  (v.frameworkId && v.frameworkId === fw.id) ||
                  (v.framework_id && v.framework_id === fw.id) ||
                  (v.name && v.name.toLowerCase() === fw.name.toLowerCase()),
              )
              return (
                <tr key={fw.id} style={{ borderBottom: '1px solid var(--border)' }}>
                  <td style={td}>
                    <div style={{ display: 'flex', alignItems: 'center' }}>
                      <span>{fw.name}</span>
                      {renderStatusBadge(matchedVersion?.status ?? 'active')}
                    </div>
                  </td>
                  <td style={td}>{(() => { const s = scaleMoney(effectiveSummary.totalAle, fw.totalControls > 0 ? fw.totalControls / effectiveSummary.totalChecks : 0); return s ? fmtMoney(s) : MONEY_UNAVAILABLE })()}</td>
                  <td style={td}>{(() => { const s = scaleMoney(effectiveSummary.totalVar95, fw.totalControls > 0 ? fw.totalControls / effectiveSummary.totalChecks : 0); return s ? fmtMoney(s) : MONEY_UNAVAILABLE })()}</td>
                  <td style={td}>{(() => { const s = scaleMoney(effectiveSummary.totalTvar, fw.totalControls > 0 ? fw.totalControls / effectiveSummary.totalChecks : 0); return s ? fmtMoney(s) : MONEY_UNAVAILABLE })()}</td>
                  <td style={td}>{fmtMoney(fw.totalExposure ?? fw.exposure)}</td>
                </tr>
              )
            })}
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
              style={{ fontSize: 13, padding: '4px 8px', borderRadius: 6, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text)' }}
              data-testid="version-select"
            >
              {availableVersions.map((v) => (
                <option key={v} value={v}>
                  {v}
                </option>
              ))}
            </select>
          </div>
          {effectiveSummary && (
            <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
              <StatCard label="ALE" value={fmtMoney(effectiveSummary.totalAle)} sub={`at ${selectedVersion}`} accent={colors.amber} />
              <StatCard label="VaR95" value={fmtMoney(effectiveSummary.totalVar95)} sub={`at ${selectedVersion}`} accent={colors.red} />
              <StatCard label="TVaR" value={fmtMoney(effectiveSummary.totalTvar)} sub={`at ${selectedVersion}`} accent={colors.red} />
              <StatCard label="Carried" value={fmtMoney(effectiveSummary.totalCarried ?? effectiveSummary.carried)} sub={`at ${selectedVersion}`} accent={(effectiveSummary.totalCarried?.amount ?? effectiveSummary.carried?.amount ?? 0) > 0 ? colors.amber : colors.tealLoom} />
            </div>
          )}
        </div>
      </Section>
    </div>
  )
}
