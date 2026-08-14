// The SuperCred agent's control set — the single source of truth that every
// main-page projection derives from.
//
// Twelve controls in four groups, each group satisfied (or broken) by one step
// of the demo. Deliberately filed under control sets that ALREADY exist in the
// baseline fixtures ('Identification & Auth', 'System & Comms Protection',
// 'Human Oversight') so a customer watching the demo sees their own compliance
// structure move rather than a bolt-on SuperCred section appearing.
//
// The three `runtime` controls are the real checks the policy engine evaluates
// in scripts/supercred-demo.sh step 3 (see the `checks` array in the
// /api/v1/evaluate call): security-context-present, run-as-non-root,
// drop-capabilities. All three fail when the pod has no securityContext.

import type { SuperCredPhase } from './supercredTypes'
import type { CurrencyCode } from '../money/currency'

export type ControlStatus = 'pass' | 'fail' | 'pending'
export type Severity = 'critical' | 'high' | 'medium' | 'low'

/**
 * Which demo step decides this control's fate.
 *
 * - `governance` — satisfied by registering/deploying the agent (step 1)
 * - `identity`   — satisfied by the SPIFFE → OpenBao credential chain (step 2)
 * - `runtime`    — broken by the compliance scan's findings (step 3)
 * - `response`   — proven by the stun actually working (step 4)
 */
export type ControlGroup = 'governance' | 'identity' | 'runtime' | 'response'

export interface SuperCredControl {
  id: string
  /** Control identifier as rendered in compliance tables, e.g. 'IA-4'. */
  control: string
  name: string
  framework: 'EU AI Act' | 'NIST 800-53'
  controlSet: string
  group: ControlGroup
  severity: Severity
  ale: number
  var95: number
  tvar: number
}

const SEVERITY_WEIGHT: Record<Severity, number> = {
  critical: 4,
  high: 3,
  medium: 2,
  low: 1,
}

/**
 * Residual carried risk after a stun, as a fraction of the exposed carried risk.
 *
 * Revoking the OpenBao lease and setting deny-all egress removes the threat
 * actor's *capability* to exploit the finding, but the defect itself (no
 * securityContext on the pod spec) is still there — so the residual is
 * deliberately non-zero. 0.15 is a treatment-effectiveness assumption, not a
 * measurement; it is surfaced in the UI under the existing
 * "industry-indicative" calibration tag.
 */
export const STUN_CONTAINMENT_RESIDUAL = 0.15

export const SUPERCRED_CONTROLS: SuperCredControl[] = [
  // ── Governance — satisfied the moment the agent is deployed (step 1) ──────
  {
    id: 'agent-registered',
    control: 'AIG-1',
    name: 'Agent registered in inventory',
    framework: 'EU AI Act',
    controlSet: 'Agent Inventory',
    group: 'governance',
    severity: 'medium',
    ale: 4200, var95: 18000, tvar: 27000,
  },
  {
    id: 'agent-owner-assigned',
    control: 'AIG-2',
    name: 'Accountable owner assigned',
    framework: 'EU AI Act',
    controlSet: 'Agent Inventory',
    group: 'governance',
    severity: 'low',
    ale: 2600, var95: 11000, tvar: 17000,
  },
  {
    id: 'agent-inventory-tracked',
    control: 'AIG-3',
    name: 'Runtime location continuously tracked',
    framework: 'EU AI Act',
    controlSet: 'Agent Inventory',
    group: 'governance',
    severity: 'medium',
    ale: 5100, var95: 22000, tvar: 34000,
  },

  // ── Identity — satisfied by the SPIFFE → OpenBao chain (step 2) ───────────
  {
    id: 'workload-identity-issued',
    control: 'IA-4',
    name: 'Cryptographic workload identity issued (SPIFFE SVID)',
    framework: 'NIST 800-53',
    controlSet: 'Identification & Auth',
    group: 'identity',
    severity: 'critical',
    ale: 19400, var95: 86000, tvar: 132000,
  },
  {
    id: 'credential-short-lived',
    control: 'IA-5',
    name: 'Credentials are short-lived and auto-expiring',
    framework: 'NIST 800-53',
    controlSet: 'Identification & Auth',
    group: 'identity',
    severity: 'high',
    ale: 13800, var95: 61000, tvar: 94000,
  },
  {
    id: 'credential-scoped',
    control: 'IA-6',
    name: 'Credential scope bound to declared purpose',
    framework: 'NIST 800-53',
    controlSet: 'Identification & Auth',
    group: 'identity',
    severity: 'high',
    ale: 11900, var95: 53000, tvar: 81000,
  },
  {
    id: 'no-static-secrets',
    control: 'IA-7',
    name: 'No static secrets in pod spec or image',
    framework: 'NIST 800-53',
    controlSet: 'Identification & Auth',
    group: 'identity',
    severity: 'critical',
    ale: 24700, var95: 110000, tvar: 169000,
  },

  // ── Runtime — the three real policy-engine checks, broken at step 3 ───────
  {
    id: 'security-context-present',
    control: 'SC-9',
    name: 'Pod securityContext defined',
    framework: 'NIST 800-53',
    controlSet: 'System & Comms Protection',
    group: 'runtime',
    severity: 'critical',
    ale: 28400, var95: 126000, tvar: 194000,
  },
  {
    id: 'run-as-non-root',
    control: 'SC-10',
    name: 'Container runs as non-root',
    framework: 'NIST 800-53',
    controlSet: 'System & Comms Protection',
    group: 'runtime',
    severity: 'critical',
    ale: 21700, var95: 96000, tvar: 148000,
  },
  {
    id: 'drop-capabilities',
    control: 'SC-11',
    name: 'Linux capabilities dropped',
    framework: 'NIST 800-53',
    controlSet: 'System & Comms Protection',
    group: 'runtime',
    severity: 'high',
    ale: 16300, var95: 72000, tvar: 111000,
  },

  // ── Response — proven only when the stun actually works (step 4) ──────────
  {
    id: 'kill-switch-operational',
    control: 'AIO-4',
    name: 'Kill switch verified against a live agent',
    framework: 'EU AI Act',
    controlSet: 'Human Oversight',
    group: 'response',
    severity: 'critical',
    ale: 26100, var95: 116000, tvar: 178000,
  },
  {
    id: 'credential-revocation-tested',
    control: 'AIO-5',
    name: 'Credential revocation verified end-to-end',
    framework: 'EU AI Act',
    controlSet: 'Human Oversight',
    group: 'response',
    severity: 'high',
    ale: 17500, var95: 78000, tvar: 119000,
  },
]

/** Sum of every control's severity weight — the posture score denominator. */
export const SUPERCRED_TOTAL_WEIGHT = SUPERCRED_CONTROLS.reduce(
  (s, c) => s + SEVERITY_WEIGHT[c.severity],
  0,
)

const PHASE_ORDER: Record<SuperCredPhase, number> = {
  absent: 0,
  deployed: 1,
  credentialed: 2,
  'non-compliant': 3,
  stunned: 4,
}

/** Where a failing control sits relative to a passing one in the score. */
const FAIL_PENALTY = 2

export function controlStatus(control: SuperCredControl, phase: SuperCredPhase): ControlStatus {
  const p = PHASE_ORDER[phase]
  switch (control.group) {
    case 'governance':
      return p >= PHASE_ORDER.deployed ? 'pass' : 'pending'
    case 'identity':
      return p >= PHASE_ORDER.credentialed ? 'pass' : 'pending'
    case 'runtime':
      return p >= PHASE_ORDER['non-compliant'] ? 'fail' : 'pending'
    case 'response':
      return p >= PHASE_ORDER.stunned ? 'pass' : 'pending'
  }
}

/**
 * Controls that have actually been evaluated at this phase.
 *
 * A pending control is not a scan result, so it must not appear as a check on
 * Policy Compliance or Agent Posture — otherwise the demo would show findings
 * for work the platform has not done yet.
 */
export function evaluatedControls(phase: SuperCredPhase): SuperCredControl[] {
  return SUPERCRED_CONTROLS.filter((c) => controlStatus(c, phase) !== 'pending')
}

export interface ComplianceTally {
  passing: number
  failing: number
  pending: number
  total: number
}

export function complianceTally(phase: SuperCredPhase): ComplianceTally {
  const tally: ComplianceTally = { passing: 0, failing: 0, pending: 0, total: SUPERCRED_CONTROLS.length }
  for (const c of SUPERCRED_CONTROLS) {
    const status = controlStatus(c, phase)
    if (status === 'pass') tally.passing++
    else if (status === 'fail') tally.failing++
    else tally.pending++
  }
  return tally
}

/**
 * Severity-weighted posture score, 0-100, or null when the agent has never
 * been exercised.
 *
 * Null until the credential chain runs: at `deployed` the only satisfied
 * controls are inventory attestations, and scoring an agent nothing has
 * actually tested would overstate what the platform knows. This matches the
 * baseline fixture's treatment of the enrolled-but-unassessed Sandbox Agent.
 *
 * Pending controls count against the score (you do not get credit for work not
 * done) and failing controls are penalised at FAIL_PENALTY, so the score dips
 * when the scan lands and recovers when the response controls are proven.
 */
export function postureScore(phase: SuperCredPhase): number | null {
  if (PHASE_ORDER[phase] < PHASE_ORDER.credentialed) return null

  let passWeight = 0
  let failWeight = 0
  let pendingWeight = 0
  for (const c of SUPERCRED_CONTROLS) {
    const w = SEVERITY_WEIGHT[c.severity]
    const status = controlStatus(c, phase)
    if (status === 'pass') passWeight += w
    else if (status === 'fail') failWeight += w
    else pendingWeight += w
  }

  const denominator = passWeight + failWeight * FAIL_PENALTY + pendingWeight
  if (denominator === 0) return null
  return Math.round((100 * passWeight) / denominator)
}

/**
 * The currency every SuperCred control's magnitude is authored in.
 *
 * These are hand-calibrated constants in this file, all sterling. Named so the
 * projection can refuse to add them to a document reported in another currency
 * rather than adding two different kinds of number — see projectPolicySummary.
 */
export const SUPERCRED_CURRENCY: CurrencyCode = 'GBP'

/**
 * Carried (residual) risk in GBP for a single control at this phase.
 *
 * A failing control carries its full ALE while the agent still holds live
 * credentials. Once stunned, it falls to STUN_CONTAINMENT_RESIDUAL of that —
 * capability removed, defect not yet fixed. Passing and pending controls carry
 * nothing.
 */
export function controlCarriedGbp(control: SuperCredControl, phase: SuperCredPhase): number {
  if (controlStatus(control, phase) !== 'fail') return 0
  if (phase === 'stunned') return Math.round(control.ale * STUN_CONTAINMENT_RESIDUAL)
  return control.ale
}

/**
 * Total carried risk for the SuperCred agent at this phase.
 *
 * Defined as the sum of the per-control figures so the aggregate on Risk
 * Exposure can never drift from the per-check rows on Agent Posture.
 */
export function carriedGbp(phase: SuperCredPhase): number {
  return SUPERCRED_CONTROLS.reduce((s, c) => s + controlCarriedGbp(c, phase), 0)
}
