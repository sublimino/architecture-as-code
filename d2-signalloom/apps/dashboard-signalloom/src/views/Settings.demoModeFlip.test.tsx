// Flipping the demo toggle without a reload must not leave the other mode's
// connector list on screen. Reproduced live: five mock seed rows plus a
// mock-created conn-claude-06 stayed listed after switching to live, and the
// modal's test then POSTed /api/connectors/conn-claude-06/test to the live
// backend (404).
//
// Its own file because the main Settings suite hands out a fresh token getter
// per render, which reloads on every render and would hide a missing
// subscription. Here the getter is stable, so only the demo-mode subscription
// can cause the refetch.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import Settings from './Settings'
import { api } from '../api/client'
import { connectorsApi } from '../api/connectorsClient'
import { isDemoMode, setDemoMode } from '../api/demoMode'
import { AppContext } from '../App'
import type { ConnectorProvider, TenantConnector } from '../types/connectors'

const { getToken } = vi.hoisted(() => ({ getToken: vi.fn() }))

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual('react-router-dom')
  return { ...actual, useNavigate: () => vi.fn() }
})

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ user: { name: 'W', email: 'w@example.test' }, logout: vi.fn(), getAccessTokenSilently: getToken }),
}))

vi.mock('../api/client', () => ({
  api: {
    settings: vi.fn(),
    compliance: { frameworks: vi.fn().mockResolvedValue([]) },
    nhi: { scans: vi.fn().mockResolvedValue({ scans: [] }) },
    patchFrameworks: vi.fn(),
    patchPreferences: vi.fn(),
    patchOrganization: vi.fn(),
    apiKeys: { revealInitial: vi.fn(), rotate: vi.fn() },
    users: vi.fn().mockResolvedValue({ users: [], total: 0 }),
  },
}))

vi.mock('../api/connectorsClient', async () => ({
  ...(await vi.importActual<typeof import('../api/connectorsClient')>('../api/connectorsClient')),
  connectorsApi: {
    listProviders: vi.fn(),
    listConnectors: vi.fn(),
    deleteConnector: vi.fn(),
    createConnector: vi.fn(),
    testConnector: vi.fn(),
    testProviderCredentials: vi.fn(),
    toggleConnector: vi.fn(),
    triggerScan: vi.fn(),
    getSyncLogs: vi.fn(),
    getStatus: vi.fn(),
    listRemoteAgents: vi.fn(),
  },
}))

vi.mock('../components/onboarding/OnboardingWizard', () => ({ default: () => null }))

const WIZ = { fields: [], permissions: [], docs_link: '', help_text: '' }
const PROVIDERS: ConnectorProvider[] = [
  { provider_id: 'ad_entra', display_name: 'Microsoft Entra ID', wizard_config: WIZ },
  { provider_id: 'okta', display_name: 'Okta', wizard_config: WIZ },
  { provider_id: 'openai', display_name: 'OpenAI', wizard_config: WIZ },
]

function row(connector_id: string, provider_id: string): TenantConnector {
  return {
    connector_id,
    provider_id,
    display_name: provider_id,
    status: 'connected',
    credential_expires_at: null,
    last_tested_at: null,
    last_scan_at: null,
    metadata: {},
    created_at: '2026-10-01T00:00:00Z',
  }
}

const DEMO_ROWS = [row('conn-mock-06', 'okta')]
const LIVE_ROWS = [row('conn-live-9', 'openai')]

const appCtx = {
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

beforeEach(() => {
  vi.clearAllMocks()
  getToken.mockResolvedValue('test-token')
  setDemoMode(true)
  vi.mocked(api.settings).mockResolvedValue({
    tenant_id: 't-1',
    org_name: 'Acme',
    plan_tier: 'growth',
    agent_count: 0,
    billing_tier: null,
    api_key_status: 'active',
    selected_frameworks: [],
    consent_required: false,
    cookie_preferences: null,
    preferred_scan_cadence_hours: 24,
    alert_email: null,
    alert_threshold: 1,
    sector: null,
    jurisdiction: null,
    reporting_currency: null,
    risk_appetite_tolerance: null,
    risk_load: null,
  })
  vi.mocked(connectorsApi.listProviders).mockResolvedValue(PROVIDERS)
  // The connectors client answers from whichever mode is current at call time.
  vi.mocked(connectorsApi.listConnectors).mockImplementation(async () => (isDemoMode() ? DEMO_ROWS : LIVE_ROWS))
  vi.mocked(connectorsApi.deleteConnector).mockResolvedValue(undefined)
})

afterEach(() => setDemoMode(true))

describe('Settings connectors across a demo-mode flip', () => {
  it('replaces the demo connector list with the live one and never sends a mock id to the live API', async () => {
    render(
      <MemoryRouter initialEntries={['/settings?tab=connectors']}>
        <AppContext.Provider value={appCtx}>
          <Settings />
        </AppContext.Provider>
      </MemoryRouter>,
    )
    expect(await screen.findByTestId('scan-connector-okta')).toBeInTheDocument()
    expect(screen.queryByTestId('scan-connector-openai')).not.toBeInTheDocument()

    act(() => setDemoMode(false))

    expect(await screen.findByTestId('scan-connector-openai')).toBeInTheDocument()
    expect(screen.queryByTestId('scan-connector-okta')).not.toBeInTheDocument()

    // Disconnect the live OpenAI row (third switch): the live id goes out.
    await userEvent.click(screen.getAllByRole('switch')[2])
    await screen.findByText('Disconnect provider?')
    await userEvent.click(screen.getByRole('button', { name: /disconnect/i }))
    await waitFor(() => expect(connectorsApi.deleteConnector).toHaveBeenCalledWith('test-token', 'conn-live-9'))

    const calls = [
      ...vi.mocked(connectorsApi.deleteConnector).mock.calls,
      ...vi.mocked(connectorsApi.testConnector).mock.calls,
      ...vi.mocked(connectorsApi.toggleConnector).mock.calls,
    ]
    expect(JSON.stringify(calls)).not.toContain('conn-mock-06')
  })

  it('discards a demo-mode load that resolves after the flip to live', async () => {
    let releaseDemo: (rows: TenantConnector[]) => void = () => undefined
    vi.mocked(connectorsApi.listConnectors).mockImplementation(() =>
      isDemoMode() ? new Promise((resolve) => (releaseDemo = resolve)) : Promise.resolve(LIVE_ROWS),
    )
    render(
      <MemoryRouter initialEntries={['/settings?tab=connectors']}>
        <AppContext.Provider value={appCtx}>
          <Settings />
        </AppContext.Provider>
      </MemoryRouter>,
    )
    await waitFor(() => expect(connectorsApi.listConnectors).toHaveBeenCalledTimes(1))
    act(() => setDemoMode(false))
    expect(await screen.findByTestId('scan-connector-openai')).toBeInTheDocument()

    await act(async () => releaseDemo(DEMO_ROWS))

    expect(screen.queryByTestId('scan-connector-okta')).not.toBeInTheDocument()
    expect(screen.getByTestId('scan-connector-openai')).toBeInTheDocument()
  })
})
