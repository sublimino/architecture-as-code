import axios from 'axios'
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
// implemented in PR #19 on services/agent_registry/routers/connectors.py).
// VITE_CONNECTORS_API_MODE defaults to 'mock' — flip to 'live' once PR #19
// merges and this is wired against a real dev deployment.
//
// Shapes below are read directly off the PR #19 diff, not guessed from the
// ADR:
//   GET  /connectors/providers -> { providers: [...] }
//   GET  /connectors           -> { connectors: [...] }  (rows use `connector_id`,
//                                   not `id`)
//   POST /connectors           -> thin { connector_id, provider_id, status,
//                                   created_at } — NOT a full connector row
//   DELETE /connectors/{id}    -> { connector_id, status } (404 if already
//                                   disconnected)
//   POST /connectors/{id}/test -> { connector_id, valid, scopes_ok, error_msg,
//                                   credential_expires_at, needs_rotation } —
//                                   no `days_until_expiry`

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

export interface ConnectorsApi {
  listProviders(token: string): Promise<ConnectorProvider[]>
  listConnectors(token: string): Promise<TenantConnector[]>
  createConnector(token: string, body: ConnectorCreateRequest): Promise<TenantConnector>
  deleteConnector(token: string, id: string): Promise<void>
  testConnector(token: string, id: string): Promise<ConnectorTestResult>
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
    // The create response is thin (no display_name/expiry/metadata) — refetch
    // to get the full row rather than hand-assembling a partial one.
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
}

// ─── Mock implementation ──────────────────────────────────────────────────

const MOCK_PROVIDERS: ConnectorProvider[] = [
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
      docs_link: 'https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app',
      help_text: 'Create an app registration with Directory.Read.All (application permission, admin consented) and use its credentials here.',
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
      docs_link: 'https://developer.okta.com/docs/guides/create-an-api-token/main/',
      help_text: 'Generate a read-only API token from an Okta service account with the scopes above.',
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
]

// Module-level, in-memory only — resets on reload. Stands in for the real
// tenant_connectors table until PR #19 merges and dev is wired to it.
let mockConnectors: TenantConnector[] = []
let mockIdSeq = 1

function delay<T>(value: T, ms = 220): Promise<T> {
  return new Promise((resolve) => setTimeout(() => resolve(value), ms))
}

function futureIso(daysOut: number): string {
  return new Date(Date.now() + daysOut * 24 * 60 * 60 * 1000).toISOString()
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
      // Real backend leaves this null until the first POST /test call.
      credential_expires_at: null,
      last_tested_at: null,
      last_scan_at: null,
      metadata: body.metadata ?? {},
      created_at: new Date().toISOString(),
    }
    mockConnectors = [...mockConnectors.filter((c) => c.provider_id !== body.provider_id), connector]
    return delay(connector, 400)
  },

  deleteConnector: async (_token, id) => {
    mockConnectors = mockConnectors.map((c) =>
      c.connector_id === id ? { ...c, status: 'disconnected' as const } : c,
    )
    return delay(undefined, 250)
  },

  testConnector: async (_token, id) => {
    const expiresAt = futureIso(90)
    mockConnectors = mockConnectors.map((c) =>
      c.connector_id === id
        ? { ...c, last_tested_at: new Date().toISOString(), credential_expires_at: expiresAt, status: 'connected' as const }
        : c,
    )
    const result: ConnectorTestResult = {
      connector_id: id,
      valid: true,
      scopes_ok: true,
      error_msg: null,
      credential_expires_at: expiresAt,
      needs_rotation: false,
    }
    return delay(result, 350)
  },
}

const MOCK_MODE = (import.meta.env.VITE_CONNECTORS_API_MODE as string | undefined) !== 'live'

export const connectorsApi: ConnectorsApi = MOCK_MODE ? mockConnectorsApi : liveConnectorsApi
