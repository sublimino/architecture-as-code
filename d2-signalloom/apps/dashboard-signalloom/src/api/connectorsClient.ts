import axios from 'axios'
import { isDemoMode, isProductionEnv } from './demoMode'
import { demoRemoteAgentsSnapshot, remoteEnvironmentFixtures, type RemoteEnvironmentFixture } from './fakeData'
import type {
  ConnectorCreateRequest,
  ConnectorCreateResponse,
  ConnectorDeleteResponse,
  ConnectorProvider,
  ConnectorProvidersResponse,
  ConnectorTestResult,
  TenantConnector,
  TenantConnectorsResponse,
} from '../types/connectors'

// Thin, swappable data layer for the connector framework (ADR-ENHC-012,
// implemented in fe-signalloom routers/connectors.py).
// Dynamically routes to live APIs in production or when demoMode is off.
// VITE_CONNECTORS_API_MODE ('live' or 'mock') provides a build-time override.

const BASE = (import.meta.env.VITE_API_BASE_URL as string) ?? ''
const http = axios.create({ baseURL: BASE })

async function req<T>(
  path: string,
  token: string,
  config?: { method?: string; data?: unknown },
): Promise<T> {
  const url = path.startsWith('/api') ? path : `/api${path}`
  const res = await http.request<T>({
    url,
    method: config?.method ?? 'GET',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    data: config?.data,
  })
  return res.data
}

// POST /connectors/providers/{id}/test: the stored-connector result minus the
// connector it would belong to, since nothing has been saved yet.
export type ProviderCredentialTestResult = Omit<ConnectorTestResult, 'connector_id'>

// endpoint, status_code and details are wire telemetry: the server sends them
// as null to anyone who is not a superadmin.
export interface SyncLogEntry {
  id: string
  timestamp: string
  level: 'info' | 'warn' | 'error' | 'debug'
  message: string
  endpoint?: string | null
  status_code?: number | null
  duration_ms?: number | null
  details?: Record<string, unknown> | null
}

// A null count means the scan did not observe that kind of record (the
// upstream call failed or the provider has no such API), never zero.
export interface SyncResult {
  provider_id: string
  synced_at: string
  duration_ms: number
  status: 'success' | 'warning' | 'error'
  records_scanned: {
    agents: number | null
    models: number | null
    environments: number | null
    tools: number | null
  }
  policies_evaluated: {
    egress_rules: number
    violations: number
  } | null
  logs: SyncLogEntry[]
}

// ─── Remote agent runtime state (GET /connectors/{id}/remote-agents + SSE) ──
//
// What the provider's managed platform reports about its agents, sessions and
// assistants, as last observed by the backend sync engine. Every timestamp is
// null where the engine has not observed it; nothing here is inferred.

/** How the backend learns of changes upstream. Unknown modes pass through as-is. */
export type RemoteSyncMode = 'poll' | 'poll+stream' | 'backoff' | 'stream' | 'webhook'

export interface ConnectorSyncState {
  mode: RemoteSyncMode | (string & {})
  last_poll_at: string | null
  last_success_at: string | null
  last_error: string | null
  next_poll_at: string | null
  /** Present on the backend's sync_state; drives the backoff label. */
  consecutive_failures?: number
}

export interface RemoteAgent {
  external_id: string
  kind: 'agent' | 'session' | 'assistant' | (string & {})
  name: string | null
  model: string | null
  status: string | null
  version: string | number | null
  external_updated_at: string | null
  first_seen_at: string | null
  last_seen_at: string | null
  last_changed_at: string | null
  /** Set once the provider stops reporting it; the row is kept, not deleted. */
  gone_at: string | null
  /** The registry agent this was claimed as (POST .../claim), or null. Absent in older payloads. */
  claimed_agent_id?: string | null
  claimed_at?: string | null
}

export interface RemoteAgentsSnapshot {
  provider_id: string
  connector_id: string
  sync_state: ConnectorSyncState
  agents: RemoteAgent[]
}

/** Decoded events from GET /connectors/stream. */
export type ConnectorStreamEvent =
  | { type: 'remote_agent.upserted'; provider_id: string; connector_id: string; agent: RemoteAgent }
  | { type: 'remote_agent.gone'; provider_id: string; connector_id: string; external_id: string; gone_at: string }
  | { type: 'connector.sync_state'; provider_id: string; connector_id: string; sync_state: ConnectorSyncState }
  /** The server could not replay from Last-Event-ID; every snapshot must be refetched. */
  | { type: 'stream.reset' }

/** Absolute URL of the connector event stream. */
export function connectorStreamUrl(): string {
  return `${BASE}/api/connectors/stream`
}

// The API's error envelope is {"error": {"code", "message"}}; null when the
// failure carries no such code (network down, non-API response).
export function apiErrorCode(err: unknown): string | null {
  if (!axios.isAxiosError(err)) return null
  const code = (err.response?.data as { error?: { code?: unknown } } | undefined)?.error?.code
  return typeof code === 'string' ? code : null
}

const CONNECTOR_ERROR_COPY: Record<string, string> = {
  connector_not_configured: 'This provider is not connected for your tenant. Configure it first.',
  scan_unsupported: 'Scanning is not supported for this provider yet.',
  never_scanned: 'This connector has not been scanned yet.',
  test_unsupported: 'Credential testing is not supported for this provider yet.',
}

/** A user-facing sentence for a failed connectors API call. */
export function connectorErrorMessage(err: unknown, fallback = 'The connectors API request failed.'): string {
  const code = apiErrorCode(err)
  if (code && CONNECTOR_ERROR_COPY[code]) return CONNECTOR_ERROR_COPY[code]
  if (axios.isAxiosError(err)) {
    const message = (err.response?.data as { error?: { message?: unknown } } | undefined)?.error?.message
    if (typeof message === 'string' && message) return message
  }
  return err instanceof Error && err.message ? err.message : fallback
}

// Providers whose connector has a remote-environment view.
export const REMOTE_ENVIRONMENT_PROVIDERS = ['claude', 'openai'] as const
export type RemoteEnvironmentProviderId = (typeof REMOTE_ENVIRONMENT_PROVIDERS)[number]

export function isRemoteEnvironmentProvider(id: string | undefined): id is RemoteEnvironmentProviderId {
  return (REMOTE_ENVIRONMENT_PROVIDERS as readonly string[]).includes(id ?? '')
}

export interface ConnectorsApi {
  listProviders(token: string): Promise<ConnectorProvider[]>
  listConnectors(token: string): Promise<TenantConnector[]>
  createConnector(token: string, body: ConnectorCreateRequest): Promise<TenantConnector>
  deleteConnector(token: string, id: string): Promise<void>
  testConnector(token: string, id: string, credentials?: Record<string, string>): Promise<ConnectorTestResult>
  // Tests credentials before anything is saved. The server answers 501
  // test_unsupported when the provider has no real verifier; a caller must
  // report that as "not checked", never as a pass.
  testProviderCredentials(
    token: string,
    providerId: string,
    credentials: Record<string, string>,
  ): Promise<ProviderCredentialTestResult>
  toggleConnector(token: string, id: string, enabled?: boolean): Promise<TenantConnector>
  triggerScan(token: string, providerId: string): Promise<SyncResult>
  /** The last scan's result, or null when the connector has never been scanned. */
  getSyncLogs(token: string, providerId: string): Promise<SyncResult | null>
  /** Remote agents/sessions and sync state, or null when the provider is not connected. */
  listRemoteAgents(token: string, providerId: string): Promise<RemoteAgentsSnapshot | null>
  getStatus(token: string): Promise<{
    status: string
    synced_at: string
    total_connectors: number
    active_connectors: number
    connectors: TenantConnector[]
  }>
}

const liveConnectorsApi: ConnectorsApi = {
  listProviders: async (token) => {
    const res = await req<ConnectorProvidersResponse>('/connectors/providers', token)
    return res.providers
  },

  listConnectors: async (token) => {
    const res = await req<TenantConnectorsResponse>('/connectors', token)
    return res.connectors
  },

  createConnector: async (token, body) => {
    await req<ConnectorCreateResponse>('/connectors', token, { method: 'POST', data: body })
    const res = await req<TenantConnectorsResponse>('/connectors', token)
    const match = res.connectors.find(
      (c) => c.provider_id === body.provider_id && c.status !== 'disconnected',
    )
    if (!match) throw new Error('Connector was created but did not appear in the connector list.')
    return match
  },

  deleteConnector: async (token, id) => {
    await req<ConnectorDeleteResponse>(`/connectors/${id}`, token, { method: 'DELETE' })
  },

  testConnector: (token, id, credentials) =>
    req<ConnectorTestResult>(`/connectors/${id}/test`, token, {
      method: 'POST',
      data: credentials ? { credentials } : undefined,
    }),

  testProviderCredentials: (token, providerId, credentials) =>
    req<ProviderCredentialTestResult>(`/connectors/providers/${encodeURIComponent(providerId)}/test`, token, {
      method: 'POST',
      data: { credentials },
    }),

  toggleConnector: async (token, id, enabled) => {
    return req<TenantConnector>(`/connectors/${id}/toggle`, token, {
      method: 'POST',
      data: enabled !== undefined ? { enabled } : {},
    })
  },

  triggerScan: (token, providerId) =>
    req<SyncResult>(`/connectors/${providerId}/scan`, token, { method: 'POST' }),

  getSyncLogs: async (token, providerId) => {
    try {
      return await req<SyncResult>(`/connectors/${providerId}/logs`, token)
    } catch (err) {
      if (apiErrorCode(err) === 'never_scanned') return null
      throw err
    }
  },

  listRemoteAgents: async (token, providerId) => {
    try {
      return await req<RemoteAgentsSnapshot>(`/connectors/${encodeURIComponent(providerId)}/remote-agents`, token)
    } catch (err) {
      if (apiErrorCode(err) === 'connector_not_configured') return null
      throw err
    }
  },

  getStatus: async (token) => {
    return req<{
      status: string
      synced_at: string
      total_connectors: number
      active_connectors: number
      connectors: TenantConnector[]
    }>('/connectors/status', token)
  },
}

// ─── Mock implementation ──────────────────────────────────────────────────

const MOCK_PROVIDERS: ConnectorProvider[] = [
  {
    provider_id: 'aws_iam',
    display_name: 'AWS IAM',
    wizard_config: {
      fields: [
        { name: 'account_id', label: 'AWS account ID', type: 'text', required: true, placeholder: '123456789012' },
        { name: 'role_arn', label: 'Cross-account role ARN', type: 'text', required: true, placeholder: 'arn:aws:iam::123456789012:role/signal-loom-readonly' },
        { name: 'external_id', label: 'External ID', type: 'password', required: true },
      ],
      permissions: ['iam:ListUsers', 'iam:ListAccessKeys', 'iam:ListRoles'],
      docs_link: 'https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-user_externalid.html',
      help_text: 'Grant a cross-account role scoped to read-only IAM actions and require the external ID above.',
    },
  },
  {
    provider_id: 'gcp_iam',
    display_name: 'GCP IAM',
    wizard_config: {
      fields: [
        { name: 'project_id', label: 'GCP project ID', type: 'text', required: true },
        { name: 'service_account_key', label: 'Service account key (JSON)', type: 'password', required: true },
      ],
      permissions: ['iam.serviceAccounts.list', 'resourcemanager.projects.getIamPolicy'],
      docs_link: 'https://cloud.google.com/iam/docs/keys-create-delete',
      help_text: 'Use a service account with the read-only IAM viewer role.',
    },
  },
  {
    provider_id: 'ad_entra',
    display_name: 'Microsoft Entra ID',
    wizard_config: {
      fields: [
        { name: 'tenant_directory_id', label: 'Directory (tenant) ID', type: 'text', required: true, placeholder: '00000000-0000-0000-0000-000000000000' },
        { name: 'client_id', label: 'Application (client) ID', type: 'text', required: true },
        { name: 'client_secret', label: 'Client secret', type: 'password', required: true },
      ],
      permissions: ['Directory.Read.All', 'User.Read.All'],
      docs_link: '/help/connectors/entra',
      help_text: 'Create an app registration with Directory.Read.All (application permission, admin consented) and use its credentials here.',
    },
  },
  {
    provider_id: 'k8s',
    display_name: 'Kubernetes Cluster',
    wizard_config: {
      fields: [
        { name: 'cluster_name', label: 'Cluster name', type: 'text', required: true, placeholder: 'cluster-prod-01' },
        { name: 'kubeconfig', label: 'Kubeconfig or service account token', type: 'password', required: true },
      ],
      permissions: ['pods:list', 'serviceaccounts:list', 'namespaces:list'],
      docs_link: '/help/connectors/k8s',
      help_text: 'Provide read-only credentials to discover running pod workloads.',
    },
  },
  {
    provider_id: 'github',
    display_name: 'GitHub',
    wizard_config: {
      fields: [
        { name: 'organization', label: 'GitHub organization', type: 'text', required: true, placeholder: 'org-name' },
        { name: 'personal_access_token', label: 'Personal access token', type: 'password', required: true },
      ],
      permissions: ['read:org', 'repo:status'],
      docs_link: '/help/connectors/github',
      help_text: 'Generate a fine-grained personal access token with organization read permissions.',
    },
  },
  {
    provider_id: 'okta',
    display_name: 'Okta',
    wizard_config: {
      fields: [
        { name: 'okta_domain', label: 'Okta domain', type: 'text', required: true, placeholder: 'your-org.okta.com' },
        { name: 'api_token', label: 'API token', type: 'password', required: true },
      ],
      permissions: ['okta.users.read', 'okta.apps.read'],
      docs_link: '/help/connectors/okta',
      help_text: 'Generate a read-only API token from an Okta service account with the scopes above.',
    },
  },
  {
    provider_id: 'claude',
    display_name: 'Anthropic Claude',
    wizard_config: {
      fields: [
        { name: 'api_key', label: 'Anthropic API Key', type: 'password', required: true, placeholder: 'sk-ant-...' },
        { name: 'workspace_id', label: 'Workspace ID (optional)', type: 'text', required: false, placeholder: 'wrkspc_xxxxxxxxxxxx' },
        { name: 'admin_api_key', label: 'Admin API Key (optional)', type: 'password', required: false, placeholder: 'sk-ant-admin...' },
      ],
      permissions: ['models.read', 'messages.batches.read'],
      docs_link: '/help/connectors/claude',
      help_text: 'Provide a read-only Anthropic API key to discover models, batches, and agent telemetry.',
    },
  },
  {
    provider_id: 'openai',
    display_name: 'OpenAI',
    wizard_config: {
      fields: [
        { name: 'api_key', label: 'OpenAI API Key', type: 'password', required: true, placeholder: 'sk-...' },
        { name: 'openai_org_id', label: 'Organization ID (optional)', type: 'text', required: false, placeholder: 'org-xxxxxxxx' },
      ],
      permissions: ['api.management.read'],
      docs_link: '/help/connectors/openai',
      help_text: 'Create an Admin API key and use it here to discover assistant credentials.',
    },
  },
  {
    provider_id: 'google_workspace',
    display_name: 'Google Workspace',
    wizard_config: {
      fields: [
        { name: 'admin_email', label: 'Admin email (for domain-wide delegation)', type: 'text', required: true },
        { name: 'customer_id', label: 'Customer ID', type: 'text', required: false, placeholder: 'C0xxxxxxx' },
        { name: 'service_account_json', label: 'Service account key (JSON)', type: 'password', required: true },
      ],
      permissions: ['admin.directory.user.readonly', 'admin.directory.rolemanagement.readonly'],
      docs_link: 'https://developers.google.com/workspace/guides/create-credentials',
      help_text: 'Use a service account with domain-wide delegation scoped to the read-only Admin SDK scopes above.',
    },
  },
]

function futureIso(daysOut: number): string {
  return new Date(Date.now() + daysOut * 24 * 60 * 60 * 1000).toISOString()
}

let mockConnectors: TenantConnector[] = [
  {
    connector_id: 'conn-aws-01',
    provider_id: 'aws_iam',
    display_name: 'AWS Production',
    status: 'connected',
    credential_expires_at: futureIso(90),
    last_tested_at: new Date().toISOString(),
    last_scan_at: new Date().toISOString(),
    metadata: { region: 'us-east-1' },
    created_at: new Date().toISOString(),
  },
  {
    connector_id: 'conn-gcp-01',
    provider_id: 'gcp_iam',
    display_name: 'GCP Europe-West',
    status: 'connected',
    credential_expires_at: futureIso(90),
    last_tested_at: new Date().toISOString(),
    last_scan_at: new Date().toISOString(),
    metadata: { project_id: 'signalloom-prod' },
    created_at: new Date().toISOString(),
  },
  {
    connector_id: 'conn-azure-01',
    provider_id: 'ad_entra',
    display_name: 'Microsoft Entra ID',
    status: 'connected',
    credential_expires_at: futureIso(90),
    last_tested_at: new Date().toISOString(),
    last_scan_at: new Date().toISOString(),
    metadata: { tenant_name: 'corp.contoso.com' },
    created_at: new Date().toISOString(),
  },
  {
    connector_id: 'conn-k8s-01',
    provider_id: 'k8s',
    display_name: 'Kubernetes Cluster Local',
    status: 'connected',
    credential_expires_at: futureIso(90),
    last_tested_at: new Date().toISOString(),
    last_scan_at: new Date().toISOString(),
    metadata: { cluster_id: 'cluster-local' },
    created_at: new Date().toISOString(),
  },
  {
    connector_id: 'conn-github-01',
    provider_id: 'github',
    display_name: 'GitHub Enterprise',
    status: 'connected',
    credential_expires_at: futureIso(90),
    last_tested_at: new Date().toISOString(),
    last_scan_at: new Date().toISOString(),
    metadata: { org: 'signalloom-corp' },
    created_at: new Date().toISOString(),
  },
  {
    connector_id: 'conn-claude-01',
    provider_id: 'claude',
    display_name: 'Anthropic Claude',
    status: 'connected',
    credential_expires_at: futureIso(90),
    last_tested_at: new Date().toISOString(),
    last_scan_at: new Date().toISOString(),
    metadata: { workspace_id: 'wrkspc_signalloom_demo' },
    created_at: new Date().toISOString(),
  },
  {
    connector_id: 'conn-openai-01',
    provider_id: 'openai',
    display_name: 'OpenAI Production',
    status: 'connected',
    credential_expires_at: futureIso(90),
    last_tested_at: new Date().toISOString(),
    last_scan_at: new Date().toISOString(),
    metadata: { openai_org_id: 'org-signalloom' },
    created_at: new Date().toISOString(),
  },
]

let mockIdSeq = 10
const mockInvalidCredentials = new Map<string, boolean>()

function delay<T>(value: T, ms = 50): Promise<T> {
  return new Promise((resolve) => setTimeout(() => resolve(value), ms))
}

const mockConnectorsApi: ConnectorsApi = {
  listProviders: () => delay(MOCK_PROVIDERS),

  listConnectors: () => delay([...mockConnectors]),

  createConnector: async (_token, body) => {
    const provider = MOCK_PROVIDERS.find((p) => p.provider_id === body.provider_id)
    const connector: TenantConnector = {
      connector_id: `mock-${mockIdSeq++}`,
      provider_id: body.provider_id,
      display_name: body.display_name ?? provider?.display_name ?? body.provider_id,
      status: 'connected',
      credential_expires_at: null,
      last_tested_at: null,
      last_scan_at: null,
      metadata: body.metadata ?? {},
      created_at: new Date().toISOString(),
    }
    mockConnectors = [...mockConnectors.filter((c) => c.provider_id !== body.provider_id), connector]
    mockInvalidCredentials.set(
      connector.connector_id,
      Object.values(body.credentials).some((v) => v.toLowerCase().includes('invalid')),
    )
    return delay(connector, 100)
  },

  deleteConnector: async (_token, id) => {
    mockConnectors = mockConnectors.map((c) =>
      c.connector_id === id ? { ...c, status: 'disconnected' as const } : c,
    )
    return delay(undefined, 80)
  },

  testConnector: async (_token, id, credentials) => {
    const invalid =
      (mockInvalidCredentials.get(id) ?? false) ||
      Boolean(credentials && Object.values(credentials).some((v) => v.toLowerCase().includes('invalid')))
    const expiresAt = invalid ? null : futureIso(90)
    mockConnectors = mockConnectors.map((c) =>
      c.connector_id === id || c.provider_id === id
        ? {
            ...c,
            last_tested_at: new Date().toISOString(),
            credential_expires_at: expiresAt,
            status: invalid ? ('error' as const) : ('connected' as const),
          }
        : c,
    )
    const result: ConnectorTestResult = {
      connector_id: id,
      valid: !invalid,
      scopes_ok: !invalid,
      error_msg: invalid ? 'Invalid credentials (mock).' : null,
      credential_expires_at: expiresAt,
      needs_rotation: false,
      message: invalid
        ? '✗ Authentication failed: Invalid credentials'
        : id === 'claude'
        ? '✓ Verified connection to Anthropic Claude API. Discovered live agent: Daily News Jokester'
        : id === 'openai'
        ? '✓ Verified connection to OpenAI Platform API. Discovered live agent: Customer Support Triage Assistant'
        : `✓ Connection verified for ${id}.`,
    }
    return delay(result, 100)
  },

  testProviderCredentials: async (_token, _providerId, credentials) => {
    const invalid = Object.values(credentials).some((v) => v.toLowerCase().includes('invalid'))
    const result: ProviderCredentialTestResult = {
      valid: !invalid,
      scopes_ok: !invalid,
      error_msg: invalid ? 'Invalid credentials (mock).' : null,
      credential_expires_at: invalid ? null : futureIso(90),
      needs_rotation: false,
    }
    return delay(result, 100)
  },

  toggleConnector: async (_token, id, enabled) => {
    const match = mockConnectors.find((c) => c.connector_id === id || c.provider_id === id)
    if (!match) {
      throw new Error(`Connector ${id} not found`)
    }
    const nextStatus = enabled !== undefined ? (enabled ? 'connected' : 'disconnected') : (match.status === 'connected' ? 'disconnected' : 'connected')
    const updated: TenantConnector = {
      ...match,
      status: nextStatus,
      last_tested_at: new Date().toISOString(),
    }
    mockConnectors = mockConnectors.map((c) => (c.connector_id === match.connector_id ? updated : c))
    return delay(updated, 80)
  },

  getStatus: async (_token) => {
    const active = mockConnectors.filter((c) => c.status === 'connected').length
    return delay(
      {
        status: active > 0 ? 'healthy' : 'degraded',
        synced_at: new Date().toISOString(),
        total_connectors: mockConnectors.length,
        active_connectors: active,
        connectors: [...mockConnectors],
      },
      80,
    )
  },

  triggerScan: async (_token, providerId) => {
    const now = new Date().toISOString()
    mockConnectors = mockConnectors.map((c) =>
      c.provider_id === providerId || c.connector_id === providerId
        ? { ...c, last_scan_at: now }
        : c,
    )
    return delay(getMockSyncResult(providerId), 120)
  },

  getSyncLogs: async (_token, providerId) => {
    return delay(getMockSyncResult(providerId), 60)
  },

  listRemoteAgents: (_token, providerId) => delay(demoRemoteAgentsSnapshot(providerId), 40),
}

function getMockSyncResult(providerId: string): SyncResult {
  const now = new Date().toISOString()
  const claudeAgents = remoteEnvironmentFixtures.claude.connectedAgents.length
  const openaiAgents = remoteEnvironmentFixtures.openai.connectedAgents.length
  if (providerId === 'claude') {
    return {
      provider_id: 'claude',
      synced_at: now,
      duration_ms: 142,
      status: 'success',
      records_scanned: {
        agents: claudeAgents,
        models: 3,
        environments: 1,
        tools: 2,
      },
      policies_evaluated: {
        egress_rules: 2,
        violations: 0,
      },
      logs: [
        {
          id: 'log-claude-1',
          timestamp: new Date(Date.now() - 140).toISOString(),
          level: 'info',
          message: 'Initiating discovery sync with Anthropic Claude API...',
        },
        {
          id: 'log-claude-2',
          timestamp: new Date(Date.now() - 110).toISOString(),
          level: 'debug',
          message: 'Discovered model catalog: claude-3-5-sonnet-20241022, claude-3-haiku-20240307, claude-3-opus-20240229',
          endpoint: 'GET /v1/models',
          status_code: 200,
          duration_ms: 142,
          details: {
            models: ['claude-3-5-sonnet-20241022', 'claude-3-haiku-20240307', 'claude-3-opus-20240229'],
            default_context: 200000,
            max_tokens: 8192,
          },
        },
        {
          id: 'log-claude-3',
          timestamp: new Date(Date.now() - 85).toISOString(),
          level: 'debug',
          message: 'Queried batch message processing queues (0 active batches)',
          endpoint: 'GET /v1/messages/batches',
          status_code: 200,
          duration_ms: 98,
          details: {
            active_batches: 0,
            pending_batches: 0,
            queue_status: 'idle',
          },
        },
        {
          id: 'log-claude-4',
          timestamp: new Date(Date.now() - 60).toISOString(),
          level: 'info',
          message: 'Inspecting remote execution environment cloud-dev (env_01CyCigBbDRSLTzSCyyHQ7eT)',
          details: {
            environment_id: 'env_01CyCigBbDRSLTzSCyyHQ7eT',
            name: 'cloud-dev',
            runtime: 'linux-container',
          },
        },
        {
          id: 'log-claude-5',
          timestamp: new Date(Date.now() - 40).toISOString(),
          level: 'debug',
          message: 'Audited egress policy: checking allowed hosts 0/16 restrictions',
          endpoint: 'GET /v1/environments/env_01CyCigBbDRSLTzSCyyHQ7eT/networking',
          status_code: 200,
          duration_ms: 84,
          details: {
            allowed_hosts_count: 0,
            max_hosts: 16,
            cel_rules_enforced: true,
            default_egress: 'deny',
          },
        },
        {
          id: 'log-claude-6',
          timestamp: new Date(Date.now() - 20).toISOString(),
          level: 'info',
          message: 'Verified agent sandbox tools: MCP servers allowed, package managers allowed',
          details: {
            mcp_servers_allowed: true,
            package_managers_allowed: true,
            sandboxing: 'landlock',
          },
        },
        {
          id: 'log-claude-7',
          timestamp: now,
          level: 'info',
          message: `Sync completed successfully. ${claudeAgents} agents, 3 models, 1 environment, 2 tools discovered.`,
          details: {
            agents: claudeAgents,
            models: 3,
            environments: 1,
            tools: 2,
          },
        },
      ],
    }
  }

  if (providerId === 'openai') {
    return {
      provider_id: 'openai',
      synced_at: now,
      duration_ms: 168,
      status: 'success',
      records_scanned: {
        agents: openaiAgents,
        models: 3,
        environments: 1,
        tools: 3,
      },
      policies_evaluated: {
        egress_rules: 2,
        violations: 0,
      },
      logs: [
        {
          id: 'log-openai-1',
          timestamp: new Date(Date.now() - 160).toISOString(),
          level: 'info',
          message: 'Connecting to OpenAI API management endpoint...',
        },
        {
          id: 'log-openai-2',
          timestamp: new Date(Date.now() - 120).toISOString(),
          level: 'debug',
          message: 'Scanned OpenAI models: gpt-4o, gpt-4o-mini, o1-preview',
          endpoint: 'GET /v1/models',
          status_code: 200,
          duration_ms: 110,
          details: {
            models: ['gpt-4o', 'gpt-4o-mini', 'o1-preview'],
            organization: 'org-signalloom',
          },
        },
        {
          id: 'log-openai-3',
          timestamp: new Date(Date.now() - 70).toISOString(),
          level: 'debug',
          message: 'Discovered assistant definitions and tools',
          endpoint: 'GET /v1/assistants',
          status_code: 200,
          duration_ms: 135,
          details: {
            assistants_count: openaiAgents,
            code_interpreter_enabled: true,
            file_search_enabled: true,
          },
        },
        {
          id: 'log-openai-4',
          timestamp: new Date(Date.now() - 30).toISOString(),
          level: 'info',
          message: 'CEL network policy evaluation passed with 0 egress violations.',
          details: {
            rules_evaluated: 2,
            violations: 0,
          },
        },
        {
          id: 'log-openai-5',
          timestamp: now,
          level: 'info',
          message: 'OpenAI discovery sync completed successfully.',
        },
      ],
    }
  }

  if (providerId === 'dex') {
    return {
      provider_id: 'dex',
      synced_at: now,
      duration_ms: 88,
      status: 'success',
      records_scanned: {
        agents: 1,
        models: 0,
        environments: 1,
        tools: 0,
      },
      policies_evaluated: {
        egress_rules: 1,
        violations: 0,
      },
      logs: [
        {
          id: 'log-dex-1',
          timestamp: new Date(Date.now() - 80).toISOString(),
          level: 'info',
          message: 'Contacting Dex OIDC identity provider discovery endpoint...',
        },
        {
          id: 'log-dex-2',
          timestamp: new Date(Date.now() - 50).toISOString(),
          level: 'debug',
          message: 'Fetched OIDC discovery document and JWKS keys',
          endpoint: 'GET /.well-known/openid-configuration',
          status_code: 200,
          duration_ms: 45,
          details: {
            issuer: 'https://dex.inf-signalloom.svc.cluster.local:5556/dex',
            signing_algs: ['RS256'],
          },
        },
        {
          id: 'log-dex-3',
          timestamp: new Date(Date.now() - 25).toISOString(),
          level: 'debug',
          message: 'Retrieved registered OAuth2 client definitions',
          endpoint: 'GET /api/v1/auth/clients',
          status_code: 200,
          duration_ms: 55,
          details: {
            client_count: 4,
          },
        },
        {
          id: 'log-dex-4',
          timestamp: now,
          level: 'info',
          message: 'Dex identity provider sync completed successfully.',
        },
      ],
    }
  }

  // Fallback for any other provider
  return {
    provider_id: providerId,
    synced_at: now,
    duration_ms: 120,
    status: 'success',
    records_scanned: {
      agents: 2,
      models: 1,
      environments: 1,
      tools: 1,
    },
    policies_evaluated: {
      egress_rules: 2,
      violations: 0,
    },
    logs: [
      {
        id: `log-${providerId}-1`,
        timestamp: new Date(Date.now() - 110).toISOString(),
        level: 'info',
        message: `Initiating discovery sync with ${providerId} provider...`,
      },
      {
        id: `log-${providerId}-2`,
        timestamp: new Date(Date.now() - 60).toISOString(),
        level: 'debug',
        message: `Queried service accounts and roles from ${providerId}`,
        endpoint: `/api/v1/${providerId}/resources`,
        status_code: 200,
        duration_ms: 120,
        details: { provider: providerId, status: 'synced' },
      },
      {
        id: `log-${providerId}-3`,
        timestamp: now,
        level: 'info',
        message: `Sync completed successfully for ${providerId}.`,
      },
    ],
  }
}

export function resolveConnectorsMockMode(envMode: string | undefined, production: boolean, demo: boolean): boolean {
  if (production) return false
  if (envMode === 'live') return false
  if (envMode === 'mock') return true
  return demo
}

export function isConnectorsMockMode(): boolean {
  const envMode = (import.meta.env.VITE_CONNECTORS_API_MODE as string | undefined)?.toLowerCase()
  return resolveConnectorsMockMode(envMode, isProductionEnv, isDemoMode())
}

/**
 * The demo remote-environment fixture for a provider, or null in live mode.
 * Pages get demo content only through this gate, never by importing fakeData.
 */
export function demoRemoteEnvironment(providerId: RemoteEnvironmentProviderId): RemoteEnvironmentFixture | null {
  return isConnectorsMockMode() ? remoteEnvironmentFixtures[providerId] : null
}

export const connectorsApi: ConnectorsApi = {
  listProviders: (token) =>
    isConnectorsMockMode() ? mockConnectorsApi.listProviders(token) : liveConnectorsApi.listProviders(token),
  listConnectors: (token) =>
    isConnectorsMockMode() ? mockConnectorsApi.listConnectors(token) : liveConnectorsApi.listConnectors(token),
  createConnector: (token, body) =>
    isConnectorsMockMode() ? mockConnectorsApi.createConnector(token, body) : liveConnectorsApi.createConnector(token, body),
  deleteConnector: (token, id) =>
    isConnectorsMockMode() ? mockConnectorsApi.deleteConnector(token, id) : liveConnectorsApi.deleteConnector(token, id),
  testConnector: (token, id, credentials) =>
    isConnectorsMockMode()
      ? mockConnectorsApi.testConnector(token, id, credentials)
      : liveConnectorsApi.testConnector(token, id, credentials),
  testProviderCredentials: (token, providerId, credentials) =>
    isConnectorsMockMode()
      ? mockConnectorsApi.testProviderCredentials(token, providerId, credentials)
      : liveConnectorsApi.testProviderCredentials(token, providerId, credentials),
  toggleConnector: (token, id, enabled) =>
    isConnectorsMockMode() ? mockConnectorsApi.toggleConnector(token, id, enabled) : liveConnectorsApi.toggleConnector(token, id, enabled),
  triggerScan: (token, providerId) =>
    isConnectorsMockMode() ? mockConnectorsApi.triggerScan(token, providerId) : liveConnectorsApi.triggerScan(token, providerId),
  getSyncLogs: (token, providerId) =>
    isConnectorsMockMode() ? mockConnectorsApi.getSyncLogs(token, providerId) : liveConnectorsApi.getSyncLogs(token, providerId),
  listRemoteAgents: (token, providerId) =>
    isConnectorsMockMode()
      ? mockConnectorsApi.listRemoteAgents(token, providerId)
      : liveConnectorsApi.listRemoteAgents(token, providerId),
  getStatus: (token) =>
    isConnectorsMockMode() ? mockConnectorsApi.getStatus(token) : liveConnectorsApi.getStatus(token),
}

export { mockConnectorsApi, liveConnectorsApi, http }

// ── Discovery page: per-source sync state (W13, read-only) ──────────────────
// Kept as one self-contained block so it merges cleanly beside the shared
// remote-agent store. It reads GET /connectors/{provider_id}/remote-agents
// only for its sync_state; the agents themselves reach the Discovery page as
// rows of GET /discovery/workloads. Once the shared store's listRemoteAgents
// is on the same line, this can collapse onto it.

export interface DiscoverySourceSyncState {
  mode: string
  last_poll_at: string | null
  last_success_at: string | null
  last_error: string | null
  next_poll_at: string | null
  /** Present on the backend's sync_state; drives the backoff label. */
  consecutive_failures?: number
}

export interface DiscoverySourceSnapshot {
  provider_id: string
  connector_id: string
  sync_state: DiscoverySourceSyncState | null
}

/**
 * The backend sync engine's state for one provider, or null when there is
 * none to report: the connector is not configured (404
 * connector_not_configured) or the connectors API is in mock mode, where no
 * sync engine exists and none is invented.
 */
export async function getDiscoverySourceSyncState(
  token: string,
  providerId: string,
): Promise<DiscoverySourceSnapshot | null> {
  if (isConnectorsMockMode()) return null
  try {
    const res = await req<DiscoverySourceSnapshot>(
      `/connectors/${encodeURIComponent(providerId)}/remote-agents`,
      token,
    )
    return { provider_id: res.provider_id, connector_id: res.connector_id, sync_state: res.sync_state ?? null }
  } catch (err) {
    if (apiErrorCode(err) === 'connector_not_configured') return null
    throw err
  }
}

// ── Remote agent claim (W14) ────────────────────────────────────────────────
// POST /connectors/{provider_id}/remote-agents/{external_id}/claim links a
// remote agent the sync observed to a tenant registry agent. 201 the first
// time, 200 with the same agent after; 404 connector_not_configured /
// remote_agent_not_found, 409 remote_agent_gone. Demo mode has no remote
// agents to claim, so it refuses rather than inventing a registry agent.

export interface RemoteAgentClaim {
  agent_id: string
  agent_name: string
  display_name: string
  provider_id: string
  connector_id: string
  external_id: string
  kind: string
  model: string | null
  claimed_at: string | null
  /** False when the agent was already claimed and this returned the existing link. */
  created: boolean
}

export async function claimRemoteAgent(token: string, providerId: string, externalId: string): Promise<RemoteAgentClaim> {
  if (isConnectorsMockMode()) {
    throw new Error('Claiming a provider-hosted agent needs the live connectors API; demo mode has none to claim.')
  }
  return req<RemoteAgentClaim>(
    `/connectors/${encodeURIComponent(providerId)}/remote-agents/${encodeURIComponent(externalId)}/claim`,
    token,
    { method: 'POST' },
  )
}

