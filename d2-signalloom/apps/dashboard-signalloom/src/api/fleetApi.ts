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

export interface ParameterTriple {
  min: number
  mode: number
  max: number
}

export interface AgentState {
  id: string
  name: string
  type: AgentType
  team: string
  trustProfile: TrustProfile
  state: AgentStateValue
  gracePeriod?: string
  riskClass?: string
  controlFailures?: string[]
  parameterTriple?: ParameterTriple
  calibratedTriple?: ParameterTriple
}

export interface Edge {
  from: string
  to: string
}

/**
 * The machine-readable cause of a route declining to report a money figure.
 *
 * Mirrors `PricingStatus` in policy-engine/pkg/compliance/fleet_scan.go, and
 * the key set is identical on all three routes that withhold money, so there
 * is one shape to deserialise and one to render.
 *
 * The two refusal values are NOT interchangeable and must not be collapsed in
 * UI copy: they demand different operator actions. A missing loss-event
 * frequency is fixed by declaring a control mapping in the policy pack; a
 * missing risk data plane is fixed by putting a priced scan behind the route.
 * See `unpricedAction` in FleetRiskGauge, which is the one place that mapping
 * is written down client-side.
 */
export type PricingStatus =
  /** A figure is present and was computed from declared inputs. */
  | 'PRICED'
  /** The checks evaluated resolve to no control in the risk pack. */
  | 'NO_DECLARED_LOSS_FREQUENCY'
  /** The route answers from a store that holds no money at all. */
  | 'NO_RISK_DATA_PLANE'

/**
 * The refusal object. Every key is always present on the wire.
 *
 * `status` is the ONLY thing to branch on. `available` is still sent and still
 * read by clients, but on the Go side it is DERIVED from the status through a
 * method precisely so two hand-maintained fields cannot carry one fact and
 * drift apart -- a test asserts the constructor offers no way to set it.
 * Branching on both here would write a disagreement the server cannot
 * produce, so this client never reads `available` at all.
 *
 * `status` is typed as the union widened with `string`: a client older than
 * the server must treat an unrecognised status as "not priced" rather than
 * failing to compile against it or, worse, coercing it to PRICED.
 *
 * The whole object is optional only because a pre-contract producer may not
 * send it yet (fleet-manager's /topology at the time of writing; W7 is
 * applying the same shape there). `isPriced` handles that case explicitly.
 */
export interface FleetPricingStatus {
  available: boolean
  status: PricingStatus | string
  reason: string
  /** The money fields this response withheld, by their JSON names. */
  unpricedFields: string[]
  /** The checks that resolved to no declared control; empty when not per-check. */
  unmappedChecks: string[]
}

/**
 * The fleet's aggregate risk, which may carry no figures at all.
 *
 * `ale` and `var95` were declared `number` (required). A TypeScript type is not
 * a runtime check: once the pricing routes began omitting these fields --
 * `*float64` with `omitempty`, so structurally ABSENT rather than zero -- the
 * required declaration became a claim about a payload nobody verified. The
 * compiler was satisfied, `bun run typecheck` passed, and every consumer read
 * `undefined` while believing it held a `number`. `money(undefined as number)`
 * then renders whatever Intl does with NaN.
 *
 * They are optional-and-nullable now so the compiler forces each call site to
 * say what it does with absence. The two shapes mean the same thing to a
 * consumer and both occur: `undefined` from an omitempty Go field, `null` from
 * a JSON null (fe-signalloom's /compliance/policy/* routes report absence that
 * way). Do NOT reach for `!` or `?? 0` to quiet this: a zero in a money field
 * reads as "no loss expected", which is a figure, and it is the exact defect
 * the server-side change removed.
 */
export interface RiskSummary {
  ale?: number | null
  var95?: number | null
  trend: 'up' | 'down' | 'stable'
  previousAle?: number | null
  carriedGbp?: number | null
  carried?: number | null
  pricing?: FleetPricingStatus
}

// The "is this priced?" predicate lives beside the thing that renders the
// answer, in components/fleet/FleetRiskGauge.tsx, not here. This module is
// wholesale-mocked (`vi.mock('../api/fleetApi', () => ({ ... }))`, no
// importOriginal) by both fleet page suites, so a helper added here is absent
// at runtime under test and the page crashes on first render with
// "No \"x\" export is defined on the mock" -- which is how this was found.

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

// Recover does NOT go through /fleet-api/, unlike every other action here.
//
// fleet-manager grants `recover` (and `resume`) to its `operator` break-glass
// key alone : /recover thaws every stunned agent at once and never consulted
// the resume-token governance that guards /resume. The /fleet-api/ proxy swaps
// in the `dashboard` key, which has `stun`, `deploy`, `scan` and `reset` and no
// `recover`, so this button answered 403 for everybody including the
// superadmin.
//
// Widening the `dashboard` key would be wrong twice: it would put break-glass
// within the browser's reach, and nginx presents that key on every
// /fleet-api/ call, so the grant could not be narrowed to this one button.
// Instead fe-signalloom proxies the capability behind its own superadmin gate
// and presents the operator key server-side (src/fleet_operator.py), so the
// browser sends only its Dex token and never holds the key.
export async function recoverFleet(token: string): Promise<void> {
  const res = await fetch('/api/v1/fleet/recover', {
    method: 'POST',
    headers: authHeaders(token),
  })
  if (!res.ok) {
    const body = await res.text().catch(() => '')
    throw new Error(`Fleet API ${res.status}: ${body || res.statusText}`)
  }
}

// One agent, local or remote. Same key and same gate as recoverFleet; this is
// the single-agent form the remote contract's resume path needs, since nothing
// else can present the operator key.
export async function resumeFleetAgent(
  agentId: string,
  token: string,
  reason?: string,
): Promise<void> {
  const res = await fetch(`/api/v1/fleet/resume/${encodeURIComponent(agentId)}`, {
    method: 'POST',
    headers: authHeaders(token),
    body: JSON.stringify(reason ? { reason } : {}),
  })
  if (!res.ok) {
    const body = await res.text().catch(() => '')
    throw new Error(`Fleet API ${res.status}: ${body || res.statusText}`)
  }
}

export async function resetFleet(token: string): Promise<void> {
  await fleetFetch<void>('/reset', {
    method: 'POST',
    headers: authHeaders(token),
  })
}
