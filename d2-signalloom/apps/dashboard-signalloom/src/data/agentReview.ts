import type { AgentResponse } from '../types/api'
import { isFrozenWithoutStun } from '../components/StatusBadge'

export type AgentReviewCategory = 'failing-controls' | 'critical-posture' | 'containment-unconfirmed' | 'kernel-split-brain' | 'server-attention'
export interface AgentReviewIssue {
  id: string
  agentId: string
  agentName: string
  responsibility: string
  category: AgentReviewCategory
  severity: 'critical' | 'warning'
  reason: string
  description: string
  detailTab: 'assessments' | 'access'
  evidenceAt?: string
}
const normalized = (value?: string | null) => value?.trim().toLowerCase() ?? ''
const evidenceTime = (value?: string | null) => value && Number.isFinite(Date.parse(value)) ? value : undefined

/** Both API score scales are supported; unknown/invalid scores are not findings. */
export function normalizeReviewPosture(score: unknown): number | null {
  if (typeof score !== 'number' || !Number.isFinite(score) || score < 0 || score > 100) return null
  return score <= 1 ? score * 100 : score
}

/** Resolve requested planes against their own evidence, before formatting a queue issue.
 * Credential `requested` is itself the API's unresolved audit outcome, whereas
 * process/network requests may be resolved by a newer independent kernel view.
 */
function deriveContainmentReview(agent: AgentResponse) {
  const containment = agent.operational_state?.containment
  const legacyRequest = normalized(agent.lifecycle_state) === 'stunned' ||
    ['stopped', 'terminated'].includes(normalized(agent.operational_state?.runtime_status)) ||
    normalized(agent.credential_state?.status) === 'revoked'
  const freezeConfirmed = normalized(agent.kernel_state) === 'frozen' ||
    normalized(agent.kernel_telemetry?.cgroup_state) === 'frozen' ||
    (containment?.source === 'sentinel-annotation' && containment.process_freeze === 'active')
  const networkConfirmed = normalized(agent.kernel_telemetry?.traffic_control_state) === 'drop' ||
    (containment?.source === 'sentinel-annotation' && containment.network_isolation === 'active')
  const requestedPlanes = [
    { label: 'Process freeze', required: containment?.process_freeze === 'requested', confirmed: freezeConfirmed },
    { label: 'Network isolation', required: containment?.network_isolation === 'requested', confirmed: networkConfirmed },
    { label: 'Credential revocation', required: containment?.credential_revocation === 'requested', confirmed: false },
  ].filter(plane => plane.required)
  const unresolved = requestedPlanes.filter(plane => !plane.confirmed).map(plane => plane.label)
  // Legacy responses lack per-plane requests. Keep the existing kernel-evidence
  // check, but never let this generic confirmation cancel an explicit request.
  const legacyUnconfirmed = requestedPlanes.length === 0 && legacyRequest && !freezeConfirmed && !networkConfirmed
  if (unresolved.length === 0 && !legacyUnconfirmed) return null
  return {
    processFreezeUnconfirmed: unresolved.includes('Process freeze') || legacyUnconfirmed,
    evidenceAt: evidenceTime(agent.kernel_telemetry?.observed_at),
    description: unresolved.length > 0
      ? `${unresolved.join('; ')} requested but outcome unconfirmed. Other confirmed planes do not resolve these requests.`
      : 'Stopped runtime or revoked credentials has no confirming kernel freeze or network-drop evidence.',
  }
}

export function agentReviewIssues(agent: AgentResponse): AgentReviewIssue[] {
  if (agent.record_class === 'discovery') return [] // shadow records are not in this inventory
  const issues: AgentReviewIssue[] = []
  const add = (category: AgentReviewCategory, severity: AgentReviewIssue['severity'], reason: string, description: string, detailTab: AgentReviewIssue['detailTab'], evidenceAt?: string) => {
    issues.push({ id: `${agent.id}:${category}`, agentId: agent.id, agentName: agent.name || 'Unnamed agent',
      responsibility: [agent.responsibility?.owner_name?.trim() || agent.owner?.trim(), agent.responsibility?.team?.trim()].filter(Boolean).join(' · ') || 'Unassigned',
      category, severity, reason, description, detailTab, evidenceAt })
  }
  const failing = agent.compliance_summary?.failing
  if (typeof failing === 'number' && Number.isFinite(failing) && failing > 0) {
    add('failing-controls', 'critical', 'Failing controls', `${failing} failing control${failing === 1 ? '' : 's'} reported by compliance assessment.`, 'assessments')
  }
  const posture = normalizeReviewPosture(agent.compliance_summary?.posture_score)
  if (posture !== null && posture < 50) {
    add('critical-posture', 'critical', 'Critical posture', `Posture score ${Number(posture.toFixed(1))}% is below the 50% review threshold.`, 'assessments')
  }
  if (isFrozenWithoutStun(agent)) {
    add('kernel-split-brain', 'critical', 'Kernel / control-plane disagreement', 'Kernel frozen without a matching stun record.', 'access', evidenceTime(agent.kernel_observed_at))
  }
  const containmentReview = deriveContainmentReview(agent)
  if (containmentReview) {
    add('containment-unconfirmed', 'warning', 'Containment unconfirmed', containmentReview.description, 'access', containmentReview.evidenceAt)
  }
  const level = agent.attention?.level
  if (level === 'warning' || level === 'critical') {
    const context = agent.attention?.highest_issue?.trim()
    const issueText = normalized(context)
    // The API generates these summaries from the same controls/kernel inputs.
    // Suppress only recognised summaries, not unrelated server finding context.
    const represented = issues.find(issue =>
      (issue.category === 'failing-controls' && /^\d+ failing controls?( detected)?$/.test(issueText)) ||
      (issue.category === 'kernel-split-brain' && issueText === 'kernel frozen without stun record') ||
      (issue.category === 'critical-posture' && issueText === 'critical posture') ||
      (issue.category === 'containment-unconfirmed' && (issueText === 'containment unconfirmed' ||
        (issueText === 'stun record without kernel freeze' && containmentReview?.processFreezeUnconfirmed))))
    if (represented && level === 'critical') represented.severity = 'critical'
    const lifecycleOnly = /^agent state is (suspended|stunned|revoked|enrolled)$/.test(issueText)
    // Null context is emitted for pending/errored controls and failed runtimes;
    // another issue on this agent is not evidence that it covers that finding.
    if (!represented && !lifecycleOnly) {
      add('server-attention', level, 'Server finding', context || `Server reports ${level} attention; no further finding details supplied.`, 'assessments')
    }
  }
  return issues
}

export function needsAgentReview(agent: AgentResponse): boolean {
  return agentReviewIssues(agent).length > 0
}

/** Severity first, then agent ID and category: independent of API ordering/locale. */
export function deriveAgentReview(agents: readonly AgentResponse[]) {
  const byId = new Map(agents.flatMap(agentReviewIssues).map(issue => [issue.id, issue]))
  const rank: Record<AgentReviewCategory, number> = { 'kernel-split-brain': 0, 'failing-controls': 1, 'critical-posture': 2, 'containment-unconfirmed': 3, 'server-attention': 4 }
  const issues = [...byId.values()].sort((a, b) => {
    const severity = Number(a.severity === 'warning') - Number(b.severity === 'warning')
    return severity || (a.agentId < b.agentId ? -1 : a.agentId > b.agentId ? 1 : rank[a.category] - rank[b.category])
  })
  return { issues, affectedAgentCount: new Set(issues.map(issue => issue.agentId)).size }
}
