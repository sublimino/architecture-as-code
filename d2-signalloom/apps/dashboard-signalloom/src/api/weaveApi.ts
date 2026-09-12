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
import type { DelegationRecord } from '../types/identity'

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

export interface AuthorizationChain {
  action: string
  agentIdentity: string
  actsOnBehalfOf: string
  principal: string
  decision: string
  confidence: number
  evidenceRefs: string[]
  attestationGitoid: string
  complete: boolean
  actorId?: string
  canonicalId?: string
  aliases?: string[]
  evidenceChain?: EvidenceLink[]
  delegationChain?: DelegationRecord[]
  cycleDetected?: boolean
  cycle_detected?: boolean
  has_cycle?: boolean
  cycle_nodes?: string[]
  timestamp?: string
}

export interface AuthorizationQueryResponse {
  chains: AuthorizationChain[]
  total: number
  complete_count: number
  kpi_fraction: number
}

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

  /**
   * Connect to the SSE observations stream.
   * Uses fetch() directly because EventSource cannot send the Authorization header.
   */
  createObservationsStream: (
    token: string,
    params?: { after?: string; before?: string; layers?: string; actor_id?: string; limit?: number },
    onMessage?: (observation: SignalObservation) => void,
    onError?: (error: Error) => void
  ) => {
    const q = new URLSearchParams()
    if (params?.after) q.set('after', params.after)
    if (params?.before) q.set('before', params.before)
    if (params?.layers) q.set('layers', params.layers)
    if (params?.actor_id) q.set('actor_id', params.actor_id)
    if (params?.limit) q.set('limit', String(params.limit))
    
    const qs = q.toString()
    const url = `/api/signals/observations/stream${qs ? `?${qs}` : ''}`
    
    const controller = new AbortController()
    
    // We cannot use the shared req() for a streaming response since it uses Axios
    // which buffers responses or requires node stream APIs. Instead we use native fetch.
    const BASE = import.meta.env.VITE_API_BASE_URL ?? ''
    const fullUrl = url.startsWith('http') ? url : `${BASE}${url}`
    
    fetch(fullUrl, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'text/event-stream',
      },
      signal: controller.signal,
    }).then(async (response) => {
      if (!response.ok) {
        throw new Error(`Stream connection failed: ${response.status}`)
      }
      if (!response.body) {
        throw new Error('No response body')
      }
      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ''
      
      try {
        while (true) {
          const { done, value } = await reader.read()
          if (done) break
          buffer += decoder.decode(value, { stream: true })
          
          const lines = buffer.split('\n')
          buffer = lines.pop() ?? ''
          
          let eventName = ''
          for (const line of lines) {
            if (line.startsWith('event: ')) {
              eventName = line.slice(7).trim()
            } else if (line.startsWith('data: ')) {
              const data = line.slice(6)
              if (eventName === 'observation' || !eventName) {
                try {
                  const obs = JSON.parse(data) as SignalObservation
                  onMessage?.(obs)
                } catch (e) {
                  console.error('Failed to parse SSE data', e)
                }
              }
            }
          }
        }
      } catch (err: any) {
        if (err.name === 'AbortError') return
        onError?.(err)
      }
    }).catch((err) => {
      if (err.name === 'AbortError') return
      onError?.(err)
    })
    
    return {
      disconnect: () => controller.abort()
    }
  },

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

  getActorAuthorization: (token: string, id: string, action?: string) =>
    req<AuthorizationChain>(`/signals/actors/${id}/authorization${action ? `?action=${encodeURIComponent(action)}` : ''}`, token),

  getAuthorizationChains: async (token: string, params?: { actor_id?: string; action?: string; action_id?: string }) => {
    const q = new URLSearchParams()
    if (params?.actor_id) q.set('actor_id', params.actor_id)
    if (params?.action) q.set('action', params.action)
    if (params?.action_id) q.set('action_id', params.action_id)
    const qs = q.toString()
    return req<AuthorizationQueryResponse>(`/signals/authorization${qs ? `?${qs}` : ''}`, token)
  },

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
