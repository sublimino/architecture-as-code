import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import DiscoveryPage from './DiscoveryPage'
import { api } from '../api/client'
import type { NHIAccount } from '../types/api'

vi.mock('../auth/oidc', () => {
  const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
  return { useAuth0: () => ({ getAccessTokenSilently }) }
})

vi.mock('../api/client', () => ({
  api: {
    nhi: {
      discovered: vi.fn(),
      scans: vi.fn().mockResolvedValue({ scans: [] }),
      enrollAccount: vi.fn().mockResolvedValue({ account_id: 'acct-1', status: 'enrollment_requested' }),
      dismissAccount: vi.fn().mockResolvedValue({ account_id: 'acct-1', status: 'dismissed' }),
    },
  },
}))

function makeAccount(overrides: Partial<NHIAccount> = {}): NHIAccount {
  return {
    id: 'acct-1',
    scan_id: 'scan-1',
    account_name: 'svc-billing-sync',
    directory_source: 'ad_entra',
    owner_email: null,
    last_credential_rotation: null,
    privilege_level: 'standard',
    status: 'discovered',
    findings: [],
    scan_count: 1,
    dismissed_at: null,
    dismissed_by: null,
    changes_since_dismissal: null,
    previous_risk_flags: null,
    first_discovered_at: '2026-07-01T00:00:00Z',
    last_seen_at: '2026-07-20T00:00:00Z',
    source_removed: false,
    source_removed_at: null,
    ...overrides,
  }
}

function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/discovery']}>
      <Routes>
        <Route path="/discovery" element={<DiscoveryPage />} />
        <Route path="/discovery/accounts/:accountId" element={<div>ACCOUNT DETAIL PAGE</div>} />
        <Route path="/onboarding" element={<div>ONBOARDING WIZARD</div>} />
      </Routes>
    </MemoryRouter>
  )
}

describe('DiscoveryPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    ;(api.nhi.scans as ReturnType<typeof vi.fn>).mockResolvedValue({ scans: [] })
  })

  it('renders discovered accounts from the list endpoint', async () => {
    ;(api.nhi.discovered as ReturnType<typeof vi.fn>).mockResolvedValue({
      accounts: [makeAccount()],
      total: 1,
      summary: { total_discovered: 1, needs_triage: 1, previously_dismissed: 0 },
    })
    renderPage()

    expect(await screen.findByText('svc-billing-sync')).toBeInTheDocument()
    expect(screen.getByText('Discovery')).toBeInTheDocument()
  })

  it('shows the Connect a directory CTA and navigates to /onboarding', async () => {
    ;(api.nhi.discovered as ReturnType<typeof vi.fn>).mockResolvedValue({
      accounts: [], total: 0, summary: { total_discovered: 0, needs_triage: 0, previously_dismissed: 0 },
    })
    renderPage()
    await screen.findByText(/No accounts found/i)

    await userEvent.click(screen.getByRole('button', { name: 'Connect a directory' }))
    expect(await screen.findByText('ONBOARDING WIZARD')).toBeInTheDocument()
  })

  it('navigates to the account detail route when an account name is clicked', async () => {
    ;(api.nhi.discovered as ReturnType<typeof vi.fn>).mockResolvedValue({
      accounts: [makeAccount()],
      total: 1,
      summary: { total_discovered: 1, needs_triage: 1, previously_dismissed: 0 },
    })
    renderPage()

    const nameBtn = await screen.findByText('svc-billing-sync')
    await userEvent.click(nameBtn)

    expect(await screen.findByText('ACCOUNT DETAIL PAGE')).toBeInTheDocument()
  })

  it('shows an Attention Required alert for unowned accounts', async () => {
    ;(api.nhi.discovered as ReturnType<typeof vi.fn>).mockResolvedValue({
      accounts: [makeAccount({ owner_email: null })],
      total: 1,
      summary: { total_discovered: 1, needs_triage: 1, previously_dismissed: 0 },
    })
    renderPage()

    expect(await screen.findByText('Attention Required')).toBeInTheDocument()
    expect(screen.getByText(/unowned accounts/i)).toBeInTheDocument()
  })

  it('dismisses an account via the triage menu and reloads the list', async () => {
    ;(api.nhi.discovered as ReturnType<typeof vi.fn>).mockResolvedValue({
      accounts: [makeAccount()],
      total: 1,
      summary: { total_discovered: 1, needs_triage: 1, previously_dismissed: 0 },
    })
    renderPage()
    await screen.findByText('svc-billing-sync')

    await userEvent.click(screen.getByRole('button', { name: /Actions/ }))
    await userEvent.click(screen.getByRole('button', { name: 'Dismiss' }))

    await waitFor(() => expect(api.nhi.dismissAccount).toHaveBeenCalledWith('test-token', 'acct-1'))
    expect(api.nhi.discovered).toHaveBeenCalledTimes(2) // initial load + reload after action
  })

  it('paginates through accounts beyond the first page using total', async () => {
    ;(api.nhi.discovered as ReturnType<typeof vi.fn>).mockResolvedValue({
      accounts: [makeAccount()],
      total: 362,
      summary: { total_discovered: 362, needs_triage: 310, previously_dismissed: 5 },
    })
    renderPage()

    expect(await screen.findByText(/Showing 1–50 of 362/)).toBeInTheDocument()
    const nextBtn = screen.getByRole('button', { name: 'Next' })
    expect(screen.getByRole('button', { name: 'Previous' })).toBeDisabled()

    await userEvent.click(nextBtn)

    await waitFor(() => expect(api.nhi.discovered).toHaveBeenLastCalledWith('test-token', 2, 50, undefined, false))
    expect(await screen.findByText(/Showing 51–100 of 362/)).toBeInTheDocument()
  })

  it('filters via the single Filter dropdown instead of separate tab buttons', async () => {
    ;(api.nhi.discovered as ReturnType<typeof vi.fn>).mockResolvedValue({
      accounts: [
        makeAccount({ id: 'acct-1', account_name: 'svc-billing-sync', status: 'discovered' }),
        makeAccount({ id: 'acct-2', account_name: 'svc-dismissed-thing', status: 'dismissed' }),
      ],
      total: 2,
      summary: { total_discovered: 2, needs_triage: 1, previously_dismissed: 1 },
    })
    renderPage()
    await screen.findByText('svc-billing-sync')

    // No standalone "All"/"Needs Triage"/"Dismissed" tab buttons — one dropdown trigger instead.
    expect(screen.queryByRole('button', { name: 'Needs Triage' })).not.toBeInTheDocument()
    expect(screen.queryByRole('checkbox', { name: /show disconnected/i })).not.toBeInTheDocument()

    const trigger = screen.getByRole('button', { name: /^Filter: All/ })
    await userEvent.click(trigger)
    await userEvent.click(screen.getByRole('button', { name: 'Dismissed' }))

    expect(screen.queryByText('svc-billing-sync')).not.toBeInTheDocument()
    expect(screen.getByText('svc-dismissed-thing')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^Filter: Dismissed/ })).toBeInTheDocument()
  })

  it('toggles "Show disconnected sources" from within the Filter dropdown and refetches', async () => {
    ;(api.nhi.discovered as ReturnType<typeof vi.fn>).mockResolvedValue({
      accounts: [makeAccount()],
      total: 1,
      summary: { total_discovered: 1, needs_triage: 1, previously_dismissed: 0 },
    })
    renderPage()
    await screen.findByText('svc-billing-sync')

    await userEvent.click(screen.getByRole('button', { name: /^Filter: All/ }))
    await userEvent.click(screen.getByRole('button', { name: /Show disconnected sources/ }))

    await waitFor(() => expect(api.nhi.discovered).toHaveBeenLastCalledWith('test-token', 1, 50, undefined, true))
    expect(screen.getByRole('button', { name: /Filter: All \+ Disconnected/ })).toBeInTheDocument()
  })
})
