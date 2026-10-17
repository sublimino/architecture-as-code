// W22: /discovery on the live estate rendered demo fixtures.
//
// A Playwright capture of the cluster dashboard showed the eleven rows of
// fakeData.ts's initialDiscoveryWorkloads, "Customer Support Triage Assistant"
// and a "Daily News Jokester" drawer full of fixture values (owner, org id,
// token counts, a last-seen of 27 Jul 2026 13:00 BST = fakeData's NOW). The
// backend never sent any of it: demoMode.ts falls back to SL_ENV when no
// preference is stored, SL_ENV falls back to 'demo', and the cluster image was
// built without VITE_SL_ENV, so every fresh browser started in demo mode.
//
// These tests drive the real api client, demo-mode module and page against a
// stubbed HTTP layer that answers what live Postgres holds for that agent.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

const { request } = vi.hoisted(() => ({ request: vi.fn() }))
vi.mock('axios', () => ({
  default: { create: () => ({ request }), isAxiosError: () => false },
}))
vi.mock('../auth/oidc', () => {
  const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
  return { useAuth0: () => ({ getAccessTokenSilently }) }
})

// Strings that exist only in demo fixtures (fakeData.ts, the backend's
// in-memory seed). None may render when the backend answered live.
const FABRICATED = ['Customer Support Triage Assistant', 'Andrew Martin (User)', '1f9b3065', '12450', '27 Jul 2026']

// What public.remote_agents holds for the real agent: user_metadata is only the
// workspace id, metrics are empty, and nothing has evaluated the four pillars.
const LIVE_JOKESTER = {
  id: 'agent_01FoEhnKF9QsC5DGmuELhm7G',
  name: 'Daily News Jokester',
  tenant_id: 'tenant-live',
  source: 'external_services',
  source_label: 'Anthropic Claude',
  namespace: null,
  status: 'discovered',
  discovery_state: 'discovered',
  owner: null,
  spiffe_id: null,
  model: 'claude-opus-5-5',
  last_seen_at: '2026-10-17T11:05:00Z',
  recommendations: { config: 'not_assessed', content: 'not_assessed', supply_chain: 'not_assessed', eu_ai_act: 'not_assessed' },
  control_recommendations: { config: 'not_assessed', content: 'not_assessed', supply_chain: 'not_assessed', eu_ai_act: 'not_assessed' },
  metadata: {
    provider_id: 'claude',
    connector_id: 'conn-claude-01',
    external_id: 'agent_01FoEhnKF9QsC5DGmuELhm7G',
    kind: 'agent',
    remote_status: null,
    raw_hash: 'd41d8cd98f00b204e9800998ecf8427e',
    system_prompt: null,
    user_metadata: { workspace_id: 'wrkspc_live' },
    environment_config: {},
    metrics: {},
  },
}

function answer({ url }: { url: string }) {
  if (url.startsWith('/api/discovery/workloads')) {
    return Promise.resolve({ data: { workloads: [LIVE_JOKESTER], total: 1, summary: { total_discovered: 1, in_review: 0, ignored: 0, revoked: 0, governed: 0 } } })
  }
  if (url.startsWith('/api/nhi/scans')) return Promise.resolve({ data: { scans: [] } })
  if (url === '/api/agents' || url.startsWith('/api/agents?')) return Promise.resolve({ data: { agents: [] } })
  if (url === '/api/connectors/providers') return Promise.resolve({ data: { providers: [] } })
  if (url === '/api/connectors') return Promise.resolve({ data: { connectors: [] } })
  return Promise.reject(new Error(`unmocked live request ${url}`))
}

// The VITE_SL_ENV the cluster image is built with: the Dockerfile's
// `ARG VITE_SL_ENV=<value>` default, or undefined when the build sets none.
function clusterImageSlEnv(): string | undefined {
  const dockerfile = readFileSync(join(__dirname, '..', '..', 'Dockerfile'), 'utf-8')
  return dockerfile.match(/^ARG VITE_SL_ENV=(\S+)\s*$/m)?.[1]
}

async function renderFreshPage() {
  const { default: DiscoveryPage } = await import('./DiscoveryPage')
  render(
    <MemoryRouter>
      <DiscoveryPage />
    </MemoryRouter>,
  )
}

async function openJokesterDrawer() {
  await userEvent.click(await screen.findByTestId(`discovery-workload-name-${LIVE_JOKESTER.id}`))
  return screen.findByTestId('discovered-workload-drawer')
}

function expectNoFabrication() {
  const text = document.body.textContent ?? ''
  for (const literal of FABRICATED) {
    expect(text, `fixture literal ${JSON.stringify(literal)} rendered in live mode`).not.toContain(literal)
  }
}

// This runner's `localStorage` global is a methodless stub (see
// styles/themes.test.ts), which would send readPersisted() down its catch
// branch. A fresh browser has a working, empty store: install one.
function installEmptyLocalStorage(): void {
  const store = new Map<string, string>()
  const mock: Storage = {
    getItem: (key) => (store.has(key) ? (store.get(key) as string) : null),
    setItem: (key, value) => void store.set(key, String(value)),
    removeItem: (key) => void store.delete(key),
    clear: () => store.clear(),
    key: (index) => Array.from(store.keys())[index] ?? null,
    get length() {
      return store.size
    },
  }
  Object.defineProperty(window, 'localStorage', { value: mock, configurable: true, writable: true })
  Object.defineProperty(globalThis, 'localStorage', { value: mock, configurable: true, writable: true })
}

describe('Discovery on the live estate renders only what the backend reported', () => {
  beforeEach(() => {
    installEmptyLocalStorage()
    request.mockReset()
    request.mockImplementation(answer)
    vi.resetModules()
  })

  afterEach(() => {
    vi.unstubAllEnvs()
  })

  it('a fresh browser on the cluster image starts live, not on demo fixtures', async () => {
    const slEnv = clusterImageSlEnv()
    if (slEnv !== undefined) vi.stubEnv('VITE_SL_ENV', slEnv)
    await renderFreshPage()
    await openJokesterDrawer()
    expectNoFabrication()

    const { isDemoMode } = await import('../api/demoMode')
    expect(isDemoMode(), `cluster image builds with VITE_SL_ENV=${slEnv ?? '(unset, so demo)'}`).toBe(false)
    expect(request).toHaveBeenCalledWith(expect.objectContaining({ url: '/api/discovery/workloads?limit=100' }))
  })

  it('the live drawer shows Not reported / Not assessed, never a fixture value or an unearned verdict', async () => {
    const { setDemoMode } = await import('../api/demoMode')
    setDemoMode(false)
    await renderFreshPage()
    const drawer = await openJokesterDrawer()

    expectNoFabrication()
    const d = within(drawer)
    expect(d.getByTestId('drawer-claude-user-owner')).toHaveTextContent('Not reported')
    expect(d.getByTestId('drawer-claude-org-id')).toHaveTextContent('Not reported')
    expect(d.getByTestId('drawer-claude-exec-identity')).toHaveTextContent('Not reported')
    expect(d.getByTestId('drawer-claude-tokens-metric')).toHaveTextContent('Not reported')
    expect(d.getByTestId('drawer-workload-owner')).toHaveTextContent('Not reported')
    expect(d.getByTestId('drawer-workload-namespace')).toHaveTextContent('Not reported')
    expect(d.getByTestId('drawer-privilege-level')).toHaveTextContent('Not reported')
    // The hash is the current remote_agents row, not a historic snapshot, and
    // nothing here verified storage deduplication.
    expect(d.getByTestId('drawer-claude-snapshot-hash')).toHaveTextContent('Current record SHA-256: d41d8cd98f00')
    expect(d.queryByTestId('drawer-claude-dedup-badge')).not.toBeInTheDocument()
    for (const pillar of ['config', 'content', 'supply_chain', 'eu_ai_act']) {
      expect(d.getByTestId(`drawer-rec-${pillar}`)).toHaveTextContent('Not assessed')
    }

    // And in the list row.
    await waitFor(() => expect(screen.getAllByText('(Not assessed)')).toHaveLength(4))
    expect(screen.queryByText('(Pass)')).not.toBeInTheDocument()
    expect(screen.queryByText('(Review)')).not.toBeInTheDocument()
  })

  it('a row that carries no pillar verdicts at all renders Not assessed, not Review', async () => {
    const { recommendations: _r, control_recommendations: _c, ...noVerdicts } = LIVE_JOKESTER
    request.mockImplementation(({ url }: { url: string }) =>
      url.startsWith('/api/discovery/workloads')
        ? Promise.resolve({ data: { workloads: [noVerdicts], total: 1, summary: { total_discovered: 1, in_review: 0, ignored: 0, revoked: 0, governed: 0 } } })
        : answer({ url }),
    )
    const { setDemoMode } = await import('../api/demoMode')
    setDemoMode(false)
    await renderFreshPage()
    const drawer = await openJokesterDrawer()

    for (const pillar of ['config', 'content', 'supply_chain', 'eu_ai_act']) {
      expect(within(drawer).getByTestId(`drawer-rec-${pillar}`)).toHaveTextContent('Not assessed')
    }
    expect(screen.getAllByText('(Not assessed)')).toHaveLength(4)
    expect(screen.queryByText('(Review)')).not.toBeInTheDocument()
  })
})
