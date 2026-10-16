import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, waitFor, act, cleanup } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import { AxiosError, AxiosHeaders } from 'axios'
import { connectorsApi, type RemoteAgent, type RemoteAgentsSnapshot, type SyncResult } from '../api/connectorsClient'
import { createSseTestServer, type SseTestServer } from '../api/__fixtures__/sseServer'
import { connectorStreamStore } from '../hooks/useConnectorStream'
import { setDemoMode } from '../api/demoMode'
import type { ConnectorProvider, TenantConnector } from '../types/connectors'
import RemoteEnvironmentPage from './RemoteEnvironmentPage'

const getToken = vi.fn()
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ user: { email: 'u@example.test' }, getAccessTokenSilently: getToken }),
}))

// Strings that exist only in the demo fixture. None may appear in live mode.
const FIXTURE_STRINGS = [
  'US$23.57',
  "Andy's Individual Org",
  'env_01CyCigBbDRSLTzSCyyHQ7eT',
  'Daily News Jokester',
  'POLICIES PASS',
  'Last updated 16 minutes ago',
  'cis-5.2.8',
]

const provider: ConnectorProvider = {
  provider_id: 'claude',
  display_name: 'Anthropic Claude',
  wizard_config: { fields: [], permissions: [], docs_link: '/help/connectors/claude', help_text: '' },
}

const connector: TenantConnector = {
  connector_id: 'conn-live-7',
  provider_id: 'claude',
  display_name: 'Claude (tenant prod)',
  status: 'connected',
  credential_expires_at: null,
  last_tested_at: '2026-10-16T09:00:00Z',
  last_scan_at: '2026-10-16T10:00:00Z',
  metadata: { workspace_id: 'wrkspc_live_42' },
  created_at: '2026-10-01T00:00:00Z',
}

const lastScan: SyncResult = {
  provider_id: 'claude',
  synced_at: '2026-10-16T10:00:00Z',
  duration_ms: 812,
  status: 'warning',
  records_scanned: { agents: 7, models: null, environments: null, tools: null },
  policies_evaluated: null,
  logs: [],
}

function httpError(status: number, code: string): AxiosError {
  return new AxiosError(`Request failed with status code ${status}`, 'ERR_BAD_RESPONSE', undefined, undefined, {
    status,
    statusText: '',
    headers: {},
    config: { headers: new AxiosHeaders() },
    data: { error: { code, message: code } },
  })
}

function renderPage(path = '/settings/connectors/claude') {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/settings/connectors/:providerId" element={<RemoteEnvironmentPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

beforeEach(() => {
  vi.restoreAllMocks()
  getToken.mockReset().mockResolvedValue('test-token')
})

afterEach(() => {
  setDemoMode(true)
})

describe('RemoteEnvironmentPage (demo mode)', () => {
  beforeEach(() => setDemoMode(true))

  it('renders the demo fixture environment', async () => {
    renderPage()
    expect(screen.getByRole('heading', { level: 1, name: /cloud-dev/i })).toBeInTheDocument()
    expect(screen.getByText('US$23.57')).toBeInTheDocument()
    expect(screen.getByText(/Organization: Andy's Individual Org/)).toBeInTheDocument()
    expect(screen.getByText('3 / 3 POLICIES PASS')).toBeInTheDocument()
    expect(screen.getByText('Daily News Jokester')).toBeInTheDocument()
  })

  it('runs Sync Now through the connectors client', async () => {
    const scan = vi.spyOn(connectorsApi, 'triggerScan')
    renderPage()
    fireEvent.click(screen.getByTestId('btn-env-sync-now'))
    await waitFor(() => expect(scan).toHaveBeenCalledWith('test-token', 'claude'))
    expect(await screen.findByText(/Synchronized just now/i)).toBeInTheDocument()
  })

  it('opens the tab named in ?tab= and shows only that section', () => {
    renderPage('/settings/connectors/claude?tab=agents')
    expect(screen.getByTestId('env-tab-agents')).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByRole('heading', { name: /Connected Agents & Workloads/i })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: /^General$/ })).not.toBeInTheDocument()
  })

  it('falls back to all sections for an unknown ?tab= value', () => {
    renderPage('/settings/connectors/claude?tab=bogus')
    expect(screen.getByTestId('env-tab-all')).toHaveAttribute('aria-selected', 'true')
  })

  it('links each agent to its dossier with the evidence drawer open', () => {
    renderPage('/settings/connectors/claude?tab=agents')
    const link = screen.getAllByTestId(/^btn-view-dossier-/)[0]
    const id = link.getAttribute('data-testid')!.replace('btn-view-dossier-', '')
    expect(link).toHaveAttribute('href', `/agents?selected=${encodeURIComponent(id)}&drawer=${encodeURIComponent(id)}`)
  })
})

describe('RemoteEnvironmentPage (live mode)', () => {
  beforeEach(() => {
    setDemoMode(false)
    vi.spyOn(connectorsApi, 'listProviders').mockResolvedValue([provider])
    vi.spyOn(connectorsApi, 'listConnectors').mockResolvedValue([connector])
    vi.spyOn(connectorsApi, 'getSyncLogs').mockResolvedValue(lastScan)
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockResolvedValue(null)
    vi.stubGlobal('fetch', createSseTestServer().fetch)
  })

  afterEach(() => {
    cleanup()
    connectorStreamStore.reset()
    vi.unstubAllGlobals()
  })

  it('renders only API data and never the demo fixture', async () => {
    renderPage()
    expect(await screen.findByRole('heading', { level: 1, name: 'Claude (tenant prod)' })).toBeInTheDocument()
    expect(screen.getByTestId('live-records-agents')).toHaveTextContent('7')
    expect(screen.getByTestId('live-records-models')).toHaveTextContent(/not observed/i)
    expect(screen.getByText(/wrkspc_live_42/)).toBeInTheDocument()
    expect(screen.getByTestId('live-env-not-available')).toHaveTextContent(/not available from this provider/i)
    const text = document.body.textContent ?? ''
    for (const s of FIXTURE_STRINGS) expect(text, s).not.toContain(s)
  })

  it('shows an explicit not-yet-scanned state when the connector was never scanned', async () => {
    vi.mocked(connectorsApi.getSyncLogs).mockResolvedValue(null)
    renderPage()
    expect(await screen.findByTestId('live-last-scan-empty')).toHaveTextContent(/not yet scanned/i)
  })

  it('runs Sync Now through triggerScan and surfaces failures visibly', async () => {
    const scan = vi.spyOn(connectorsApi, 'triggerScan').mockRejectedValueOnce(httpError(501, 'scan_unsupported'))
    renderPage()
    fireEvent.click(await screen.findByTestId('btn-env-sync-now'))
    expect(await screen.findByRole('alert')).toHaveTextContent(/not supported/i)

    scan.mockResolvedValueOnce({ ...lastScan, status: 'success', records_scanned: { ...lastScan.records_scanned, agents: 9 } })
    fireEvent.click(screen.getByTestId('btn-env-sync-now'))
    await waitFor(() => expect(screen.getByTestId('live-records-agents')).toHaveTextContent('9'))
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('shows the design-system wait on Sync Now while a scan is in flight, then returns to idle', async () => {
    let resolveScan: ((value: SyncResult) => void) | undefined
    vi.spyOn(connectorsApi, 'triggerScan').mockImplementation(
      () =>
        new Promise<SyncResult>((resolve) => {
          resolveScan = resolve
        }),
    )
    renderPage()
    const btn = await screen.findByTestId('btn-env-sync-now')
    fireEvent.click(btn)

    await waitFor(() => expect(btn).toBeDisabled())
    expect(btn.getAttribute('aria-busy')).toBe('true')
    expect(screen.getByTestId('env-sync-now-wait-grid')).toBeTruthy()
    expect(screen.queryByText('Scanning...')).toBeNull()

    resolveScan?.({ ...lastScan, status: 'success' })

    await waitFor(() => expect(btn).not.toBeDisabled())
    expect(btn.getAttribute('aria-busy')).not.toBe('true')
    expect(screen.queryByTestId('env-sync-now-wait-grid')).toBeNull()
  })

  it('shows a failed rescan inside the logs modal instead of presenting old logs as fresh', async () => {
    vi.spyOn(connectorsApi, 'triggerScan').mockRejectedValue(httpError(501, 'scan_unsupported'))
    renderPage()
    fireEvent.click(await screen.findByTestId('btn-env-sync-logs'))
    fireEvent.click(await screen.findByTestId('btn-modal-rescan'))
    expect(await screen.findByTestId('sync-logs-error')).toHaveTextContent(/not supported/i)
    // The page banner still reports it too.
    expect(screen.getAllByRole('alert').some((el) => /not supported/i.test(el.textContent ?? ''))).toBe(true)
  })

  it('shows no claim control in live mode: no greyed button, no explanation block', async () => {
    renderPage()
    await screen.findByRole('heading', { level: 1, name: 'Claude (tenant prod)' })
    expect(screen.queryByRole('button', { name: /claim/i })).not.toBeInTheDocument()
    expect(screen.queryByTestId('live-claim-explanation')).not.toBeInTheDocument()
  })

  it('surfaces a failed connector lookup as an error', async () => {
    vi.mocked(connectorsApi.listConnectors).mockRejectedValue(httpError(500, 'internal_error'))
    renderPage()
    expect(await screen.findByRole('alert')).toBeInTheDocument()
    expect(screen.queryByTestId('live-records-agents')).not.toBeInTheDocument()
  })

  it('says the provider is not connected when the tenant has no connector for it', async () => {
    vi.mocked(connectorsApi.listConnectors).mockResolvedValue([])
    renderPage()
    expect(await screen.findByTestId('live-not-connected')).toHaveTextContent(/not connected/i)
  })
})

describe('RemoteEnvironmentPage (live remote agents)', () => {
  let server: SseTestServer
  const agent = (external_id: string, over: Partial<RemoteAgent> = {}): RemoteAgent => ({
    external_id,
    kind: 'session',
    name: `Session ${external_id}`,
    model: 'claude-sonnet-4-5',
    status: 'idle',
    version: 3,
    external_updated_at: null,
    first_seen_at: '2026-10-16T09:00:00Z',
    last_seen_at: '2026-10-16T10:00:00Z',
    last_changed_at: '2026-10-16T09:30:00Z',
    gone_at: null,
    ...over,
  })
  const snap = (over: Partial<RemoteAgentsSnapshot> = {}): RemoteAgentsSnapshot => ({
    provider_id: 'claude',
    connector_id: 'conn-live-7',
    sync_state: { mode: 'poll', last_poll_at: '2026-10-16T10:00:00Z', last_success_at: '2026-10-16T10:00:00Z', last_error: null, next_poll_at: '2026-10-16T10:00:30Z' },
    agents: [agent('s1'), agent('s2', { status: 'running' })],
    ...over,
  })
  const send = (event: string, body: unknown) => server.connections[0].send(`event: ${event}\ndata: ${JSON.stringify(body)}\n\n`)
  const row = (id: string) => screen.getByTestId(`remote-agent-${id}`)

  beforeEach(() => {
    setDemoMode(false)
    server = createSseTestServer()
    vi.stubGlobal('fetch', server.fetch)
    vi.spyOn(connectorsApi, 'listProviders').mockResolvedValue([provider])
    vi.spyOn(connectorsApi, 'listConnectors').mockResolvedValue([connector])
    vi.spyOn(connectorsApi, 'getSyncLogs').mockResolvedValue(lastScan)
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockResolvedValue(snap())
  })

  afterEach(() => {
    cleanup()
    connectorStreamStore.reset()
    vi.unstubAllGlobals()
  })

  async function ready() {
    renderPage()
    await screen.findByTestId('remote-agent-s1')
    await waitFor(() => expect(screen.getByTestId('stream-connection')).toHaveTextContent(/live updates connected/i))
  }

  it('lists the remote agents and sessions with sync state', async () => {
    await ready()
    expect(row('s1')).toHaveTextContent('Session s1')
    expect(row('s1')).toHaveTextContent('session')
    expect(row('s1')).toHaveTextContent('claude-sonnet-4-5')
    expect(row('s2')).toHaveTextContent('running')
    expect(screen.getByTestId('remote-sync-state')).toHaveTextContent(/Polling every 30 s/)
    expect(screen.getByTestId('remote-sync-state')).toHaveTextContent(/Last synced/)
    // Each row links to Discovery, where claiming happens; no button here.
    const link = screen.getByTestId('claim-in-discovery-s1')
    expect(link).toHaveTextContent('Claim in Discovery')
    expect(link).toHaveAttribute('href', '/discovery?provider=claude&selected=s1')
    expect(screen.queryByRole('button', { name: /claim/i })).not.toBeInTheDocument()
    const text = document.body.textContent ?? ''
    for (const s of FIXTURE_STRINGS) expect(text, s).not.toContain(s)
  })

  it('shows a claimed agent as Claimed linking to its registry agent, with no Claim in Discovery link', async () => {
    vi.mocked(connectorsApi.listRemoteAgents).mockResolvedValue(
      snap({ agents: [agent('s1', { claimed_agent_id: 'agent-uuid-1', claimed_at: '2026-10-16T10:05:00Z' }), agent('s2')] }),
    )
    await ready()
    const claimed = screen.getByTestId('remote-claimed-link-s1')
    expect(claimed).toHaveTextContent('Claimed')
    expect(claimed).toHaveAttribute('href', '/agents?selected=agent-uuid-1')
    expect(screen.queryByTestId('claim-in-discovery-s1')).not.toBeInTheDocument()
    // The unclaimed row keeps its link to Discovery.
    expect(screen.getByTestId('claim-in-discovery-s2')).toBeInTheDocument()
    expect(screen.queryByTestId('remote-claimed-link-s2')).not.toBeInTheDocument()
  })

  it('turns a row to Claimed when the claim arrives over the stream', async () => {
    await ready()
    send('remote_agent.upserted', {
      provider_id: 'claude', connector_id: 'conn-live-7',
      agent: agent('s2', { status: 'running', claimed_agent_id: 'agent-uuid-2', claimed_at: '2026-10-16T10:06:00Z' }),
    })
    const claimed = await screen.findByTestId('remote-claimed-link-s2')
    expect(claimed).toHaveAttribute('href', '/agents?selected=agent-uuid-2')
    expect(screen.queryByTestId('claim-in-discovery-s2')).not.toBeInTheDocument()
  })

  it('applies upserts in place and announces the change politely', async () => {
    await ready()
    send('remote_agent.upserted', { provider_id: 'claude', connector_id: 'conn-live-7', agent: agent('s1', { status: 'running' }) })
    send('remote_agent.upserted', { provider_id: 'claude', connector_id: 'conn-live-7', agent: agent('s3', { name: 'Fresh session' }) })
    await waitFor(() => expect(row('s1')).toHaveTextContent('running'))
    expect(row('s3')).toHaveTextContent('Fresh session')
    const ids = screen.getAllByTestId(/^remote-agent-s/).map((el) => el.getAttribute('data-testid'))
    expect(ids).toEqual(['remote-agent-s1', 'remote-agent-s2', 'remote-agent-s3'])
    const live = screen.getByTestId('remote-agents-announcer')
    expect(live).toHaveAttribute('aria-live', 'polite')
    await waitFor(() => expect(live).toHaveTextContent(/Session s1 is now running/))
  })

  it('keeps a gone agent visible, marked gone with its time', async () => {
    await ready()
    send('remote_agent.gone', { provider_id: 'claude', connector_id: 'conn-live-7', external_id: 's2', gone_at: '2026-10-16T11:00:00Z' })
    await waitFor(() => expect(row('s2')).toHaveAttribute('data-gone', 'true'))
    expect(row('s2')).toHaveTextContent(/Gone/)
    expect(row('s2')).toHaveTextContent('Session s2')
    expect(row('s1')).toHaveAttribute('data-gone', 'false')
  })

  it('shows a visible reconnecting state when the stream drops', async () => {
    await ready()
    server.connections[0].fail(new TypeError('network down'))
    await waitFor(() => expect(screen.getByTestId('stream-connection')).toHaveTextContent(/connection lost, reconnecting/i))
    expect(screen.getByTestId('stream-connection')).toHaveTextContent(/network down/)
  })

  it('shows the sync error and a live upstream mode honestly', async () => {
    vi.mocked(connectorsApi.listRemoteAgents).mockResolvedValue(
      snap({ sync_state: { mode: 'stream', last_poll_at: null, last_success_at: null, last_error: 'HTTP 401 from provider', next_poll_at: null } }),
    )
    await ready()
    expect(screen.getByTestId('remote-sync-state')).toHaveTextContent(/Live/)
    expect(screen.getByTestId('remote-sync-state')).toHaveTextContent(/Never synced/)
    expect(screen.getByTestId('remote-sync-error')).toHaveTextContent('HTTP 401 from provider')
  })

  it('says so when the provider reports no agents', async () => {
    vi.mocked(connectorsApi.listRemoteAgents).mockResolvedValue(snap({ agents: [] }))
    renderPage()
    expect(await screen.findByTestId('remote-agents-empty')).toBeInTheDocument()
  })
})

describe('RemoteEnvironmentPage (demo-mode flip without a reload)', () => {
  beforeEach(() => {
    vi.spyOn(connectorsApi, 'listProviders').mockResolvedValue([provider])
    vi.spyOn(connectorsApi, 'listConnectors').mockResolvedValue([connector])
    vi.spyOn(connectorsApi, 'getSyncLogs').mockResolvedValue(lastScan)
  })

  it('drops the demo fixture and loads the live connector when demo mode is switched off', async () => {
    setDemoMode(true)
    renderPage()
    expect(screen.getByText('US$23.57')).toBeInTheDocument()

    act(() => setDemoMode(false))

    expect(await screen.findByRole('heading', { level: 1, name: 'Claude (tenant prod)' })).toBeInTheDocument()
    const text = document.body.textContent ?? ''
    for (const s of FIXTURE_STRINGS) expect(text, s).not.toContain(s)
  })

  it('drops live state and shows the demo fixture when demo mode is switched on', async () => {
    setDemoMode(false)
    renderPage()
    expect(await screen.findByRole('heading', { level: 1, name: 'Claude (tenant prod)' })).toBeInTheDocument()

    act(() => setDemoMode(true))

    expect(await screen.findByText('US$23.57')).toBeInTheDocument()
    expect(screen.queryByText('Claude (tenant prod)')).not.toBeInTheDocument()
  })
})

describe('RemoteEnvironmentPage (unknown provider)', () => {
  it.each([true, false])('renders not-found instead of another provider (demo=%s)', async (demo) => {
    setDemoMode(demo)
    const list = vi.spyOn(connectorsApi, 'listConnectors')
    renderPage('/settings/connectors/okta')
    expect(screen.getByTestId('remote-env-not-found')).toBeInTheDocument()
    expect(screen.queryByText(/Anthropic Claude/)).not.toBeInTheDocument()
    expect(list).not.toHaveBeenCalled()
  })
})

// ── Design-system audit A6: page shell, disclosure sections, tab wiring ────

describe('RemoteEnvironmentPage (design-system A6 fixes)', () => {
  describe('demo mode', () => {
    beforeEach(() => setDemoMode(true))

    it('renders the page h1 at the standard 22px size, not a page-local 24px', () => {
      renderPage()
      const h1 = screen.getByTestId('env-title')
      expect(h1.style.fontSize).toBe('22px')
    })

    it('makes each Section header a single accessible disclosure button with aria-expanded', () => {
      renderPage()
      const toggle = screen.getByRole('button', { name: /toggle general section/i })
      // The header (title + subtitle) stays visible either way — only the
      // panel content collapses, same as before this fix.
      expect(toggle).toHaveAttribute('aria-expanded', 'true')
      expect(screen.getByRole('heading', { name: /^General$/ })).toBeInTheDocument()
      expect(screen.getByText('Workspace / Org ID')).toBeInTheDocument()

      fireEvent.click(toggle)
      expect(toggle).toHaveAttribute('aria-expanded', 'false')
      expect(screen.getByRole('heading', { name: /^General$/ })).toBeInTheDocument()
      expect(screen.queryByText('Workspace / Org ID')).not.toBeInTheDocument()

      fireEvent.click(toggle)
      expect(toggle).toHaveAttribute('aria-expanded', 'true')
      expect(screen.getByText('Workspace / Org ID')).toBeInTheDocument()
    })

    it('wires each tab to a tabpanel it controls', () => {
      renderPage()
      const generalTab = screen.getByTestId('env-tab-general')
      const controlsId = generalTab.getAttribute('aria-controls')
      expect(controlsId).toBeTruthy()
      const panel = document.getElementById(controlsId!)
      expect(panel).not.toBeNull()
      expect(panel).toHaveAttribute('role', 'tabpanel')
      expect(panel).toHaveAttribute('aria-labelledby', generalTab.id)
    })

    it('announces the Sync Now outcome through a live region', async () => {
      renderPage()
      const statusPill = screen.getByTestId('env-title').closest('div')!.querySelector('[role="status"]')
      expect(statusPill).toBeTruthy()
      fireEvent.click(screen.getByTestId('btn-env-sync-now'))
      expect(await screen.findByText(/Synchronized just now/i)).toHaveAttribute('role', 'status')
    })

    it('replaces fontFamily: monospace inline styles with the shared .mono class', () => {
      renderPage()
      expect(screen.getByTestId('env-badge-id')).toHaveClass('mono')
    })
  })

  describe('live mode', () => {
    beforeEach(() => {
      setDemoMode(false)
      vi.spyOn(connectorsApi, 'listProviders').mockResolvedValue([provider])
      vi.spyOn(connectorsApi, 'listConnectors').mockResolvedValue([connector])
      vi.spyOn(connectorsApi, 'listRemoteAgents').mockResolvedValue(null)
      vi.stubGlobal('fetch', createSseTestServer().fetch)
    })

    afterEach(() => {
      cleanup()
      connectorStreamStore.reset()
      vi.unstubAllGlobals()
    })

    it('shows the shared LoadingState (not bare text) while the connector loads', async () => {
      let resolveLogs: ((value: SyncResult | null) => void) | undefined
      vi.spyOn(connectorsApi, 'getSyncLogs').mockImplementation(
        () => new Promise((resolve) => { resolveLogs = resolve }),
      )
      renderPage()
      expect(await screen.findByTestId('live-page-loading')).toBeInTheDocument()
      expect(screen.queryByText('Loading connector...')).not.toBeInTheDocument()
      resolveLogs?.(lastScan)
      await waitFor(() => expect(screen.queryByTestId('live-page-loading')).not.toBeInTheDocument())
    })

    it('renders the connector id with the shared .mono class', async () => {
      vi.spyOn(connectorsApi, 'getSyncLogs').mockResolvedValue(lastScan)
      renderPage()
      const el = await screen.findByText(/Connector ID:/)
      expect(el).toHaveClass('mono')
    })
  })
})
