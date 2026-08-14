import axios from 'axios'
import { isDemoMode } from './demoMode'
import { hasFakeRoute, resolveFake } from './fakeData'
import { affectsDemo, projectResponse } from './supercredProjection'
import { ensureSuperCredState, isSuperCredEnabled } from './supercredSource'
import type {
  AgentCreateRequest,
  AgentListResponse,
  AgentResponse,
  AuditListResponse,
  ComplianceSummaryResponse,
  ConsentAcceptRequest,
  ConsentAcceptResponse,
  ConsentStatusResponse,
  CryptoHealthResponse,
  CookiePreferencesResponse,
  FrameworkResponse,
  InitialApiKeyResponse,
  IssueCredentialResponse,
  NetworkTestListResponse,
  NetworkTestScanResponse,
  NHIAccountDetail,
  NHIDiscoveredResponse,
  NHIScanListResponse,
  PlatformUsersResponse,
  PostureResponse,
  PreferencesUpdateRequest,
  ReassessmentResponse,
  RevokeCredentialResponse,
  RotateApiKeyResponse,
  StunAgentResponse,
  SupportRequestCreate,
  SupportRequestResponse,
  TenantSettingsResponse,
  TransitionRequest,
  TransitionResponse,
  TrustTopologyResponse,
  UserPreferencesResponse,
  ViolationListResponse,
} from '../types/api'
import type {
  ComplianceCheck,
  ComplianceScanRequest,
  FrameworkSummary,
  PostureSummary,
} from '../types/compliance'

const BASE = (import.meta.env.VITE_API_BASE_URL as string) ?? ''

const http = axios.create({ baseURL: BASE })

// How long a demo fixture pretends to be on the network. Named because the
// cancellation path below has to clear this timer rather than let it fire.
const DEMO_LATENCY_MS = 120

// Coalesce identical concurrent GETs so an accidental render storm (or rapid
// re-mounts) cannot fan out into hundreds of duplicate backend calls. Only
// in-flight requests share a promise; sequential and interval refreshes are
// unaffected.
//
// `waiters` is what makes per-caller cancellation safe here. A coalesced
// request has more than one consumer by construction, so one caller aborting
// must NOT kill the HTTP request the others are still waiting on — it may only
// detach that caller. The shared request is aborted when, and only when, the
// last waiter has left. A caller that passed no signal is uncancellable and so
// pins the request open, which is the correct conservative reading of "this
// consumer cannot be told to stop caring".
interface InflightGet {
  promise: Promise<unknown>
  controller: AbortController
  waiters: number
}

const inflightGets = new Map<string, InflightGet>()

// Merge union: both helpers below are live in the merged req(). demoModeError
// (feat/supercred-agents-unify) makes an unresolvable demo route fail loudly
// instead of escaping to live HTTP; applyDemoProjection
// (feat/supercred-main-pages) overlays the running demo onto the response.
// Resolving this hunk to either side alone would leave req() calling an
// undefined function.
type ApiLikeError = Error & {
  response?: { status?: number }
  status?: number
}

function demoModeError(message: string, status: number): ApiLikeError {
  const err = new Error(message) as ApiLikeError
  err.status = status
  err.response = { status }
  return err
}

/**
 * Overlay the running SuperCred demo onto a response.
 *
 * The SuperCred demo lives on a different data plane (the cluster, via
 * /supercred-api) from the governance API, so its effects are federated in
 * here rather than being baked into any page. This is the single interception
 * point: every main page keeps rendering exactly what the data layer reports,
 * and none of them know the demo exists.
 *
 * Applies to both demo-data fixtures and live API responses, because the
 * observation driving it — the agent's `signalloom.ai/state` pod label — reads
 * the same either way. Hard-gated off in uat/prod by isSuperCredEnabled().
 */
async function applyDemoProjection<T>(method: string, path: string, data: T): Promise<T> {
  // Deliberately total: every branch, including the enablement checks, is
  // inside the catch. This overlay is decoration on top of the real response,
  // so no failure in it — an unreachable proxy, a partially-mocked module, a
  // malformed payload — may ever surface as a page error.
  try {
    if (!isSuperCredEnabled() || !affectsDemo(method, path)) return data
    const state = await ensureSuperCredState()
    return projectResponse(method, path, data, state) as T
  } catch {
    return data
  }
}

/**
 * The rejection every cancelled request produces.
 *
 * Named `AbortError` because callers have to be able to tell "you stopped
 * caring" apart from "the service failed" — a page that renders the first as
 * the second reports an outage that never happened.
 */
function abortError(): ApiLikeError {
  const err = new Error('Request aborted') as ApiLikeError
  err.name = 'AbortError'
  return err
}

/**
 * The demo fixture's simulated latency, as a promise that can actually be
 * cancelled.
 *
 * `clearTimeout` rather than a resolved-but-ignored timer is the whole point:
 * an abandoned timer still fires, still holds its callback alive, and — if the
 * caller has gone away in the meantime — still runs that callback in whatever
 * the environment has become by then.
 */
function delayedFixture<T>(value: T, signal?: AbortSignal): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortError())
      return
    }
    const onAbort = () => {
      clearTimeout(timer)
      reject(abortError())
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort)
      resolve(value)
    }, DEMO_LATENCY_MS)
    signal?.addEventListener('abort', onAbort, { once: true })
  })
}

/**
 * Detach one caller from a coalesced request, aborting the shared HTTP call
 * only once nobody is left waiting on it.
 */
function releaseInflight(url: string, entry: InflightGet): void {
  entry.waiters -= 1
  if (entry.waiters > 0) return
  entry.controller.abort()
  if (inflightGets.get(url) === entry) inflightGets.delete(url)
}

/** One caller's view of a coalesced request, cancellable independently. */
function joinInflight<T>(url: string, entry: InflightGet, signal?: AbortSignal): Promise<T> {
  if (!signal) return entry.promise as Promise<T>
  if (signal.aborted) {
    releaseInflight(url, entry)
    return Promise.reject(abortError())
  }
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => {
      releaseInflight(url, entry)
      reject(abortError())
    }
    signal.addEventListener('abort', onAbort, { once: true })
    // Attached for every waiter, including one that has already been rejected
    // by its own abort — settling an already-settled promise is a no-op, and
    // the handler is what keeps a cancelled shared request from surfacing as an
    // unhandled rejection.
    entry.promise.then(
      (value) => {
        signal.removeEventListener('abort', onAbort)
        resolve(value as T)
      },
      (err) => {
        signal.removeEventListener('abort', onAbort)
        reject(err)
      },
    )
  })
}

async function req<T>(
  path: string,
  token: string,
  config?: { method?: string; data?: unknown; signal?: AbortSignal },
): Promise<T> {
  const method = config?.method ?? 'GET'
  const signal = config?.signal
  // Demo mode: short-circuit to local fixtures so every screen renders even
  // when the backend API is unavailable / in development. No call sites change.
  // If a demo route cannot resolve, fail explicitly instead of escaping back to
  // live HTTP and fabricating a "working" demo from partial coverage.
  if (isDemoMode()) {
    const fake = resolveFake(method, path, config?.data)
    if (fake !== undefined) {
      const settled = await delayedFixture(fake as T, signal)
      return applyDemoProjection(method, path, settled)
    }
    const status = hasFakeRoute(method, path) ? 404 : 501
    throw demoModeError(
      hasFakeRoute(method, path)
        ? `Demo fixture not found for ${method.toUpperCase()} ${path}`
        : `Demo fixture route not implemented for ${method.toUpperCase()} ${path}`,
      status,
    )
  }
  const url = path.startsWith('/api') ? path : `/api${path}`
  const send = (requestSignal?: AbortSignal) =>
    http
      .request<T>({
        url,
        method,
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
        },
        data: config?.data,
        signal: requestSignal,
      })
      .then((res) => res.data)

  // Not coalesced, so this caller owns the request outright and its signal can
  // go straight to axios.
  if (method.toUpperCase() !== 'GET') {
    return applyDemoProjection(method, path, await send(signal))
  }

  // Coalesce on the raw response so concurrent callers share one HTTP request,
  // then project per-caller — the projection is pure and cheap.
  const existing = inflightGets.get(url)
  if (existing) {
    existing.waiters += 1
    return applyDemoProjection(method, path, await joinInflight<T>(url, existing, signal))
  }
  const controller = new AbortController()
  const entry: InflightGet = {
    controller,
    waiters: 1,
    promise: send(controller.signal).finally(() => {
      if (inflightGets.get(url) === entry) inflightGets.delete(url)
    }),
  }
  inflightGets.set(url, entry)
  return applyDemoProjection(method, path, await joinInflight<T>(url, entry, signal))
}

export const api = {
  trustTopology: (token: string) =>
    req<TrustTopologyResponse>('/trust-topology', token),

  agents: {
    list: (token: string) =>
      req<AgentListResponse>('/agents', token),

    register: (token: string, body: AgentCreateRequest) =>
      req<AgentResponse>('/agents', token, { method: 'POST', data: body }),

    // Step 2 of register-then-issue: mint an identity credential for an existing
    // record. The token is returned once; callers must show-once and never store it.
    issueCredential: (token: string, id: string) =>
      req<IssueCredentialResponse>(`/agents/${id}/credentials`, token, { method: 'POST' }),

    // Self-serve revoke — revokes ALL active credentials for the agent (ClickUp 86cak75u7).
    revokeCredential: (token: string, id: string) =>
      req<RevokeCredentialResponse>(`/agents/${id}/credentials/revoke`, token, { method: 'POST' }),

    get: (token: string, id: string) =>
      req<AgentResponse>(`/agents/${id}`, token),

    update: (token: string, id: string, body: Partial<AgentCreateRequest>) =>
      req<AgentResponse>(`/agents/${id}`, token, { method: 'PUT', data: body }),

    transition: (token: string, id: string, body: TransitionRequest) =>
      req<TransitionResponse>(`/agents/${id}/transition`, token, { method: 'POST', data: body }),

    // Stun an agent. This endpoint PERFORMS the isolation — it calls the
    // SuperCred proxy itself to relabel the pod and revoke the lease — and
    // writes the state change and its audit event in the same transaction.
    //
    // No body, by design. The browser used to POST the proxy directly and then
    // POST here to record what it had done; a closed tab or an expired token
    // between the two left the cluster mutated with nothing written down. One
    // call closes that window, and with the server making the proxy call there
    // is nothing left for the client to supply: actor from the token, target
    // from the path, everything else from what the server observed.
    //
    // In demo mode it resolves to a fixture that appends to the demo activity
    // log instead — same event, same timeline, no backend.
    stun: (token: string, id: string) =>
      req<StunAgentResponse>(`/agents/${id}/stun`, token, { method: 'POST' }),

    violations: (token: string, agentId: string) =>
      req<ViolationListResponse>(`/agents/${agentId}/violations`, token),

    acknowledge: (token: string, violationId: string) =>
      req<{ status: string }>(`/agents/violations/${violationId}/acknowledge`, token, { method: 'POST' }),

    reassess: (token: string, agentId: string, controlId: string) =>
      req<ReassessmentResponse>(`/agents/${agentId}/compliance/${controlId}/reassess`, token, { method: 'POST' }),
  },

  compliance: {
    summary: (token: string) =>
      req<ComplianceSummaryResponse>('/compliance/summary', token),

    posture: (token: string) =>
      req<PostureResponse>('/compliance/posture', token),

    frameworks: (token: string) =>
      req<FrameworkResponse[]>('/compliance/frameworks', token),

    export: (token: string, format: 'json' | 'pdf' | 'both' = 'json') =>
      req<unknown>(`/compliance/export?format=${format}`, token),
  },

  audit: (
    token: string,
    params: {
      page?: number
      limit?: number
      from?: string
      to?: string
      agent?: string
      type?: string
    },
  ) => {
    const q = new URLSearchParams()
    if (params.page) q.set('page', String(params.page))
    if (params.limit) q.set('limit', String(params.limit))
    if (params.from) q.set('from', params.from)
    if (params.to) q.set('to', params.to)
    if (params.agent) q.set('agent', params.agent)
    if (params.type) q.set('type', params.type)
    return req<AuditListResponse>(`/audit?${q.toString()}`, token)
  },

  auditExportCsv: async (
    token: string,
    params: { from?: string; to?: string; agent?: string; type?: string },
  ): Promise<string> => {
    const q = new URLSearchParams()
    if (params.from) q.set('from', params.from)
    if (params.to) q.set('to', params.to)
    if (params.agent) q.set('agent', params.agent)
    if (params.type) q.set('type', params.type)
    const path = `/audit/events.csv?${q.toString()}`
    const url = path.startsWith('/api') ? path : `/api${path}`
    const res = await http.request<string>({
      url,
      method: 'GET',
      responseType: 'text',
      headers: { Authorization: `Bearer ${token}` },
    })
    return res.data
  },

  nhi: {
    scans: (token: string) =>
      req<NHIScanListResponse>('/nhi/scans', token),

    discovered: (token: string, page = 1, limit = 50, status?: string, includeDisconnected = false) => {
      const q = new URLSearchParams({ page: String(page), limit: String(limit) })
      if (status) q.set('status', status)
      if (includeDisconnected) q.set('include_disconnected', 'true')
      return req<NHIDiscoveredResponse>(`/nhi/discovered?${q.toString()}`, token)
    },

    getAccount: (token: string, accountId: string) =>
      req<NHIAccountDetail>(`/nhi/discovered/${accountId}`, token),

    enrollAccount: (token: string, accountId: string) =>
      req<{ account_id: string; status: string }>(`/nhi/discovered/${accountId}/enroll`, token, { method: 'POST' }),

    dismissAccount: (token: string, accountId: string) =>
      req<{ account_id: string; status: string }>(`/nhi/discovered/${accountId}/dismiss`, token, { method: 'POST' }),

    reportJson: (token: string) =>
      req<unknown>('/nhi/report/json', token),
  },

  health: {
    // Takes a signal because CryptographyPage is mounted and unmounted far
    // faster than this call settles, and an uncancellable request there writes
    // React state into a tree that has already gone.
    crypto: (token: string, signal?: AbortSignal) =>
      req<CryptoHealthResponse>('/health/crypto', token, { signal }),
  },

  networkTests: {
    list: (token: string) =>
      req<NetworkTestListResponse>('/network-tests', token),

    // POST with no body — the scan target set is fixed server-side (see
    // fake-integration-proxy/server.py's _netassert_job_manifest); there is
    // nothing for a caller to parameterise.
    scan: (token: string) =>
      req<NetworkTestScanResponse>('/network-tests/scan', token, { method: 'POST' }),
  },

  settings: (token: string) =>
    req<TenantSettingsResponse>('/tenant/settings', token),

  patchFrameworks: (token: string, selectedFrameworks: string[]) =>
    req<TenantSettingsResponse>('/tenant/settings/frameworks', token, {
      method: 'PATCH',
      data: { selected_frameworks: selectedFrameworks },
    }),

  patchPreferences: (token: string, body: PreferencesUpdateRequest) =>
    req<TenantSettingsResponse>('/tenant/settings/preferences', token, {
      method: 'PATCH',
      data: body,
    }),

  support: (token: string, body: SupportRequestCreate) =>
    req<SupportRequestResponse>('/support', token, { method: 'POST', data: body }),

  apiKeys: {
    revealInitial: (token: string, tenantId: string) =>
      req<InitialApiKeyResponse>(`/tenants/${tenantId}/api-keys/initial`, token, { method: 'POST' }),

    rotate: (token: string, tenantId: string) =>
      req<RotateApiKeyResponse>(`/tenants/${tenantId}/api-keys/rotate`, token, { method: 'POST' }),
  },

  compliancePolicy: {
    frameworks: (token: string) =>
      req<FrameworkSummary[]>('/compliance/policy/frameworks', token),

    summary: (token: string) =>
      req<PostureSummary>('/compliance/policy/summary', token),

    scan: (token: string, body: ComplianceScanRequest) =>
      req<{ checks: ComplianceCheck[]; summary: PostureSummary }>(
        '/compliance/policy/scan',
        token,
        { method: 'POST', data: body },
      ),
  },

  consent: {
    status: (token: string) =>
      req<ConsentStatusResponse>('/consent/status', token),

    accept: (token: string, body: ConsentAcceptRequest) =>
      req<ConsentAcceptResponse>('/consent/accept', token, { method: 'POST', data: body }),
  },

  users: (token: string) =>
    req<PlatformUsersResponse>('/tenant/users', token),

  cookiePreferences: {
    get: (token: string) =>
      req<CookiePreferencesResponse>('/cookie-preferences', token),

    patch: (token: string, analytics: boolean) =>
      req<CookiePreferencesResponse>('/cookie-preferences', token, {
        method: 'PATCH',
        data: { analytics },
      }),
  },

  // Per-user, not per-tenant: the caller is identified by the bearer token, so
  // there is no user id in the path. A tenant-scoped path would let one user
  // move another's figures, which is the bug this shape prevents by
  // construction rather than by a permission check.
  userPreferences: {
    get: (token: string) =>
      req<UserPreferencesResponse>('/user/preferences', token),

    patchCurrency: (token: string, displayCurrency: string) =>
      req<UserPreferencesResponse>('/user/preferences', token, {
        method: 'PATCH',
        data: { display_currency: displayCurrency },
      }),
  },
}
