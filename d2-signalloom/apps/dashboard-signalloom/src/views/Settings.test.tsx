import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import Settings from './Settings'
import { api } from '../api/client'
import { connectorsApi } from '../api/connectorsClient'
import { AppContext } from '../App'
import type { TenantSettingsResponse } from '../types/api'

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
  },
}))

vi.mock('../api/connectorsClient', () => ({
  connectorsApi: {
    listProviders: vi.fn(),
    listConnectors: vi.fn(),
    deleteConnector: vi.fn(),
    createConnector: vi.fn(),
    testConnector: vi.fn(),
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
    selected_frameworks: [],
    consent_required: false,
    cookie_preferences: null,
    preferred_scan_cadence_hours: 24,
    alert_email: null,
    alert_threshold: 1,
    ...overrides,
  }
}

const MOCK_PROVIDERS = [
  { provider_id: 'ad_entra', display_name: 'Microsoft Entra ID', description: 'Azure AD / Entra ID', category: 'identity', auth_type: 'oauth2' as const },
  { provider_id: 'okta', display_name: 'Okta', description: 'Okta IAM', category: 'identity', auth_type: 'oauth2' as const },
  { provider_id: 'openai', display_name: 'OpenAI', description: 'OpenAI platform', category: 'ai', auth_type: 'api_key' as const },
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

function renderSettings() {
  return render(
    <MemoryRouter initialEntries={['/settings']}>
      <AppContext.Provider value={appCtxValue}>
        <Settings />
      </AppContext.Provider>
    </MemoryRouter>,
  )
}

describe('Settings — Service Connectors', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    vi.mocked(connectorsApi.listProviders).mockResolvedValue(MOCK_PROVIDERS)
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([])
  })

  it('renders all providers from the API with their display names', async () => {
    renderSettings()
    expect(await screen.findByText('Microsoft Entra ID')).toBeInTheDocument()
    expect(screen.getByText('Okta')).toBeInTheDocument()
    expect(screen.getByText('OpenAI')).toBeInTheDocument()
  })

  it('shows "Not configured" for providers without a connector', async () => {
    renderSettings()
    await screen.findByText('Microsoft Entra ID')
    const notConfigured = screen.getAllByText('Not configured')
    expect(notConfigured).toHaveLength(3)
  })

  it('shows "Connected" for providers with an active connector', async () => {
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([
      { connector_id: 'conn-1', provider_id: 'okta', tenant_id: 'tenant-1', display_name: 'Okta', status: 'connected', created_at: '2026-01-01', last_tested_at: null },
    ])
    renderSettings()
    expect(await screen.findByText('Connected')).toBeInTheDocument()
    const notConfigured = screen.getAllByText('Not configured')
    expect(notConfigured).toHaveLength(2)
  })

  it('shows toggle ON for connected providers and OFF for unconfigured', async () => {
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([
      { connector_id: 'conn-1', provider_id: 'okta', tenant_id: 'tenant-1', display_name: 'Okta', status: 'connected', created_at: '2026-01-01', last_tested_at: null },
    ])
    renderSettings()
    await screen.findByText('Service Connectors')
    // No framework toggles (mocked to []), so all switches belong to connectors
    const switches = screen.getAllByRole('switch')
    expect(switches).toHaveLength(3)
    // Order matches providers: Entra (off), Okta (on), OpenAI (off)
    expect(switches[0]).toHaveAttribute('aria-checked', 'false')
    expect(switches[1]).toHaveAttribute('aria-checked', 'true')
    expect(switches[2]).toHaveAttribute('aria-checked', 'false')
  })

  it('navigates to /onboarding when toggling ON an unconfigured provider', async () => {
    renderSettings()
    await screen.findByText('Service Connectors')
    const switches = screen.getAllByRole('switch')
    // First switch is Entra (unconfigured)
    await userEvent.click(switches[0])
    expect(mockNavigate).toHaveBeenCalledWith('/onboarding')
  })

  it('shows disconnect confirmation when toggling OFF a connected provider', async () => {
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([
      { connector_id: 'conn-1', provider_id: 'okta', tenant_id: 'tenant-1', display_name: 'Okta', status: 'connected', created_at: '2026-01-01', last_tested_at: null },
    ])
    renderSettings()
    await screen.findByText('Connected')
    const switches = screen.getAllByRole('switch')
    // Second switch is Okta (connected)
    await userEvent.click(switches[1])
    expect(await screen.findByText('Disconnect provider?')).toBeInTheDocument()
  })

  it('calls deleteConnector and refreshes onboarding state on disconnect confirm', async () => {
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([
      { connector_id: 'conn-1', provider_id: 'okta', tenant_id: 'tenant-1', display_name: 'Okta', status: 'connected', created_at: '2026-01-01', last_tested_at: null },
    ])
    vi.mocked(connectorsApi.deleteConnector).mockResolvedValue(undefined)
    renderSettings()
    await screen.findByText('Connected')

    const switches = screen.getAllByRole('switch')
    await userEvent.click(switches[1])
    await screen.findByText('Disconnect provider?')

    const confirmBtn = screen.getByRole('button', { name: /disconnect/i })
    await userEvent.click(confirmBtn)

    await waitFor(() => {
      expect(connectorsApi.deleteConnector).toHaveBeenCalledWith('test-token', 'conn-1')
      expect(appCtxValue.refreshOnboardingState).toHaveBeenCalled()
    })
  })

  it('shows empty state when no providers are available', async () => {
    vi.mocked(connectorsApi.listProviders).mockResolvedValue([])
    renderSettings()
    expect(await screen.findByText('No providers available.')).toBeInTheDocument()
  })
})
