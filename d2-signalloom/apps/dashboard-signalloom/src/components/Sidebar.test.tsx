import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { installMemoryStorage } from '../test-utils/memoryStorage'

// The sidebar only reads `user` and `logout` off the auth shim.
const auth: { user: Record<string, unknown> | undefined } = { user: undefined }
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    user: auth.user,
    logout: vi.fn(),
    getAccessTokenSilently: vi.fn().mockResolvedValue('test-token'),
  }),
}))

import Sidebar from './Sidebar'
import { AppContext } from '../App'
import { SUPERADMIN_STORAGE_KEY, useSuperadmin } from '../auth/superadmin'

const DEMO_USER = { email: 'demo-user@signalloom.local' }
const GATED_PATHS = [
  '/cryptography',
  '/federated-services',
  '/collusion-access',
  '/rbac-analysis',
  '/rbac-explorer',
]
const UNGATED_PATHS = ['/agents', '/compliance', '/audit', '/supercred', '/settings']

// Mirrors the provider in App.tsx so the sidebar exercises the real
// superadmin state hook (including its localStorage persistence).
function Harness() {
  const [superadmin, setSuperadmin] = useSuperadmin()
  return (
    <AppContext.Provider
      value={{
        failingControls: 0,
        setFailingControls: () => undefined,
        helpOpen: false,
        setHelpOpen: () => undefined,
        apiKeyReveal: null,
        setApiKeyReveal: () => undefined,
        cookieSettingsOpen: false,
        setCookieSettingsOpen: () => undefined,
        superadmin,
        setSuperadmin,
      }}
    >
      <Sidebar />
    </AppContext.Provider>
  )
}

function renderSidebar() {
  return render(
    <MemoryRouter>
      <Harness />
    </MemoryRouter>,
  )
}

function navPaths(): string[] {
  return screen
    .getAllByRole('link')
    .map((a) => a.getAttribute('href') ?? '')
}

// Fresh, empty localStorage per test — see test-utils/memoryStorage.ts for why
// the jsdom default is not usable here.
beforeEach(() => {
  installMemoryStorage()
  auth.user = undefined
})

describe('Sidebar superadmin toggle visibility', () => {
  it('is absent for a non-demo user', () => {
    auth.user = { email: 'auditor@bank.example', name: 'Auditor' }
    renderSidebar()
    expect(screen.queryByTestId('superadmin-toggle')).not.toBeInTheDocument()
  })

  it('is absent when there is no profile at all', () => {
    renderSidebar()
    expect(screen.queryByTestId('superadmin-toggle')).not.toBeInTheDocument()
  })

  it.each([
    ['email', { email: 'demo-user@signalloom.local' }],
    ['preferred_username', { preferred_username: 'demo-user' }],
    ['name', { name: 'demo-user' }],
  ])('is present for the demo user identified by %s', (_claim, user) => {
    auth.user = user
    renderSidebar()
    expect(screen.getByTestId('superadmin-toggle')).toBeInTheDocument()
  })

  it('sits next to the Help & Support control in the sidebar footer', () => {
    auth.user = DEMO_USER
    renderSidebar()
    const help = screen.getByRole('button', { name: 'Help & Support' })
    const toggle = screen.getByTestId('superadmin-toggle')
    expect(help.parentElement).toBe(toggle.parentElement)
  })
})

describe('Sidebar nav gating', () => {
  it('hides the five gated links by default and always shows the rest', () => {
    auth.user = DEMO_USER
    renderSidebar()

    const paths = navPaths()
    for (const p of GATED_PATHS) expect(paths).not.toContain(p)
    for (const p of UNGATED_PATHS) expect(paths).toContain(p)
  })

  it('shows the ungated links to a non-demo user and hides the gated ones', () => {
    auth.user = { email: 'auditor@bank.example' }
    renderSidebar()

    const paths = navPaths()
    for (const p of GATED_PATHS) expect(paths).not.toContain(p)
    for (const p of UNGATED_PATHS) expect(paths).toContain(p)
  })

  it('reveals all five gated links when the toggle is switched on', async () => {
    auth.user = DEMO_USER
    renderSidebar()

    await userEvent.click(screen.getByTestId('superadmin-toggle'))

    const paths = navPaths()
    for (const p of GATED_PATHS) expect(paths).toContain(p)
    for (const p of UNGATED_PATHS) expect(paths).toContain(p)
  })

  it('hides them again when the toggle is switched back off', async () => {
    auth.user = DEMO_USER
    renderSidebar()

    await userEvent.click(screen.getByTestId('superadmin-toggle'))
    await userEvent.click(screen.getByTestId('superadmin-toggle'))

    const paths = navPaths()
    for (const p of GATED_PATHS) expect(paths).not.toContain(p)
  })
})

describe('Sidebar superadmin persistence', () => {
  it('writes the namespaced localStorage key when toggled', async () => {
    auth.user = DEMO_USER
    renderSidebar()

    await userEvent.click(screen.getByTestId('superadmin-toggle'))
    expect(localStorage.getItem(SUPERADMIN_STORAGE_KEY)).toBe('true')

    await userEvent.click(screen.getByTestId('superadmin-toggle'))
    expect(localStorage.getItem(SUPERADMIN_STORAGE_KEY)).toBe('false')
  })

  it('restores the on state on remount', async () => {
    auth.user = DEMO_USER
    const first = renderSidebar()
    await userEvent.click(screen.getByTestId('superadmin-toggle'))
    expect(navPaths()).toContain('/rbac-explorer')
    first.unmount()

    renderSidebar()
    expect(navPaths()).toContain('/rbac-explorer')
  })

  it('keeps the gated links hidden for a non-demo user even when stored on', () => {
    // The identity gate wins over the stored preference.
    localStorage.setItem(SUPERADMIN_STORAGE_KEY, 'true')
    auth.user = { email: 'auditor@bank.example' }
    renderSidebar()

    expect(screen.queryByTestId('superadmin-toggle')).not.toBeInTheDocument()
    const paths = navPaths()
    for (const p of GATED_PATHS) expect(paths).not.toContain(p)
  })
})

describe('route registration is untouched', () => {
  it('still registers every gated path in App.tsx — this is visibility, not authorization', () => {
    // import.meta.url is an http:// URL under vite-node, so resolve from the
    // vitest root (the dashboard package directory) instead.
    const appSource = readFileSync(resolve(process.cwd(), 'src/App.tsx'), 'utf-8')
    for (const p of GATED_PATHS) {
      expect(appSource).toContain(`path="${p}"`)
    }
  })
})
