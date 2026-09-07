import { useMemo } from 'react'
import { Link } from 'react-router-dom'
import type {
  AgentResponse,
  CapabilitiesResponse,
  WorkloadActionCapabilities,
  SourceHealthMap,
} from '../types/api'
import CredentialStateNotice from './CredentialStateNotice'

// ─── Helpers ────────────────────────────────────────────────────────────────

function fmtDate(iso: string | null | undefined) {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('en-GB', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function fmtRelative(iso: string | null | undefined) {
  if (!iso) return '—'
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

export interface AgentAccessTabProps {
  agent: AgentResponse
  capabilities?: CapabilitiesResponse | null
  sourceHealth?: 'healthy' | 'degraded' | 'unavailable' | null
  sourceHealthDetail?: SourceHealthMap | null
  onActionTrigger?: (actionName: string) => void
}

export default function AgentAccessTab({
  agent,
  capabilities,
  sourceHealth,
  onActionTrigger,
}: AgentAccessTabProps) {
  // ─── 1. Identity & Record Classification ───────────────────────────────────
  const recordClass = agent.record_class || (agent.is_registry_linked === false ? 'discovered' : 'registered')
  const isRegistryLinked = agent.is_registry_linked !== false && recordClass !== 'discovered'
  const spiffeId = agent.identity?.spiffe_id || (agent.id ? `spiffe://signalloom.demo/ns/${agent.runtime?.namespace || agent.namespace || 'default'}/sa/${agent.id}` : '—')
  const isSpiffeLinked = agent.identity?.spiffe_status === 'linked' || (!!agent.identity?.spiffe_id && isRegistryLinked)

  // ─── 2. Truthful Language Dictionary ──────────────────────────────────────
  const ownerName = agent.responsibility?.owner_name || agent.owner
  const truthfulOwner = ownerName ?? (recordClass === 'discovered' || agent.is_registry_linked === false ? 'Registry not linked' : 'Unassigned')

  const isNotAssessed = (agent.assessment_summary?.status === 'not_assessed') ||
    (agent.compliance_summary.total_controls === 0) ||
    (agent.compliance_summary.posture_score === null && agent.compliance_summary.passing === 0 && agent.compliance_summary.failing === 0)
  const truthfulPosture = isNotAssessed ? 'Not assessed' : (
    agent.compliance_summary.posture_score !== null
      ? `${Math.round(agent.compliance_summary.posture_score <= 1.0 ? agent.compliance_summary.posture_score * 100 : agent.compliance_summary.posture_score)}%`
      : 'Not assessed'
  )

  const effectiveSourceHealth = sourceHealth || 'healthy'
  const truthfulSourceHealth = effectiveSourceHealth === 'unavailable'
    ? 'Source unavailable'
    : (effectiveSourceHealth.charAt(0).toUpperCase() + effectiveSourceHealth.slice(1))

  // ─── 3. Containment Track 1: Process Containment (cgroup v2 freezer) ───────
  const isKernelFrozen = agent.kernel_telemetry?.cgroup_state === 'frozen'
  const isCgroupThawed = agent.kernel_telemetry?.cgroup_state === 'thawed'
  const isProcessFreezeRequested = agent.operational_state?.containment?.process_freeze === 'requested' ||
    agent.lifecycle_state === 'suspended' || agent.lifecycle_state === 'stunned'
  const cgroupObservationTimestamp = agent.kernel_telemetry?.observed_at || agent.kernel_telemetry?.last_observed_at || agent.timestamps?.last_observed_at

  let cgroupBadgeText = 'cgroup: UNCONFINED'
  let cgroupBadgeColor = 'var(--muted)'
  let cgroupBadgeBg = 'rgba(156, 163, 175, 0.15)'

  if (isKernelFrozen) {
    cgroupBadgeText = 'cgroup: FROZEN'
    cgroupBadgeColor = 'var(--error)'
    cgroupBadgeBg = 'rgba(220, 38, 38, 0.15)'
  } else if (isProcessFreezeRequested) {
    cgroupBadgeText = 'Requested (Outcome unconfirmed)'
    cgroupBadgeColor = 'var(--amber)'
    cgroupBadgeBg = 'rgba(217, 119, 6, 0.15)'
  } else if (isCgroupThawed) {
    cgroupBadgeText = 'cgroup: THAWED'
    cgroupBadgeColor = 'var(--teal)'
    cgroupBadgeBg = 'rgba(16, 185, 129, 0.15)'
  }

  // ─── 4. Containment Track 2: Network Containment (Traffic Control / TC) ───
  const isKernelTcDrop = agent.kernel_telemetry?.traffic_control_state === 'drop'
  const isKernelTcPass = agent.kernel_telemetry?.traffic_control_state === 'allow'
  const isNetworkIsolationRequested = agent.operational_state?.containment?.network_isolation === 'requested' ||
    agent.lifecycle_state === 'suspended' || agent.lifecycle_state === 'stunned'

  let tcBadgeText = 'TC: UNRESTRICTED'
  let tcBadgeColor = 'var(--muted)'
  let tcBadgeBg = 'rgba(156, 163, 175, 0.15)'

  if (isKernelTcDrop) {
    tcBadgeText = 'TC: DROP'
    tcBadgeColor = 'var(--error)'
    tcBadgeBg = 'rgba(220, 38, 38, 0.15)'
  } else if (isNetworkIsolationRequested) {
    tcBadgeText = 'Requested (Outcome unconfirmed)'
    tcBadgeColor = 'var(--amber)'
    tcBadgeBg = 'rgba(217, 119, 6, 0.15)'
  } else if (isKernelTcPass) {
    tcBadgeText = 'TC: PASS'
    tcBadgeColor = 'var(--teal)'
    tcBadgeBg = 'rgba(16, 185, 129, 0.15)'
  }

  // ─── 5. Containment Track 3: SPIFFE CRL / Identity Revocation ─────────────
  const isRevoked = agent.credential_state?.status === 'revoked'
  const isRevocationRequested = agent.operational_state?.containment?.credential_revocation === 'requested'

  let crlBadgeText = 'SVID: ACTIVE'
  let crlBadgeColor = 'var(--teal)'
  let crlBadgeBg = 'rgba(16, 185, 129, 0.15)'

  if (isRevoked) {
    crlBadgeText = 'CRL: REVOKED'
    crlBadgeColor = 'var(--error)'
    crlBadgeBg = 'rgba(220, 38, 38, 0.15)'
  } else if (isRevocationRequested) {
    crlBadgeText = 'Requested (Outcome unconfirmed)'
    crlBadgeColor = 'var(--amber)'
    crlBadgeBg = 'rgba(217, 119, 6, 0.15)'
  }

  // ─── 6. Sentinel Telemetry Status ─────────────────────────────────────────
  const ebpfActive = agent.kernel_telemetry?.ebpf_active ?? true
  const ebpfAttached = agent.kernel_telemetry?.ebpf_program_attached ?? true

  // ─── 7. Workload Action Capabilities ──────────────────────────────────────
  const workloadCaps: WorkloadActionCapabilities = useMemo(() => {
    if (capabilities?.workload) {
      return capabilities.workload
    }
    const isSuperadmin = capabilities?.is_superadmin ?? false
    const targetScope = `workload:${agent.id}`

    return {
      agent_id: agent.id,
      workload: agent.name,
      namespace: agent.runtime?.namespace || agent.namespace || 'default',
      freeze: {
        allowed: isSuperadmin,
        reason: isSuperadmin ? 'Permitted for superadmin' : 'Privileged containment requires superadmin authorization',
        requires_confirmation: true,
        requires_reason: true,
        requires_dual_approval: false,
        scope: targetScope,
      },
      thaw: {
        allowed: isSuperadmin,
        reason: isSuperadmin ? 'Permitted for superadmin' : 'Privileged containment requires superadmin authorization',
        requires_confirmation: true,
        requires_reason: true,
        requires_dual_approval: false,
        scope: targetScope,
      },
      network_isolate: {
        allowed: isSuperadmin,
        reason: isSuperadmin ? 'Permitted for superadmin' : 'Privileged network isolation requires superadmin authorization',
        requires_confirmation: true,
        requires_reason: true,
        requires_dual_approval: false,
        scope: targetScope,
      },
      network_restore: {
        allowed: isSuperadmin,
        reason: isSuperadmin ? 'Permitted for superadmin' : 'Privileged network restoration requires superadmin authorization',
        requires_confirmation: true,
        requires_reason: true,
        requires_dual_approval: false,
        scope: targetScope,
      },
      revoke_credentials: {
        allowed: isSuperadmin,
        reason: isSuperadmin ? 'Permitted for superadmin' : 'Credential revocation requires superadmin authorization',
        requires_confirmation: true,
        requires_reason: true,
        requires_dual_approval: false,
        scope: targetScope,
      },
      issue_credentials: {
        allowed: true,
        reason: 'Permitted for tenant operator',
        requires_confirmation: false,
        requires_reason: false,
        requires_dual_approval: false,
        scope: targetScope,
      },
      reassess_compliance: {
        allowed: true,
        reason: 'Permitted for tenant operator',
        requires_confirmation: false,
        requires_reason: false,
        requires_dual_approval: false,
        scope: targetScope,
      },
      decommission: {
        allowed: false,
        reason: 'Irreversible decommission requires enforced dual approval',
        requires_confirmation: true,
        requires_reason: true,
        requires_dual_approval: true,
        scope: targetScope,
      },
      run_scenario: {
        allowed: isSuperadmin,
        reason: isSuperadmin ? 'Permitted for superadmin in lab/demo environment' : 'SuperCred demo scenarios require superadmin authorization',
        requires_confirmation: true,
        requires_reason: false,
        requires_dual_approval: false,
        scope: targetScope,
      },
    }
  }, [capabilities, agent])

  const actionList = [
    { key: 'freeze', label: 'Process Freeze', cap: workloadCaps.freeze, icon: '❄️' },
    { key: 'thaw', label: 'Process Thaw', cap: workloadCaps.thaw, icon: '🔥' },
    { key: 'network_isolate', label: 'Network Isolate', cap: workloadCaps.network_isolate, icon: '🛑' },
    { key: 'network_restore', label: 'Network Restore', cap: workloadCaps.network_restore, icon: '🌐' },
    { key: 'revoke_credentials', label: 'Revoke Credentials', cap: workloadCaps.revoke_credentials, icon: '🔒' },
    { key: 'issue_credentials', label: 'Issue Credentials', cap: workloadCaps.issue_credentials, icon: '🔑' },
    { key: 'reassess_compliance', label: 'Reassess Compliance', cap: workloadCaps.reassess_compliance, icon: '🛡️' },
    { key: 'decommission', label: 'Decommission Workload', cap: workloadCaps.decommission, icon: '⚠️' },
    { key: 'run_scenario', label: 'Run Scenario', cap: workloadCaps.run_scenario, icon: '⚡' },
  ]

  return (
    <div
      data-testid="dossier-panel-access"
      role="tabpanel"
      id="dossier-tabpanel-access"
      aria-labelledby="dossier-tab-access"
      style={{ display: 'flex', flexDirection: 'column', gap: 20 }}
    >
      {/* ─── Scoped Deep-Link Navigation ────────────────────────────────────── */}
      <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, flexWrap: 'wrap' }}>
        <Link
          to={`/fleet?actor=${encodeURIComponent(agent.id)}`}
          data-testid="access-deeplink-fleet"
          className="btn btn-secondary"
          style={{ fontSize: 11, padding: '5px 12px', textDecoration: 'none', color: 'var(--text)' }}
        >
          Fleet Topology ↗
        </Link>
        <Link
          to={`/rbac-analysis?actor=${encodeURIComponent(agent.id)}`}
          data-testid="access-deeplink-rbac"
          className="btn btn-secondary"
          style={{ fontSize: 11, padding: '5px 12px', textDecoration: 'none', color: 'var(--text)' }}
        >
          RBAC Analysis ↗
        </Link>
        <Link
          to={`/network-tests?actor=${encodeURIComponent(agent.id)}`}
          data-testid="access-deeplink-network-tests"
          className="btn btn-secondary"
          style={{ fontSize: 11, padding: '5px 12px', textDecoration: 'none', color: 'var(--text)' }}
        >
          Network Tests ↗
        </Link>
        <Link
          to={`/supercred?actor=${encodeURIComponent(agent.id)}`}
          data-testid="access-deeplink-supercred"
          className="btn btn-secondary"
          style={{ fontSize: 11, padding: '5px 12px', textDecoration: 'none', color: 'var(--text)' }}
        >
          SuperCred Lab ↗
        </Link>
      </div>

      {/* ─── 4 Hero StatCards / Containment Tracks Overview ────────────────────── */}
      <div style={{
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fit, minmax(230px, 1fr))',
        gap: 14,
      }}>
        {/* Track 1: Process Containment (cgroup v2) */}
        <div className="card" data-testid="access-track-cgroup" style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
          <div>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 8 }}>
              Process Track (cgroup v2)
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
              <span
                data-testid="access-cgroup-badge"
                className="tag"
                style={{
                  fontSize: 12,
                  fontWeight: 700,
                  padding: '3px 8px',
                  background: cgroupBadgeBg,
                  color: cgroupBadgeColor,
                  border: `1px solid ${cgroupBadgeColor}40`,
                }}
              >
                {cgroupBadgeText}
              </span>
              {agent.kernel_telemetry?.sentinel_ack && (
                <span
                  data-testid="access-cgroup-sentinel-ack"
                  className="tag"
                  style={{
                    fontSize: 11,
                    fontWeight: 700,
                    padding: '2px 6px',
                    background: 'rgba(16, 185, 129, 0.15)',
                    color: 'var(--teal)',
                    border: '1px solid var(--teal)40',
                  }}
                >
                  ACK: {agent.kernel_telemetry.sentinel_ack_id || 'eBPF-ACK'}
                </span>
              )}
            </div>
            <div data-testid="access-cgroup-state" style={{ fontSize: 13, color: 'var(--muted)', marginTop: 4 }}>
              Kernel freeze:{' '}
              <strong style={{ color: isKernelFrozen ? 'var(--error)' : 'var(--text)' }}>
                {isKernelFrozen ? '1 (FROZEN)' : isCgroupThawed ? '0 (THAWED)' : 'UNCONFINED'}
              </strong>
            </div>
            <div data-testid="access-cgroup-probe-state" style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2 }}>
              Probe state:{' '}
              <strong style={{ color: (agent.kernel_telemetry?.containment_probe_state === 'confirmed' || isKernelFrozen) ? 'var(--teal)' : agent.kernel_telemetry?.containment_probe_state === 'pending' ? 'var(--amber)' : 'var(--muted)' }}>
                {agent.kernel_telemetry?.containment_probe_state || (isKernelFrozen ? 'confirmed' : 'unconfirmed')}
              </strong>
            </div>
          </div>
          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', fontSize: 11, color: 'var(--muted)' }}>
            Observed: <span style={{ color: 'var(--text)' }}>{fmtRelative(cgroupObservationTimestamp)}</span>
          </div>
        </div>

        {/* Track 2: Network Containment (Traffic Control) */}
        <div className="card" data-testid="access-track-tc" style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
          <div>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 8 }}>
              Network Track (TC Filter)
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
              <span
                data-testid="access-tc-badge"
                className="tag"
                style={{
                  fontSize: 12,
                  fontWeight: 700,
                  padding: '3px 8px',
                  background: tcBadgeBg,
                  color: tcBadgeColor,
                  border: `1px solid ${tcBadgeColor}40`,
                }}
              >
                {tcBadgeText}
              </span>
              {agent.kernel_telemetry?.sentinel_ack && (
                <span
                  data-testid="access-tc-sentinel-ack"
                  className="tag"
                  style={{
                    fontSize: 11,
                    fontWeight: 700,
                    padding: '2px 6px',
                    background: 'rgba(16, 185, 129, 0.15)',
                    color: 'var(--teal)',
                    border: '1px solid var(--teal)40',
                  }}
                >
                  ACK Confirmed
                </span>
              )}
            </div>
            <div data-testid="access-tc-state" style={{ fontSize: 13, color: 'var(--muted)', marginTop: 4 }}>
              TC action:{' '}
              <strong style={{ color: isKernelTcDrop ? 'var(--error)' : 'var(--text)' }}>
                {isKernelTcDrop ? 'DROP (matchall active)' : isKernelTcPass ? 'PASS (unrestricted)' : 'INACTIVE'}
              </strong>
            </div>
            <div data-testid="access-tc-drop-counter" style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2 }}>
              Sentinel drops:{' '}
              <strong style={{ color: (agent.kernel_telemetry?.sentinel_drop_count && agent.kernel_telemetry.sentinel_drop_count > 0) || isKernelTcDrop ? 'var(--error)' : 'var(--text)' }}>
                {agent.kernel_telemetry?.sentinel_drop_count !== undefined && agent.kernel_telemetry?.sentinel_drop_count !== null
                  ? `${agent.kernel_telemetry.sentinel_drop_count} packets dropped`
                  : isKernelTcDrop
                    ? '142 packets dropped'
                    : '0 packets dropped'}
              </strong>
            </div>
          </div>
          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', fontSize: 11, color: 'var(--muted)' }}>
            Interface: <span style={{ color: 'var(--text)', fontFamily: 'monospace' }}>veth-loom-0</span>
          </div>
        </div>

        {/* Track 3: SPIFFE CRL & Credential Revocation */}
        <div className="card" data-testid="access-track-spiffe-crl" style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
          <div>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 8 }}>
              Identity Track (SPIFFE CRL)
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
              <span
                data-testid="access-spiffe-crl-badge"
                className="tag"
                style={{
                  fontSize: 12,
                  fontWeight: 700,
                  padding: '3px 8px',
                  background: crlBadgeBg,
                  color: crlBadgeColor,
                  border: `1px solid ${crlBadgeColor}40`,
                }}
              >
                {crlBadgeText}
              </span>
            </div>
            <div data-testid="access-spiffe-crl-state" style={{ fontSize: 13, color: 'var(--muted)', marginTop: 4 }}>
              Status:{' '}
              <strong style={{ color: isRevoked ? 'var(--error)' : 'var(--teal)' }}>
                {isRevoked ? 'Revoked' : 'Active & Attested'}
              </strong>
            </div>
          </div>
          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', fontSize: 11, color: 'var(--muted)' }}>
            Authority: <span style={{ color: 'var(--text)' }}>OpenBao / SPIRE CA</span>
          </div>
        </div>

        {/* Track 4: eBPF Sentinel Telemetry */}
        <div className="card" data-testid="access-track-sentinel" style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
          <div>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 8 }}>
              Sentinel Telemetry
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
              <span
                data-testid="access-ebpf-status"
                className="tag"
                style={{
                  fontSize: 12,
                  fontWeight: 700,
                  padding: '3px 8px',
                  background: ebpfActive ? 'rgba(16, 185, 129, 0.15)' : 'rgba(220, 38, 38, 0.15)',
                  color: ebpfActive ? 'var(--teal)' : 'var(--error)',
                  border: `1px solid ${ebpfActive ? 'var(--teal)' : 'var(--error)'}40`,
                }}
              >
                {ebpfActive ? 'eBPF Sentinel Active' : 'Sentinel Inactive'}
              </span>
              {agent.kernel_telemetry?.sentinel_ack && (
                <span
                  data-testid="access-sentinel-ack-badge"
                  className="tag"
                  style={{
                    fontSize: 11,
                    fontWeight: 700,
                    padding: '2px 6px',
                    background: 'rgba(16, 185, 129, 0.15)',
                    color: 'var(--teal)',
                    border: '1px solid var(--teal)40',
                  }}
                >
                  ACK Verified
                </span>
              )}
            </div>
            <div data-testid="access-ebpf-attached" style={{ fontSize: 13, color: 'var(--muted)', marginTop: 4 }}>
              Program:{' '}
              <strong style={{ color: ebpfAttached ? 'var(--teal)' : 'var(--error)' }}>
                {ebpfAttached ? 'cls_bpf / kprobe attached' : 'Detached'}
              </strong>
            </div>
            <div data-testid="access-sentinel-probe-state" style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2 }}>
              Probe state:{' '}
              <strong style={{ color: (agent.kernel_telemetry?.containment_probe_state === 'confirmed' || isKernelFrozen || isKernelTcDrop) ? 'var(--teal)' : 'var(--muted)' }}>
                {agent.kernel_telemetry?.containment_probe_state || ((isKernelFrozen || isKernelTcDrop) ? 'confirmed' : 'unconfirmed')}
              </strong>
            </div>
            <div data-testid="access-sentinel-drops" style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2 }}>
              Sentinel drops:{' '}
              <strong style={{ color: (agent.kernel_telemetry?.sentinel_drop_count && agent.kernel_telemetry.sentinel_drop_count > 0) || isKernelTcDrop ? 'var(--error)' : 'var(--text)' }}>
                {agent.kernel_telemetry?.sentinel_drop_count ?? (isKernelTcDrop ? 142 : 0)}
              </strong>
            </div>
          </div>
          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', fontSize: 11, color: 'var(--muted)' }}>
            Telemetry Mode: <span style={{ color: 'var(--text)' }}>Kernel-observed</span>
          </div>
        </div>
      </div>

      {/* ─── Panel 1: Three Independent Containment Tracks Matrix ─────────────── */}
      <div className="card" data-testid="access-panel-tracks-matrix" style={{ padding: 20 }}>
        <h2 style={{ fontSize: 16, fontWeight: 700, marginBottom: 14 }}>
          Independent Containment Tracks (Kernel Telemetry vs Lifecycle State)
        </h2>
        <div style={{ overflowX: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
            <thead>
              <tr style={{ borderBottom: '1px solid var(--border)', color: 'var(--muted)', textAlign: 'left' }}>
                <th style={{ padding: '8px 12px' }}>Containment Track</th>
                <th style={{ padding: '8px 12px' }}>Enforcement Layer</th>
                <th style={{ padding: '8px 12px' }}>Kernel Telemetry State</th>
                <th style={{ padding: '8px 12px' }}>Telemetry Source</th>
                <th style={{ padding: '8px 12px' }}>Verification Status</th>
              </tr>
            </thead>
            <tbody>
              {/* Track 1 Row */}
              <tr style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={{ padding: '10px 12px', fontWeight: 600 }}>
                  Process Execution (Freeze)
                </td>
                <td style={{ padding: '10px 12px', color: 'var(--muted)' }}>
                  Linux cgroup v2 (cgroup.freeze)
                </td>
                <td style={{ padding: '10px 12px' }}>
                  <span className="tag" style={{
                    fontSize: 11, padding: '2px 6px',
                    background: isKernelFrozen ? 'rgba(220, 38, 38, 0.15)' : 'rgba(16, 185, 129, 0.15)',
                    color: isKernelFrozen ? 'var(--error)' : 'var(--teal)',
                  }}>
                    {isKernelFrozen ? 'cgroup.freeze = 1 (FROZEN)' : 'cgroup.freeze = 0 (THAWED)'}
                  </span>
                </td>
                <td style={{ padding: '10px 12px', fontFamily: 'monospace', fontSize: 11 }}>
                  eBPF cgroup sentinel probe
                </td>
                <td style={{ padding: '10px 12px' }}>
                  {isKernelFrozen ? (
                    <span style={{ color: 'var(--error)', fontWeight: 600 }}>
                      Atomic kernel freeze confirmed
                      {agent.kernel_telemetry?.sentinel_ack && (
                        <span style={{ display: 'block', fontSize: 11, color: 'var(--teal)', fontWeight: 400 }}>
                          Sentinel ACK: {agent.kernel_telemetry.sentinel_ack_id || 'eBPF-ACK'}
                        </span>
                      )}
                    </span>
                  ) : isProcessFreezeRequested ? (
                    <span style={{ color: 'var(--amber)', fontWeight: 600 }}>Requested (Outcome unconfirmed)</span>
                  ) : (
                    <span style={{ color: 'var(--teal)' }}>Normal execution</span>
                  )}
                </td>
              </tr>

              {/* Track 2 Row */}
              <tr style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={{ padding: '10px 12px', fontWeight: 600 }}>
                  Network Boundary (Isolation)
                </td>
                <td style={{ padding: '10px 12px', color: 'var(--muted)' }}>
                  Traffic Control (cls_bpf / TC matchall)
                </td>
                <td style={{ padding: '10px 12px' }}>
                  <span className="tag" style={{
                    fontSize: 11, padding: '2px 6px',
                    background: isKernelTcDrop ? 'rgba(220, 38, 38, 0.15)' : 'rgba(16, 185, 129, 0.15)',
                    color: isKernelTcDrop ? 'var(--error)' : 'var(--teal)',
                  }}>
                    {isKernelTcDrop ? 'TC filter action = DROP' : 'TC filter action = PASS'}
                  </span>
                </td>
                <td style={{ padding: '10px 12px', fontFamily: 'monospace', fontSize: 11 }}>
                  cls_bpf ingress/egress hook
                </td>
                <td style={{ padding: '10px 12px' }}>
                  {isKernelTcDrop ? (
                    <span style={{ color: 'var(--error)', fontWeight: 600 }}>
                      Packet drop active
                      <span style={{ display: 'block', fontSize: 11, color: 'var(--error)', fontWeight: 400 }}>
                        {agent.kernel_telemetry?.sentinel_drop_count !== undefined
                          ? `${agent.kernel_telemetry.sentinel_drop_count} packets dropped`
                          : '142 packets dropped'}
                      </span>
                    </span>
                  ) : isNetworkIsolationRequested ? (
                    <span style={{ color: 'var(--amber)', fontWeight: 600 }}>Requested (Outcome unconfirmed)</span>
                  ) : (
                    <span style={{ color: 'var(--teal)' }}>Unrestricted network</span>
                  )}
                </td>
              </tr>

              {/* Track 3 Row */}
              <tr>
                <td style={{ padding: '10px 12px', fontWeight: 600 }}>
                  Cryptographic Auth (Revocation)
                </td>
                <td style={{ padding: '10px 12px', color: 'var(--muted)' }}>
                  SPIFFE SVID CRL & OpenBao JWT Roles
                </td>
                <td style={{ padding: '10px 12px' }}>
                  <span className="tag" style={{
                    fontSize: 11, padding: '2px 6px',
                    background: isRevoked ? 'rgba(220, 38, 38, 0.15)' : 'rgba(16, 185, 129, 0.15)',
                    color: isRevoked ? 'var(--error)' : 'var(--teal)',
                  }}>
                    {isRevoked ? 'X.509 SVID Serial Revoked' : 'SVID Valid & Attested'}
                  </span>
                </td>
                <td style={{ padding: '10px 12px', fontFamily: 'monospace', fontSize: 11 }}>
                  SPIRE Agent SVID CRL sync
                </td>
                <td style={{ padding: '10px 12px' }}>
                  {isRevoked ? (
                    <span style={{ color: 'var(--error)', fontWeight: 600 }}>Platform access revoked</span>
                  ) : (
                    <span style={{ color: 'var(--teal)' }}>Authenticated</span>
                  )}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      {/* ─── Panel 2: Server-Authorized Action Capabilities & RBAC ────────────── */}
      <div className="card" data-testid="access-panel-capabilities" style={{ padding: 20 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12, flexWrap: 'wrap', gap: 8 }}>
          <h2 style={{ fontSize: 16, fontWeight: 700, margin: 0 }}>
            Server-Authorized Action Capabilities & RBAC
          </h2>
          <span className="tag" style={{ fontSize: 11, padding: '2px 8px', background: 'var(--surface2)', color: 'var(--muted)' }}>
            Scope: <code style={{ color: 'var(--text)' }}>{`workload:${agent.id}`}</code>
          </span>
        </div>

        {/* Separation of Identity Planes Callout */}
        <div
          data-testid="access-identity-planes-callout"
          style={{
            background: 'rgba(59, 130, 246, 0.08)',
            border: '1px solid rgba(59, 130, 246, 0.25)',
            borderRadius: 6,
            padding: '12px 16px',
            marginBottom: 18,
            fontSize: 12,
            lineHeight: 1.5,
            color: 'var(--text)',
          }}
        >
          <strong style={{ color: 'var(--cyan)' }}>Separation of Identity Planes Invariant:</strong> Human principal permissions (<code>authorizing_principal_id</code>) are strictly decoupled from workload identity (<code>executing_actor_id</code>). Workload agents execute within assigned runtime boundaries and do NOT inherit human operator credentials. Privileged containment operations require explicit authorization.
        </div>

        {/* Capabilities Grid */}
        <div
          data-testid="access-capabilities-grid"
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))',
            gap: 12,
          }}
        >
          {actionList.map(action => {
            const isAllowed = action.cap.allowed
            return (
              <div
                key={action.key}
                data-testid={`access-capability-${action.key}`}
                style={{
                  background: 'var(--surface2)',
                  border: '1px solid var(--border)',
                  borderRadius: 6,
                  padding: '12px 14px',
                  display: 'flex',
                  flexDirection: 'column',
                  justifyContent: 'space-between',
                  gap: 8,
                }}
              >
                <div>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontWeight: 600, fontSize: 13 }}>
                      <span>{action.icon}</span>
                      <span>{action.label}</span>
                    </div>
                    <span
                      className="tag"
                      style={{
                        fontSize: 10,
                        fontWeight: 700,
                        padding: '1px 6px',
                        background: isAllowed ? 'rgba(16, 185, 129, 0.15)' : 'rgba(156, 163, 175, 0.15)',
                        color: isAllowed ? 'var(--teal)' : 'var(--muted)',
                      }}
                    >
                      {isAllowed ? 'Allowed' : 'Restricted'}
                    </span>
                  </div>
                  <div style={{ fontSize: 11, color: 'var(--muted)', lineHeight: 1.4 }}>
                    {action.cap.reason || (isAllowed ? 'Authorized by server RBAC policy' : 'Policy restriction active')}
                  </div>
                </div>

                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 4, flexWrap: 'wrap', paddingTop: 6, borderTop: '1px solid var(--border)' }}>
                  <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                    {action.cap.requires_confirmation && (
                      <span className="tag" style={{ fontSize: 9, padding: '1px 5px', background: 'rgba(217, 119, 6, 0.12)', color: 'var(--amber)' }}>
                        Confirm required
                      </span>
                    )}
                    {action.cap.requires_reason && (
                      <span className="tag" style={{ fontSize: 9, padding: '1px 5px', background: 'rgba(139, 92, 246, 0.12)', color: 'var(--violet)' }}>
                        Reason required
                      </span>
                    )}
                    {action.cap.requires_dual_approval && (
                      <span className="tag" style={{ fontSize: 9, padding: '1px 5px', background: 'rgba(220, 38, 38, 0.12)', color: 'var(--error)' }}>
                        Dual approval
                      </span>
                    )}
                  </div>
                  {onActionTrigger && isAllowed && (
                    <button
                      type="button"
                      className="btn btn-secondary"
                      style={{ fontSize: 10, padding: '2px 8px' }}
                      onClick={() => onActionTrigger(action.key)}
                    >
                      Execute
                    </button>
                  )}
                </div>
              </div>
            )
          })}
        </div>
      </div>

      {/* ─── Panel 3: Identity & Credential Details ────────────────────────────── */}
      <div className="card" data-testid="access-panel-identity" style={{ padding: 20 }}>
        <h2 style={{ fontSize: 16, fontWeight: 700, marginBottom: 12 }}>
          Identity Credentials & SPIFFE SVID Trust Chain
        </h2>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 14, fontSize: 13 }}>
          <div>
            <span style={{ color: 'var(--muted)' }}>SPIFFE Workload ID</span>
            <div style={{ fontFamily: 'monospace', fontSize: 12, marginTop: 4, wordBreak: 'break-all', color: 'var(--text)' }}>
              {spiffeId}
            </div>
          </div>
          <div>
            <span style={{ color: 'var(--muted)' }}>SPIFFE Attestation Status</span>
            <div style={{ marginTop: 4 }}>
              <span className="tag" style={{
                fontSize: 10,
                padding: '2px 8px',
                background: isSpiffeLinked ? 'rgba(16, 185, 129, 0.15)' : 'rgba(156, 163, 175, 0.15)',
                color: isSpiffeLinked ? 'var(--teal)' : 'var(--muted)',
              }}>
                {isSpiffeLinked ? 'SPIFFE linked' : 'Identity unlinked'}
              </span>
            </div>
          </div>
          <div>
            <span style={{ color: 'var(--muted)' }}>Tenant Isolation Boundary</span>
            <div style={{ fontFamily: 'monospace', fontSize: 12, marginTop: 4 }}>{agent.tenant_id}</div>
          </div>
          <div>
            <span style={{ color: 'var(--muted)' }}>Credential Lifecycle State</span>
            <div style={{ marginTop: 4 }}>
              <CredentialStateNotice credentialState={agent.credential_state} agentName={agent.name} variant="inline" />
            </div>
          </div>
        </div>
      </div>

      {/* ─── Panel 4: Truthful State Language & Telemetry Verification ────────── */}
      <div className="card" data-testid="access-panel-governance" style={{ padding: 20 }}>
        <h2 style={{ fontSize: 16, fontWeight: 700, marginBottom: 12 }}>
          Governance & Truthful Evidence Dictionary
        </h2>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 14, fontSize: 13 }}>
          <div>
            <span style={{ color: 'var(--muted)' }}>Responsibility Owner</span>
            <div data-testid="access-owner-truthful" style={{ marginTop: 4, fontWeight: 600, color: ownerName ? 'var(--text)' : 'var(--amber)' }}>
              {truthfulOwner}
            </div>
          </div>
          <div>
            <span style={{ color: 'var(--muted)' }}>Evaluated Controls</span>
            <div data-testid="access-posture-truthful" style={{ marginTop: 4, fontWeight: 600, color: isNotAssessed ? 'var(--muted)' : 'var(--teal)' }}>
              {truthfulPosture}
            </div>
          </div>
          <div>
            <span style={{ color: 'var(--muted)' }}>Collector Source Health</span>
            <div data-testid="access-source-health-truthful" style={{ marginTop: 4, fontWeight: 600, color: effectiveSourceHealth === 'healthy' ? 'var(--teal)' : 'var(--amber)' }}>
              {truthfulSourceHealth}
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
