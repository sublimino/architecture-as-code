import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import type { ReactNode } from 'react'
import App, { routeLoadingLabel, SuperadminRoute } from './App'
import { NAV } from './components/Sidebar'
import { FeatureFlagProvider, clearFeatureFlagCache } from './providers/FeatureFlagProvider'
import * as featuresApi from './api/featuresApi'


// The bug this file pins: clicking Compliance showed a rotating ring (App's
// own private `Spinner`) while the route chunk downloaded, and only then the
// Signal Loom loader once the page mounted. Two loading idioms back to back.
// The Signal Loom mark is now the only one, at both of App's waits.


const auth = vi.hoisted(() => ({
  isAuthenticated: true,
  isLoading: false,
  user: { name: 'Test User', email: 'test@acme.com' } as Record<string, unknown> | null,
  // Never resolves: App's onboarding/consent effects both start by awaiting a
  // token, so a pending promise keeps every post-mount setState from firing
  // and the tree under test stays exactly as rendered.
  getAccessTokenSilently: () => new Promise<string>(() => {}),
  loginWithRedirect: () => undefined,
}))

const featuresMock = vi.hoisted(() => ({
  flags: {
    core_governance: true,
    audit: true,
    compliance: true,
    demos_fleet: false,
    supercred: false,
    rbac_analysis: false,
    collusion_access: false,
  } as Record<string, boolean>,
}))

vi.mock('./api/featuresApi', () => ({
  fetchFeatures: vi.fn(async () => ({
    tenant_id: 'test-tenant',
    flags: { ...featuresMock.flags },
  })),
}))

vi.mock('./auth/oidc', () => ({ useAuth0: () => auth }))

// The onboarding gate has its own suite (ProtectedRoute.test.tsx). Here it
// would only stand between the router and the Suspense boundary under test.
vi.mock('./auth/ProtectedRoute', () => ({
  default: ({ children }: { children: ReactNode }) => <>{children}</>,
}))

// Sidebar is stubbed for its render only: NAV is where the loading labels
// come from, so the real export has to survive the mock.
vi.mock('./components/Sidebar', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./components/Sidebar')>()),
  default: () => <nav data-testid="sidebar" />,
}))
vi.mock('./components/DemoToggle', () => ({ default: () => null }))
vi.mock('./components/ThemeToggle', () => ({ default: () => null }))
vi.mock('./components/WidthToggle', () => ({ default: () => null }))
vi.mock('./components/KeyboardShortcutsOverlay', () => ({ default: () => null }))

// React.lazy caches: a chunk resolves once and every later mount of that route
// is synchronous, so a route whose module settles can only be observed
// suspending by the first test that touches it. These two never settle, which
// holds the fallback up for as many renders as the suite needs, and does it
// through the genuine pending-import path rather than a hand-thrown thenable.
vi.mock('./pages/CompliancePage', () => new Promise<never>(() => {}))
vi.mock('./pages/DiscoveryAccountDetailPage', () => new Promise<never>(() => {}))

// Settles, so the hand-over from fallback to page can be watched. Exactly one
// test may use this route, for the caching reason above.
vi.mock('./pages/AgentDetailPage', () => ({ default: () => <div>Agent detail page</div> }))
vi.mock('./pages/FleetDemoPage', () => ({ default: () => <div data-testid="fleet-demo-page">Fleet Demo Page</div> }))
vi.mock('./pages/SuperCredPage', () => ({ default: () => <div data-testid="supercred-page">SuperCred Page</div> }))
vi.mock('./pages/RbacAnalysisPage', () => ({ default: () => <div data-testid="rbac-analysis-page">Rbac Analysis Page</div> }))
vi.mock('./pages/RbacExplorerPage', () => ({ default: () => <div data-testid="rbac-explorer-page">Rbac Explorer Page</div> }))
vi.mock('./pages/CollusionAccessPage', () => ({ default: () => <div data-testid="collusion-access-page">Collusion Access Page</div> }))
vi.mock('./pages/DiscoveryPage', () => ({ default: () => <div data-testid="discovery-page">Discovery Page</div> }))

/**
 * The markers of the ring that used to render here: its keyframe, and the
 * `rotate(360deg)` that keyframe drove.
 */
function ringMarkup(): string[] {
  return ['rotate(360deg)', '@keyframes spin', 'onboarding-spin'].filter((m) =>
    document.body.innerHTML.includes(m),
  )
}

/** Every element that would announce. There must never be more than one. */
function liveRegions(): Element[] {
  return Array.from(document.querySelectorAll('[aria-live], [role="status"], [role="alert"]'))
}

function renderAt(path: string) {
  return render(
    <FeatureFlagProvider initialFlags={featuresMock.flags} disableAutoFetch>
      <MemoryRouter initialEntries={[path]}>
        <App />
      </MemoryRouter>
    </FeatureFlagProvider>,
  )
}

beforeEach(() => {
  clearFeatureFlagCache()
  featuresMock.flags = {
    core_governance: true,
    audit: true,
    compliance: true,
    demos_fleet: false,
    supercred: false,
    rbac_analysis: false,
    collusion_access: false,
  }
  auth.isAuthenticated = true
  auth.isLoading = false
  auth.user = { name: 'Test User', email: 'test@acme.com' }
  auth.getAccessTokenSilently = () => new Promise<string>(() => {})
})

describe('routeLoadingLabel', () => {
  it('names the page, so the fallback says what is loading', () => {
    expect(routeLoadingLabel('/compliance')).toBe('Loading Compliance')
    expect(routeLoadingLabel('/agents')).toBe('Loading Agents')
    expect(routeLoadingLabel('/settings')).toBe('Loading Settings')
  })

  it('matches exact routes before parameterised ones', () => {
    // The trap: `/compliance/:frameworkId` matches `/compliance/policies` too,
    // so a naive first-match walk labels the Policy Compliance page "Framework".
    expect(routeLoadingLabel('/compliance/policies')).toBe('Loading Policy Compliance')
    expect(routeLoadingLabel('/compliance/posture')).toBe('Loading Agent Posture')
    expect(routeLoadingLabel('/compliance/risk')).toBe('Loading Risk Exposure')
    expect(routeLoadingLabel('/compliance/soc2')).toBe('Loading Framework')

    expect(routeLoadingLabel('/fleet')).toBe('Loading Fleet Demo')
    expect(routeLoadingLabel('/fleet/audience')).toBe('Loading Fleet Demo Audience')
  })

  it('labels the detail routes that are not in the nav', () => {
    expect(routeLoadingLabel('/agents/agt-42')).toBe('Loading Agent')
    expect(routeLoadingLabel('/discovery/accounts/acc-7')).toBe('Loading Account')
    expect(routeLoadingLabel('/help/connectors/github')).toBe('Loading Connector Help')
    expect(routeLoadingLabel('/settings/help/deploy-sensor')).toBe('Loading Deploy Sensor Help')
    expect(routeLoadingLabel('/settings/help/onboard-agent')).toBe('Loading Onboard Agent Help')
    expect(routeLoadingLabel('/onboarding')).toBe('Loading Setup')
    expect(routeLoadingLabel('/redeem-invite')).toBe('Loading Invite')
  })

  it('gives every nav destination a name of its own', () => {
    // A nav item added without a label here would silently fall through to the
    // bare "Loading": the exact wording this change exists to get rid of.
    for (const item of NAV) {
      expect(routeLoadingLabel(item.to)).toBe(`Loading ${item.label}`)
    }
  })

  it('falls back to honest generic wording for an unrecognised path', () => {
    expect(routeLoadingLabel('/nothing-here')).toBe('Loading')
  })
})

describe('App route Suspense fallback', () => {
  it('draws the Signal Loom mark, not a rotating ring', () => {
    // Synchronous: React.lazy resolves in a microtask, which cannot run inside
    // render's act(), so this is the genuine fallback of the genuine lazy path.
    renderAt('/compliance')

    const loader = screen.getByTestId('route-loading')
    expect(loader.querySelector('[data-loom-weave]')).not.toBeNull()
    expect(ringMarkup()).toEqual([])
  })

  it('names the page it is loading', () => {
    renderAt('/compliance')
    expect(screen.getByTestId('route-loading-label')).toHaveTextContent('Loading Compliance')
  })

  it('derives the label per route rather than saying the same thing everywhere', () => {
    renderAt('/discovery/accounts/acc-7')
    expect(screen.getByTestId('route-loading-label')).toHaveTextContent('Loading Account')
  })

  it('owns exactly one live region', () => {
    renderAt('/compliance')
    expect(liveRegions()).toHaveLength(1)
    expect(screen.getByTestId('route-loading')).toHaveAttribute('aria-live', 'polite')
  })

  it('hands over to the page and leaves nothing behind', async () => {
    renderAt('/agents/agt-42')
    expect(screen.getByTestId('route-loading')).toBeInTheDocument()

    await waitFor(() => expect(screen.getByText('Agent detail page')).toBeInTheDocument())
    expect(screen.queryByTestId('route-loading')).toBeNull()
    expect(ringMarkup()).toEqual([])
  })
})

describe('App auth gate', () => {
  it('draws the Signal Loom mark while the session resolves', () => {
    auth.isLoading = true
    renderAt('/compliance')

    const loader = screen.getByTestId('auth-loading')
    expect(loader.querySelector('[data-loom-weave]')).not.toBeNull()
    expect(ringMarkup()).toEqual([])
  })

  it('says what is happening, not "Loading"', () => {
    auth.isLoading = true
    renderAt('/compliance')
    expect(screen.getByTestId('auth-loading-label')).toHaveTextContent('Signing in')
  })

  it('owns exactly one live region', () => {
    auth.isLoading = true
    renderAt('/compliance')
    expect(liveRegions()).toHaveLength(1)
  })
})

describe('SuperadminRoute route guards', () => {
  it('redirects unauthorized standard users to /agents', () => {
    auth.user = { name: 'Standard User', email: 'user@example.com' }

    render(
      <MemoryRouter initialEntries={['/protected-demo']}>
        <Routes>
          <Route
            path="/protected-demo"
            element={
              <SuperadminRoute>
                <div>Sensitive Demo Content</div>
              </SuperadminRoute>
            }
          />
          <Route path="/agents" element={<div>Agents Fallback Page</div>} />
        </Routes>
      </MemoryRouter>,
    )

    expect(screen.queryByText('Sensitive Demo Content')).not.toBeInTheDocument()
    expect(screen.getByText('Agents Fallback Page')).toBeInTheDocument()
  })

  it('renders protected content when user is superadmin eligible', () => {
    auth.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }

    render(
      <MemoryRouter initialEntries={['/protected-demo']}>
        <Routes>
          <Route
            path="/protected-demo"
            element={
              <SuperadminRoute>
                <div>Sensitive Demo Content</div>
              </SuperadminRoute>
            }
          />
          <Route path="/agents" element={<div>Agents Fallback Page</div>} />
        </Routes>
      </MemoryRouter>,
    )

    expect(screen.getByText('Sensitive Demo Content')).toBeInTheDocument()
    expect(screen.queryByText('Agents Fallback Page')).not.toBeInTheDocument()
  })
})

describe('FeatureGate route guards and NotFound fallback', () => {
  it('renders NotFound (404) on direct navigation to /fleet when demos_fleet is disabled', async () => {
    auth.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }
    auth.getAccessTokenSilently = () => Promise.resolve('test-token')
    featuresMock.flags.demos_fleet = false

    renderAt('/fleet')

    await waitFor(() => expect(screen.getByTestId('not-found')).toBeInTheDocument())
    expect(screen.getByText('404')).toBeInTheDocument()
    expect(screen.getByText('Page Not Found')).toBeInTheDocument()
    expect(screen.queryByTestId('fleet-demo-page')).toBeNull()
  })

  it('renders FleetDemoPage on direct navigation to /fleet when demos_fleet is enabled', async () => {
    auth.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }
    auth.getAccessTokenSilently = () => Promise.resolve('test-token')
    featuresMock.flags.demos_fleet = true

    renderAt('/fleet')

    await waitFor(() => expect(screen.getByTestId('fleet-demo-page')).toBeInTheDocument())
    expect(screen.queryByTestId('not-found')).toBeNull()
  })

  it('renders NotFound (404) on direct navigation to /supercred when supercred is disabled', async () => {
    auth.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }
    auth.getAccessTokenSilently = () => Promise.resolve('test-token')
    featuresMock.flags.supercred = false

    renderAt('/supercred')

    await waitFor(() => expect(screen.getByTestId('not-found')).toBeInTheDocument())
    expect(screen.queryByTestId('supercred-page')).toBeNull()
  })

  it('renders SuperCredPage on direct navigation to /supercred when supercred is enabled', async () => {
    auth.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }
    auth.getAccessTokenSilently = () => Promise.resolve('test-token')
    featuresMock.flags.supercred = true

    renderAt('/supercred')

    await waitFor(() => expect(screen.getByTestId('supercred-page')).toBeInTheDocument())
    expect(screen.queryByTestId('not-found')).toBeNull()
  })

  it('renders NotFound (404) on direct navigation to /rbac-analysis when rbac_analysis is disabled', async () => {
    auth.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }
    auth.getAccessTokenSilently = () => Promise.resolve('test-token')
    featuresMock.flags.rbac_analysis = false

    renderAt('/rbac-analysis')

    await waitFor(() => expect(screen.getByTestId('not-found')).toBeInTheDocument())
    expect(screen.queryByTestId('rbac-analysis-page')).toBeNull()
  })

  it('renders RbacAnalysisPage on direct navigation to /rbac-analysis when rbac_analysis is enabled', async () => {
    auth.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }
    auth.getAccessTokenSilently = () => Promise.resolve('test-token')
    featuresMock.flags.rbac_analysis = true

    renderAt('/rbac-analysis')

    await waitFor(() => expect(screen.getByTestId('rbac-analysis-page')).toBeInTheDocument())
    expect(screen.queryByTestId('not-found')).toBeNull()
  })

  it('renders NotFound (404) on direct navigation to /collusion-access when collusion_access is disabled', async () => {
    auth.user = { name: 'Standard User', email: 'user@acme.com' }
    auth.getAccessTokenSilently = () => Promise.resolve('test-token')
    featuresMock.flags.collusion_access = false

    renderAt('/collusion-access')

    await waitFor(() => expect(screen.getByTestId('not-found')).toBeInTheDocument())
    expect(screen.queryByTestId('collusion-access-page')).toBeNull()
  })

  it('renders CollusionAccessPage on direct navigation to /collusion-access when collusion_access is enabled', async () => {
    auth.user = { name: 'Standard User', email: 'user@acme.com' }
    auth.getAccessTokenSilently = () => Promise.resolve('test-token')
    featuresMock.flags.collusion_access = true

    renderAt('/collusion-access')

    await waitFor(() => expect(screen.getByTestId('collusion-access-page')).toBeInTheDocument())
    expect(screen.queryByTestId('not-found')).toBeNull()
  })

  it('renders NotFound (404) on direct navigation to /discovery when page_discovery is disabled', async () => {
    auth.user = { name: 'Standard User', email: 'user@acme.com' }
    auth.getAccessTokenSilently = () => Promise.resolve('test-token')
    featuresMock.flags.page_discovery = false

    renderAt('/discovery')

    await waitFor(() => expect(screen.getByTestId('not-found')).toBeInTheDocument())
    expect(screen.queryByTestId('discovery-page')).toBeNull()
  })

  it('renders DiscoveryPage on direct navigation to /discovery when page_discovery is enabled', async () => {
    auth.user = { name: 'Standard User', email: 'user@acme.com' }
    auth.getAccessTokenSilently = () => Promise.resolve('test-token')
    featuresMock.flags.page_discovery = true

    renderAt('/discovery')

    await waitFor(() => expect(screen.getByTestId('discovery-page')).toBeInTheDocument())
    expect(screen.queryByTestId('not-found')).toBeNull()
  })

  it('renders AppLoader and does NOT render 404 while feature flags are resolving', async () => {
    auth.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }
    auth.getAccessTokenSilently = () => Promise.resolve('test-token')

    let resolveFetch: (val: any) => void
    const pendingFetch = new Promise((resolve) => {
      resolveFetch = resolve
    })

    const fetchFeaturesMock = vi.spyOn(featuresApi, 'fetchFeatures').mockReturnValue(pendingFetch as any)

    render(
      <FeatureFlagProvider initialFlags={{ page_discovery: false }} disableAutoFetch={false} tenantId="slow-tenant">
        <MemoryRouter initialEntries={['/discovery']}>
          <App />
        </MemoryRouter>
      </FeatureFlagProvider>,
    )

    // While features are loading, AppLoader must be visible, NOT 404!
    expect(screen.getByTestId('route-loading')).toBeInTheDocument()
    expect(screen.queryByTestId('not-found')).toBeNull()

    // Resolve fetch before test teardown
    await waitFor(async () => {
      resolveFetch!({ tenant_id: 'slow-tenant', flags: { page_discovery: true } })
    })

    fetchFeaturesMock.mockRestore()
  })
})


