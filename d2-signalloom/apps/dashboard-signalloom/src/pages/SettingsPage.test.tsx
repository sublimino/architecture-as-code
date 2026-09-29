import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import SettingsPage from './SettingsPage'
import { api } from '../api/client'
import { connectorsApi } from '../api/connectorsClient'
import { AppContext } from '../App'
import type { TenantSettingsResponse } from '../types/api'
import type { ConnectorProvider } from '../types/connectors'

const mockNavigate = vi.fn()
vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual('react-router-dom')
  return { ...actual, useNavigate: () => mockNavigate }
})

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    user: { name: 'Wendy', email: 'woverton@signal-loom.ai' },
    logout: vi.fn(),
    getAccessTokenSilently: vi.fn().mockResolvedValue('test-token'),
  }),
}))

vi.mock('../api/client', () => ({
  api: {
    settings: vi.fn(),
    compliance: { frameworks: vi.fn().mockResolvedValue([]) },
    nhi: { scans: vi.fn().mockResolvedValue({ scans: [] }) },
    patchFrameworks: vi.fn(),
    patchPreferences: vi.fn(),
    apiKeys: { revealInitial: vi.fn(), rotate: vi.fn() },
    users: vi.fn().mockResolvedValue({ users: [], total: 0 }),
  },
}))

vi.mock('../api/connectorsClient', () => ({
  connectorsApi: {
    listProviders: vi.fn(),
    listConnectors: vi.fn(),
    deleteConnector: vi.fn(),
    createConnector: vi.fn(),
    testConnector: vi.fn(),
    toggleConnector: vi.fn(),
    getStatus: vi.fn(),
  },
}))

function makeSettings(overrides: Partial<TenantSettingsResponse> = {}): TenantSettingsResponse {
  return {
    tenant_id: 'tenant-1',
    org_name: 'Acme Corp',
    plan_tier: 'growth',
    agent_count: 5,
    billing_tier: null,
    api_key_status: 'active',
    selected_frameworks: ['eu-ai-act'],
    consent_required: false,
    cookie_preferences: null,
    preferred_scan_cadence_hours: 24,
    alert_email: null,
    alert_threshold: 1,
    ...overrides,
  }
}

const STUB_WIZARD = { fields: [], permissions: [], docs_link: '', help_text: '' }

const MOCK_PROVIDERS: ConnectorProvider[] = [
  { provider_id: 'aws_iam', display_name: 'AWS IAM', wizard_config: STUB_WIZARD },
  { provider_id: 'gcp_iam', display_name: 'GCP IAM', wizard_config: STUB_WIZARD },
  { provider_id: 'ad_entra', display_name: 'Microsoft Entra ID', wizard_config: STUB_WIZARD },
  { provider_id: 'k8s', display_name: 'Kubernetes Cluster', wizard_config: STUB_WIZARD },
  { provider_id: 'github', display_name: 'GitHub', wizard_config: STUB_WIZARD },
]

const appCtxValue = {
  failingControls: 0,
  setFailingControls: () => undefined,
  helpOpen: false,
  setHelpOpen: () => undefined,
  apiKeyReveal: null,
  setApiKeyReveal: () => undefined,
  cookieSettingsOpen: false,
  setCookieSettingsOpen: () => undefined,
  connectedProviderCount: 0,
  totalProviderCount: 0,
  needsOnboarding: null,
  refreshOnboardingState: vi.fn().mockResolvedValue(undefined),
  superadmin: false,
  setSuperadmin: () => undefined,
}

function renderSettingsPage() {
  return render(
    <MemoryRouter initialEntries={['/settings']}>
      <AppContext.Provider value={appCtxValue}>
        <SettingsPage />
      </AppContext.Provider>
    </MemoryRouter>,
  )
}

describe('SettingsPage: Integration & Reconciliation', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    vi.mocked(connectorsApi.listProviders).mockResolvedValue(MOCK_PROVIDERS)
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([
      {
        connector_id: 'conn-aws-01',
        provider_id: 'aws_iam',
        display_name: 'AWS IAM',
        status: 'connected',
        credential_expires_at: null,
        last_tested_at: '2026-09-29T10:00:00Z',
        last_scan_at: null,
        metadata: {},
        created_at: '2026-01-01',
      },
    ])
  })

  it('renders Settings heading, Service Connectors, and Policy-as-Code cards', async () => {
    renderSettingsPage()
    expect(await screen.findByRole('heading', { name: 'Settings' })).toBeInTheDocument()
    expect(screen.getByText('Service Connectors')).toBeInTheDocument()
    expect(screen.getByText('AWS IAM')).toBeInTheDocument()
    expect(screen.getByText('Policy-as-Code & CEL Rules')).toBeInTheDocument()
  })

  it('navigates to /policies when clicking the CEL policy editor button', async () => {
    renderSettingsPage()
    const policyBtn = await screen.findByTestId('settings-goto-policies-btn')
    expect(policyBtn).toBeInTheDocument()
    await userEvent.click(policyBtn)
    expect(mockNavigate).toHaveBeenCalledWith('/policies')
  })

  it('renders configured connectors and allows toggling disconnect confirm', async () => {
    renderSettingsPage()
    expect(await screen.findByText('Connected · Last tested 29 Sept 2026, 11:00')).toBeInTheDocument()
    const switches = screen.getAllByRole('switch')
    expect(switches[0]).toHaveAttribute('aria-checked', 'true')
    await userEvent.click(switches[0])
    expect(await screen.findByText('Disconnect provider?')).toBeInTheDocument()
  })
})
