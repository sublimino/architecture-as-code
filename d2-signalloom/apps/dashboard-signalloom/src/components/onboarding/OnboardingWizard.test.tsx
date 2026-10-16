import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, fireEvent, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import OnboardingWizard from './OnboardingWizard'
import { onboardingApi, OnboardingApiError } from '../../api/onboardingClient'

const auth = vi.hoisted(() => ({
  isAuthenticated: true,
  isLoading: false,
  getAccessTokenSilently: vi.fn<() => Promise<string>>().mockResolvedValue('test-bearer-token'),
  loginWithRedirect: vi.fn(),
}))

const mockNavigate = vi.fn()
vi.mock('react-router-dom', async (importOriginal) => ({
  ...(await importOriginal<typeof import('react-router-dom')>()),
  useNavigate: () => mockNavigate,
  useLocation: () => ({ pathname: '/onboarding', state: { returnTo: '/overview' } }),
}))

vi.mock('../../auth/oidc', () => ({
  useAuth0: () => auth,
}))

vi.mock('../../auth/tenant', () => ({
  getTenantIdFromToken: () => 'tenant-test-123',
}))

const mockRefreshOnboardingState = vi.fn<() => Promise<void>>().mockResolvedValue(undefined)
vi.mock('../../App', () => ({
  useAppContext: () => ({
    refreshOnboardingState: mockRefreshOnboardingState,
    needsOnboarding: true,
  }),
}))

const clientApi = vi.hoisted(() => ({
  me: vi.fn(),
  settings: vi.fn(),
  patchPreferences: vi.fn(),
  patchRiskProfile: vi.fn(),
  apiKeys: { revealInitial: vi.fn() },
}))
vi.mock('../../api/client', () => ({ api: clientApi }))

const connectors = vi.hoisted(() => ({
  listProviders: vi.fn(),
  listConnectors: vi.fn(),
  createConnector: vi.fn(),
  testProviderCredentials: vi.fn(),
  testConnector: vi.fn(),
}))
vi.mock('../../api/connectorsClient', () => ({
  connectorsApi: connectors,
  isConnectorsMockMode: () => false,
}))

vi.mock('../../api/onboardingClient', () => ({
  onboardingApi: {
    getStatus: vi.fn(),
    getState: vi.fn(),
    putState: vi.fn(),
    skip: vi.fn(),
    complete: vi.fn(),
  },
  OnboardingApiError: class OnboardingApiError extends Error {
    status?: number
    constructor(message: string, status?: number) {
      super(message)
      this.name = 'OnboardingApiError'
      this.status = status
    }
  },
}))

describe('OnboardingWizard component', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    auth.isAuthenticated = true
    auth.isLoading = false
    auth.getAccessTokenSilently.mockResolvedValue('test-bearer-token')

    vi.mocked(onboardingApi.getStatus).mockResolvedValue({ status: 'pending', skipped_at: null, completed_at: null })
    vi.mocked(onboardingApi.getState).mockResolvedValue({ selected_provider_ids: [], step_index: 0, provider_run_state: {} })
    vi.mocked(onboardingApi.putState).mockResolvedValue({ selected_provider_ids: ['dex'], step_index: 0, provider_run_state: {} })
    vi.mocked(onboardingApi.skip).mockResolvedValue({ status: 'skipped', skipped_at: '2026-09-10T09:00:00Z', completed_at: null })
    vi.mocked(onboardingApi.complete).mockResolvedValue({ status: 'completed', skipped_at: null, completed_at: '2026-09-10T09:00:00Z' })

    clientApi.me.mockResolvedValue({ subject: 'kusari-operator', tenant: 'kusari', email: 'kusari-operator@signalloom.local', superadmin: false })
    clientApi.settings.mockResolvedValue({
      tenant_id: 'tenant-test-123', org_name: 'Kusari', plan_tier: null, agent_count: 0, billing_tier: null,
      api_key_status: 'active', selected_frameworks: [], consent_required: true, cookie_preferences: null,
      preferred_scan_cadence_hours: 168, alert_email: 'ops@kusari.dev', alert_threshold: 7,
    })
    clientApi.patchPreferences.mockImplementation(async (_token: string, body: { preferred_scan_cadence_hours: number; alert_email: string | null; alert_threshold: number }) => ({
      tenant_id: 'tenant-test-123', org_name: 'Kusari', plan_tier: null, agent_count: 0, billing_tier: null,
      api_key_status: 'active', selected_frameworks: [], consent_required: true, cookie_preferences: null,
      ...body,
    }))
    connectors.listProviders.mockResolvedValue(
      [['okta', 'Okta', ['okta_domain', 'api_token']], ['claude', 'Anthropic Claude', ['api_key']]].map(([provider_id, display_name, names]) => ({
        provider_id,
        display_name,
        wizard_config: {
          fields: (names as string[]).map((name) => ({ name, label: name, type: 'password', required: true })),
          permissions: [], docs_link: '', help_text: '',
        },
      })),
    )
    connectors.listConnectors.mockResolvedValue([])
    connectors.createConnector.mockResolvedValue({ connector_id: 'conn-claude-01', provider_id: 'claude', status: 'connected' })
    clientApi.patchRiskProfile.mockResolvedValue({})
    clientApi.apiKeys.revealInitial.mockResolvedValue({ key: 'sl_live_abcdef0123456789', prefix_hint: 'sl_live_abcdef', revealed_at: '2026-10-04T10:00:00Z' })
  })

  function renderWizard(props?: React.ComponentProps<typeof OnboardingWizard>) {
    return render(
      <MemoryRouter initialEntries={['/onboarding']}>
        <OnboardingWizard {...props} />
      </MemoryRouter>,
    )
  }

  function resumeAt(step_index: number, provider_run_state: Record<string, { status: 'idle' | 'submitting' | 'connected' | 'error' }> = {}) {
    vi.mocked(onboardingApi.getState).mockResolvedValueOnce({ selected_provider_ids: ['dex'], step_index, provider_run_state })
  }

  async function pastWelcome(user: ReturnType<typeof userEvent.setup>) {
    const welcome = await screen.findByTestId('onboarding-welcome')
    await user.click(within(welcome).getByRole('button', { name: /get started/i }))
    await waitFor(() => expect(screen.getByText('Tenant & Workspace Identity')).toBeInTheDocument())
  }

  describe('Initial load and state restoration', () => {
    it('welcomes a fresh tenant first, then shows Organization & Identity', async () => {
      const user = userEvent.setup()
      renderWizard()
      expect(await screen.findByTestId('onboarding-welcome')).toBeInTheDocument()
      expect(screen.queryByTestId('onboarding-wizard-container')).not.toBeInTheDocument()

      await pastWelcome(user)

      expect(screen.getByLabelText(/Organization \/ Tenant Name/i)).toHaveValue('Acme Corporation')
      expect(screen.getByLabelText(/Workspace Identifier/i)).toHaveValue('acme-primary')
      expect(screen.getByTestId('next-step-button')).toBeInTheDocument()
    })

    it('resumes at the Identity Provider step without the welcome when step_index is 1', async () => {
      resumeAt(1, { dex: { status: 'connected' } })
      renderWizard()
      await waitFor(() => expect(screen.getByText('Identity Provider Linkage')).toBeInTheDocument())
      expect(screen.queryByTestId('onboarding-welcome')).not.toBeInTheDocument()
      expect(screen.getByTestId('idp-option-dex')).toBeInTheDocument()
      // provider_run_state is written by this client; it is not a server verdict,
      // so resuming does not restore the "verified" tick.
      expect(screen.queryByTestId('idp-connection-success')).not.toBeInTheDocument()
      expect(clientApi.me).not.toHaveBeenCalled()
    })

    it('resumes at Scan preferences, prefilled from GET /tenant/settings, when step_index is 2', async () => {
      resumeAt(2)
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('preferences-step')).toBeInTheDocument())
      expect(clientApi.settings).toHaveBeenCalledWith('test-bearer-token')
      expect(screen.getByLabelText(/alert email/i)).toHaveValue('ops@kusari.dev')
      expect(screen.getByLabelText(/threshold/i)).toHaveValue(7)
    })

    it('resumes at the API key step when step_index is 3', async () => {
      resumeAt(3)
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('api-key-step')).toBeInTheDocument())
      expect(screen.getByText('Your API key')).toBeInTheDocument()
    })

    it('resumes at Containment & Consent when step_index is 4', async () => {
      resumeAt(4)
      renderWizard()
      await waitFor(() => expect(screen.getByText('Containment Policy & Security Consent')).toBeInTheDocument())
      expect(screen.getByTestId('complete-onboarding-button')).toBeInTheDocument()
    })

    it('displays the celebration directly if already completed', async () => {
      vi.mocked(onboardingApi.getStatus).mockResolvedValueOnce({ status: 'completed', skipped_at: null, completed_at: '2026-09-10T08:00:00Z' })
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('completion-celebration')).toBeInTheDocument())
      expect(screen.getByText('Onboarding Completed!')).toBeInTheDocument()
    })

    it('still loads when GET /tenant/settings fails, with default preferences', async () => {
      clientApi.settings.mockRejectedValueOnce(new Error('503'))
      resumeAt(2)
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('preferences-step')).toBeInTheDocument())
      expect(screen.getByLabelText(/alert email/i)).toHaveValue('')
    })
  })

  describe('Step 1: Organization & Identity', () => {
    it('validates required fields and shows the error banner', async () => {
      const user = userEvent.setup()
      renderWizard()
      await pastWelcome(user)

      const orgInput = screen.getByTestId('input-organization-name')
      await user.clear(orgInput)
      fireEvent.change(screen.getByTestId('input-workspace-id'), { target: { value: '' } })
      await user.click(screen.getByTestId('next-step-button'))

      expect(await screen.findByTestId('validation-error-banner')).toBeInTheDocument()
      expect(onboardingApi.putState).not.toHaveBeenCalled()
    })

    it('advances to the Identity Provider step and persists step_index 1', async () => {
      const user = userEvent.setup()
      renderWizard()
      await pastWelcome(user)

      const orgInput = screen.getByTestId('input-organization-name')
      await user.clear(orgInput)
      await user.type(orgInput, 'Global Defense Corp')
      await user.click(screen.getByTestId('next-step-button'))

      await waitFor(() => expect(screen.getByText('Identity Provider Linkage')).toBeInTheDocument())
      expect(onboardingApi.putState).toHaveBeenCalledWith('test-bearer-token', expect.objectContaining({ step_index: 1 }))
    })
  })

  describe('Step 2: Identity Provider and Test Connection', () => {
    async function openDex(user: ReturnType<typeof userEvent.setup>) {
      await user.click(await screen.findByTestId('configure-idp-dex'))
      return screen.findByRole('dialog')
    }

    it('opens the backend-declared fields for a selected IdP', async () => {
      const user = userEvent.setup()
      resumeAt(1)
      renderWizard()
      await user.click(await screen.findByTestId('configure-idp-okta'))
      expect(await screen.findByTestId('wizard-field-okta_domain')).toBeInTheDocument()
    })

    it('Test Connection for Dex calls GET /api/v1/me with the session bearer and shows what the server said', async () => {
      const user = userEvent.setup()
      resumeAt(1)
      renderWizard()
      await openDex(user)
      await user.click(screen.getByTestId('btn-modal-test-connection'))

      const ok = await screen.findByTestId('test-connection-success')
      expect(clientApi.me).toHaveBeenCalledWith('test-bearer-token')
      expect(ok).toHaveTextContent(/kusari-operator@signalloom.local in tenant kusari/i)
      expect(ok).toHaveTextContent(/saved, not probed/i)
    })

    it('Test Connection reports a refusal from the server instead of a green tick', async () => {
      const user = userEvent.setup()
      clientApi.me.mockRejectedValueOnce({ response: { status: 403 } })
      resumeAt(1)
      renderWizard()
      await openDex(user)
      await user.click(screen.getByTestId('btn-modal-test-connection'))

      expect(await screen.findByTestId('test-connection-error')).toHaveTextContent(/HTTP 403/)
      expect(screen.queryByTestId('test-connection-success')).not.toBeInTheDocument()
    })

    it('supports navigating Back to Organization & Identity', async () => {
      const user = userEvent.setup()
      resumeAt(1)
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('back-step-button')).toBeInTheDocument())
      await user.click(screen.getByTestId('back-step-button'))
      await waitFor(() => expect(screen.getByText('Tenant & Workspace Identity')).toBeInTheDocument())
    })

    it('advances to Scan preferences and records the connection verdict in wizard state', async () => {
      const user = userEvent.setup()
      resumeAt(1)
      renderWizard()
      await openDex(user)
      await user.click(screen.getByTestId('btn-modal-test-connection'))
      await screen.findByTestId('test-connection-success')
      await user.click(screen.getByTestId('btn-modal-save-connector'))
      await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
      await user.click(screen.getByTestId('next-step-button'))

      await waitFor(() => expect(screen.getByTestId('preferences-step')).toBeInTheDocument())
      expect(onboardingApi.putState).toHaveBeenCalledWith(
        'test-bearer-token',
        expect.objectContaining({ step_index: 2, provider_run_state: { dex: { status: 'connected' } } }),
      )
    })

    it('a saved but untested Claude connector is persisted as selected, not as connected', async () => {
      const user = userEvent.setup()
      resumeAt(1)
      renderWizard()
      await user.click(await screen.findByTestId('configure-idp-claude'))
      await user.type(await screen.findByTestId('wizard-field-api_key'), 'sk-ant-k')
      await user.click(screen.getByTestId('btn-modal-save-connector'))
      await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
      expect(connectors.createConnector).toHaveBeenCalledWith('test-bearer-token', expect.objectContaining({ provider_id: 'claude' }))

      await user.click(screen.getByTestId('next-step-button'))
      await waitFor(() => expect(screen.getByTestId('preferences-step')).toBeInTheDocument())
      expect(onboardingApi.putState).toHaveBeenCalledWith(
        'test-bearer-token',
        expect.objectContaining({ selected_provider_ids: ['claude'], step_index: 2, provider_run_state: { claude: { status: 'idle' } } }),
      )
    })
  })

  describe('Step 1 risk profile in replay', () => {
    const DECLARED = { sector: 'banking', jurisdiction: 'UK', reporting_currency: 'GBP', risk_appetite_tolerance: 5000, risk_load: 0.15 }

    beforeEach(() => {
      clientApi.settings.mockResolvedValue({
        tenant_id: 'tenant-test-123', org_name: 'Kusari', plan_tier: null, agent_count: 0, billing_tier: null,
        api_key_status: 'active', selected_frameworks: [], consent_required: true, cookie_preferences: null,
        preferred_scan_cadence_hours: 168, alert_email: 'ops@kusari.dev', alert_threshold: 7, ...DECLARED,
      })
    })

    it('loads the stored profile into the form and does not PATCH when nothing changed', async () => {
      const user = userEvent.setup()
      renderWizard({ mode: 'settings' })
      await waitFor(() => expect(screen.getByTestId('input-sector')).toHaveValue('banking'))
      expect(screen.getByTestId('input-jurisdiction')).toHaveValue('UK')
      expect(screen.getByTestId('input-reporting-currency')).toHaveValue('GBP')
      expect(screen.getByTestId('input-risk-appetite-tolerance')).toHaveValue(5000)

      await user.click(screen.getByTestId('next-step-button'))
      await waitFor(() => expect(screen.getByText('Identity Provider Linkage')).toBeInTheDocument())
      expect(clientApi.patchRiskProfile).not.toHaveBeenCalled()
    })

    it('one change PATCHes the whole profile with the stored risk_load preserved', async () => {
      const user = userEvent.setup()
      renderWizard({ mode: 'settings' })
      await waitFor(() => expect(screen.getByTestId('input-jurisdiction')).toHaveValue('UK'))
      await user.selectOptions(screen.getByTestId('input-jurisdiction'), 'EU')
      await user.click(screen.getByTestId('next-step-button'))

      await waitFor(() => expect(clientApi.patchRiskProfile).toHaveBeenCalled())
      expect(clientApi.patchRiskProfile).toHaveBeenCalledWith('test-bearer-token', { ...DECLARED, jurisdiction: 'EU' })
    })

    it('does not PATCH a guessed profile when the stored one could not be loaded', async () => {
      const user = userEvent.setup()
      clientApi.settings.mockRejectedValueOnce(new Error('503'))
      renderWizard({ mode: 'settings' })
      await waitFor(() => expect(screen.getByTestId('input-jurisdiction')).toBeInTheDocument())
      await user.selectOptions(screen.getByTestId('input-jurisdiction'), 'EU')
      await user.click(screen.getByTestId('next-step-button'))

      expect(await screen.findByText(/risk profile was not saved/i)).toBeInTheDocument()
      expect(clientApi.patchRiskProfile).not.toHaveBeenCalled()
    })
  })

  describe('Step 3: Scan preferences persist through the tenant settings API', () => {
    it('PATCHes /tenant/settings/preferences and advances to the API key step', async () => {
      const user = userEvent.setup()
      resumeAt(2)
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('preferences-step')).toBeInTheDocument())

      const email = screen.getByLabelText(/alert email/i)
      await user.clear(email)
      await user.type(email, 'secops@kusari.dev')
      await user.click(screen.getByRole('button', { name: /^continue$/i }))

      await waitFor(() => expect(screen.getByTestId('api-key-step')).toBeInTheDocument())
      expect(clientApi.patchPreferences).toHaveBeenCalledWith('test-bearer-token', {
        preferred_scan_cadence_hours: 168,
        alert_email: 'secops@kusari.dev',
        alert_threshold: 7,
      })
      expect(onboardingApi.putState).toHaveBeenCalledWith('test-bearer-token', expect.objectContaining({ step_index: 3 }))
    })

    it('sends null for a blank alert email', async () => {
      const user = userEvent.setup()
      resumeAt(2)
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('preferences-step')).toBeInTheDocument())
      await user.clear(screen.getByLabelText(/alert email/i))
      await user.click(screen.getByRole('button', { name: /^continue$/i }))
      await waitFor(() => expect(clientApi.patchPreferences).toHaveBeenCalled())
      expect(clientApi.patchPreferences.mock.calls[0][1]).toMatchObject({ alert_email: null })
    })

    it('stays on the step and shows the server error when the PATCH fails', async () => {
      const user = userEvent.setup()
      clientApi.patchPreferences.mockRejectedValueOnce(new Error('alert_threshold must be at least 1'))
      resumeAt(2)
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('preferences-step')).toBeInTheDocument())
      await user.click(screen.getByRole('button', { name: /^continue$/i }))

      expect(await screen.findByText(/alert_threshold must be at least 1/)).toBeInTheDocument()
      expect(screen.getByTestId('preferences-step')).toBeInTheDocument()
      expect(onboardingApi.putState).not.toHaveBeenCalledWith('test-bearer-token', expect.objectContaining({ step_index: 3 }))
    })
  })

  describe('Step 4: API key is opt-in', () => {
    it('reveals the key only after an explicit confirmation', async () => {
      const user = userEvent.setup()
      resumeAt(3)
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('api-key-step')).toBeInTheDocument())

      await user.click(screen.getByRole('button', { name: /reveal my api key/i }))
      expect(clientApi.apiKeys.revealInitial).not.toHaveBeenCalled()
      await user.click(screen.getByRole('button', { name: /yes, reveal it/i }))

      expect(await screen.findByText('sl_live_abcdef0123456789')).toBeInTheDocument()
      expect(clientApi.apiKeys.revealInitial).toHaveBeenCalledWith('test-bearer-token', 'tenant-test-123')
    })

    it('lets the user defer the reveal and moves on to Containment & Consent', async () => {
      const user = userEvent.setup()
      resumeAt(3)
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('api-key-step')).toBeInTheDocument())
      await user.click(screen.getByRole('button', { name: /do this later/i }))
      await waitFor(() => expect(screen.getByText('Containment Policy & Security Consent')).toBeInTheDocument())
      expect(clientApi.apiKeys.revealInitial).not.toHaveBeenCalled()
      expect(onboardingApi.putState).toHaveBeenCalledWith('test-bearer-token', expect.objectContaining({ step_index: 4 }))
    })

    it('shows the reveal error when the key has already been shown', async () => {
      const user = userEvent.setup()
      clientApi.apiKeys.revealInitial.mockRejectedValueOnce(new Error('Initial key already revealed'))
      resumeAt(3)
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('api-key-step')).toBeInTheDocument())
      await user.click(screen.getByRole('button', { name: /reveal my api key/i }))
      await user.click(screen.getByRole('button', { name: /yes, reveal it/i }))
      expect(await screen.findByText(/Initial key already revealed/)).toBeInTheDocument()
    })
  })

  describe('Step 5: Containment, consent and completion', () => {
    it('validates consent checkboxes before allowing completion', async () => {
      const user = userEvent.setup()
      resumeAt(4)
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('complete-onboarding-button')).toBeInTheDocument())

      await user.click(screen.getByTestId('consent-zero-trust'))
      await user.click(screen.getByTestId('complete-onboarding-button'))

      expect(screen.getByTestId('validation-error-banner')).toBeInTheDocument()
      expect(screen.getByText(/Zero-Trust Workload Identity consent is required/i)).toBeInTheDocument()
      expect(onboardingApi.complete).not.toHaveBeenCalled()
    })

    it('executes full completion, refreshes context, and renders the celebration', async () => {
      const user = userEvent.setup()
      resumeAt(4)
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('complete-onboarding-button')).toBeInTheDocument())
      await user.click(screen.getByTestId('complete-onboarding-button'))

      await waitFor(() => {
        expect(onboardingApi.complete).toHaveBeenCalledWith('test-bearer-token')
        expect(mockRefreshOnboardingState).toHaveBeenCalled()
        expect(screen.getByTestId('completion-celebration')).toBeInTheDocument()
      })
      expect(onboardingApi.putState).toHaveBeenCalledWith('test-bearer-token', expect.objectContaining({ step_index: 4 }))

      await user.click(screen.getByTestId('goto-dashboard-button'))
      expect(mockNavigate).toHaveBeenCalledWith('/overview', { replace: true })
    })

    it('does not celebrate a verified connection that was only claimed by stored client state', async () => {
      const user = userEvent.setup()
      resumeAt(4, { dex: { status: 'connected' } })
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('complete-onboarding-button')).toBeInTheDocument())
      await user.click(screen.getByTestId('complete-onboarding-button'))
      const celebration = await screen.findByTestId('completion-celebration')
      expect(celebration).toHaveTextContent('Connection not verified')
      expect(celebration).not.toHaveTextContent('Connection verified'.replace(/^/, '✓ '))
      expect(onboardingApi.complete).toHaveBeenCalled()
    })

    it('renders the error banner when the completion API rejects', async () => {
      const user = userEvent.setup()
      vi.mocked(onboardingApi.complete).mockRejectedValueOnce(new OnboardingApiError('Database transaction conflict during completion', 500))
      resumeAt(4)
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('complete-onboarding-button')).toBeInTheDocument())
      await user.click(screen.getByTestId('complete-onboarding-button'))

      await waitFor(() => {
        expect(screen.getByTestId('validation-error-banner')).toBeInTheDocument()
        expect(screen.getByText(/Database transaction conflict during completion/i)).toBeInTheDocument()
      })
    })
  })

  describe('Skip', () => {
    it('dispatches onboardingApi.skip, refreshes state, and navigates to returnTo', async () => {
      const user = userEvent.setup()
      resumeAt(1)
      renderWizard()
      await waitFor(() => expect(screen.getByTestId('skip-onboarding-button')).toBeInTheDocument())
      await user.click(screen.getByTestId('skip-onboarding-button'))

      await waitFor(() => {
        expect(onboardingApi.skip).toHaveBeenCalledWith('test-bearer-token')
        expect(screen.queryByText(/exit/i)).not.toBeInTheDocument()
        expect(mockRefreshOnboardingState).toHaveBeenCalled()
        expect(mockNavigate).toHaveBeenCalledWith('/overview', { replace: true })
      })
    })

    it('in settings replay, the header Exit leaves locally and never flips a completed tenant to skipped', async () => {
      const user = userEvent.setup()
      const onSkipped = vi.fn()
      vi.mocked(onboardingApi.getStatus).mockResolvedValueOnce({ status: 'completed', skipped_at: null, completed_at: '2026-09-10T08:00:00Z' })
      renderWizard({ mode: 'settings', onSkipped })
      const exit = await screen.findByTestId('skip-onboarding-button')
      expect(exit).toHaveTextContent(/exit/i)
      await user.click(exit)

      await waitFor(() => expect(onSkipped).toHaveBeenCalled())
      expect(onboardingApi.skip).not.toHaveBeenCalled()
    })

    it.each([
      ['Organization & Identity', 0],
      ['Identity Provider', 1],
      ['Containment & Consent', 4],
    ])('in replay, the %s step skip exits locally too', async (_name, initialStepIndex) => {
      const user = userEvent.setup()
      renderWizard({ allowReplay: true, initialStepIndex })
      const skip = await screen.findByTestId('step-skip-button')
      expect(skip).toHaveTextContent(/exit/i)
      await user.click(skip)
      await waitFor(() => expect(mockNavigate).toHaveBeenCalledWith('/overview', { replace: true }))
      expect(onboardingApi.skip).not.toHaveBeenCalled()
    })
  })

  describe('Settings and replay mode', () => {
    it('does not get trapped in CompletionCelebration when status is completed with allowReplay={true}', async () => {
      vi.mocked(onboardingApi.getStatus).mockResolvedValueOnce({ status: 'completed', skipped_at: null, completed_at: '2026-09-10T08:00:00Z' })
      renderWizard({ allowReplay: true })

      await waitFor(() => expect(screen.getByTestId('onboarding-replay-banner')).toBeInTheDocument())
      expect(screen.queryByTestId('completion-celebration')).not.toBeInTheDocument()
      expect(screen.queryByTestId('onboarding-welcome')).not.toBeInTheDocument()
      expect(screen.getByText(/Onboarding previously completed. You can re-run any step/i)).toBeInTheDocument()
      expect(screen.getByLabelText(/Organization \/ Tenant Name/i)).toBeInTheDocument()
    })

    it('does not get trapped in CompletionCelebration when status is completed with mode="settings"', async () => {
      vi.mocked(onboardingApi.getStatus).mockResolvedValueOnce({ status: 'completed', skipped_at: null, completed_at: '2026-09-10T08:00:00Z' })
      renderWizard({ mode: 'settings' })

      await waitFor(() => expect(screen.getByTestId('onboarding-replay-banner')).toBeInTheDocument())
      expect(screen.queryByTestId('completion-celebration')).not.toBeInTheDocument()
      expect(screen.queryByTestId('onboarding-welcome')).not.toBeInTheDocument()
      expect(screen.getByLabelText(/Organization \/ Tenant Name/i)).toBeInTheDocument()
    })

    it('respects initialStepIndex in settings mode', async () => {
      renderWizard({ mode: 'settings', initialStepIndex: 2 })
      await waitFor(() => expect(screen.getByTestId('preferences-step')).toBeInTheDocument())
      expect(screen.queryByTestId('onboarding-welcome')).not.toBeInTheDocument()
    })

    it('in mode="settings", clicking any step in the header navigates to that step', async () => {
      const user = userEvent.setup()
      renderWizard({ mode: 'settings' })
      await waitFor(() => expect(screen.getByLabelText(/Organization \/ Tenant Name/i)).toBeInTheDocument())

      // Operator can jump from step 0 directly to step 2 (Scan preferences)
      const preferencesStepBtn = screen.getByRole('button', { name: /scan preferences/i })
      await user.click(preferencesStepBtn)
      await waitFor(() => expect(screen.getByTestId('preferences-step')).toBeInTheDocument())

      // Operator can jump from step 2 to step 4 (Containment & Consent)
      const containmentStepBtn = screen.getByRole('button', { name: /containment & consent/i })
      await user.click(containmentStepBtn)
      await waitFor(() => expect(screen.getByText('Containment Policy & Security Consent')).toBeInTheDocument())

      // Operator can jump back to step 0 (Organization & Identity)
      const identityStepBtn = screen.getByRole('button', { name: /organization & identity/i })
      await user.click(identityStepBtn)
      await waitFor(() => expect(screen.getByLabelText(/Organization \/ Tenant Name/i)).toBeInTheDocument())
    })

    it('completing in mode="settings" calls onCompleted and renders success banner with Modify Again and Done buttons', async () => {
      const user = userEvent.setup()
      const onCompleted = vi.fn()
      renderWizard({ mode: 'settings', initialStepIndex: 4, onCompleted })

      await waitFor(() => expect(screen.getByTestId('complete-onboarding-button')).toBeInTheDocument())
      await user.click(screen.getByTestId('complete-onboarding-button'))

      await waitFor(() => {
        expect(onboardingApi.complete).toHaveBeenCalledWith('test-bearer-token')
        expect(onCompleted).toHaveBeenCalled()
        expect(screen.getByTestId('onboarding-settings-completed-banner')).toBeInTheDocument()
      })

      expect(screen.getByText(/Onboarding configuration updated successfully/i)).toBeInTheDocument()
      // No API persists the containment choices, so the banner must not claim
      // they took effect anywhere.
      const banner = screen.getByTestId('onboarding-settings-completed-banner')
      expect(banner).not.toHaveTextContent(/active across all agents/i)
      expect(banner).toHaveTextContent(/containment policy choices are not saved/i)
      expect(screen.queryByTestId('completion-celebration')).not.toBeInTheDocument()

      // Clicking Modify Again resets completed banner to review/edit steps
      const modifyAgainBtn = screen.getByRole('button', { name: /modify again/i })
      await user.click(modifyAgainBtn)
      await waitFor(() => {
        expect(screen.queryByTestId('onboarding-settings-completed-banner')).not.toBeInTheDocument()
        expect(screen.getByTestId('onboarding-replay-banner')).toBeInTheDocument()
      })

      // When completed again, clicking Done triggers onCompleted
      await user.click(screen.getByTestId('complete-onboarding-button'))
      await waitFor(() => expect(screen.getByTestId('onboarding-settings-completed-banner')).toBeInTheDocument())
      const doneBtn = screen.getByRole('button', { name: /done/i })
      await user.click(doneBtn)
      expect(onCompleted).toHaveBeenCalledTimes(3)
    })
  })
})
