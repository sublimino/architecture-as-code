import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import Sidebar, { NAV, SIDEBAR_COLLAPSED_STORAGE_KEY } from './Sidebar'
import { AppContext } from '../App'
import { api } from '../api/client'
import { installMemoryStorage } from '../test-utils/memoryStorage'
import type { TenantSettingsResponse } from '../types/api'

// The superadmin block only renders for a superadmin-eligible identity (see
// auth/superadmin.ts), so the mocked OIDC user has to be swappable. Hoisted so
// the vi.mock factory can read it without hitting the TDZ.
const DEFAULT_USER = { name: 'Test User', email: 'test@acme.com' }
const authMock = vi.hoisted(() => ({
  user: { name: 'Test User', email: 'test@acme.com' } as Record<string, unknown>,
}))

vi.mock('../auth/oidc', () => {
  const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
  return {
    useAuth0: () => ({
      user: authMock.user,
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

function renderSidebar(ctx: Partial<typeof appCtxValue> = {}) {
  return render(
    <MemoryRouter>
      <AppContext.Provider value={{ ...appCtxValue, ...ctx }}>
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

describe('Sidebar primary navigation destinations', () => {
  it('keeps core destinations as client-side route links', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()

    await screen.findByRole('link', { name: /Agents/ })
    expect(screen.getByRole('link', { name: /Agents/ })).toHaveAttribute('href', '/agents')
    expect(screen.getByRole('link', { name: /^Compliance$/ })).toHaveAttribute('href', '/compliance')
    expect(screen.getByRole('link', { name: /Audit Trail/ })).toHaveAttribute('href', '/audit')
    expect(screen.getByRole('link', { name: /^Settings$/ })).toHaveAttribute('href', '/settings')
  })
})

describe('Sidebar Beautiful UI interactions', () => {
  it('renders icon-bearing navigation and filters it through quick search', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()

    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })
    expect(screen.getByRole('link', { name: /Agents/ }).querySelector('svg')).toBeInTheDocument()

    fireEvent.change(search, { target: { value: 'audit' } })
    expect(screen.getByRole('link', { name: /Audit Trail/ })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: /Agents/ })).not.toBeInTheDocument()

    fireEvent.change(search, { target: { value: '' } })
    expect(screen.getByRole('link', { name: /Agents/ })).toBeInTheDocument()
  })

  it('focuses quick search when slash is pressed outside inputs', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()

    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })
    fireEvent.keyDown(window, { key: '/' })
    expect(search).toHaveFocus()
  })
})

describe('Sidebar Agent Trust Topology navigation', () => {
  it('places Agent Trust Topology immediately before Settings', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()

    const labels = (await screen.findAllByRole('link')).map(link => link.textContent?.replace(/\d+/g, '').trim())
    expect(labels.indexOf('Agent Trust Topology')).toBe(labels.indexOf('Settings') - 1)
  })
})

describe('Sidebar superadmin-only nav', () => {
  // Every admin surface behind the superadmin visibility flag. SuperCred is a
  // demo surface and belongs here with the rest of them.
  const SUPERADMIN_LINKS = [
    'Cryptography',
    'Federated Services',
    'Collusion & Access',
    'RBAC Analysis',
    'RBAC Explorer',
    'Network Tests',
    'SuperCredential Demo',
  ]

  beforeEach(() => {
    authMock.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }
  })

  afterEach(() => {
    authMock.user = { ...DEFAULT_USER }
  })

  it('renders every superadmin-only link, including SuperCred, when superadmin is on', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar({ superadmin: true })
    await screen.findByRole('link', { name: 'Agents' })

    for (const label of SUPERADMIN_LINKS) {
      expect(screen.getByRole('link', { name: label })).toBeInTheDocument()
    }
  })

  it('hides every superadmin-only link, including SuperCred, when superadmin is off', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar({ superadmin: false })
    await screen.findByRole('link', { name: 'Agents' })

    for (const label of SUPERADMIN_LINKS) {
      expect(screen.queryByRole('link', { name: label })).not.toBeInTheDocument()
    }
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

describe('Sidebar iconography', () => {
  // The regression this guards: four Governance routes once shared the
  // 'compliance' glyph and the two RBAC routes shared 'rbac', so a collapsed
  // icon-only rail was ambiguous. Asserting on the data, not the pixels, is
  // what actually stops the duplication creeping back in.
  it('gives every nav item a distinct icon kind', () => {
    const kinds = NAV.map(({ icon }) => icon)
    expect(new Set(kinds).size).toBe(kinds.length)
  })

  describe('rendered glyphs', () => {
    beforeEach(() => {
      authMock.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }
    })

    afterEach(() => {
      authMock.user = { ...DEFAULT_USER }
    })

    it('renders a unique svg for every nav link, superadmin block included', async () => {
      vi.mocked(api.settings).mockResolvedValue(makeSettings())
      renderSidebar({ superadmin: true })
      await screen.findByRole('link', { name: 'Agents' })

      const glyphs = screen.getAllByRole('link').map((link) => link.querySelector('svg')?.innerHTML)
      expect(glyphs).toHaveLength(NAV.length)
      expect(glyphs.every(Boolean)).toBe(true)
      expect(new Set(glyphs).size).toBe(glyphs.length)
    })
  })
})

describe('Sidebar collapse', () => {
  beforeEach(() => {
    installMemoryStorage()
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
  })

  it('collapses to an icon-only rail and expands again', async () => {
    const user = userEvent.setup()
    renderSidebar()
    await screen.findByRole('link', { name: 'Agents' })

    const toggle = screen.getByTestId('sidebar-collapse-toggle')
    expect(toggle).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByText('Workspace')).toBeInTheDocument()

    await user.click(toggle)

    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    // Section headings, workspace copy and the search box all go away…
    expect(screen.queryByText('Workspace')).not.toBeInTheDocument()
    expect(screen.queryByText('Agent governance workspace')).not.toBeInTheDocument()
    expect(screen.queryByRole('textbox', { name: 'Quick search navigation' })).not.toBeInTheDocument()

    await user.click(toggle)
    expect(toggle).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByText('Workspace')).toBeInTheDocument()
  })

  it('keeps every collapsed link named and hoverable', async () => {
    const user = userEvent.setup()
    renderSidebar()
    await screen.findByRole('link', { name: 'Agents' })

    await user.click(screen.getByTestId('sidebar-collapse-toggle'))

    // The label is still in the accessibility tree, just visually hidden.
    const agents = screen.getByRole('link', { name: 'Agents' })
    expect(agents).toHaveAttribute('title', 'Agents')
    expect(agents.querySelector('.sr-only')).toHaveTextContent('Agents')
    expect(agents.querySelector('.sl-sidebar__link-label')).toBeNull()
    expect(agents.querySelector('svg')).toBeInTheDocument()
  })

  it('round-trips the collapsed state through localStorage', async () => {
    const user = userEvent.setup()
    const { unmount } = renderSidebar()
    await screen.findByRole('link', { name: 'Agents' })

    await user.click(screen.getByTestId('sidebar-collapse-toggle'))
    expect(localStorage.getItem(SIDEBAR_COLLAPSED_STORAGE_KEY)).toBe('true')
    unmount()

    renderSidebar()
    await screen.findByRole('link', { name: 'Agents' })
    expect(screen.getByTestId('sidebar-collapse-toggle')).toHaveAttribute('aria-expanded', 'false')
  })

  it('defaults to expanded when localStorage throws', async () => {
    Object.defineProperty(globalThis, 'localStorage', {
      get() { throw new Error('storage disabled') },
      configurable: true,
    })

    renderSidebar()
    await screen.findByRole('link', { name: 'Agents' })
    expect(screen.getByTestId('sidebar-collapse-toggle')).toHaveAttribute('aria-expanded', 'true')

    installMemoryStorage()
  })

  it('reopens and focuses quick search when "/" is pressed while collapsed', async () => {
    const user = userEvent.setup()
    renderSidebar()
    await screen.findByRole('link', { name: 'Agents' })
    await user.click(screen.getByTestId('sidebar-collapse-toggle'))

    fireEvent.keyDown(window, { key: '/' })

    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })
    await waitFor(() => expect(search).toHaveFocus())
  })

  it('keeps number-key navigation working while collapsed', async () => {
    const user = userEvent.setup()
    renderSidebar()
    await screen.findByRole('link', { name: 'Agents' })
    await user.click(screen.getByTestId('sidebar-collapse-toggle'))

    fireEvent.keyDown(window, { key: '3' })

    await waitFor(() =>
      expect(screen.getByRole('link', { name: /^Compliance$/ })).toHaveAttribute('aria-current', 'page')
    )
  })
})

describe('Sidebar quick-search clearing', () => {
  beforeEach(() => {
    installMemoryStorage()
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
  })

  it('shows the clear button only once the query is non-empty', async () => {
    const user = userEvent.setup()
    renderSidebar()
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    expect(screen.queryByTestId('sidebar-search-clear')).not.toBeInTheDocument()

    await user.type(search, 'aud')
    expect(screen.getByTestId('sidebar-search-clear')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Clear search' })).toBeInTheDocument()
  })

  it('clears the query and returns focus to the input', async () => {
    const user = userEvent.setup()
    renderSidebar()
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    await user.type(search, 'audit')
    expect(screen.queryByRole('link', { name: 'Agents' })).not.toBeInTheDocument()

    await user.click(screen.getByTestId('sidebar-search-clear'))

    expect(search).toHaveValue('')
    expect(search).toHaveFocus()
    expect(screen.queryByTestId('sidebar-search-clear')).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Agents' })).toBeInTheDocument()
  })

  it('clears the query when Escape is pressed inside the input', async () => {
    const user = userEvent.setup()
    renderSidebar()
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    await user.type(search, 'audit')
    await user.keyboard('{Escape}')

    expect(search).toHaveValue('')
    expect(search).toHaveFocus()
    expect(screen.getByRole('link', { name: 'Agents' })).toBeInTheDocument()
  })

  it('blurs the input when Escape is pressed on an already-empty query', async () => {
    const user = userEvent.setup()
    renderSidebar()
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    await user.click(search)
    expect(search).toHaveFocus()

    await user.keyboard('{Escape}')
    expect(search).not.toHaveFocus()
  })

  it('leaves the global "/" and digit shortcuts untouched', async () => {
    renderSidebar()
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    fireEvent.keyDown(window, { key: '/' })
    expect(search).toHaveFocus()

    // Digits typed inside the search box must filter, never navigate.
    fireEvent.keyDown(search, { key: '3' })
    expect(screen.getByRole('link', { name: /^Compliance$/ })).not.toHaveAttribute('aria-current', 'page')
  })
})
