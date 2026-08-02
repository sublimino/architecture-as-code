// Audit Trail projection for the SuperCred demo.
//
// Deliberately isolated in its own file: another workstream owns writing real
// Stun events into the audit store, and this is the read-side overlay that
// makes /audit move during a demo in demo-data mode. If the write path lands,
// delete this file and its route entry in supercredProjection — nothing else
// depends on it.
//
// Two rules keep it honest and collision-free:
//
//  1. It only emits event types AuditTrail.tsx already knows about
//     (`enrollment`, `token_issued`, `compliance_check`, `violation_detected`,
//     `state_transition`, `token_refused`). Those are in its EVENT_TYPES filter
//     list and EVENT_COLORS map, so the events are filterable and coloured
//     without touching the page — and without competing with any new type
//     another workstream introduces.
//
//  2. Timestamps are the times the dashboard OBSERVED each transition, never
//     invented offsets. Where a transition happened before the dashboard was
//     watching, it falls back to the agent's own stunned_at annotation or the
//     current observation time, and never fabricates a plausible-looking
//     history.

import type { AuditEventResponse, AuditListResponse } from '../types/api'
import type { SuperCredDemoState, SuperCredPhase } from './supercredTypes'
import { SUPERCRED_AGENT_ID } from './supercredProjection'
import { SUPERCRED_CONTROLS } from './supercredControls'

const PHASE_ORDER: SuperCredPhase[] = ['deployed', 'credentialed', 'non-compliant', 'stunned']

const RUNTIME_CHECKS = SUPERCRED_CONTROLS.filter((c) => c.group === 'runtime').map((c) => c.id)

/** True once the demo has progressed at least as far as `phase`. */
function reached(state: SuperCredDemoState, phase: SuperCredPhase): boolean {
  const now = PHASE_ORDER.indexOf(state.phase)
  const target = PHASE_ORDER.indexOf(phase)
  return now >= 0 && target >= 0 && now >= target
}

/**
 * Best available timestamp for a phase transition.
 *
 * Prefers the observed entry time; falls back to the agent's own annotation
 * (the cluster's record) and finally to the current observation.
 */
function timestampFor(state: SuperCredDemoState, phase: SuperCredPhase): string {
  const observed = state.enteredAt?.[phase]
  if (observed) return observed
  if (phase === 'stunned' && state.agent?.stunned_at) return state.agent.stunned_at
  return state.observedAt ?? new Date().toISOString()
}

function event(
  state: SuperCredDemoState,
  id: string,
  phase: SuperCredPhase,
  event_type: string,
  actor: string,
  detail: Record<string, unknown>,
): AuditEventResponse {
  return {
    id: `supercred:${id}`,
    timestamp: timestampFor(state, phase),
    event_type,
    agent_id: SUPERCRED_AGENT_ID,
    agent_name: state.agent?.name ?? 'Cardvault Agent',
    actor,
    detail,
  }
}

/**
 * The audit events the demo has generated so far, newest first.
 *
 * Derived from observed state rather than stored, so a teardown (step 5)
 * removes them along with the agent — the demo returns cleanly and the real
 * audit store is never written to.
 */
export function superCredAuditEvents(state: SuperCredDemoState): AuditEventResponse[] {
  if (state.phase === 'absent' || !state.agent) return []

  const events: AuditEventResponse[] = []
  const namespace = state.agent.namespace ?? 'unknown'

  if (reached(state, 'deployed')) {
    events.push(event(state, 'deployed', 'deployed', 'enrollment', 'demo-operator', {
      namespace,
      source: 'supercred-demo step 1',
      spiffe_id: `spiffe://signalloom.ai/ns/${namespace}/sa/cardvault-agent`,
    }))
  }

  if (reached(state, 'credentialed')) {
    events.push(event(state, 'credentialed', 'credentialed', 'token_issued', 'spire-server', {
      source: 'supercred-demo step 2',
      chain: 'SPIFFE SVID -> OpenBao dynamic secret -> cardvault',
      issuer: 'openbao.openbao-system',
      target: state.agent.supercred_target ?? 'cardvault',
    }))
  }

  if (reached(state, 'non-compliant')) {
    const failed = state.scan?.failed_checks?.length ? state.scan.failed_checks : RUNTIME_CHECKS
    events.push(event(state, 'scanned', 'non-compliant', 'compliance_check', 'policy-engine', {
      source: 'supercred-demo step 3',
      compliant: false,
      failed_checks: failed,
      finding: 'securityContext not set',
    }))
  }

  if (reached(state, 'stunned')) {
    const reason = state.agent.stun_reason ?? 'compliance-failure: securityContext not set'
    // Three records, because the stun is three distinct governance facts: the
    // violation that justified it, the state change, and the credential denial
    // that proves the revocation actually took effect.
    events.push(event(state, 'violation', 'stunned', 'violation_detected', 'policy-engine', {
      source: 'supercred-demo step 4',
      severity: 'critical',
      reason,
    }))
    events.push(event(state, 'stunned', 'stunned', 'state_transition', 'signal-loom-platform', {
      source: 'supercred-demo step 4',
      from: 'active',
      to: 'suspended',
      action: 'stun',
      reason,
    }))
    events.push(event(state, 'revoked', 'stunned', 'token_refused', 'openbao', {
      source: 'supercred-demo step 4',
      lease: 'revoked',
      outcome: 'agent could not re-acquire credentials after stun',
    }))
  }

  // Newest first, matching the baseline audit fixture's ordering.
  return events.reverse()
}

/** Merge the demo's events into an audit page response. */
export function projectAudit(base: AuditListResponse, state: SuperCredDemoState): AuditListResponse {
  const extra = superCredAuditEvents(state)
  if (extra.length === 0) return base
  if (typeof base !== 'object' || base === null || !Array.isArray(base.events)) return base

  // Strip any previous projection so repeated polls cannot accumulate. The
  // total has to be rebased the same way — deriving it from base.total alone
  // would compound on every poll once this response had been projected before.
  const existing = base.events.filter((e) => !e?.id?.startsWith('supercred:'))
  const alreadyProjected = base.events.length - existing.length
  const baseTotal = (Number(base.total) || existing.length) - alreadyProjected

  return {
    ...base,
    events: [...extra, ...existing],
    total: baseTotal + extra.length,
  }
}
