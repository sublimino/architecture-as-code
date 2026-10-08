import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor, within, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import UsersPage from './UsersPage'
import * as usersApiModule from '../../api/usersApi'
import type { PlatformUser, UsersListResponse } from '../../api/usersApi'
import { AppContext } from '../../App'

// Mocks
const mockGetAccessTokenSilently = vi.fn().mockResolvedValue('test-bearer-token')
const mockAuthUser = {
  email: 'admin@acme.com',
  name: 'Admin User',
}

vi.mock('../../auth/oidc', () => ({
  useAuth0: () => ({
    user: mockAuthUser,
    getAccessTokenSilently: mockGetAccessTokenSilently,
  }),
}))

const mockServerSuperadmin = { superadmin: false, resolved: true }
vi.mock('../../auth/superadmin', () => ({
  useServerSuperadmin: () => mockServerSuperadmin,
}))

const MOCK_USERS_DATA: PlatformUser[] = [
  {
    id: 'usr-1',
    tenant_id: 'tenant-acme',
    email: 'admin@acme.com',
    display_name: 'Acme Admin',
    role: 'admin',
    status: 'active',
    is_superadmin: true,
    title: 'Security Lead',
    created_at: '2026-01-01T00:00:00Z',
  },
  {
    id: 'usr-2',
    tenant_id: 'tenant-acme',
    email: 'dev@acme.com',
    display_name: 'Acme Developer',
    role: 'editor',
    status: 'active',
    is_superadmin: false,
    title: 'Core Dev',
    created_at: '2026-02-01T00:00:00Z',
  },
  {
    id: 'usr-3',
    tenant_id: 'tenant-kusari',
    email: 'auditor@kusari.com',
    display_name: 'Kusari Auditor',
    role: 'viewer',
    status: 'suspended',
    is_superadmin: false,
    title: 'External Auditor',
    created_at: '2026-03-01T00:00:00Z',
  },
]

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

async function renderUsersPage(
  props: Partial<React.ComponentProps<typeof UsersPage>> = {},
  ctxOverrides: Partial<typeof appCtxDefault> = {},
) {
  let result: any
  await act(async () => {
    result = render(
      <AppContext.Provider value={{ ...appCtxDefault, ...ctxOverrides }}>
        <UsersPage {...props} />
      </AppContext.Provider>,
    )
    await Promise.resolve()
  })
  return result
}

describe('UsersPage Component', () => {
  let mockUseUsers: ReturnType<typeof vi.fn>
  let mockUseUpdateUser: ReturnType<typeof vi.fn>
  let mockUseDeactivateUser: ReturnType<typeof vi.fn>
  let mutateUpdateAsyncMock: ReturnType<typeof vi.fn>
  let mutateDeactivateAsyncMock: ReturnType<typeof vi.fn>
  let refetchMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    vi.clearAllMocks()
    mockServerSuperadmin.superadmin = false

    refetchMock = vi.fn().mockResolvedValue({} as any)
    mutateUpdateAsyncMock = vi.fn().mockImplementation(async (vars) => {
      const target = MOCK_USERS_DATA.find((u) => u.id === vars.userId) || MOCK_USERS_DATA[0]
      return { ...target, ...vars.payload }
    })
    mutateDeactivateAsyncMock = vi.fn().mockImplementation(async (userId) => {
      const target = MOCK_USERS_DATA.find((u) => u.id === userId) || MOCK_USERS_DATA[1]
      return { ...target, status: 'deactivated' as const }
    })

    mockUseUsers = vi.fn().mockReturnValue({
      data: { users: MOCK_USERS_DATA, total: MOCK_USERS_DATA.length } as UsersListResponse,
      isLoading: false,
      isError: false,
      error: null,
      refetch: refetchMock,
    })

    mockUseUpdateUser = vi.fn().mockImplementation((options) => ({
      mutateAsync: async (vars: any) => {
        try {
          const res = await mutateUpdateAsyncMock(vars)
          options?.onSuccess?.(res, vars)
          return res
        } catch (err) {
          options?.onError?.(err, vars)
          throw err
        }
      },
      isLoading: false,
    }))

    mockUseDeactivateUser = vi.fn().mockImplementation((options) => ({
      mutateAsync: async (vars: any) => {
        try {
          const res = await mutateDeactivateAsyncMock(vars)
          options?.onSuccess?.(res, vars)
          return res
        } catch (err) {
          options?.onError?.(err, vars)
          throw err
        }
      },
      isLoading: false,
    }))

    vi.spyOn(usersApiModule, 'useUsers').mockImplementation(mockUseUsers as any)
    vi.spyOn(usersApiModule, 'useUpdateUser').mockImplementation(mockUseUpdateUser as any)
    vi.spyOn(usersApiModule, 'useDeactivateUser').mockImplementation(mockUseDeactivateUser as any)
  })

  it('renders page header, breadcrumbs, title, and descriptive summary', async () => {
    await renderUsersPage()

    expect(screen.getByRole('navigation', { name: /breadcrumb/i })).toBeInTheDocument()
    expect(screen.getByRole('heading', { level: 1, name: 'User Administration' })).toBeInTheDocument()
    expect(
      screen.getByText(/Manage platform users, roles, tenant assignments/i),
    ).toBeInTheDocument()
  })

  it('renders primary "Invite User" action button and handles click', async () => {
    const onInviteMock = vi.fn()
    await renderUsersPage({ onInviteUser: onInviteMock })

    const inviteBtn = screen.getByTestId('invite-user-btn')
    expect(inviteBtn).toBeInTheDocument()
    expect(inviteBtn).toHaveTextContent('Invite User')

    fireEvent.click(inviteBtn)
    expect(onInviteMock).toHaveBeenCalledTimes(1)
  })

  it('renders KPI summary cards with computed metrics', async () => {
    await renderUsersPage()

    expect(within(screen.getByTestId('kpi-total-users')).getByText('3')).toBeInTheDocument()
    expect(within(screen.getByTestId('kpi-active-users')).getByText('2')).toBeInTheDocument()
    expect(within(screen.getByTestId('kpi-suspended-users')).getByText('1')).toBeInTheDocument()
    expect(within(screen.getByTestId('kpi-admin-users')).getByText('1')).toBeInTheDocument()
  })

  it('renders search input and passes debounced query parameter', async () => {
    await renderUsersPage()

    const searchInput = screen.getByTestId('user-search-input')
    expect(searchInput).toBeInTheDocument()

    await userEvent.type(searchInput, 'Auditor')
    expect(searchInput).toHaveValue('Auditor')

    // Search query passed to useUsers hook
    expect(mockUseUsers).toHaveBeenCalledWith(
      expect.objectContaining({ search: 'Auditor' }),
      expect.toBeOneOf ? expect.toBeOneOf([null, undefined, expect.any(String)]) : null,
      expect.any(Object),
    )

    // Clear search button appears
    const clearBtn = screen.getByTestId('clear-search-btn')
    fireEvent.click(clearBtn)
    expect(searchInput).toHaveValue('')
  })

  describe('tenant_filter access control', () => {
    it('hides tenant filter dropdown when user is NOT superadmin', async () => {
      mockServerSuperadmin.superadmin = false
      await renderUsersPage({}, { superadmin: false })

      // Tenant dropdown must NOT be in the document
      expect(screen.queryByTestId('tenant-filter-select')).not.toBeInTheDocument()
      expect(screen.queryByTestId('tenant-filter-wrapper')).not.toBeInTheDocument()
      expect(screen.queryByTestId('superadmin-scope-pill')).not.toBeInTheDocument()
    })

    it('renders tenant filter dropdown when user IS superadmin', async () => {
      mockServerSuperadmin.superadmin = true
      await renderUsersPage({}, { superadmin: true })

      // Tenant dropdown MUST be visible
      const tenantSelect = screen.getByTestId('tenant-filter-select')
      expect(tenantSelect).toBeInTheDocument()
      expect(screen.getByTestId('superadmin-scope-pill')).toBeInTheDocument()

      // Should populate discovered tenant options
      expect(within(tenantSelect).getByText('All Tenants')).toBeInTheDocument()
      expect(within(tenantSelect).getByText('tenant-acme')).toBeInTheDocument()
      expect(within(tenantSelect).getByText('tenant-kusari')).toBeInTheDocument()

      // Selecting tenant triggers query with tenant_id
      fireEvent.change(tenantSelect, { target: { value: 'tenant-kusari' } })
      expect(mockUseUsers).toHaveBeenCalledWith(
        expect.objectContaining({ tenant_id: 'tenant-kusari' }),
        expect.toBeOneOf ? expect.toBeOneOf([null, undefined, expect.any(String)]) : null,
        expect.any(Object),
      )
    })
  })

  it('renders role and status filter dropdowns and applies selections', async () => {
    await renderUsersPage()

    const roleSelect = screen.getByTestId('role-filter-select')
    const statusSelect = screen.getByTestId('status-filter-select')

    fireEvent.change(roleSelect, { target: { value: 'admin' } })
    expect(mockUseUsers).toHaveBeenCalledWith(
      expect.objectContaining({ role: 'admin' }),
      expect.toBeOneOf ? expect.toBeOneOf([null, undefined, expect.any(String)]) : null,
      expect.any(Object),
    )

    fireEvent.change(statusSelect, { target: { value: 'suspended' } })
    expect(mockUseUsers).toHaveBeenCalledWith(
      expect.objectContaining({ status: 'suspended' }),
      expect.toBeOneOf ? expect.toBeOneOf([null, undefined, expect.any(String)]) : null,
      expect.any(Object),
    )

    // Clear Filters button appears and resets all
    const clearFiltersBtn = screen.getByTestId('clear-filters-btn')
    expect(clearFiltersBtn).toBeInTheDocument()
    fireEvent.click(clearFiltersBtn)

    expect(roleSelect).toHaveValue('all')
    expect(statusSelect).toHaveValue('all')
  })

  it('renders loading state when users query is in flight', async () => {
    mockUseUsers.mockReturnValue({
      data: undefined,
      isLoading: true,
      isError: false,
      error: null,
      refetch: refetchMock,
    })

    await renderUsersPage()
    expect(screen.getAllByTestId('user-table-skeleton-row').length).toBe(5)
  })

  it('renders error state and handles refetch retry when query fails', async () => {
    mockUseUsers.mockReturnValue({
      data: undefined,
      isLoading: false,
      isError: true,
      error: new Error('Network timeout loading users'),
      refetch: refetchMock,
    })

    await renderUsersPage()
    expect(screen.getByText('Network timeout loading users')).toBeInTheDocument()

    const retryBtn = screen.getByRole('button', { name: /retry/i })
    fireEvent.click(retryBtn)
    expect(refetchMock).toHaveBeenCalledTimes(1)
  })

  it('displays success toast when user mutation succeeds', async () => {
    await renderUsersPage()

    // Suspend usr-2 (Acme Developer)
    const toggleBtn = screen.getByTestId('toggle-status-btn-usr-2')
    fireEvent.click(toggleBtn)

    const dialog = screen.getByRole('dialog')
    const confirmBtn = within(dialog).getByRole('button', { name: /suspend user/i })
    await userEvent.click(confirmBtn)

    await waitFor(() => {
      expect(screen.getByTestId('success-toast')).toBeInTheDocument()
      expect(
        screen.getByText(/User "Acme Developer" updated successfully/),
      ).toBeInTheDocument()
    })
  })

  it('displays action error banner when user mutation fails', async () => {
    mutateUpdateAsyncMock.mockRejectedValueOnce(
      new usersApiModule.UsersApiError('Permission denied: cannot suspend superadmin', 403),
    )

    await renderUsersPage()

    // Attempt to suspend usr-2
    const toggleBtn = screen.getByTestId('toggle-status-btn-usr-2')
    fireEvent.click(toggleBtn)

    const dialog = screen.getByRole('dialog')
    const confirmBtn = within(dialog).getByRole('button', { name: /suspend user/i })
    await userEvent.click(confirmBtn)

    await waitFor(() => {
      expect(screen.getByTestId('action-error-banner')).toBeInTheDocument()
      expect(
        screen.getByText('Permission denied: cannot suspend superadmin'),
      ).toBeInTheDocument()
    })

    // Dismiss error banner
    const dismissBtn = screen.getByRole('button', { name: /dismiss error/i })
    fireEvent.click(dismissBtn)
    expect(screen.queryByTestId('action-error-banner')).not.toBeInTheDocument()
  })

  it('opens InviteUserModal when Invite User button is clicked without onInviteUser prop', async () => {
    let mockUseInviteUser = vi.fn().mockImplementation((options) => ({
      mutateAsync: async (vars: any) => {
        const payload = vars.payload || vars
        const res = { ...MOCK_USERS_DATA[0], ...payload, id: 'usr-new-invited' }
        options?.onSuccess?.(res, vars)
        return res
      },
      isPending: false,
    }))
    vi.spyOn(usersApiModule, 'useInviteUser').mockImplementation(mockUseInviteUser as any)

    await renderUsersPage()

    const inviteBtn = screen.getByTestId('invite-user-btn')
    fireEvent.click(inviteBtn)

    expect(screen.getByTestId('invite-user-modal')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Invite Platform Operator' })).toBeInTheDocument()

    // Fill email and submit
    const emailInput = screen.getByTestId('invite-email-input')
    await userEvent.type(emailInput, 'operator.new@acme.com')

    const submitBtn = screen.getByTestId('invite-submit-btn')
    await userEvent.click(submitBtn)

    await waitFor(() => {
      expect(screen.queryByTestId('invite-user-modal')).not.toBeInTheDocument()
      expect(screen.getByTestId('success-toast')).toHaveTextContent(
        'Invitation dispatched to operator.new@acme.com',
      )
    })
  })

  it('opens EditUserModal when Edit button is clicked without onEditUser prop', async () => {
    await renderUsersPage()

    const editBtn = screen.getByTestId('edit-user-btn-usr-1')
    fireEvent.click(editBtn)

    expect(screen.getByTestId('edit-user-modal')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Edit Operator Profile' })).toBeInTheDocument()
    expect(screen.getByTestId('edit-email-display')).toHaveTextContent('admin@acme.com')

    // Close edit modal
    const closeBtn = screen.getByTestId('edit-close-btn')
    fireEvent.click(closeBtn)

    expect(screen.queryByTestId('edit-user-modal')).not.toBeInTheDocument()
  })
})

