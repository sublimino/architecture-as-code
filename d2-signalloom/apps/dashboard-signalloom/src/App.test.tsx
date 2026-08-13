import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import type { ReactNode } from 'react'
import App, { routeLoadingLabel } from './App'
import { NAV } from './components/Sidebar'

// The bug this file pins: clicking Compliance showed a rotating ring (App's
// own private `Spinner`) while the route chunk downloaded, and only then the
// Signal Loom loader once the page mounted. Two loading idioms back to back.
// The Signal Loom mark is now the only one, at both of App's waits.

const auth = vi.hoisted(() => ({
  isAuthenticated: true,
  isLoading: false,
  // Never resolves: App's onboarding/consent effects both start by awaiting a
  // token, so a pending promise keeps every post-mount setState from firing
  // and the tree under test stays exactly as rendered.
  getAccessTokenSilently: () => new Promise<string>(() => {}),
  loginWithRedirect: () => undefined,
}))

vi.mock('./auth/oidc', () => ({ useAuth0: () => auth }))

// The onboarding gate has its own suite (ProtectedRoute.test.tsx). Here it
// would only stand between the router and the Suspense boundary under test.
vi.mock('./auth/ProtectedRoute', () => ({
  default: ({ children }: { children: ReactNode }) => <>{children}</>,
}))

// Sidebar is stubbed for its render only — NAV is where the loading labels
// come from, so the real export has to survive the mock.
vi.mock('./components/Sidebar', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./components/Sidebar')>()),
  default: () => <nav data-testid="sidebar" />,
}))
vi.mock('./components/DemoToggle', () => ({ default: () => null }))
vi.mock('./components/ThemeToggle', () => ({ default: () => null }))
vi.mock('./components/KeyboardShortcutsOverlay', () => ({ default: () => null }))

// React.lazy caches: a chunk resolves once and every later mount of that route
// is synchronous, so a route whose module settles can only be observed
// suspending by the first test that touches it. These two never settle, which
// holds the fallback up for as many renders as the suite needs — and does it
// through the genuine pending-import path rather than a hand-thrown thenable.
vi.mock('./pages/CompliancePage', () => new Promise<never>(() => {}))
vi.mock('./pages/DiscoveryAccountDetailPage', () => new Promise<never>(() => {}))

// Settles, so the hand-over from fallback to page can be watched. Exactly one
// test may use this route, for the caching reason above.
vi.mock('./pages/AgentDetailPage', () => ({ default: () => <div>Agent detail page</div> }))

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
    <MemoryRouter initialEntries={[path]}>
      <App />
    </MemoryRouter>,
  )
}

beforeEach(() => {
  auth.isAuthenticated = true
  auth.isLoading = false
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
    expect(routeLoadingLabel('/fleet/audience')).toBe('Loading Fleet Demo')
  })

  it('labels the detail routes that are not in the nav', () => {
    expect(routeLoadingLabel('/agents/agt-42')).toBe('Loading Agent')
    expect(routeLoadingLabel('/discovery/accounts/acc-7')).toBe('Loading Account')
    expect(routeLoadingLabel('/help/connectors/github')).toBe('Loading Connector Help')
    expect(routeLoadingLabel('/onboarding')).toBe('Loading Setup')
    expect(routeLoadingLabel('/redeem-invite')).toBe('Loading Invite')
  })

  it('gives every nav destination a name of its own', () => {
    // A nav item added without a label here would silently fall through to the
    // bare "Loading" — the exact wording this change exists to get rid of.
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
