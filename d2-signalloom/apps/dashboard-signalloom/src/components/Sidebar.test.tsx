import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import Sidebar from './Sidebar'
import { AppContext } from '../App'
import { api } from '../api/client'
import type { TenantSettingsResponse } from '../types/api'

vi.mock('../auth/oidc', () => {
  const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
  return {
    useAuth0: () => ({
      user: { name: 'Test User', email: 'test@acme.com' },
      logout: vi.fn(),
      getAccessTokenSilently,
    }),
  }
})

vi.mock('../api/client', () => ({
  api: {
    settings: vi.fn(),
    nhi: { discovered: vi.fn().mockResolvedValue({ accounts: [], total: 0, summary: { total_discovered: 0, needs_triage: 0, previously_dismissed: 0 } }) },
  },
}))

function makeSettings(overrides: Partial<TenantSettingsResponse> = {}): TenantSettingsResponse {
  return {
    tenant_id: 'tenant-1',
    org_name: 'Acme Insurance',
    plan_tier: 'growth',
    agent_count: 12,
    billing_tier: null,
    api_key_status: 'active',
    selected_frameworks: [],
    consent_required: false,
    cookie_preferences: null,
    preferred_scan_cadence_hours: 24,
    alert_email: null,
    alert_threshold: 1,
    ...overrides,
  }
}

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
  refreshOnboardingState: () => Promise.resolve(),
  superadmin: false,
  setSuperadmin: () => undefined,
}

function renderSidebar() {
  return render(
    <MemoryRouter>
      <AppContext.Provider value={appCtxValue}>
        <Sidebar />
      </AppContext.Provider>
    </MemoryRouter>
  )
}

describe('Sidebar tenant identity card', () => {
  it('renders the org name only once settings load', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()

    await waitFor(() => expect(screen.getByText('Acme Insurance')).toBeInTheDocument())
    expect(screen.queryByText('growth')).not.toBeInTheDocument()
    expect(screen.queryByText('12 agents')).not.toBeInTheDocument()
  })

  it('shows a live agent count badge next to the Agents nav item', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings({ agent_count: 7 }))
    renderSidebar()

    const agentsLink = await screen.findByRole('link', { name: /Agents/ })
    await waitFor(() => expect(agentsLink).toHaveTextContent('7'))
  })

  it('fails open — renders nav with no tenant card when settings fetch errors', async () => {
    vi.mocked(api.settings).mockRejectedValue(new Error('network error'))
    renderSidebar()

    expect(await screen.findByRole('link', { name: 'Agents' })).toBeInTheDocument()
    expect(screen.queryByText(/\d+ agents?/i)).not.toBeInTheDocument()
  })
})

describe('Sidebar Discovery nav item', () => {
  it('is present as a top-level nav item', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()

    expect(await screen.findByRole('link', { name: /Discovery/ })).toBeInTheDocument()
  })

  it('shows a needs-triage badge next to Discovery when accounts need triage', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    vi.mocked(api.nhi.discovered).mockResolvedValue({
      accounts: [], total: 0, summary: { total_discovered: 5, needs_triage: 3, previously_dismissed: 2 },
    })
    renderSidebar()

    const discoveryLink = await screen.findByRole('link', { name: /Discovery/ })
    await waitFor(() => expect(discoveryLink).toHaveTextContent('3'))
  })

  it('fails open — renders nav with no badge when the discovery-count fetch errors', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    vi.mocked(api.nhi.discovered).mockRejectedValue(new Error('network error'))
    renderSidebar()

    const discoveryLink = await screen.findByRole('link', { name: /Discovery/ })
    expect(discoveryLink).toBeInTheDocument()
  })
})

describe('Sidebar active-link precision', () => {
  it('does not highlight Compliance when a child route like /compliance/policies is active', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    render(
      <MemoryRouter initialEntries={['/compliance/policies']}>
        <AppContext.Provider value={appCtxValue}>
          <Sidebar />
        </AppContext.Provider>
      </MemoryRouter>
    )

    const policyLink = await screen.findByRole('link', { name: /Policy Compliance/ })
    expect(policyLink).toHaveAttribute('aria-current', 'page')

    const complianceLink = screen.getByRole('link', { name: /^Compliance$/ })
    expect(complianceLink).not.toHaveAttribute('aria-current', 'page')
  })
})

describe('Sidebar keyboard shortcuts', () => {
  it('navigates to the nth nav item when its digit key is pressed', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()
    await screen.findByRole('link', { name: /Agents/ })

    fireEvent.keyDown(window, { key: '3' })

    await waitFor(() =>
      expect(screen.getByRole('link', { name: /^Compliance$/ })).toHaveAttribute('aria-current', 'page')
    )
  })

  it('navigates to Discovery (nav item 1) when "1" is pressed', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()
    await screen.findByRole('link', { name: /Agents/ })

    fireEvent.keyDown(window, { key: '1' })

    await waitFor(() =>
      expect(screen.getByRole('link', { name: /Discovery/ })).toHaveAttribute('aria-current', 'page')
    )
  })

  it('navigates to Agents (nav item 2) when "2" is pressed', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()
    await screen.findByRole('link', { name: /Agents/ })

    fireEvent.keyDown(window, { key: '2' })

    await waitFor(() =>
      expect(screen.getByRole('link', { name: /Agents/ })).toHaveAttribute('aria-current', 'page')
    )
  })

  it('ignores digit presses when focus is inside an input', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()
    await screen.findByRole('link', { name: /Agents/ })

    const input = document.createElement('input')
    document.body.appendChild(input)
    input.focus()

    fireEvent.keyDown(input, { key: '2' })

    expect(screen.queryByRole('link', { name: /^Compliance$/ })).not.toHaveAttribute('aria-current', 'page')
    document.body.removeChild(input)
  })

  it('ignores digit presses out of nav range', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()
    await screen.findByRole('link', { name: /Agents/ })

    fireEvent.keyDown(window, { key: '2' })
    await waitFor(() =>
      expect(screen.getByRole('link', { name: /Agents/ })).toHaveAttribute('aria-current', 'page')
    )

    fireEvent.keyDown(window, { key: '0' })

    expect(screen.getByRole('link', { name: /Agents/ })).toHaveAttribute('aria-current', 'page')
    expect(screen.queryByRole('link', { name: /^Compliance$/ })).not.toHaveAttribute('aria-current', 'page')
  })
})
