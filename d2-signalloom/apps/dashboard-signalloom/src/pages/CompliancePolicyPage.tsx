import { useState, useEffect, useCallback, useMemo } from 'react'
import { Link, useLocation, useSearchParams } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { colors, exposureAccent } from '../styles/tokens'
import { StatCard, Section, Table, td } from '../components/DashKit'
import StatusBadge, { tint } from '../components/StatusBadge'
import LoadingState, { loadPhase } from '../components/LoadingState'
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Cell } from 'recharts'
import type { FrameworkSummary, PostureSummary } from '../types/compliance'
import type { PolicyBundle, PolicyBundleSummary, VersionHistoryItem } from '../types/policies'
import { useMoney } from '../money/CurrencyContext'
import ConversionNote from '../components/ConversionNote'
import PolicyEditor from '../components/PolicyEditor'
import {
  getBundleForFramework,
  getCanonicalFrameworkOptions,
  normalizeFrameworkId,
  CANONICAL_BUNDLES,
  REGULATORY_FRAMEWORKS,
} from '../data/regulatoryFrameworks'

function fmtPct(n: number, d: number) {
  if (d === 0) return '0%'
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

export { CANONICAL_BUNDLES as DEMO_BUNDLES, normalizeFrameworkId }

export default function CompliancePolicyPage() {
  const { getAccessTokenSilently } = useAuth0()
  const { fmtMoney, noteFor } = useMoney()
  const location = useLocation()
  const [searchParams, setSearchParams] = useSearchParams()

  const frameworkQuery = searchParams.get('framework')
  const ruleQuery = searchParams.get('rule')
  const isPoliciesRoute = location.pathname.startsWith('/policies')

  const [summary, setSummary] = useState<PostureSummary | null>(null)
  const [frameworks, setFrameworks] = useState<FrameworkSummary[]>([])
  const [policySummaries, setPolicySummaries] = useState<PolicyBundleSummary[]>([])
  const [activeTenantFrameworks, setActiveTenantFrameworks] = useState<string[]>([])
  const [selectedFrameworkId, setSelectedFrameworkId] = useState<string>(() => {
    return normalizeFrameworkId(frameworkQuery)
  })
  const [selectedRuleId, setSelectedRuleId] = useState<string | null>(ruleQuery)
  const [scanning, setScanning] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [activeTab, setActiveTab] = useState<'editor' | 'overview'>(
    isPoliciesRoute || Boolean(frameworkQuery) ? 'editor' : 'overview',
  )

  useEffect(() => {
    if (location.pathname.startsWith('/policies')) {
      setActiveTab('editor')
    }
  }, [location.pathname])

  // Synchronize internal state with external URL query parameters
  useEffect(() => {
    const fw = searchParams.get('framework')
    const normalized = normalizeFrameworkId(fw)
    if (normalized !== selectedFrameworkId) {
      setSelectedFrameworkId(normalized)
    }
    const r = searchParams.get('rule')
    if (r !== selectedRuleId) {
      setSelectedRuleId(r)
    }
  }, [searchParams, selectedFrameworkId, selectedRuleId])

  const handleSelectFramework = useCallback((fwId: string) => {
    const canonical = normalizeFrameworkId(fwId)
    setSelectedFrameworkId(canonical)
    setSelectedRuleId(null)
    setSearchParams(
      (prev) => {
        const next = new URLSearchParams(prev)
        next.set('framework', canonical)
        next.delete('rule')
        return next
      },
      { replace: true },
    )
  }, [setSearchParams])

  const handleSelectRule = useCallback((ruleId: string) => {
    setSelectedRuleId(ruleId)
    setSearchParams(
      (prev) => {
        const next = new URLSearchParams(prev)
        next.set('framework', selectedFrameworkId)
        next.set('rule', ruleId)
        return next
      },
      { replace: true },
    )
  }, [selectedFrameworkId, setSearchParams])

  const load = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const [fw, sum, pol, sett] = await Promise.allSettled([
        api.compliancePolicy.frameworks(token),
        api.compliancePolicy.summary(token),
        api.policies ? api.policies.list(token) : Promise.resolve([]),
        api.settings ? api.settings(token) : Promise.resolve(null),
      ])

      if (fw.status === 'fulfilled') setFrameworks(fw.value)
      if (sum.status === 'fulfilled') setSummary(sum.value)
      if (pol.status === 'fulfilled' && Array.isArray(pol.value)) setPolicySummaries(pol.value)
      if (sett.status === 'fulfilled' && sett.value?.selected_frameworks) {
        setActiveTenantFrameworks(sett.value.selected_frameworks)
      }

      const failures = [
        fw.status === 'rejected' ? 'frameworks' : null,
        sum.status === 'rejected' ? 'posture summary' : null,
        pol.status === 'rejected' ? 'policy bundles' : null,
      ].filter((x): x is string => x !== null)

      if (failures.length > 0) {
        const first = [fw, sum, pol].find((r) => r.status === 'rejected') as
          | PromiseRejectedResult
          | undefined
        const detail =
          first?.reason instanceof Error ? `: ${first.reason.message}` : ''
        setError(`Failed to load ${failures.join(', ')}${detail}`)
      } else {
        setError(null)
      }
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

  const activeBundleSummary = useMemo(() => {
    const canonical = normalizeFrameworkId(selectedFrameworkId)
    return policySummaries.find(
      (s) => normalizeFrameworkId(s.framework_id) === canonical,
    )
  }, [policySummaries, selectedFrameworkId])

  // Returns bundle if available from policy service or fallback to built-in regulatory catalogue
  const currentBundle: PolicyBundle = useMemo(() => {
    if (activeBundleSummary?.active_bundle) {
      return activeBundleSummary.active_bundle
    }
    const template = getBundleForFramework(selectedFrameworkId)
    if (template) {
      return template
    }
    // Return empty bundle stub rather than null to preserve navigation and framework selector
    return {
      id: `${selectedFrameworkId}-bundle`,
      framework_id: selectedFrameworkId,
      version: 'v0.0.0',
      author: 'system',
      description: `Unregistered bundle for ${selectedFrameworkId}`,
      created_at: new Date().toISOString(),
      checksum: '',
      rules: [],
    }
  }, [activeBundleSummary, selectedFrameworkId])

  const versionHistory: VersionHistoryItem[] = useMemo(() => {
    if (activeBundleSummary?.version_history?.length) {
      return activeBundleSummary.version_history
    }
    return []
  }, [activeBundleSummary])

  // Strictly deduplicated list of available frameworks
  const availableFrameworkOptions = useMemo(() => {
    const map = new Map<string, string>()

    // Canonical defaults
    for (const opt of getCanonicalFrameworkOptions()) {
      map.set(opt.id, opt.name)
    }

    // Add any backend frameworks, normalizing aliases so duplicates never occur
    for (const fw of frameworks) {
      const normId = normalizeFrameworkId(fw.id)
      if (!map.has(normId)) {
        map.set(normId, fw.name)
      }
    }

    return Array.from(map.entries()).map(([id, name]) => {
      const isActive = activeTenantFrameworks.length === 0 || activeTenantFrameworks.includes(id)
      return {
        id,
        name: isActive ? name : `${name} (Inactive)`,
      }
    })
  }, [frameworks, activeTenantFrameworks])

  const handleSaveBundle = async (updatedBundle: PolicyBundle) => {
    const token = await getAccessTokenSilently()
    if (api.policies?.registerBundle) {
      await api.policies.registerBundle(token, updatedBundle)
      await load()
    }
  }

  const handleRollbackBundle = async (frameworkId: string, targetVersion: string) => {
    const token = await getAccessTokenSilently()
    if (api.policies?.rollback) {
      await api.policies.rollback(token, {
        framework_id: frameworkId,
        target_version: targetVersion,
      })
      await load()
    }
  }

  const chartData = frameworks.map((fw) => ({
    name: fw.name,
    coverage: fw.totalControls > 0 ? Math.round((fw.passedControls / fw.totalControls) * 100) : 0,
  }))

  return (
    <div data-testid="compliance-policy-page">
      {/* Breadcrumbs Navigation */}
      <nav
        aria-label="Breadcrumb"
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 8,
          fontSize: 12,
          color: 'var(--muted)',
          marginBottom: 16,
        }}
      >
        <Link to="/compliance" style={{ color: 'var(--cyan)', textDecoration: 'none' }}>
          Compliance
        </Link>
        <span>/</span>
        <span style={{ color: 'var(--text)', fontWeight: 600 }}>Policy-as-Code & CEL Rules</span>
      </nav>

      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 20 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, color: 'var(--text)', margin: 0 }}>Policy Compliance</h1>
          {summary && (
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
              Last scan: {fmtTimestamp(summary.scanTimestamp)}
            </div>
          )}
          <ConversionNote note={summary ? noteFor(summary.currency) : null} testId="policy-conversion-note" />
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <button className="btn btn-primary" onClick={handleScan} disabled={scanning}>
            {scanning ? 'Scanning...' : 'Scan Now'}
          </button>
        </div>
      </div>

      {/* Navigation Tabs */}
      <div
        style={{
          display: 'flex',
          gap: 12,
          borderBottom: '1px solid var(--border)',
          marginBottom: 20,
        }}
      >
        <button
          data-testid="tab-editor"
          type="button"
          onClick={() => setActiveTab('editor')}
          style={{
            padding: '8px 16px',
            background: 'none',
            border: 'none',
            borderBottom: activeTab === 'editor' ? '2px solid var(--cyan)' : '2px solid transparent',
            color: activeTab === 'editor' ? 'var(--cyan)' : 'var(--muted)',
            fontWeight: activeTab === 'editor' ? 600 : 400,
            fontSize: 13,
            cursor: 'pointer',
          }}
        >
          CEL Policy Editor
        </button>
        <button
          data-testid="tab-overview"
          type="button"
          onClick={() => setActiveTab('overview')}
          style={{
            padding: '8px 16px',
            background: 'none',
            border: 'none',
            borderBottom: activeTab === 'overview' ? '2px solid var(--cyan)' : '2px solid transparent',
            color: activeTab === 'overview' ? 'var(--cyan)' : 'var(--muted)',
            fontWeight: activeTab === 'overview' ? 600 : 400,
            fontSize: 13,
            cursor: 'pointer',
          }}
        >
          Compliance Posture & Framework Scans
        </button>
      </div>

      <div className="card" style={{ padding: 16, marginBottom: 16 }}>
        <LoadingState
          status={loadPhase({ loading: scanning, error, loaded: summary !== null || frameworks.length > 0 })}
          label="compliance data"
          error={error}
          onRetry={load}
          testId="compliance-policy-load-state"
        />
      </div>

      {activeTab === 'editor' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <Section title="Policy-as-Code Editor" hint="Client-side syntax diagnostics with authoritative Go CEL engine">
            <PolicyEditor
              bundle={currentBundle}
              versionHistory={versionHistory}
              availableFrameworks={availableFrameworkOptions}
              onSelectFramework={handleSelectFramework}
              selectedRuleId={selectedRuleId}
              onSelectRule={handleSelectRule}
              onSave={handleSaveBundle}
              onRollback={handleRollbackBundle}
            />
          </Section>
        </div>
      )}

      {activeTab === 'overview' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
          {/* Stat cards */}
          {summary && (
            <div style={{ display: 'flex', gap: 12, marginBottom: 8, flexWrap: 'wrap' }}>
              <StatCard label="Total Checks" value={String(summary.totalChecks)} sub={`${summary.passed} passed`} accent={colors.cyanLoom} />
              <StatCard label="Passed" value={String(summary.passed)} sub={fmtPct(summary.passed, summary.totalChecks)} accent={colors.tealLoom} />
              <StatCard label="Failed" value={String(summary.failed)} sub={fmtPct(summary.failed, summary.totalChecks)} accent={summary.failed > 0 ? colors.red : colors.tealLoom} />
              <StatCard label="Total Exposure" value={fmtMoney(summary.totalCarried ?? summary.carried)} sub="carried risk" accent={exposureAccent(summary.totalCarried ?? summary.carried)} />
            </div>
          )}

          {/* Framework cards */}
          <Section title="Frameworks" hint={`${frameworks.length} registered`}>
            <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 16 }}>
              {frameworks.map((fw) => {
                const coverage = fw.totalControls > 0 ? Math.round((fw.passedControls / fw.totalControls) * 100) : 0
                const currentVersion = fw.versions[fw.versions.length - 1] ?? 'None'
                return (
                  <div key={fw.id} className="card" style={{ flex: '1 1 280px', padding: 16 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
                      <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--text)' }}>{fw.name}</div>
                      <Link
                        to={`/policies?framework=${normalizeFrameworkId(fw.id)}`}
                        style={{ fontSize: 11, color: 'var(--cyan)', textDecoration: 'none', fontWeight: 600 }}
                      >
                        Edit CEL →
                      </Link>
                    </div>
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
                      {fw.passedControls}/{fw.totalControls} controls passing ({coverage}%) | {fmtMoney(fw.totalExposure ?? fw.exposure)} exposure
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
            <Table headers={['Framework', 'Control Set', 'Controls', 'Passed', 'Coverage', 'Exposure', 'Action']}>
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
                  <td style={td}>{fmtMoney(fw.totalExposure ?? fw.exposure)}</td>
                  <td style={td}>
                    <Link
                      to={`/policies?framework=${normalizeFrameworkId(fw.id)}`}
                      className="btn btn-secondary"
                      style={{ fontSize: 11, padding: '3px 8px', textDecoration: 'none' }}
                    >
                      Open Editor
                    </Link>
                  </td>
                </tr>
              ))}
            </Table>
          </Section>
        </div>
      )}
    </div>
  )
}
