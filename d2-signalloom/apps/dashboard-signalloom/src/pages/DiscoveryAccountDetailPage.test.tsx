import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import DiscoveryAccountDetailPage from './DiscoveryAccountDetailPage'
import { api } from '../api/client'
import type { NHIAccountDetail } from '../types/api'

vi.mock('../auth/oidc', () => {
  const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
  return { useAuth0: () => ({ getAccessTokenSilently }) }
})

vi.mock('../api/client', () => ({
  api: {
    nhi: {
      getAccount: vi.fn(),
      enrollAccount: vi.fn().mockResolvedValue({ account_id: 'acct-1', status: 'enrollment_requested' }),
      dismissAccount: vi.fn().mockResolvedValue({ account_id: 'acct-1', status: 'dismissed' }),
    },
    agents: {
      list: vi.fn().mockResolvedValue({ agents: [] }),
    },
  },
}))

function makeDetail(overrides: Partial<NHIAccountDetail> = {}): NHIAccountDetail {
  return {
    id: 'acct-1',
    scan_id: 'scan-1',
    account_name: 'svc-billing-sync',
    directory_source: 'ad_entra',
    owner_email: null,
    last_rotated: null,
    privilege_level: 'elevated',
    findings: ['unowned', 'no_rotation'],
    status: 'discovered',
    first_discovered_at: '2026-07-01T00:00:00Z',
    last_seen_at: '2026-07-20T00:00:00Z',
    dismissed_at: null,
    dismissed_by: null,
    dismiss_reason: null,
    scan_count: 2,
    ...overrides,
  }
}

function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/discovery/accounts/acct-1']}>
      <Routes>
        <Route path="/discovery" element={<div>DISCOVERY PAGE</div>} />
        <Route path="/discovery/accounts/:accountId" element={<DiscoveryAccountDetailPage />} />
      </Routes>
    </MemoryRouter>
  )
}

describe('DiscoveryAccountDetailPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('renders account details fetched from GET /nhi/discovered/{id}', async () => {
    ;(api.nhi.getAccount as ReturnType<typeof vi.fn>).mockResolvedValue(makeDetail())
    renderPage()

    expect(await screen.findByText('svc-billing-sync')).toBeInTheDocument()
    expect(api.nhi.getAccount).toHaveBeenCalledWith('test-token', 'acct-1')
    expect(screen.getByText('unowned')).toBeInTheDocument()
    expect(screen.getByText('no_rotation')).toBeInTheDocument()
    expect(screen.getByText('Unowned')).toBeInTheDocument()
    expect(screen.getByText('Never')).toBeInTheDocument()
  })

  it('shows dismissal details for a dismissed account', async () => {
    ;(api.nhi.getAccount as ReturnType<typeof vi.fn>).mockResolvedValue(makeDetail({
      status: 'dismissed',
      dismissed_at: '2026-07-15T00:00:00Z',
      dismissed_by: 'ops@acme.com',
      dismiss_reason: 'Known service account, rotation exempt.',
    }))
    renderPage()

    await screen.findByText('svc-billing-sync')
    expect(screen.getByText('ops@acme.com')).toBeInTheDocument()
    expect(screen.getByText('Known service account, rotation exempt.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Enroll' })).toBeInTheDocument()
  })

  it('navigates back to /discovery via the back button', async () => {
    ;(api.nhi.getAccount as ReturnType<typeof vi.fn>).mockResolvedValue(makeDetail())
    renderPage()
    await screen.findByText('svc-billing-sync')

    await userEvent.click(screen.getByRole('button', { name: /Discovery/ }))
    expect(await screen.findByText('DISCOVERY PAGE')).toBeInTheDocument()
  })

  it('requests enrollment via the triage menu and reloads', async () => {
    ;(api.nhi.getAccount as ReturnType<typeof vi.fn>).mockResolvedValue(makeDetail())
    renderPage()
    await screen.findByText('svc-billing-sync')

    await userEvent.click(screen.getByRole('button', { name: /Actions/ }))
    await userEvent.click(screen.getByRole('button', { name: 'Request Enrollment' }))

    await waitFor(() => expect(api.nhi.enrollAccount).toHaveBeenCalledWith('test-token', 'acct-1'))
    expect(api.nhi.getAccount).toHaveBeenCalledTimes(2) // initial load + reload after action
  })

  it('shows an error state with retry when the fetch fails', async () => {
    ;(api.nhi.getAccount as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('network error'))
    renderPage()

    expect(await screen.findByText('network error')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Back to Discovery/ })).toBeInTheDocument()
  })

  it('renders Associated Agent Dossier panel when a registered agent matches the account', async () => {
    ;(api.nhi.getAccount as ReturnType<typeof vi.fn>).mockResolvedValue(makeDetail())
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        {
          id: 'agent-billing-sync',
          name: 'Billing Agent Worker',
          service_account: 'svc-billing-sync',
          owner: 'billing-team@acme.com',
          type: 'Signal Loom Built',
          tenant_id: 'tenant-1',
          lifecycle_state: 'active',
          last_transition_at: null,
          eu_ai_act_risk_class: null,
          compliance_summary: { total_controls: 10, passing: 9, failing: 1, pending: 0, posture_score: 90 },
          created_at: null,
        },
      ],
    })

    renderPage()
    await screen.findByText('svc-billing-sync')

    const dossierPanel = await screen.findByTestId('associated-agent-dossier')
    expect(dossierPanel).toBeInTheDocument()
    expect(dossierPanel).toHaveTextContent('Billing Agent Worker')
    expect(dossierPanel).toHaveTextContent('Posture Score: 90%')

    const viewBtn = screen.getByTestId('view-agent-dossier-btn')
    expect(viewBtn).toHaveAttribute('href', '/agents/agent-billing-sync?tab=overview')
    expect(viewBtn).toHaveTextContent('View Agent Dossier ↗')
  })

  it('renders Search Agent Registry button when no registered agent matches', async () => {
    ;(api.nhi.getAccount as ReturnType<typeof vi.fn>).mockResolvedValue(makeDetail({ account_name: 'unknown-cron-svc' }))
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({ agents: [] })

    renderPage()
    await screen.findByText('unknown-cron-svc')

    const searchCard = await screen.findByTestId('associated-agent-search')
    expect(searchCard).toBeInTheDocument()
    const searchBtn = screen.getByTestId('search-agent-registry-btn')
    expect(searchBtn).toHaveAttribute('href', '/agents?search=unknown-cron-svc')
    expect(searchBtn).toHaveTextContent('Search Agent Registry ↗')
  })
})
