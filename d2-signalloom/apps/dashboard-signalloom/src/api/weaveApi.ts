/**
 * Signal Weave API — types and client functions for the signal observation
 * and provisional actor correlation system.
 *
 * All calls go through the shared `req()` from client.ts, which handles demo
 * mode (via resolveFake / fakeData.ts ROUTES), GET coalescing, cancellation,
 * and SuperCred projection. The weave fake routes are registered in
 * fakeData.ts via fakeWeaveData.ts's WEAVE_ROUTES export.
 */
import { req } from './client'

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

export interface StoreStats {
  total_observations: number
  observations_by_layer: Record<string, number>
  observations_by_fidelity: Record<string, number>
  actor_count: number
  actors_by_status: Record<string, number>
  last_ingestion: string | null
  store_type: string
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
 * Coerce a list-shaped response to an actual array.
 *
 * `req<T[]>` is a cast, not a check: TypeScript describes what the server is
 * *supposed* to send and enforces nothing at runtime. A Go service marshalling
 * a nil slice emits `null`, which sailed straight through that cast into
 * component state and produced
 *
 *     Uncaught TypeError: Cannot read properties of null (reading 'length')
 *
 * on the Weave page whenever the observations query came back empty.
 *
 * The service-side fix (signal-ingest now emits `[]`) is the real one and is
 * where the bad state entered. This is the second line of defence, because the
 * page is one caching proxy, one gateway error body, or one future service away
 * from being handed a null again — and the browser should degrade to "empty"
 * rather than a white screen. Anything that is not an array becomes an empty
 * array, which is the truthful reading of "no items".
 */
const asList = <T>(value: T[] | null | undefined): T[] => (Array.isArray(value) ? value : [])

export const weaveApi = {
  getObservations: async (token: string, params?: { layer?: string; limit?: number }) => {
    const q = new URLSearchParams()
    if (params?.layer) q.set('layer', params.layer)
    if (params?.limit) q.set('limit', String(params.limit))
    const qs = q.toString()
    return asList(await req<SignalObservation[] | null>(`/signals/observations${qs ? `?${qs}` : ''}`, token))
  },

  getActors: async (token: string) =>
    asList(await req<ProvisionalActor[] | null>('/signals/actors', token)),

  getActor: (token: string, id: string) =>
    req<ProvisionalActor>(`/signals/actors/${id}`, token),

  getCoverage: (token: string) =>
    req<CoverageStatement>('/signals/coverage', token),

  promoteActor: (token: string, id: string) =>
    req<{ status: string }>(`/signals/actors/${id}/promote`, token, { method: 'POST' }),

  runCorrelation: (token: string) =>
    req<{ status: string }>('/signals/correlate', token, { method: 'POST' }),

  getStoreStats: (token: string) =>
    req<StoreStats>('/signals/store/stats', token),

  seedFixtures: (token: string) =>
    req<{ seeded: number }>('/signals/collectors/seed', token, { method: 'POST' }),
}
