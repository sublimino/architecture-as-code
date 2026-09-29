import { useState, useEffect, useCallback, useMemo } from 'react'
import { Link } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { colors } from '../styles/tokens'
import { StatCard, Section, Table, td } from '../components/DashKit'
import StatusBadge, { tint } from '../components/StatusBadge'
import LoadingState, { loadPhase } from '../components/LoadingState'
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Cell } from 'recharts'
import type { FrameworkSummary, PostureSummary } from '../types/compliance'
import type { PolicyBundle, PolicyBundleSummary, VersionHistoryItem } from '../types/policies'
import { useMoney } from '../money/CurrencyContext'
import ConversionNote from '../components/ConversionNote'
import PolicyEditor from '../components/PolicyEditor'

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

const DEFAULT_BUNDLES: Record<string, PolicyBundle> = {
  'eu-ai-act': {
    id: 'eu-ai-act-v2.1.0',
    framework_id: 'eu-ai-act',
    version: 'v2.1.0',
    author: 'system',
    description: 'EU AI Act: High-Risk AI System Requirements',
    created_at: '2026-09-28T12:00:00Z',
    checksum: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    rules: [
      {
        id: 'container-run-as-non-root',
        name: 'AI system container runs as non-root',
        description: 'Ensures high-risk AI workloads do not execute with root UID privileges.',
        cel_expression: 'object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)',
        severity: 'high',
        remediation: 'Configure securityContext.runAsNonRoot to true.',
      },
      {
        id: 'no-privilege-escalation',
        name: 'No privilege escalation in AI workloads',
        description: 'Prohibits processes within AI workloads from gaining more privileges than their parent process.',
        cel_expression: 'object.spec.containers.all(c, c.securityContext.allowPrivilegeEscalation == false)',
        severity: 'critical',
        remediation: 'Set securityContext.allowPrivilegeEscalation to false.',
      },
      {
        id: 'training-data-provenance',
        name: 'Training data provenance and validation',
        description: 'Validates that training and validation data sets have verified provenance records.',
        cel_expression: 'has(agent.training_data_provenance) && agent.training_data_provenance.validated == true',
        severity: 'high',
        remediation: 'Attach verified data provenance metadata to agent definition.',
      },
      {
        id: 'block-unauthorized-host-exec',
        name: 'Privileged action human authorization SVID',
        description: 'Mandates human approval credential for sensitive host execution or IAM modification actions.',
        cel_expression: "request.tool_call.action in ['exec', 'write_file', 'modify_iam'] ? (has(request.context.claims) && request.context.claims.exists(c, c.type == 'human_approval_svid' && c.valid == true)) : true",
        severity: 'critical',
        remediation: 'Obtain valid human approval SVID prior to executing privileged host operations.',
      },
    ],
  },
  'nist-800-53': {
    id: 'nist-800-53-v2.1.0',
    framework_id: 'nist-800-53',
    version: 'v2.1.0',
    author: 'system',
    description: 'NIST SP 800-53 Rev. 5',
    created_at: '2026-09-28T12:00:00Z',
    checksum: 'a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef0',
    rules: [
      {
        id: 'no-automount-sa-token',
        name: 'Service account token auto-mount disabled',
        description: 'Prevents automatic injection of default API credentials into container pods.',
        cel_expression: 'object.spec.automountServiceAccountToken == false',
        severity: 'high',
        remediation: 'Set automountServiceAccountToken: false in pod spec.',
      },
      {
        id: 'spiffe-peer-authorization',
        name: 'SPIFFE peer workload identity authorization',
        description: 'Enforces cryptographically verifiable SPIFFE SVID peer authentication.',
        cel_expression: "has(request.peer.spiffe_id) && request.peer.spiffe_id.startsWith('spiffe://signalloom.demo/ns/')",
        severity: 'critical',
        remediation: 'Present valid SPIFFE SVID rooted in the Signal Loom trust domain.',
      },
    ],
  },
  'cra': {
    id: 'cra-v1.0.0',
    framework_id: 'cra',
    version: 'v1.0.0',
    author: 'system',
    description: 'Cyber Resilience Act (CRA)',
    created_at: '2026-09-28T12:00:00Z',
    checksum: 'c1c2c3c4c5c60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef0',
    rules: [
      {
        id: 'default-secure-configuration',
        name: 'Secure-by-default runtime profile',
        description: 'Ensures system components ship and run with hardened security configurations by default.',
        cel_expression: 'has(agent.security_profile) && agent.security_profile.secure_by_default == true',
        severity: 'high',
        remediation: 'Enable default hardened security profile in agent manifest.',
      },
      {
        id: 'sbom-verified-provenance',
        name: 'Verified Software Bill of Materials (SBOM)',
        description: 'Requires machine-readable CycloneDX or SPDX SBOM with verified supply chain provenance.',
        cel_expression: "has(agent.sbom) && (agent.sbom.format == 'CycloneDX' || agent.sbom.format == 'SPDX') && agent.sbom.verified == true",
        severity: 'critical',
        remediation: 'Attach signed CycloneDX or SPDX SBOM metadata to agent workload.',
      },
    ],
  },
  'finos-aigf': {
    id: 'finos-aigf-v1.0.0',
    framework_id: 'finos-aigf',
    version: 'v1.0.0',
    author: 'system',
    description: 'FINOS AI Governance Framework (AIGF)',
    created_at: '2026-09-28T12:00:00Z',
    checksum: 'f1f2f3f4f5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef0',
    rules: [
      {
        id: 'registered-model-registry-entry',
        name: 'Model catalog registration and approval',
        description: 'Verifies AI agent model is registered and actively approved in the enterprise model catalog.',
        cel_expression: 'has(agent.registry) && agent.registry.model_registered == true',
        severity: 'high',
        remediation: 'Register model in the centralized enterprise AI model registry.',
      },
      {
        id: 'prompt-injection-guardrail-active',
        name: 'Active prompt injection filter guardrail',
        description: 'Enforces real-time input and output guardrails to detect adversarial prompt injection attacks.',
        cel_expression: 'has(agent.guardrails) && agent.guardrails.prompt_injection_filter == true',
        severity: 'critical',
        remediation: 'Enable prompt injection detection filter in agent inference pipeline.',
      },
    ],
  },
}

export default function CompliancePolicyPage() {
  const { getAccessTokenSilently } = useAuth0()
  const { fmtMoney, noteFor } = useMoney()
  const [summary, setSummary] = useState<PostureSummary | null>(null)
  const [frameworks, setFrameworks] = useState<FrameworkSummary[]>([])
  const [policySummaries, setPolicySummaries] = useState<PolicyBundleSummary[]>([])
  const [selectedFrameworkId, setSelectedFrameworkId] = useState<string>('eu-ai-act')
  const [scanning, setScanning] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [activeTab, setActiveTab] = useState<'editor' | 'overview'>('overview')

  const load = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const [fw, sum, pol] = await Promise.allSettled([
        api.compliancePolicy.frameworks(token),
        api.compliancePolicy.summary(token),
        api.policies ? api.policies.list(token) : Promise.resolve([]),
      ])

      if (fw.status === 'fulfilled') setFrameworks(fw.value)
      if (sum.status === 'fulfilled') setSummary(sum.value)
      if (pol.status === 'fulfilled' && Array.isArray(pol.value)) setPolicySummaries(pol.value)

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

  const activeBundleSummary = useMemo(() => {
    return policySummaries.find((s) => s.framework_id === selectedFrameworkId)
  }, [policySummaries, selectedFrameworkId])

  const currentBundle: PolicyBundle = useMemo(() => {
    if (activeBundleSummary?.active_bundle) {
      return activeBundleSummary.active_bundle
    }
    return DEFAULT_BUNDLES[selectedFrameworkId] || {
      id: `${selectedFrameworkId}-v1.0.0`,
      framework_id: selectedFrameworkId,
      version: 'v1.0.0',
      author: 'system',
      description: `${selectedFrameworkId.toUpperCase()} Policy Bundle`,
      created_at: new Date().toISOString(),
      checksum: '',
      rules: [],
    }
  }, [activeBundleSummary, selectedFrameworkId])

  const versionHistory: VersionHistoryItem[] = useMemo(() => {
    if (activeBundleSummary?.version_history?.length) {
      return activeBundleSummary.version_history
    }
    return [
      {
        version: currentBundle.version,
        author: currentBundle.author || 'system',
        description: currentBundle.description || 'Active bundle',
        created_at: currentBundle.created_at || new Date().toISOString(),
        rule_count: currentBundle.rules.length,
        checksum: currentBundle.checksum || '',
      },
    ]
  }, [activeBundleSummary, currentBundle])

  const availableFrameworkOptions = useMemo(() => {
    const defaultList = [
      { id: 'eu-ai-act', name: 'EU AI Act' },
      { id: 'nist-800-53', name: 'NIST SP 800-53' },
      { id: 'cra', name: 'Cyber Resilience Act (CRA)' },
      { id: 'finos-aigf', name: 'FINOS AIGF' },
      { id: 'dora', name: 'DORA (Placeholder)' },
      { id: 'nis2', name: 'NIS2 (Placeholder)' },
    ]
    if (frameworks.length === 0) return defaultList
    const map = new Map<string, string>()
    for (const item of defaultList) map.set(item.id, item.name)
    for (const fw of frameworks) {
      if (!map.has(fw.id)) map.set(fw.id, fw.name)
    }
    return Array.from(map.entries()).map(([id, name]) => ({ id, name }))
  }, [frameworks])

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
              onSelectFramework={setSelectedFrameworkId}
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
              <StatCard label="Total Exposure" value={fmtMoney(summary.totalCarried ?? summary.carried)} sub="carried risk" accent={(summary.totalCarried?.amount ?? summary.carried?.amount ?? 0) > 0 ? colors.amber : colors.tealLoom} />
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
                  <td style={td}>{fmtMoney(fw.totalExposure ?? fw.exposure)}</td>
                </tr>
              ))}
            </Table>
          </Section>
        </div>
      )}
    </div>
  )
}
