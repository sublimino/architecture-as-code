/**
 * Flag-configuration matrix: what a tenant can see under each account type, and
 * under every pairwise flag combination (scripts/flag-matrix.ts).
 *
 * For each configuration:
 *   - the sidebar shows a tenant nav item exactly when its flag is on;
 *   - the route behind it renders when the flag is on, and the 404 page when it
 *     is off (GatedRoute, the wrapper App.tsx uses for every gated page);
 * and, once, that App.tsx really wraps each of those routes in GatedRoute with
 * the flag the contract names, so the behaviour above is the app's behaviour.
 *
 * Design: docs/signalloom/feature-flag-account-types.md ("How we test flag
 * configurations").
 */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { cleanup, render, screen, within } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { pairwiseRows, uncoveredPairs } from '../../scripts/flag-matrix'
import { AppContext, GatedRoute } from '../App'
import { FeatureFlagProvider } from '../providers/FeatureFlagProvider'
import { ACCOUNT_TYPES } from '../types/accountTypes'
import { DEFAULT_SYSTEM_FLAGS } from '../types/features'
import Sidebar from './Sidebar'

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    user: { name: 'Tenant User', email: 'user@tenant.example' },
    logout: vi.fn(),
    getAccessTokenSilently: vi.fn().mockResolvedValue('test-token'),
  }),
}))

vi.mock('../api/client', () => ({
  api: {
    // Never settle: the matrix asserts on flags alone, and a late settle is an
    // act() warning, not information.
    settings: vi.fn(() => new Promise(() => undefined)),
    nhi: { discovered: vi.fn(() => new Promise(() => undefined)) },
  },
}))

interface NavEntry { label: string; route: string; flag: string }

const CONTRACT: { tenant_nav: NavEntry[] } = JSON.parse(
  readFileSync(join(__dirname, '..', '..', '..', '..', 'contracts', 'feature-account-types.json'), 'utf8'),
)
const TENANT_NAV = CONTRACT.tenant_nav
const FLAG_KEYS = Object.keys(DEFAULT_SYSTEM_FLAGS)
const PAIRWISE = pairwiseRows(FLAG_KEYS)

const appCtx = {
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

const CONFIGS: [string, Record<string, boolean>][] = [
  ...ACCOUNT_TYPES.map((t): [string, Record<string, boolean>] => [`account type ${t.id}`, t.flags]),
  ...PAIRWISE.map((row, i): [string, Record<string, boolean>] => [`pairwise row ${i}`, row]),
]

afterEach(cleanup)

function renderSidebar(flags: Record<string, boolean>) {
  return render(
    <MemoryRouter>
      <AppContext.Provider value={appCtx}>
        <FeatureFlagProvider initialFlags={flags} disableAutoFetch>
          <Sidebar />
        </FeatureFlagProvider>
      </AppContext.Provider>
    </MemoryRouter>,
  )
}

function renderRoute(entry: NavEntry, flags: Record<string, boolean>) {
  return render(
    <MemoryRouter initialEntries={[entry.route]}>
      <AppContext.Provider value={appCtx}>
        <FeatureFlagProvider initialFlags={flags} disableAutoFetch>
          <Routes>
            <Route
              path={entry.route}
              element={<GatedRoute flag={entry.flag}><div data-testid="gated-page">{entry.label}</div></GatedRoute>}
            />
          </Routes>
        </FeatureFlagProvider>
      </AppContext.Provider>
    </MemoryRouter>,
  )
}

describe('pairwise matrix', () => {
  it('covers every value pair of every two registered flags', () => {
    expect(uncoveredPairs(FLAG_KEYS, PAIRWISE)).toEqual([])
  })

  it('is small and deterministic', () => {
    expect(PAIRWISE.length).toBe(8)
    expect(pairwiseRows(FLAG_KEYS)).toEqual(PAIRWISE)
  })
})

describe('App.tsx gates each tenant nav route on the contract flag', () => {
  const app = readFileSync(join(__dirname, '..', 'App.tsx'), 'utf8')
  it.each(TENANT_NAV)('$route is wrapped in GatedRoute flag="$flag"', ({ route, flag }) => {
    const line = app.split('\n').find((l) => l.includes(`path="${route}"`))
    expect(line, `no <Route path="${route}"> in App.tsx`).toBeDefined()
    expect(line).toContain(`<GatedRoute flag="${flag}">`)
  })
})

describe.each(CONFIGS)('%s', (_name, flags) => {
  it('sidebar shows exactly the tenant pages the flags enable', () => {
    renderSidebar(flags)
    const nav = screen.getByRole('navigation', { name: 'Primary navigation' })
    const shown = TENANT_NAV.filter((n) => within(nav).queryByRole('link', { name: n.label }) !== null).map((n) => n.label)
    expect(shown).toEqual(TENANT_NAV.filter((n) => flags[n.flag]).map((n) => n.label))
  })

  it('enabled routes render and disabled routes are unreachable (404)', () => {
    for (const entry of TENANT_NAV) {
      renderRoute(entry, flags)
      if (flags[entry.flag]) {
        expect(screen.getByTestId('gated-page'), entry.route).toBeInTheDocument()
        expect(screen.queryByTestId('not-found'), entry.route).toBeNull()
      } else {
        expect(screen.queryByTestId('gated-page'), entry.route).toBeNull()
        expect(screen.getByTestId('not-found'), entry.route).toBeInTheDocument()
      }
      cleanup()
    }
  })
})
