/**
 * The identity step's declared risk profile, and the bug that it is saved at all.
 *
 * Before this, ``TenantIdentityStep`` collected an organisation profile,
 * ``OnboardingWizard`` held it in React state, and NOTHING ever sent it
 * anywhere -- it did not even reach ``wizard_state``. A tenant typed its
 * identity, clicked Next, and the whole thing evaporated on reload.
 *
 * The first test here is that regression guard. The rest pin the behaviours
 * that make an optional declaration safe: blank means undeclared (not ''), a
 * money amount cannot be declared without its denomination, and a failed save
 * warns rather than either blocking the step or failing silently.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import OnboardingWizard from './OnboardingWizard'

vi.mock('react-router-dom', async (importOriginal) => ({
  ...(await importOriginal<typeof import('react-router-dom')>()),
  useNavigate: () => vi.fn(),
}))

const auth = vi.hoisted(() => ({
  isAuthenticated: true,
  isLoading: false,
  getAccessTokenSilently: vi.fn<() => Promise<string>>().mockResolvedValue('test-bearer-token'),
  loginWithRedirect: vi.fn(),
  user: { email: 'operator@acme.corp', name: 'Operator' },
}))
vi.mock('../../auth/oidc', () => ({ useAuth0: () => auth }))

vi.mock('../../auth/tenant', () => ({
  getTenantIdFromToken: () => 'tenant-test-123',
}))

vi.mock('../../App', () => ({
  useAppContext: () => ({ refreshOnboarding: vi.fn() }),
}))

const clientApi = vi.hoisted(() => ({
  me: vi.fn(),
  settings: vi.fn(),
  patchPreferences: vi.fn(),
  patchRiskProfile: vi.fn(),
  apiKeys: { revealInitial: vi.fn() },
}))
vi.mock('../../api/client', () => ({ api: clientApi }))

const onboardingApi = vi.hoisted(() => ({
  getStatus: vi.fn(),
  getState: vi.fn(),
  putState: vi.fn(),
  skip: vi.fn(),
  complete: vi.fn(),
}))
vi.mock('../../api/onboardingClient', () => ({
  onboardingApi,
  OnboardingApiError: class extends Error {
    status?: number
    constructor(message: string, status?: number) {
      super(message)
      this.name = 'OnboardingApiError'
      this.status = status
    }
  },
}))

const SETTINGS = {
  tenant_id: 'tenant-test-123',
  org_name: 'Acme',
  plan_tier: null,
  agent_count: 0,
  billing_tier: null,
  api_key_status: 'active',
  selected_frameworks: [],
  consent_required: true,
  cookie_preferences: null,
  preferred_scan_cadence_hours: 24,
  alert_email: null,
  alert_threshold: 1,
  sector: null,
  jurisdiction: null,
  reporting_currency: null,
  risk_appetite_tolerance: null,
  risk_load: null,
}

describe('the declared risk profile in the onboarding wizard', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    auth.isAuthenticated = true
    auth.isLoading = false
    auth.getAccessTokenSilently.mockResolvedValue('test-bearer-token')
    onboardingApi.getStatus.mockResolvedValue({ status: 'pending', skipped_at: null, completed_at: null })
    onboardingApi.getState.mockResolvedValue({ selected_provider_ids: [], step_index: 0, provider_run_state: {} })
    onboardingApi.putState.mockResolvedValue({ selected_provider_ids: [], step_index: 0, provider_run_state: {} })
    onboardingApi.skip.mockResolvedValue({ status: 'skipped', skipped_at: '2026-09-10T09:00:00Z', completed_at: null })
    onboardingApi.complete.mockResolvedValue({ status: 'completed', skipped_at: null, completed_at: '2026-09-10T09:00:00Z' })
    clientApi.me.mockResolvedValue({
      subject: 'acme-operator', tenant: 'tenant-test-123',
      email: 'operator@acme.corp', superadmin: false,
    })
    clientApi.settings.mockResolvedValue(SETTINGS)
    clientApi.patchRiskProfile.mockResolvedValue(SETTINGS)
  })

  function renderWizard() {
    return render(
      <MemoryRouter initialEntries={['/onboarding']}>
        <OnboardingWizard />
      </MemoryRouter>,
    )
  }

  async function pastWelcome(user: ReturnType<typeof userEvent.setup>) {
    const welcome = await screen.findByTestId('onboarding-welcome')
    await user.click(within(welcome).getByTestId('welcome-continue-button'))
    await waitFor(() => expect(screen.getByText('Tenant & Workspace Identity')).toBeInTheDocument())
  }

  it('PATCHes the declared profile instead of discarding it', async () => {
    const user = userEvent.setup()
    renderWizard()
    await pastWelcome(user)

    await user.type(screen.getByTestId('input-sector'), 'healthcare-provider')
    await user.selectOptions(screen.getByTestId('input-jurisdiction'), 'US')
    await user.selectOptions(screen.getByTestId('input-reporting-currency'), 'USD')
    await user.type(screen.getByTestId('input-risk-appetite-tolerance'), '6000')
    await user.click(screen.getByTestId('next-step-button'))

    await waitFor(() => expect(clientApi.patchRiskProfile).toHaveBeenCalled())
    expect(clientApi.patchRiskProfile).toHaveBeenCalledWith('test-bearer-token', {
      sector: 'healthcare-provider',
      jurisdiction: 'US',
      reporting_currency: 'USD',
      risk_appetite_tolerance: 6000,
      risk_load: null,
    })
  })

  it('sends null rather than an empty string when a stored declaration is cleared', async () => {
    clientApi.settings.mockResolvedValue({ ...SETTINGS, jurisdiction: 'UK' })
    const user = userEvent.setup()
    renderWizard()
    await pastWelcome(user)

    await user.selectOptions(screen.getByTestId('input-jurisdiction'), '')
    await user.click(screen.getByTestId('next-step-button'))

    await waitFor(() => expect(clientApi.patchRiskProfile).toHaveBeenCalled())
    expect(clientApi.patchRiskProfile.mock.calls[0][1]).toEqual({
      sector: null,
      jurisdiction: null,
      reporting_currency: null,
      risk_appetite_tolerance: null,
      risk_load: null,
    })
  })

  it('still advances to the next step when nothing was declared', async () => {
    const user = userEvent.setup()
    renderWizard()
    await pastWelcome(user)

    await user.click(screen.getByTestId('next-step-button'))

    await waitFor(() => expect(screen.getByText('Identity Provider Linkage')).toBeInTheDocument())
  })

  it('refuses a tolerance with no currency, because an amount needs a denomination', async () => {
    const user = userEvent.setup()
    renderWizard()
    await pastWelcome(user)

    await user.type(screen.getByTestId('input-risk-appetite-tolerance'), '6000')
    await user.click(screen.getByTestId('next-step-button'))

    expect(await screen.findByTestId('validation-error-banner')).toBeInTheDocument()
    expect(clientApi.patchRiskProfile).not.toHaveBeenCalled()
  })

  it('refuses a non-positive tolerance', async () => {
    const user = userEvent.setup()
    renderWizard()
    await pastWelcome(user)

    await user.selectOptions(screen.getByTestId('input-reporting-currency'), 'GBP')
    await user.type(screen.getByTestId('input-risk-appetite-tolerance'), '-5')
    await user.click(screen.getByTestId('next-step-button'))

    expect(await screen.findByTestId('validation-error-banner')).toBeInTheDocument()
    expect(clientApi.patchRiskProfile).not.toHaveBeenCalled()
  })

  it('warns but does not block the step when the save fails', async () => {
    clientApi.patchRiskProfile.mockRejectedValue(new Error('boom'))
    const user = userEvent.setup()
    renderWizard()
    await pastWelcome(user)

    await user.selectOptions(screen.getByTestId('input-jurisdiction'), 'UK')
    await user.click(screen.getByTestId('next-step-button'))

    // The warning is visible -- a silent failure would let the operator believe
    // a declaration landed when it did not.
    await waitFor(() => expect(screen.getByTestId('validation-error-banner')).toBeInTheDocument())
    // And the optional step did not become a wall.
    await waitFor(() => expect(screen.getByText('Identity Provider Linkage')).toBeInTheDocument())
  })

  it('offers Global as a distinct choice from not declaring', async () => {
    const user = userEvent.setup()
    renderWizard()
    await pastWelcome(user)

    await user.selectOptions(screen.getByTestId('input-jurisdiction'), '*')
    await user.click(screen.getByTestId('next-step-button'))

    await waitFor(() => expect(clientApi.patchRiskProfile).toHaveBeenCalled())
    expect(clientApi.patchRiskProfile.mock.calls[0][1].jurisdiction).toBe('*')
  })
})
