import axios from 'axios'
import { isDemoMode } from './demoMode'
import { hasFakeRoute, resolveFake } from './fakeData'
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
  SupportRequestCreate,
  SupportRequestResponse,
  TenantSettingsResponse,
  TransitionRequest,
  TransitionResponse,
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

// Coalesce identical concurrent GETs so an accidental render storm (or rapid
// re-mounts) cannot fan out into hundreds of duplicate backend calls. Only
// in-flight requests share a promise; sequential and interval refreshes are
// unaffected.
const inflightGets = new Map<string, Promise<unknown>>()

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

async function req<T>(
  path: string,
  token: string,
  config?: { method?: string; data?: unknown },
): Promise<T> {
  const method = config?.method ?? 'GET'
  // Demo mode: short-circuit to local fixtures so every screen renders even
  // when the backend API is unavailable / in development. No call sites change.
  // If a demo route cannot resolve, fail explicitly instead of escaping back to
  // live HTTP and fabricating a "working" demo from partial coverage.
  if (isDemoMode()) {
    const fake = resolveFake(method, path, config?.data)
    if (fake !== undefined) {
      return new Promise<T>((resolve) => setTimeout(() => resolve(fake as T), 120))
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
  const send = () =>
    http
      .request<T>({
        url,
        method,
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
        },
        data: config?.data,
      })
      .then((res) => res.data)

  if (method.toUpperCase() !== 'GET') return send()

  const existing = inflightGets.get(url) as Promise<T> | undefined
  if (existing) return existing
  const promise = send().finally(() => inflightGets.delete(url))
  inflightGets.set(url, promise)
  return promise
}

export const api = {
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
    crypto: (token: string) =>
      req<CryptoHealthResponse>('/health/crypto', token),
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
}
