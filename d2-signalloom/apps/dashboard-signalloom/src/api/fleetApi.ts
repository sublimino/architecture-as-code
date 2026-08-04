// Fleet Manager API layer.
//
// Type-safe fetch wrappers for the fleet-manager service. The `/fleet-api/`
// prefix is proxied to fleet-manager by nginx, same pattern as `/demo-api/`
// for the supercred demo runner.

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

export interface FleetTopology {
  agents: AgentState[]
  edges: Edge[]
  aggregateRisk: RiskSummary
  cascadeHistory: CascadeEvent[]
}

// ── Constants ───────────────────────────────────────────────────────────────

const FLEET_API = '/fleet-api/v1/fleet'

// ── Helpers ─────────────────────────────────────────────────────────────────

async function fleetFetch<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${FLEET_API}${path}`, init)
  if (!res.ok) {
    const body = await res.text().catch(() => '')
    throw new Error(`Fleet API ${res.status}: ${body || res.statusText}`)
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

export async function stunFleetAgent(agentId: string, token: string): Promise<CascadeEvent> {
  return fleetFetch<CascadeEvent>(`/stun/${encodeURIComponent(agentId)}`, {
    method: 'POST',
    headers: authHeaders(token),
  })
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
