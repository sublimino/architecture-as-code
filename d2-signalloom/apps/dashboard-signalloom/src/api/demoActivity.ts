// Demo-mode activity log.
//
// In live mode a mutation and its audit row are written together by
// fe-signalloom (api_compat._write + _audit_log), and the Audit Trail page
// reads them back over GET /api/audit. Demo mode has no backend, so a
// demo-mode action used to leave no trace at all — the operator pressed Stun,
// the agent changed state, and the audit trail showed nothing. For a product
// whose output is regulatory evidence, an action with no record is the one
// thing a demo must never show.
//
// So demo mode keeps its own append-only log. fakeData.ts writes to it from
// the mutation routes and merges it into the GET /audit fixture, which is what
// puts a demo action on the same timeline a live action lands on. This is
// deliberately NOT a parallel event store in the product sense: it is the
// fixture half of the one audit_events model, shaped as AuditEventResponse so
// the same AuditTrail rendering path handles both.

import type { AuditEventResponse } from '../types/api'

/** Newest-first cap. A demo session is minutes long; this only stops a
 *  left-running tab from growing without bound. */
export const DEMO_ACTIVITY_LIMIT = 200

export interface DemoActivityInput {
  event_type: string
  actor: string
  agent_id?: string | null
  agent_name?: string | null
  detail?: Record<string, unknown>
  /** Overridable so tests can pin a timestamp; defaults to now. */
  timestamp?: string
}

// Newest last internally; demoActivityEvents() reverses on read.
const log: AuditEventResponse[] = []
let seq = 0

/** Record one demo activity event and return the stored row. */
export function recordDemoActivity(input: DemoActivityInput): AuditEventResponse {
  // Date.now() alone collides when two actions land in the same millisecond,
  // and a duplicate id makes React drop a row from the table.
  seq += 1
  const event: AuditEventResponse = {
    id: `demo-activity-${seq}`,
    timestamp: input.timestamp ?? new Date().toISOString(),
    event_type: input.event_type,
    agent_id: input.agent_id ?? null,
    agent_name: input.agent_name ?? null,
    actor: input.actor,
    detail: input.detail ?? {},
  }
  log.push(event)
  if (log.length > DEMO_ACTIVITY_LIMIT) log.splice(0, log.length - DEMO_ACTIVITY_LIMIT)
  return event
}

/** Recorded events, newest first — the order the Audit Trail table expects. */
export function demoActivityEvents(): AuditEventResponse[] {
  return [...log].reverse()
}

/** Reset the log. Test-only; nothing in the app clears it. */
export function clearDemoActivity(): void {
  log.length = 0
  seq = 0
}
