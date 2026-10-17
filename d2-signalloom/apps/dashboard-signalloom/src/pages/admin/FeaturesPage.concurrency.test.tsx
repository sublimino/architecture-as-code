/**
 * Rapid toggling on the Feature Flags page with requests in flight (W24).
 *
 * Reported 2026-10-17: clicking many toggles quickly, with several requests in
 * flight at once, sometimes loses changes. This suite drives the real page, the
 * real React Query hooks and the real featuresApi functions; only axios is
 * replaced, by a fake server that commits each PUT the moment it arrives (the
 * backend serialises a tenant's flag writes) and whose replies the test then
 * delivers in an adversarial order: newest first, so every older reply lands
 * after a newer one.
 *
 * The page must
 *   - show each click at once and never flick back to an older value while
 *     replies are outstanding,
 *   - send each change as that flag's own desired value (a second click on the
 *     same flag is a change too, not a repeat of the first),
 *   - ignore replies older than what it already shows, and
 *   - end on exactly the server's final state, which is the union of the clicks.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import FeaturesPage from './FeaturesPage'
import { AppContext } from '../../App'
import { DEFAULT_SYSTEM_FLAGS } from '../../types/features'

vi.mock('../../auth/oidc', () => {
  // Stable identities: the page's token effect depends on them.
  const auth = {
    user: { email: 'admin@acme.com', name: 'Admin User' },
    getAccessTokenSilently: () => Promise.resolve('test-bearer-token'),
    token: 'test-bearer-token',
  }
  return { useAuth0: () => auth }
})

vi.mock('../../api/client', () => ({
  api: { settings: () => Promise.resolve({ tenant_id: 'kusari', org_name: 'Kusari Enterprise' }) },
}))

vi.mock('../../auth/superadmin', () => {
  const state = { superadmin: true, resolved: true }
  return { useServerSuperadmin: () => state }
})

// ─── Fake server ──────────────────────────────────────────────────────────────

type Flags = Record<string, boolean>
interface Reply {
  label: string
  deliver: () => void
}

const server = {
  flags: {} as Flags,
  version: 0,
  puts: [] as { flagKey: string; enabled: boolean }[],
  pending: [] as Reply[],
}

function snapshot() {
  return {
    tenant_id: 'kusari',
    version: server.version,
    flags: { ...server.flags },
    details: {},
    account_type: { id: null, customised: false, matches: null, label: 'Unassigned' },
  }
}

/** Hold a reply until the test delivers it; the state is captured now. */
function deferred<T>(label: string, body: T): Promise<{ data: T }> {
  return new Promise((resolve) => {
    server.pending.push({ label, deliver: () => resolve({ data: body }) })
  })
}

vi.mock('axios', () => {
  const get = (url: string) => {
    if (url.includes('/api/v1/admin/features/presets')) {
      return Promise.resolve({ data: { presets: [] } })
    }
    if (url.includes('/api/v1/admin/features')) {
      return deferred(`GET v${server.version}`, snapshot())
    }
    return Promise.reject(new Error(`unexpected GET ${url}`))
  }
  const put = (url: string, body: { enabled?: boolean }) => {
    const match = /\/api\/v1\/admin\/features\/([^?]+)\?/.exec(url)
    if (!match || typeof body.enabled !== 'boolean') {
      return Promise.reject(new Error(`unexpected PUT ${url}`))
    }
    const flagKey = decodeURIComponent(match[1])
    // Commit on arrival, exactly like the per-tenant serialised backend.
    server.flags[flagKey] = body.enabled
    server.version += 1
    server.puts.push({ flagKey, enabled: body.enabled })
    return deferred(`PUT ${flagKey}=${body.enabled} v${server.version}`, snapshot())
  }
  const unused = () => Promise.reject(new Error('unexpected request'))
  const instance = { get: unused, put: unused, post: unused, patch: unused, delete: unused }
  const axios = { get, put, post: unused, patch: unused, delete: unused, create: () => instance }
  return { default: axios, ...axios }
})

// ─── Helpers ─────────────────────────────────────────────────────────────────

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
  superadmin: true,
  setSuperadmin: () => undefined,
}

async function flush(): Promise<void> {
  await act(async () => {
    for (let i = 0; i < 5; i++) await Promise.resolve()
    await new Promise((r) => setTimeout(r, 0))
  })
}

/** Deliver the newest outstanding reply first, until none remain. */
async function deliverNewestFirst(onEach: () => void): Promise<string[]> {
  const order: string[] = []
  for (let guard = 0; server.pending.length > 0 && guard < 500; guard++) {
    const reply = server.pending.pop()!
    order.push(reply.label)
    await act(async () => reply.deliver())
    await flush()
    onEach()
  }
  return order
}

function shown(flagKey: string): boolean {
  return screen.getByTestId(`flag-toggle-${flagKey}`).getAttribute('aria-checked') === 'true'
}

const CLICKED = [
  'page_topology',
  'page_weave',
  'page_signals',
  'page_risk',
  'page_audit',
  'page_feeds',
  'page_network_tests',
  'page_agentmaxxing',
  'demos_fleet',
  'supercred',
]

describe('FeaturesPage under rapid toggling with replies out of order', () => {
  beforeEach(() => {
    server.flags = { ...DEFAULT_SYSTEM_FLAGS }
    server.version = 0
    server.puts = []
    server.pending = []
  })

  it('shows every click at once, never flicks back, and converges on the server state', async () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <AppContext.Provider value={appCtx}>
          <FeaturesPage defaultTenant="kusari" />
        </AppContext.Provider>
      </QueryClientProvider>,
    )
    await flush()
    await deliverNewestFirst(() => undefined) // the initial load
    expect(shown('page_topology')).toBe(DEFAULT_SYSTEM_FLAGS.page_topology)

    const initial: Flags = { ...DEFAULT_SYSTEM_FLAGS }
    const intended: Flags = { ...initial }

    // Ten different flags, then page_weave and page_risk a second time: twelve
    // clicks, none waiting for a reply.
    for (const key of [...CLICKED, 'page_weave', 'page_risk']) {
      fireEvent.click(screen.getByTestId(`flag-toggle-${key}`))
      intended[key] = !intended[key]
      await flush()
      // The click shows at once.
      expect(shown(key)).toBe(intended[key])
    }

    const assertShowsIntended = () => {
      for (const key of CLICKED) expect(shown(key), key).toBe(intended[key])
    }
    assertShowsIntended()

    // Newest reply first: every older reply arrives after a newer one.
    await deliverNewestFirst(assertShowsIntended)

    // The server ends on the union of the clicks: a flag clicked twice is back
    // where it started, every other clicked flag is flipped.
    expect(server.flags).toEqual(intended)
    expect(intended.page_weave).toBe(initial.page_weave)
    expect(intended.page_risk).toBe(initial.page_risk)

    // Each PUT carries one flag's desired value; the second click on a flag is
    // its own change, sent after the first was answered.
    expect(server.puts.filter((p) => p.flagKey === 'page_weave').map((p) => p.enabled)).toEqual([
      !initial.page_weave,
      initial.page_weave,
    ])

    // ...and the page shows exactly the server's final state.
    for (const key of Object.keys(server.flags)) {
      if (screen.queryByTestId(`flag-toggle-${key}`)) expect(shown(key), key).toBe(server.flags[key])
    }
  }, 30_000)
})
