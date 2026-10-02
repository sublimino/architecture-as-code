// Fleet Manager API layer.
//
// Type-safe fetch wrappers for the fleet-manager service. The `/fleet-api/`
// prefix is proxied to fleet-manager by nginx, same pattern as `/demo-api/`
// for the supercred demo runner.

import type { PlaneResult } from '../types/api'

// ── Types ───────────────────────────────────────────────────────────────────

export type AgentType = 'data-vault' | 'data-pipeline' | 'llm-inference' | 'api-gateway' | 'observability'
export type AgentStateValue = 'absent' | 'deploying' | 'active' | 'non-compliant' | 'grace-period' | 'stunned'
export type TrustProfile = 'high' | 'medium' | 'low'

export interface AgentState {
  id: string
  name: string
  type: AgentType
  team: string
  trustProfile: TrustProfile
  state: AgentStateValue
  gracePeriod?: string
  riskClass?: string
}

export interface Edge {
  from: string
  to: string
}

export interface RiskSummary {
  ale: number
  var95: number
  trend: 'up' | 'down' | 'stable'
  previousAle?: number
}

export interface CascadeEvent {
  triggerId: string
  affectedIds: string[]
  timestamp: string
  durationMs: number
  riskBefore: number
  riskAfter: number
}

/**
 * What POST /stun/{agentId} answers with: fleet-manager's cascade result,
 * snake_case, written in full under a status its own verdict earns (200
 * contained, 207 partial, 404 not_found, 500 failed). `planes` is flat across
 * the cascade, so one plane name can appear once per affected target.
 *
 * `affectedIds` is the older CascadeEvent spelling, kept optional so a
 * response in that shape still drives the cascade animation.
 */
export interface FleetStunResult {
  target_agent?: string
  affected_agents?: string[]
  affectedIds?: string[]
  duration_ms?: number
  overall_outcome?: string
  planes?: PlaneResult[]
}

/** Required by fleet-manager since it began rejecting a stun with no body (400). */
export interface FleetStunRequest {
  agent_id: string
  reason: string
}

export interface NodeMetrics {
  name: string
  status: 'Ready' | 'NotReady'
  cpuUsagePercent: number
  memoryUsagePercent: number
  roles: string[]
}

export interface PodPhaseCounts {
  running: number
  pending: number
  failed: number
  succeeded: number
}

export interface FluxStatus {
  reconciled: boolean
  lastReconciledAt: string
  revision: string
  suspended: boolean
}

export interface FleetTopology {
  agents: AgentState[]
  edges: Edge[]
  aggregateRisk: RiskSummary
  cascadeHistory: CascadeEvent[]
  nodes?: NodeMetrics[]
  podPhaseCounts?: PodPhaseCounts
  fluxStatus?: FluxStatus
}

// ── Constants ───────────────────────────────────────────────────────────────

const FLEET_API = '/fleet-api/v1/fleet'

// ── Helpers ─────────────────────────────────────────────────────────────────

/** Thrown when the Fleet API answered with something that is not the API. */
export class FleetUnreachableError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'FleetUnreachableError'
  }
}

const FLEET_UNREACHABLE_MESSAGE =
  'Fleet Manager did not respond: the request was answered by the dashboard ' +
  'itself, which means the fleet-manager service is not deployed or /fleet-api/ ' +
  'is not proxied. Run `make demo-signalloom-fleet-up` to deploy it.'

async function fleetFetch<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${FLEET_API}${path}`, init)
  if (!res.ok) {
    const body = await res.text().catch(() => '')
    throw new Error(`Fleet API ${res.status}: ${body || res.statusText}`)
  }

  // `res.ok` is TRUE for the SPA fallback. When no nginx location matches
  // /fleet-api/, the catch-all serves index.html with 200 OK, so this reached
  // res.json() and surfaced as
  //   Unexpected token '<', "<!doctype "... is not valid JSON
  // which describes the symptom and hides the cause: fleet-manager is not
  // deployed, or not proxied. Content-type is the discriminator -- a 200 that
  // is not JSON is not an answer from this API.
  const contentType = res.headers.get('content-type') ?? ''
  if (!contentType.includes('json')) {
    throw new FleetUnreachableError(FLEET_UNREACHABLE_MESSAGE)
  }
  return res.json() as Promise<T>
}

function authHeaders(token: string): HeadersInit {
  return { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }
}

// ── Public API ──────────────────────────────────────────────────────────────

export async function fetchFleetTopology(): Promise<FleetTopology> {
  return fleetFetch<FleetTopology>('/topology')
}

/** Verdict statuses whose body is still a complete cascade report. */
const STUN_VERDICT_STATUSES = new Set([404, 500])

export async function stunFleetAgent(agentId: string, token: string, reason: string): Promise<FleetStunResult> {
  const body: FleetStunRequest = { agent_id: agentId, reason }
  const init: RequestInit = { method: 'POST', headers: authHeaders(token), body: JSON.stringify(body) }
  const path = `/stun/${encodeURIComponent(agentId)}`
  // 404 and 500 carry the full per-plane record of a not_found or failed
  // cascade. fleetFetch would throw it away; this keeps it so the page can
  // show which plane failed. Anything else non-2xx (400 for a bad reason,
  // 403, a proxy error) still throws.
  const res = await fetch(`${FLEET_API}${path}`, init)
  if (STUN_VERDICT_STATUSES.has(res.status) && (res.headers.get('content-type') ?? '').includes('json')) {
    const report = (await res.json().catch(() => null)) as FleetStunResult | null
    if (report && typeof report.overall_outcome === 'string') return report
    throw new Error(`Fleet API ${res.status}: ${JSON.stringify(report) || res.statusText}`)
  }
  if (!res.ok) {
    const text = await res.text().catch(() => '')
    throw new Error(`Fleet API ${res.status}: ${text || res.statusText}`)
  }
  if (!(res.headers.get('content-type') ?? '').includes('json')) {
    // Same SPA-fallback diagnosis as fleetFetch. Never retried: a stun is not
    // idempotent in effect, and a second POST would be a second stun.
    throw new FleetUnreachableError(FLEET_UNREACHABLE_MESSAGE)
  }
  return res.json() as Promise<FleetStunResult>
}

export async function deployFleet(token: string): Promise<void> {
  await fleetFetch<void>('/deploy', {
    method: 'POST',
    headers: authHeaders(token),
  })
}

export async function scanFleet(token: string): Promise<void> {
  await fleetFetch<void>('/scan', {
    method: 'POST',
    headers: authHeaders(token),
  })
}

export async function recoverFleet(token: string): Promise<void> {
  await fleetFetch<void>('/recover', {
    method: 'POST',
    headers: authHeaders(token),
  })
}

export async function resetFleet(token: string): Promise<void> {
  await fleetFetch<void>('/reset', {
    method: 'POST',
    headers: authHeaders(token),
  })
}
