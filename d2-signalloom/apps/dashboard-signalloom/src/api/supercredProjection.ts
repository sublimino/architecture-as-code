// Projections of the SuperCred demo state onto the main pages' API responses.
//
// This module is the reason no main page contains a line of demo-specific
// code. Every function here is pure: given the response the API (or the demo
// fixture) produced, plus the observed demo state, it returns the response the
// dashboard should render. client.ts applies them at its single request choke
// point, so AgentsPage, Compliance, CompliancePolicyPage, AgentPosturePage,
// RiskExposurePage and AuditTrail keep rendering exactly what the data layer
// reports and know nothing about the demo.
//
// Two invariants hold throughout:
//   1. At phase 'absent' every projection is the identity function. Nothing
//      leaks into a dashboard that is not running the demo.
//   2. Nothing is mutated in place. Responses are cloned, because the same
//      fixture object is handed out repeatedly in demo-data mode and an
//      in-place edit would compound on every poll.

import {
  carriedGbp,
  complianceTally,
  controlCarriedGbp,
  controlStatus,
  evaluatedControls,
  postureScore,
} from './supercredControls'
import type { SuperCredControl } from './supercredControls'
import type { SuperCredDemoState } from './supercredTypes'
import type {
  AgentListResponse,
  AgentPosture,
  AgentResponse,
  ComplianceSummaryResponse,
  PostureResponse,
  TenantSettingsResponse,
} from '../types/api'
import type { ComplianceCheck, FrameworkSummary, PostureSummary } from '../types/compliance'
import type { AuditListResponse } from '../types/api'
import { projectAudit } from './supercredAudit'

/** Response shape of POST /compliance/policy/scan. */
export interface PolicyScanResponse {
  checks: ComplianceCheck[]
  summary: PostureSummary
}

/**
 * Stable id for the SuperCred agent's governance record.
 *
 * Namespaced so it cannot collide with a real tenant-scoped agent id, and
 * constant across live and demo-data modes so deep links keep working.
 */
export const SUPERCRED_AGENT_ID = 'supercred:agent-cardvault'

const CALIBRATION = 'industry-indicative'
const POLICY_VERSION = 'v2.1'
const CHECK_PREFIX = '[cardvault-agent] '

/** Framework id used by the policy-compliance fixtures, keyed by display name. */
const FRAMEWORK_IDS: Record<string, string> = {
  'EU AI Act': 'eu-ai-act',
  'NIST 800-53': 'nist-800-53',
}

const isObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v)

/** True when the demo is running and there is something to project. */
function isActive(state: SuperCredDemoState): boolean {
  return state.phase !== 'absent' && state.agent !== null
}

// ─── /agents ─────────────────────────────────────────────────────────────────

/**
 * The lifecycle state the governance record should show at each step.
 *
 * Mirrors what the platform actually did: the agent is registered but not yet
 * exercised (enrolled), running on a verified credential chain (active), and
 * finally isolated by the stun (suspended).
 */
function lifecycleState(state: SuperCredDemoState): string {
  switch (state.phase) {
    case 'deployed': return 'enrolled'
    case 'credentialed': return 'active'
    case 'non-compliant': return 'active'
    case 'stunned': return 'suspended'
    default: return 'enrolled'
  }
}

/** Build the governance record for the cluster-observed SuperCred agent. */
export function buildSuperCredAgent(state: SuperCredDemoState): AgentResponse | null {
  if (!isActive(state)) return null
  const observed = state.agent!
  const tally = complianceTally(state.phase)

  return {
    id: SUPERCRED_AGENT_ID,
    name: observed.name || 'Cardvault Agent',
    type: observed.type || 'Signal Loom Built',
    owner: 'platform-security',
    tenant_id: 'supercred',
    lifecycle_state: lifecycleState(state),
    // The stun is the most recent governance action once it has happened.
    last_transition_at: observed.stunned_at || state.observedAt,
    last_transition_by: state.phase === 'stunned' ? 'signal-loom-platform' : 'demo-operator',
    // The agent holds credentials for a card-data service, so it is high risk
    // under the EU AI Act regardless of how far the demo has progressed.
    eu_ai_act_risk_class: 'high',
    compliance_summary: {
      total_controls: tally.total,
      passing: tally.passing,
      failing: tally.failing,
      pending: tally.pending,
      posture_score: postureScore(state.phase),
    },
    model_name: observed.model ?? null,
    created_at: observed.created_at ?? null,
  }
}

export function projectAgentList(base: AgentListResponse, state: SuperCredDemoState): AgentListResponse {
  if (!isActive(state)) return base
  if (!isObject(base) || !Array.isArray(base.agents)) return base

  const agent = buildSuperCredAgent(state)
  if (!agent) return base

  const agents = [...(base.agents as AgentResponse[]).filter((a) => a?.id !== SUPERCRED_AGENT_ID), agent]
  return { ...base, agents, total: agents.length } as AgentListResponse
}

/** Resolve GET /agents/{id} for the SuperCred agent so its table row links somewhere. */
export function projectAgentDetail(
  id: string,
  base: AgentResponse | null,
  state: SuperCredDemoState,
): AgentResponse | null {
  if (id !== SUPERCRED_AGENT_ID) return base
  return buildSuperCredAgent(state)
}

// ─── /compliance ─────────────────────────────────────────────────────────────

export function projectComplianceSummary(base: ComplianceSummaryResponse, state: SuperCredDemoState): ComplianceSummaryResponse {
  if (!isActive(state)) return base
  if (!isObject(base)) return base

  const tally = complianceTally(state.phase)
  const assessed = tally.passing + tally.failing > 0 ? 1 : 0

  return {
    ...base,
    total_agents: Number(base.total_agents ?? 0) + 1,
    agents_assessed: Number(base.agents_assessed ?? 0) + assessed,
    controls_passing: Number(base.controls_passing ?? 0) + tally.passing,
    controls_failing: Number(base.controls_failing ?? 0) + tally.failing,
    controls_pending: Number(base.controls_pending ?? 0) + tally.pending,
  } as ComplianceSummaryResponse
}

export function projectPosture(base: PostureResponse, state: SuperCredDemoState): PostureResponse {
  if (!isActive(state)) return base
  if (!isObject(base) || !Array.isArray(base.agents)) return base

  const assessedAt = state.observedAt
  const row: AgentPosture = {
    agent_id: SUPERCRED_AGENT_ID,
    agent_name: state.agent!.name || 'Cardvault Agent',
    posture_score: postureScore(state.phase),
    results: evaluatedControls(state.phase).map((c) => ({
      agent_id: SUPERCRED_AGENT_ID,
      control_id: c.control,
      control_name: c.name,
      framework_name: c.framework,
      status: controlStatus(c, state.phase),
      assessed_at: assessedAt,
      evidence_ref: `supercred://${state.agent!.namespace ?? 'cluster'}/${c.id}`,
    })),
  }

  const agents = [
    ...(base.agents as AgentPosture[]).filter((a) => a?.agent_id !== SUPERCRED_AGENT_ID),
    row,
  ]
  return { ...base, agents } as PostureResponse
}

// ─── /compliance/policy ──────────────────────────────────────────────────────

function toCheck(control: SuperCredControl, state: SuperCredDemoState): ComplianceCheck {
  return {
    framework: control.framework,
    controlSet: control.controlSet,
    control: control.control,
    check: `${CHECK_PREFIX}${control.name}`,
    passed: controlStatus(control, state.phase) === 'pass',
    policyVersion: POLICY_VERSION,
    ale: control.ale,
    var95: control.var95,
    tvar: control.tvar,
    carriedGbp: controlCarriedGbp(control, state.phase),
    scanTimestamp: state.observedAt ?? new Date().toISOString(),
    calibrationSource: CALIBRATION,
  }
}

/** The SuperCred checks that have been evaluated at the current phase. */
export function superCredChecks(state: SuperCredDemoState): ComplianceCheck[] {
  if (!isActive(state)) return []
  return evaluatedControls(state.phase).map((c) => toCheck(c, state))
}

function projectFrameworkSummary(fw: FrameworkSummary, state: SuperCredDemoState): FrameworkSummary {
  const mine = evaluatedControls(state.phase).filter((c) => FRAMEWORK_IDS[c.framework] === fw.id)
  if (mine.length === 0) return fw

  const passed = mine.filter((c) => controlStatus(c, state.phase) === 'pass').length
  return {
    ...fw,
    totalControls: fw.totalControls + mine.length,
    passedControls: fw.passedControls + passed,
    failedControls: fw.failedControls + (mine.length - passed),
    totalExposureGbp:
      fw.totalExposureGbp + mine.reduce((s, c) => s + controlCarriedGbp(c, state.phase), 0),
  }
}

export function projectPolicyFrameworks(base: FrameworkSummary[], state: SuperCredDemoState): FrameworkSummary[] {
  if (!isActive(state)) return base
  if (!Array.isArray(base)) return base
  return base.map((fw) => (isObject(fw) ? projectFrameworkSummary(fw, state) : fw))
}

export function projectPolicySummary(base: PostureSummary, state: SuperCredDemoState): PostureSummary {
  if (!isActive(state)) return base
  if (!isObject(base)) return base

  const evaluated = evaluatedControls(state.phase)
  const passed = evaluated.filter((c) => controlStatus(c, state.phase) === 'pass').length
  const frameworks = Array.isArray(base.frameworks)
    ? base.frameworks.map((fw) => projectFrameworkSummary(fw, state))
    : base.frameworks

  return {
    ...base,
    totalChecks: Number(base.totalChecks ?? 0) + evaluated.length,
    passed: Number(base.passed ?? 0) + passed,
    failed: Number(base.failed ?? 0) + (evaluated.length - passed),
    // Inherent risk accrues for every evaluated control, passing or failing —
    // matching how the baseline fixtures aggregate ALE across all checks.
    totalAle: Number(base.totalAle ?? 0) + evaluated.reduce((s, c) => s + c.ale, 0),
    totalVar95: Number(base.totalVar95 ?? 0) + evaluated.reduce((s, c) => s + c.var95, 0),
    totalTvar: Number(base.totalTvar ?? 0) + evaluated.reduce((s, c) => s + c.tvar, 0),
    // Carried (residual) risk only accrues for failures, and drops to the
    // containment residual once the agent is stunned.
    totalCarriedGbp: Number(base.totalCarriedGbp ?? 0) + carriedGbp(state.phase),
    frameworks,
  } as PostureSummary
}

export function projectPolicyScan(base: PolicyScanResponse, state: SuperCredDemoState): PolicyScanResponse {
  if (!isActive(state)) return base
  if (!isObject(base)) return base

  const checks = Array.isArray(base.checks)
    ? [...base.checks, ...superCredChecks(state)]
    : base.checks
  const summary = isObject(base.summary) ? projectPolicySummary(base.summary, state) : base.summary

  return { ...base, checks, summary }
}

// ─── /tenant/settings ────────────────────────────────────────────────────────

export function projectTenantSettings(base: TenantSettingsResponse, state: SuperCredDemoState): TenantSettingsResponse {
  if (!isActive(state)) return base
  if (!isObject(base)) return base
  return { ...base, agent_count: Number(base.agent_count ?? 0) + 1 }
}

// ─── Dispatcher ──────────────────────────────────────────────────────────────

const AGENT_DETAIL_RE = /^\/agents\/([^/]+)$/

const PROJECTED_GETS = new Set([
  '/agents',
  '/audit',
  '/compliance/summary',
  '/compliance/posture',
  '/compliance/policy/frameworks',
  '/compliance/policy/summary',
  '/tenant/settings',
])

/**
 * Cheap synchronous test for whether a request is worth observing the demo for.
 *
 * client.ts uses this to avoid awaiting (and therefore polling) the SuperCred
 * proxy on the ~30 endpoints the demo does not touch.
 */
export function affectsDemo(method: string, path: string): boolean {
  const clean = path.replace(/^\/api/, '').split('?')[0]
  const verb = method.toUpperCase()
  if (verb === 'GET') return PROJECTED_GETS.has(clean) || AGENT_DETAIL_RE.test(clean)
  if (verb === 'POST') return clean === '/compliance/policy/scan'
  return false
}

/**
 * Apply the demo projection for a single API response.
 *
 * `path` is the raw path passed to req() in client.ts; the /api prefix and any
 * query string are stripped before matching, mirroring resolveFake().
 */
export function projectResponse(
  method: string,
  path: string,
  data: unknown,
  state: SuperCredDemoState,
): unknown {
  if (!isActive(state)) return data

  const clean = path.replace(/^\/api/, '').split('?')[0]
  const verb = method.toUpperCase()

  // The dispatcher is the one place that accepts `unknown`: it is fed raw HTTP
  // responses. Each projection re-validates the shape it was handed and returns
  // the input untouched if it does not match, so these casts cannot smuggle a
  // malformed payload past a guard.
  if (verb === 'GET') {
    switch (clean) {
      case '/agents': return projectAgentList(data as AgentListResponse, state)
      case '/audit': return projectAudit(data as AuditListResponse, state)
      case '/compliance/summary': return projectComplianceSummary(data as ComplianceSummaryResponse, state)
      case '/compliance/posture': return projectPosture(data as PostureResponse, state)
      case '/compliance/policy/frameworks': return projectPolicyFrameworks(data as FrameworkSummary[], state)
      case '/compliance/policy/summary': return projectPolicySummary(data as PostureSummary, state)
      case '/tenant/settings': return projectTenantSettings(data as TenantSettingsResponse, state)
    }
    const detail = AGENT_DETAIL_RE.exec(clean)
    if (detail) return projectAgentDetail(decodeURIComponent(detail[1]), data as AgentResponse | null, state)
  }

  if (verb === 'POST' && clean === '/compliance/policy/scan') {
    return projectPolicyScan(data as PolicyScanResponse, state)
  }

  return data
}
