import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor, act, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import FeaturesPage from './FeaturesPage'
import * as featuresApiModule from '../../api/featuresApi'
import { api } from '../../api/client'
import { AppContext } from '../../App'
import { DEFAULT_SYSTEM_FLAGS } from '../../types/features'
import { ACCOUNT_TYPES, EAP_VIEW_FLAGS } from '../../types/accountTypes'

const mockGetAccessTokenSilently = vi.fn().mockResolvedValue('test-bearer-token')
const mockAuthUser = {
  email: 'admin@acme.com',
  name: 'Admin User',
}

vi.mock('../../auth/oidc', () => ({
  useAuth0: () => ({
    user: mockAuthUser,
    getAccessTokenSilently: mockGetAccessTokenSilently,
    token: 'test-bearer-token',
  }),
}))

vi.mock('../../api/client', () => ({
  api: {
    settings: vi.fn().mockResolvedValue({
      tenant_id: 'kusari',
      org_name: 'Kusari Enterprise',
      plan_tier: 'enterprise',
      agent_count: 5,
    }),
  },
}))

const mockServerSuperadmin = { superadmin: false, resolved: true }
vi.mock('../../auth/superadmin', () => ({
  useServerSuperadmin: () => mockServerSuperadmin,
}))

// The catalogue as GET /api/v1/admin/features/presets serves it: the three
// account types, then other bundles.
const MOCK_PRESETS = [
  ...ACCOUNT_TYPES,
  {
    id: 'minimal_governance',
    name: 'Minimal Governance',
    kind: 'bundle' as const,
    status: 'confirmed' as const,
    aliases: [],
    description: 'Minimal boundary view: agents registry, policy compliance, and audit trail only.',
    flags: {
      ...Object.fromEntries(Object.keys(DEFAULT_SYSTEM_FLAGS).map((k) => [k, false])),
      core_governance: true,
      audit: true,
      page_agents: true,
      page_audit: true,
    },
  },
]

const MOCK_FEATURES_DATA = {
  tenant_id: 'kusari',
  flags: {
    ...DEFAULT_SYSTEM_FLAGS,
    page_discovery: true,
    page_agents: true,
    page_topology: true,
    page_weave: true,
    page_signals: true,
    page_risk: true,
    page_policies: true,
    page_compliance: true,
    page_audit: true,
    page_federated_services: true,
    page_cryptography: true,
    page_credential_inventory: true,
    page_signal_store: false,
    page_feeds: false,
    page_network_tests: false,
    page_agentmaxxing: false,
    demos_fleet: false,
    supercred: false,
    rbac_analysis: false,
    collusion_access: false,
  },
}

const appCtxDefault = {
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
  needsOnboarding: null as boolean | null,
  refreshOnboardingState: () => Promise.resolve(),
  superadmin: false,
  setSuperadmin: () => undefined,
}

async function renderFeaturesPage(
  props: Partial<React.ComponentProps<typeof FeaturesPage>> = {},
  ctxOverrides: Partial<typeof appCtxDefault> = {},
) {
  let result: any
  await act(async () => {
    result = render(
      <AppContext.Provider value={{ ...appCtxDefault, ...ctxOverrides }}>
        <FeaturesPage {...props} />
      </AppContext.Provider>,
    )
    await Promise.resolve()
  })
  return result
}

describe('FeaturesPage Component', () => {
  let mockUseAdminFeatures: ReturnType<typeof vi.fn>
  let mockUseFeaturePresets: ReturnType<typeof vi.fn>
  let mockUseUpdateTenantFeatures: ReturnType<typeof vi.fn>
  let mockUseUpdateSingleFeature: ReturnType<typeof vi.fn>
  let mutateTenantAsyncMock: ReturnType<typeof vi.fn>
  let mutateSingleAsyncMock: ReturnType<typeof vi.fn>
  let refetchMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    vi.clearAllMocks()
    mockServerSuperadmin.superadmin = false

    refetchMock = vi.fn().mockResolvedValue({} as any)
    mutateTenantAsyncMock = vi.fn().mockImplementation(async (payload) => {
      let mergedFlags = { ...MOCK_FEATURES_DATA.flags, ...(payload.flags ?? {}) }
      if (payload.preset) {
        const found = MOCK_PRESETS.find((p) => p.id === payload.preset)
        if (found) {
          mergedFlags = { ...mergedFlags, ...found.flags }
        }
      }
      return {
        tenant_id: payload.tenant_id,
        flags: mergedFlags,
      }
    })
    mutateSingleAsyncMock = vi.fn().mockImplementation(async ({ tenantId, flagKey, payload }) => {
      return {
        tenant_id: tenantId,
        flags: { ...MOCK_FEATURES_DATA.flags, [flagKey]: payload.enabled },
      }
    })

    mockUseAdminFeatures = vi.fn().mockReturnValue({
      data: MOCK_FEATURES_DATA,
      isLoading: false,
      isFetching: false,
      isError: false,
      error: null,
      refetch: refetchMock,
    })

    mockUseFeaturePresets = vi.fn().mockReturnValue({
      data: { presets: MOCK_PRESETS },
      isLoading: false,
      isError: false,
      error: null,
    })

    mockUseUpdateTenantFeatures = vi.fn().mockImplementation((opts) => ({
      mutateAsync: async (vars: any) => {
        try {
          const res = await mutateTenantAsyncMock(vars)
          opts?.onSuccess?.(res)
          return res
        } catch (err) {
          opts?.onError?.(err as Error)
          throw err
        }
      },
      isLoading: false,
    }))

    mockUseUpdateSingleFeature = vi.fn().mockImplementation((opts) => ({
      mutateAsync: async (vars: any) => {
        try {
          const res = await mutateSingleAsyncMock(vars)
          opts?.onSuccess?.(res)
          return res
        } catch (err) {
          opts?.onError?.(err as Error)
          throw err
        }
      },
      isLoading: false,
    }))

    vi.spyOn(featuresApiModule, 'useAdminFeatures').mockImplementation(mockUseAdminFeatures)
    vi.spyOn(featuresApiModule, 'useFeaturePresets').mockImplementation(mockUseFeaturePresets)
    vi.spyOn(featuresApiModule, 'useUpdateTenantFeatures').mockImplementation(mockUseUpdateTenantFeatures)
    vi.spyOn(featuresApiModule, 'useUpdateSingleFeature').mockImplementation(mockUseUpdateSingleFeature)
  })

  it('renders page header, breadcrumbs, title, and descriptive summary', async () => {
    await renderFeaturesPage()

    expect(screen.getByRole('heading', { level: 1, name: 'Feature Flags & Presets' })).toBeInTheDocument()
    expect(screen.getByRole('navigation', { name: 'Breadcrumb' })).toBeInTheDocument()
    expect(screen.getAllByText('Feature Flags').length).toBeGreaterThanOrEqual(1)
    expect(
      screen.getByText(/Configure granular platform capabilities, route access, and enterprise preset bundles/i),
    ).toBeInTheDocument()
  })

  it('displays Global Superadmin pill when isSuperadmin is true', async () => {
    mockServerSuperadmin.superadmin = true
    await renderFeaturesPage({}, { superadmin: true })

    const pill = screen.getByTestId('superadmin-scope-pill')
    expect(pill).toBeInTheDocument()
    expect(pill).toHaveTextContent(/Global Superadmin/i)
  })

  it('hides Global Superadmin pill when isSuperadmin is false', async () => {
    mockServerSuperadmin.superadmin = false
    await renderFeaturesPage({}, { superadmin: false })

    expect(screen.queryByTestId('superadmin-scope-pill')).not.toBeInTheDocument()
  })

  it('renders AdminNavTabs sub-navigation with Users and Features links', async () => {
    await renderFeaturesPage()

    expect(screen.getByRole('tab', { name: /User Administration/i })).toBeInTheDocument()
    expect(screen.getByRole('tab', { name: /Feature Flags/i })).toBeInTheDocument()
  })

  it('renders tenant selector and allows switching between known tenants', async () => {
    await renderFeaturesPage({ defaultTenant: 'kusari' })

    const select = screen.getByTestId('admin-tenant-select') as HTMLSelectElement
    expect(select.value).toBe('kusari')

    fireEvent.change(select, { target: { value: 'tenant-demo' } })
    expect(select.value).toBe('tenant-demo')
  })

  it('allows entering a custom tenant ID and submitting switch form', async () => {
    await renderFeaturesPage({ defaultTenant: 'kusari' })

    const input = screen.getByTestId('custom-tenant-input')
    const button = screen.getByTestId('switch-tenant-btn')

    fireEvent.change(input, { target: { value: 'tenant-enterprise-x' } })
    fireEvent.click(button)

    const select = screen.getByTestId('admin-tenant-select') as HTMLSelectElement
    expect(select.value).toBe('custom')
    expect(screen.getByTestId('kpi-account-scope')).toHaveTextContent('tenant-enterprise-x')
  })

  it('offers the three account types as radio cards, EAP Full marked draft', async () => {
    await renderFeaturesPage()

    const group = screen.getByRole('radiogroup', { name: 'Account type' })
    const radios = within(group).getAllByRole('radio')
    expect(radios.map((r) => r.getAttribute('data-testid'))).toEqual([
      'account-type-option-eap_view',
      'account-type-option-eap_full',
      'account-type-option-full',
    ])
    expect(within(radios[0]!).getByText('EAP View (read-only)')).toBeInTheDocument()
    expect(within(radios[1]!).getByTestId('account-type-draft-eap_full')).toHaveTextContent('Draft')
    expect(within(radios[0]!).queryByText('Draft')).toBeNull()
  })

  it('summarises which pages each account type enables', async () => {
    await renderFeaturesPage()

    const view = screen.getByTestId('account-type-pages-eap_view')
    expect(view).toHaveTextContent('3 of 20 pages')
    expect(view).toHaveTextContent('Agents Registry')
    expect(view).toHaveTextContent('Discovery & Accounts')
    expect(view).toHaveTextContent('Governance Policies')
    expect(view).not.toHaveTextContent('Signal Stream')
    expect(screen.getByTestId('account-type-pages-full')).toHaveTextContent('20 of 20 pages')
  })

  it('shows the recorded account type, and the current card as checked', async () => {
    mockUseAdminFeatures.mockReturnValue({
      data: {
        ...MOCK_FEATURES_DATA,
        flags: EAP_VIEW_FLAGS,
        account_type: { id: 'eap_view', customised: false, matches: 'eap_view', label: 'EAP View (read-only)' },
      },
      isLoading: false, isFetching: false, isError: false, error: null, refetch: refetchMock,
    })
    await renderFeaturesPage()

    expect(screen.getByTestId('account-type-current')).toHaveTextContent('EAP View (read-only)')
    expect(screen.getByTestId('account-type-option-eap_view')).toHaveAttribute('aria-checked', 'true')
    expect(screen.getByTestId('account-type-option-full')).toHaveAttribute('aria-checked', 'false')
  })

  it('says "Custom, based on" once flags drift from the recorded type', async () => {
    mockUseAdminFeatures.mockReturnValue({
      data: {
        ...MOCK_FEATURES_DATA,
        flags: { ...EAP_VIEW_FLAGS, page_signals: true },
        account_type: { id: 'eap_view', customised: true, matches: null, label: 'Custom, based on EAP View (read-only)' },
      },
      isLoading: false, isFetching: false, isError: false, error: null, refetch: refetchMock,
    })
    await renderFeaturesPage()

    expect(screen.getByTestId('account-type-current')).toHaveTextContent('Custom, based on EAP View (read-only)')
    // No card claims to be the tenant's type when the flags no longer match it.
    for (const id of ['eap_view', 'eap_full', 'full']) {
      expect(screen.getByTestId(`account-type-option-${id}`)).toHaveAttribute('aria-checked', 'false')
    }
  })

  it('applies an account type only after confirmation', async () => {
    mockServerSuperadmin.superadmin = true
    await renderFeaturesPage({ defaultTenant: 'kusari' })

    fireEvent.click(screen.getByTestId('account-type-option-eap_view'))
    fireEvent.click(screen.getByTestId('account-type-apply'))

    const dialog = screen.getByRole('dialog')
    expect(dialog).toHaveTextContent('Apply EAP View (read-only) to kusari?')
    expect(dialog).toHaveTextContent('3 of 20 pages')
    expect(mutateTenantAsyncMock).not.toHaveBeenCalled()

    fireEvent.click(within(dialog).getByRole('button', { name: 'Cancel' }))
    expect(screen.queryByRole('dialog')).toBeNull()
    expect(mutateTenantAsyncMock).not.toHaveBeenCalled()

    fireEvent.click(screen.getByTestId('account-type-apply'))
    await act(async () => {
      fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Apply account type' }))
    })
    expect(mutateTenantAsyncMock).toHaveBeenCalledWith({ tenant_id: 'kusari', preset: 'eap_view' })
    await waitFor(() =>
      expect(screen.getByTestId('success-toast')).toHaveTextContent(
        'Account type "EAP View (read-only)" applied to "kusari".',
      ),
    )
  })

  it('does not let a non-superadmin apply an account type', async () => {
    mockServerSuperadmin.superadmin = false
    await renderFeaturesPage()

    fireEvent.click(screen.getByTestId('account-type-option-full'))
    expect(screen.getByTestId('account-type-apply')).toBeDisabled()
    expect(screen.getByTestId('account-type-superadmin-note')).toHaveTextContent('Only a superadmin can change')
  })

  it('falls back to the built-in account types when the catalogue is unavailable', async () => {
    mockUseFeaturePresets.mockReturnValue({ data: null, isLoading: false, isError: false, error: null })
    await renderFeaturesPage()

    expect(screen.getByTestId('account-type-option-eap_view')).toBeInTheDocument()
    expect(screen.getByTestId('account-type-pages-eap_view')).toHaveTextContent('3 of 20 pages')
  })

  it('keeps other preset bundles applicable, behind the same confirmation', async () => {
    mockServerSuperadmin.superadmin = true
    await renderFeaturesPage({ defaultTenant: 'kusari' })

    expect(screen.queryByTestId('preset-card-eap_view')).toBeNull()
    fireEvent.click(screen.getByTestId('apply-preset-minimal_governance'))
    await act(async () => {
      fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Apply account type' }))
    })
    expect(mutateTenantAsyncMock).toHaveBeenCalledWith({ tenant_id: 'kusari', preset: 'minimal_governance' })
  })

  it('renders KPI summary cards with computed metrics', async () => {
    await renderFeaturesPage()

    expect(screen.getByTestId('kpi-total-flags')).toBeInTheDocument()
    expect(screen.getByTestId('kpi-enabled-flags')).toBeInTheDocument()
    expect(screen.getByTestId('kpi-disabled-flags')).toBeInTheDocument()
    expect(screen.getByTestId('kpi-account-scope')).toBeInTheDocument()
  })

  it('renders feature flag cards grouped by categories with routes and status badges', async () => {
    await renderFeaturesPage()

    expect(screen.getByTestId('category-group-operational')).toBeInTheDocument()
    expect(screen.getByTestId('category-group-security')).toBeInTheDocument()
    expect(screen.getByTestId('category-group-demos')).toBeInTheDocument()

    // Flag cards
    expect(screen.getByTestId('flag-card-page_discovery')).toBeInTheDocument()
    expect(screen.getByTestId('flag-status-pill-page_discovery')).toHaveTextContent('Enabled')

    expect(screen.getByTestId('flag-card-demos_fleet')).toBeInTheDocument()
    expect(screen.getByTestId('flag-status-pill-demos_fleet')).toHaveTextContent('Disabled')
  })

  it('filters feature flags using search input', async () => {
    await renderFeaturesPage()

    const searchInput = screen.getByTestId('feature-search-input')
    fireEvent.change(searchInput, { target: { value: 'discovery' } })

    expect(screen.getByTestId('flag-card-page_discovery')).toBeInTheDocument()
    expect(screen.queryByTestId('flag-card-demos_fleet')).not.toBeInTheDocument()
  })

  it('filters feature flags using category dropdown', async () => {
    await renderFeaturesPage()

    const categorySelect = screen.getByTestId('filter-category-select')
    fireEvent.change(categorySelect, { target: { value: 'demos' } })

    expect(screen.queryByTestId('category-group-operational')).not.toBeInTheDocument()
    expect(screen.getByTestId('category-group-demos')).toBeInTheDocument()
  })

  it('filters feature flags using status dropdown', async () => {
    await renderFeaturesPage()

    const statusSelect = screen.getByTestId('filter-status-select')
    fireEvent.change(statusSelect, { target: { value: 'disabled' } })

    // Disabled flag should be visible
    expect(screen.getByTestId('flag-card-demos_fleet')).toBeInTheDocument()
    // Enabled flag should not be visible
    expect(screen.queryByTestId('flag-card-page_discovery')).not.toBeInTheDocument()
  })

  it('handles clicking toggle switch to enable/disable an individual flag', async () => {
    await renderFeaturesPage({ defaultTenant: 'kusari' })

    const toggle = screen.getByTestId('flag-toggle-demos_fleet')
    expect(toggle).toHaveAttribute('aria-checked', 'false')

    await act(async () => {
      fireEvent.click(toggle)
    })

    expect(mutateSingleAsyncMock).toHaveBeenCalledWith({
      tenantId: 'kusari',
      flagKey: 'demos_fleet',
      payload: { enabled: true },
    })

    await waitFor(() => {
      const toast = screen.getByTestId('success-toast')
      expect(toast).toHaveTextContent(/Flag "demos_fleet" set to ENABLED/i)
    })
  })

  it('displays action error banner when mutation fails', async () => {
    mutateSingleAsyncMock.mockRejectedValueOnce(new Error('Permission denied: superadmin required'))
    await renderFeaturesPage({ defaultTenant: 'kusari' })

    const toggle = screen.getByTestId('flag-toggle-demos_fleet')
    await act(async () => {
      fireEvent.click(toggle)
    })

    await waitFor(() => {
      const errorBanner = screen.getByTestId('action-error-banner')
      expect(errorBanner).toHaveTextContent(/Permission denied: superadmin required/i)
    })
  })

  it('renders loading state when query is loading', async () => {
    mockUseAdminFeatures.mockReturnValue({
      data: null,
      isLoading: true,
      isFetching: true,
      isError: false,
      error: null,
      refetch: refetchMock,
    })

    await renderFeaturesPage()
    expect(screen.getByText(/Loading feature flags/i)).toBeInTheDocument()
  })

  it('renders error state when query fails and triggers retry', async () => {
    mockUseAdminFeatures.mockReturnValue({
      data: null,
      isLoading: false,
      isFetching: false,
      isError: true,
      error: new Error('Failed to connect to backend service'),
      refetch: refetchMock,
    })

    await renderFeaturesPage()
    expect(screen.getByText('Failed to load')).toBeInTheDocument()
    expect(screen.getByText('Failed to connect to backend service')).toBeInTheDocument()

    const retryBtn = screen.getByRole('button', { name: /Retry/i })
    fireEvent.click(retryBtn)
    expect(refetchMock).toHaveBeenCalled()
  })

  it('resolves primary account scope and organization name from settings', async () => {
    vi.mocked(api.settings).mockResolvedValueOnce({
      tenant_id: 'tenant-primary',
      org_name: 'Primary Enterprise Corp',
      plan_tier: 'enterprise',
      agent_count: 8,
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

    await renderFeaturesPage()

    await waitFor(() => {
      const select = screen.getByTestId('admin-tenant-select') as HTMLSelectElement
      expect(select.value).toBe('tenant-primary')
      expect(screen.getByText('Primary Enterprise Corp (tenant-primary)')).toBeInTheDocument()
      expect(screen.getByTestId('kpi-account-scope')).toHaveTextContent('tenant-primary')
      expect(screen.getByTestId('kpi-account-scope')).toHaveTextContent('Primary Enterprise Corp')
    })
  })
})
