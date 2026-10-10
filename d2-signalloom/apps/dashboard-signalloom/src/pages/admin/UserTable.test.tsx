import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import UserTable, { RoleBadge, StatusIndicator } from './UserTable'
import type { PlatformUser } from '../../api/usersApi'

const MOCK_USERS: PlatformUser[] = [
  {
    id: 'usr-1',
    tenant_id: 'tenant-acme',
    email: 'alice@acme.com',
    display_name: 'Alice Admin',
    role: 'admin',
    status: 'active',
    is_superadmin: true,
    title: 'Lead Security Architect',
    created_at: '2026-01-15T10:00:00Z',
  },
  {
    id: 'usr-2',
    tenant_id: 'tenant-acme',
    email: 'bob@acme.com',
    display_name: 'Bob Editor',
    role: 'editor',
    status: 'suspended',
    is_superadmin: false,
    title: 'Platform Engineer',
    created_at: '2026-02-20T11:30:00Z',
  },
  {
    id: 'usr-3',
    tenant_id: 'tenant-kusari',
    email: 'charlie@kusari.com',
    display_name: 'Charlie Viewer',
    role: 'viewer',
    status: 'invited',
    is_superadmin: false,
    title: 'Security Auditor',
    created_at: '2026-03-01T09:15:00Z',
  },
]

describe('UserTable Component', () => {
  const onStatusChangeMock = vi.fn()
  const onEditUserMock = vi.fn()
  const onDeactivateUserMock = vi.fn()

  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('renders semantic table structure with headers and rows', () => {
    render(
      <UserTable
        users={MOCK_USERS}
        onStatusChange={onStatusChangeMock}
        onEditUser={onEditUserMock}
        onDeactivateUser={onDeactivateUserMock}
      />,
    )

    // Semantic HTML table checks
    const table = screen.getByRole('table')
    expect(table).toBeInTheDocument()

    const colHeaders = screen.getAllByRole('columnheader')
    expect(colHeaders.length).toBe(7)
    expect(screen.getByText('User')).toBeInTheDocument()
    expect(screen.getByText('Email')).toBeInTheDocument()
    expect(screen.getByText('Tenant')).toBeInTheDocument()
    expect(screen.getByText('Role')).toBeInTheDocument()
    expect(screen.getByText('Status')).toBeInTheDocument()
    expect(screen.getByText('Created')).toBeInTheDocument()
    expect(screen.getByText('Actions')).toBeInTheDocument()

    // Table rows
    expect(screen.getByTestId('user-row-usr-1')).toBeInTheDocument()
    expect(screen.getByTestId('user-row-usr-2')).toBeInTheDocument()
    expect(screen.getByTestId('user-row-usr-3')).toBeInTheDocument()
  })

  it('renders user details, email, tenant, and formatted created date', () => {
    render(<UserTable users={MOCK_USERS} />)

    // Names and emails
    expect(screen.getByText('Alice Admin')).toBeInTheDocument()
    expect(screen.getByText('alice@acme.com')).toBeInTheDocument()
    expect(screen.getByText('Lead Security Architect')).toBeInTheDocument()
    expect(screen.getByText('Bob Editor')).toBeInTheDocument()
    expect(screen.getByText('bob@acme.com')).toBeInTheDocument()

    // Tenants
    expect(screen.getAllByText('tenant-acme').length).toBe(2)
    expect(screen.getByText('tenant-kusari')).toBeInTheDocument()

    // Formatted Dates
    expect(screen.getByText('2026-01-15')).toBeInTheDocument()
    expect(screen.getByText('2026-02-20')).toBeInTheDocument()
    expect(screen.getByText('2026-03-01')).toBeInTheDocument()
  })

  it('renders distinct semantic role badges and superadmin indicators', () => {
    render(<UserTable users={MOCK_USERS} />)

    // Admin badge
    const adminBadge = screen.getByTestId('role-badge-admin')
    expect(adminBadge).toBeInTheDocument()
    expect(adminBadge).toHaveTextContent('Admin')

    // Superadmin star badge
    const superadminBadge = screen.getByTestId('superadmin-badge')
    expect(superadminBadge).toBeInTheDocument()
    expect(superadminBadge).toHaveTextContent('★ Superadmin')

    // Editor badge
    const editorBadge = screen.getByTestId('role-badge-editor')
    expect(editorBadge).toBeInTheDocument()
    expect(editorBadge).toHaveTextContent('Editor')

    // Viewer badge
    const viewerBadge = screen.getByTestId('role-badge-viewer')
    expect(viewerBadge).toBeInTheDocument()
    expect(viewerBadge).toHaveTextContent('Viewer')
  })

  it('renders distinct status badges with semantic indicators', () => {
    render(<UserTable users={MOCK_USERS} />)

    // Active
    const activeBadge = screen.getByTestId('status-badge-active')
    expect(activeBadge).toBeInTheDocument()
    expect(activeBadge).toHaveTextContent('Active')
    expect(screen.getByTestId('status-dot-active')).toBeInTheDocument()

    // Suspended
    const suspendedBadge = screen.getByTestId('status-badge-suspended')
    expect(suspendedBadge).toBeInTheDocument()
    expect(suspendedBadge).toHaveTextContent('Suspended')
    expect(screen.getByTestId('status-dot-suspended')).toBeInTheDocument()

    // Invited
    const invitedBadge = screen.getByTestId('status-badge-invited')
    expect(invitedBadge).toBeInTheDocument()
    expect(invitedBadge).toHaveTextContent('Invited')
    expect(screen.getByTestId('status-dot-invited')).toBeInTheDocument()
  })

  it('opens confirmation dialog when attempting to suspend an active user', async () => {
    render(
      <UserTable
        users={MOCK_USERS}
        onStatusChange={onStatusChangeMock}
      />,
    )

    // Click Suspend button for Alice Admin (active)
    const suspendBtn = screen.getByTestId('toggle-status-btn-usr-1')
    expect(suspendBtn).toHaveTextContent('Suspend')
    fireEvent.click(suspendBtn)

    // Confirmation dialog should appear
    expect(screen.getByRole('dialog')).toBeInTheDocument()
    expect(screen.getByText('Confirm User Suspension')).toBeInTheDocument()
    expect(
      screen.getByText(/Are you sure you want to suspend "Alice Admin"/),
    ).toBeInTheDocument()

    // Cancel suspension
    const cancelBtn = screen.getByRole('button', { name: /cancel/i })
    fireEvent.click(cancelBtn)
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(onStatusChangeMock).not.toHaveBeenCalled()

    // Click Suspend again and confirm
    fireEvent.click(suspendBtn)
    const dialog = screen.getByRole('dialog')
    const confirmBtn = within(dialog).getByRole('button', { name: /suspend user/i })
    await userEvent.click(confirmBtn)

    expect(onStatusChangeMock).toHaveBeenCalledTimes(1)
    expect(onStatusChangeMock).toHaveBeenCalledWith(MOCK_USERS[0], 'suspended')
  })

  it('activates suspended user directly when toggle button is clicked', async () => {
    render(
      <UserTable
        users={MOCK_USERS}
        onStatusChange={onStatusChangeMock}
      />,
    )

    // Bob Editor is suspended
    const activateBtn = screen.getByTestId('toggle-status-btn-usr-2')
    expect(activateBtn).toHaveTextContent('Activate')
    await userEvent.click(activateBtn)

    // Does not require suspension modal
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(onStatusChangeMock).toHaveBeenCalledTimes(1)
    expect(onStatusChangeMock).toHaveBeenCalledWith(MOCK_USERS[1], 'active')
  })

  it('disables self-suspension for current logged-in user', () => {
    render(
      <UserTable
        users={MOCK_USERS}
        currentUserEmail="alice@acme.com"
        onStatusChange={onStatusChangeMock}
      />,
    )

    const aliceToggleBtn = screen.getByTestId('toggle-status-btn-usr-1')
    expect(aliceToggleBtn).toBeDisabled()
    expect(aliceToggleBtn).toHaveAttribute(
      'title',
      'You cannot suspend your own active account',
    )

    // Other user buttons remain enabled
    const bobToggleBtn = screen.getByTestId('toggle-status-btn-usr-2')
    expect(bobToggleBtn).not.toBeDisabled()
  })

  it('invokes onEditUser when Edit button is clicked', () => {
    render(
      <UserTable
        users={MOCK_USERS}
        onEditUser={onEditUserMock}
      />,
    )

    const editBtn = screen.getByTestId('edit-user-btn-usr-1')
    fireEvent.click(editBtn)
    expect(onEditUserMock).toHaveBeenCalledTimes(1)
    expect(onEditUserMock).toHaveBeenCalledWith(MOCK_USERS[0])
  })

  it('invokes onDeactivateUser when Delete button is clicked', () => {
    render(
      <UserTable
        users={MOCK_USERS}
        onDeactivateUser={onDeactivateUserMock}
      />,
    )

    const deleteBtn = screen.getByTestId('deactivate-user-btn-usr-2')
    fireEvent.click(deleteBtn)
    expect(onDeactivateUserMock).toHaveBeenCalledTimes(1)
    expect(onDeactivateUserMock).toHaveBeenCalledWith(MOCK_USERS[1])
  })

  it('supports sorting by column headers (name, email, role, status)', () => {
    render(<UserTable users={MOCK_USERS} />)

    const nameHeader = screen.getByText('User')
    fireEvent.click(nameHeader) // Sort asc by name

    let rows = screen.getAllByTestId(/^user-row-/)
    expect(rows[0]).toHaveAttribute('data-testid', 'user-row-usr-1') // Alice Admin
    expect(rows[1]).toHaveAttribute('data-testid', 'user-row-usr-2') // Bob Editor
    expect(rows[2]).toHaveAttribute('data-testid', 'user-row-usr-3') // Charlie Viewer

    fireEvent.click(nameHeader) // Sort desc by name
    rows = screen.getAllByTestId(/^user-row-/)
    expect(rows[0]).toHaveAttribute('data-testid', 'user-row-usr-3') // Charlie Viewer
    expect(rows[1]).toHaveAttribute('data-testid', 'user-row-usr-2') // Bob Editor
    expect(rows[2]).toHaveAttribute('data-testid', 'user-row-usr-1') // Alice Admin
  })

  it('supports pagination controls with page size selection', () => {
    const manyUsers: PlatformUser[] = Array.from({ length: 25 }, (_, i) => ({
      id: `usr-${i + 1}`,
      tenant_id: `tenant-${i % 2 === 0 ? 'acme' : 'kusari'}`,
      email: `user${i + 1}@example.com`,
      display_name: `User ${i + 1}`,
      role: (i % 3 === 0 ? 'admin' : i % 3 === 1 ? 'editor' : 'viewer') as any,
      status: (i % 2 === 0 ? 'active' : 'suspended') as any,
      is_superadmin: i === 0,
      created_at: new Date(Date.now() - i * 86400000).toISOString(),
    }))

    render(<UserTable users={manyUsers} pageSize={10} />)

    // Initial page shows 10 items
    expect(screen.getByTestId('pagination-page-indicator')).toHaveTextContent('Page 1 of 3')
    expect(screen.getAllByTestId(/^user-row-/).length).toBe(10)

    // Next page
    const nextBtn = screen.getByTestId('pagination-next-btn')
    fireEvent.click(nextBtn)
    expect(screen.getByTestId('pagination-page-indicator')).toHaveTextContent('Page 2 of 3')
    expect(screen.getAllByTestId(/^user-row-/).length).toBe(10)

    // Previous page
    const prevBtn = screen.getByTestId('pagination-prev-btn')
    fireEvent.click(prevBtn)
    expect(screen.getByTestId('pagination-page-indicator')).toHaveTextContent('Page 1 of 3')

    // Change page size to 25
    const pageSizeSelect = screen.getByTestId('page-size-select')
    fireEvent.change(pageSizeSelect, { target: { value: '25' } })
    expect(screen.getByTestId('pagination-page-indicator')).toHaveTextContent('Page 1 of 1')
    expect(screen.getAllByTestId(/^user-row-/).length).toBe(25)
  })

  it('renders loading skeleton rows when isLoading is true', () => {
    render(<UserTable users={[]} isLoading={true} />)
    const skeletons = screen.getAllByTestId('user-table-skeleton-row')
    expect(skeletons.length).toBe(5)
  })

  it('renders empty state when users array is empty and not loading', () => {
    render(<UserTable users={[]} isLoading={false} />)
    expect(screen.getByText('No users found')).toBeInTheDocument()
  })

  it('passes accessibility checks for table semantics and button aria-labels', () => {
    render(<UserTable users={MOCK_USERS} />)

    const table = screen.getByRole('table')
    expect(table).toHaveAccessibleName('Directory Platform Users')

    const headers = screen.getAllByRole('columnheader')
    headers.forEach((h) => expect(h).toHaveAttribute('scope', 'col'))

    expect(
      screen.getByRole('button', { name: /suspend user alice admin/i }),
    ).toBeInTheDocument()
    expect(
      screen.getByRole('button', { name: /activate user bob editor/i }),
    ).toBeInTheDocument()
  })
})
