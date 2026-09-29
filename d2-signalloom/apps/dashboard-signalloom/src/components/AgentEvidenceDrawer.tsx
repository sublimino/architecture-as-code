import { useState, useEffect, useCallback } from 'react'
import type { AgentResponse, SourceHealthMap } from '../types/api'
import StatusBadge, { KernelStateBadge, isFrozenWithoutStun } from './StatusBadge'
import CredentialStateNotice from './CredentialStateNotice'
import RiskWidget from './RiskWidget'
import { useAgentRisk } from '../hooks/useAgentRisk'

/**
 * The drawer's quantitative-risk panel.
 *
 * Its own component, and not inlined, for one reason that is not style: the
 * drawer renders `agent` as nullable and returns early when there is no
 * selection, so a `useAgentRisk` call in the drawer body would sit above an
 * early return and change the hook order between renders. A child component
 * mounts and unmounts instead, which is the legal way to make a hook
 * conditional, and its unmount is what aborts the in-flight risk query when
 * the operator closes the drawer.
 */
function AgentRiskSection({ agentId }: { agentId: string }) {
  const { data, loading, error, source, refresh } = useAgentRisk(agentId)
  return (
    <RiskWidget
      testId="drawer-section-risk"
      title="Quantitative Risk (OpenFAIR)"
      lef={data?.lef ?? null}
      lossMagnitude={data?.lossMagnitude.mode ?? null}
      pml={data?.pml ?? null}
      ale={data?.ale ?? null}
      tvar={data?.tvar ?? null}
      source={source}
      loading={loading}
      error={error}
      onRetry={refresh}
    />
  )
}

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

// ─── Props ──────────────────────────────────────────────────────────────────

export interface AgentEvidenceDrawerProps {
  agent: AgentResponse | null
  sourceHealth?: 'healthy' | 'degraded' | 'unavailable' | null
  sourceHealthDetail?: SourceHealthMap | null
  onClose: () => void
  onOpenFullRecord?: (id: string) => void
  onEdit?: (agent: AgentResponse) => void
}

export default function AgentEvidenceDrawer({
  agent,
  sourceHealth,
  sourceHealthDetail,
  onClose,
  onOpenFullRecord,
  onEdit,
}: AgentEvidenceDrawerProps) {
  const [copiedId, setCopiedId] = useState(false)

  // Keyboard shortcut: Escape closes drawer
  const handleKeyDown = useCallback((e: KeyboardEvent) => {
    if (e.key === 'Escape') {
      onClose()
    }
  }, [onClose])

  useEffect(() => {
    if (agent) {
      window.addEventListener('keydown', handleKeyDown)
      return () => window.removeEventListener('keydown', handleKeyDown)
    }
  }, [agent, handleKeyDown])

  if (!agent) return null

  // 1. Record Class & Badges
  const recordClass = agent.record_class || (agent.is_registry_linked === false ? 'discovered' : 'registered')
  const recordClassLabel = recordClass.charAt(0).toUpperCase() + recordClass.slice(1)

  // 2. Runtime metadata
  const namespace = agent.runtime?.namespace || agent.namespace || 'default'
  const framework = agent.runtime?.framework || agent.framework || agent.type || 'Custom'
  const executionMode = agent.runtime?.execution_mode || agent.type || '-'
  const model = agent.runtime?.model || agent.model_name || 'Not specified'
  const node = agent.runtime?.node || agent.node || 'Not assigned'
  const podUid = agent.runtime?.pod_uid || agent.pod_uid || '-'
  const serviceAccount = agent.runtime?.service_account || agent.service_account || '-'
  // Kernel frozen with no stun record: the lifecycle label is stale, so it is
  // never used as a fallback phase and never rendered as the header badge.
  const splitBrainFrozen = isFrozenWithoutStun(agent)
  const phase = agent.runtime?.phase || (splitBrainFrozen ? null : agent.state) || 'Running'

  // 3. Responsibility metadata (Truthful language)
  const ownerName = agent.responsibility?.owner_name || agent.owner
  const team = agent.responsibility?.team
  const assignmentStatus = agent.responsibility?.assignment_status || (ownerName ? 'assigned' : 'unassigned')

  // 4. Assessment & Attention metadata (Truthful language)
  const isNotAssessed = (agent.assessment_summary?.status === 'not_assessed') ||
    (agent.compliance_summary.total_controls === 0) ||
    (agent.compliance_summary.posture_score === null && agent.compliance_summary.passing === 0 && agent.compliance_summary.failing === 0)

  const attentionLevel = agent.attention?.level || (agent.compliance_summary.failing > 0 ? 'critical' : 'none')
  const highestIssue = agent.attention?.highest_issue ||
    (agent.compliance_summary.failing > 0
      ? `${agent.compliance_summary.failing} failing control${agent.compliance_summary.failing > 1 ? 's' : ''} detected`
      : 'No verified issues')

  const postureScorePct = agent.compliance_summary.posture_score !== null
    ? Math.round(agent.compliance_summary.posture_score <= 1.0 ? agent.compliance_summary.posture_score * 100 : agent.compliance_summary.posture_score)
    : null

  // 5. Identity & Telemetry (Truthful language)
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

  function handleCopyId() {
    navigator.clipboard?.writeText(agent?.id ?? '')
    setCopiedId(true)
    setTimeout(() => setCopiedId(false), 2000)
  }

  return (
    <>
      {/* Backdrop overlay */}
      <div
        data-testid="agent-evidence-drawer-backdrop"
        onClick={onClose}
        style={{
          position: 'fixed',
          inset: 0,
          background: 'rgba(0,0,0,0.5)',
          backdropFilter: 'blur(3px)',
          zIndex: 999,
        }}
      />

      {/* Slide-out drawer panel */}
      <div
        data-testid="agent-evidence-drawer"
        role="dialog"
        aria-modal="true"
        aria-label={`Evidence for ${agent.name}`}
        style={{
          position: 'fixed',
          top: 0,
          right: 0,
          bottom: 0,
          width: 560,
          maxWidth: '100vw',
          background: 'var(--surface)',
          borderLeft: '1px solid var(--border)',
          zIndex: 1000,
          display: 'flex',
          flexDirection: 'column',
          overflow: 'hidden',
          boxShadow: '-8px 0 24px rgba(0,0,0,0.4)',
        }}
      >
        {/* Header */}
        <div style={{
          padding: '18px 22px 14px',
          borderBottom: '1px solid var(--border)',
          background: 'var(--surface2)',
          flexShrink: 0,
        }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 8 }}>
            <div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                <h2
                  data-testid="drawer-agent-name"
                  style={{ fontSize: 18, fontWeight: 700, color: 'var(--text)', margin: 0 }}
                >
                  {agent.name || 'Unnamed agent'}
                </h2>
                <span
                  data-testid="drawer-record-class-badge"
                  className="tag"
                  style={{
                    fontSize: 10,
                    padding: '2px 6px',
                    background: recordClass === 'discovered'
                      ? 'rgba(59, 130, 246, 0.15)'
                      : recordClass === 'resolved'
                      ? 'rgba(139, 92, 246, 0.15)'
                      : recordClass === 'fixture'
                      ? 'rgba(156, 163, 175, 0.15)'
                      : 'rgba(16, 185, 129, 0.15)',
                    color: recordClass === 'discovered'
                      ? 'var(--cyan)'
                      : recordClass === 'resolved'
                      ? 'var(--violet)'
                      : recordClass === 'fixture'
                      ? 'var(--muted)'
                      : 'var(--teal)',
                  }}
                >
                  {recordClassLabel}
                </span>
                {!splitBrainFrozen && (
                  <StatusBadge status={agent.lifecycle_state} variant="lifecycle" testId="drawer-lifecycle-badge" />
                )}
                <KernelStateBadge view={agent} testId="drawer-kernel-state-badge" />
              </div>
              <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
                Quick Evidence Dossier · {framework} · {executionMode}
              </div>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              {onOpenFullRecord && (
                <button
                  type="button"
                  className="btn btn-secondary"
                  data-testid="drawer-header-full-record"
                  onClick={() => onOpenFullRecord(agent.id)}
                  style={{
                    fontSize: 11,
                    padding: '3px 8px',
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: 4,
                  }}
                  title="Open full agent dossier"
                >
                  <span>Full Dossier</span>
                  <span style={{ fontSize: 10 }}>&rarr;</span>
                </button>
              )}
              <button
                onClick={onClose}
                aria-label="Close evidence drawer"
                data-testid="agent-evidence-drawer-close"
                style={{
                  background: 'none',
                  border: 'none',
                  color: 'var(--muted)',
                  fontSize: 22,
                  cursor: 'pointer',
                  padding: '2px 6px',
                  lineHeight: 1,
                }}
              >
                &times;
              </button>
            </div>
          </div>

          {/* Identifier bar (Safe copy: only copies ID string) */}
          <div style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            background: 'var(--surface)',
            border: '1px solid var(--border)',
            borderRadius: 4,
            padding: '4px 10px',
            marginTop: 8,
          }}>
            <span
              data-testid="drawer-agent-id"
              style={{ fontFamily: 'monospace', fontSize: 11, color: 'var(--muted)' }}
            >
              ID: {agent.id}
            </span>
            <button
              data-testid="drawer-copy-id"
              type="button"
              className="btn btn-secondary"
              style={{ fontSize: 10, padding: '2px 8px' }}
              onClick={handleCopyId}
              title="Copy Agent ID"
            >
              {copiedId ? 'Copied!' : 'Copy ID'}
            </button>
          </div>
        </div>

        {/* Scrollable Body Content */}
        <div style={{
          flex: 1,
          overflowY: 'auto',
          padding: '16px 22px',
          display: 'flex',
          flexDirection: 'column',
          gap: 16,
        }}>

          {/* 1. Attention & Assessments Snapshot */}
          <div className="card" data-testid="drawer-section-assessment" style={{ padding: 14 }}>
            <div style={{
              fontSize: 11,
              fontWeight: 600,
              textTransform: 'uppercase',
              letterSpacing: '0.06em',
              color: 'var(--muted)',
              marginBottom: 8,
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'center',
            }}>
              <span>Verified Attention & Assessment</span>
              <span
                data-testid="drawer-attention-level"
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

            <div
              data-testid="drawer-highest-issue"
              style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 8 }}
            >
              {highestIssue}
            </div>

            <div style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(2, 1fr)',
              gap: 8,
              paddingTop: 8,
              borderTop: '1px solid var(--border)',
              fontSize: 12,
            }}>
              <div>
                <span style={{ color: 'var(--muted)' }}>Governance Evaluation:</span>
                <div style={{ marginTop: 2 }}>
                  {isNotAssessed ? (
                    <span
                      data-testid="drawer-assessment-status"
                      className="tag"
                      style={{ background: 'rgba(156, 163, 175, 0.15)', color: 'var(--muted)', fontSize: 11 }}
                    >
                      Not assessed
                    </span>
                  ) : agent.compliance_summary.failing > 0 ? (
                    <span data-testid="drawer-assessment-status" style={{ color: 'var(--error)', fontWeight: 600 }}>
                      {agent.compliance_summary.failing} failing / {agent.compliance_summary.total_controls} total
                    </span>
                  ) : (
                    <span data-testid="drawer-assessment-status" style={{ color: 'var(--teal)', fontWeight: 600 }}>
                      {agent.compliance_summary.passing} / {agent.compliance_summary.total_controls} passing
                    </span>
                  )}
                </div>
              </div>

              <div>
                <span style={{ color: 'var(--muted)' }}>Posture Score:</span>
                <div data-testid="drawer-posture-score" style={{ marginTop: 2, fontWeight: 700, fontSize: 14 }}>
                  {isNotAssessed ? (
                    <span style={{ color: 'var(--muted)', fontSize: 12, fontWeight: 400 }}>Not assessed</span>
                  ) : postureScorePct !== null ? (
                    <span style={{ color: postureScorePct >= 70 ? 'var(--teal)' : postureScorePct >= 50 ? 'var(--amber)' : 'var(--error)' }}>
                      {postureScorePct}%
                    </span>
                  ) : (
                    <span style={{ color: 'var(--muted)', fontSize: 12, fontWeight: 400 }}>-</span>
                  )}
                </div>
              </div>
            </div>
          </div>

          {/* 1b. Quantitative Risk (OpenFAIR): live riskctl figures, or demo fixtures.
              Placed directly under the qualitative assessment on purpose: a posture
              score answers "how bad is the control coverage" and these four answer
              "what does that cost", and the pair is the whole argument. */}
          <AgentRiskSection agentId={agent.id} />

          {/* 2. Runtime Snapshot */}
          <div className="card" data-testid="drawer-section-runtime" style={{ padding: 14 }}>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 10 }}>
              Runtime Snapshot
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10, fontSize: 12 }}>
              <div>
                <span style={{ color: 'var(--muted)' }}>Namespace / Cluster</span>
                <div data-testid="drawer-runtime-namespace" style={{ color: 'var(--text)', fontWeight: 500, marginTop: 1 }}>
                  {namespace}
                </div>
              </div>
              <div>
                <span style={{ color: 'var(--muted)' }}>Framework / Mode</span>
                <div data-testid="drawer-runtime-framework" style={{ color: 'var(--text)', fontWeight: 500, marginTop: 1 }}>
                  {framework} ({executionMode})
                </div>
              </div>
              <div>
                <span style={{ color: 'var(--muted)' }}>Model</span>
                <div data-testid="drawer-runtime-model" style={{ color: 'var(--text)', marginTop: 1 }}>
                  {model}
                </div>
              </div>
              <div>
                <span style={{ color: 'var(--muted)' }}>Service Account</span>
                <div data-testid="drawer-runtime-sa" style={{ color: 'var(--text)', fontFamily: 'monospace', fontSize: 11, marginTop: 1 }}>
                  {serviceAccount}
                </div>
              </div>
              <div>
                <span style={{ color: 'var(--muted)' }}>Node</span>
                <div data-testid="drawer-runtime-node" style={{ color: 'var(--text)', marginTop: 1 }}>
                  {node}
                </div>
              </div>
              <div>
                <span style={{ color: 'var(--muted)' }}>Runtime State</span>
                <div data-testid="drawer-runtime-phase" style={{ color: 'var(--text)', fontWeight: 500, marginTop: 1 }}>
                  {phase}
                </div>
              </div>
              <div style={{ gridColumn: 'span 2' }}>
                <span style={{ color: 'var(--muted)' }}>Pod UID</span>
                <div data-testid="drawer-runtime-pod-uid" style={{ color: 'var(--muted)', fontFamily: 'monospace', fontSize: 11, marginTop: 1 }}>
                  {podUid}
                </div>
              </div>
            </div>
          </div>

          {/* 3. Responsibility */}
          <div className="card" data-testid="drawer-section-responsibility" style={{ padding: 14 }}>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 10 }}>
              Responsibility & Ownership
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10, fontSize: 12 }}>
              <div>
                <span style={{ color: 'var(--muted)' }}>Assigned Owner</span>
                <div data-testid="drawer-responsibility-owner" style={{ color: 'var(--text)', fontWeight: 500, marginTop: 1 }}>
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
                <div data-testid="drawer-responsibility-team" style={{ color: 'var(--text)', marginTop: 1 }}>
                  {team || '-'}
                </div>
              </div>
              <div>
                <span style={{ color: 'var(--muted)' }}>Assignment Status</span>
                <div data-testid="drawer-responsibility-status" style={{ color: 'var(--text)', marginTop: 1, textTransform: 'capitalize' }}>
                  {assignmentStatus.replace('_', ' ')}
                </div>
              </div>
              <div>
                <span style={{ color: 'var(--muted)' }}>Tenant Boundary</span>
                <div data-testid="drawer-responsibility-tenant" style={{ color: 'var(--muted)', fontFamily: 'monospace', fontSize: 11, marginTop: 1 }}>
                  {agent.tenant_id}
                </div>
              </div>
            </div>
          </div>

          {/* 4. Identity, Trust & Containment Telemetry */}
          <div className="card" data-testid="drawer-section-identity" style={{ padding: 14 }}>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 10 }}>
              Identity, Trust & Containment
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10, fontSize: 12 }}>
              <div>
                <span style={{ color: 'var(--muted)' }}>SPIFFE Workload Identity</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 2 }}>
                  <span
                    data-testid="drawer-spiffe-status"
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
                  <span
                    data-testid="drawer-spiffe-id"
                    style={{ fontFamily: 'monospace', fontSize: 11, color: 'var(--text)', wordBreak: 'break-all' }}
                  >
                    {spiffeId}
                  </span>
                </div>
              </div>

              {aliases.length > 0 && (
                <div>
                  <span style={{ color: 'var(--muted)' }}>Identity Aliases</span>
                  <div data-testid="drawer-identity-aliases" style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 3 }}>
                    {aliases.map(alias => (
                      <span key={alias} className="tag" style={{ fontSize: 10, padding: '1px 6px' }}>
                        {alias}
                      </span>
                    ))}
                  </div>
                </div>
              )}

              <div>
                <span style={{ color: 'var(--muted)' }}>Credential State</span>
                <div data-testid="drawer-credential-notice" style={{ marginTop: 2 }}>
                  <CredentialStateNotice
                    credentialState={agent.credential_state}
                    agentName={agent.name}
                    variant="inline"
                  />
                </div>
              </div>

              <div>
                <span style={{ color: 'var(--muted)' }}>Observed Kernel Containment Telemetry</span>
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 4 }}>
                  {splitBrainFrozen ? (
                    <KernelStateBadge view={agent} testId="drawer-kernel-split-brain" />
                  ) : isTelemetryFrozenOrDrop ? (
                    <>
                      <span
                        data-testid="drawer-kernel-cgroup"
                        className="tag"
                        title="cgroup.freeze: 1 (FROZEN): Processes atomically suspended by Sentinel"
                        style={{ fontSize: 10, padding: '2px 6px', background: 'color-mix(in srgb, var(--error) 15%, transparent)', color: 'var(--error)', borderColor: 'color-mix(in srgb, var(--error) 30%, transparent)' }}
                      >
                        cgroup: FROZEN
                      </span>
                      <span
                        data-testid="drawer-kernel-tc"
                        className="tag"
                        title="TC matchall drop active: Network isolated by Sentinel"
                        style={{ fontSize: 10, padding: '2px 6px', background: 'color-mix(in srgb, var(--error) 15%, transparent)', color: 'var(--error)', borderColor: 'color-mix(in srgb, var(--error) 30%, transparent)' }}
                      >
                        TC: DROP
                      </span>
                    </>
                  ) : isContainmentRequested ? (
                    <span
                      data-testid="drawer-kernel-unconfirmed"
                      className="tag"
                      title="Containment requested but kernel telemetry observation is unconfirmed"
                      style={{ fontSize: 10, padding: '2px 6px', background: 'color-mix(in srgb, var(--amber) 15%, transparent)', color: 'var(--amber)', borderColor: 'color-mix(in srgb, var(--amber) 30%, transparent)' }}
                    >
                      Requested (Outcome unconfirmed)
                    </span>
                  ) : (
                    <>
                      <span
                        data-testid="drawer-kernel-cgroup"
                        className="tag"
                        title="cgroup.freeze: 0 (THAWED)"
                        style={{ fontSize: 10, padding: '2px 6px', background: 'color-mix(in srgb, var(--teal) 15%, transparent)', color: 'var(--teal)', borderColor: 'color-mix(in srgb, var(--teal) 30%, transparent)' }}
                      >
                        cgroup: THAWED
                      </span>
                      <span
                        data-testid="drawer-kernel-tc"
                        className="tag"
                        title="TC drop: INACTIVE"
                        style={{ fontSize: 10, padding: '2px 6px', background: 'color-mix(in srgb, var(--teal) 15%, transparent)', color: 'var(--teal)', borderColor: 'color-mix(in srgb, var(--teal) 30%, transparent)' }}
                      >
                        TC: PASS
                      </span>
                    </>
                  )}
                </div>
              </div>
            </div>
          </div>

          {/* 5. Source Health & Freshness */}
          <div className="card" data-testid="drawer-section-source-health" style={{ padding: 14 }}>
            <div style={{
              fontSize: 11,
              fontWeight: 600,
              textTransform: 'uppercase',
              letterSpacing: '0.06em',
              color: 'var(--muted)',
              marginBottom: 10,
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'center',
            }}>
              <span>Evidence Sources & Freshness</span>
              <span
                data-testid="drawer-overall-source-health"
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
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8, fontSize: 11, marginBottom: 12 }}>
              <div style={{ background: 'var(--surface2)', padding: '6px 8px', borderRadius: 4 }}>
                <span style={{ color: 'var(--muted)' }}>K8s Discovery</span>
                <div data-testid="drawer-k8s-health" style={{ fontWeight: 600, color: k8sStatus === 'healthy' ? 'var(--teal)' : k8sStatus === 'degraded' ? 'var(--amber)' : 'var(--error)', textTransform: 'capitalize', marginTop: 1 }}>
                  {k8sStatus}
                </div>
              </div>
              <div style={{ background: 'var(--surface2)', padding: '6px 8px', borderRadius: 4 }}>
                <span style={{ color: 'var(--muted)' }}>Registry DB</span>
                <div data-testid="drawer-postgres-health" style={{ fontWeight: 600, color: dbStatus === 'healthy' ? 'var(--teal)' : dbStatus === 'degraded' ? 'var(--amber)' : 'var(--error)', textTransform: 'capitalize', marginTop: 1 }}>
                  {dbStatus}
                </div>
              </div>
              <div style={{ background: 'var(--surface2)', padding: '6px 8px', borderRadius: 4 }}>
                <span style={{ color: 'var(--muted)' }}>Crypto Proofs</span>
                <div data-testid="drawer-crypto-health" style={{ fontWeight: 600, color: cryptoStatus === 'healthy' ? 'var(--teal)' : cryptoStatus === 'degraded' ? 'var(--amber)' : 'var(--error)', textTransform: 'capitalize', marginTop: 1 }}>
                  {cryptoStatus}
                </div>
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8, fontSize: 12, borderTop: '1px solid var(--border)', paddingTop: 10 }}>
              <div>
                <span style={{ color: 'var(--muted)' }}>Last Observed</span>
                <div data-testid="drawer-last-observed" style={{ color: 'var(--text)', marginTop: 1 }}>
                  {fmtRelative(observedTime)}
                </div>
                <div style={{ fontSize: 10, color: 'var(--muted)' }}>{fmtDate(observedTime)}</div>
              </div>
              <div>
                <span style={{ color: 'var(--muted)' }}>Last Transition</span>
                <div data-testid="drawer-last-transition" style={{ color: 'var(--text)', marginTop: 1 }}>
                  {fmtRelative(transitionTime)}
                </div>
                <div style={{ fontSize: 10, color: 'var(--muted)' }}>{fmtDate(transitionTime)}</div>
              </div>
              <div>
                <span style={{ color: 'var(--muted)' }}>Last Action</span>
                <div data-testid="drawer-last-action" style={{ color: actionTime ? 'var(--text)' : 'var(--muted)', marginTop: 1 }}>
                  {actionTime ? fmtRelative(actionTime) : 'No observed events'}
                </div>
                {actionTime && <div style={{ fontSize: 10, color: 'var(--muted)' }}>{fmtDate(actionTime)}</div>}
              </div>
            </div>
          </div>
        </div>

        {/* Footer Actions */}
        <div style={{
          padding: '14px 22px',
          borderTop: '1px solid var(--border)',
          background: 'var(--surface2)',
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          gap: 10,
          flexShrink: 0,
        }}>
          <div style={{ display: 'flex', gap: 8 }}>
            <button
              type="button"
              className="btn btn-secondary"
              data-testid="drawer-close-btn"
              onClick={onClose}
              style={{ fontSize: 12 }}
            >
              Close
            </button>
            {onEdit && (
              <button
                type="button"
                className="btn btn-secondary"
                data-testid="drawer-edit-agent"
                onClick={() => onEdit(agent)}
                style={{ fontSize: 12 }}
              >
                Edit Agent
              </button>
            )}
          </div>
          {onOpenFullRecord && (
            <button
              type="button"
              className="btn btn-primary"
              data-testid="drawer-open-full-record"
              onClick={() => onOpenFullRecord(agent.id)}
              style={{ fontSize: 12, padding: '6px 16px' }}
            >
              Open Full Record &rarr;
            </button>
          )}
        </div>
      </div>
    </>
  )
}
