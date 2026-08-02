import { describe, it, expect } from 'vitest'
import {
  SUPERCRED_AGENT_ID,
  projectAgentDetail,
  projectAgentList,
  projectComplianceSummary,
  projectPolicyFrameworks,
  projectPolicyScan,
  projectPolicySummary,
  projectPosture,
  projectResponse,
  projectTenantSettings,
} from './supercredProjection'
import { SUPERCRED_CONTROLS, carriedGbp, complianceTally, postureScore } from './supercredControls'
import type { SuperCredDemoState, SuperCredPhase } from './supercredTypes'
import type {
  AgentListResponse,
  AgentResponse,
  ComplianceSummaryResponse,
  PostureResponse,
  TenantSettingsResponse,
} from '../types/api'
import type { FrameworkSummary, PostureSummary } from '../types/compliance'

// ─── Fixtures ────────────────────────────────────────────────────────────────

function stateAt(phase: SuperCredPhase): SuperCredDemoState {
  return {
    phase,
    agent: phase === 'absent' ? null : {
      id: 'agent-cardvault',
      name: 'Cardvault Agent',
      namespace: 'fe-signalloom-agents',
      supercred: true,
      model: 'gpt-4o',
      state: phase === 'stunned' ? 'stunned' : phase === 'credentialed' ? 'active' : null,
      stunned_at: phase === 'stunned' ? '2026-08-02T10:05:00Z' : null,
      stun_reason: phase === 'stunned' ? 'compliance-failure: securityContext not set' : null,
    },
    scan: null,
    observedAt: '2026-08-02T10:00:00Z',
  }
}

const ALL_PHASES: SuperCredPhase[] = ['absent', 'deployed', 'credentialed', 'non-compliant', 'stunned']
const LIVE_PHASES: SuperCredPhase[] = ['deployed', 'credentialed', 'non-compliant', 'stunned']

function baseAgent(id: string): AgentResponse {
  return {
    id, name: 'Existing Agent', type: 'COTS', owner: 'demo-user', tenant_id: 'tenant-demo',
    lifecycle_state: 'active', last_transition_at: null, eu_ai_act_risk_class: 'limited',
    compliance_summary: { total_controls: 12, passing: 10, failing: 0, pending: 2, posture_score: 83 },
    created_at: null,
  }
}

const baseAgentList: AgentListResponse = { agents: [baseAgent('tenant-demo:a1')], total: 1 }

const baseComplianceSummary: ComplianceSummaryResponse = {
  total_agents: 1, agents_assessed: 1,
  controls_passing: 28, controls_failing: 6, controls_pending: 5, posture_score: 74,
}

const basePosture: PostureResponse = {
  agents: [{ agent_id: 'tenant-demo:a1', agent_name: 'Existing Agent', posture_score: 83, results: [] }],
}

const baseFrameworks: FrameworkSummary[] = [
  { id: 'eu-ai-act', name: 'EU AI Act', versions: ['v2.0', 'v2.1'], totalControls: 10, passedControls: 7, failedControls: 3, totalExposureGbp: 53200 },
  { id: 'nist-800-53', name: 'NIST 800-53', versions: ['v2.0', 'v2.1'], totalControls: 10, passedControls: 8, failedControls: 2, totalExposureGbp: 45500 },
]

const basePolicySummary: PostureSummary = {
  totalChecks: 20, passed: 15, failed: 5,
  totalAle: 195500, totalVar95: 858000, totalTvar: 1332000, totalCarriedGbp: 98700,
  scanTimestamp: '2026-07-27T12:00:00Z',
  frameworks: baseFrameworks,
}

const baseSettings: TenantSettingsResponse = {
  tenant_id: 'tenant-demo', org_name: 'Acme Co. (demo)', plan_tier: 'enterprise', agent_count: 6,
  billing_tier: 'enterprise', api_key_status: 'active', selected_frameworks: ['eu-ai-act'],
  consent_required: false, cookie_preferences: null, preferred_scan_cadence_hours: 24,
  alert_email: null, alert_threshold: 1,
}

// ─── /agents ─────────────────────────────────────────────────────────────────

describe('projectAgentList — the Agents page', () => {
  it('leaves the list untouched before step 1 and after teardown', () => {
    expect(projectAgentList(baseAgentList, stateAt('absent'))).toEqual(baseAgentList)
  })

  it('adds the SuperCred agent from step 1 onward', () => {
    for (const phase of LIVE_PHASES) {
      const result = projectAgentList(baseAgentList, stateAt(phase))
      expect(result.agents).toHaveLength(2)
      expect(result.total).toBe(2)
      expect(result.agents.some((a) => a.id === SUPERCRED_AGENT_ID)).toBe(true)
    }
  })

  it('never mutates the response it was handed', () => {
    const input: AgentListResponse = { agents: [baseAgent('tenant-demo:a1')], total: 1 }
    projectAgentList(input, stateAt('stunned'))
    expect(input.agents).toHaveLength(1)
    expect(input.total).toBe(1)
  })

  it('walks the lifecycle state across the demo steps', () => {
    const lifecycleAt = (phase: SuperCredPhase) =>
      projectAgentList(baseAgentList, stateAt(phase)).agents
        .find((a) => a.id === SUPERCRED_AGENT_ID)!.lifecycle_state

    expect(lifecycleAt('deployed')).toBe('enrolled')
    expect(lifecycleAt('credentialed')).toBe('active')
    expect(lifecycleAt('non-compliant')).toBe('active')
    expect(lifecycleAt('stunned')).toBe('suspended')
  })

  it('surfaces the failing controls that drive the Agents attention panel at step 3', () => {
    const agent = projectAgentList(baseAgentList, stateAt('non-compliant')).agents
      .find((a) => a.id === SUPERCRED_AGENT_ID)!
    expect(agent.compliance_summary.failing).toBe(3)
    expect(agent.compliance_summary.posture_score).toBe(postureScore('non-compliant'))
  })

  it('shows no failing controls before the scan runs', () => {
    for (const phase of ['deployed', 'credentialed'] as SuperCredPhase[]) {
      const agent = projectAgentList(baseAgentList, stateAt(phase)).agents
        .find((a) => a.id === SUPERCRED_AGENT_ID)!
      expect(agent.compliance_summary.failing).toBe(0)
    }
  })

  it('records the stun timestamp as the last transition at step 4', () => {
    const agent = projectAgentList(baseAgentList, stateAt('stunned')).agents
      .find((a) => a.id === SUPERCRED_AGENT_ID)!
    expect(agent.last_transition_at).toBe('2026-08-02T10:05:00Z')
  })

  it('keeps the compliance summary consistent with the control tally at every phase', () => {
    for (const phase of LIVE_PHASES) {
      const agent = projectAgentList(baseAgentList, stateAt(phase)).agents
        .find((a) => a.id === SUPERCRED_AGENT_ID)!
      const tally = complianceTally(phase)
      expect(agent.compliance_summary).toEqual({
        total_controls: tally.total,
        passing: tally.passing,
        failing: tally.failing,
        pending: tally.pending,
        posture_score: postureScore(phase),
      })
    }
  })
})

describe('projectAgentDetail', () => {
  it('resolves the SuperCred agent by id so the Agents table row links somewhere', () => {
    const detail = projectAgentDetail(SUPERCRED_AGENT_ID, null, stateAt('credentialed'))
    expect(detail).not.toBeNull()
    expect(detail!.id).toBe(SUPERCRED_AGENT_ID)
  })

  it('passes other agents through untouched', () => {
    const other = baseAgent('tenant-demo:a1')
    expect(projectAgentDetail('tenant-demo:a1', other, stateAt('credentialed'))).toBe(other)
  })

  it('does not resurrect the agent after teardown', () => {
    expect(projectAgentDetail(SUPERCRED_AGENT_ID, null, stateAt('absent'))).toBeNull()
  })
})

// ─── /compliance ─────────────────────────────────────────────────────────────

describe('projectComplianceSummary — the Compliance page and sidebar badge', () => {
  it('is inert before step 1', () => {
    expect(projectComplianceSummary(baseComplianceSummary, stateAt('absent'))).toEqual(baseComplianceSummary)
  })

  it('raises the failing-control count when the scan lands at step 3', () => {
    const before = projectComplianceSummary(baseComplianceSummary, stateAt('credentialed'))
    const after = projectComplianceSummary(baseComplianceSummary, stateAt('non-compliant'))
    expect(before.controls_failing).toBe(6)
    expect(after.controls_failing).toBe(9)
  })

  it('counts the SuperCred agent in the estate from step 1', () => {
    const result = projectComplianceSummary(baseComplianceSummary, stateAt('deployed'))
    expect(result.total_agents).toBe(2)
  })

  it('adds the passing response controls at step 4', () => {
    const before = projectComplianceSummary(baseComplianceSummary, stateAt('non-compliant'))
    const after = projectComplianceSummary(baseComplianceSummary, stateAt('stunned'))
    expect(after.controls_passing).toBe(before.controls_passing + 2)
  })
})

describe('projectPosture — the Compliance page agent table', () => {
  it('is inert before step 1', () => {
    expect(projectPosture(basePosture, stateAt('absent'))).toEqual(basePosture)
  })

  it('adds a posture row for the SuperCred agent from step 1', () => {
    for (const phase of LIVE_PHASES) {
      const result = projectPosture(basePosture, stateAt(phase))
      expect(result.agents).toHaveLength(2)
      expect(result.agents.some((a) => a.agent_id === SUPERCRED_AGENT_ID)).toBe(true)
    }
  })

  it('reports only controls that have been evaluated', () => {
    const resultsAt = (phase: SuperCredPhase) =>
      projectPosture(basePosture, stateAt(phase)).agents
        .find((a) => a.agent_id === SUPERCRED_AGENT_ID)!.results

    expect(resultsAt('deployed')).toHaveLength(3)
    expect(resultsAt('credentialed')).toHaveLength(7)
    expect(resultsAt('non-compliant')).toHaveLength(10)
    expect(resultsAt('stunned')).toHaveLength(12)
  })

  it('marks the three runtime findings as failed at step 3', () => {
    const results = projectPosture(basePosture, stateAt('non-compliant')).agents
      .find((a) => a.agent_id === SUPERCRED_AGENT_ID)!.results
    expect(results.filter((r) => r.status === 'fail')).toHaveLength(3)
  })

  it('moves the SuperCred agent into the critical donut band at step 3', () => {
    // Compliance.tsx categorises a score below 50 as critical.
    const scoreAt = (phase: SuperCredPhase) =>
      projectPosture(basePosture, stateAt(phase)).agents
        .find((a) => a.agent_id === SUPERCRED_AGENT_ID)!.posture_score

    expect(scoreAt('credentialed')!).toBeGreaterThanOrEqual(50)
    expect(scoreAt('non-compliant')!).toBeLessThan(50)
    expect(scoreAt('stunned')!).toBeGreaterThanOrEqual(50)
  })
})

// ─── /compliance/policies and /compliance/posture ────────────────────────────

describe('projectPolicySummary — Policy Compliance stat cards', () => {
  it('is inert before step 1', () => {
    expect(projectPolicySummary(basePolicySummary, stateAt('absent'))).toEqual(basePolicySummary)
  })

  it('grows the total check count as each step is evaluated', () => {
    const totalAt = (phase: SuperCredPhase) => projectPolicySummary(basePolicySummary, stateAt(phase)).totalChecks
    expect(totalAt('deployed')).toBe(23)
    expect(totalAt('credentialed')).toBe(27)
    expect(totalAt('non-compliant')).toBe(30)
    expect(totalAt('stunned')).toBe(32)
  })

  it('raises the failed count by exactly the three runtime findings at step 3', () => {
    expect(projectPolicySummary(basePolicySummary, stateAt('credentialed')).failed).toBe(5)
    expect(projectPolicySummary(basePolicySummary, stateAt('non-compliant')).failed).toBe(8)
  })

  it('keeps passed + failed equal to totalChecks', () => {
    for (const phase of ALL_PHASES) {
      const s = projectPolicySummary(basePolicySummary, stateAt(phase))
      expect(s.passed + s.failed).toBe(s.totalChecks)
    }
  })

  it('spikes carried exposure at step 3 and contains it at step 4', () => {
    const carriedAt = (phase: SuperCredPhase) =>
      projectPolicySummary(basePolicySummary, stateAt(phase)).totalCarriedGbp

    expect(carriedAt('credentialed')).toBe(98700)
    expect(carriedAt('non-compliant')).toBe(98700 + carriedGbp('non-compliant'))
    expect(carriedAt('stunned')).toBe(98700 + carriedGbp('stunned'))
    expect(carriedAt('stunned')).toBeLessThan(carriedAt('non-compliant'))
    expect(carriedAt('stunned')).toBeGreaterThan(carriedAt('credentialed'))
  })

  it('adds inherent risk for every evaluated control, passing or failing', () => {
    const evaluatedAle = SUPERCRED_CONTROLS
      .filter((c) => c.group === 'governance')
      .reduce((s, c) => s + c.ale, 0)
    expect(projectPolicySummary(basePolicySummary, stateAt('deployed')).totalAle)
      .toBe(195500 + evaluatedAle)
  })

  it('keeps per-framework totals summing to the estate totals', () => {
    for (const phase of ALL_PHASES) {
      const s = projectPolicySummary(basePolicySummary, stateAt(phase))
      const fwControls = s.frameworks.reduce((n, f) => n + f.totalControls, 0)
      const fwPassed = s.frameworks.reduce((n, f) => n + f.passedControls, 0)
      const fwExposure = s.frameworks.reduce((n, f) => n + f.totalExposureGbp, 0)
      expect(fwControls).toBe(s.totalChecks)
      expect(fwPassed).toBe(s.passed)
      expect(fwExposure).toBe(s.totalCarriedGbp)
    }
  })
})

describe('projectPolicyFrameworks — Policy Compliance framework cards', () => {
  it('is inert before step 1', () => {
    expect(projectPolicyFrameworks(baseFrameworks, stateAt('absent'))).toEqual(baseFrameworks)
  })

  it('grows the NIST control count as identity and runtime checks land', () => {
    const nistAt = (phase: SuperCredPhase) =>
      projectPolicyFrameworks(baseFrameworks, stateAt(phase)).find((f) => f.id === 'nist-800-53')!

    expect(nistAt('deployed').totalControls).toBe(10)
    expect(nistAt('credentialed').totalControls).toBe(14)
    expect(nistAt('non-compliant').totalControls).toBe(17)
    expect(nistAt('non-compliant').failedControls).toBe(5)
  })

  it('grows the EU AI Act control count on deploy and on stun', () => {
    const euAt = (phase: SuperCredPhase) =>
      projectPolicyFrameworks(baseFrameworks, stateAt(phase)).find((f) => f.id === 'eu-ai-act')!

    expect(euAt('deployed').totalControls).toBe(13)
    expect(euAt('credentialed').totalControls).toBe(13)
    expect(euAt('stunned').totalControls).toBe(15)
    expect(euAt('stunned').passedControls).toBe(euAt('non-compliant').passedControls + 2)
  })

  it('does not invent a framework the customer has not adopted', () => {
    for (const phase of ALL_PHASES) {
      const ids = projectPolicyFrameworks(baseFrameworks, stateAt(phase)).map((f) => f.id)
      expect(ids.sort()).toEqual(['eu-ai-act', 'nist-800-53'])
    }
  })
})

describe('projectPolicyScan — Agent Posture check rows and Risk Exposure aggregates', () => {
  const baseScan = { checks: [], summary: basePolicySummary }

  it('is inert before step 1', () => {
    expect(projectPolicyScan(baseScan, stateAt('absent'))).toEqual(baseScan)
  })

  it('emits one check row per evaluated control', () => {
    expect(projectPolicyScan(baseScan, stateAt('deployed')).checks).toHaveLength(3)
    expect(projectPolicyScan(baseScan, stateAt('stunned')).checks).toHaveLength(12)
  })

  it('files every check under an existing control set so the page groups them naturally', () => {
    const sets = new Set(projectPolicyScan(baseScan, stateAt('stunned')).checks.map((c) => c.controlSet))
    expect(sets).toContain('Identification & Auth')
    expect(sets).toContain('System & Comms Protection')
    expect(sets).toContain('Human Oversight')
  })

  it('labels the checks so an operator can see which agent they belong to', () => {
    for (const c of projectPolicyScan(baseScan, stateAt('stunned')).checks) {
      expect(c.check).toMatch(/^\[cardvault-agent\] /)
    }
  })

  it('carries per-check exposure that sums to the aggregate', () => {
    for (const phase of LIVE_PHASES) {
      const { checks } = projectPolicyScan(baseScan, stateAt(phase))
      const sum = checks.reduce((s, c) => s + c.carriedGbp, 0)
      expect(sum).toBe(carriedGbp(phase))
    }
  })

  it('keeps the summary consistent with the checks it returns', () => {
    for (const phase of LIVE_PHASES) {
      const { checks, summary } = projectPolicyScan(baseScan, stateAt(phase))
      expect(summary.totalChecks).toBe(basePolicySummary.totalChecks + checks.length)
    }
  })
})

// ─── /tenant/settings (sidebar agent-count badge) ────────────────────────────

describe('projectTenantSettings — the sidebar Agents badge', () => {
  it('is inert before step 1', () => {
    expect(projectTenantSettings(baseSettings, stateAt('absent'))).toEqual(baseSettings)
  })

  it('increments the agent count while the demo agent exists', () => {
    expect(projectTenantSettings(baseSettings, stateAt('deployed')).agent_count).toBe(7)
    expect(projectTenantSettings(baseSettings, stateAt('stunned')).agent_count).toBe(7)
  })
})

// ─── Dispatcher ──────────────────────────────────────────────────────────────

describe('projectResponse — the single interception point in client.ts', () => {
  it('returns unknown paths untouched', () => {
    const payload = { anything: true }
    expect(projectResponse('GET', '/nhi/scans', payload, stateAt('stunned'))).toBe(payload)
  })

  it('returns everything untouched while the demo is not running', () => {
    expect(projectResponse('GET', '/agents', baseAgentList, stateAt('absent'))).toBe(baseAgentList)
    expect(projectResponse('GET', '/compliance/summary', baseComplianceSummary, stateAt('absent')))
      .toBe(baseComplianceSummary)
  })

  it('routes each demo-affected endpoint to its projection', () => {
    const state = stateAt('non-compliant')

    const agents = projectResponse('GET', '/agents', baseAgentList, state) as AgentListResponse
    expect(agents.agents).toHaveLength(2)

    const summary = projectResponse('GET', '/compliance/summary', baseComplianceSummary, state) as ComplianceSummaryResponse
    expect(summary.controls_failing).toBe(9)

    const posture = projectResponse('GET', '/compliance/posture', basePosture, state) as PostureResponse
    expect(posture.agents).toHaveLength(2)

    const fw = projectResponse('GET', '/compliance/policy/frameworks', baseFrameworks, state) as FrameworkSummary[]
    expect(fw.find((f) => f.id === 'nist-800-53')!.totalControls).toBe(17)

    const policySummary = projectResponse('GET', '/compliance/policy/summary', basePolicySummary, state) as PostureSummary
    expect(policySummary.totalChecks).toBe(30)

    const scan = projectResponse('POST', '/compliance/policy/scan', { checks: [], summary: basePolicySummary }, state) as { checks: unknown[] }
    expect(scan.checks).toHaveLength(10)

    const settings = projectResponse('GET', '/tenant/settings', baseSettings, state) as TenantSettingsResponse
    expect(settings.agent_count).toBe(7)
  })

  it('tolerates a query string on the path', () => {
    const agents = projectResponse('GET', '/agents?page=1', baseAgentList, stateAt('deployed')) as AgentListResponse
    expect(agents.agents).toHaveLength(2)
  })

  it('tolerates the /api prefix', () => {
    const agents = projectResponse('GET', '/api/agents', baseAgentList, stateAt('deployed')) as AgentListResponse
    expect(agents.agents).toHaveLength(2)
  })

  it('never throws on a malformed payload — a broken projection must not break the page', () => {
    for (const path of ['/agents', '/compliance/summary', '/compliance/posture', '/compliance/policy/summary']) {
      expect(() => projectResponse('GET', path, null, stateAt('stunned'))).not.toThrow()
      expect(() => projectResponse('GET', path, 'garbage', stateAt('stunned'))).not.toThrow()
    }
  })
})
