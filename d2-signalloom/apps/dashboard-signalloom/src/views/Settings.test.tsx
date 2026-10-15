import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { cleanup, render, screen, waitFor, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import Settings, { SETTINGS_TABS } from './Settings'
import PixelLoader from '../components/PixelLoader'
import { api } from '../api/client'
import { connectorsApi } from '../api/connectorsClient'
import {
  DEFAULT_LOAD_TIMES,
  LOAD_TIMES_OPTIONS,
  getLoadTimes,
  setLoadTimes,
} from '../api/loadTimes'
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
    patchOrganization: vi.fn(),
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
    ...overrides,
  }
}

import type { ConnectorProvider } from '../types/connectors'

const STUB_WIZARD = { fields: [], permissions: [], docs_link: '', help_text: '' }

const MOCK_PROVIDERS: ConnectorProvider[] = [
  { provider_id: 'ad_entra', display_name: 'Microsoft Entra ID', wizard_config: STUB_WIZARD },
  { provider_id: 'okta', display_name: 'Okta', wizard_config: STUB_WIZARD },
  { provider_id: 'openai', display_name: 'OpenAI', wizard_config: STUB_WIZARD },
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

function renderSettings(initialEntries: string[] = ['/settings']) {
  return render(
    <MemoryRouter initialEntries={initialEntries}>
      <AppContext.Provider value={appCtxValue}>
        <Settings />
      </AppContext.Provider>
    </MemoryRouter>,
  )
}

describe('Settings: Tabs Navigation & Section Distribution', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    vi.mocked(api.compliance.frameworks).mockResolvedValue([
      {
        id: 'eu-ai-act',
        name: 'EU AI Act',
        version: '1.0',
        regulatory_body: 'EU',
        compliance_deadline: null,
        control_count: 42,
        controls: [],
      },
    ])
    vi.mocked(api.nhi.scans).mockResolvedValue({
      scans: [
        {
          id: 'scan-1',
          tenant_id: 'tenant-1',
          scan_source: 'okta',
          status: 'completed',
          started_at: '2026-10-01T10:00:00Z',
          completed_at: '2026-10-01T10:05:00Z',
          total_entries_scanned: 150,
          service_accounts_found: 12,
          total_at_risk: 1,
        },
      ],
    })
    vi.mocked(connectorsApi.listProviders).mockResolvedValue(MOCK_PROVIDERS)
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([])
    vi.mocked(api.users).mockResolvedValue({
      users: [
        {
          id: 'u1',
          email: 'alice@acme.com',
          display_name: 'Alice Smith',
          role: 'admin',
          status: 'active',
          department: 'Security',
          title: 'SecOps Lead',
          last_login_at: '2026-10-01T09:00:00Z',
          created_at: '2026-01-01T00:00:00Z',
        },
      ],
      total: 1,
    })
  })

  it('renders tab navigation bar with 4 tabs and correct accessible ARIA attributes', async () => {
    renderSettings()
    expect(await screen.findByRole('heading', { name: 'Settings' })).toBeInTheDocument()

    const tablist = screen.getByRole('tablist', { name: /settings tabs/i })
    expect(tablist).toBeInTheDocument()

    const tabs = screen.getAllByRole('tab')
    expect(tabs).toHaveLength(6)

    const expectedTabs = [
      { id: 'general', label: 'General' },
      { id: 'access', label: 'API & Access' },
      { id: 'connectors', label: 'Connectors & Discovery' },
      { id: 'governance', label: 'Governance & Policy' },
      { id: 'deploy-sensor', label: 'Deploy Sensor' },
      { id: 'onboard-agent', label: 'Onboard Agent' },
    ]

    expectedTabs.forEach((tab, index) => {
      expect(tabs[index]).toHaveTextContent(tab.label)
      expect(tabs[index]).toHaveAttribute('id', `settings-tab-${tab.id}`)
      expect(tabs[index]).toHaveAttribute('aria-controls', `settings-tabpanel-${tab.id}`)
    })

    // Default tab is 'general'
    expect(tabs[0]).toHaveAttribute('aria-selected', 'true')
    expect(tabs[1]).toHaveAttribute('aria-selected', 'false')
    expect(tabs[2]).toHaveAttribute('aria-selected', 'false')
    expect(tabs[3]).toHaveAttribute('aria-selected', 'false')
    expect(tabs[4]).toHaveAttribute('aria-selected', 'false')
    expect(tabs[5]).toHaveAttribute('aria-selected', 'false')

    const panel = screen.getByRole('tabpanel')
    expect(panel).toHaveAttribute('id', 'settings-tabpanel-general')
    expect(panel).toHaveAttribute('aria-labelledby', 'settings-tab-general')
  })

  it('defaults to General tab, displaying Organization, Account, Currency, and Display sections', async () => {
    renderSettings()
    expect(await screen.findByText('Organization')).toBeInTheDocument()
    expect(screen.getByText('Account')).toBeInTheDocument()
    expect(screen.getByText('Currency')).toBeInTheDocument()
    expect(screen.getByText('Display')).toBeInTheDocument()

    // Sections from other tabs should not be present
    expect(screen.queryByText('API Access')).not.toBeInTheDocument()
    expect(screen.queryByText('Team')).not.toBeInTheDocument()
    expect(screen.queryByText('Service Connectors')).not.toBeInTheDocument()
    expect(screen.queryByText('NHI Discovery')).not.toBeInTheDocument()
    expect(screen.queryByText('Scan Preferences')).not.toBeInTheDocument()
    expect(screen.queryByText('Compliance Frameworks')).not.toBeInTheDocument()
    expect(screen.queryByText('Policy-as-Code & CEL Rules')).not.toBeInTheDocument()
  })

  it('activates the Access tab via URL search param ?tab=access', async () => {
    renderSettings(['/settings?tab=access'])
    expect(await screen.findByRole('heading', { name: 'Settings' })).toBeInTheDocument()

    const accessTab = screen.getByRole('tab', { name: 'API & Access' })
    expect(accessTab).toHaveAttribute('aria-selected', 'true')

    const panel = screen.getByRole('tabpanel')
    expect(panel).toHaveAttribute('id', 'settings-tabpanel-access')

    expect(screen.getByText('API Access')).toBeInTheDocument()
    expect(screen.getByText('Team')).toBeInTheDocument()
    expect(screen.queryByText('Organization')).not.toBeInTheDocument()
  })

  it('falls back to General tab when unknown ?tab= param is provided', async () => {
    renderSettings(['/settings?tab=unknown-tab'])
    expect(await screen.findByText('Organization')).toBeInTheDocument()
    const generalTab = screen.getByRole('tab', { name: 'General' })
    expect(generalTab).toHaveAttribute('aria-selected', 'true')
  })

  it('switches tabs and reveals corresponding sections across all 4 tabs', async () => {
    renderSettings()
    await screen.findByText('Organization')

    // 1. Switch to 'API & Access'
    await userEvent.click(screen.getByRole('tab', { name: 'API & Access' }))
    expect(await screen.findByText('API Access')).toBeInTheDocument()
    expect(screen.getByText('Team')).toBeInTheDocument()
    // Verify callout and link to /users
    const usersLink = screen.getByRole('link', {
      name: /Manage permissions and human identities on the Users & Permissions page → \/users/i,
    })
    expect(usersLink).toBeInTheDocument()
    expect(usersLink).toHaveAttribute('href', '/users')
    // Verify team members displayed
    expect(screen.getByText('Alice Smith')).toBeInTheDocument()
    expect(screen.queryByText('Organization')).not.toBeInTheDocument()

    // 2. Switch to 'Connectors & Discovery'
    await userEvent.click(screen.getByRole('tab', { name: 'Connectors & Discovery' }))
    expect(await screen.findByText('Service Connectors')).toBeInTheDocument()
    expect(screen.getByText('NHI Discovery')).toBeInTheDocument()
    expect(screen.getByText('Scan Preferences')).toBeInTheDocument()
    expect(screen.queryByText('API Access')).not.toBeInTheDocument()

    // 3. Switch to 'Governance & Policy'
    await userEvent.click(screen.getByRole('tab', { name: 'Governance & Policy' }))
    expect(await screen.findByText('Compliance Frameworks')).toBeInTheDocument()
    expect(screen.getByText('EU AI Act')).toBeInTheDocument()
    expect(screen.getByText('Policy-as-Code & CEL Rules')).toBeInTheDocument()
    expect(screen.queryByText('Service Connectors')).not.toBeInTheDocument()

    // 4. Switch to 'Deploy Sensor'
    await userEvent.click(screen.getByRole('tab', { name: 'Deploy Sensor' }))
    expect(await screen.findByRole('heading', { name: /Help to Deploy Sensor/i })).toBeInTheDocument()
    expect(screen.getByTestId('architecture-section')).toBeInTheDocument()

    // 5. Switch to 'Onboard Agent'
    await userEvent.click(screen.getByRole('tab', { name: 'Onboard Agent' }))
    expect(await screen.findByRole('heading', { name: /Help to Onboard an Agent/i })).toBeInTheDocument()
    expect(screen.getByTestId('step-1-section')).toBeInTheDocument()

    // 6. Switch back to 'General'
    await userEvent.click(screen.getByRole('tab', { name: 'General' }))
    expect(await screen.findByText('Organization')).toBeInTheDocument()
    expect(screen.getByText('Account')).toBeInTheDocument()
    expect(screen.getByText('Currency')).toBeInTheDocument()
    expect(screen.getByText('Display')).toBeInTheDocument()
    expect(screen.getByTestId('settings-guide-card-deploy-sensor')).toBeInTheDocument()
    expect(screen.getByTestId('settings-guide-card-onboard-agent')).toBeInTheDocument()
    expect(screen.queryByText('Compliance Frameworks')).not.toBeInTheDocument()
  })
})

describe('Settings: Service Connectors', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    vi.mocked(connectorsApi.listProviders).mockResolvedValue(MOCK_PROVIDERS)
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([])
  })

  it('renders all providers from the API with their display names', async () => {
    renderSettings(['/settings?tab=connectors'])
    expect(await screen.findByText('Microsoft Entra ID')).toBeInTheDocument()
    expect(screen.getByText('Okta')).toBeInTheDocument()
    expect(screen.getByText('OpenAI')).toBeInTheDocument()
  })

  it('shows "Not configured" for providers without a connector', async () => {
    renderSettings(['/settings?tab=connectors'])
    await screen.findByText('Microsoft Entra ID')
    const notConfigured = screen.getAllByText('Not configured')
    expect(notConfigured).toHaveLength(3)
  })

  it('shows "Connected" for providers with an active connector', async () => {
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([
      { connector_id: 'conn-1', provider_id: 'okta', display_name: 'Okta', status: 'connected', credential_expires_at: null, last_tested_at: null, last_scan_at: null, metadata: {}, created_at: '2026-01-01' },
    ])
    renderSettings(['/settings?tab=connectors'])
    expect(await screen.findByText('Connected')).toBeInTheDocument()
    const notConfigured = screen.getAllByText('Not configured')
    expect(notConfigured).toHaveLength(2)
  })

  it('shows toggle ON for connected providers and OFF for unconfigured', async () => {
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([
      { connector_id: 'conn-1', provider_id: 'okta', display_name: 'Okta', status: 'connected', credential_expires_at: null, last_tested_at: null, last_scan_at: null, metadata: {}, created_at: '2026-01-01' },
    ])
    renderSettings(['/settings?tab=connectors'])
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
    renderSettings(['/settings?tab=connectors'])
    await screen.findByText('Service Connectors')
    const switches = screen.getAllByRole('switch')
    // First switch is Entra (unconfigured)
    await userEvent.click(switches[0])
    expect(mockNavigate).toHaveBeenCalledWith('/onboarding')
  })

  it('shows disconnect confirmation when toggling OFF a connected provider', async () => {
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([
      { connector_id: 'conn-1', provider_id: 'okta', display_name: 'Okta', status: 'connected', credential_expires_at: null, last_tested_at: null, last_scan_at: null, metadata: {}, created_at: '2026-01-01' },
    ])
    renderSettings(['/settings?tab=connectors'])
    await screen.findByText('Connected')
    const switches = screen.getAllByRole('switch')
    // Second switch is Okta (connected)
    await userEvent.click(switches[1])
    expect(await screen.findByText('Disconnect provider?')).toBeInTheDocument()
  })

  it('calls deleteConnector and refreshes onboarding state on disconnect confirm', async () => {
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([
      { connector_id: 'conn-1', provider_id: 'okta', display_name: 'Okta', status: 'connected', credential_expires_at: null, last_tested_at: null, last_scan_at: null, metadata: {}, created_at: '2026-01-01' },
    ])
    vi.mocked(connectorsApi.deleteConnector).mockResolvedValue(undefined)
    renderSettings(['/settings?tab=connectors'])
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
    renderSettings(['/settings?tab=connectors'])
    expect(await screen.findByText('No providers available.')).toBeInTheDocument()
  })
})

/**
 * The Display card: whether loaders show how long they have been waiting.
 *
 * Unlike everything else on this page, this setting is browser-local and takes
 * effect the moment it changes: there is no Save Preferences button behind it
 * and no PATCH. So the tests here are not "does the select hold a value" but
 * "does changing the select move the loaders", which is the only claim worth
 * making: the whole feature is one choice reaching every loader in the app.
 */
describe('Settings: Display, load times', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    vi.mocked(connectorsApi.listProviders).mockResolvedValue([])
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([])
    setLoadTimes(DEFAULT_LOAD_TIMES)
  })

  afterEach(() => {
    // cleanup() first, and deliberately: this hook is registered inside the
    // describe, so it runs BEFORE testing-library's own auto-cleanup. Resetting
    // the store while the tree is still mounted pushes a state update through
    // every subscriber outside act(), which is twelve act warnings per test for
    // no benefit. Unmount, then reset, and there is nobody left to notify.
    cleanup()
    setLoadTimes(DEFAULT_LOAD_TIMES)
  })

  /** Settings, with a loader alongside it standing in for the rest of the app. */
  function renderWithProbe() {
    return render(
      <MemoryRouter initialEntries={['/settings']}>
        <AppContext.Provider value={appCtxValue}>
          <Settings />
          <PixelLoader label="Deploying" announce={false} testId="probe" />
        </AppContext.Provider>
      </MemoryRouter>,
    )
  }

  const control = () => screen.getByTestId<HTMLSelectElement>('settings-load-times')

  it('offers the three values and starts on all', async () => {
    renderSettings()
    await screen.findByText('Display')
    expect(control().value).toBe('all')
    expect([...control().options].map((o) => o.value)).toEqual(
      LOAD_TIMES_OPTIONS.map((o) => o.value),
    )
  })

  it('explains what each value means rather than just naming it', async () => {
    // Three one-word options with no explanation is not a choice a user can
    // make. Every hint is on screen at once, not one that swaps as you scroll.
    renderSettings()
    await screen.findByText('Display')
    for (const option of LOAD_TIMES_OPTIONS) {
      expect(screen.getByTestId(`settings-load-times-hint-${option.value}`)).toHaveTextContent(
        option.hint,
      )
    }
  })

  it('says on the page that the wording next to the spinner is never hidden', async () => {
    // The invariant, stated where the person changing the setting will read it,
    // so "None" cannot be read as "no loader".
    renderSettings()
    await screen.findByText('Display')
    expect(screen.getByTestId('settings-load-times-note')).toHaveTextContent(
      /wording next to the spinner.*always shown/i,
    )
  })

  it('reflects a value that was already set', async () => {
    setLoadTimes('long')
    renderSettings()
    await screen.findByText('Display')
    expect(control().value).toBe('long')
  })

  it('changes the stored setting when the operator picks a new value', async () => {
    renderSettings()
    await screen.findByText('Display')

    await userEvent.selectOptions(control(), 'none')
    expect(getLoadTimes()).toBe('none')
    expect(control().value).toBe('none')

    await userEvent.selectOptions(control(), 'long')
    expect(getLoadTimes()).toBe('long')
    expect(control().value).toBe('long')
  })

  it('reaches a loader that is already on screen, with no reload and no remount', async () => {
    renderWithProbe()
    await screen.findByText('Display')

    const loader = screen.getByTestId('probe')
    expect(screen.getByTestId('probe-elapsed')).toBeInTheDocument()

    await userEvent.selectOptions(control(), 'none')

    expect(screen.getByTestId('probe')).toBe(loader) // same node: not remounted
    expect(screen.queryByTestId('probe-elapsed')).not.toBeInTheDocument()
    // And the requirement that outranks the setting: the wording stays.
    expect(screen.getByTestId('probe-label')).toHaveTextContent('Deploying')

    await userEvent.selectOptions(control(), 'all')
    expect(screen.getByTestId('probe')).toBe(loader)
    expect(screen.getByTestId('probe-elapsed')).toBeInTheDocument()
  })

  it('puts a loader into long mode from the control, figure withheld until it earns it', async () => {
    renderWithProbe()
    await screen.findByText('Display')

    await userEvent.selectOptions(control(), 'long')
    // The probe mounted moments ago, so it is a short wait so far: the label
    // is there and the figure is not.
    expect(screen.getByTestId('probe-label')).toHaveTextContent('Deploying')
    expect(screen.queryByTestId('probe-elapsed')).not.toBeInTheDocument()
    expect(screen.getByTestId('probe')).toHaveAttribute('data-load-times', 'long')
  })
})

describe('Settings: Policy-as-Code Navigation Card', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    vi.mocked(connectorsApi.listProviders).mockResolvedValue(MOCK_PROVIDERS)
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([])
  })

  it('renders the Policy-as-Code & CEL Rules card and navigates to /policies on button click', async () => {
    renderSettings(['/settings?tab=governance'])
    expect(await screen.findByText('Policy-as-Code & CEL Rules')).toBeInTheDocument()
    const policyBtn = screen.getByTestId('settings-goto-policies-btn')
    expect(policyBtn).toBeInTheDocument()
    await userEvent.click(policyBtn)
    expect(mockNavigate).toHaveBeenCalledWith('/policies')
  })
})

describe('Settings: Governance Frameworks & Child Policies Expansion', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(api.settings).mockResolvedValue(
      makeSettings({ selected_frameworks: ['eu-ai-act'] }),
    )
    vi.mocked(api.compliance.frameworks).mockResolvedValue([
      {
        id: 'eu-ai-act',
        name: 'EU AI Act',
        version: '1.0',
        regulatory_body: 'EU',
        compliance_deadline: null,
        control_count: 42,
        controls: [],
      },
    ])
    vi.mocked(connectorsApi.listProviders).mockResolvedValue([])
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([])
  })

  it('renders auto-expanded child policies underneath EU AI Act', async () => {
    renderSettings(['/settings?tab=governance'])
    expect(await screen.findByText('EU AI Act')).toBeInTheDocument()

    // Child policies container should exist
    const childContainer = screen.getByTestId('framework-children-eu-ai-act')
    expect(childContainer).toBeInTheDocument()

    // Check specific child rules from regulatoryFrameworks
    expect(screen.getByText(/Workload container execution as non-root/i)).toBeInTheDocument()
    expect(screen.getByText(/Technical Documentation & Annex IV Architecture Dossier/i)).toBeInTheDocument()

    // Non-CEL / manual attestation badge should be visible for Art 11
    const manualSign = screen.getByTestId('manual-sign-eu-ai-act-art-11-tech-doc')
    expect(manualSign).toBeInTheDocument()
    expect(manualSign).toHaveTextContent(/Manual Attestation/i)
  })

  it('navigates to policy editor with URL params when clicking a child policy row', async () => {
    renderSettings(['/settings?tab=governance'])
    expect(await screen.findByText('EU AI Act')).toBeInTheDocument()

    const techDocRow = screen.getByTestId('policy-row-eu-ai-act-art-11-tech-doc')
    expect(techDocRow).toBeInTheDocument()

    const clickableArea = techDocRow.querySelector('div[title*="Click to view and edit"]')
    expect(clickableArea).not.toBeNull()
    await userEvent.click(clickableArea!)

    expect(mockNavigate).toHaveBeenCalledWith(
      '/policies?framework=eu-ai-act&rule=eu-ai-act-art-11-tech-doc',
    )
  })

  it('navigates to /policies when clicking Compliance Frameworks card header button', async () => {
    renderSettings(['/settings?tab=governance'])
    expect(await screen.findByText('Compliance Frameworks')).toBeInTheDocument()

    const openEditorBtn = screen.getByRole('button', { name: /Open Policy Editor/i })
    await userEvent.click(openEditorBtn)

    expect(mockNavigate).toHaveBeenCalledWith('/policies')
  })

  it('toggles child policy active state when its switch is clicked', async () => {
    renderSettings(['/settings?tab=governance'])
    expect(await screen.findByText('EU AI Act')).toBeInTheDocument()

    const techDocRow = screen.getByTestId('policy-row-eu-ai-act-art-11-tech-doc')
    const switchBtn = techDocRow.querySelector('button[role="switch"]')
    expect(switchBtn).toBeInTheDocument()
    expect(switchBtn).toHaveAttribute('aria-checked', 'true')

    await userEvent.click(switchBtn!)
    expect(switchBtn).toHaveAttribute('aria-checked', 'false')

    await userEvent.click(switchBtn!)
    expect(switchBtn).toHaveAttribute('aria-checked', 'true')
  })

  it('renders editable organization name input initialized with settings.org_name', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings({ org_name: 'Stark Industries' }))
    renderSettings()

    const input = (await screen.findByTestId('settings-org-name-input')) as HTMLInputElement
    expect(input).toBeInTheDocument()
    expect(input.value).toBe('Stark Industries')
  })

  it('allows editing and saving organization name, updating settings and dispatching tenant-updated event', async () => {
    const initialSettings = makeSettings({ org_name: 'Acme Corp' })
    const updatedSettings = makeSettings({ org_name: 'Acme International' })
    vi.mocked(api.settings).mockResolvedValue(initialSettings)
    vi.mocked(api.patchOrganization).mockResolvedValue(updatedSettings)

    const eventSpy = vi.fn()
    window.addEventListener('signalloom:tenant-updated', eventSpy)

    renderSettings()

    const input = await screen.findByTestId('settings-org-name-input')
    const saveBtn = screen.getByTestId('settings-save-org-name-btn')

    expect(saveBtn).toBeDisabled()

    fireEvent.change(input, { target: { value: 'Acme International' } })

    expect(saveBtn).toBeEnabled()
    fireEvent.click(saveBtn)

    await waitFor(() => {
      expect(api.patchOrganization).toHaveBeenCalledWith('test-token', 'Acme International')
    })
    expect(await screen.findByTestId('settings-org-saved-indicator')).toHaveTextContent('Saved')
    expect(eventSpy).toHaveBeenCalled()

    window.removeEventListener('signalloom:tenant-updated', eventSpy)
  })

  it('displays error indicator when organization name patch fails', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings({ org_name: 'Acme Corp' }))
    vi.mocked(api.patchOrganization).mockRejectedValue(new Error('Organization name already taken'))

    renderSettings()

    const input = await screen.findByTestId('settings-org-name-input')
    const saveBtn = screen.getByTestId('settings-save-org-name-btn')

    fireEvent.change(input, { target: { value: 'Taken Org' } })
    fireEvent.click(saveBtn)

    expect(await screen.findByTestId('settings-org-error-indicator')).toHaveTextContent('Organization name already taken')
  })

  it('renders k8s-cis-benchmark framework card with active toggle and Edit in Editor link', async () => {
    vi.mocked(api.settings).mockResolvedValue(
      makeSettings({ selected_frameworks: ['eu-ai-act', 'k8s-cis-benchmark'] }),
    )
    vi.mocked(api.compliance.frameworks).mockResolvedValue([
      {
        id: 'k8s-cis-benchmark',
        name: 'CIS Kubernetes Benchmark',
        version: '1.8.0',
        regulatory_body: 'Center for Internet Security (CIS)',
        compliance_deadline: '2026-12-31',
        control_count: 8,
        controls: [
          { id: 'cis-5.2.6', name: 'Minimize admission of root containers', description: 'Containers must run as non-root user.', control_order: 1 },
        ],
      },
    ])

    renderSettings(['/settings?tab=governance'])

    const card = await screen.findByTestId('framework-card-k8s-cis-benchmark')
    expect(card).toBeInTheDocument()
    expect(card).toHaveTextContent('CIS Kubernetes Benchmark')
    expect(card).toHaveTextContent('Active')
    expect(card).toHaveTextContent('Edit in Editor ↗')

    const editLink = card.querySelector('a[href="/policies?framework=k8s-cis-benchmark"]')
    expect(editLink).toBeInTheDocument()
  })

  it('navigates to policy editor with canonical framework and rule ID when clicking a CIS benchmark child policy edit button', async () => {
    vi.mocked(api.settings).mockResolvedValue(
      makeSettings({ selected_frameworks: ['k8s-cis-benchmark'] }),
    )
    vi.mocked(api.compliance.frameworks).mockResolvedValue([
      {
        id: 'k8s-cis-benchmark',
        name: 'CIS Kubernetes Benchmark',
        version: '1.8.0',
        regulatory_body: 'Center for Internet Security (CIS)',
        compliance_deadline: '2026-12-31',
        control_count: 17,
        controls: [
          { id: 'no-privilege-escalation', name: 'CIS-5.2.6: Privilege escalation disallowed', description: 'Containers must not allow privilege escalation.', control_order: 1 },
        ],
      },
    ])

    renderSettings(['/settings?tab=governance'])

    const card = await screen.findByTestId('framework-card-k8s-cis-benchmark')
    expect(card).toBeInTheDocument()

    const row = await screen.findByTestId('policy-row-no-privilege-escalation')
    expect(row).toBeInTheDocument()

    const editBtn = row.querySelector('.governance-policy-table__edit-btn')
    expect(editBtn).not.toBeNull()
    await userEvent.click(editBtn!)

    expect(mockNavigate).toHaveBeenCalledWith(
      '/policies?framework=k8s-cis-benchmark&rule=no-privilege-escalation',
    )
  })
})


