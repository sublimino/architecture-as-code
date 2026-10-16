import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import DiscoveryPage from './DiscoveryPage'
import { api } from '../api/client'
import { isDemoMode } from '../api/demoMode'
import { claimRemoteAgent, connectorsApi, getDiscoverySourceSyncState } from '../api/connectorsClient'
import type { DiscoveryWorkload, DiscoveryWorkloadsResponse } from '../types/api'
import type { TenantConnector } from '../types/connectors'

// The Discovery page's view of connected sources (connectors) and the remote
// agents they sync into GET /discovery/workloads. Principal feedback: the scan
// said "claim discovered agents from Discovery" and Discovery said "No
// workloads found". These tests pin the sources strip, its Re-scan and Logs
// actions, the provider deep link, and empty states that say which of
// "nothing connected", "nothing discovered" and "request failed" is true.

vi.mock('../auth/oidc', () => {
  const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
  return { useAuth0: () => ({ getAccessTokenSilently, user: null }) }
})

vi.mock('../api/demoMode', () => ({ isDemoMode: vi.fn(() => false) }))

vi.mock('../api/client', () => ({
  api: {
    discovery: {
      workloads: vi.fn(),
      autoclaimNamespace: vi.fn(),
      enroll: vi.fn(),
      dismiss: vi.fn(),
    },
    nhi: {
      discovered: vi.fn(),
      scans: vi.fn().mockResolvedValue({ scans: [] }),
    },
    agents: { list: vi.fn().mockResolvedValue({ agents: [] }) },
  },
}))

vi.mock('../api/connectorsClient', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api/connectorsClient')>()
  return {
    ...actual,
    connectorsApi: {
      listConnectors: vi.fn(),
      listProviders: vi.fn(),
      triggerScan: vi.fn(),
      getSyncLogs: vi.fn(),
    },
    getDiscoverySourceSyncState: vi.fn(),
    claimRemoteAgent: vi.fn(),
  }
})

// SyncLogsModal is reused as-is; its own suite covers its internals. Here we
// only need to know it was opened, and for which provider.
vi.mock('../components/connectors/SyncLogsModal', () => ({
  default: (props: { isOpen: boolean; providerId: string; providerName: string; onClose: () => void }) =>
    props.isOpen ? (
      <div data-testid="sync-logs-modal-stub" data-provider={props.providerId} data-name={props.providerName}>
        <button type="button" onClick={props.onClose}>close logs</button>
      </div>
    ) : null,
}))

const NOW = Date.now()
const iso = (offsetMs: number) => new Date(NOW + offsetMs).toISOString()

function connector(overrides: Partial<TenantConnector>): TenantConnector {
  return {
    connector_id: 'conn-x',
    provider_id: 'x',
    display_name: null,
    status: 'connected',
    credential_expires_at: null,
    last_tested_at: null,
    last_scan_at: null,
    last_scan_status: null,
    last_scan_error: null,
    metadata: {},
    created_at: iso(-86_400_000),
    ...overrides,
  }
}

const claudeConn = connector({
  connector_id: 'conn-claude',
  provider_id: 'claude',
  last_scan_at: iso(-10 * 60_000),
  last_scan_status: 'success',
})
const openaiConn = connector({
  connector_id: 'conn-openai',
  provider_id: 'openai',
  last_scan_at: null,
  last_scan_status: 'error',
  last_scan_error: 'OpenAI returned 401: invalid API key',
})
const disconnectedConn = connector({ connector_id: 'conn-gone', provider_id: 'aws_iam', status: 'disconnected' })

function remoteWorkload(overrides: Partial<DiscoveryWorkload>): DiscoveryWorkload {
  return {
    id: 'agent_01',
    name: 'support-triage',
    source: 'external_services',
    source_label: 'Anthropic Claude',
    namespace: null,
    status: 'discovered',
    owner: null,
    spiffe_id: null,
    model: 'claude-sonnet-4-5',
    last_seen_at: iso(-60_000),
    metadata: { provider_id: 'claude', connector_id: 'conn-claude' },
    ...overrides,
  }
}

const liveResponse: DiscoveryWorkloadsResponse = {
  workloads: [
    remoteWorkload({ id: 'agent_01', name: 'support-triage' }),
    // A row whose id merely starts with the deep-linked id: must NOT be selected.
    remoteWorkload({ id: 'agent_01x', name: 'support-triage-shadow' }),
    remoteWorkload({
      id: 'asst_9',
      name: 'billing-assistant',
      source_label: 'OpenAI',
      model: 'gpt-4.1',
      metadata: { provider_id: 'openai', connector_id: 'conn-openai' },
    }),
    {
      id: 'k8s-1',
      name: 'agent-inventory-worker',
      source: 'local_k8s',
      source_label: 'Local K8s',
      namespace: 'fe-signalloom-agents',
      status: 'discovered',
      owner: 'platform@signalloom.test',
      spiffe_id: null,
      model: null,
      last_seen_at: iso(-60_000),
      metadata: {},
    },
  ],
  total: 4,
  summary: { total_discovered: 4, in_review: 0, ignored: 0, revoked: 0, governed: 0 },
}

const emptyResponse: DiscoveryWorkloadsResponse = {
  workloads: [],
  total: 0,
  summary: { total_discovered: 0, in_review: 0, ignored: 0, revoked: 0, governed: 0 },
}

function renderPage(initialEntry = '/discovery') {
  return render(
    <MemoryRouter initialEntries={[initialEntry]}>
      <Routes>
        <Route path="/discovery" element={<DiscoveryPage />} />
        <Route path="/settings" element={<div>SETTINGS PAGE</div>} />
        <Route path="/onboarding" element={<div>ONBOARDING WIZARD</div>} />
      </Routes>
    </MemoryRouter>,
  )
}

const mocked = <T,>(fn: T) => fn as unknown as ReturnType<typeof vi.fn>

beforeEach(() => {
  vi.clearAllMocks()
  mocked(isDemoMode).mockReturnValue(false)
  mocked(api.nhi.scans).mockResolvedValue({ scans: [] })
  mocked(api.agents.list).mockResolvedValue({ agents: [] })
  mocked(api.discovery.workloads).mockResolvedValue(liveResponse)
  mocked(connectorsApi.listConnectors).mockResolvedValue([claudeConn, openaiConn, disconnectedConn])
  mocked(connectorsApi.listProviders).mockResolvedValue([
    { provider_id: 'claude', display_name: 'Anthropic Claude', wizard_config: { fields: [], permissions: [], docs_link: '', help_text: '' } },
    { provider_id: 'openai', display_name: 'OpenAI', wizard_config: { fields: [], permissions: [], docs_link: '', help_text: '' } },
  ])
  mocked(getDiscoverySourceSyncState).mockImplementation(async (_token: string, providerId: string) => {
    if (providerId === 'claude') {
      return {
        provider_id: 'claude',
        connector_id: 'conn-claude',
        sync_state: {
          mode: 'poll',
          last_poll_at: iso(-60_000),
          last_success_at: iso(-60_000),
          last_error: null,
          next_poll_at: iso(4 * 60_000),
        },
      }
    }
    if (providerId === 'openai') {
      return {
        provider_id: 'openai',
        connector_id: 'conn-openai',
        sync_state: { mode: 'stream', last_poll_at: null, last_success_at: null, last_error: null, next_poll_at: null },
      }
    }
    return null
  })
})

describe('Discovery sources strip', () => {
  it('renders one source per connected connector with its sync state, and skips disconnected ones', async () => {
    renderPage()
    const strip = await screen.findByTestId('discovery-sources')
    const claude = await within(strip).findByTestId('discovery-source-claude')
    const openai = within(strip).getByTestId('discovery-source-openai')
    expect(within(strip).queryByTestId('discovery-source-aws_iam')).not.toBeInTheDocument()

    expect(claude).toHaveTextContent('Anthropic Claude')
    expect(within(claude).getByTestId('discovery-source-claude-sync')).toHaveTextContent('Polling every 5 min')
    expect(within(claude).getByTestId('discovery-source-claude-last-scan')).toHaveTextContent('Last scanned 10m ago')

    expect(openai).toHaveTextContent('OpenAI')
    expect(within(openai).getByTestId('discovery-source-openai-sync')).toHaveTextContent('Live')
    expect(within(openai).getByTestId('discovery-source-openai-last-scan')).toHaveTextContent('Never scanned')
    expect(within(openai).getByTestId('discovery-source-openai-error')).toHaveTextContent(
      'OpenAI returned 401: invalid API key',
    )
  })

  it.each([
    // W11's sync_state.mode is poll | poll+stream | backoff; the interval is next_poll_at - last_poll_at.
    [{ mode: 'poll', last_poll_at: iso(-10_000), next_poll_at: iso(20_000) }, 'Polling every 30 s'],
    [{ mode: 'poll', last_poll_at: iso(-60_000), next_poll_at: iso(29_000) }, 'Polling every 89 s'],
    [{ mode: 'poll', last_poll_at: iso(-60_000), next_poll_at: iso(30_000) }, 'Polling every 2 min'],
    [{ mode: 'poll+stream', last_poll_at: iso(-10_000), next_poll_at: iso(20_000) }, 'Live sessions + polling every 30 s'],
    [{ mode: 'poll+stream', last_poll_at: null, next_poll_at: null }, 'Live sessions + polling'],
    [{ mode: 'backoff', last_poll_at: iso(-10_000), next_poll_at: iso(60_000), consecutive_failures: 3 },
      'Backing off after errors (3 consecutive failures)'],
    [{ mode: 'backoff', last_poll_at: null, next_poll_at: null, consecutive_failures: 1 },
      'Backing off after errors (1 consecutive failure)'],
    [{ mode: 'backoff', last_poll_at: null, next_poll_at: null }, 'Backing off after errors'],
  ])('labels sync state %j as "%s"', async (partial, label) => {
    mocked(getDiscoverySourceSyncState).mockImplementation(async (_t: string, providerId: string) =>
      providerId === 'claude'
        ? { provider_id: 'claude', connector_id: 'conn-claude',
            sync_state: { last_success_at: null, last_error: null, ...partial } }
        : null,
    )
    renderPage()
    const badge = await screen.findByTestId('discovery-source-claude-sync')
    expect(badge).toHaveTextContent(new RegExp(`^${label.replace(/[()+]/g, '\\$&')}$`))
  })

  it('Re-scan scans only that provider, shows ButtonWait while pending, then refetches workloads', async () => {
    let resolveScan: (v: unknown) => void = () => {}
    mocked(connectorsApi.triggerScan).mockImplementation(
      () => new Promise((r) => { resolveScan = r }),
    )
    renderPage()
    const rescan = await screen.findByTestId('discovery-source-claude-rescan')
    expect(rescan).toHaveClass('btn', 'btn-secondary')
    const workloadCallsBefore = mocked(api.discovery.workloads).mock.calls.length

    await userEvent.click(rescan)

    expect(connectorsApi.triggerScan).toHaveBeenCalledTimes(1)
    expect(connectorsApi.triggerScan).toHaveBeenCalledWith('test-token', 'claude')
    expect(within(rescan).getByTestId('discovery-source-claude-rescan-wait')).toBeInTheDocument()
    expect(rescan).toBeDisabled()
    // The other source's button is untouched.
    expect(screen.getByTestId('discovery-source-openai-rescan')).not.toBeDisabled()

    resolveScan({
      provider_id: 'claude',
      synced_at: iso(0),
      duration_ms: 120,
      status: 'success',
      records_scanned: { agents: 2, models: null, environments: null, tools: null },
      policies_evaluated: null,
      logs: [],
    })

    await waitFor(() =>
      expect(mocked(api.discovery.workloads).mock.calls.length).toBeGreaterThan(workloadCallsBefore),
    )
    await waitFor(() =>
      expect(screen.queryByTestId('discovery-source-claude-rescan-wait')).not.toBeInTheDocument(),
    )
  })

  it('shows a failed Re-scan error on that source', async () => {
    mocked(connectorsApi.triggerScan).mockRejectedValue(new Error('upstream 503 from api.anthropic.com'))
    renderPage()
    await userEvent.click(await screen.findByTestId('discovery-source-claude-rescan'))
    const err = await screen.findByTestId('discovery-source-claude-rescan-error')
    expect(err).toHaveAttribute('role', 'alert')
    expect(err).toHaveTextContent('upstream 503 from api.anthropic.com')
  })

  it('Logs opens the existing SyncLogsModal for that provider', async () => {
    renderPage()
    await userEvent.click(await screen.findByTestId('discovery-source-openai-logs'))
    const modal = await screen.findByTestId('sync-logs-modal-stub')
    expect(modal).toHaveAttribute('data-provider', 'openai')
    expect(modal).toHaveAttribute('data-name', 'OpenAI')
  })
})

describe('Remote agents in the live workloads list', () => {
  it('renders Anthropic and OpenAI agents from /discovery/workloads with model and source', async () => {
    renderPage()
    const row = await screen.findByTestId('discovery-row-agent_01')
    expect(row).toHaveTextContent('support-triage')
    expect(row).toHaveTextContent('Anthropic Claude')
    expect(row).toHaveTextContent('claude-sonnet-4-5')
    expect(screen.getByTestId('discovery-row-asst_9')).toHaveTextContent('OpenAI')
  })

  it('demo mode keeps claim disabled on provider-hosted agents with the reason, and enabled for k8s rows', async () => {
    mocked(isDemoMode).mockReturnValue(true)
    renderPage()
    const claim = await screen.findByTestId('enroll-workload-btn-agent_01')
    expect(claim).toBeDisabled()
    expect(screen.getByTestId('claim-unavailable-reason-agent_01')).toHaveTextContent(/namespace/i)
    expect(screen.queryByTestId('claim-remote-btn-agent_01')).not.toBeInTheDocument()
    expect(screen.getByTestId('enroll-workload-btn-k8s-1')).not.toBeDisabled()
  })
})

describe('Claiming a provider-hosted agent (live)', () => {
  const CLAIMED = {
    agent_id: '9f0e5a52-6c1b-5d7e-8a43-1f2e3d4c5b6a', agent_name: 'claude:agent_01@tenant-a', display_name: 'support-triage',
    provider_id: 'claude', connector_id: 'conn-claude', external_id: 'agent_01', kind: 'agent',
    model: 'claude-sonnet-4-5', claimed_at: iso(0), created: true,
  }

  it('offers a working Claim instead of the disabled control and its reason; k8s rows keep enroll', async () => {
    renderPage()
    const claim = await screen.findByTestId('claim-remote-btn-agent_01')
    expect(claim).not.toBeDisabled()
    expect(claim).toHaveTextContent('Claim')
    expect(screen.queryByTestId('enroll-workload-btn-agent_01')).not.toBeInTheDocument()
    expect(screen.queryByTestId('claim-unavailable-reason-agent_01')).not.toBeInTheDocument()
    expect(screen.getByTestId('enroll-workload-btn-k8s-1')).not.toBeDisabled()
  })

  it('claims through the connectors API with ButtonWait in flight, then shows Claimed linking to the agent', async () => {
    let resolve: (v: unknown) => void = () => {}
    mocked(claimRemoteAgent).mockImplementation(() => new Promise((r) => { resolve = r }))
    renderPage()
    const claim = await screen.findByTestId('claim-remote-btn-agent_01')
    await userEvent.click(claim)

    expect(claimRemoteAgent).toHaveBeenCalledTimes(1)
    expect(claimRemoteAgent).toHaveBeenCalledWith('test-token', 'claude', 'agent_01')
    expect(within(claim).getByTestId('claim-remote-wait-agent_01')).toBeInTheDocument()
    expect(claim).toBeDisabled()

    resolve(CLAIMED)
    const link = await screen.findByTestId('remote-claimed-link-agent_01')
    expect(link).toHaveTextContent('Claimed')
    expect(link).toHaveAttribute('href', `/agents?selected=${CLAIMED.agent_id}`)
    expect(screen.queryByTestId('claim-remote-btn-agent_01')).not.toBeInTheDocument()
    // The other provider row is untouched.
    expect(screen.getByTestId('claim-remote-btn-asst_9')).not.toBeDisabled()
  })

  it('shows a failed claim on the row and lets the operator retry', async () => {
    mocked(claimRemoteAgent).mockRejectedValueOnce(new Error('Remote agent agent_01 is no longer listed by the provider'))
    renderPage()
    await userEvent.click(await screen.findByTestId('claim-remote-btn-agent_01'))
    const err = await screen.findByTestId('claim-remote-error-agent_01')
    expect(err).toHaveAttribute('role', 'alert')
    expect(err).toHaveTextContent('no longer listed by the provider')
    expect(screen.getByTestId('claim-remote-btn-agent_01')).not.toBeDisabled()
    expect(screen.queryByTestId('remote-claimed-link-agent_01')).not.toBeInTheDocument()
  })

  it('a row the backend already reports claimed shows Claimed with its link, no Claim button', async () => {
    mocked(api.discovery.workloads).mockResolvedValue({
      ...liveResponse,
      workloads: [
        remoteWorkload({
          id: 'agent_01', status: 'governed',
          metadata: { provider_id: 'claude', connector_id: 'conn-claude', claimed_agent_id: 'agent-uuid-1' },
        }),
      ],
    })
    renderPage()
    const link = await screen.findByTestId('remote-claimed-link-agent_01')
    expect(link).toHaveAttribute('href', '/agents?selected=agent-uuid-1')
    expect(screen.queryByTestId('claim-remote-btn-agent_01')).not.toBeInTheDocument()
  })
})

describe('Provider deep link', () => {
  it('?provider=claude&selected=agent_01 filters to that provider and selects the exact row only', async () => {
    renderPage('/discovery?provider=claude&selected=agent_01')
    const row = await screen.findByTestId('discovery-row-agent_01')
    expect(row).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByTestId('discovery-row-agent_01x')).toHaveAttribute('aria-selected', 'false')
    expect(screen.queryByTestId('discovery-row-asst_9')).not.toBeInTheDocument()
    expect(screen.queryByTestId('discovery-row-k8s-1')).not.toBeInTheDocument()
    expect(await screen.findByTestId('drawer-workload-id')).toHaveTextContent('agent_01')
  })

  it('a selected id that matches no row exactly selects nothing and says so', async () => {
    renderPage('/discovery?provider=claude&selected=agent_0')
    await screen.findByTestId('discovery-row-agent_01')
    expect(screen.getByTestId('discovery-row-agent_01')).toHaveAttribute('aria-selected', 'false')
    expect(screen.queryByTestId('discovered-workload-drawer')).not.toBeInTheDocument()
    expect(screen.getByTestId('discovery-deeplink-missing')).toHaveTextContent('agent_0')
  })
})

describe('Honest empty states', () => {
  it('no connected sources: says so and links to Settings > Connectors', async () => {
    mocked(connectorsApi.listConnectors).mockResolvedValue([disconnectedConn])
    mocked(api.discovery.workloads).mockResolvedValue(emptyResponse)
    renderPage()
    const empty = await screen.findByTestId('discovery-empty-no-sources')
    expect(empty).toHaveTextContent('No sources connected')
    expect(screen.queryByText('No workloads found')).not.toBeInTheDocument()
    await userEvent.click(within(empty).getByRole('link', { name: /Settings/i }))
    expect(await screen.findByText('SETTINGS PAGE')).toBeInTheDocument()
  })

  it('sources connected but nothing discovered: lists each source with last scan and error', async () => {
    mocked(api.discovery.workloads).mockResolvedValue(emptyResponse)
    renderPage()
    const empty = await screen.findByTestId('discovery-empty-no-discoveries')
    expect(empty).toHaveTextContent('Nothing discovered yet')
    expect(empty).toHaveTextContent('Anthropic Claude')
    expect(empty).toHaveTextContent('Last scanned 10m ago')
    expect(empty).toHaveTextContent('OpenAI returned 401: invalid API key')
    expect(screen.queryByText('No workloads found')).not.toBeInTheDocument()
  })

  it('a failed workloads request in live mode is an error, not an empty list', async () => {
    mocked(api.discovery.workloads).mockRejectedValue(new Error('502 Bad Gateway'))
    renderPage()
    const err = await screen.findByTestId('discovery-workloads-error')
    expect(err).toHaveTextContent('502 Bad Gateway')
    expect(screen.queryByText('No workloads found')).not.toBeInTheDocument()
    // Sources stay usable so the operator can still re-scan or read logs.
    expect(screen.getByTestId('discovery-source-claude-rescan')).toBeInTheDocument()
  })

  it('demo mode is unchanged: a failed aggregate still falls back to the NHI fixtures', async () => {
    mocked(isDemoMode).mockReturnValue(true)
    mocked(api.discovery.workloads).mockRejectedValue(new Error('not in demo'))
    mocked(api.nhi.discovered).mockResolvedValue({
      accounts: [
        {
          id: 'nhi-1',
          account_name: 'svc-demo-entra',
          directory_source: 'entra',
          status: 'discovered',
          owner_email: 'demo@signalloom.test',
          last_seen_at: iso(-60_000),
          first_discovered_at: iso(-120_000),
          privilege_level: 'standard',
        },
      ],
    })
    renderPage()
    expect(await screen.findByTestId('discovery-row-nhi-1')).toHaveTextContent('svc-demo-entra')
    expect(screen.queryByTestId('discovery-workloads-error')).not.toBeInTheDocument()
  })
})
