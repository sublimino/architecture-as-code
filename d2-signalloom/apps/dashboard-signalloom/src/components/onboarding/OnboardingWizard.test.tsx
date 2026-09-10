import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
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

    vi.mocked(onboardingApi.getStatus).mockResolvedValue({
      status: 'pending',
      skipped_at: null,
      completed_at: null,
    })

    vi.mocked(onboardingApi.getState).mockResolvedValue({
      selected_provider_ids: [],
      step_index: 0,
      provider_run_state: {},
    })

    vi.mocked(onboardingApi.putState).mockResolvedValue({
      selected_provider_ids: ['dex'],
      step_index: 0,
      provider_run_state: {},
    })

    vi.mocked(onboardingApi.skip).mockResolvedValue({
      status: 'skipped',
      skipped_at: '2026-09-10T09:00:00Z',
      completed_at: null,
    })

    vi.mocked(onboardingApi.complete).mockResolvedValue({
      status: 'completed',
      skipped_at: null,
      completed_at: '2026-09-10T09:00:00Z',
    })
  })

  function renderWizard() {
    return render(
      <MemoryRouter initialEntries={['/onboarding']}>
        <OnboardingWizard />
      </MemoryRouter>,
    )
  }

  describe('Initial Load & State Restoration', () => {
    it('renders Step 1 (Tenant & Workspace Identity) by default for fresh tenants', async () => {
      renderWizard()

      await waitFor(() => {
        expect(screen.getByText('Tenant & Workspace Identity')).toBeInTheDocument()
      })

      expect(screen.getByLabelText(/Organization \/ Tenant Name/i)).toHaveValue('Acme Corporation')
      expect(screen.getByLabelText(/Workspace Identifier/i)).toHaveValue('acme-primary')
      expect(screen.getByLabelText(/Primary Operator Email/i)).toHaveValue('operator@acme.corp')
      expect(screen.getByTestId('next-step-button')).toBeInTheDocument()
    })

    it('resumes at Step 2 when server reports step_index 1', async () => {
      vi.mocked(onboardingApi.getState).mockResolvedValueOnce({
        selected_provider_ids: ['dex'],
        step_index: 1,
        provider_run_state: { dex: { status: 'connected' } },
      })

      renderWizard()

      await waitFor(() => {
        expect(screen.getByText('Identity Provider Linkage')).toBeInTheDocument()
      })

      expect(screen.getByTestId('idp-option-dex')).toBeInTheDocument()
      expect(screen.getByTestId('input-idp-issuer-url')).toBeInTheDocument()
    })

    it('resumes at Step 3 when server reports step_index 2', async () => {
      vi.mocked(onboardingApi.getState).mockResolvedValueOnce({
        selected_provider_ids: ['dex'],
        step_index: 2,
        provider_run_state: {},
      })

      renderWizard()

      await waitFor(() => {
        expect(screen.getByText('Containment Policy & Security Consent')).toBeInTheDocument()
      })

      expect(screen.getByTestId('complete-onboarding-button')).toBeInTheDocument()
    })

    it('displays celebratory screen directly if already completed', async () => {
      vi.mocked(onboardingApi.getStatus).mockResolvedValueOnce({
        status: 'completed',
        skipped_at: null,
        completed_at: '2026-09-10T08:00:00Z',
      })

      renderWizard()

      await waitFor(() => {
        expect(screen.getByTestId('completion-celebration')).toBeInTheDocument()
      })

      expect(screen.getByText('Onboarding Completed!')).toBeInTheDocument()
    })
  })

  describe('Step 1: Tenant & Workspace Identity Validation & Submission', () => {
    it('validates required fields and shows error banner on invalid input', async () => {
      const user = userEvent.setup()
      renderWizard()

      await waitFor(() => {
        expect(screen.getByText('Tenant & Workspace Identity')).toBeInTheDocument()
      })

      // Clear organization name and email
      const orgInput = screen.getByTestId('input-organization-name')
      await user.clear(orgInput)

      const emailInput = screen.getByTestId('input-admin-email')
      await user.clear(emailInput)
      await user.type(emailInput, 'invalid-email-address')

      const nextBtn = screen.getByTestId('next-step-button')
      await user.click(nextBtn)

      expect(screen.getByTestId('validation-error-banner')).toBeInTheDocument()
      expect(screen.getByText('Organization Name is required.')).toBeInTheDocument()
      expect(screen.getByText(/Please enter a valid email address/i)).toBeInTheDocument()

      // API putState should not be called on validation failure
      expect(onboardingApi.putState).not.toHaveBeenCalled()
    })

    it('advances to Step 2 and persists state on valid submission', async () => {
      const user = userEvent.setup()
      renderWizard()

      await waitFor(() => {
        expect(screen.getByText('Tenant & Workspace Identity')).toBeInTheDocument()
      })

      const orgInput = screen.getByTestId('input-organization-name')
      await user.clear(orgInput)
      await user.type(orgInput, 'Global Defense Corp')

      const nextBtn = screen.getByTestId('next-step-button')
      await user.click(nextBtn)

      await waitFor(() => {
        expect(screen.getByText('Identity Provider Linkage')).toBeInTheDocument()
      })

      expect(onboardingApi.putState).toHaveBeenCalledWith(
        'test-bearer-token',
        expect.objectContaining({
          step_index: 1,
        }),
      )
    })
  })

  describe('Step 2: Identity Provider Linkage & Connection Test', () => {
    it('allows selecting different IdPs and updates pre-filled defaults', async () => {
      const user = userEvent.setup()
      vi.mocked(onboardingApi.getState).mockResolvedValueOnce({
        selected_provider_ids: [],
        step_index: 1,
        provider_run_state: {},
      })

      renderWizard()

      await waitFor(() => {
        expect(screen.getByText('Identity Provider Linkage')).toBeInTheDocument()
      })

      // Select Okta
      const oktaBtn = screen.getByTestId('idp-option-okta')
      await user.click(oktaBtn)

      expect(screen.getByTestId('input-idp-issuer-url')).toHaveValue('https://dev-signalloom.okta.com/oauth2/default')
      expect(screen.getByTestId('input-idp-client-id')).toHaveValue('signalloom-okta-client')

      // Select Entra
      const entraBtn = screen.getByTestId('idp-option-ad_entra')
      await user.click(entraBtn)

      expect(screen.getByTestId('input-idp-issuer-url')).toHaveValue('https://login.microsoftonline.com/common/v2.0')
      expect(screen.getByTestId('input-idp-client-id')).toHaveValue('signalloom-entra-app')
    })

    it('executes connection test and renders status verification', async () => {
      const user = userEvent.setup()
      vi.mocked(onboardingApi.getState).mockResolvedValueOnce({
        selected_provider_ids: ['dex'],
        step_index: 1,
        provider_run_state: {},
      })

      renderWizard()

      await waitFor(() => {
        expect(screen.getByTestId('test-idp-connection-button')).toBeInTheDocument()
      })

      const testBtn = screen.getByTestId('test-idp-connection-button')
      await user.click(testBtn)

      await waitFor(() => {
        expect(screen.getByTestId('idp-connection-success')).toBeInTheDocument()
      })

      expect(screen.getByText(/OIDC discovery document verified/i)).toBeInTheDocument()
    })

    it('supports navigating Back to Step 1', async () => {
      const user = userEvent.setup()
      vi.mocked(onboardingApi.getState).mockResolvedValueOnce({
        selected_provider_ids: ['dex'],
        step_index: 1,
        provider_run_state: {},
      })

      renderWizard()

      await waitFor(() => {
        expect(screen.getByTestId('back-step-button')).toBeInTheDocument()
      })

      const backBtn = screen.getByTestId('back-step-button')
      await user.click(backBtn)

      await waitFor(() => {
        expect(screen.getByText('Tenant & Workspace Identity')).toBeInTheDocument()
      })
    })

    it('advances to Step 3 and persists state on Next click', async () => {
      const user = userEvent.setup()
      vi.mocked(onboardingApi.getState).mockResolvedValueOnce({
        selected_provider_ids: ['dex'],
        step_index: 1,
        provider_run_state: {},
      })

      renderWizard()

      await waitFor(() => {
        expect(screen.getByTestId('next-step-button')).toBeInTheDocument()
      })

      const nextBtn = screen.getByTestId('next-step-button')
      await user.click(nextBtn)

      await waitFor(() => {
        expect(screen.getByText('Containment Policy & Security Consent')).toBeInTheDocument()
      })

      expect(onboardingApi.putState).toHaveBeenCalledWith(
        'test-bearer-token',
        expect.objectContaining({
          step_index: 2,
        }),
      )
    })
  })

  describe('Step 3: Containment Policy, Consent & Full Completion', () => {
    it('validates consent checkboxes before allowing completion', async () => {
      const user = userEvent.setup()
      vi.mocked(onboardingApi.getState).mockResolvedValueOnce({
        selected_provider_ids: ['dex'],
        step_index: 2,
        provider_run_state: {},
      })

      renderWizard()

      await waitFor(() => {
        expect(screen.getByTestId('complete-onboarding-button')).toBeInTheDocument()
      })

      // Uncheck zero trust consent
      const zeroTrustCb = screen.getByTestId('consent-zero-trust')
      await user.click(zeroTrustCb)

      const completeBtn = screen.getByTestId('complete-onboarding-button')
      await user.click(completeBtn)

      expect(screen.getByTestId('validation-error-banner')).toBeInTheDocument()
      expect(screen.getByText(/Zero-Trust Workload Identity consent is required/i)).toBeInTheDocument()
      expect(onboardingApi.complete).not.toHaveBeenCalled()
    })

    it('executes full completion, updates context, and renders celebration', async () => {
      const user = userEvent.setup()
      vi.mocked(onboardingApi.getState).mockResolvedValueOnce({
        selected_provider_ids: ['dex'],
        step_index: 2,
        provider_run_state: {},
      })

      renderWizard()

      await waitFor(() => {
        expect(screen.getByTestId('complete-onboarding-button')).toBeInTheDocument()
      })

      const completeBtn = screen.getByTestId('complete-onboarding-button')
      await user.click(completeBtn)

      await waitFor(() => {
        expect(onboardingApi.complete).toHaveBeenCalledWith('test-bearer-token')
        expect(mockRefreshOnboardingState).toHaveBeenCalled()
        expect(screen.getByTestId('completion-celebration')).toBeInTheDocument()
      })

      expect(screen.getByText('Onboarding Completed!')).toBeInTheDocument()

      // Click Go to Dashboard
      const dashboardBtn = screen.getByTestId('goto-dashboard-button')
      await user.click(dashboardBtn)

      expect(mockNavigate).toHaveBeenCalledWith('/overview', { replace: true })
    })

    it('renders error banner when completion API rejects', async () => {
      const user = userEvent.setup()
      vi.mocked(onboardingApi.complete).mockRejectedValueOnce(
        new OnboardingApiError('Database transaction conflict during completion', 500),
      )
      vi.mocked(onboardingApi.getState).mockResolvedValueOnce({
        selected_provider_ids: ['dex'],
        step_index: 2,
        provider_run_state: {},
      })

      renderWizard()

      await waitFor(() => {
        expect(screen.getByTestId('complete-onboarding-button')).toBeInTheDocument()
      })

      const completeBtn = screen.getByTestId('complete-onboarding-button')
      await user.click(completeBtn)

      await waitFor(() => {
        expect(screen.getByTestId('validation-error-banner')).toBeInTheDocument()
        expect(screen.getByText(/Database transaction conflict during completion/i)).toBeInTheDocument()
      })
    })
  })

  describe('Skip Action', () => {
    it('dispatches onboardingApi.skip, refreshes state, and navigates to returnTo', async () => {
      const user = userEvent.setup()
      renderWizard()

      await waitFor(() => {
        expect(screen.getByTestId('skip-onboarding-button')).toBeInTheDocument()
      })

      const skipBtn = screen.getByTestId('skip-onboarding-button')
      await user.click(skipBtn)

      await waitFor(() => {
        expect(onboardingApi.skip).toHaveBeenCalledWith('test-bearer-token')
        expect(mockRefreshOnboardingState).toHaveBeenCalled()
        expect(mockNavigate).toHaveBeenCalledWith('/overview', { replace: true })
      })
    })
  })
})
