import axios from 'axios'
import { isDemoMode, isProductionEnv } from './demoMode'
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

export interface SyncLogEntry {
  id: string
  timestamp: string
  level: 'info' | 'warn' | 'error' | 'debug'
  message: string
  endpoint?: string
  status_code?: number
  duration_ms?: number
  details?: Record<string, unknown>
}

export interface SyncResult {
  provider_id: string
  synced_at: string
  duration_ms: number
  status: 'success' | 'warning' | 'error'
  records_scanned: {
    agents: number
    models: number
    environments: number
    tools: number
  }
  policies_evaluated: {
    egress_rules: number
    violations: number
  }
  logs: SyncLogEntry[]
}

export interface ConnectorsApi {
  listProviders(token: string): Promise<ConnectorProvider[]>
  listConnectors(token: string): Promise<TenantConnector[]>
  createConnector(token: string, body: ConnectorCreateRequest): Promise<TenantConnector>
  deleteConnector(token: string, id: string): Promise<void>
  testConnector(token: string, id: string): Promise<ConnectorTestResult>
  toggleConnector(token: string, id: string, enabled?: boolean): Promise<TenantConnector>
  triggerScan(token: string, providerId: string): Promise<SyncResult>
  getSyncLogs(token: string, providerId: string): Promise<SyncResult>
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

  testConnector: (token, id) =>
    req<ConnectorTestResult>(`/connectors/${id}/test`, token, { method: 'POST' }),

  toggleConnector: async (token, id, enabled) => {
    return req<TenantConnector>(`/connectors/${id}/toggle`, token, {
      method: 'POST',
      data: enabled !== undefined ? { enabled } : {},
    })
  },

  triggerScan: async (token, providerId) => {
    return req<SyncResult>(`/connectors/${providerId}/scan`, token, { method: 'POST' })
  },

  getSyncLogs: async (token, providerId) => {
    return req<SyncResult>(`/connectors/${providerId}/logs`, token)
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

  testConnector: async (_token, id) => {
    const invalid = mockInvalidCredentials.get(id) ?? false
    const expiresAt = invalid ? null : futureIso(90)
    mockConnectors = mockConnectors.map((c) =>
      c.connector_id === id
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
}

function getMockSyncResult(providerId: string): SyncResult {
  const now = new Date().toISOString()
  if (providerId === 'claude') {
    return {
      provider_id: 'claude',
      synced_at: now,
      duration_ms: 142,
      status: 'success',
      records_scanned: {
        agents: 3,
        models: 4,
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
          message: 'Sync completed successfully. 3 agents, 4 models, 1 environment, 2 tools discovered.',
          details: {
            agents: 3,
            models: 4,
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
        agents: 2,
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
            assistants_count: 2,
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

export function isConnectorsMockMode(): boolean {
  const envMode = (import.meta.env.VITE_CONNECTORS_API_MODE as string | undefined)?.toLowerCase()
  if (envMode === 'live') return false
  if (envMode === 'mock') return true
  if (isProductionEnv) return false
  return isDemoMode()
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
  testConnector: (token, id) =>
    isConnectorsMockMode() ? mockConnectorsApi.testConnector(token, id) : liveConnectorsApi.testConnector(token, id),
  toggleConnector: (token, id, enabled) =>
    isConnectorsMockMode() ? mockConnectorsApi.toggleConnector(token, id, enabled) : liveConnectorsApi.toggleConnector(token, id, enabled),
  triggerScan: (token, providerId) =>
    isConnectorsMockMode() ? mockConnectorsApi.triggerScan(token, providerId) : liveConnectorsApi.triggerScan(token, providerId),
  getSyncLogs: (token, providerId) =>
    isConnectorsMockMode() ? mockConnectorsApi.getSyncLogs(token, providerId) : liveConnectorsApi.getSyncLogs(token, providerId),
  getStatus: (token) =>
    isConnectorsMockMode() ? mockConnectorsApi.getStatus(token) : liveConnectorsApi.getStatus(token),
}

export { mockConnectorsApi, liveConnectorsApi, http }

