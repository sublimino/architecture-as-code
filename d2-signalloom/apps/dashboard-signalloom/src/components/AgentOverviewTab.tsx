import { Link } from 'react-router-dom'
import type { AgentResponse, SourceHealthMap, AgentComplianceResultResponse } from '../types/api'
import { colors } from '../styles/tokens'
import AgentCockpitSection from './AgentCockpitSection'
import { DEFAULT_BUNDLES } from '../pages/CompliancePolicyPage'

// ─── Helpers ────────────────────────────────────────────────────────────────

export function getControlSlug(controlName: string): string {
  const cisMatch = controlName.match(/cis\s*(\d+)[\.\-](\d+)[\.\-](\d+)/i)
  if (cisMatch) {
    return `cis-${cisMatch[1]}-${cisMatch[2]}-${cisMatch[3]}`
  }
  return controlName.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
}

interface ControlPolicyMetadata {
  ruleId: string
  ruleName: string
  frameworkId: string
  frameworkName: string
  celExpression: string
  severity?: string
  remediation?: string
  docsUrl: string
  testedSeparately?: boolean
  testedSeparatelyNote?: string
}

function lookupPolicyForControl(controlName: string, frameworkName: string): ControlPolicyMetadata {
  const slug = getControlSlug(controlName)

  // 1. CIS Kubernetes Benchmark
  const cisBundle = DEFAULT_BUNDLES['k8s-cis-benchmark']
  if (cisBundle) {
    const cisRule = cisBundle.rules.find(r => {
      const rSlug = r.id.toLowerCase().replace(/[^a-z0-9]+/g, '-')
      return slug.includes(rSlug) || rSlug.includes(slug) || controlName.toLowerCase().includes(r.id.toLowerCase())
    })
    if (cisRule) {
      return {
        ruleId: cisRule.id,
        ruleName: cisRule.name,
        frameworkId: cisBundle.framework_id,
        frameworkName: 'CIS Kubernetes Benchmark',
        celExpression: cisRule.cel_expression,
        severity: cisRule.severity,
        remediation: cisRule.remediation,
        docsUrl: cisRule.docs_url || cisBundle.official_docs_url || 'https://www.cisecurity.org/benchmark/kubernetes',
        testedSeparately: cisRule.tested_separately,
        testedSeparatelyNote: cisRule.tested_separately_note,
      }
    }
  }

  // 2. EU AI Act
  if (frameworkName.toLowerCase().includes('eu ai act') || controlName.toLowerCase().includes('art.')) {
    const euBundle = DEFAULT_BUNDLES['eu-ai-act']
    if (euBundle) {
      let rule = euBundle.rules[0]
      if (controlName.includes('9')) rule = euBundle.rules.find(r => r.id === 'audit-trail-logging') || rule
      else if (controlName.includes('10')) rule = euBundle.rules.find(r => r.id === 'training-data-governance') || rule
      else if (controlName.includes('13')) rule = euBundle.rules.find(r => r.id === 'transparency-system-prompt') || rule
      else if (controlName.includes('14')) rule = euBundle.rules.find(r => r.id === 'block-unauthorized-host-exec') || rule
      return {
        ruleId: rule.id,
        ruleName: rule.name,
        frameworkId: euBundle.framework_id,
        frameworkName: 'EU AI Act',
        celExpression: rule.cel_expression,
        severity: rule.severity,
        remediation: rule.remediation,
        docsUrl: rule.docs_url || 'https://artificialintelligenceact.eu/',
      }
    }
  }

  // 3. SOC 2 or NIST
  if (frameworkName.toLowerCase().includes('soc') || frameworkName.toLowerCase().includes('nist')) {
    const nistBundle = DEFAULT_BUNDLES['nist-800-53']
    if (nistBundle) {
      let rule = nistBundle.rules[0]
      if (controlName.includes('CC6.1') || controlName.includes('Access')) {
        rule = nistBundle.rules.find(r => r.id === 'spiffe-peer-authorization') || rule
      } else if (controlName.includes('CC7.2') || controlName.includes('Monitoring')) {
        rule = nistBundle.rules.find(r => r.id === 'audit-trail-tamper-protection') || rule
      }
      return {
        ruleId: rule.id,
        ruleName: rule.name,
        frameworkId: nistBundle.framework_id,
        frameworkName: frameworkName,
        celExpression: rule.cel_expression,
        severity: rule.severity,
        remediation: rule.remediation,
        docsUrl: rule.docs_url || 'https://www.aicpa.org/resources/landing/trust-services-criteria',
      }
    }
  }

  // Fallback
  return {
    ruleId: slug,
    ruleName: controlName,
    frameworkId: frameworkName.toLowerCase().replace(/[^a-z0-9]+/g, '-'),
    frameworkName: frameworkName,
    celExpression: 'object.spec.metadata.name != ""',
    severity: 'medium',
    remediation: `Remediate findings for ${controlName}.`,
    docsUrl: 'https://kubernetes.io/docs/concepts/security/',
  }
}

function fmtDate(iso: string | null) {
  if (!iso) return '-'
  return new Date(iso).toLocaleDateString('en-GB', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function fmtRelative(iso: string | null) {
  if (!iso) return '-'
  const diff = Date.now() - new Date(iso).getTime()
  const mins = Math.floor(diff / 60000)
  if (mins < 1) return 'just now'
  if (mins === 1) return '1m ago'
  if (mins < 60) return `${mins}m ago`
  const hours = Math.floor(mins / 60)
  if (hours === 1) return '1h ago'
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(diff / 86400000)
  if (days === 0) return 'Today'
  if (days === 1) return 'Yesterday'
  if (days < 30) return `${days}d ago`
  return fmtDate(iso)
}

export interface AgentOverviewTabProps {
  agent: AgentResponse
  complianceResults?: AgentComplianceResultResponse[]
  sourceHealth?: 'healthy' | 'degraded' | 'unavailable' | null
  sourceHealthDetail?: SourceHealthMap | null
  claiming?: boolean
  claimError?: string | null
  retryingClaimRefresh?: boolean
  onClaim?: () => void
}

export default function AgentOverviewTab({
  agent,
  complianceResults,
  sourceHealth,
  sourceHealthDetail,
  claiming = false,
  claimError,
  retryingClaimRefresh = false,
  onClaim,
}: AgentOverviewTabProps) {
  // 1. Record Class & Badges
  const recordClass = agent.record_class || (agent.is_registry_linked === false ? 'discovered' : 'registered')
  const isUnclaimed = agent.is_registry_linked === false || recordClass === 'discovered'
  const complianceSummary = agent.compliance_summary ?? {
    total_controls: 0,
    passing: 0,
    failing: 0,
    pending: 0,
    posture_score: null,
  }

  // 2. Runtime metadata
  const namespace = agent.runtime?.namespace || agent.namespace || 'default'
  const clusterId = agent.runtime?.cluster_id || 'cluster-local'
  const framework = agent.runtime?.framework || agent.framework || agent.type || 'Custom'
  const executionMode = agent.runtime?.execution_mode || agent.type || '-'
  const model = agent.runtime?.model || agent.model_name || 'Not specified'
  const node = agent.runtime?.node || agent.node || 'Not assigned'
  const podUid = agent.runtime?.pod_uid || agent.pod_uid || '-'
  const serviceAccount = agent.runtime?.service_account || agent.service_account || '-'
  const phase = agent.runtime?.phase || agent.state || 'Running'

  // 3. Responsibility metadata (Truthful language dictionary)
  const ownerName = agent.responsibility?.owner_name || agent.owner
  const team = agent.responsibility?.team
  const assignmentStatus = agent.responsibility?.assignment_status || (ownerName ? 'assigned' : 'unassigned')

  // 4. Assessment & Attention metadata (Truthful language dictionary)
  const isNotAssessed = (agent.assessment_summary?.status === 'not_assessed') ||
    (complianceSummary.total_controls === 0) ||
    (complianceSummary.posture_score === null && complianceSummary.passing === 0 && complianceSummary.failing === 0)

  const attentionLevel = agent.attention?.level || (complianceSummary.failing > 0 ? 'critical' : 'none')
  const highestIssue = agent.attention?.highest_issue ||
    (complianceSummary.failing > 0
      ? `${complianceSummary.failing} failing control${complianceSummary.failing > 1 ? 's' : ''} detected`
      : 'No verified issues')

  const postureScorePct = complianceSummary.posture_score !== null
    ? Math.round(complianceSummary.posture_score <= 1.0 ? complianceSummary.posture_score * 100 : complianceSummary.posture_score)
    : null

  // 5. Identity & Telemetry (Truthful language dictionary)
  const spiffeId = agent.identity?.spiffe_id || '-'
  const isSpiffeLinked = agent.identity?.spiffe_status === 'linked' ||
    (!!agent.identity?.spiffe_id && agent.record_class !== 'discovered' && agent.is_registry_linked !== false)
  const aliases = agent.identity?.aliases ?? []

  const isTelemetryFrozenOrDrop = agent.kernel_telemetry?.cgroup_state === 'frozen' || agent.kernel_telemetry?.traffic_control_state === 'drop'
  const isContainmentRequested = agent.lifecycle_state === 'suspended' || agent.lifecycle_state === 'stunned' || agent.credential_state?.status === 'revoked'

  // 6. Source Health
  const k8sStatus = sourceHealthDetail?.k8s_discovery?.status ?? (sourceHealth === 'unavailable' ? 'unavailable' : 'healthy')
  const dbStatus = sourceHealthDetail?.postgres_registry?.status ?? (sourceHealth === 'unavailable' ? 'unavailable' : 'healthy')
  const cryptoStatus = sourceHealthDetail?.crypto_proofs?.status ?? (sourceHealth === 'unavailable' ? 'unavailable' : 'healthy')
  const effectiveSourceHealth = sourceHealth || 'healthy'
  const sourceHealthText = effectiveSourceHealth === 'unavailable' ? 'Source unavailable' : (effectiveSourceHealth.charAt(0).toUpperCase() + effectiveSourceHealth.slice(1))

  // 7. Timestamps
  const observedTime = agent.timestamps?.last_observed_at || agent.last_transition_at || agent.created_at
  const transitionTime = agent.timestamps?.last_transition_at || agent.last_transition_at
  const actionTime = agent.timestamps?.last_action_at

  // 8. Compliance & CEL Policy Frameworks
  const defaultFrameworks: Record<string, { name: string; bundleId: string; officialDocsUrl?: string }> = {
    'eu-ai-act': {
      name: 'EU AI Act',
      bundleId: 'eu-ai-act',
      officialDocsUrl: 'https://artificialintelligenceact.eu/',
    },
    'soc-2-type-ii': {
      name: 'SOC 2 Type II',
      bundleId: 'nist-800-53',
      officialDocsUrl: 'https://www.aicpa.org/resources/landing/trust-services-criteria',
    },
    'cis-kubernetes-benchmark': {
      name: 'CIS Kubernetes Benchmark',
      bundleId: 'k8s-cis-benchmark',
      officialDocsUrl: 'https://www.cisecurity.org/benchmark/kubernetes',
    },
  }

  const frameworkMap: Record<
    string,
    {
      name: string
      bundleId: string
      officialDocsUrl?: string
      total: number
      passing: number
      failing: number
      pending: number
    }
  > = {}

  for (const [slug, def] of Object.entries(defaultFrameworks)) {
    frameworkMap[slug] = {
      ...def,
      total: 0,
      passing: 0,
      failing: 0,
      pending: 0,
    }
  }

  if (complianceResults && complianceResults.length > 0) {
    for (const r of complianceResults) {
      const slug = r.framework_name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
      if (!frameworkMap[slug]) {
        frameworkMap[slug] = {
          name: r.framework_name,
          bundleId: slug,
          total: 0,
          passing: 0,
          failing: 0,
          pending: 0,
        }
      }
      frameworkMap[slug].total += 1
      if (r.status === 'pass') {
        frameworkMap[slug].passing += 1
      } else if (r.status === 'fail') {
        frameworkMap[slug].failing += 1
      } else {
        frameworkMap[slug].pending += 1
      }
    }
  }

  const frameworkEntries = Object.entries(frameworkMap)
  const nonCompliantControls = (complianceResults ?? []).filter(r => r.status !== 'pass')

  return (
    <div data-testid="dossier-panel-overview" role="tabpanel" id="dossier-tabpanel-overview" aria-labelledby="dossier-tab-overview" style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      <div
        className="card"
        data-testid="overview-governance-enrolment"
        style={{
          minHeight: 88,
          padding: '14px 18px',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 16,
          flexWrap: 'wrap',
          borderColor: claimError ? 'var(--error)' : isUnclaimed ? 'var(--amber)' : 'var(--teal)',
          background: claimError
            ? 'color-mix(in srgb, var(--error) 8%, var(--surface))'
            : isUnclaimed
            ? 'color-mix(in srgb, var(--amber) 8%, var(--surface))'
            : 'color-mix(in srgb, var(--teal) 8%, var(--surface))',
        }}
      >
        <div style={{ flex: '1 1 420px', minWidth: 0 }}>
          {isUnclaimed ? (
            <>
              <div data-testid="overview-unclaimed-banner" style={{ color: claimError ? 'var(--error)' : 'var(--amber)', fontWeight: 700, marginBottom: 4 }}>
                Unclaimed Workload
              </div>
              <div style={{ color: 'var(--muted)', fontSize: 12, lineHeight: 1.45 }}>
                {claimError ?? 'Enroll this discovered workload to activate cryptographic identity, policy evaluation, and governance controls.'}
              </div>
            </>
          ) : (
            <>
              <span data-testid="overview-enrolled-badge" className="tag" style={{ color: 'var(--teal)', background: 'rgba(16, 185, 129, 0.15)', fontWeight: 700 }}>
                Enrolled in Governance
              </span>
              <div data-testid="overview-active-controls" style={{ color: 'var(--muted)', fontSize: 12, marginTop: 7 }}>
                {complianceSummary.total_controls} active compliance controls
              </div>
            </>
          )}
        </div>
        {isUnclaimed && (
          <button
            type="button"
            className="btn btn-primary"
            data-testid="overview-claim-governance"
            disabled={claiming || !onClaim}
            aria-busy={claiming}
            title="Enroll this workload to verify its SPIFFE identity and activate continuous compliance governance"
            onClick={onClaim}
            style={{ minWidth: 190, whiteSpace: 'nowrap' }}
          >
            {claiming && (
              <svg data-testid="overview-claim-spinner" aria-hidden="true" width="12" height="12" viewBox="0 0 12 12" style={{ marginRight: 6, verticalAlign: '-1px' }}>
                <circle cx="6" cy="6" r="4.5" fill="none" stroke="currentColor" strokeOpacity="0.3" />
                <path d="M6 1.5a4.5 4.5 0 0 1 4.5 4.5" fill="none" stroke="currentColor" strokeLinecap="round">
                  <animateTransform attributeName="transform" type="rotate" from="0 6 6" to="360 6 6" dur="0.8s" repeatCount="indefinite" />
                </path>
              </svg>
            )}
            {claiming
              ? retryingClaimRefresh ? 'Refreshing…' : 'Claiming…'
              : claimError
              ? retryingClaimRefresh ? 'Retry Governance Refresh' : 'Retry Claim into Governance'
              : 'Claim into Governance'}
          </button>
        )}
      </div>

      {/* ─── 4 StatCards / Summary Grid ────────────────────────────────────────── */}
      <div style={{
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))',
        gap: 14,
      }}>
        {/* StatCard 1: Posture & Assessment */}
        <div className="card" data-testid="overview-card-posture" style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <span style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)' }}>
                Governance Posture
              </span>
              <a
                href="#overview-compliance-posture-section"
                data-testid="overview-posture-drilldown"
                style={{ fontSize: 11, color: 'var(--teal)', textDecoration: 'none', fontWeight: 600 }}
              >
                CEL Policies ↓
              </a>
            </div>
            <div data-testid="overview-posture-score" style={{
              fontSize: 32,
              fontWeight: 800,
              lineHeight: 1.1,
              color: isNotAssessed
                ? 'var(--muted)'
                : postureScorePct !== null && postureScorePct >= 80
                ? colors.tealLoom
                : postureScorePct !== null && postureScorePct >= 50
                ? colors.amber
                : colors.red,
            }}>
              {isNotAssessed ? 'Not assessed' : `${postureScorePct}%`}
            </div>
          </div>
          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', fontSize: 12 }}>
            <span style={{ color: 'var(--muted)' }}>Controls: </span>
            <span data-testid="overview-assessment-status" style={{ fontWeight: 600, color: isNotAssessed ? 'var(--muted)' : complianceSummary.failing > 0 ? 'var(--error)' : 'var(--teal)' }}>
              {isNotAssessed
                ? 'Not assessed'
                : complianceSummary.failing > 0
                ? `${complianceSummary.failing} failing / ${complianceSummary.total_controls} total`
                : `${complianceSummary.passing} / ${complianceSummary.total_controls} passing`}
            </span>
          </div>
        </div>

        {/* StatCard 2: Attention & Verified Issues */}
        <div className="card" data-testid="overview-card-attention" style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <span style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)' }}>
                Attention Level
              </span>
              <span
                data-testid="overview-attention-level"
                className="tag"
                style={{
                  fontSize: 10,
                  padding: '1px 6px',
                  background: attentionLevel === 'critical'
                    ? 'color-mix(in srgb, var(--error) 15%, transparent)'
                    : attentionLevel === 'warning'
                    ? 'color-mix(in srgb, var(--amber) 15%, transparent)'
                    : 'color-mix(in srgb, var(--teal) 15%, transparent)',
                  color: attentionLevel === 'critical'
                    ? 'var(--error)'
                    : attentionLevel === 'warning'
                    ? 'var(--amber)'
                    : 'var(--teal)',
                }}
              >
                {attentionLevel.toUpperCase()}
              </span>
            </div>
            <div data-testid="overview-highest-issue" style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)', marginTop: 4 }}>
              {highestIssue}
            </div>
          </div>
          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', fontSize: 12, color: 'var(--muted)' }}>
            Verified via signal correlation
          </div>
        </div>

        {/* StatCard 3: Identity & SPIFFE Trust */}
        <div className="card" data-testid="overview-card-identity" style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <span style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)' }}>
                SPIFFE Trust
              </span>
              <span
                data-testid="overview-spiffe-status"
                className="tag"
                style={{
                  fontSize: 10,
                  padding: '1px 6px',
                  background: isSpiffeLinked ? 'rgba(16, 185, 129, 0.15)' : 'rgba(156, 163, 175, 0.15)',
                  color: isSpiffeLinked ? 'var(--teal)' : 'var(--muted)',
                }}
              >
                {isSpiffeLinked ? 'SPIFFE linked' : 'Identity unlinked'}
              </span>
            </div>
            <div
              data-testid="overview-spiffe-id"
              style={{
                fontFamily: 'monospace',
                fontSize: 11,
                color: 'var(--text)',
                wordBreak: 'break-all',
                marginTop: 4,
                lineHeight: 1.4,
              }}
            >
              {spiffeId}
            </div>
          </div>
          {aliases.length > 0 && (
            <div data-testid="overview-identity-aliases" style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', display: 'flex', gap: 4, flexWrap: 'wrap' }}>
              {aliases.map(alias => (
                <span key={alias} className="tag" style={{ fontSize: 10, padding: '1px 6px' }}>
                  {alias}
                </span>
              ))}
            </div>
          )}
        </div>

        {/* StatCard 4: Observed Kernel Containment */}
        <div className="card" data-testid="overview-card-containment" style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
          <div>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 8 }}>
              Kernel Telemetry
            </div>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 4 }}>
              {isTelemetryFrozenOrDrop ? (
                <>
                  {agent.kernel_telemetry?.cgroup_state === 'frozen' && (
                    <span
                      data-testid="overview-kernel-cgroup"
                      className="tag"
                      title="cgroup.freeze: 1 (FROZEN): Processes suspended by Sentinel"
                      style={{
                        fontSize: 10,
                        padding: '3px 8px',
                        background: 'color-mix(in srgb, var(--error) 15%, transparent)',
                        color: 'var(--error)',
                        borderColor: 'color-mix(in srgb, var(--error) 30%, transparent)',
                        fontWeight: 700,
                      }}
                    >
                      cgroup: FROZEN
                    </span>
                  )}
                  {agent.kernel_telemetry?.traffic_control_state === 'drop' && (
                    <span
                      data-testid="overview-kernel-tc"
                      className="tag"
                      title="TC matchall drop active: Network isolated by Sentinel"
                      style={{
                        fontSize: 10,
                        padding: '3px 8px',
                        background: 'color-mix(in srgb, var(--error) 15%, transparent)',
                        color: 'var(--error)',
                        borderColor: 'color-mix(in srgb, var(--error) 30%, transparent)',
                        fontWeight: 700,
                      }}
                    >
                      TC: DROP
                    </span>
                  )}
                </>
              ) : isContainmentRequested ? (
                <span
                  data-testid="overview-kernel-unconfirmed"
                  className="tag"
                  title="Containment requested but kernel telemetry observation is unconfirmed"
                  style={{
                    fontSize: 10,
                    padding: '3px 8px',
                    background: 'color-mix(in srgb, var(--amber) 15%, transparent)',
                    color: 'var(--amber)',
                    borderColor: 'color-mix(in srgb, var(--amber) 30%, transparent)',
                    fontWeight: 600,
                  }}
                >
                  Requested (Outcome unconfirmed)
                </span>
              ) : (
                <>
                  {agent.kernel_telemetry?.cgroup_state === 'thawed' && (
                    <span
                      data-testid="overview-kernel-cgroup"
                      className="tag"
                      title="cgroup.freeze: 0 (THAWED)"
                      style={{
                        fontSize: 10,
                        padding: '3px 8px',
                        background: 'color-mix(in srgb, var(--teal) 15%, transparent)',
                        color: 'var(--teal)',
                        borderColor: 'color-mix(in srgb, var(--teal) 30%, transparent)',
                        fontWeight: 600,
                      }}
                    >
                      cgroup: THAWED
                    </span>
                  )}
                  {agent.kernel_telemetry?.traffic_control_state === 'allow' && (
                    <span
                      data-testid="overview-kernel-tc"
                      className="tag"
                      title="TC drop: INACTIVE"
                      style={{
                        fontSize: 10,
                        padding: '3px 8px',
                        background: 'color-mix(in srgb, var(--teal) 15%, transparent)',
                        color: 'var(--teal)',
                        borderColor: 'color-mix(in srgb, var(--teal) 30%, transparent)',
                        fontWeight: 600,
                      }}
                    >
                      TC: PASS
                    </span>
                  )}
                </>
              )}
            </div>
          </div>
          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', fontSize: 12, color: 'var(--muted)' }}>
            Observed eBPF / TC enforcement
          </div>
        </div>
      </div>

      {/* ─── Live Containment Cockpit ────────────────────────────────────────── */}
      <AgentCockpitSection agent={agent} style={{ marginBottom: 0 }} />

      {/* ─── Compliance Posture & CEL Policy Section ───────────────────────────── */}
      <div
        id="overview-compliance-posture-section"
        data-testid="overview-compliance-posture-section"
        className="card"
        style={{ padding: 20, display: 'flex', flexDirection: 'column', gap: 16 }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 12 }}>
          <div>
            <h3 style={{ margin: 0, fontSize: 16, fontWeight: 700, color: 'var(--text)' }}>
              Compliance Posture & Frameworks
            </h3>
            <div style={{ color: 'var(--muted)', fontSize: 12, marginTop: 4 }}>
              Active regulatory and security frameworks governing this agent, evaluated via Common Expression Language (CEL) policies and cluster admission rules.
            </div>
          </div>
          <Link
            to="/compliance/policies"
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '6px 12px', textDecoration: 'none' }}
          >
            Policy Engine & Bundles →
          </Link>
        </div>

        {/* Framework Cards Grid */}
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))', gap: 14 }}>
          {frameworkEntries.map(([fKey, data]) => {
            const passPct = data.total > 0 ? Math.round((data.passing / data.total) * 100) : 0
            const hasFails = data.failing > 0
            return (
              <div
                key={fKey}
                data-testid={`framework-card-${fKey}`}
                style={{
                  background: 'var(--surface2)',
                  border: `1px solid ${hasFails ? 'color-mix(in srgb, var(--error) 40%, transparent)' : 'var(--border)'}`,
                  borderRadius: 6,
                  padding: 14,
                  display: 'flex',
                  flexDirection: 'column',
                  justifyContent: 'space-between',
                  gap: 12,
                }}
              >
                <div>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 8 }}>
                    <div style={{ fontWeight: 700, fontSize: 14, color: 'var(--text)' }}>
                      {data.name}
                    </div>
                    <span
                      className="tag"
                      style={{
                        fontSize: 10,
                        padding: '2px 8px',
                        fontWeight: 700,
                        background: hasFails
                          ? 'color-mix(in srgb, var(--error) 15%, transparent)'
                          : data.passing > 0
                          ? 'rgba(16, 185, 129, 0.15)'
                          : 'rgba(156, 163, 175, 0.15)',
                        color: hasFails
                          ? 'var(--error)'
                          : data.passing > 0
                          ? 'var(--teal)'
                          : 'var(--muted)',
                      }}
                    >
                      {hasFails ? `${data.failing} FAILING` : data.total === 0 ? 'NOT ASSESSED' : 'COMPLIANT'}
                    </span>
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6 }}>
                    {data.passing} / {data.total} controls compliant ({passPct}%)
                  </div>
                </div>

                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', borderTop: '1px solid var(--border)', paddingTop: 10, fontSize: 11 }}>
                  <Link
                    to={`/policies?framework=${data.bundleId || fKey}`}
                    style={{ color: 'var(--teal)', textDecoration: 'none', fontWeight: 600 }}
                  >
                    View CEL Policy Rules →
                  </Link>
                  {data.officialDocsUrl && (
                    <a
                      href={data.officialDocsUrl}
                      target="_blank"
                      rel="noopener noreferrer"
                      style={{ color: 'var(--muted)', textDecoration: 'none' }}
                    >
                      Official Docs ↗
                    </a>
                  )}
                </div>
              </div>
            )
          })}
        </div>

        {/* Detailed Non-compliant or Failing Controls Inspection */}
        {nonCompliantControls.length > 0 && (
          <div style={{ marginTop: 8, display: 'flex', flexDirection: 'column', gap: 12 }}>
            <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--error)', display: 'flex', alignItems: 'center', gap: 6 }}>
              <span>⚠️ Non-Compliant Controls Requiring Remediation</span>
              <span className="tag" style={{ background: 'color-mix(in srgb, var(--error) 15%, transparent)', color: 'var(--error)', fontSize: 10 }}>
                {nonCompliantControls.length} findings
              </span>
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              {nonCompliantControls.map(res => {
                const slug = getControlSlug(res.control_name)
                const policy = lookupPolicyForControl(res.control_name, res.framework_name)
                return (
                  <div
                    key={res.control_id}
                    data-testid={`noncompliant-control-${slug}`}
                    style={{
                      background: 'var(--surface2)',
                      border: '1px solid color-mix(in srgb, var(--error) 30%, transparent)',
                      borderRadius: 6,
                      padding: 14,
                    }}
                  >
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', flexWrap: 'wrap', gap: 8 }}>
                      <div>
                        <div style={{ fontWeight: 600, fontSize: 13, color: 'var(--text)' }}>
                          {res.control_name}
                        </div>
                        <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
                          Framework: <strong>{res.framework_name}</strong> | ID: <code>{res.control_id}</code>
                        </div>
                      </div>
                      <span
                        className="tag"
                        style={{
                          fontSize: 10,
                          padding: '2px 8px',
                          fontWeight: 700,
                          background: res.status === 'fail'
                            ? 'color-mix(in srgb, var(--error) 15%, transparent)'
                            : 'color-mix(in srgb, var(--amber) 15%, transparent)',
                          color: res.status === 'fail' ? 'var(--error)' : 'var(--amber)',
                        }}
                      >
                        {res.status.toUpperCase()}
                      </span>
                    </div>

                    {/* CEL Expression */}
                    <div style={{ marginTop: 10 }}>
                      <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', marginBottom: 4 }}>
                        CEL Policy Rule ({policy.ruleId}):
                      </div>
                      <pre
                        data-testid={`cel-rule-expression-${slug}`}
                        style={{
                          margin: 0,
                          padding: '8px 12px',
                          background: 'var(--surface)',
                          borderRadius: 4,
                          border: '1px solid var(--border)',
                          fontFamily: 'monospace',
                          fontSize: 11,
                          overflowX: 'auto',
                          color: '#e2e8f0',
                        }}
                      >
                        <code>{policy.celExpression}</code>
                      </pre>
                    </div>

                    {/* Remediation & Audit notes */}
                    <div style={{ marginTop: 8, fontSize: 12, color: 'var(--text)' }}>
                      <span style={{ color: 'var(--muted)', fontWeight: 600 }}>Remediation: </span>
                      {policy.remediation}
                    </div>

                    {policy.testedSeparately && (
                      <div style={{ marginTop: 4, fontSize: 11, color: 'var(--cyan)' }}>
                        ℹ️ {policy.testedSeparatelyNote || 'Audited at cluster / namespace scope separately.'}
                      </div>
                    )}

                    {/* Links */}
                    <div style={{ marginTop: 10, display: 'flex', gap: 12, alignItems: 'center', fontSize: 12 }}>
                      <Link
                        to={`/policies?framework=${policy.frameworkId}&rule=${policy.ruleId}`}
                        data-testid={`cel-drilldown-link-${slug}`}
                        className="btn btn-secondary"
                        style={{ fontSize: 11, padding: '4px 10px', textDecoration: 'none' }}
                      >
                        Drill down to CEL Policy Rule →
                      </Link>
                      <a
                        href={policy.docsUrl}
                        target="_blank"
                        rel="noopener noreferrer"
                        data-testid={`compliance-docs-link-${slug}`}
                        style={{ color: 'var(--teal)', fontSize: 11, textDecoration: 'none', fontWeight: 600 }}
                      >
                        Official Benchmark Documentation ↗
                      </a>
                    </div>
                  </div>
                )
              })}
            </div>
          </div>
        )}
      </div>

      {/* ─── Detail Snapshot Panels ────────────────────────────────────────────── */}
      <div style={{
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fit, minmax(420px, 1fr))',
        gap: 16,
      }}>
        {/* Panel 1: Runtime & Deployment Snapshot */}
        <div className="card" data-testid="overview-section-runtime" style={{ padding: 18 }}>
          <div style={{ fontSize: 12, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 14 }}>
            Runtime & Deployment Snapshot
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 12, fontSize: 12 }}>
            <div>
              <span style={{ color: 'var(--muted)' }}>Namespace / Cluster</span>
              <div data-testid="overview-runtime-namespace" style={{ color: 'var(--text)', fontWeight: 500, marginTop: 2 }}>
                {namespace} ({clusterId})
              </div>
            </div>
            <div>
              <span style={{ color: 'var(--muted)' }}>Framework / Mode</span>
              <div data-testid="overview-runtime-framework" style={{ color: 'var(--text)', fontWeight: 500, marginTop: 2 }}>
                {framework} ({executionMode})
              </div>
            </div>
            <div>
              <span style={{ color: 'var(--muted)' }}>Model</span>
              <div data-testid="overview-runtime-model" style={{ color: 'var(--text)', marginTop: 2 }}>
                {model}
              </div>
            </div>
            <div>
              <span style={{ color: 'var(--muted)' }}>Service Account</span>
              <div data-testid="overview-runtime-sa" style={{ color: 'var(--text)', fontFamily: 'monospace', fontSize: 11, marginTop: 2 }}>
                {serviceAccount}
              </div>
            </div>
            <div>
              <span style={{ color: 'var(--muted)' }}>Node</span>
              <div data-testid="overview-runtime-node" style={{ color: 'var(--text)', marginTop: 2 }}>
                {node}
              </div>
            </div>
            <div>
              <span style={{ color: 'var(--muted)' }}>Runtime State</span>
              <div data-testid="overview-runtime-phase" style={{ color: 'var(--text)', fontWeight: 500, marginTop: 2 }}>
                {phase}
              </div>
            </div>
            <div style={{ gridColumn: 'span 2' }}>
              <span style={{ color: 'var(--muted)' }}>Pod UID</span>
              <div data-testid="overview-runtime-pod-uid" style={{ color: 'var(--muted)', fontFamily: 'monospace', fontSize: 11, marginTop: 2 }}>
                {podUid}
              </div>
            </div>
          </div>
        </div>

        {/* Panel 2: Responsibility & Ownership */}
        <div className="card" data-testid="overview-section-responsibility" style={{ padding: 18 }}>
          <div style={{ fontSize: 12, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 14 }}>
            Responsibility & Ownership
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 12, fontSize: 12 }}>
            <div>
              <span style={{ color: 'var(--muted)' }}>Assigned Owner</span>
              <div data-testid="overview-responsibility-owner" style={{ color: 'var(--text)', fontWeight: 500, marginTop: 2 }}>
                {ownerName ? (
                  ownerName
                ) : (
                  <span style={{ color: 'var(--muted)' }}>
                    {recordClass === 'discovered' || agent.is_registry_linked === false ? 'Registry not linked' : 'Unassigned'}
                  </span>
                )}
              </div>
            </div>
            <div>
              <span style={{ color: 'var(--muted)' }}>Team</span>
              <div data-testid="overview-responsibility-team" style={{ color: 'var(--text)', marginTop: 2 }}>
                {team || '-'}
              </div>
            </div>
            <div>
              <span style={{ color: 'var(--muted)' }}>Assignment Status</span>
              <div data-testid="overview-responsibility-status" style={{ color: 'var(--text)', marginTop: 2, textTransform: 'capitalize' }}>
                {assignmentStatus.replace('_', ' ')}
              </div>
            </div>
            <div>
              <span style={{ color: 'var(--muted)' }}>Tenant Boundary</span>
              <div data-testid="overview-responsibility-tenant" style={{ color: 'var(--muted)', fontFamily: 'monospace', fontSize: 11, marginTop: 2 }}>
                {agent.tenant_id}
              </div>
            </div>
            <div style={{ gridColumn: 'span 2', background: 'var(--surface2)', padding: '8px 12px', borderRadius: 4, marginTop: 4 }}>
              <span style={{ fontSize: 11, color: 'var(--muted)', display: 'block' }}>
                <strong>Identity Plane Decoupling:</strong> Workload executing actor identity is decoupled from human authorizing principal permissions.
              </span>
            </div>
          </div>
        </div>
      </div>

      {/* Panel 3: Evidence Sources & Freshness */}
      <div className="card" data-testid="overview-section-source-health" style={{ padding: 18 }}>
        <div style={{
          fontSize: 12,
          fontWeight: 700,
          textTransform: 'uppercase',
          letterSpacing: '0.06em',
          color: 'var(--muted)',
          marginBottom: 14,
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
        }}>
          <span>Evidence Sources & Freshness</span>
          <span
            data-testid="overview-overall-source-health"
            className="tag"
            style={{
              fontSize: 10,
              padding: '1px 6px',
              background: effectiveSourceHealth === 'healthy'
                ? 'rgba(16, 185, 129, 0.15)'
                : effectiveSourceHealth === 'degraded'
                ? 'rgba(217, 119, 6, 0.15)'
                : 'rgba(220, 38, 38, 0.15)',
              color: effectiveSourceHealth === 'healthy'
                ? 'var(--teal)'
                : effectiveSourceHealth === 'degraded'
                ? 'var(--amber)'
                : 'var(--error)',
            }}
          >
            {sourceHealthText}
          </span>
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10, fontSize: 11, marginBottom: 14 }}>
          <div style={{ background: 'var(--surface2)', padding: '8px 10px', borderRadius: 4 }}>
            <span style={{ color: 'var(--muted)' }}>K8s Discovery</span>
            <div data-testid="overview-k8s-health" style={{ fontWeight: 600, color: k8sStatus === 'healthy' ? 'var(--teal)' : k8sStatus === 'degraded' ? 'var(--amber)' : 'var(--error)', textTransform: 'capitalize', marginTop: 2 }}>
              {k8sStatus}
            </div>
          </div>
          <div style={{ background: 'var(--surface2)', padding: '8px 10px', borderRadius: 4 }}>
            <span style={{ color: 'var(--muted)' }}>Registry DB</span>
            <div data-testid="overview-postgres-health" style={{ fontWeight: 600, color: dbStatus === 'healthy' ? 'var(--teal)' : dbStatus === 'degraded' ? 'var(--amber)' : 'var(--error)', textTransform: 'capitalize', marginTop: 2 }}>
              {dbStatus}
            </div>
          </div>
          <div style={{ background: 'var(--surface2)', padding: '8px 10px', borderRadius: 4 }}>
            <span style={{ color: 'var(--muted)' }}>Crypto Proofs</span>
            <div data-testid="overview-crypto-health" style={{ fontWeight: 600, color: cryptoStatus === 'healthy' ? 'var(--teal)' : cryptoStatus === 'degraded' ? 'var(--amber)' : 'var(--error)', textTransform: 'capitalize', marginTop: 2 }}>
              {cryptoStatus}
            </div>
          </div>
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10, fontSize: 12, borderTop: '1px solid var(--border)', paddingTop: 12 }}>
          <div>
            <span style={{ color: 'var(--muted)' }}>Last Observed</span>
            <div data-testid="overview-last-observed" style={{ color: 'var(--text)', marginTop: 2 }}>
              {fmtRelative(observedTime)}
            </div>
            <div style={{ fontSize: 10, color: 'var(--muted)' }}>{fmtDate(observedTime)}</div>
          </div>
          <div>
            <span style={{ color: 'var(--muted)' }}>Last Transition</span>
            <div data-testid="overview-last-transition" style={{ color: 'var(--text)', marginTop: 2 }}>
              {fmtRelative(transitionTime)}
            </div>
            <div style={{ fontSize: 10, color: 'var(--muted)' }}>{fmtDate(transitionTime)}</div>
          </div>
          <div>
            <span style={{ color: 'var(--muted)' }}>Last Action</span>
            <div data-testid="overview-last-action" style={{ color: actionTime ? 'var(--text)' : 'var(--muted)', marginTop: 2 }}>
              {actionTime ? fmtRelative(actionTime) : 'No observed events'}
            </div>
            {actionTime && <div style={{ fontSize: 10, color: 'var(--muted)' }}>{fmtDate(actionTime)}</div>}
          </div>
        </div>
      </div>

      {/* ─── Dossier Section Quick-Links ────────────────────────────────────── */}
      <div className="card" data-testid="overview-dossier-links" style={{ padding: '16px 20px' }}>
        <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 12 }}>
          Dossier Sections & Scoped Surfaces
        </div>
        <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
          <Link
            to={`/agents/${agent.id}?tab=identity`}
            data-testid="overview-link-identity"
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '6px 12px', textDecoration: 'none', color: 'var(--text)' }}
          >
            Identity & SPIFFE →
          </Link>
          <Link
            to={`/agents/${agent.id}?tab=access`}
            data-testid="overview-link-access"
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '6px 12px', textDecoration: 'none', color: 'var(--text)' }}
          >
            Access & Containment →
          </Link>
          <Link
            to={`/agents/${agent.id}?tab=assessments`}
            data-testid="overview-link-assessments"
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '6px 12px', textDecoration: 'none', color: 'var(--text)' }}
          >
            Assessments & Controls →
          </Link>
          <Link
            to={`/agents/${agent.id}?tab=activity`}
            data-testid="overview-link-activity"
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '6px 12px', textDecoration: 'none', color: 'var(--text)' }}
          >
            Activity Timeline →
          </Link>
          <Link
            to={`/audit?agent=${encodeURIComponent(agent.id)}`}
            data-testid="overview-deeplink-audit"
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '6px 12px', textDecoration: 'none', color: 'var(--cyan)' }}
          >
            Audit Trail ↗
          </Link>
          <Link
            to={`/credential-inventory?actor=${encodeURIComponent(agent.id)}`}
            data-testid="overview-deeplink-credentials"
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '6px 12px', textDecoration: 'none', color: 'var(--violet)' }}
          >
            Credential Inventory ↗
          </Link>
          <Link
            to={`/agent-trust-topology?actor=${encodeURIComponent(agent.id)}`}
            data-testid="overview-deeplink-topology"
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '6px 12px', textDecoration: 'none', color: 'var(--teal)' }}
          >
            Trust Topology ↗
          </Link>
        </div>
      </div>
    </div>
  )
}
