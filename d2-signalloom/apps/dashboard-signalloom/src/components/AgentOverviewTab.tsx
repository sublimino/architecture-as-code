import { Link } from 'react-router-dom'
import type { AgentResponse, SourceHealthMap } from '../types/api'
import { colors } from '../styles/tokens'

// ─── Helpers ────────────────────────────────────────────────────────────────

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
  sourceHealth?: 'healthy' | 'degraded' | 'unavailable' | null
  sourceHealthDetail?: SourceHealthMap | null
  claiming?: boolean
  claimError?: string | null
  retryingClaimRefresh?: boolean
  onClaim?: () => void
}

export default function AgentOverviewTab({
  agent,
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
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 8 }}>
              Governance Posture
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
