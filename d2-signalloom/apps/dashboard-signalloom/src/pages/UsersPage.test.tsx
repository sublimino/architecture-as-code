// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, screen, fireEvent, within } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import UsersPage from './UsersPage'
import { DEFAULT_USERS } from '../data/defaultUsers'

describe('UsersPage', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
  })

  it('renders the header title, subtitle, and CSV export button', () => {
    render(
      <MemoryRouter initialEntries={['/users']}>
        <Routes>
          <Route path="/users" element={<UsersPage />} />
        </Routes>
      </MemoryRouter>
    )

    expect(screen.getByRole('heading', { level: 1, name: /Users & Access Control/i })).toBeInTheDocument()
    expect(screen.getByText(/Enterprise human identity anchoring for autonomous agent claims/i)).toBeInTheDocument()
    expect(screen.getByTestId('export-users-csv')).toBeInTheDocument()
  })

  it('renders top summary StatCards with full dataset counts', () => {
    render(
      <MemoryRouter initialEntries={['/users']}>
        <Routes>
          <Route path="/users" element={<UsersPage />} />
        </Routes>
      </MemoryRouter>
    )

    const totalIdentities = screen.getByTestId('stat-total-identities')
    const observeAccess = screen.getByTestId('stat-observe-access')
    const governAnchors = screen.getByTestId('stat-govern-anchors')
    const attestOfficers = screen.getByTestId('stat-attest-officers')

    expect(totalIdentities).toHaveTextContent(String(DEFAULT_USERS.length))

    const expectedObserve = DEFAULT_USERS.filter((u) => u.platform_level.includes('observe')).length
    const expectedGovern = DEFAULT_USERS.filter((u) => u.platform_level.includes('govern') || u.can_claim_agents).length
    const expectedAttest = DEFAULT_USERS.filter((u) => u.platform_level.includes('attest') || u.can_sign_attestations).length

    expect(observeAccess).toHaveTextContent(String(expectedObserve))
    expect(governAnchors).toHaveTextContent(String(expectedGovern))
    expect(attestOfficers).toHaveTextContent(String(expectedAttest))
  })

  it('renders the Super Data Table with default seeded enterprise identities', () => {
    render(
      <MemoryRouter initialEntries={['/users']}>
        <Routes>
          <Route path="/users" element={<UsersPage />} />
        </Routes>
      </MemoryRouter>
    )

    expect(screen.getByText('Andy M.')).toBeInTheDocument()
    expect(screen.getByText('andy@signalloom.demo')).toBeInTheDocument()

    expect(screen.getByText('Sarah Chen')).toBeInTheDocument()
    expect(screen.getByText('sarah.chen@secops.internal')).toBeInTheDocument()

    expect(screen.getByText('Marcus Vance')).toBeInTheDocument()
    expect(screen.getByText('Elena Rostova')).toBeInTheDocument()
    expect(screen.getByText('DevOps Service')).toBeInTheDocument()
    expect(screen.getByText('Alex Rivera')).toBeInTheDocument()
    expect(screen.getByText('Trust Log Notary')).toBeInTheDocument()
  })

  it('filters the users list by search query across name, email, and department', () => {
    render(
      <MemoryRouter initialEntries={['/users']}>
        <Routes>
          <Route path="/users" element={<UsersPage />} />
        </Routes>
      </MemoryRouter>
    )

    const searchInput = screen.getByTestId('users-search')

    // Search by display name
    fireEvent.change(searchInput, { target: { value: 'Andy' } })
    expect(screen.getByText('Andy M.')).toBeInTheDocument()
    expect(screen.queryByText('Sarah Chen')).not.toBeInTheDocument()
    expect(screen.queryByText('Marcus Vance')).not.toBeInTheDocument()

    // Search by email
    fireEvent.change(searchInput, { target: { value: 'secops.internal' } })
    expect(screen.getByText('Sarah Chen')).toBeInTheDocument()
    expect(screen.queryByText('Andy M.')).not.toBeInTheDocument()

    // Search by department
    fireEvent.change(searchInput, { target: { value: 'Compliance & Governance' } })
    expect(screen.getByText('Elena Rostova')).toBeInTheDocument()
    expect(screen.queryByText('Andy M.')).not.toBeInTheDocument()

    // Clear search
    fireEvent.change(searchInput, { target: { value: '' } })
    expect(screen.getByText('Andy M.')).toBeInTheDocument()
    expect(screen.getByText('Sarah Chen')).toBeInTheDocument()
  })

  it('filters by platform level (Observe / Govern / Attest)', () => {
    render(
      <MemoryRouter initialEntries={['/users']}>
        <Routes>
          <Route path="/users" element={<UsersPage />} />
        </Routes>
      </MemoryRouter>
    )

    // Filter by Govern
    const governBtn = screen.getByTestId('filter-level-govern')
    fireEvent.click(governBtn)
    expect(governBtn).toHaveAttribute('aria-pressed', 'true')

    // Users with Govern level should be present
    expect(screen.getByText('Andy M.')).toBeInTheDocument()
    expect(screen.getByText('Marcus Vance')).toBeInTheDocument()
    expect(screen.getByText('DevOps Service')).toBeInTheDocument()
    // Alex Rivera has only Observe level, Trust Log Notary has only Attest
    expect(screen.queryByText('Alex Rivera')).not.toBeInTheDocument()
    expect(screen.queryByText('Trust Log Notary')).not.toBeInTheDocument()

    // Filter by Attest
    const attestBtn = screen.getByTestId('filter-level-attest')
    fireEvent.click(attestBtn)
    expect(screen.getByText('Andy M.')).toBeInTheDocument()
    expect(screen.getByText('Sarah Chen')).toBeInTheDocument()
    expect(screen.getByText('Elena Rostova')).toBeInTheDocument()
    expect(screen.getByText('Trust Log Notary')).toBeInTheDocument()
    expect(screen.queryByText('Marcus Vance')).not.toBeInTheDocument()
    expect(screen.queryByText('Alex Rivera')).not.toBeInTheDocument()

    // Reset to All
    const allBtn = screen.getByTestId('filter-level-all')
    fireEvent.click(allBtn)
    expect(screen.getByText('Alex Rivera')).toBeInTheDocument()
    expect(screen.getByText('Marcus Vance')).toBeInTheDocument()
  })

  it('filters by auth tag (2FA Active, SSO Ready, user/pass, Service Key)', () => {
    render(
      <MemoryRouter initialEntries={['/users']}>
        <Routes>
          <Route path="/users" element={<UsersPage />} />
        </Routes>
      </MemoryRouter>
    )

    // Filter by 2FA Active
    const twoFaBtn = screen.getByTestId('filter-tag-2fa-active')
    fireEvent.click(twoFaBtn)
    expect(screen.getByText('Andy M.')).toBeInTheDocument()
    expect(screen.getByText('Sarah Chen')).toBeInTheDocument()
    expect(screen.getByText('Marcus Vance')).toBeInTheDocument()
    // DevOps Service only has 'Service Key', Alex Rivera only has 'user/pass'
    expect(screen.queryByText('DevOps Service')).not.toBeInTheDocument()
    expect(screen.queryByText('Alex Rivera')).not.toBeInTheDocument()

    // Filter by SSO Ready
    const ssoBtn = screen.getByTestId('filter-tag-sso-ready')
    fireEvent.click(ssoBtn)
    expect(screen.getByText('Andy M.')).toBeInTheDocument()
    expect(screen.getByText('Elena Rostova')).toBeInTheDocument()
    expect(screen.queryByText('Sarah Chen')).not.toBeInTheDocument()
    expect(screen.queryByText('Marcus Vance')).not.toBeInTheDocument()

    // Filter by user/pass
    const userPassBtn = screen.getByTestId('filter-tag-user-pass')
    fireEvent.click(userPassBtn)
    expect(screen.getByText('Alex Rivera')).toBeInTheDocument()
    expect(screen.getByText('Andy M.')).toBeInTheDocument()
    expect(screen.queryByText('DevOps Service')).not.toBeInTheDocument()
    expect(screen.queryByText('Trust Log Notary')).not.toBeInTheDocument()
  })

  it('filters by role and status facets', () => {
    render(
      <MemoryRouter initialEntries={['/users']}>
        <Routes>
          <Route path="/users" element={<UsersPage />} />
        </Routes>
      </MemoryRouter>
    )

    // Filter by Role: Admin
    const adminBtn = screen.getByTestId('filter-role-admin')
    fireEvent.click(adminBtn)
    expect(screen.getByText('Andy M.')).toBeInTheDocument()
    expect(screen.getByText('Sarah Chen')).toBeInTheDocument()
    expect(screen.queryByText('Marcus Vance')).not.toBeInTheDocument()
    expect(screen.queryByText('Alex Rivera')).not.toBeInTheDocument()

    // Filter by Role: Viewer
    const viewerBtn = screen.getByTestId('filter-role-viewer')
    fireEvent.click(viewerBtn)
    expect(screen.getByText('Alex Rivera')).toBeInTheDocument()
    expect(screen.queryByText('Andy M.')).not.toBeInTheDocument()

    // Reset role
    fireEvent.click(screen.getByTestId('filter-role-all'))

    // Filter by Status: Invited
    const invitedBtn = screen.getByTestId('filter-status-invited')
    fireEvent.click(invitedBtn)
    expect(screen.getByText('Jordan Hayes')).toBeInTheDocument()
    expect(screen.queryByText('Andy M.')).not.toBeInTheDocument()

    // Filter by Status: Suspended
    const suspendedBtn = screen.getByTestId('filter-status-suspended')
    fireEvent.click(suspendedBtn)
    expect(screen.getByText('Tanya Morgan')).toBeInTheDocument()
    expect(screen.queryByText('Jordan Hayes')).not.toBeInTheDocument()
  })

  it('allows clearing/resetting active filters', () => {
    render(
      <MemoryRouter initialEntries={['/users']}>
        <Routes>
          <Route path="/users" element={<UsersPage />} />
        </Routes>
      </MemoryRouter>
    )

    const searchInput = screen.getByTestId('users-search')
    fireEvent.change(searchInput, { target: { value: 'Chen' } })
    expect(screen.getByText('Sarah Chen')).toBeInTheDocument()
    expect(screen.queryByText('Andy M.')).not.toBeInTheDocument()

    const clearBtn = screen.getByTestId('clear-filters')
    expect(clearBtn).toBeInTheDocument()
    fireEvent.click(clearBtn)

    expect(screen.getByText('Andy M.')).toBeInTheDocument()
    expect(screen.getByText('Sarah Chen')).toBeInTheDocument()
  })

  it('opens the Permissions Matrix modal and displays profile, 3 platform levels, and 6 feature flags', () => {
    render(
      <MemoryRouter initialEntries={['/users']}>
        <Routes>
          <Route path="/users" element={<UsersPage />} />
        </Routes>
      </MemoryRouter>
    )

    // Click "View Matrix" button for Andy M.
    const andyBtn = screen.getByTestId('btn-matrix-usr-andy-001')
    fireEvent.click(andyBtn)

    // Modal dialog should be open
    const modal = screen.getByTestId('permissions-matrix-modal')
    expect(modal).toBeInTheDocument()

    const modalWithin = within(modal)
    expect(modalWithin.getByRole('heading', { level: 2, name: 'Andy M.' })).toBeInTheDocument()
    expect(modalWithin.getByText('andy@signalloom.demo')).toBeInTheDocument()

    // Check Platform Access Tiers section
    const levelsSection = screen.getByTestId('modal-platform-levels')
    expect(within(levelsSection).getByText(/Observe Level/i)).toBeInTheDocument()
    expect(within(levelsSection).getByText(/Govern Level/i)).toBeInTheDocument()
    expect(within(levelsSection).getByText(/Attest Level/i)).toBeInTheDocument()

    // Andy M. has all 3 granted
    const grantedBadges = within(levelsSection).getAllByText('GRANTED')
    expect(grantedBadges.length).toBe(3)

    // Check Active Feature Flags Matrix section (all 6 flags present)
    const flagsSection = screen.getByTestId('modal-feature-flags')
    expect(within(flagsSection).getByText('SuperCredential Multi-Agent Cascade')).toBeInTheDocument()
    expect(within(flagsSection).getByText('Cross-Plane Identity Probes (SLAWS/SLAAT)')).toBeInTheDocument()
    expect(within(flagsSection).getByText('A2A Delegation Chains')).toBeInTheDocument()
    expect(within(flagsSection).getByText('eBPF L4/L7 Kernel Sentinel')).toBeInTheDocument()
    expect(within(flagsSection).getByText('Continuous Attestation Engine')).toBeInTheDocument()
    expect(within(flagsSection).getByText('Dynamic CEL Policy Evaluation')).toBeInTheDocument()

    // Check Human Identity Anchoring section
    const anchorSection = screen.getByTestId('modal-human-anchor')
    expect(within(anchorSection).getByText('Agent Auto-Claim Anchor Authority')).toBeInTheDocument()
    expect(within(anchorSection).getByText('ENABLED')).toBeInTheDocument()
    expect(within(anchorSection).getByText('Trust Log Notary & Attestation Signer')).toBeInTheDocument()
    expect(within(anchorSection).getByText('AUTHORIZED')).toBeInTheDocument()

    // Close modal via close button
    const closeBtn = screen.getByTestId('close-permissions-matrix')
    fireEvent.click(closeBtn)
    expect(screen.queryByTestId('permissions-matrix-modal')).not.toBeInTheDocument()
  })

  it('closes the Permissions Matrix modal when Escape key is pressed', () => {
    render(
      <MemoryRouter initialEntries={['/users']}>
        <Routes>
          <Route path="/users" element={<UsersPage />} />
        </Routes>
      </MemoryRouter>
    )

    const andyBtn = screen.getByTestId('btn-matrix-usr-andy-001')
    fireEvent.click(andyBtn)
    expect(screen.getByTestId('permissions-matrix-modal')).toBeInTheDocument()

    fireEvent.keyDown(window, { key: 'Escape' })
    expect(screen.queryByTestId('permissions-matrix-modal')).not.toBeInTheDocument()
  })

  it('initializes search and faceted filters from URL query parameters', () => {
    render(
      <MemoryRouter initialEntries={['/users?search=Andy&level=govern&tag=2FA%20Active']}>
        <Routes>
          <Route path="/users" element={<UsersPage />} />
        </Routes>
      </MemoryRouter>
    )

    const searchInput = screen.getByTestId('users-search') as HTMLInputElement
    expect(searchInput.value).toBe('Andy')

    const governBtn = screen.getByTestId('filter-level-govern')
    expect(governBtn).toHaveAttribute('aria-pressed', 'true')

    const twoFaBtn = screen.getByTestId('filter-tag-2fa-active')
    expect(twoFaBtn).toHaveAttribute('aria-pressed', 'true')

    expect(screen.getByText('Andy M.')).toBeInTheDocument()
    expect(screen.queryByText('Sarah Chen')).not.toBeInTheDocument()
    expect(screen.queryByText('Marcus Vance')).not.toBeInTheDocument()
  })

  it('triggers CSV download when Export Users Matrix button is clicked', () => {
    const createObjectURLMock = vi.fn().mockReturnValue('blob:mock-url')
    const revokeObjectURLMock = vi.fn()
    window.URL.createObjectURL = createObjectURLMock
    window.URL.revokeObjectURL = revokeObjectURLMock
    const clickSpy = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})

    render(
      <MemoryRouter initialEntries={['/users']}>
        <Routes>
          <Route path="/users" element={<UsersPage />} />
        </Routes>
      </MemoryRouter>
    )

    const exportBtn = screen.getByTestId('export-users-csv')
    fireEvent.click(exportBtn)

    expect(createObjectURLMock).toHaveBeenCalled()
    expect(clickSpy).toHaveBeenCalled()
    expect(revokeObjectURLMock).toHaveBeenCalledWith('blob:mock-url')
  })
})
