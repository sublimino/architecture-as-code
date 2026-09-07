import { useState, useMemo, useEffect, useCallback } from 'react'
import { useSearchParams } from 'react-router-dom'
import type {
  AgentResponse,
  AgentComplianceResultResponse,
  SourceHealthMap,
} from '../types/api'
import { colors } from '../styles/tokens'
import StatusBadge from './StatusBadge'
import EmptyState from './EmptyState'

// ─── Helpers ────────────────────────────────────────────────────────────────

function fmtDate(iso: string | null) {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('en-GB', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export interface AgentAssessmentsTabProps {
  agent: AgentResponse
  complianceResults?: AgentComplianceResultResponse[]
  openViolations?: number
  onReassess: (controlId: string) => Promise<void>
  onScanCompliance?: () => Promise<void>
  isScanning?: boolean
  lastScanTimestamp?: string | null
  sourceHealth?: 'healthy' | 'degraded' | 'unavailable' | null
  sourceHealthDetail?: SourceHealthMap | null
}

interface FrameworkGroup {
  name: string
  controls: AgentComplianceResultResponse[]
  passing: number
  failing: number
  pending: number
  total: number
  passRate: number
}

interface Article9RequirementItem {
  clause: string
  title: string
  description: string
  controlId: string
  status: string
  evidenceRef: string | null
  assessedAt: string | null
}

const DEFAULT_ARTICLE_9_REQUIREMENTS: Omit<Article9RequirementItem, 'status' | 'evidenceRef' | 'assessedAt'>[] = [
  {
    clause: 'Art. 9(1)',
    title: 'Continuous Risk Management System',
    description: 'Systematic iterative risk identification and lifecycle governance for high-risk AI workflows.',
    controlId: 'eu-ai-act:art-9',
  },
  {
    clause: 'Art. 9(2)',
    title: 'Risk Estimation & Mitigation Controls',
    description: 'Identification of known and foreseeable risks with enforced cryptographic containment boundaries.',
    controlId: 'eu-ai-act:art-9-mitigation',
  },
  {
    clause: 'Art. 9(5)',
    title: 'Testing & Robustness Validation',
    description: 'Empirical verification against predefined performance thresholds prior to production deployment.',
    controlId: 'eu-ai-act:art-9-testing',
  },
  {
    clause: 'Art. 9(7)',
    title: 'Post-Market Telemetry & Monitoring',
    description: 'Continuous operational monitoring and evaluation of post-deployment real-world telemetry data.',
    controlId: 'eu-ai-act:art-9-monitoring',
  },
]

export default function AgentAssessmentsTab({
  agent,
  complianceResults = [],
  openViolations = 0,
  onReassess,
  onScanCompliance,
  isScanning = false,
  lastScanTimestamp,
  sourceHealth,
  sourceHealthDetail,
}: AgentAssessmentsTabProps) {
  const [searchParams, setSearchParams] = useSearchParams()
  const initialFramework = searchParams.get('framework') || 'all'
  const initialStatus = searchParams.get('status') || 'all'
  const initialSearch = searchParams.get('search') || ''

  const [selectedFramework, setSelectedFramework] = useState<string>(initialFramework)
  const [statusFilter, setStatusFilter] = useState<string>(initialStatus)
  const [searchQuery, setSearchQuery] = useState<string>(initialSearch)
  const [requestingId, setRequestingId] = useState<string | null>(null)
  const [requestedIds, setRequestedIds] = useState<Set<string>>(new Set())

  useEffect(() => {
    const fw = searchParams.get('framework') || 'all'
    const st = searchParams.get('status') || 'all'
    const q = searchParams.get('search') || ''
    setSelectedFramework(fw)
    setStatusFilter(st)
    setSearchQuery(q)
  }, [searchParams])

  const handleFrameworkChange = useCallback((fw: string) => {
    setSelectedFramework(fw)
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      if (fw && fw !== 'all') next.set('framework', fw)
      else next.delete('framework')
      return next
    }, { replace: true })
  }, [setSearchParams])

  const handleStatusChange = useCallback((st: string) => {
    setStatusFilter(st)
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      if (st && st !== 'all') next.set('status', st)
      else next.delete('status')
      return next
    }, { replace: true })
  }, [setSearchParams])

  const handleSearchChange = useCallback((q: string) => {
    setSearchQuery(q)
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      if (q.trim()) next.set('search', q.trim())
      else next.delete('search')
      return next
    }, { replace: true })
  }, [setSearchParams])

  // 1. Truthful Assessment & Posture Calculations
  const rawResults = complianceResults
  const totalControlsCount = rawResults.length > 0
    ? rawResults.length
    : (agent.assessment_summary?.total_controls || agent.compliance_summary.total_controls)

  const passingControls = rawResults.length > 0
    ? rawResults.filter(c => c.status === 'pass' || c.status === 'compliant').length
    : (agent.assessment_summary?.passed_controls ?? agent.compliance_summary.passing)

  const failingControls = rawResults.length > 0
    ? rawResults.filter(c => c.status === 'fail' || c.status === 'non_compliant').length
    : (agent.assessment_summary?.failed_controls ?? agent.compliance_summary.failing)

  const pendingControls = rawResults.length > 0
    ? rawResults.filter(c => c.status === 'pending' || c.status === 'reassessment_requested' || c.status === 'not_assessed').length
    : (agent.assessment_summary?.pending_controls ?? agent.compliance_summary.pending)

  const isNotAssessed = (agent.assessment_summary?.status === 'not_assessed') ||
    (totalControlsCount === 0) ||
    (agent.compliance_summary.posture_score === null && passingControls === 0 && failingControls === 0)

  const postureScorePct = !isNotAssessed && totalControlsCount > 0
    ? (agent.compliance_summary.posture_score !== null
        ? Math.round(agent.compliance_summary.posture_score <= 1.0 ? agent.compliance_summary.posture_score * 100 : agent.compliance_summary.posture_score)
        : Math.round((passingControls / totalControlsCount) * 100))
    : null

  const overallPassRatePct = totalControlsCount > 0
    ? Math.round((passingControls / totalControlsCount) * 100)
    : 0

  // 2. Source Health
  const effectiveSourceHealth = sourceHealth || (sourceHealthDetail?.crypto_proofs?.status === 'unavailable' ? 'unavailable' : 'healthy')
  const isSourceUnavailable = effectiveSourceHealth === 'unavailable'
  const sourceHealthText = isSourceUnavailable
    ? 'Source unavailable'
    : (effectiveSourceHealth.charAt(0).toUpperCase() + effectiveSourceHealth.slice(1))

  // 3. Last Assessed Timestamp
  const lastAssessedIso = lastScanTimestamp || agent.timestamps?.last_action_at || agent.timestamps?.last_observed_at || null

  // 4. Framework Groups & Control Ratios
  const frameworkGroups: FrameworkGroup[] = useMemo(() => {
    const map: Record<string, AgentComplianceResultResponse[]> = {}
    for (const r of rawResults) {
      const fwName = r.framework_name || 'Standard Governance'
      if (!map[fwName]) map[fwName] = []
      map[fwName].push(r)
    }
    return Object.entries(map).map(([name, controls]) => {
      const passing = controls.filter(c => c.status === 'pass' || c.status === 'compliant').length
      const failing = controls.filter(c => c.status === 'fail' || c.status === 'non_compliant').length
      const pending = controls.filter(c => c.status === 'pending' || c.status === 'reassessment_requested' || c.status === 'not_assessed').length
      const total = controls.length
      const passRate = total > 0 ? Math.round((passing / total) * 100) : 0
      return {
        name,
        controls,
        passing,
        failing,
        pending,
        total,
        passRate,
      }
    })
  }, [rawResults])

  // 5. Article 9 Breakdown
  const article9Requirements: Article9RequirementItem[] = useMemo(() => {
    return DEFAULT_ARTICLE_9_REQUIREMENTS.map(def => {
      // Find matching real control if present
      const match = rawResults.find(r =>
        r.control_id.toLowerCase() === def.controlId.toLowerCase() ||
        (def.clause === 'Art. 9(1)' && (r.control_id.includes('art-9') || r.control_name.toLowerCase().includes('risk management'))) ||
        (r.control_name.toLowerCase().includes(def.title.toLowerCase()))
      )
      if (match) {
        return {
          ...def,
          status: match.status,
          evidenceRef: match.evidence_ref,
          assessedAt: match.assessed_at,
        }
      }
      return {
        ...def,
        status: isNotAssessed ? 'not_assessed' : 'pending',
        evidenceRef: null,
        assessedAt: null,
      }
    })
  }, [rawResults, isNotAssessed])

  const article9PassingCount = article9Requirements.filter(r => r.status === 'pass' || r.status === 'compliant').length
  const article9TotalCount = article9Requirements.length
  const article9RatioPct = Math.round((article9PassingCount / article9TotalCount) * 100)

  // 6. Filtered Frameworks & Controls
  const filteredGroups = useMemo(() => {
    return frameworkGroups
      .filter(fg => selectedFramework === 'all' || fg.name === selectedFramework)
      .map(fg => {
        const filteredControls = fg.controls.filter(c => {
          // Status filter
          if (statusFilter === 'fail' && !(c.status === 'fail' || c.status === 'non_compliant')) return false
          if (statusFilter === 'pass' && !(c.status === 'pass' || c.status === 'compliant')) return false
          if (statusFilter === 'pending' && !(c.status === 'pending' || c.status === 'reassessment_requested' || c.status === 'not_assessed')) return false
          if (statusFilter === 'reassessment_requested' && c.status !== 'reassessment_requested') return false
          // Search query
          if (searchQuery.trim()) {
            const q = searchQuery.toLowerCase()
            const matchName = c.control_name.toLowerCase().includes(q)
            const matchId = c.control_id.toLowerCase().includes(q)
            const matchEvidence = (c.evidence_ref || '').toLowerCase().includes(q)
            if (!matchName && !matchId && !matchEvidence) return false
          }
          return true
        })
        return {
          ...fg,
          controls: filteredControls,
        }
      })
      .filter(fg => fg.controls.length > 0 || (statusFilter === 'all' && !searchQuery.trim()))
  }, [frameworkGroups, selectedFramework, statusFilter, searchQuery])

  // 7. Reassessment Handler
  async function handleReassess(controlId: string) {
    setRequestingId(controlId)
    try {
      await onReassess(controlId)
      setRequestedIds(prev => new Set(prev).add(controlId))
    } catch (e) {
      alert(`Reassessment request failed: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setRequestingId(null)
    }
  }

  const statusIcons: Record<string, string> = {
    pass: '✓',
    compliant: '✓',
    fail: '✗',
    non_compliant: '✗',
    pending: '○',
    not_assessed: '—',
    reassessment_requested: '↻',
  }

  const statusColorsMap: Record<string, string> = {
    pass: colors.tealLoom,
    compliant: colors.tealLoom,
    fail: colors.red,
    non_compliant: colors.red,
    pending: colors.muted,
    not_assessed: colors.muted,
    reassessment_requested: colors.amber,
  }

  return (
    <div
      data-testid="dossier-panel-assessments"
      role="tabpanel"
      id="dossier-tabpanel-assessments"
      aria-labelledby="dossier-tab-assessments"
      style={{ display: 'flex', flexDirection: 'column', gap: 20 }}
    >
      {/* ─── Source Health Warning Banner (Fail-closed Truthful Notice) ─────────── */}
      {isSourceUnavailable && (
        <div
          data-testid="assessments-source-health-alert"
          style={{
            padding: '12px 16px',
            borderRadius: 6,
            background: 'rgba(239, 68, 68, 0.12)',
            border: '1px solid rgba(239, 68, 68, 0.3)',
            color: 'var(--error)',
            fontSize: 13,
            display: 'flex',
            alignItems: 'center',
            gap: 10,
          }}
        >
          <span style={{ fontSize: 16, fontWeight: 700 }}>⚠️</span>
          <div>
            <strong>Source unavailable:</strong> Primary compliance assessment collector is currently unreachable. Displayed control states reflect last cached observation and may be degraded.
          </div>
        </div>
      )}

      {/* ─── 4 StatCards / Assessment Summary Grid ──────────────────────────────── */}
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))',
          gap: 14,
        }}
      >
        {/* StatCard 1: Overall Posture & Assessed Control Ratio */}
        <div
          className="card"
          data-testid="assessments-card-posture"
          style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}
        >
          <div>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 8 }}>
              Governance Posture
            </div>
            <div
              data-testid="assessments-posture-score"
              style={{
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
              }}
            >
              {isNotAssessed ? 'Not assessed' : `${postureScorePct}%`}
            </div>
          </div>

          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 6 }}>
              <span style={{ color: 'var(--muted)' }}>Control Ratio:</span>
              <span data-testid="assessments-control-ratio" style={{ fontWeight: 600 }}>
                {isNotAssessed ? 'Not assessed' : `${passingControls}/${totalControlsCount} Passing (${overallPassRatePct}%)`}
              </span>
            </div>
            {/* Visual ratio progress bar */}
            {!isNotAssessed && totalControlsCount > 0 && (
              <div style={{ height: 5, width: '100%', background: 'var(--surface2)', borderRadius: 3, overflow: 'hidden', display: 'flex' }}>
                <div style={{ width: `${(passingControls / totalControlsCount) * 100}%`, background: colors.tealLoom }} />
                <div style={{ width: `${(failingControls / totalControlsCount) * 100}%`, background: colors.red }} />
                <div style={{ width: `${(pendingControls / totalControlsCount) * 100}%`, background: colors.amber }} />
              </div>
            )}
          </div>
        </div>

        {/* StatCard 2: Evaluated Control Breakdown */}
        <div
          className="card"
          data-testid="assessments-card-counts"
          style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}
        >
          <div>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 8 }}>
              Evaluated Controls
            </div>
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
              <span
                data-testid="assessments-total-controls"
                style={{ fontSize: 32, fontWeight: 800, lineHeight: 1.1, color: 'var(--text)' }}
              >
                {totalControlsCount}
              </span>
              <span style={{ fontSize: 13, color: 'var(--muted)' }}>total defined</span>
            </div>
          </div>

          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 6, textAlign: 'center', fontSize: 11 }}>
            <div>
              <div data-testid="assessments-passed-count" style={{ fontWeight: 700, fontSize: 14, color: colors.tealLoom }}>
                {passingControls}
              </div>
              <div style={{ color: 'var(--muted)' }}>Pass</div>
            </div>
            <div>
              <div data-testid="assessments-failing-count" style={{ fontWeight: 700, fontSize: 14, color: failingControls > 0 ? colors.red : 'var(--muted)' }}>
                {failingControls}
              </div>
              <div style={{ color: 'var(--muted)' }}>Fail</div>
            </div>
            <div>
              <div data-testid="assessments-pending-count" style={{ fontWeight: 700, fontSize: 14, color: pendingControls > 0 ? colors.amber : 'var(--muted)' }}>
                {pendingControls}
              </div>
              <div style={{ color: 'var(--muted)' }}>Pending</div>
            </div>
          </div>
        </div>

        {/* StatCard 3: Open Violations & Findings */}
        <div
          className="card"
          data-testid="assessments-card-violations"
          style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}
        >
          <div>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 8 }}>
              Open Violations
            </div>
            <div
              data-testid="assessments-open-violations"
              style={{
                fontSize: 32,
                fontWeight: 800,
                lineHeight: 1.1,
                color: openViolations > 0 ? colors.red : colors.tealLoom,
              }}
            >
              {openViolations}
            </div>
          </div>

          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 12 }}>
            <span style={{ color: 'var(--muted)' }}>Attention:</span>
            <span
              data-testid="assessments-attention-status"
              style={{
                fontWeight: 600,
                color: openViolations > 0 ? colors.red : colors.tealLoom,
              }}
            >
              {openViolations > 0 ? `${openViolations} active violation${openViolations > 1 ? 's' : ''}` : 'Clean posture'}
            </span>
          </div>
        </div>

        {/* StatCard 4: Assessment Lifecycle & Scan Action */}
        <div
          className="card"
          data-testid="assessments-card-lifecycle"
          style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}
        >
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <span style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)' }}>
                Assessment Lifecycle
              </span>
              <span
                data-testid="assessments-source-health"
                style={{
                  fontSize: 10,
                  fontWeight: 600,
                  padding: '2px 6px',
                  borderRadius: 3,
                  background: isSourceUnavailable ? 'rgba(239, 68, 68, 0.15)' : 'rgba(16, 185, 129, 0.15)',
                  color: isSourceUnavailable ? colors.red : colors.tealLoom,
                }}
              >
                {sourceHealthText}
              </span>
            </div>
            <div data-testid="assessments-last-assessed" style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>
              {lastAssessedIso ? fmtDate(lastAssessedIso) : '—'}
            </div>
            {!lastAssessedIso && (
              <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>Pending assessment</div>
            )}
          </div>

          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)' }}>
            {onScanCompliance && (
              <button
                type="button"
                className="btn btn-secondary"
                data-testid="assessments-scan-button"
                style={{ width: '100%', fontSize: 11, padding: '5px 10px', justifyContent: 'center' }}
                disabled={isScanning || isSourceUnavailable}
                onClick={() => onScanCompliance()}
              >
                {isScanning ? 'Scanning Compliance…' : '⚡ Run Assessment Scan'}
              </button>
            )}
          </div>
        </div>
      </div>

      {/* ─── EU AI Act Article 9 Breakdown Panel ────────────────────────────────── */}
      <section data-testid="assessments-section-article9" className="card" style={{ padding: 20 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', flexWrap: 'wrap', gap: 12, marginBottom: 16 }}>
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <h2 style={{ fontSize: 16, fontWeight: 700, margin: 0 }}>
                EU AI Act Article 9 — Risk Management System
              </h2>
              <span
                className="tag"
                data-testid="article9-risk-badge"
                style={{
                  fontSize: 10,
                  padding: '2px 8px',
                  background: 'rgba(139, 92, 246, 0.15)',
                  color: 'var(--violet)',
                  border: '1px solid rgba(139, 92, 246, 0.3)',
                }}
              >
                {agent.eu_ai_act_risk_class ? `Risk Class: ${agent.eu_ai_act_risk_class.toUpperCase()}` : 'High-Risk AI System'}
              </span>
            </div>
            <p style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4, marginBottom: 0 }}>
              Continuous iterative risk management system requirement established under Regulation (EU) 2024/1689 Article 9.
            </p>
          </div>

          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                Article 9 Compliance
              </div>
              <div
                data-testid="article9-ratio-score"
                style={{
                  fontSize: 18,
                  fontWeight: 700,
                  color: isNotAssessed ? 'var(--muted)' : article9PassingCount === article9TotalCount ? colors.tealLoom : colors.amber,
                }}
              >
                {isNotAssessed ? 'Not assessed' : `${article9PassingCount}/${article9TotalCount} Controls (${article9RatioPct}%)`}
              </div>
            </div>
          </div>
        </div>

        {/* Article 9 Requirements Grid */}
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))', gap: 12 }}>
          {article9Requirements.map(req => {
            const isPassing = req.status === 'pass' || req.status === 'compliant'
            const isFailing = req.status === 'fail' || req.status === 'non_compliant'
            const isAlreadyRequested = requestedIds.has(req.controlId) || req.status === 'reassessment_requested'
            const isReqPending = requestingId === req.controlId

            return (
              <div
                key={req.clause}
                data-testid={`article9-card-${req.clause.replace(/[^a-zA-Z0-9]/g, '-').toLowerCase()}`}
                style={{
                  padding: 14,
                  borderRadius: 6,
                  background: isFailing
                    ? 'rgba(239, 68, 68, 0.04)'
                    : isPassing
                    ? 'rgba(16, 185, 129, 0.04)'
                    : 'var(--surface2)',
                  border: isFailing
                    ? '1px solid rgba(239, 68, 68, 0.2)'
                    : isPassing
                    ? '1px solid rgba(16, 185, 129, 0.2)'
                    : '1px solid var(--border)',
                  display: 'flex',
                  flexDirection: 'column',
                  justifyContent: 'space-between',
                  gap: 10,
                }}
              >
                <div>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 }}>
                    <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--cyan)' }}>
                      {req.clause}
                    </span>
                    <StatusBadge status={req.status} variant="compliance" />
                  </div>
                  <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}>
                    {req.title}
                  </div>
                  <div style={{ fontSize: 11, color: 'var(--muted)', lineHeight: 1.4 }}>
                    {req.description}
                  </div>
                </div>

                <div style={{ paddingTop: 8, borderTop: '1px solid var(--border)', display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 11 }}>
                  <div>
                    {req.evidenceRef ? (
                      <span style={{ fontFamily: 'monospace', color: 'var(--muted)', fontSize: 10 }}>
                        {req.evidenceRef}
                      </span>
                    ) : (
                      <span style={{ color: 'var(--dim)', fontStyle: 'italic' }}>No evidence attached</span>
                    )}
                  </div>
                  {isFailing && (
                    <button
                      type="button"
                      className="btn btn-secondary"
                      style={{ fontSize: 10, padding: '2px 8px' }}
                      disabled={isAlreadyRequested || isReqPending}
                      onClick={() => handleReassess(req.controlId)}
                    >
                      {isReqPending ? 'Requesting…' : isAlreadyRequested ? 'Requested' : 'Reassess'}
                    </button>
                  )}
                </div>
              </div>
            )
          })}
        </div>
      </section>

      {/* ─── Framework Controls Breakdown & Ratios Section ─────────────────────── */}
      <section data-testid="assessments-section-frameworks">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 12, marginBottom: 14 }}>
          <div>
            <h2 style={{ fontSize: 16, fontWeight: 700, margin: 0 }}>
              Framework Controls & Assessment Ratios
            </h2>
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2 }}>
              Verified compliance observations mapped to regulatory standards.
            </div>
          </div>

          {/* Filter Bar */}
          <div
            data-testid="frameworks-filter-bar"
            style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}
          >
            {/* Search Input */}
            <input
              type="text"
              data-testid="assessments-search-input"
              placeholder="Filter controls or evidence…"
              value={searchQuery}
              onChange={e => handleSearchChange(e.target.value)}
              style={{
                fontSize: 12,
                padding: '5px 10px',
                background: 'var(--surface)',
                border: '1px solid var(--border)',
                borderRadius: 4,
                color: 'var(--text)',
                width: 180,
              }}
            />

            {/* Framework Select */}
            {frameworkGroups.length > 1 && (
              <select
                data-testid="assessments-framework-select"
                value={selectedFramework}
                onChange={e => handleFrameworkChange(e.target.value)}
                style={{
                  fontSize: 12,
                  padding: '5px 10px',
                  background: 'var(--surface)',
                  border: '1px solid var(--border)',
                  borderRadius: 4,
                  color: 'var(--text)',
                }}
              >
                <option value="all">All Frameworks ({frameworkGroups.length})</option>
                {frameworkGroups.map(fg => (
                  <option key={fg.name} value={fg.name}>
                    {fg.name} ({fg.total})
                  </option>
                ))}
              </select>
            )}

            {/* Status Filter */}
            <div style={{ display: 'flex', gap: 4 }}>
              {(['all', 'fail', 'pass', 'pending'] as const).map(st => (
                <button
                  key={st}
                  type="button"
                  data-testid={`assessments-status-filter-${st}`}
                  onClick={() => handleStatusChange(st)}
                  style={{
                    fontSize: 11,
                    padding: '4px 10px',
                    borderRadius: 4,
                    border: '1px solid',
                    borderColor: statusFilter === st ? 'var(--cyan)' : 'var(--border)',
                    background: statusFilter === st ? 'rgba(6, 182, 212, 0.15)' : 'var(--surface)',
                    color: statusFilter === st ? 'var(--cyan)' : 'var(--muted)',
                    cursor: 'pointer',
                    textTransform: 'capitalize',
                  }}
                >
                  {st}
                </button>
              ))}
            </div>
          </div>
        </div>

        {/* Empty state when 0 controls exist across all frameworks */}
        {frameworkGroups.length === 0 ? (
          <div data-testid="assessments-empty-state">
            <EmptyState
              kicker="No assessment results"
              body="Compliance controls will appear here after the first assessment run."
            />
          </div>
        ) : filteredGroups.length === 0 ? (
          <div className="card" style={{ padding: 24, textAlign: 'center', color: 'var(--muted)', fontSize: 13 }}>
            No controls matched the active search or status filters.
          </div>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
            {filteredGroups.map(fw => {
              return (
                <div
                  key={fw.name}
                  className="card"
                  data-testid={`framework-card-${fw.name.toLowerCase().replace(/[^a-z0-9]/g, '-')}`}
                  style={{ padding: 0, overflow: 'hidden' }}
                >
                  {/* Framework Card Header */}
                  <div
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'space-between',
                      padding: '14px 20px',
                      borderBottom: '1px solid var(--border)',
                      background: 'var(--surface2)',
                    }}
                  >
                    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                      <span style={{ fontWeight: 700, fontSize: 14 }}>{fw.name}</span>
                      <span
                        style={{
                          fontSize: 11,
                          fontWeight: 600,
                          padding: '2px 8px',
                          borderRadius: 12,
                          background: fw.passRate >= 80 ? 'rgba(16, 185, 129, 0.15)' : 'rgba(239, 68, 68, 0.15)',
                          color: fw.passRate >= 80 ? colors.tealLoom : colors.red,
                        }}
                      >
                        {fw.passRate}% Pass Rate
                      </span>
                    </div>

                    <div style={{ display: 'flex', gap: 14, fontSize: 12 }}>
                      <span style={{ color: colors.tealLoom }}>{fw.passing} passing</span>
                      {fw.failing > 0 && <span style={{ color: colors.red }}>{fw.failing} failing</span>}
                      {fw.pending > 0 && <span style={{ color: colors.amber }}>{fw.pending} pending</span>}
                      <span style={{ color: 'var(--muted)' }}>{fw.total} controls</span>
                    </div>
                  </div>

                  {/* Controls List */}
                  <div>
                    {fw.controls.map((c, i) => {
                      const isFail = c.status === 'fail' || c.status === 'non_compliant'
                      const isAlreadyRequested = requestedIds.has(c.control_id) || c.status === 'reassessment_requested'
                      const isRequesting = requestingId === c.control_id

                      return (
                        <div
                          key={c.control_id}
                          data-testid={`control-row-${c.control_id}`}
                          style={{
                            display: 'flex',
                            alignItems: 'center',
                            gap: 14,
                            padding: '12px 20px',
                            borderBottom: i < fw.controls.length - 1 ? '1px solid var(--border)' : 'none',
                            background: isFail ? 'rgba(220, 38, 38, 0.03)' : 'transparent',
                          }}
                        >
                          {/* Status Icon */}
                          <span
                            style={{
                              fontSize: 15,
                              fontWeight: 700,
                              flexShrink: 0,
                              color: statusColorsMap[c.status] ?? colors.muted,
                              width: 20,
                              textAlign: 'center',
                            }}
                          >
                            {statusIcons[c.status] ?? '?'}
                          </span>

                          {/* Control Name & ID */}
                          <div style={{ flex: 1, minWidth: 0 }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                              <span style={{ fontSize: 13, fontWeight: isFail ? 600 : 500, color: 'var(--text)' }}>
                                {c.control_name}
                              </span>
                              <code
                                style={{
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                  color: 'var(--muted)',
                                  background: 'var(--surface2)',
                                  padding: '1px 5px',
                                  borderRadius: 3,
                                }}
                              >
                                {c.control_id}
                              </code>
                            </div>

                            <div style={{ display: 'flex', gap: 14, fontSize: 11, color: 'var(--muted)', marginTop: 3 }}>
                              {c.assessed_at ? (
                                <span>Assessed {fmtDate(c.assessed_at)}</span>
                              ) : (
                                <span style={{ color: 'var(--dim)' }}>Pending assessment</span>
                              )}
                              {c.evidence_ref && (
                                <span style={{ fontFamily: 'monospace', color: 'var(--cyan)' }}>
                                  Evidence: {c.evidence_ref}
                                </span>
                              )}
                            </div>
                          </div>

                          {/* Status Badge */}
                          <StatusBadge status={c.status} variant="compliance" />

                          {/* Reassessment Action */}
                          {isFail && (
                            <button
                              type="button"
                              className="btn btn-secondary"
                              data-testid={`reassess-btn-${c.control_id}`}
                              style={{ fontSize: 11, padding: '4px 12px', flexShrink: 0 }}
                              disabled={isAlreadyRequested || isRequesting || isSourceUnavailable}
                              onClick={() => handleReassess(c.control_id)}
                            >
                              {isRequesting
                                ? 'Requesting…'
                                : isAlreadyRequested
                                ? 'Requested'
                                : 'Request Reassessment'}
                            </button>
                          )}
                        </div>
                      )
                    })}
                  </div>
                </div>
              )
            })}
          </div>
        )}
      </section>
    </div>
  )
}
