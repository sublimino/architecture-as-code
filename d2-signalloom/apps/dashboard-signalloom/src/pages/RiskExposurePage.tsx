import { useState, useEffect, useCallback, useMemo } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { fairApi } from '../api/fairApi'
import { colors, exposureAccent } from '../styles/tokens'
import { StatCard, Section, Table, td } from '../components/DashKit'
import StatusBadge, { tint } from '../components/StatusBadge'
import AgentSuperFilterTable, { formatFullTimestamp } from '../components/AgentSuperFilterTable'
import LoadingState, { loadPhase } from '../components/LoadingState'
import { AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts'
import type { PostureSummary } from '../types/compliance'
import type { FrameworkVersion, PopulationFilter } from '../types/fair'
import { useMoney } from '../money/CurrencyContext'
import { scaleMoney } from '../money/money'
import { MONEY_UNAVAILABLE } from '../money/format'
import ConversionNote from '../components/ConversionNote'
import AgentDeepLink from '../components/AgentDeepLink'
import { isDemoMode } from '../api/demoMode'

/**
 * Demo-only framework/version catalogue.
 *
 * There is no fixture route for the FAIR versions endpoint
 * (`VITE_FAIR_VERSIONS_PREFIX`, default `/v1/fair/versions`), so demo mode
 * cannot obtain this list through the api client's fixture gate. It is
 * therefore seeded here and reachable ONLY when `isDemoMode()` is true. In
 * live mode the version selector shows exactly what the API returned — an
 * empty selector is the honest answer when the API serves nothing.
 */
export const DEMO_VERSIONS: FrameworkVersion[] = [
  { frameworkId: 'eu-ai-act', name: 'EU AI Act', version: 'v2.1', status: 'active', isDefault: true },
  { frameworkId: 'eu-ai-act', name: 'EU AI Act', version: 'v2.0', status: 'retired', isDefault: false },
  { frameworkId: 'eu-ai-act', name: 'EU AI Act', version: 'v1.0', status: 'retired', isDefault: false },
  { frameworkId: 'nist-800-53', name: 'NIST 800-53', version: 'v2.1', status: 'active', isDefault: true },
  { frameworkId: 'nist-800-53', name: 'NIST 800-53', version: 'v2.0', status: 'retired', isDefault: false },
  { frameworkId: 'cra', name: 'Cyber Resilience Act', version: 'v2.1', status: 'active', isDefault: true },
  { frameworkId: 'cra', name: 'Cyber Resilience Act', version: 'v2.0', status: 'retired', isDefault: false },
  { frameworkId: 'cra', name: 'Cyber Resilience Act', version: 'v1.0', status: 'retired', isDefault: false },
  { frameworkId: 'finos-aigf', name: 'FINOS AI Governance Framework', version: 'v2.1', status: 'active', isDefault: true },
  { frameworkId: 'finos-aigf', name: 'FINOS AI Governance Framework', version: 'v2.0', status: 'retired', isDefault: false },
  { frameworkId: 'finos-aigf', name: 'FINOS AI Governance Framework', version: 'v1.0', status: 'retired', isDefault: false },
  { frameworkId: 'soc2-type-ii', name: 'SOC 2 Type II', version: 'v2.1', status: 'active', isDefault: false },
]

/**
 * Why the per-agent carried exposure column shows no figure.
 *
 * It used to show `failing * 12000`. That is a worse shape than a displayed
 * constant and it is worth being precise about why: £12,000 per failing
 * control is a fabricated UNIT RATE, so the output moved with a real count and
 * therefore looked derived. A reviewer reading the column saw figures that
 * responded correctly to the data and had no way to tell that the coefficient
 * was invented -- the same property that made the discarded Monte Carlo hard
 * to spot.
 *
 * No per-control rate is declared anywhere: not in `risk/packs/agent-policy`,
 * not on any response this page receives, not in the policy engine's output.
 * Whether one SHOULD exist is a calibration decision for the risk owner, not
 * something a dashboard may assume, so the column reports the failing-control
 * count -- which is real and is what the API actually sends -- and declines
 * the money.
 */
const PER_CONTROL_RATE_UNDECLARED =
  'Not priced: no per-control loss rate is declared in risk/packs/agent-policy, and no ' +
  'response to this page carries a per-agent exposure figure. The failing-control count ' +
  'below is the real number this row has.'

interface PopulationAgent {
  id: string
  agent_id?: string
  name: string
  agent_name?: string | null
  lifecycle_state: string
  namespace: string
  source?: string
  origin?: string
  owner?: string | null
  last_assessed?: string | number | null
  last_observed_at?: string | null
  compliance_summary?: {
    total_controls?: number
    passing?: number
    failing?: number
    pending?: number
    posture_score?: number | null
  }
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
  const [frameworkVersions, setFrameworkVersions] = useState<FrameworkVersion[]>(
    () => (isDemoMode() ? DEMO_VERSIONS : []),
  )
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
    } catch (err) {
      // A failed version lookup must be visible. Silently keeping whatever is
      // in state presents a stale or empty selector as if it were current.
      setError(err instanceof Error ? err.message : 'Failed to load framework versions')
    }
  }, [getAccessTokenSilently])

  // Load agent inventory to drive population filtering
  const loadAgents = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const agentsData = await api.agents.list(token)
      if (agentsData?.agents && Array.isArray(agentsData.agents) && agentsData.agents.length > 0) {
        setAgentList(
          agentsData.agents.map((a) => ({
            id: a.id,
            agent_id: a.id,
            name: a.name || 'Unnamed',
            agent_name: a.name,
            lifecycle_state: a.lifecycle_state || 'Governed',
            namespace: a.runtime?.namespace || a.namespace || 'default',
            source: a.origin || (a as unknown as Record<string, string>).source || 'K8s Cluster',
            owner: a.responsibility?.owner_name || a.owner || null,
            last_assessed: a.timestamps?.last_observed_at || a.last_transition_at || a.created_at || null,
            compliance_summary: a.compliance_summary,
          }))
        )
        return
      }
    } catch (err) {
      // The agent inventory is the preferred source but not the only one, so
      // record the failure and fall through to the posture endpoint rather
      // than swallowing it.
      setError(err instanceof Error ? err.message : 'Failed to load agent inventory')
    }
    try {
      const token = await getAccessTokenSilently()
      const postureData = await api.compliance.posture(token)
      if (postureData?.agents && Array.isArray(postureData.agents)) {
        setAgentList(
          postureData.agents.map((a: { agent_id?: string; id?: string; agent_name?: string; name?: string; lifecycle_state?: string; namespace?: string }) => ({
            id: a.agent_id || a.id || '',
            agent_id: a.agent_id || a.id || '',
            name: a.agent_name || a.name || 'Unnamed',
            lifecycle_state: a.lifecycle_state || 'Governed',
            namespace: a.namespace || 'default',
            source: 'K8s Cluster',
            owner: null,
            // The posture endpoint carries neither an assessment timestamp nor
            // a per-agent control breakdown. Leaving both absent renders an
            // explicit "unknown"; inventing them (this used to assert
            // 10 controls / 8 passing / 2 failing / score 80 for every agent)
            // puts a figure on screen that no backend ever produced.
            last_assessed: null,
            compliance_summary: undefined,
          }))
        )
        setError(null)
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load agent posture')
    }
  }, [getAccessTokenSilently])

  // Dynamic versions list sorted semantically descending
  const availableVersions = useMemo(() => {
    const list = frameworkVersions
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

  // Agent counts are observations, never estimates. An empty inventory means
  // "we have not been told about any agents", which is zero — not the 20/15/5
  // these previously asserted. Those literals also fed `ratio` below, so a
  // fabricated population silently rescaled real ALE/VaR/TVaR money.
  const governedCount = useMemo(
    () => agentList.filter((a) => isGovernedState(a.lifecycle_state)).length,
    [agentList],
  )

  const discoveredCount = useMemo(
    () => agentList.filter((a) => isDiscoveredState(a.lifecycle_state)).length,
    [agentList],
  )

  const totalAgentCount = useMemo(() => agentList.length, [agentList])

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

    // Apportioning the estate-wide figures to a sub-population requires a
    // known denominator. With no agent inventory there is nothing to divide
    // by, so report "unknown" rather than scaling by an assumed population.
    if (totalAgentCount === 0) return null

    const total = totalAgentCount
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

    // scaleMoney returns null precisely when the product is not a usable
    // figure. Each of these used to answer that null with
    // `{ amount: Math.round(x * ratio) }` — recomputing by hand the number the
    // money layer had just refused to produce, and defeating the one guard
    // that exists. `?? 0` in those fallbacks also turned a missing carried
    // figure into a £0 claim. If any leg cannot be scaled, the apportioned
    // view is unavailable as a whole.
    const scaled = {
      totalAle: scaleMoney(summary.totalAle, ratio),
      totalVar95: scaleMoney(summary.totalVar95, ratio),
      totalTvar: scaleMoney(summary.totalTvar, ratio),
      totalCarried: scaleMoney(summary.totalCarried ?? summary.carried, ratio),
      carried: scaleMoney(summary.carried ?? summary.totalCarried, ratio),
    }
    if (Object.values(scaled).some((m) => m === null)) return null

    const frameworks = summary.frameworks.map((fw) => ({
      fw,
      totalExposure: scaleMoney(fw.totalExposure ?? fw.exposure, ratio),
      exposure: scaleMoney(fw.exposure ?? fw.totalExposure, ratio),
    }))
    if (frameworks.some((f) => f.totalExposure === null || f.exposure === null)) return null

    return {
      ...summary,
      totalAle: scaled.totalAle!,
      totalVar95: scaled.totalVar95!,
      totalTvar: scaled.totalTvar!,
      totalCarried: scaled.totalCarried!,
      carried: scaled.carried!,
      frameworks: frameworks.map((f) => ({
        ...f.fw,
        totalExposure: f.totalExposure!,
        exposure: f.exposure!,
      })),
    }
  }, [summary, population, totalAgentCount, governedCount, discoveredCount])

  // Reactive loss exceedance curve recalculated under 250ms
  const exceedanceCurve = useMemo(() => {
    if (!effectiveSummary) return []
    // No curve from an unpriced summary. A curve drawn through zeros is not an
    // empty chart, it is a chart asserting zero loss at every exceedance
    // probability -- the most confident possible statement of a figure nobody
    // computed.
    const { totalAle, totalTvar } = effectiveSummary
    if (!totalAle || !totalTvar) return []
    return fairApi.calculateLossExceedance(totalAle.amount, totalTvar.amount)
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
            background: tint('var(--teal)', 0.15),
            color: 'var(--teal)',
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
                  background: population === 'all' ? 'var(--cyan)' : 'transparent',
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
                  background: population === 'governed' ? 'var(--cyan)' : 'transparent',
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
                  background: population === 'discovered' ? 'var(--cyan)' : 'transparent',
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
            <div style={{ fontSize: 28, fontWeight: 700, color: exposureAccent(effectiveSummary.totalCarried ?? effectiveSummary.carried), lineHeight: 1 }}>{fmtMoney(effectiveSummary.totalCarried ?? effectiveSummary.carried)}</div>
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

      {/* Assessed Population Agent Inventory */}
      <Section title="Assessed Agents Population" hint="risk posture and exposure breakdown across agents">
        <AgentSuperFilterTable<PopulationAgent>
          data={agentList}
          testId="fair-risk-super-table"
          pageSize={10}
          columns={[
            {
              key: 'name',
              label: 'Agent',
              sortable: true,
              accessor: (a) => a.name || a.agent_name || a.id,
            },
            {
              key: 'namespace',
              label: 'Namespace',
              sortable: true,
              accessor: (a) => a.namespace || 'default',
            },
            {
              key: 'lifecycle',
              label: 'Lifecycle State',
              sortable: true,
              accessor: (a) => a.lifecycle_state || 'Governed',
            },
            {
              key: 'source',
              label: 'Connector Source',
              sortable: true,
              accessor: (a) => a.source || 'K8s Cluster',
            },
            {
              key: 'last_assessed',
              label: 'Last Assessed',
              sortable: true,
              accessor: (a) => a.last_assessed ?? '',
            },
            {
              key: 'exposure',
              label: 'Carried Exposure',
              sortable: true,
              // Sorts on the failing-control COUNT, which is a real number
              // this row actually has. It used to sort on `failing * 12000`,
              // which is the same ordering derived from a fabricated rate --
              // see the note on PER_CONTROL_RATE_UNDECLARED below. Sorting by
              // the count is honest and gives the identical order, because
              // multiplying every row by one constant cannot reorder them.
              accessor: (a) => a.compliance_summary?.failing ?? 0,
            },
          ]}
          renderRow={(agent) => {
            const agentId = agent.id || agent.agent_id || ''
            const agentName = agent.name || agent.agent_name || agentId || 'Unnamed'
            const state = agent.lifecycle_state || 'Governed'
            const failing = agent.compliance_summary?.failing ?? 0
            return (
              <tr key={agent.id} style={{ borderBottom: '1px solid var(--border)' }} data-testid={`fair-agent-row-${agent.id}`}>
                <td style={td}>
                  {agentId ? (
                    <>
                      <div>
                        <AgentDeepLink
                          target={{ kind: 'agent', agentId }}
                          label={agentName}
                          dataTestId={`risk-agent-link-${agent.id}`}
                          title={`View agent dossier for ${agentName}`}
                          className="hover:underline"
                        />
                      </div>
                      <div style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace', marginTop: 2 }}>
                        <AgentDeepLink
                          target={{ kind: 'agent', agentId }}
                          variant="subtle"
                          dataTestId={`risk-agent-id-link-${agent.id}`}
                          title={`View agent dossier for ${agent.id}`}
                          className="hover:underline hover:text-[var(--cyan)]"
                        >
                          <span style={{ fontSize: 11, fontFamily: 'monospace' }}>{agent.id}</span>
                        </AgentDeepLink>
                      </div>
                    </>
                  ) : (
                    <>
                      <div style={{ fontWeight: 600, color: 'var(--text)' }}>{agentName}</div>
                      <div style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace' }}>{agent.id}</div>
                    </>
                  )}
                </td>
                <td style={td}>
                  <span style={{ fontFamily: 'monospace', fontSize: 12 }}>{agent.namespace || 'default'}</span>
                </td>
                <td style={td}>
                  <StatusBadge status={state} variant="lifecycle" />
                </td>
                <td style={td}>
                  <span style={{ fontSize: 12 }}>{agent.source || 'K8s Cluster'}</span>
                </td>
                <td style={td}>
                  <span style={{ fontSize: 12, color: 'var(--text)' }}>
                    {formatFullTimestamp(agent.last_assessed)}
                  </span>
                </td>
                <td style={td}>
                  <span
                    data-testid={`risk-agent-exposure-${agent.id}`}
                    style={{ fontWeight: 600, color: exposureAccent(null) }}
                    title={PER_CONTROL_RATE_UNDECLARED}
                  >
                    {fmtMoney(null)}
                  </span>
                  <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
                    {failing} failing {failing === 1 ? 'control' : 'controls'}
                  </div>
                </td>
              </tr>
            )
          }}
        />
      </Section>

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
              <StatCard label="Carried" value={fmtMoney(effectiveSummary.totalCarried ?? effectiveSummary.carried)} sub={`at ${selectedVersion}`} accent={exposureAccent(effectiveSummary.totalCarried ?? effectiveSummary.carried)} />
            </div>
          )}
        </div>
      </Section>
    </div>
  )
}
