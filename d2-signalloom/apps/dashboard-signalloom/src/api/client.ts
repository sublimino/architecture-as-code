import axios from 'axios'
import { isDemoMode } from './demoMode'
import { resolveFake } from './fakeData'
import type {
  AgentCreateRequest,
  AgentListResponse,
  AgentResponse,
  AuditListResponse,
  ComplianceSummaryResponse,
  ConsentAcceptRequest,
  ConsentAcceptResponse,
  ConsentStatusResponse,
  CookiePreferencesResponse,
  FrameworkResponse,
  InitialApiKeyResponse,
  IssueCredentialResponse,
  NHIDiscoveredResponse,
  NHIScanListResponse,
  PostureResponse,
  ReassessmentResponse,
  RotateApiKeyResponse,
  SupportRequestCreate,
  SupportRequestResponse,
  TenantSettingsResponse,
  TransitionRequest,
  TransitionResponse,
  ViolationListResponse,
} from '../types/api'

const BASE = (import.meta.env.VITE_API_BASE_URL as string) ?? ''

const http = axios.create({ baseURL: BASE })

// Coalesce identical concurrent GETs so an accidental render storm (or rapid
// re-mounts) cannot fan out into hundreds of duplicate backend calls. Only
// in-flight requests share a promise; sequential and interval refreshes are
// unaffected.
const inflightGets = new Map<string, Promise<unknown>>()

async function req<T>(
  path: string,
  token: string,
  config?: { method?: string; data?: unknown },
): Promise<T> {
  const method = config?.method ?? 'GET'
  // Demo mode: short-circuit to local fixtures so every screen renders even
  // when the backend API is unavailable / in development. No call sites change.
  if (isDemoMode()) {
    const fake = resolveFake(method, path, config?.data)
    if (fake !== undefined) {
      return new Promise<T>((resolve) => setTimeout(() => resolve(fake as T), 120))
    }
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

    get: (token: string, id: string) =>
      req<AgentResponse>(`/agents/${id}`, token),

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

  nhi: {
    scans: (token: string) =>
      req<NHIScanListResponse>('/nhi/scans', token),

    discovered: (token: string, page = 1, limit = 50, status?: string) => {
      const q = new URLSearchParams({ page: String(page), limit: String(limit) })
      if (status) q.set('status', status)
      return req<NHIDiscoveredResponse>(`/nhi/discovered?${q.toString()}`, token)
    },

    enrollAccount: (token: string, accountId: string) =>
      req<{ account_id: string; status: string }>(`/nhi/discovered/${accountId}/enroll`, token, { method: 'POST' }),

    dismissAccount: (token: string, accountId: string) =>
      req<{ account_id: string; status: string }>(`/nhi/discovered/${accountId}/dismiss`, token, { method: 'POST' }),

    reportJson: (token: string) =>
      req<unknown>('/nhi/report/json', token),
  },

  settings: (token: string) =>
    req<TenantSettingsResponse>('/tenant/settings', token),

  patchFrameworks: (token: string, selectedFrameworks: string[]) =>
    req<TenantSettingsResponse>('/tenant/settings/frameworks', token, {
      method: 'PATCH',
      data: { selected_frameworks: selectedFrameworks },
    }),

  support: (token: string, body: SupportRequestCreate) =>
    req<SupportRequestResponse>('/support', token, { method: 'POST', data: body }),

  apiKeys: {
    revealInitial: (token: string, tenantId: string) =>
      req<InitialApiKeyResponse>(`/tenants/${tenantId}/api-keys/initial`, token, { method: 'POST' }),

    rotate: (token: string, tenantId: string) =>
      req<RotateApiKeyResponse>(`/tenants/${tenantId}/api-keys/rotate`, token, { method: 'POST' }),
  },

  consent: {
    status: (token: string) =>
      req<ConsentStatusResponse>('/consent/status', token),

    accept: (token: string, body: ConsentAcceptRequest) =>
      req<ConsentAcceptResponse>('/consent/accept', token, { method: 'POST', data: body }),
  },

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
