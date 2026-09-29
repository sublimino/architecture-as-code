import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import AgentDeepLink from '../components/AgentDeepLink'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import type {
  DiscoveryWorkload,
  DiscoverySource,
  DiscoveryLifecycleState,
  ControlRecommendations,
  NHIScan,
  AgentResponse,
} from '../types/api'
import { colors } from '../styles/tokens'
import StatusBadge from '../components/StatusBadge'
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

// Workload Row Component

interface WorkloadRowProps {
  workload: DiscoveryWorkload
  matchedAgent?: AgentResponse
  onEnroll: (id: string) => void
  onDismiss: (id: string) => void
  onOpen: (id: string) => void
}

function WorkloadRow({ workload, matchedAgent, onEnroll, onDismiss, onOpen }: WorkloadRowProps) {
  const isIgnored = workload.status === 'ignored'
  const isGoverned = workload.status === 'governed'
  const isRevoked = workload.status === 'revoked'

  const rowStyle: React.CSSProperties = {
    borderBottom: '1px solid var(--border)',
    opacity: isIgnored ? 0.65 : 1,
  }
  const td: React.CSSProperties = { ...DataTable.td, padding: '10px 14px', fontSize: 13 }

  return (
    <tr style={rowStyle} data-testid={`discovery-row-${workload.id}`}>
      {/* Workload Name & Info */}
      <td style={td}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <button
            onClick={() => onOpen(workload.id)}
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
        <StatusBadge status={workload.status} variant="lifecycle" />
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
          {isGoverned ? (
            <span style={{
              fontSize: 11,
              fontWeight: 600,
              padding: '3px 8px',
              borderRadius: 4,
              background: 'rgba(20, 184, 166, 0.15)',
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
                title="Claim and enroll this workload into Signal Loom governance"
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
                  title="Dismiss this discovery finding"
                >
                  Ignore
                </button>
              )}
            </>
          )}
        </div>
      </td>
    </tr>
  )
}

// Main Page Component

export default function DiscoveryPage() {
  const { getAccessTokenSilently } = useAuth0()
  const navigate = useNavigate()

  const [workloads, setWorkloads] = useState<DiscoveryWorkload[]>([])
  const [total, setTotal] = useState(0)
  const [latestScan, setLatestScan] = useState<NHIScan | null>(null)
  const [agents, setAgents] = useState<AgentResponse[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [feedbackToast, setFeedbackToast] = useState<string | null>(null)

  // Filters
  const [searchQuery, setSearchQuery] = useState('')
  const [sourceFilter, setSourceFilter] = useState('all')
  const [stateFilter, setStateFilter] = useState('all')
  const [namespaceFilter, setNamespaceFilter] = useState('all')
  const [attentionFilter, setAttentionFilter] = useState<'all' | 'unowned' | 'attention_all'>('all')

  // Auto-claim Modal
  const [isAutoClaimOpen, setIsAutoClaimOpen] = useState(false)

  const loadData = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const [workloadsRes, scansData, agentsData] = await Promise.all([
        api.discovery.workloads(token).catch(async () => {
          // Fallback to demo fixture endpoint if live aggregate fails
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
        }),
        api.nhi.scans(token).catch(() => ({ scans: [] as NHIScan[] })),
        api.agents?.list
          ? api.agents.list(token).catch(() => ({ agents: [] as AgentResponse[] }))
          : Promise.resolve({ agents: [] as AgentResponse[] }),
      ])

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
  }, [getAccessTokenSilently])

  useEffect(() => {
    loadData()
    const timer = setInterval(loadData, POLL_MS)
    return () => clearInterval(timer)
  }, [loadData])

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

  const isFiltered = searchQuery !== '' || sourceFilter !== 'all' || stateFilter !== 'all' || namespaceFilter !== 'all' || attentionFilter !== 'all'

  function handleClearFilters() {
    setSearchQuery('')
    setSourceFilter('all')
    setStateFilter('all')
    setNamespaceFilter('all')
    setAttentionFilter('all')
  }

  // Filtered dataset
  const filteredWorkloads = useMemo(() => {
    return workloads.filter((w) => {
      // Attention filter
      if (attentionFilter === 'unowned') {
        if (w.owner || w.status === 'ignored') return false
      } else if (attentionFilter === 'attention_all') {
        const isUnowned = !w.owner && w.status !== 'ignored'
        const isDiscovered = w.status === 'discovered'
        const isRevoked = w.status === 'revoked'
        const isInReview = w.status === 'in_review'
        if (!isUnowned && !isDiscovered && !isRevoked && !isInReview) return false
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
        if (!matchName && !matchOwner && !matchNs && !matchSource) return false
      }
      return true
    })
  }, [workloads, sourceFilter, stateFilter, namespaceFilter, searchQuery, attentionFilter])

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

  async function handleDismissWorkload(workloadId: string) {
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
                spiffe_id: w.spiffe_id || `spiffe://signalloom.demo/ns/${targetNamespace}/sa/${w.name}`,
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

          {filteredWorkloads.length === 0 ? (
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
                    onOpen={(id) => navigate(`/discovery/accounts/${id}`)}
                  />
                )
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
