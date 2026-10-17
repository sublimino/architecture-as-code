import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { useNavigate, useSearchParams, Link } from 'react-router-dom'
import AgentDeepLink from '../components/AgentDeepLink'
import DiscoveredWorkloadDrawer from '../components/DiscoveredWorkloadDrawer'
import ClaimModal from '../components/agents/ClaimModal'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { isDemoMode } from '../api/demoMode'
import type {
  DiscoveryWorkload,
  DiscoverySource,
  DiscoveryLifecycleState,
  ControlRecommendations,
  NHIScan,
  AgentResponse,
} from '../types/api'
import { colors } from '../styles/tokens'
import StatusBadge, { KernelStateBadge, hasKernelSplitBrain } from '../components/StatusBadge'
import EmptyState from '../components/EmptyState'
import LoadingState from '../components/LoadingState'
import DataTable, { type Column } from '../components/DataTable'
import {
  DataTableToolbar,
  ToolbarSearch,
  ToolbarFacet,
  ToolbarSelect,
  ToolbarClear,
  ToolbarCount,
  type ToolbarOption,
} from '../components/DataTableToolbar'
import { findMatchingAgent } from '../data/agentMatching'
import { hasGitOpsMetadata } from '../data/workloadFilters'
import ButtonWait from '../components/ButtonWait'
import SyncLogsModal from '../components/connectors/SyncLogsModal'
import SyncStatusPill, { type SyncTone } from '../components/connectors/SyncStatusPill'
import {
  connectorsApi,
  claimRemoteAgent,
  connectorErrorMessage,
  getDiscoverySourceSyncState,
  isRemoteEnvironmentProvider,
  type DiscoverySourceSyncState,
} from '../api/connectorsClient'
import type { TenantConnector } from '../types/connectors'
import { pollIntervalLabel } from '../hooks/useConnectorStream'

const POLL_MS = 15 * 60 * 1000
const PAGE_SIZE = 50

// Helpers (Zero em-dashes allowed)

function fmtDate(iso: string | null | undefined): string {
  if (!iso) return 'None'
  return new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })
}

function fmtRelative(iso: string | null | undefined): string {
  if (!iso) return 'None'
  const diff = Date.now() - new Date(iso).getTime()
  const days = Math.floor(diff / 86400000)
  if (days === 0) return 'Today'
  if (days === 1) return 'Yesterday'
  if (days < 30) return `${days}d ago`
  return fmtDate(iso)
}

// Control Recommendations Popover & Badges

interface ControlBadgeProps {
  category: 'config' | 'content' | 'supply_chain' | 'eu_ai_act'
  label: string
  status?: 'pass' | 'recommended' | 'warning' | 'not_applicable'
  ruleRequirement: string
}

function ControlBadge({ category, label, status = 'recommended', ruleRequirement }: ControlBadgeProps) {
  const [showTooltip, setShowTooltip] = useState(false)

  const statusStyles: Record<string, { bg: string; border: string; color: string; text: string }> = {
    pass: {
      bg: 'rgba(20, 184, 166, 0.12)',
      border: 'rgba(20, 184, 166, 0.35)',
      color: colors.tealLoom,
      text: 'Pass',
    },
    recommended: {
      bg: 'rgba(245, 158, 11, 0.12)',
      border: 'rgba(245, 158, 11, 0.35)',
      color: colors.amber,
      text: 'Review',
    },
    warning: {
      bg: 'rgba(239, 68, 68, 0.12)',
      border: 'rgba(239, 68, 68, 0.35)',
      color: colors.red,
      text: 'Action',
    },
    not_applicable: {
      bg: 'var(--surface2)',
      border: 'var(--border-subtle)',
      color: 'var(--muted)',
      text: 'N/A',
    },
  }


  const s = statusStyles[status] || statusStyles.recommended

  return (
    <div
      style={{ position: 'relative', display: 'inline-block' }}
      onMouseEnter={() => setShowTooltip(true)}
      onMouseLeave={() => setShowTooltip(false)}
    >
      <button
        type="button"
        data-testid={`control-rec-badge-${category}`}
        onClick={() => setShowTooltip(true)}
        onFocus={() => setShowTooltip(true)}
        onBlur={() => setShowTooltip(false)}

        style={{
          display: 'inline-flex',
          alignItems: 'center',
          gap: 4,
          padding: '2px 6px',
          borderRadius: 4,
          fontSize: 10.5,
          fontWeight: 600,
          fontFamily: 'inherit',
          background: s.bg,
          border: `1px solid ${s.border}`,
          color: s.color,
          cursor: 'pointer',
          textTransform: 'uppercase',
          letterSpacing: '0.02em',
        }}
      >
        <span>{label}</span>
        <span style={{ fontSize: 9, opacity: 0.85 }}>({s.text})</span>
      </button>

      {showTooltip && (
        <div
          role="tooltip"
          style={{
            position: 'absolute',
            bottom: '100%',
            left: '50%',
            transform: 'translateX(-50%)',
            marginBottom: 6,
            background: 'var(--surface)',
            border: '1px solid var(--border)',
            boxShadow: '0 8px 24px rgba(0,0,0,0.5)',
            borderRadius: 6,
            padding: '8px 12px',
            fontSize: 11.5,
            color: 'var(--text)',
            width: 220,
            zIndex: 120,
            pointerEvents: 'none',
            textAlign: 'left',
          }}
        >
          <div style={{ fontWeight: 600, color: s.color, marginBottom: 3 }}>
            {label} Control: {s.text}
          </div>
          <div style={{ color: 'var(--muted)', lineHeight: 1.35 }}>{ruleRequirement}</div>
        </div>
      )}
    </div>
  )
}

function ControlRecommendationsCell({ recommendations }: { recommendations?: ControlRecommendations }) {
  const recs = recommendations || {}

  return (
    <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap', alignItems: 'center' }}>
      <ControlBadge
        category="config"
        label="CFG"
        status={recs.config}
        ruleRequirement="Runtime and least-privilege credential confinement policies."
      />
      <ControlBadge
        category="content"
        label="CNT"
        status={recs.content}
        ruleRequirement="Prompt injection boundary defense and DLP output inspection rules."
      />
      <ControlBadge
        category="supply_chain"
        label="SC"
        status={recs.supply_chain}
        ruleRequirement="Cosign and Witness cryptographically verified SBOM provenance."
      />
      <ControlBadge
        category="eu_ai_act"
        label="EU"
        status={recs.eu_ai_act}
        ruleRequirement="EU AI Act Article 9 risk governance and Article 14 oversight."
      />
    </div>
  )
}

// Auto-Claim Namespace Confirmation Modal

interface AutoClaimModalProps {
  isOpen: boolean
  namespaces: string[]
  onClose: () => void
  onConfirm: (namespace: string) => Promise<void>
}

function AutoClaimModal({ isOpen, namespaces, onClose, onConfirm }: AutoClaimModalProps) {
  const [selectedNs, setSelectedNs] = useState(namespaces[0] || 'fe-signalloom-agents')
  const [isSubmitting, setIsSubmitting] = useState(false)
  const modalRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (namespaces.length > 0 && !namespaces.includes(selectedNs)) {
      setSelectedNs(namespaces[0])
    }
  }, [namespaces, selectedNs])

  if (!isOpen) return null

  async function handleConfirm() {
    setIsSubmitting(true)
    try {
      await onConfirm(selectedNs)
      onClose()
    } finally {
      setIsSubmitting(false)
    }
  }

  return (
    <div
      style={{
        position: 'fixed',
        inset: 0,
        backgroundColor: 'rgba(0, 0, 0, 0.65)',
        backdropFilter: 'blur(3px)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 1000,
        padding: 20,
      }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div
        ref={modalRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="autoclaim-modal-title"
        style={{
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 10,
          boxShadow: '0 16px 48px rgba(0, 0, 0, 0.6)',
          width: '100%',
          maxWidth: 480,
          padding: 24,
          fontFamily: 'inherit',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 16 }}>
          <h2 id="autoclaim-modal-title" style={{ fontSize: 16, fontWeight: 700, margin: 0 }}>
            Auto-Claim Discovered Namespace
          </h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close modal"
            style={{
              background: 'none',
              border: 'none',
              fontSize: 18,
              cursor: 'pointer',
              color: 'var(--muted)',
            }}
          >
            ✕
          </button>
        </div>

        <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 18, lineHeight: 1.45 }}>
          Auto-claiming transitions discovered workloads in the selected namespace to <strong>Governed</strong> status.
          Signal Loom will mint cryptographic SPIFFE SVIDs, allocate default token budgets, and apply Landlock LSM containment.
        </p>

        <div style={{ marginBottom: 20 }}>
          <label style={{ display: 'block', fontSize: 12, fontWeight: 600, marginBottom: 6 }}>
            Target Namespace
          </label>
          <select
            data-testid="autoclaim-modal-namespace-select"
            value={selectedNs}
            onChange={(e) => setSelectedNs(e.target.value)}
            style={{
              width: '100%',
              padding: '8px 12px',
              fontSize: 13,
              borderRadius: 6,
              background: 'var(--surface2)',
              border: '1px solid var(--border)',
              color: 'var(--text)',
              fontFamily: 'inherit',
            }}
          >
            {namespaces.length === 0 ? (
              <option value="fe-signalloom-agents">fe-signalloom-agents</option>
            ) : (
              namespaces.map((ns) => (
                <option key={ns} value={ns}>
                  {ns}
                </option>
              ))
            )}
          </select>
        </div>

        <div style={{
          background: 'rgba(6, 182, 212, 0.08)',
          border: '1px solid rgba(6, 182, 212, 0.25)',
          borderRadius: 6,
          padding: '10px 14px',
          fontSize: 12,
          color: colors.cyanLoom,
          marginBottom: 20,
        }}>
          Workload identities will be attested via cluster SPIRE server and bound to the eBPF network sentinel.
        </div>

        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 10 }}>
          <button
            type="button"
            className="btn btn-secondary"
            data-testid="autoclaim-modal-cancel-btn"
            onClick={onClose}
            disabled={isSubmitting}
            style={{ fontSize: 12, padding: '7px 14px' }}
          >
            Cancel
          </button>
          <button
            type="button"
            className="btn btn-primary"
            data-testid="autoclaim-modal-confirm-btn"
            onClick={handleConfirm}
            disabled={isSubmitting}
            style={{ fontSize: 12, padding: '7px 16px', background: colors.cyanLoom, borderColor: colors.cyanLoom }}
          >
            {isSubmitting ? 'Claiming Workloads...' : 'Claim Namespace'}
          </button>
        </div>
      </div>
    </div>
  )
}

// Attention Panel

interface AlertItem {
  id: string
  label: string
  count: number
  severity: 'warning' | 'critical'
  filterKey: string
}

function AttentionPanel({ alerts, onAlert }: { alerts: AlertItem[]; onAlert: (filterKey: string) => void }) {
  if (alerts.length === 0) return null
  return (
    <div style={{
      background: 'rgba(220,38,38,0.07)',
      border: '1px solid rgba(220,38,38,0.25)',
      borderRadius: 8,
      padding: '14px 18px',
      marginBottom: 20,
      display: 'flex',
      flexDirection: 'column',
      gap: 10,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 2 }}>
        <button
          type="button"
          onClick={() => onAlert('attention_all')}
          data-testid="attention-required-header-btn"
          style={{
            background: 'none',
            border: 'none',
            padding: 0,
            cursor: 'pointer',
            display: 'inline-flex',
            alignItems: 'center',
            gap: 8,
            fontFamily: 'inherit',
          }}
        >
          <span style={{ fontSize: 13, fontWeight: 700, color: colors.red }}>Attention Required</span>
          <span style={{
            background: colors.red, color: 'var(--on-accent)', borderRadius: 99,
            fontSize: 10, fontWeight: 700, padding: '1px 7px',
          }}>{alerts.length}</span>
        </button>
      </div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
        {alerts.map((a) => (
          <button
            key={a.id}
            data-testid={`attention-alert-${a.id}`}
            onClick={() => onAlert(a.filterKey)}
            style={{
              display: 'flex', alignItems: 'center', gap: 6,
              background: a.severity === 'critical'
                ? 'rgba(220,38,38,0.12)'
                : 'rgba(215,119,6,0.12)',
              border: `1px solid ${a.severity === 'critical' ? 'rgba(220,38,38,0.3)' : 'rgba(215,119,6,0.3)'}`,
              borderRadius: 6, padding: '5px 12px',
              color: a.severity === 'critical' ? colors.red : colors.amber,
              fontSize: 12, fontWeight: 500, cursor: 'pointer',
              fontFamily: 'inherit', transition: 'opacity 0.15s',
            }}
          >
            <span style={{
              background: a.severity === 'critical' ? colors.red : colors.amber,
              color: 'var(--on-accent)', borderRadius: 99, fontSize: 10,
              fontWeight: 700, padding: '0px 6px', minWidth: 20, textAlign: 'center',
            }}>{a.count}</span>
            {a.label}
          </button>
        ))}
      </div>
    </div>
  )
}

// Connect CTA

function ConnectDirectoryCta() {
  const navigate = useNavigate()
  return (
    <div className="card" style={{
      marginBottom: 20, padding: '16px 20px', display: 'flex',
      alignItems: 'center', justifyContent: 'space-between', gap: 16, flexWrap: 'wrap',
    }}>
      <div>
        <div style={{ fontSize: 14, fontWeight: 600, marginBottom: 3 }}>Connect Discovery Sources</div>
        <div style={{ fontSize: 12, color: 'var(--muted)' }}>
          Link Entra ID, Okta, remote Kubernetes clusters via AFM, or Cloud Run/n8n services to discover shadow AI workloads.
        </div>
      </div>
      <button
        className="btn btn-primary"
        style={{ fontSize: 12, padding: '7px 16px', whiteSpace: 'nowrap' }}
        onClick={() => navigate('/onboarding')}
      >
        Connect Directory / Clusters
      </button>
    </div>
  )
}

// Scan status

function ScanStatusCard({ scan, totalDiscovered }: { scan: NHIScan | null; totalDiscovered: number }) {
  if (!scan) {
    return (
      <div className="card" style={{ marginBottom: 14, padding: '14px 20px' }}>
        <span style={{ color: 'var(--muted)', fontSize: 13 }}>
          Continuous connector monitoring active. Total discovered workloads across sources: {totalDiscovered}
        </span>
      </div>
    )
  }

  const duration = scan.completed_at && scan.started_at
    ? Math.round((new Date(scan.completed_at).getTime() - new Date(scan.started_at).getTime()) / 1000)
    : null

  return (
    <div className="card" style={{ marginBottom: 14, padding: '14px 20px' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 20, flexWrap: 'wrap' }}>
        <div>
          <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 3 }}>Last Discovery Scan</div>
          <div style={{ fontSize: 13, fontWeight: 500 }}>{fmtRelative(scan.started_at)}</div>
        </div>
        <div>
          <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 3 }}>Active Source</div>
          <div style={{ fontSize: 13 }}>{scan.scan_source === 'ad_entra' ? 'Entra ID / AD' : scan.scan_source}</div>
        </div>
        {duration !== null && (
          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 3 }}>Duration</div>
            <div style={{ fontSize: 13 }}>{duration}s</div>
          </div>
        )}
        <div>
          <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 3 }}>Discovered Workloads</div>
          <div style={{ fontSize: 13, fontWeight: 600, color: colors.cyanLoom }}>{totalDiscovered}</div>
        </div>
        <StatusBadge status={scan.status} />
      </div>
    </div>
  )
}

// Discovery sources: the connected connectors that feed this page

/** One connected connector, with whatever the backend sync engine reports for it. */
interface DiscoverySourceView {
  providerId: string
  name: string
  connector: TenantConnector
  /** Null where the engine reports nothing (not a remote-agent provider, or mock mode). */
  syncState: DiscoverySourceSyncState | null
  /** Set when reading the sync state itself failed; never folded into "no state". */
  syncStateError: string | null
}

// Remote agents synced from an AI provider arrive as external_services rows.
// The backend tags them with metadata.provider_id; source_label is the
// fallback for rows written before that tag existed.
const PROVIDER_BY_SOURCE_LABEL: Record<string, string> = {
  'Anthropic Claude': 'claude',
  OpenAI: 'openai',
}

function rowProviderId(w: DiscoveryWorkload): string | null {
  const tagged = w.metadata?.provider_id
  if (typeof tagged === 'string' && tagged) return tagged
  if (w.source !== 'external_services') return null
  return PROVIDER_BY_SOURCE_LABEL[w.source_label] ?? null
}

function isProviderHosted(w: DiscoveryWorkload): boolean {
  return w.source === 'external_services' && rowProviderId(w) !== null
}

// POST /discovery/claim takes {agent_id, namespace, spiffe_id} and rejects a
// namespace that does not exist for the tenant; it has no field for a
// provider-hosted agent. Claiming one would mean inventing a namespace.
function claimUnavailableReason(w: DiscoveryWorkload): string {
  return `Claim needs a Kubernetes namespace and pod. This agent runs on ${w.source_label}, and the claim API has no field for a provider-hosted agent yet.`
}

// The registry agent a provider-hosted row was claimed as (backend
// metadata.claimed_agent_id, migration 072), or null.
function remoteClaimedAgentId(w: DiscoveryWorkload): string | null {
  const id = w.metadata?.claimed_agent_id
  return typeof id === 'string' && id ? id : null
}

const DISMISS_UNAVAILABLE_REASON =
  'Ignore applies to directory identities (POST /nhi/discovered/{id}/dismiss); provider-hosted agents are not in that store.'

function fmtAgo(iso: string): string {
  const mins = Math.floor((Date.now() - new Date(iso).getTime()) / 60000)
  if (mins < 1) return 'just now'
  if (mins < 60) return `${mins}m ago`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `${hours}h ago`
  return `${Math.floor(hours / 24)}d ago`
}

// The poll interval the engine scheduled (next_poll_at - last_poll_at), in
// seconds below 90 s so a 30 s interval is not rounded to "1 min".
// Backend modes (remote_agent_sync): poll | poll+stream | backoff.
function syncModeLabel(s: DiscoverySourceSyncState | null): string | null {
  if (!s) return null
  if (s.mode === 'stream' || s.mode === 'webhook') return 'Live'
  const every = pollIntervalLabel(s)
  if (s.mode === 'poll') return every ? `Polling every ${every}` : 'Polling'
  if (s.mode === 'poll+stream') return every ? `Live sessions + polling every ${every}` : 'Live sessions + polling'
  if (s.mode === 'backoff') {
    const n = s.consecutive_failures
    return typeof n === 'number' && n > 0
      ? `Backing off after errors (${n} consecutive failure${n === 1 ? '' : 's'})`
      : 'Backing off after errors'
  }
  return s.mode
}

function lastScanLabel(src: DiscoverySourceView): string {
  const at = src.connector.last_scan_at ?? src.syncState?.last_success_at ?? null
  return at ? `Last scanned ${fmtAgo(at)}` : 'Never scanned'
}

function sourceError(src: DiscoverySourceView): string | null {
  return src.connector.last_scan_error ?? src.syncState?.last_error ?? src.syncStateError
}

// Design-system audit rules 4/12: a sync badge with its own radius/padding
// (previously 4px/2px 7px against .tag's 3px/2px 8px) is one more pill
// geometry in a file that already has several. The shared SyncStatusPill
// gives this the same .tag shape as every other sync-status pill in the
// app; the live/poll/other tone mapping below is unchanged from before.
function SyncBadge({ providerId, state }: { providerId: string; state: DiscoverySourceSyncState | null }) {
  const label = syncModeLabel(state)
  if (!label) return null
  const mode = state?.mode
  const tone: SyncTone = label === 'Live' || mode === 'poll+stream' ? 'teal' : mode === 'poll' ? 'cyan' : 'muted'
  return (
    <SyncStatusPill
      testId={`discovery-source-${providerId}-sync`}
      tone={tone}
      label={label}
      style={{ whiteSpace: 'nowrap' }}
    />
  )
}

interface DiscoverySourcesStripProps {
  sources: DiscoverySourceView[]
  loadError: string | null
  scanning: Record<string, boolean>
  rescanErrors: Record<string, string>
  onRescan: (providerId: string) => void
  onLogs: (providerId: string) => void
}

function DiscoverySourcesStrip({ sources, loadError, scanning, rescanErrors, onRescan, onLogs }: DiscoverySourcesStripProps) {
  if (loadError) {
    return (
      <div className="card" role="alert" data-testid="discovery-sources-error" style={{ marginBottom: 14, padding: '12px 18px', fontSize: 12.5, color: 'var(--error)' }}>
        Could not load connected sources: {loadError}
      </div>
    )
  }
  if (sources.length === 0) return null
  return (
    <section
      aria-label="Discovery sources"
      data-testid="discovery-sources"
      style={{ display: 'flex', flexWrap: 'wrap', gap: 10, marginBottom: 14 }}
    >
      {sources.map((src) => {
        const pid = src.providerId
        const busy = Boolean(scanning[pid])
        const err = sourceError(src)
        return (
          <div
            key={src.connector.connector_id}
            className="card"
            data-testid={`discovery-source-${pid}`}
            style={{ padding: '10px 14px', display: 'flex', flexDirection: 'column', gap: 6, minWidth: 260, flex: '1 1 260px' }}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <span style={{ fontSize: 13, fontWeight: 600 }}>{src.name}</span>
              <SyncBadge providerId={pid} state={src.syncState} />
            </div>
            <div role="status" data-testid={`discovery-source-${pid}-last-scan`} style={{ fontSize: 11.5, color: 'var(--muted)' }}>
              {lastScanLabel(src)}
            </div>
            {err && (
              <div data-testid={`discovery-source-${pid}-error`} style={{ fontSize: 11.5, color: 'var(--error)' }}>
                {err}
              </div>
            )}
            <div style={{ display: 'flex', gap: 6, marginTop: 2 }}>
              <button
                type="button"
                className="btn btn-secondary"
                data-testid={`discovery-source-${pid}-rescan`}
                disabled={busy}
                aria-busy={busy}
                onClick={() => onRescan(pid)}
                style={{ fontSize: 11.5, padding: '4px 10px', minWidth: 96 }}
              >
                {busy ? <ButtonWait label={`Re-scanning ${src.name}`} testId={`discovery-source-${pid}-rescan-wait`} /> : 'Re-scan'}
              </button>
              <button
                type="button"
                className="btn btn-secondary"
                data-testid={`discovery-source-${pid}-logs`}
                onClick={() => onLogs(pid)}
                style={{ fontSize: 11.5, padding: '4px 10px' }}
              >
                Logs
              </button>
            </div>
            {rescanErrors[pid] && (
              <div role="alert" data-testid={`discovery-source-${pid}-rescan-error`} style={{ fontSize: 11.5, color: 'var(--error)' }}>
                Re-scan failed: {rescanErrors[pid]}
              </div>
            )}
          </div>
        )
      })}
    </section>
  )
}

/** Shown instead of a filter-miss message when the page genuinely has no rows. */
function DiscoveryEmptyState({ sources, sourcesError }: { sources: DiscoverySourceView[]; sourcesError: string | null }) {
  if (sources.length === 0 && !sourcesError) {
    return (
      <div className="card" data-testid="discovery-empty-no-sources" style={{ padding: '18px 22px' }}>
        <div style={{ fontSize: 14, fontWeight: 600, marginBottom: 4 }}>No sources connected</div>
        <div style={{ fontSize: 12.5, color: 'var(--muted)' }}>
          Discovery lists what connected sources report. Connect an AI provider, identity directory or cluster in{' '}
          <Link to="/settings?tab=connectors">Settings › Connectors</Link>.
        </div>
      </div>
    )
  }
  return (
    <div className="card" data-testid="discovery-empty-no-discoveries" style={{ padding: '18px 22px' }}>
      <div style={{ fontSize: 14, fontWeight: 600, marginBottom: 4 }}>Nothing discovered yet</div>
      <div style={{ fontSize: 12.5, color: 'var(--muted)', marginBottom: 8 }}>
        {sources.length === 0
          ? 'The connected sources could not be read, so there is no scan history to show.'
          : 'The connected sources have reported no workloads or agents. Their latest scans:'}
      </div>
      <ul style={{ margin: 0, paddingLeft: 18, fontSize: 12.5 }}>
        {sources.map((src) => {
          const err = sourceError(src)
          return (
            <li key={src.connector.connector_id}>
              <strong>{src.name}</strong>: {lastScanLabel(src)}
              {err && <span style={{ color: 'var(--error)' }}> ({err})</span>}
            </li>
          )
        })}
      </ul>
    </div>
  )
}

// Workload Row Component

interface WorkloadRowProps {
  workload: DiscoveryWorkload
  matchedAgent?: AgentResponse
  onEnroll: (id: string) => void
  onDismiss: (id: string) => void
  onOpen: (id: string) => void
  selected?: boolean
  /** Claim of a provider-hosted agent (live mode only). */
  onClaimRemote?: (w: DiscoveryWorkload) => void
  remoteClaim?: RemoteClaimState
}

interface RemoteClaimState {
  busy: boolean
  error: string | null
}

function WorkloadRow({
  workload, matchedAgent, onEnroll, onDismiss, onOpen, selected = false, onClaimRemote, remoteClaim,
}: WorkloadRowProps) {
  const isIgnored = workload.status === 'ignored'
  const isGoverned = workload.status === 'governed'
  const isRevoked = workload.status === 'revoked'
  const providerHosted = isProviderHosted(workload)
  // Live only: demo rows are fixtures, and a demo claim would invent a registry agent.
  const remoteClaimable = providerHosted && Boolean(onClaimRemote) && !isDemoMode()
  const claimedAgentId = providerHosted ? remoteClaimedAgentId(workload) : null

  const rowStyle: React.CSSProperties = {
    borderBottom: '1px solid var(--border)',
    opacity: isIgnored ? 0.65 : 1,
    background: selected ? 'var(--cyan-focus)' : undefined,
    boxShadow: selected ? 'inset 3px 0 0 var(--cyan)' : undefined,
  }
  const td: React.CSSProperties = { ...DataTable.td, padding: '10px 14px', fontSize: 13 }

  return (
    <tr style={rowStyle} data-testid={`discovery-row-${workload.id}`} aria-selected={selected}>
      {/* Workload Name & Info */}
      <td style={td}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <button
            onClick={() => onOpen(workload.id)}
            data-testid={`discovery-workload-name-${workload.id}`}
            style={{
              background: 'none',
              border: 'none',
              padding: 0,
              fontFamily: 'inherit',
              fontWeight: 600,
              fontSize: 13,
              color: 'var(--text)',
              cursor: 'pointer',
              textAlign: 'left',
            }}
            onMouseEnter={(e) => (e.currentTarget.style.textDecoration = 'underline')}
            onMouseLeave={(e) => (e.currentTarget.style.textDecoration = 'none')}
          >
            {workload.name}
          </button>
        </div>

        {matchedAgent && (
          <div style={{ marginTop: 4 }}>
            <AgentDeepLink
              target={matchedAgent.id}
              variant="badge"
              dataTestId={`discovery-agent-link-${workload.id}`}
              title={`View agent dossier for ${matchedAgent.name}`}
              showIcon={true}
            >
              <span>🤖 {matchedAgent.name}</span>
            </AgentDeepLink>
          </div>
        )}

        {workload.spiffe_id && (
          <div style={{ fontSize: 11, color: colors.cyanLoom, marginTop: 3, fontFamily: 'monospace' }}>
            {workload.spiffe_id}
          </div>
        )}

        {workload.model && (
          <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
            Model: {workload.model}
          </div>
        )}
      </td>

      {/* Connector Source */}
      <td style={td}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
          <span style={{ fontWeight: 500 }}>{workload.source_label}</span>
          <span style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase' }}>
            {workload.source.replace('_', ' ')}
          </span>
        </div>
      </td>

      {/* Namespace / Region */}
      <td style={td}>
        {workload.namespace ? (
          <span style={{ fontFamily: 'monospace', fontSize: 12 }}>
            {workload.namespace}
          </span>
        ) : (
          <span style={{ color: 'var(--muted)', fontSize: 12 }}>None</span>
        )}
      </td>

      {/* Discovery Status */}
      <td style={td}>
        <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', alignItems: 'center' }}>
          <StatusBadge status={workload.status} variant="lifecycle" />
          <KernelStateBadge view={workload} testId={`kernel-state-badge-${workload.id}`} />
        </div>
      </td>


      {/* Owner */}
      <td style={td}>
        {workload.owner ? (
          <span style={{ fontSize: 12 }}>{workload.owner}</span>
        ) : (
          <span style={{ color: colors.red, fontSize: 12, fontWeight: 600 }}>Unowned</span>
        )}
      </td>

      {/* Control Recommendations */}
      <td style={td}>
        <ControlRecommendationsCell recommendations={workload.recommendations} />
      </td>

      {/* Actions */}
      <td style={{ ...td, textAlign: 'right' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 6 }}>
          {claimedAgentId ? (
            <Link
              to={`/agents?selected=${encodeURIComponent(claimedAgentId)}`}
              data-testid={`remote-claimed-link-${workload.id}`}
              title="Open the registry agent this provider agent was claimed as"
              style={{
                fontSize: 11,
                fontWeight: 600,
                padding: '3px 8px',
                borderRadius: 4,
                // Design-system audit rule 1: colour comes only from tokens.
                // The raw rgba(20, 184, 166, 0.15) literal never switched
                // with the theme; var(--teal-bg) is the themed equivalent.
                background: 'var(--teal-bg)',
                color: colors.tealLoom,
                textDecoration: 'none',
              }}
            >
              Claimed →
            </Link>
          ) : remoteClaimable && !isGoverned ? (
            <button
              type="button"
              className="btn btn-primary"
              data-testid={`claim-remote-btn-${workload.id}`}
              style={{ fontSize: 11, padding: '4px 10px', background: colors.cyanLoom, borderColor: colors.cyanLoom }}
              onClick={() => onClaimRemote?.(workload)}
              disabled={remoteClaim?.busy}
              title={`Claim this ${workload.source_label} agent into your tenant's agent registry`}
            >
              {remoteClaim?.busy ? (
                <ButtonWait label={`Claiming ${workload.name}`} testId={`claim-remote-wait-${workload.id}`} />
              ) : (
                'Claim'
              )}
            </button>
          ) : isGoverned ? (
            // Same rule-1 fix as the "Claimed →" link above: a tokenised
            // background instead of the raw rgba(20, 184, 166, 0.15) literal.
            <span style={{
              fontSize: 11,
              fontWeight: 600,
              padding: '3px 8px',
              borderRadius: 4,
              background: 'var(--teal-bg)',
              color: colors.tealLoom,
            }}>
              Governed
            </span>
          ) : (
            <>
              <button
                type="button"
                className="btn btn-primary"
                data-testid={`enroll-workload-btn-${workload.id}`}
                style={{ fontSize: 11, padding: '4px 10px', background: colors.cyanLoom, borderColor: colors.cyanLoom }}
                onClick={() => onEnroll(workload.id)}
                disabled={providerHosted}
                aria-describedby={providerHosted ? `claim-unavailable-reason-${workload.id}` : undefined}
                title={providerHosted ? claimUnavailableReason(workload) : 'Claim and enroll this workload into Signal Loom governance'}
              >
                Claim / Enroll
              </button>
              {!isIgnored && (
                <button
                  type="button"
                  className="btn btn-secondary"
                  data-testid={`dismiss-workload-btn-${workload.id}`}
                  style={{ fontSize: 11, padding: '4px 8px', color: 'var(--muted)' }}
                  onClick={() => onDismiss(workload.id)}
                  disabled={providerHosted}
                  title={providerHosted ? DISMISS_UNAVAILABLE_REASON : 'Dismiss this discovery finding'}
                >
                  Ignore
                </button>
              )}
            </>
          )}
        </div>
        {remoteClaim?.error && (
          // Design-system audit rule 11: --error on a plain surface measures
          // 3.70:1 in dark, below the 4.5:1 AA floor for this text size. The
          // message goes on --text; colour is carried by the dot instead,
          // which only owes 3:1 as non-text UI (same pattern as
          // SyncStatusPill's amber/red dot).
          <div
            role="alert"
            data-testid={`claim-remote-error-${workload.id}`}
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'flex-end',
              gap: 4,
              fontSize: 10.5,
              color: 'var(--text)',
              marginTop: 4,
              maxWidth: 240,
              marginLeft: 'auto',
              textAlign: 'right',
            }}
          >
            <span aria-hidden="true" style={{ width: 6, height: 6, borderRadius: '50%', background: colors.red, flexShrink: 0 }} />
            {remoteClaim.error}
          </div>
        )}
        {providerHosted && !isGoverned && !remoteClaimable && !claimedAgentId && (
          <div
            id={`claim-unavailable-reason-${workload.id}`}
            data-testid={`claim-unavailable-reason-${workload.id}`}
            style={{ fontSize: 10.5, color: 'var(--muted)', marginTop: 4, maxWidth: 240, marginLeft: 'auto', textAlign: 'right' }}
          >
            {claimUnavailableReason(workload)}
          </div>
        )}
      </td>
    </tr>
  )
}

function workloadToClaimAgent(w: DiscoveryWorkload): AgentResponse {
  const meta = w.metadata || {}
  const podName = (meta.pod_name as string) || w.name
  const ns = w.namespace || (meta.namespace as string) || 'fe-signalloom-agents'
  const sa = (meta.service_account as string) || podName
  const framework = (meta.framework as string) || 'claude-code'
  const model = w.model || 'claude-3-5-sonnet'
  const spiffeId = w.spiffe_id || `spiffe://signalloom.svc.cluster.local/ns/${ns}/sa/${sa}`

  return {
    id: w.id,
    name: w.name,
    type: 'Discovered Workload',
    owner: w.owner || 'unassigned',
    tenant_id: w.tenant_id || (isDemoMode() ? 'tenant-demo' : 'default'),
    lifecycle_state: w.status === 'governed' ? 'governed' : 'discovered',
    last_transition_at: w.last_seen_at || new Date().toISOString(),
    last_transition_by: 'system',
    eu_ai_act_risk_class: 'minimal',
    // A DISCOVERED workload has not been assessed. That is the whole meaning
    // of "discovered": it was found running, nothing has evaluated it, and
    // claiming it into governance is what causes it to be evaluated.
    //
    // This used to assert 12 controls / 8 passing / 4 pending / score 0.67 for
    // every workload the claim modal was opened on -- the fourth copy of that
    // same fabricated summary, and the source of the "67%" that
    // CryptographyPage's own comment remarks on. The figures were identical
    // for every workload, which is the tell: a real assessment varies.
    //
    // Zero counts with a null score is the honest empty shape, and it is the
    // one the API itself sends for an unassessed agent (see
    // api/fakeData.ts:122). `posture_score` is already `number | null` in
    // types/api.ts, and views/Agents.tsx already branches on
    // `posture_score !== null` to render "no score" -- so the empty state this
    // needs was built and this call site simply never used it.
    compliance_summary: {
      total_controls: 0,
      passing: 0,
      failing: 0,
      pending: 0,
      posture_score: null,
    },
    runtime: {
      namespace: ns,
      pod_name: podName,
      service_account: sa,
      framework,
      model,
    },
    identity: {
      spiffe_id: spiffeId,
      spiffe_status: w.status === 'governed' ? 'linked' : 'unlinked',
      aliases: [],
    },
    created_at: w.last_seen_at || new Date().toISOString(),
    record_class: 'discovered',
  }
}

// Main Page Component

export default function DiscoveryPage() {
  const { getAccessTokenSilently } = useAuth0()
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()

  const [workloads, setWorkloads] = useState<DiscoveryWorkload[]>([])
  const [total, setTotal] = useState(0)
  const [latestScan, setLatestScan] = useState<NHIScan | null>(null)
  const [agents, setAgents] = useState<AgentResponse[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [feedbackToast, setFeedbackToast] = useState<string | null>(null)
  // Live mode only: a failed aggregate is an error, never an empty list.
  const [workloadsError, setWorkloadsError] = useState<string | null>(null)

  // Connected sources (connectors), their sync state, and per-source actions
  const [sources, setSources] = useState<DiscoverySourceView[]>([])
  const [sourcesError, setSourcesError] = useState<string | null>(null)
  const [sourcesLoaded, setSourcesLoaded] = useState(false)
  const [scanning, setScanning] = useState<Record<string, boolean>>({})
  const [rescanErrors, setRescanErrors] = useState<Record<string, string>>({})
  const [logsProviderId, setLogsProviderId] = useState<string | null>(null)

  // Provider deep link: ?provider=<id>&selected=<external_id>. The provider
  // narrows the list; `selected` must equal a row id exactly (no name or
  // suffix matching, unlike the older ?workload= link).
  const providerFilter = searchParams.get('provider')
  const selectedExternalId = searchParams.get('selected')

  // Discovered Workload Drawer & Claim Modal state
  const selectedWorkloadId =
    searchParams.get('workload') ||
    searchParams.get('agent') ||
    searchParams.get('selected') ||
    searchParams.get('sidebar')

  const selectedWorkload = useMemo(() => {
    if (providerFilter && selectedExternalId) {
      return (
        workloads.find(
          (w) => w.id === selectedExternalId && rowProviderId(w) === providerFilter,
        ) || null
      )
    }
    if (selectedWorkloadId) {
      return (
        workloads.find(
          (w) =>
            w.id === selectedWorkloadId ||
            w.name === selectedWorkloadId ||
            w.id.endsWith(`:${selectedWorkloadId}`),
        ) || null
      )
    }
    if (selectedExternalId) {
      return (
        workloads.find(
          (w) => w.id === selectedExternalId && (!providerFilter || rowProviderId(w) === providerFilter),
        ) || null
      )
    }
    return null
  }, [workloads, selectedWorkloadId, selectedExternalId, providerFilter])
  const [claimWorkload, setClaimWorkload] = useState<DiscoveryWorkload | null>(null)
  const [remoteClaims, setRemoteClaims] = useState<Record<string, RemoteClaimState>>({})

  const handleOpenWorkload = useCallback(
    (id: string) => {
      setSearchParams((prev) => {
        const next = new URLSearchParams(prev)
        next.delete('workload')
        next.delete('selected')
        next.delete('sidebar')
        next.set('agent', id)
        return next
      })
    },
    [setSearchParams],
  )

  const handleCloseDrawer = useCallback(() => {
    setSearchParams((prev) => {
      const next = new URLSearchParams(prev)
      next.delete('agent')
      next.delete('workload')
      next.delete('selected')
      next.delete('sidebar')
      return next
    })
  }, [setSearchParams])

  // Filters
  const [searchQuery, setSearchQuery] = useState('')
  const [sourceFilter, setSourceFilter] = useState('all')
  const [stateFilter, setStateFilter] = useState('all')
  const [namespaceFilter, setNamespaceFilter] = useState('all')
  const [attentionFilter, setAttentionFilter] = useState<'all' | 'unowned' | 'attention_all'>('all')
  const [gitopsFilter, setGitopsFilter] = useState(false)

  // Auto-claim Modal
  const [isAutoClaimOpen, setIsAutoClaimOpen] = useState(false)

  const loadSources = useCallback(async (token: string) => {
    try {
      const [connectors, providers] = await Promise.all([
        connectorsApi.listConnectors(token),
        // Names only: a failure here falls back to the provider id.
        connectorsApi.listProviders(token).catch(() => []),
      ])
      const providerNames = new Map(providers.map((p) => [p.provider_id, p.display_name]))
      const connected = connectors.filter((c) => c.status === 'connected')
      const views = await Promise.all(
        connected.map(async (c): Promise<DiscoverySourceView> => {
          const base = {
            providerId: c.provider_id,
            name: c.display_name || providerNames.get(c.provider_id) || c.provider_id,
            connector: c,
          }
          if (!isRemoteEnvironmentProvider(c.provider_id)) {
            return { ...base, syncState: null, syncStateError: null }
          }
          try {
            const snap = await getDiscoverySourceSyncState(token, c.provider_id)
            return { ...base, syncState: snap?.sync_state ?? null, syncStateError: null }
          } catch (err) {
            return { ...base, syncState: null, syncStateError: connectorErrorMessage(err, 'Could not read sync state.') }
          }
        }),
      )
      setSources(views)
      setSourcesError(null)
    } catch (err) {
      setSources([])
      setSourcesError(connectorErrorMessage(err, 'The connectors API request failed.'))
    } finally {
      setSourcesLoaded(true)
    }
  }, [])

  const loadData = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      let liveWorkloadsError: string | null = null
      const [workloadsRes, scansData, agentsData] = await Promise.all([
        api.discovery.workloads(token, { limit: 100 }).catch(async (err) => {
          // Fallback to demo fixture endpoint if live aggregate fails, but ONLY in demo mode
          if (isDemoMode()) {
            const nhiData = await api.nhi.discovered(token, 1, 100).catch(() => ({ accounts: [] }))
            const mapped: DiscoveryWorkload[] = nhiData.accounts.map((a) => ({
              id: a.id,
              name: a.account_name,
              source: 'idp',
              source_label: a.directory_source.includes('entra') ? 'Entra ID' : 'Okta',
              namespace: `identity-${a.directory_source.toLowerCase()}`,
              status: a.status === 'dismissed' ? 'ignored' : (a.status === 'needs_triage' ? 'in_review' : 'discovered'),
              owner: a.owner_email,
              spiffe_id: null,
              model: null,
              last_seen_at: a.last_seen_at || a.first_discovered_at,
              recommendations: {
                config: 'warning',
                content: 'not_applicable',
                supply_chain: 'pass',
                eu_ai_act: 'pass',
              },
              metadata: { privilege_level: a.privilege_level },
            }))
            return { workloads: mapped, total: mapped.length, summary: { total_discovered: mapped.length, in_review: 0, ignored: 0, revoked: 0, governed: 0 } }
          }
          liveWorkloadsError = err instanceof Error && err.message ? err.message : 'The discovery workloads request failed.'
          return { workloads: [], total: 0, summary: { total_discovered: 0, in_review: 0, ignored: 0, revoked: 0, governed: 0 } }
        }),
        api.nhi.scans(token).catch(() => ({ scans: [] as NHIScan[] })),
        api.agents?.list
          ? api.agents.list(token).catch(() => ({ agents: [] as AgentResponse[] }))
          : Promise.resolve({ agents: [] as AgentResponse[] }),
      ])
      // Sources load beside the table rather than in front of it: a slow
      // connectors API must not hold back the workloads already in hand.
      void loadSources(token)

      setWorkloadsError(liveWorkloadsError)
      setWorkloads(workloadsRes.workloads || [])
      setTotal(workloadsRes.total || (workloadsRes.workloads ? workloadsRes.workloads.length : 0))
      const scans = scansData.scans
      setLatestScan(scans && scans.length > 0 ? scans[0] : null)
      if (agentsData && 'agents' in agentsData && Array.isArray(agentsData.agents)) {
        setAgents(agentsData.agents)
      }
      setError(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load discovery workloads')
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently, loadSources])

  useEffect(() => {
    loadData()
    const timer = setInterval(loadData, POLL_MS)
    return () => clearInterval(timer)
  }, [loadData])

  // The single refresh seam for "a provider's remote agents changed": called
  // after a Re-scan settles, and the hook a connector event stream subscribes
  // to when one is wired in.
  const onRemoteAgentsChanged = loadData

  const handleRescanSource = useCallback(
    async (providerId: string) => {
      setScanning((prev) => ({ ...prev, [providerId]: true }))
      setRescanErrors((prev) => {
        const next = { ...prev }
        delete next[providerId]
        return next
      })
      try {
        const token = await getAccessTokenSilently()
        const result = await connectorsApi.triggerScan(token, providerId)
        if (result.status === 'error') {
          const firstError = result.logs.find((l) => l.level === 'error')?.message
          setRescanErrors((prev) => ({ ...prev, [providerId]: firstError || 'The scan finished with errors; open Logs for detail.' }))
        }
      } catch (err) {
        setRescanErrors((prev) => ({ ...prev, [providerId]: connectorErrorMessage(err, 'The scan request failed.') }))
      } finally {
        setScanning((prev) => ({ ...prev, [providerId]: false }))
      }
      await onRemoteAgentsChanged()
    },
    [getAccessTokenSilently, onRemoteAgentsChanged],
  )

  // Extract distinct namespaces from workloads
  const distinctNamespaces = useMemo(() => {
    const set = new Set<string>()
    for (const w of workloads) {
      if (w.namespace) set.add(w.namespace)
    }
    return Array.from(set).sort()
  }, [workloads])

  // Filter options
  const sourceOptions: readonly ToolbarOption[] = [
    { value: 'all', label: 'All Sources', count: workloads.length },
    { value: 'idp', label: 'IDP / NHI', count: workloads.filter((w) => w.source === 'idp').length },
    { value: 'local_k8s', label: 'Local K8s', count: workloads.filter((w) => w.source === 'local_k8s').length },
    { value: 'external_k8s', label: 'Remote K8s (AFM)', count: workloads.filter((w) => w.source === 'external_k8s').length },
    { value: 'external_services', label: 'Cloud Run / n8n', count: workloads.filter((w) => w.source === 'external_services').length },
  ]

  const stateOptions: readonly ToolbarOption[] = [
    { value: 'all', label: 'All States', count: workloads.length },
    { value: 'discovered', label: 'Discovered', count: workloads.filter((w) => w.status === 'discovered').length },
    { value: 'in_review', label: 'In Review', count: workloads.filter((w) => w.status === 'in_review').length },
    { value: 'governed', label: 'Governed', count: workloads.filter((w) => w.status === 'governed').length },
    { value: 'ignored', label: 'Ignored', count: workloads.filter((w) => w.status === 'ignored').length },
    { value: 'revoked', label: 'Revoked', count: workloads.filter((w) => w.status === 'revoked').length },
  ]

  const namespaceSelectOptions: readonly ToolbarOption[] = [
    { value: 'all', label: 'All Namespaces' },
    ...distinctNamespaces.map((ns) => ({
      value: ns,
      label: ns,
      count: workloads.filter((w) => w.namespace === ns).length,
    })),
  ]

  const isFiltered = searchQuery !== '' || sourceFilter !== 'all' || stateFilter !== 'all' || namespaceFilter !== 'all' || attentionFilter !== 'all' || gitopsFilter || Boolean(providerFilter)

  function clearProviderFilter() {
    setSearchParams((prev) => {
      const next = new URLSearchParams(prev)
      next.delete('provider')
      next.delete('selected')
      return next
    })
  }

  function handleClearFilters() {
    if (providerFilter) clearProviderFilter()
    setSearchQuery('')
    setSourceFilter('all')
    setStateFilter('all')
    setNamespaceFilter('all')
    setAttentionFilter('all')
    setGitopsFilter(false)
  }

  // Filtered dataset
  const filteredWorkloads = useMemo(() => {
    return workloads.filter((w) => {
      if (providerFilter && rowProviderId(w) !== providerFilter) return false
      // GitOps filter
      if (gitopsFilter && !hasGitOpsMetadata(w)) return false

      // Attention filter
      if (attentionFilter === 'unowned') {
        if (w.owner || w.status === 'ignored') return false
      } else if (attentionFilter === 'attention_all') {
        const isUnowned = !w.owner && w.status !== 'ignored'
        const isDiscovered = w.status === 'discovered'
        const isRevoked = w.status === 'revoked'
        const isInReview = w.status === 'in_review'
        const isSplitBrain = hasKernelSplitBrain(w)
        if (!isUnowned && !isDiscovered && !isRevoked && !isInReview && !isSplitBrain) return false
      }

      if (sourceFilter !== 'all' && w.source !== sourceFilter) return false
      if (stateFilter !== 'all' && w.status !== stateFilter) return false
      if (namespaceFilter !== 'all' && w.namespace !== namespaceFilter) return false
      if (searchQuery) {
        const q = searchQuery.toLowerCase()
        const matchName = w.name.toLowerCase().includes(q)
        const matchOwner = w.owner ? w.owner.toLowerCase().includes(q) : false
        const matchNs = w.namespace ? w.namespace.toLowerCase().includes(q) : false
        const matchSource = w.source_label.toLowerCase().includes(q)
        const matchModel = w.model ? w.model.toLowerCase().includes(q) : false
        const matchSpiffe = w.spiffe_id ? w.spiffe_id.toLowerCase().includes(q) : false
        if (!matchName && !matchOwner && !matchNs && !matchSource && !matchModel && !matchSpiffe) return false
      }
      return true
    })
  }, [workloads, sourceFilter, stateFilter, namespaceFilter, searchQuery, attentionFilter, gitopsFilter, providerFilter])

  // Attention Alerts
  const alerts: AlertItem[] = useMemo(() => {
    const items: AlertItem[] = []
    const unowned = workloads.filter((w) => !w.owner && w.status !== 'ignored')
    if (unowned.length > 0) {
      items.push({
        id: 'unowned',
        label: 'unowned workloads',
        count: unowned.length,
        severity: 'critical',
        filterKey: 'unowned',
      })
    }
    const unreviewed = workloads.filter((w) => w.status === 'discovered')
    if (unreviewed.length > 0) {
      items.push({
        id: 'discovered_unreviewed',
        label: 'new discovered workloads',
        count: unreviewed.length,
        severity: 'warning',
        filterKey: 'discovered',
      })
    }
    const revoked = workloads.filter((w) => w.status === 'revoked')
    if (revoked.length > 0) {
      items.push({
        id: 'revoked_workloads',
        label: 'revoked workloads',
        count: revoked.length,
        severity: 'critical',
        filterKey: 'revoked',
      })
    }
    return items
  }, [workloads])

  function handleAlertClick(key: string) {
    if (key === 'discovered' || key === 'revoked') {
      setStateFilter(key)
      setAttentionFilter('all')
    } else if (key === 'unowned') {
      setAttentionFilter('unowned')
      setStateFilter('all')
      setSourceFilter('all')
    } else if (key === 'attention_all') {
      setAttentionFilter((prev) => (prev === 'attention_all' ? 'all' : 'attention_all'))
    }
  }

  // Row Actions Handlers
  async function handleEnrollWorkload(workloadId: string) {
    const target = workloads.find((w) => w.id === workloadId)
    if (target && isProviderHosted(target)) {
      alert(claimUnavailableReason(target))
      return
    }
    try {
      const token = await getAccessTokenSilently()
      await api.discovery.enroll(token, workloadId)
      setWorkloads((prev) =>
        prev.map((w) => (w.id === workloadId ? { ...w, status: 'in_review' as DiscoveryLifecycleState } : w))
      )
      setFeedbackToast(`Workload ${workloadId} enrolled into governance review.`)
      setTimeout(() => setFeedbackToast(null), 4000)
    } catch (e) {
      alert(`Enrollment failed: ${e instanceof Error ? e.message : String(e)}`)
    }
  }

  // Claim a provider-hosted agent into the tenant registry (live only).
  async function handleClaimRemote(w: DiscoveryWorkload) {
    const providerId = rowProviderId(w)
    if (!providerId) return
    const meta = w.metadata || {}
    const externalId = typeof meta.external_id === 'string' && meta.external_id ? meta.external_id : w.id
    setRemoteClaims((prev) => ({ ...prev, [w.id]: { busy: true, error: null } }))
    try {
      const token = await getAccessTokenSilently()
      const res = await claimRemoteAgent(token, providerId, externalId)
      setWorkloads((prev) =>
        prev.map((x) =>
          x.id === w.id
            ? { ...x, status: 'governed' as DiscoveryLifecycleState, metadata: { ...x.metadata, claimed_agent_id: res.agent_id } }
            : x,
        ),
      )
      setRemoteClaims((prev) => {
        const next = { ...prev }
        delete next[w.id]
        return next
      })
      setFeedbackToast(`${w.name} claimed into your agent registry.`)
      setTimeout(() => setFeedbackToast(null), 4000)
    } catch (e) {
      setRemoteClaims((prev) => ({ ...prev, [w.id]: { busy: false, error: connectorErrorMessage(e, 'Claim failed.') } }))
    }
  }

  async function handleDismissWorkload(workloadId: string) {
    const target = workloads.find((w) => w.id === workloadId)
    if (target && isProviderHosted(target)) {
      alert(DISMISS_UNAVAILABLE_REASON)
      return
    }
    try {
      const token = await getAccessTokenSilently()
      await api.discovery.dismiss(token, workloadId)
      setWorkloads((prev) =>
        prev.map((w) => (w.id === workloadId ? { ...w, status: 'ignored' as DiscoveryLifecycleState } : w))
      )
      setFeedbackToast(`Workload ${workloadId} dismissed.`)
      setTimeout(() => setFeedbackToast(null), 4000)
    } catch (e) {
      alert(`Dismissal failed: ${e instanceof Error ? e.message : String(e)}`)
    }
  }

  // Auto-Claim Namespace Handler
  async function handleAutoClaimNamespace(targetNamespace: string) {
    try {
      const token = await getAccessTokenSilently()
      const res = await api.discovery.autoclaimNamespace(token, targetNamespace)
      // Optimistic update: mark workloads in that namespace as governed
      setWorkloads((prev) =>
        prev.map((w) =>
          w.namespace === targetNamespace || (w.source === 'local_k8s' && targetNamespace === 'fe-signalloom-agents')
            ? {
                ...w,
                status: 'governed' as DiscoveryLifecycleState,
                spiffe_id: w.spiffe_id || `spiffe://signalloom.svc.cluster.local/ns/${targetNamespace}/sa/${w.name}`,
              }
            : w
        )
      )
      const count = res.total_claimed || res.claimed?.length || 1
      setFeedbackToast(`Successfully auto-claimed ${count} workload(s) in namespace '${targetNamespace}'.`)
      setTimeout(() => setFeedbackToast(null), 5000)
    } catch (e) {
      alert(`Auto-claim failed: ${e instanceof Error ? e.message : String(e)}`)
    }
  }

  function exportJson() {
    const blob = new Blob(
      [JSON.stringify({ workloads: filteredWorkloads, exported_at: new Date().toISOString() }, null, 2)],
      { type: 'application/json' }
    )
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `discovery-workloads-${new Date().toISOString().split('T')[0]}.json`
    a.click()
    URL.revokeObjectURL(url)
  }

  const SUPER_DATATABLE_COLUMNS: Column<DiscoveryWorkload>[] = [
    { key: 'name', label: 'Workload & Identity', sortable: true, help: 'Discovered non-human identity, pod, or external service.' },
    { key: 'source', label: 'Connector Source', sortable: true, help: 'Discovery integration source (IDP, Local K8s, AFM Remote K8s, Cloud Run, or n8n).' },
    { key: 'namespace', label: 'Namespace / Region', sortable: true, help: 'Cluster namespace or cloud deployment region.' },
    { key: 'status', label: 'Discovery State', sortable: true, help: 'Lifecycle state: Discovered, In Review, Ignored, Revoked, or Governed.' },
    { key: 'owner', label: 'Owner', sortable: true, help: 'Designated engineering owner or security contact.' },
    { key: 'id', label: 'Control Recommendations', help: 'Policy recommendations covering Config, Content, Supply Chain, and EU AI Act.' },
    { key: 'id', label: 'Actions' },
  ]

  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 18, flexWrap: 'wrap', gap: 12 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, margin: 0 }}>Shadow AI & Multi-Source Discovery</h1>
          <div style={{ fontSize: 13, color: 'var(--muted)', marginTop: 4 }}>
            Continuous discovery, non-human identity governance, and automated workload onboarding across IDP, Kubernetes, and Cloud Run.
          </div>
        </div>

        <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
          <button
            type="button"
            className="btn btn-primary"
            data-testid="autoclaim-namespace-btn"
            onClick={() => setIsAutoClaimOpen(true)}
            style={{
              fontSize: 12,
              padding: '7px 16px',
              background: colors.cyanLoom,
              borderColor: colors.cyanLoom,
              fontWeight: 600,
              display: 'inline-flex',
              alignItems: 'center',
              gap: 6,
            }}
          >
            <span>⚡ Auto-Claim Namespace</span>
          </button>
        </div>
      </div>

      <ConnectDirectoryCta />

      <AttentionPanel alerts={alerts} onAlert={handleAlertClick} />

      {feedbackToast && (
        <div
          role="status"
          data-testid="discovery-feedback-toast"
          style={{
            marginBottom: 16,
            padding: '12px 18px',
            background: 'rgba(20, 184, 166, 0.12)',
            border: '1px solid rgba(20, 184, 166, 0.35)',
            borderRadius: 8,
            color: colors.tealLoom,
            fontSize: 13,
            fontWeight: 500,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
          }}
        >
          <span>✓ {feedbackToast}</span>
          <button
            type="button"
            onClick={() => setFeedbackToast(null)}
            style={{ background: 'none', border: 'none', color: colors.tealLoom, cursor: 'pointer', fontSize: 14 }}
          >
            ✕
          </button>
        </div>

      )}

      {loading ? (
        <LoadingState variant="block" status="loading" label="discovery workloads" testId="discovery-load-state" />
      ) : error ? (
        <LoadingState
          variant="block"
          status="error"
          label="discovery workloads"
          error={error}
          onRetry={loadData}
          testId="discovery-load-state"
        />
      ) : (
        <>
          <ScanStatusCard scan={latestScan} totalDiscovered={workloads.length} />

          <DiscoverySourcesStrip
            sources={sources}
            loadError={sourcesError}
            scanning={scanning}
            rescanErrors={rescanErrors}
            onRescan={handleRescanSource}
            onLogs={setLogsProviderId}
          />

          {selectedExternalId && !selectedWorkload && !searchParams.get('workload') && !searchParams.get('agent') && !searchParams.get('sidebar') && (
            <div
              role="status"
              data-testid="discovery-deeplink-missing"
              className="card"
              style={{ marginBottom: 14, padding: '10px 16px', fontSize: 12.5, color: 'var(--muted)' }}
            >
              No discovered workload has the id <code>{selectedExternalId}</code>
              {providerFilter ? <> from provider <code>{providerFilter}</code></> : null}. It may not have been synced yet; try Re-scan.
            </div>
          )}

          {/* Super Datatable Toolbar */}
          <div style={{ marginBottom: 14 }}>
            <DataTableToolbar label="Discovery filter strip">
              <ToolbarSearch
                label="Search discovered workloads"
                placeholder="Search by name, owner, namespace..."
                value={searchQuery}
                onChange={setSearchQuery}
                testId="discovery-search-input"
              />
              <ToolbarFacet
                label="Filter workloads by source"
                value={sourceFilter}
                options={sourceOptions}
                onChange={setSourceFilter}
                testIdPrefix="discovery-source-facet"
              />
              <ToolbarFacet
                label="Filter workloads by state"
                value={stateFilter}
                options={stateOptions}
                onChange={setStateFilter}
                testIdPrefix="discovery-state-facet"
              />
              <ToolbarSelect
                label="Namespace"
                subject="the workloads"
                value={namespaceFilter}
                options={namespaceSelectOptions}
                onChange={setNamespaceFilter}
                testId="discovery-namespace-select"
              />
              <button
                type="button"
                onClick={() => setAttentionFilter((prev) => (prev === 'attention_all' ? 'all' : 'attention_all'))}
                data-testid="discovery-attention-facet-btn"
                aria-pressed={attentionFilter === 'attention_all'}
                style={{
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: 6,
                  padding: '5px 10px',
                  borderRadius: 4,
                  fontSize: 12,
                  fontWeight: attentionFilter === 'attention_all' ? 600 : 500,
                  cursor: 'pointer',
                  fontFamily: 'inherit',
                  background: attentionFilter === 'attention_all'
                    ? 'rgba(239, 68, 68, 0.18)'
                    : 'var(--surface2)',
                  color: attentionFilter === 'attention_all' ? colors.red : 'var(--text)',
                  border: `1px solid ${attentionFilter === 'attention_all' ? colors.red : 'var(--border)'}`,
                }}
              >
                <span
                  style={{
                    background: colors.red,
                    color: 'var(--on-accent)',
                    borderRadius: 99,
                    fontSize: 10,
                    fontWeight: 700,
                    padding: '0px 5px',
                    minWidth: 16,
                    textAlign: 'center',
                  }}
                >
                  {workloads.filter((w) => (!w.owner && w.status !== 'ignored') || w.status === 'discovered' || w.status === 'revoked' || w.status === 'in_review').length}
                </span>
                Attention Required
              </button>
              <button
                type="button"
                onClick={() => setGitopsFilter((prev) => !prev)}
                data-testid="discovery-gitops-filter-btn"
                aria-pressed={gitopsFilter}
                style={{
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: 6,
                  padding: '5px 10px',
                  borderRadius: 4,
                  fontSize: 12,
                  fontWeight: gitopsFilter ? 600 : 500,
                  cursor: 'pointer',
                  fontFamily: 'inherit',
                  background: gitopsFilter
                    ? 'rgba(0, 210, 255, 0.18)'
                    : 'var(--surface2)',
                  color: gitopsFilter ? colors.cyanLoom : 'var(--text)',
                  border: `1px solid ${gitopsFilter ? colors.cyanLoom : 'var(--border)'}`,
                }}
              >
                <span
                  style={{
                    background: gitopsFilter ? colors.cyanLoom : 'var(--surface)',
                    color: gitopsFilter ? 'var(--on-accent)' : 'var(--muted)',
                    borderRadius: 99,
                    fontSize: 10,
                    fontWeight: 700,
                    padding: '0px 5px',
                    minWidth: 16,
                    textAlign: 'center',
                  }}
                >
                  {workloads.filter(hasGitOpsMetadata).length}
                </span>
                GitOps
              </button>
              {providerFilter && (
                <button
                  type="button"
                  className="btn btn-secondary"
                  data-testid="discovery-provider-filter-chip"
                  onClick={clearProviderFilter}
                  aria-label={`Remove provider filter ${providerFilter}`}
                  style={{ fontSize: 11.5, padding: '4px 10px' }}
                >
                  Provider: {sources.find((s) => s.providerId === providerFilter)?.name ?? providerFilter} ✕
                </button>
              )}
              <ToolbarClear
                active={isFiltered}
                onClear={handleClearFilters}
                testId="discovery-clear-filters"
              />
              <ToolbarCount
                shown={filteredWorkloads.length}
                total={workloads.length}
                noun="workloads"
                testId="discovery-workload-count"
              />
              <div style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
                <button
                  type="button"
                  className="btn btn-secondary"
                  style={{ fontSize: 11.5, padding: '4px 10px' }}
                  onClick={exportJson}
                >
                  Export JSON
                </button>
              </div>
            </DataTableToolbar>
          </div>

          {workloadsError ? (
            <div
              className="card"
              role="alert"
              data-testid="discovery-workloads-error"
              style={{ padding: '14px 20px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}
            >
              <span style={{ fontSize: 13, color: 'var(--error)' }}>
                Could not load discovered workloads: {workloadsError}
              </span>
              <button type="button" className="btn btn-secondary" onClick={() => void loadData()} style={{ fontSize: 12 }}>
                Retry
              </button>
            </div>
          ) : workloads.length === 0 ? (
            sourcesLoaded ? (
              <DiscoveryEmptyState sources={sources} sourcesError={sourcesError} />
            ) : (
              <LoadingState variant="block" status="loading" label="connected sources" testId="discovery-sources-load-state" />
            )
          ) : filteredWorkloads.length === 0 ? (
            <EmptyState
              kicker="No workloads found"
              body="No discovered workloads match the selected filter criteria."
            />
          ) : (
            <DataTable<DiscoveryWorkload>
              columns={SUPER_DATATABLE_COLUMNS}
              data={filteredWorkloads}
              pageSize={PAGE_SIZE}
              hidePaginationWhenSinglePage
              testIdPrefix="discovery-super-datatable"
              renderRow={(w) => {
                const matched = findMatchingAgent(
                  {
                    id: w.id,
                    account_name: w.name,
                    owner_email: w.owner || null,
                  },
                  agents
                )
                return (
                  <WorkloadRow
                    key={w.id}
                    workload={w}
                    matchedAgent={matched}
                    onEnroll={handleEnrollWorkload}
                    onDismiss={handleDismissWorkload}
                    onOpen={handleOpenWorkload}
                    selected={selectedWorkload?.id === w.id}
                    onClaimRemote={handleClaimRemote}
                    remoteClaim={remoteClaims[w.id]}
                  />
                )
              }}
            />
          )}

          <DiscoveredWorkloadDrawer
            isOpen={Boolean(selectedWorkload)}
            workload={selectedWorkload}
            matchedAgent={
              selectedWorkload
                ? findMatchingAgent(
                    {
                      id: selectedWorkload.id,
                      account_name: selectedWorkload.name,
                      owner_email: selectedWorkload.owner || null,
                    },
                    agents,
                  )
                : null
            }
            onClose={handleCloseDrawer}
            onEnroll={handleEnrollWorkload}
            onDismiss={handleDismissWorkload}
            onClaim={selectedWorkload && isProviderHosted(selectedWorkload) ? undefined : (w) => setClaimWorkload(w)}
          />

          {logsProviderId && (
            <SyncLogsModal
              isOpen
              providerId={logsProviderId}
              providerName={sources.find((s) => s.providerId === logsProviderId)?.name ?? logsProviderId}
              onClose={() => setLogsProviderId(null)}
              onRescan={() => handleRescanSource(logsProviderId)}
            />
          )}

          {claimWorkload && (
            <ClaimModal
              agent={workloadToClaimAgent(claimWorkload)}
              onClose={() => setClaimWorkload(null)}
              onSuccess={() => {
                setWorkloads((prev) =>
                  prev.map((w) =>
                    w.id === claimWorkload.id
                      ? { ...w, status: 'governed' as DiscoveryLifecycleState }
                      : w,
                  ),
                )
                setClaimWorkload(null)
                setFeedbackToast(`Workload ${claimWorkload.name} successfully claimed into Signal Loom governance.`)
                setTimeout(() => setFeedbackToast(null), 4000)
              }}
            />
          )}

          <AutoClaimModal
            isOpen={isAutoClaimOpen}
            namespaces={distinctNamespaces}
            onClose={() => setIsAutoClaimOpen(false)}
            onConfirm={handleAutoClaimNamespace}
          />
        </>
      )}
    </div>
  )
}
