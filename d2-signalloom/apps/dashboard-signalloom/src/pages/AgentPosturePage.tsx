// TODO: migrate tables to DataTable (expandable accordion tables — may need DataTable extension for nested rows)
import { useState, useEffect, useCallback, useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { colors } from '../styles/tokens'
import { StatCard, Section, Table, td } from '../components/DashKit'
import StatusBadge, { tint } from '../components/StatusBadge'
import SignalBadge from '../components/SignalBadge'
import LoadingState, { loadPhase } from '../components/LoadingState'
import type { ComplianceCheck, PostureSummary } from '../types/compliance'
import type { SignalLayer } from '../api/weaveApi'
import { useMoney } from '../money/CurrencyContext'
import { sumMoney } from '../money/money'
import { MONEY_UNAVAILABLE } from '../money/format'
import ConversionNote from '../components/ConversionNote'
import { useSignalSummary } from '../hooks/useSignalSummary'

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

// ─── Layer Tooltip Descriptions ─────────────────────────────────────────────

const LAYER_TOOLTIPS: Record<string, string> = {
  network_egress: 'Outbound traffic analysis — detects unexpected external communication',
  identity_authorization: 'Identity and access audit — detects unauthorised service account usage',
  application_saas: 'SaaS integration monitoring — detects unregistered AI workloads',
  endpoint_host: 'Host-level detection — detects container filesystem and process anomalies',
  behavioural: 'Behavioural analysis — detects anomalous request patterns and cadence',
  cloud_control_plane: 'Cloud API monitoring — detects control plane misuse',
  protocol: 'Protocol-level analysis — detects non-standard protocol usage',
}

const LAYER_DISPLAY: Record<string, string> = {
  network_egress: 'Network/Egress',
  identity_authorization: 'Identity/Auth',
  application_saas: 'Application/SaaS',
  endpoint_host: 'Endpoint/Host',
  behavioural: 'Behavioural',
  cloud_control_plane: 'Cloud Control Plane',
  protocol: 'Protocol',
}

const LAYER_COLORS: Record<string, string> = {
  network_egress: 'var(--cyan)',
  identity_authorization: 'var(--violet)',
  application_saas: 'var(--teal)',
  endpoint_host: 'var(--amber)',
  behavioural: 'var(--error)',
  cloud_control_plane: 'var(--dim)',
  protocol: 'var(--dim)',
}

const DISPLAY_LAYERS: SignalLayer[] = [
  'network_egress',
  'identity_authorization',
  'application_saas',
  'endpoint_host',
  'behavioural',
]

// ─── Signal Evidence Section ────────────────────────────────────────────────

function SignalEvidenceSection() {
  const navigate = useNavigate()
  const signal = useSignalSummary()

  if (signal.loading) return null
  if (signal.error || signal.totalObservations === 0) {
    return (
      <Section title="Signal Evidence" hint="cross-layer signal correlation">
        <div className="card" style={{ padding: '16px 18px' }}>
          <p style={{ color: 'var(--muted)', fontSize: 13, margin: 0 }}>
            {signal.error
              ? 'Signal data currently unavailable — signal-ingest may be offline.'
              : 'No signal observations recorded yet.'}
          </p>
        </div>
      </Section>
    )
  }

  return (
    <div data-testid="signal-evidence-section">
    <Section title="Signal Evidence" hint="cross-layer signal correlation">
      <div className="card" style={{ padding: '16px 18px' }}>
        {/* Summary row */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginBottom: 14 }}>
          <SignalBadge
            observationCount={signal.totalObservations}
            highestFidelity={signal.highestFidelity!}
            layerCount={signal.layerCount}
            onClick={() => navigate('/weave')}
            testId="posture-signal-badge"
          />
          <span style={{ fontSize: 12, color: 'var(--muted)' }}>
            {signal.totalActors} provisional actor{signal.totalActors !== 1 ? 's' : ''} under correlation
          </span>
          <button
            className="btn btn-secondary"
            style={{ fontSize: 11, padding: '4px 10px', marginLeft: 'auto' }}
            onClick={() => navigate('/weave')}
            title="View full Signal Weave correlation dashboard"
          >
            View Weave
          </button>
        </div>

        {/* Layer coverage bar */}
        <div style={{ marginBottom: 8 }}>
          <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 6 }}>
            Layer Coverage
          </div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {DISPLAY_LAYERS.map((layer) => {
              const count = signal.observationsByLayer[layer] ?? 0
              const isActive = count > 0
              const layerColor = LAYER_COLORS[layer]
              return (
                <span
                  key={layer}
                  title={`${LAYER_DISPLAY[layer]}: ${count} observation${count !== 1 ? 's' : ''} — ${LAYER_TOOLTIPS[layer]}`}
                  style={{
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: 5,
                    fontSize: 11,
                    padding: '3px 8px',
                    borderRadius: 4,
                    background: isActive
                      ? `color-mix(in srgb, ${layerColor} 12%, transparent)`
                      : 'color-mix(in srgb, var(--muted) 8%, transparent)',
                    color: isActive ? layerColor : 'var(--muted)',
                    fontWeight: isActive ? 600 : 400,
                    opacity: isActive ? 1 : 0.6,
                  }}
                >
                  <span style={{
                    width: 6,
                    height: 6,
                    borderRadius: '50%',
                    background: isActive ? layerColor : 'var(--muted)',
                  }} />
                  {LAYER_DISPLAY[layer]}
                  {isActive && (
                    <span style={{ fontWeight: 700 }}>{count}</span>
                  )}
                </span>
              )
            })}
          </div>
        </div>
      </div>
    </Section>
    </div>
  )
}

// ─── Main Component ─────────────────────────────────────────────────────────

export default function AgentPosturePage() {
  const { getAccessTokenSilently } = useAuth0()
  // Exposure figures are source-currency amounts converted for display;
  // `fmt` yields "Unavailable" rather than an unconverted number if no rate
  // exists, and `conversionNote` states the rate and its effective date.
  const { fmtMoney, noteFor } = useMoney()
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
  // Summed in the SOURCE currency and converted once at render. Converting
  // each row and adding the rounded results would produce a total that does not
  // equal its own visible parts. Null on a mixed-currency list rather than
  // adding numbers that are not the same kind of thing.
  const totalExposure = sumMoney(filteredChecks.map((c) => c.carried), summary?.currency ?? 'GBP')

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
          <ConversionNote note={summary ? noteFor(summary.currency) : null} testId="posture-conversion-note" />
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
          value={totalExposure ? fmtMoney(totalExposure) : MONEY_UNAVAILABLE}
          sub="carried risk from failures"
          accent={(totalExposure?.amount ?? 0) > 0 ? colors.amber : colors.tealLoom}
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
                        <td style={td}>{fmtMoney(c.ale)}</td>
                        <td style={td}>{fmtMoney(c.var95)}</td>
                      </tr>
                    ))}
                  </Table>
                )}
              </div>
            )
          })}
        </Section>
      ))}

      {/* Signal Evidence — cross-cutting signal correlation data */}
      <SignalEvidenceSection />
    </div>
  )
}
