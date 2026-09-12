import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor, fireEvent, within } from '@testing-library/react'
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
  needsOnboarding: null as boolean | null,
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

describe('Sidebar Overview nav item', () => {
  it('is present as top-level nav item in View group', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()

    expect(await screen.findByRole('link', { name: /Overview/ })).toBeInTheDocument()
  })

  it('shows a needs-triage badge next to Overview when accounts need triage', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    vi.mocked(api.nhi.discovered).mockResolvedValue({
      accounts: [], total: 0, summary: { total_discovered: 5, needs_triage: 3, previously_dismissed: 2 },
    })
    renderSidebar()

    const overviewLink = await screen.findByRole('link', { name: /Overview/ })
    await waitFor(() => expect(overviewLink).toHaveTextContent('3'))
  })

  it('fails open — renders nav with no badge when discovery fetch errors', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    vi.mocked(api.nhi.discovered).mockRejectedValue(new Error('network error'))
    renderSidebar()

    const overviewLink = await screen.findByRole('link', { name: /Overview/ })
    expect(overviewLink).toBeInTheDocument()
  })
})

describe('Sidebar active-link precision', () => {
  it('highlights Policies when /policies is active', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    render(
      <MemoryRouter initialEntries={['/policies']}>
        <AppContext.Provider value={appCtxValue}>
          <Sidebar />
        </AppContext.Provider>
      </MemoryRouter>
    )

    const policyLink = await screen.findByRole('link', { name: /^Policies$/ })
    expect(policyLink).toHaveAttribute('aria-current', 'page')

    const containmentLink = screen.getByRole('link', { name: /^Containment$/ })
    expect(containmentLink).not.toHaveAttribute('aria-current', 'page')
  })

  it('highlights Containment when /containment is active', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    render(
      <MemoryRouter initialEntries={['/containment']}>
        <AppContext.Provider value={appCtxValue}>
          <Sidebar />
        </AppContext.Provider>
      </MemoryRouter>
    )

    const containmentLink = await screen.findByRole('link', { name: /^Containment$/ })
    expect(containmentLink).toHaveAttribute('aria-current', 'page')
  })
})

describe('Sidebar 3-Tier Navigation Hierarchy & Ordering (SP-2)', () => {
  it('renders all 3 category headings: View, Control, Design', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()

    await screen.findByRole('link', { name: /Agents/ })
    expect(screen.getByText('View')).toBeInTheDocument()
    expect(screen.getByText('Control')).toBeInTheDocument()
    expect(screen.getByText('Design')).toBeInTheDocument()
  })

  it('organizes items in the exact SP-2 3-tier sequence', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()

    await screen.findByRole('link', { name: /Agents/ })

    // View group
    expect(screen.getByRole('link', { name: /^Overview/ })).toHaveAttribute('href', '/overview')
    expect(screen.getByRole('link', { name: /^Agents/ })).toHaveAttribute('href', '/agents')
    expect(screen.getByRole('link', { name: /^Topology$/ })).toHaveAttribute('href', '/topology')
    expect(screen.getByRole('link', { name: /^Activity$/ })).toHaveAttribute('href', '/activity')
    expect(screen.getByRole('link', { name: /^FAIR Risk$/ })).toHaveAttribute('href', '/risk')

    // Control group
    expect(screen.getByRole('link', { name: /^Policies$/ })).toHaveAttribute('href', '/policies')
    expect(screen.getByRole('link', { name: /^Containment$/ })).toHaveAttribute('href', '/containment')
    expect(screen.getByRole('link', { name: /^Approvals$/ })).toHaveAttribute('href', '/approvals')
    expect(screen.getByRole('link', { name: /^Audit Trail$/ })).toHaveAttribute('href', '/audit')

    // Design group
    expect(screen.getByRole('link', { name: /^Workspaces$/ })).toHaveAttribute('href', '/workspaces')
    expect(screen.getByRole('link', { name: /^Connectors$/ })).toHaveAttribute('href', '/connectors')
    expect(screen.getByRole('link', { name: /^Fleet Config$/ })).toHaveAttribute('href', '/fleet')
    expect(screen.getByRole('link', { name: /^Settings$/ })).toHaveAttribute('href', '/settings')

    // Persistent Anchors
    expect(screen.getByRole('link', { name: /^Onboarding/ })).toHaveAttribute('href', '/onboarding')
    expect(screen.getByRole('button', { name: /Help & (Support|Docs)/ })).toBeInTheDocument()
  })

  it('renders View items before Control items, and Control items before Design items', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()

    const navRegion = document.getElementById('sl-sidebar-nav')!
    const links = Array.from(navRegion.querySelectorAll('a')).map((a) => a.getAttribute('href'))

    expect(links.indexOf('/overview')).toBeLessThan(links.indexOf('/agents'))
    expect(links.indexOf('/agents')).toBeLessThan(links.indexOf('/topology'))
    expect(links.indexOf('/topology')).toBeLessThan(links.indexOf('/activity'))
    expect(links.indexOf('/activity')).toBeLessThan(links.indexOf('/risk'))

    expect(links.indexOf('/risk')).toBeLessThan(links.indexOf('/policies'))
    expect(links.indexOf('/policies')).toBeLessThan(links.indexOf('/containment'))
    expect(links.indexOf('/containment')).toBeLessThan(links.indexOf('/approvals'))
    expect(links.indexOf('/approvals')).toBeLessThan(links.indexOf('/audit'))

    expect(links.indexOf('/audit')).toBeLessThan(links.indexOf('/workspaces'))
    expect(links.indexOf('/workspaces')).toBeLessThan(links.indexOf('/connectors'))
    expect(links.indexOf('/connectors')).toBeLessThan(links.indexOf('/fleet'))
    expect(links.indexOf('/fleet')).toBeLessThan(links.indexOf('/settings'))
  })
})

describe('Sidebar Persistent Anchors', () => {
  it('renders Onboarding and Help & Support persistent anchors in utilities region', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar({ needsOnboarding: true })

    const onboardingLink = await screen.findByRole('link', { name: /Onboarding/ })
    expect(onboardingLink).toHaveAttribute('href', '/onboarding')
    expect(onboardingLink).toHaveTextContent('New')

    const helpButton = screen.getByRole('button', { name: /Help & (Support|Docs)/ })
    expect(helpButton).toBeInTheDocument()
  })

  it('triggers setHelpOpen when Help & Support button is clicked', async () => {
    const setHelpOpen = vi.fn()
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar({ setHelpOpen })

    const helpButton = await screen.findByRole('button', { name: /Help & (Support|Docs)/ })
    fireEvent.click(helpButton)
    expect(setHelpOpen).toHaveBeenCalledWith(true)
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

describe('Sidebar superadmin-only nav', () => {
  const SUPERADMIN_LINKS = [
    'Cryptography',
    'Credential Inventory',
    'Federated Services',
    'Collusion & Access',
    'RBAC Analysis',
    'RBAC Explorer',
    'Network Tests',
    'SuperCredential Demo',
    'Signal Fusion Demo',
  ]

  beforeEach(() => {
    authMock.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }
  })

  afterEach(() => {
    authMock.user = { ...DEFAULT_USER }
  })

  it('renders every superadmin-only link when superadmin is on', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar({ superadmin: true })
    await screen.findByRole('link', { name: 'Agents' })

    for (const label of SUPERADMIN_LINKS) {
      expect(screen.getByRole('link', { name: label })).toBeInTheDocument()
    }
  })

  it('hides every superadmin-only link when superadmin is off', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar({ superadmin: false })
    await screen.findByRole('link', { name: 'Agents' })

    for (const label of SUPERADMIN_LINKS) {
      expect(screen.queryByRole('link', { name: label })).not.toBeInTheDocument()
    }
  })
})

describe('Sidebar keyboard shortcuts', () => {
  it('navigates to Overview (nav item 1) when "1" is pressed', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()
    await screen.findByRole('link', { name: /Agents/ })

    fireEvent.keyDown(window, { key: '1' })

    await waitFor(() =>
      expect(screen.getByRole('link', { name: /Overview/ })).toHaveAttribute('aria-current', 'page')
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

  it('navigates to Topology (nav item 3) when "3" is pressed', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()
    await screen.findByRole('link', { name: /Agents/ })

    fireEvent.keyDown(window, { key: '3' })

    await waitFor(() =>
      expect(screen.getByRole('link', { name: /^Topology$/ })).toHaveAttribute('aria-current', 'page')
    )
  })

  it('navigates to Policies (nav item 6) when "6" is pressed', async () => {
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    renderSidebar()
    await screen.findByRole('link', { name: /Agents/ })

    fireEvent.keyDown(window, { key: '6' })

    await waitFor(() =>
      expect(screen.getByRole('link', { name: /^Policies$/ })).toHaveAttribute('aria-current', 'page')
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

    expect(screen.queryByRole('link', { name: /^Policies$/ })).not.toHaveAttribute('aria-current', 'page')
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
    expect(screen.queryByRole('link', { name: /^Policies$/ })).not.toHaveAttribute('aria-current', 'page')
  })
})

describe('Sidebar iconography', () => {
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

      const navRegion = document.getElementById('sl-sidebar-nav')!
      const glyphs = Array.from(navRegion.querySelectorAll('a')).map((link) => link.querySelector('svg')?.innerHTML)
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
    expect(screen.getByText('View')).toBeInTheDocument()

    await user.click(toggle)

    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    // Section headings, workspace copy and the search box all go away…
    expect(screen.queryByText('View')).not.toBeInTheDocument()
    expect(screen.queryByText('Control')).not.toBeInTheDocument()
    expect(screen.queryByText('Design')).not.toBeInTheDocument()
    expect(screen.queryByText('Agent governance workspace')).not.toBeInTheDocument()
    expect(screen.queryByRole('textbox', { name: 'Quick search navigation' })).not.toBeInTheDocument()

    await user.click(toggle)
    expect(toggle).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByText('View')).toBeInTheDocument()
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

    fireEvent.keyDown(window, { key: '2' })

    await waitFor(() =>
      expect(screen.getByRole('link', { name: /Agents/ })).toHaveAttribute('aria-current', 'page')
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
    fireEvent.keyDown(search, { key: '2' })
    expect(screen.getByRole('link', { name: /Agents/ })).not.toHaveAttribute('aria-current', 'page')
  })
})

describe('Sidebar filtered section headings', () => {
  const ALL_HEADINGS = ['View', 'Control', 'Design', 'Superadmin']

  function navRegion(): HTMLElement {
    return document.getElementById('sl-sidebar-nav')!
  }

  function visibleHeadings(): string[] {
    return ALL_HEADINGS.filter((heading) => within(navRegion()).queryByText(heading) !== null)
  }

  beforeEach(() => {
    installMemoryStorage()
    authMock.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
  })

  afterEach(() => {
    authMock.user = { ...DEFAULT_USER }
  })

  it('renders every heading when nothing is filtered', async () => {
    renderSidebar({ superadmin: true })
    await screen.findByRole('link', { name: 'Agents' })

    expect(visibleHeadings()).toEqual(ALL_HEADINGS)
  })

  it('renders only Control when the match is a Control item', async () => {
    renderSidebar({ superadmin: true })
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    fireEvent.change(search, { target: { value: 'audit' } })

    expect(visibleHeadings()).toEqual(['Control'])
    expect(screen.getByRole('link', { name: /Audit Trail/ })).toBeInTheDocument()
  })

  it('renders only View when the match is a View item', async () => {
    renderSidebar({ superadmin: true })
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    fireEvent.change(search, { target: { value: 'overview' } })

    expect(visibleHeadings()).toEqual(['View'])
  })

  it('renders only Design when the match is a Design item', async () => {
    renderSidebar({ superadmin: true })
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    fireEvent.change(search, { target: { value: 'workspaces' } })

    expect(visibleHeadings()).toEqual(['Design'])
  })

  it('drops the Superadmin heading and its rule when no superadmin item matches', async () => {
    const { container } = renderSidebar({ superadmin: true })
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    fireEvent.change(search, { target: { value: 'audit' } })

    expect(within(navRegion()).queryByText('Superadmin')).not.toBeInTheDocument()
    expect(container.querySelector('hr')).toBeNull()
    expect(screen.getByTestId('superadmin-toggle')).toHaveTextContent('Superadmin')
  })

  it('keeps the Superadmin heading and its rule when a superadmin item matches', async () => {
    const { container } = renderSidebar({ superadmin: true })
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    fireEvent.change(search, { target: { value: 'rbac' } })

    expect(within(navRegion()).getByText('Superadmin')).toBeInTheDocument()
    expect(container.querySelector('hr')).not.toBeNull()
    expect(screen.getByRole('link', { name: 'RBAC Analysis' })).toBeInTheDocument()
    expect(visibleHeadings()).toEqual(['Superadmin'])
  })

  it('renders no headings at all when nothing matches', async () => {
    const { container } = renderSidebar({ superadmin: true })
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    fireEvent.change(search, { target: { value: 'zzzznotathing' } })

    expect(visibleHeadings()).toEqual([])
    expect(container.querySelector('hr')).toBeNull()
    expect(within(navRegion()).queryAllByRole('link')).toHaveLength(0)
  })
})

describe('Sidebar empty search results', () => {
  beforeEach(() => {
    installMemoryStorage()
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
  })

  it('explains the empty rail instead of leaving a blank dead end', async () => {
    renderSidebar()
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    fireEvent.change(search, { target: { value: 'zzzznotathing' } })

    const empty = screen.getByTestId('sidebar-no-matches')
    expect(empty).toHaveTextContent('No navigation matches zzzznotathing')
    expect(empty).toHaveAttribute('role', 'status')
    expect(empty).toHaveTextContent(/Escape to clear/i)
  })

  it('shows nothing of the kind while there are still matches', async () => {
    renderSidebar()
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    expect(screen.queryByTestId('sidebar-no-matches')).not.toBeInTheDocument()

    fireEvent.change(search, { target: { value: 'audit' } })
    expect(screen.queryByTestId('sidebar-no-matches')).not.toBeInTheDocument()
  })

  it('withdraws once the search is cleared', async () => {
    const user = userEvent.setup()
    renderSidebar()
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    await user.type(search, 'zzzz')
    expect(screen.getByTestId('sidebar-no-matches')).toBeInTheDocument()

    await user.click(screen.getByTestId('sidebar-search-clear'))

    expect(screen.queryByTestId('sidebar-no-matches')).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Agents' })).toBeInTheDocument()
  })

  it('withdraws on Escape too', async () => {
    const user = userEvent.setup()
    renderSidebar()
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    await user.type(search, 'zzzz')
    expect(screen.getByTestId('sidebar-no-matches')).toBeInTheDocument()

    await user.keyboard('{Escape}')

    expect(screen.queryByTestId('sidebar-no-matches')).not.toBeInTheDocument()
    expect(search).toHaveValue('')
  })
})

describe('Sidebar collapse control legibility', () => {
  beforeEach(() => {
    installMemoryStorage()
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
  })

  function toggleGlyph(): SVGSVGElement {
    return screen.getByTestId('sidebar-collapse-toggle').querySelector('svg')!
  }

  it('draws a panel, not a bare stroke, so the icon depicts what it acts on', async () => {
    renderSidebar()
    await screen.findByRole('link', { name: 'Agents' })

    const svg = toggleGlyph()
    expect(svg.querySelector('rect')).not.toBeNull()
    expect(svg.innerHTML).toContain('M9 4v16')
    expect(svg).toHaveAttribute('aria-hidden', 'true')
  })

  it('points the chevron the way the rail will travel, and flips it', async () => {
    const user = userEvent.setup()
    renderSidebar()
    await screen.findByRole('link', { name: 'Agents' })

    const expandedGlyph = toggleGlyph().innerHTML
    expect(expandedGlyph).toContain('m16.5 9.5-2.5 2.5 2.5 2.5')

    await user.click(screen.getByTestId('sidebar-collapse-toggle'))

    const collapsedGlyph = toggleGlyph().innerHTML
    expect(collapsedGlyph).toContain('m14 9.5 2.5 2.5-2.5 2.5')
    expect(collapsedGlyph).not.toBe(expandedGlyph)
    expect(toggleGlyph().querySelector('rect')).not.toBeNull()
  })

  it('keeps its name, tooltip and aria-expanded truthful in both states', async () => {
    const user = userEvent.setup()
    renderSidebar()
    await screen.findByRole('link', { name: 'Agents' })

    const toggle = screen.getByTestId('sidebar-collapse-toggle')
    expect(toggle).toHaveAccessibleName('Collapse sidebar')
    expect(toggle).toHaveAttribute('title', 'Collapse sidebar')
    expect(toggle).toHaveAttribute('aria-expanded', 'true')
    expect(toggle).toHaveAttribute('aria-controls', 'sl-sidebar-nav')

    await user.click(toggle)

    expect(toggle).toHaveAccessibleName('Expand sidebar')
    expect(toggle).toHaveAttribute('title', 'Expand sidebar')
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    expect(document.getElementById('sl-sidebar-nav')).not.toBeNull()
  })

  it('does not collide with the nav glyphs it sits above', async () => {
    renderSidebar()
    await screen.findByRole('link', { name: 'Agents' })

    const navGlyphs = screen.getAllByRole('link').map((link) => link.querySelector('svg')?.innerHTML)
    expect(navGlyphs).not.toContain(toggleGlyph().innerHTML)
  })
})

describe('Sidebar brand mark', () => {
  const LOGO_SRC = '/brand/signal-loom-logo.png'

  function workspaceButton() {
    return screen.getByRole('button', { name: /Acme Insurance/ })
  }

  beforeEach(() => {
    installMemoryStorage()
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
  })

  it('renders the Signal Loom mark inside the workspace button', async () => {
    renderSidebar()
    await waitFor(() => expect(screen.getByText('Acme Insurance')).toBeInTheDocument())

    const logo = workspaceButton().querySelector('img')
    expect(logo).not.toBeNull()
    expect(logo).toHaveAttribute('src', LOGO_SRC)
  })

  it('keeps the mark decorative so the button has exactly one accessible name', async () => {
    renderSidebar()
    await waitFor(() => expect(screen.getByText('Acme Insurance')).toBeInTheDocument())

    const button = workspaceButton()
    const logo = button.querySelector('img')!

    expect(logo).toHaveAttribute('alt', '')
    expect(logo).toHaveAttribute('aria-hidden', 'true')
    expect(logo).not.toHaveAttribute('title')
    expect(screen.queryAllByRole('img')).toHaveLength(0)
    expect(screen.getAllByRole('button', { name: /Acme Insurance/ })).toHaveLength(1)
    expect(button.textContent?.match(/Acme Insurance/g)).toHaveLength(1)
  })

  it('reserves a square 32px box so the mark is never stretched', async () => {
    renderSidebar()
    await waitFor(() => expect(screen.getByText('Acme Insurance')).toBeInTheDocument())

    const logo = workspaceButton().querySelector('img')! as HTMLImageElement
    expect(logo).toHaveAttribute('width', '32')
    expect(logo).toHaveAttribute('height', '32')
    expect(logo.style.objectFit).toBe('contain')
    expect(logo.style.flexShrink).toBe('0')
  })

  it('still shows the mark when the rail is collapsed to icons only', async () => {
    const user = userEvent.setup()
    renderSidebar()
    await waitFor(() => expect(screen.getByText('Acme Insurance')).toBeInTheDocument())

    await user.click(screen.getByTestId('sidebar-collapse-toggle'))

    expect(screen.queryByText('Agent governance workspace')).not.toBeInTheDocument()
    const button = screen.getByRole('button', { name: 'Acme Insurance' })
    expect(button.querySelector('img')).toHaveAttribute('src', LOGO_SRC)
    expect(screen.queryAllByRole('img')).toHaveLength(0)
  })
})

describe('Sidebar Design System nav entry', () => {
  beforeEach(() => {
    installMemoryStorage()
    authMock.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
  })

  afterEach(() => {
    authMock.user = { ...DEFAULT_USER }
  })

  it('is declared superadmin-only and owns an icon kind no other item uses', () => {
    const item = NAV.find(({ to }) => to === '/design-system')
    expect(item).toBeDefined()
    expect(item!.label).toBe('Design System')
    expect(item!.superadminOnly).toBe(true)
    expect(NAV.filter(({ icon }) => icon === item!.icon)).toHaveLength(1)
  })

  it('renders in the superadmin block, with a glyph, when superadmin is on', async () => {
    renderSidebar({ superadmin: true })

    const link = await screen.findByRole('link', { name: 'Design System' })
    expect(link).toHaveAttribute('href', '/design-system')
    expect(link.querySelector('svg')).toBeInTheDocument()
  })

  it('is hidden when superadmin is off — it is an internal surface', async () => {
    renderSidebar({ superadmin: false })
    await screen.findByRole('link', { name: 'Agents' })

    expect(screen.queryByRole('link', { name: 'Design System' })).not.toBeInTheDocument()
  })
})

describe('Sidebar selection highlight', () => {
  const SUPERADMIN_ROUTES = [
    '/cryptography',
    '/credential-inventory',
    '/federated-services',
    '/collusion-access',
    '/rbac-analysis',
    '/rbac-explorer',
    '/network-tests',
    '/supercred',
    '/signal-fusion',
    '/design-system',
  ]

  const ROW_ORIGIN = 100
  const ROW_PITCH = 40
  const ROW_HEIGHT = 34
  let rectSpy: ReturnType<typeof vi.spyOn> | null = null

  function domRect(top: number, height: number): DOMRect {
    return {
      top, height, bottom: top + height, left: 0, right: 0, width: 0, x: 0, y: top,
      toJSON: () => ({}),
    } as DOMRect
  }

  function navRegion(): HTMLElement {
    return document.getElementById('sl-sidebar-nav')!
  }

  function navLinks(): HTMLAnchorElement[] {
    return Array.from(navRegion().querySelectorAll('a'))
  }

  function link(href: string): HTMLAnchorElement {
    const found = navRegion().querySelector<HTMLAnchorElement>(`a[href="${href}"]`)
    expect(found, `no nav link for ${href}`).not.toBeNull()
    return found!
  }

  function expectedTop(href: string): string {
    return `${ROW_ORIGIN + navLinks().indexOf(link(href)) * ROW_PITCH}px`
  }

  function selection(): HTMLElement | null {
    return navRegion().querySelector<HTMLElement>('.sl-sidebar__selection')
  }

  function selectedHrefs(): string[] {
    const box = selection()
    const boxed = box?.dataset.navTo
    const classed = Array.from(navRegion().querySelectorAll<HTMLAnchorElement>('a.sl-sidebar__link--active'))
      .map((a) => a.getAttribute('href')!)
    const current = Array.from(navRegion().querySelectorAll<HTMLAnchorElement>('a[aria-current="page"]'))
      .map((a) => a.getAttribute('href')!)
    return Array.from(new Set([...(boxed ? [boxed] : []), ...classed, ...current]))
  }

  function renderAt(entry: string, ctx: Partial<typeof appCtxValue> = {}) {
    return render(
      <MemoryRouter initialEntries={[entry]}>
        <AppContext.Provider value={{ ...appCtxValue, ...ctx }}>
          <Sidebar />
        </AppContext.Provider>
      </MemoryRouter>
    )
  }

  beforeEach(() => {
    installMemoryStorage()
    authMock.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    rectSpy = vi.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(function (this: Element) {
      const nav = document.getElementById('sl-sidebar-nav')
      if (!nav) return domRect(0, 0)
      if (this === nav) return domRect(0, 1000)
      const index = Array.from(nav.querySelectorAll('a')).indexOf(this as HTMLAnchorElement)
      return index === -1 ? domRect(0, 0) : domRect(ROW_ORIGIN + index * ROW_PITCH - nav.scrollTop, ROW_HEIGHT)
    })
  })

  afterEach(() => {
    rectSpy?.mockRestore()
    rectSpy = null
    authMock.user = { ...DEFAULT_USER }
  })

  it.each(SUPERADMIN_ROUTES)('shows exactly one selected row on %s', async (route) => {
    renderAt(route, { superadmin: true })
    await screen.findByRole('link', { name: 'Agents' })

    expect(selectedHrefs()).toEqual([route])
    expect(selection()!.style.top).toBe(expectedTop(route))
    expect(selection()!.style.height).toBe(`${ROW_HEIGHT}px`)
  })

  it.each(['/overview', '/agents', '/audit', '/topology', '/settings'])(
    'shows exactly one selected row on %s with the superadmin block open',
    async (route) => {
      renderAt(route, { superadmin: true })
      await screen.findByRole('link', { name: 'Agents' })

      expect(selectedHrefs()).toEqual([route])
      expect(selection()!.style.top).toBe(expectedTop(route))
    },
  )

  it('leaves no stale highlight going from a normal route to a superadmin one', async () => {
    renderAt('/agents', { superadmin: true })
    await screen.findByRole('link', { name: 'Agents' })
    const agentsTop = expectedTop('/agents')
    expect(selection()!.style.top).toBe(agentsTop)

    fireEvent.click(link('/cryptography'))

    await waitFor(() => expect(link('/cryptography')).toHaveAttribute('aria-current', 'page'))
    expect(selectedHrefs()).toEqual(['/cryptography'])
    expect(selection()!.style.top).not.toBe(agentsTop)
    expect(selection()!.style.top).toBe(expectedTop('/cryptography'))
    expect(link('/agents')).not.toHaveClass('sl-sidebar__link--active')
  })

  it('leaves no stale highlight going from a superadmin route back to a normal one', async () => {
    renderAt('/cryptography', { superadmin: true })
    await screen.findByRole('link', { name: 'Agents' })
    const cryptoTop = expectedTop('/cryptography')
    expect(selection()!.style.top).toBe(cryptoTop)

    fireEvent.click(link('/agents'))

    await waitFor(() => expect(link('/agents')).toHaveAttribute('aria-current', 'page'))
    expect(selectedHrefs()).toEqual(['/agents'])
    expect(selection()!.style.top).not.toBe(cryptoTop)
    expect(selection()!.style.top).toBe(expectedTop('/agents'))
    expect(link('/cryptography')).not.toHaveClass('sl-sidebar__link--active')
  })

  it('walks every superadmin route in turn without accumulating highlights', async () => {
    renderAt('/agents', { superadmin: true })
    await screen.findByRole('link', { name: 'Agents' })

    for (const route of SUPERADMIN_ROUTES) {
      fireEvent.click(link(route))
      await waitFor(() => expect(link(route)).toHaveAttribute('aria-current', 'page'))
      expect(selectedHrefs()).toEqual([route])
      expect(selection()!.style.top).toBe(expectedTop(route))
    }
  })

  it('tracks superadmin rows while collapsed', async () => {
    const user = userEvent.setup()
    renderAt('/agents', { superadmin: true })
    await screen.findByRole('link', { name: 'Agents' })

    await user.click(screen.getByTestId('sidebar-collapse-toggle'))
    fireEvent.click(link('/network-tests'))

    await waitFor(() => expect(link('/network-tests')).toHaveAttribute('aria-current', 'page'))
    expect(selectedHrefs()).toEqual(['/network-tests'])
    expect(selection()!.style.top).toBe(expectedTop('/network-tests'))
  })

  it('previews a hovered superadmin row and returns to the active one', async () => {
    renderAt('/agents', { superadmin: true })
    await screen.findByRole('link', { name: 'Agents' })

    fireEvent.mouseEnter(link('/rbac-explorer'))
    expect(selection()!.style.top).toBe(expectedTop('/rbac-explorer'))
    expect(selection()!.dataset.navTo).toBe('/rbac-explorer')

    fireEvent.mouseLeave(link('/rbac-explorer'))
    expect(selection()!.style.top).toBe(expectedTop('/agents'))
  })

  it('withdraws the highlight when the active row is filtered out of the rail', async () => {
    renderAt('/agents', { superadmin: true })
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })
    expect(selection()).not.toBeNull()

    fireEvent.change(search, { target: { value: 'audit' } })

    expect(selectedHrefs()).toEqual([])
    expect(selection()).toBeNull()
  })

  it('re-seats the highlight on the active row once the filter is cleared', async () => {
    renderAt('/agents', { superadmin: true })
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    fireEvent.change(search, { target: { value: 'agent' } })
    expect(selectedHrefs()).toEqual(['/agents'])
    expect(selection()!.style.top).toBe(expectedTop('/agents'))

    fireEvent.change(search, { target: { value: '' } })
    expect(selectedHrefs()).toEqual(['/agents'])
    expect(selection()!.style.top).toBe(expectedTop('/agents'))
  })

  it('withdraws the highlight when the active route is hidden behind the superadmin flag', async () => {
    renderAt('/cryptography', { superadmin: false })
    await screen.findByRole('link', { name: 'Agents' })

    expect(selectedHrefs()).toEqual([])
    expect(selection()).toBeNull()
  })

  it('seats the highlight when the superadmin block opens onto the active route', async () => {
    const { rerender } = render(
      <MemoryRouter initialEntries={['/cryptography']}>
        <AppContext.Provider value={{ ...appCtxValue, superadmin: false }}>
          <Sidebar />
        </AppContext.Provider>
      </MemoryRouter>
    )
    await screen.findByRole('link', { name: 'Agents' })
    expect(selection()).toBeNull()

    rerender(
      <MemoryRouter initialEntries={['/cryptography']}>
        <AppContext.Provider value={{ ...appCtxValue, superadmin: true }}>
          <Sidebar />
        </AppContext.Provider>
      </MemoryRouter>
    )

    expect(selectedHrefs()).toEqual(['/cryptography'])
    expect(selection()!.style.top).toBe(expectedTop('/cryptography'))
  })

  it('seats the highlight in content coordinates when the rail is scrolled', async () => {
    renderAt('/agents', { superadmin: true })
    await screen.findByRole('link', { name: 'Agents' })

    Object.defineProperty(navRegion(), 'scrollTop', { value: 120, configurable: true })
    fireEvent.click(link('/cryptography'))

    await waitFor(() => expect(link('/cryptography')).toHaveAttribute('aria-current', 'page'))
    expect(selection()!.style.top).toBe(expectedTop('/cryptography'))
  })

  it('keeps digit-shortcut badges off superadmin rows even when hovered', async () => {
    renderAt('/agents', { superadmin: true })
    await screen.findByRole('link', { name: 'Agents' })

    fireEvent.mouseEnter(link('/cryptography'))
    expect(link('/cryptography').querySelector('.sl-sidebar__shortcut')).toBeNull()
    expect(link('/cryptography').textContent).toBe('Cryptography')

    fireEvent.mouseEnter(link('/agents'))
    expect(link('/agents').querySelector('.sl-sidebar__shortcut')).toHaveTextContent('2')
  })
})

