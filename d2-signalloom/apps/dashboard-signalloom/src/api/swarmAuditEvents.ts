/**
 * Swarm audit event types — the vocabulary for the agent swarm lifecycle.
 *
 * These events cover the full claim-credential-sandbox-sentinel lifecycle
 * that distinguishes the swarm from the platform's existing agent registry.
 * Each event is scoped to a single agent and carries its SPIFFE ID so the
 * audit trail is identity-correlated, not just pod-correlated.
 */

// ─── Event type vocabulary ─────────────────────────────────────────────────

export const SWARM_AUDIT_EVENT_TYPES = [
  'swarm.agent.claimed',
  'swarm.agent.released',
  'swarm.credential.fetched',
  'swarm.credential.rotated',
  'swarm.nono.sandbox_entered',
  'swarm.nono.violation_blocked',
  'swarm.sentinel.stun_triggered',
  'swarm.sentinel.stun_released',
] as const

export type SwarmAuditEventType = (typeof SWARM_AUDIT_EVENT_TYPES)[number]

// ─── Event record ──────────────────────────────────────────────────────────

export interface SwarmAuditEvent {
  id: string
  type: SwarmAuditEventType
  agent_id: string
  spiffe_id: string
  timestamp: string
  details: Record<string, string>
}

// ─── Display helpers ───────────────────────────────────────────────────────

/** Human label for each event type, used in timeline filters and tooltips. */
export const SWARM_EVENT_LABELS: Record<SwarmAuditEventType, string> = {
  'swarm.agent.claimed': 'Agent claimed',
  'swarm.agent.released': 'Agent released',
  'swarm.credential.fetched': 'Credential fetched',
  'swarm.credential.rotated': 'Credential rotated',
  'swarm.nono.sandbox_entered': 'Sandbox entered',
  'swarm.nono.violation_blocked': 'Violation blocked',
  'swarm.sentinel.stun_triggered': 'Stun triggered',
  'swarm.sentinel.stun_released': 'Stun released',
}
