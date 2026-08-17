/**
 * Signal Weave API — types and client functions for the signal observation
 * and provisional actor correlation system.
 *
 * In demo mode the client module (client.ts) resolves these routes from
 * fakeWeaveData.ts fixtures. In live mode they hit the signal-ingest service.
 */
import { api } from './client'

// ─── Domain Types ────────────────────────────────────────────────────────────

export type SignalLayer =
  | 'network_egress'
  | 'identity_authorization'
  | 'application_saas'
  | 'endpoint_host'
  | 'behavioural'
  | 'cloud_control_plane'
  | 'protocol'

export type FidelityTier = 'definitive' | 'strong' | 'suggestive' | 'circumstantial'

export interface SignalObservation {
  id: string
  timestamp: string
  layer: SignalLayer
  fidelity: FidelityTier
  source: string
  confidence: number
  actor_hint?: string
  raw_evidence_ref: string
  labels?: Record<string, string>
  description: string
}

export interface EvidenceLink {
  observation_id: string
  layer: SignalLayer
  fidelity: FidelityTier
  contribution: string
  timestamp: string
}

export interface ProvisionalActor {
  id: string
  status: 'provisional' | 'actionable' | 'promoted' | 'dismissed'
  confidence: number
  evidence_chain: EvidenceLink[]
  correlation_keys: string[]
  created_at: string
  updated_at: string
  promoted_at?: string
  agent_registry_id?: string
  display_name?: string
}

export interface BlindSpot {
  id: string
  layer: SignalLayer
  description: string
}

export interface CoverageStatement {
  covered_layers: SignalLayer[]
  blind_spots: BlindSpot[]
  closeable_by_issuance: string[]
  deployment_coverage: string
}

// ─── API Responses ───────────────────────────────────────────────────────────

export interface WeaveObservationsResponse {
  observations: SignalObservation[]
}

export interface WeaveActorsResponse {
  actors: ProvisionalActor[]
}

// ─── Client ──────────────────────────────────────────────────────────────────

/**
 * All weave API calls go through the shared `req()` in client.ts via the
 * exported `api` object — but the signal routes are not yet wired there, so
 * we build thin wrappers that call `req` indirectly. When the routes are added
 * to client.ts's `api` object the signatures stay the same.
 *
 * NOTE: These use the same `req()` function from client.ts which already
 * handles demo mode via `resolveFake()`. The fakeWeaveData.ts module registers
 * its routes in fakeData.ts's ROUTES array.
 */

// We re-export a weaveApi namespace so pages import from one place.
// Under the hood each function calls the shared req() via the api object,
// but since the signal routes aren't yet on the api object we import req
// through a local wrapper that matches the api.* call pattern.

// For now, these functions accept a token and call req() via a dynamic import
// of the client module's internal function. The simplest correct approach is
// to add them to the api object directly, but that's a change to client.ts
// which already has a large surface. Instead we'll call the http instance.
import axios from 'axios'
import { isDemoMode } from './demoMode'
import { fakeWeaveData } from './fakeWeaveData'

const BASE = (import.meta.env.VITE_API_BASE_URL as string) ?? ''
const http = axios.create({ baseURL: BASE })

function authHeaders(token: string) {
  return {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${token}`,
  }
}

async function weaveReq<T>(
  method: string,
  path: string,
  token: string,
): Promise<T> {
  if (isDemoMode()) {
    const fake = fakeWeaveData.resolve(method, path)
    if (fake !== undefined) return fake as T
    throw new Error(`No demo fixture for ${method} ${path}`)
  }
  const url = path.startsWith('/api') ? path : `/api${path}`
  const res = await http.request<T>({
    url,
    method,
    headers: authHeaders(token),
  })
  return res.data
}

export const weaveApi = {
  getObservations: (token: string, params?: { layer?: string; limit?: number }) => {
    const q = new URLSearchParams()
    if (params?.layer) q.set('layer', params.layer)
    if (params?.limit) q.set('limit', String(params.limit))
    const qs = q.toString()
    return weaveReq<SignalObservation[]>('GET', `/signals/observations${qs ? `?${qs}` : ''}`, token)
  },

  getActors: (token: string) =>
    weaveReq<ProvisionalActor[]>('GET', '/signals/actors', token),

  getActor: (token: string, id: string) =>
    weaveReq<ProvisionalActor>('GET', `/signals/actors/${id}`, token),

  getCoverage: (token: string) =>
    weaveReq<CoverageStatement>('GET', '/signals/coverage', token),

  promoteActor: (token: string, id: string) =>
    weaveReq<{ status: string }>('POST', `/signals/actors/${id}/promote`, token),

  runCorrelation: (token: string) =>
    weaveReq<{ status: string }>('POST', '/signals/correlate', token),
}
