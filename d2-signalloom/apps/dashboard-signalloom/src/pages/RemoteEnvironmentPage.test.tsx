import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import { AxiosError, AxiosHeaders } from 'axios'
import { connectorsApi, type SyncResult } from '../api/connectorsClient'
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
})

describe('RemoteEnvironmentPage (live mode)', () => {
  beforeEach(() => {
    setDemoMode(false)
    vi.spyOn(connectorsApi, 'listProviders').mockResolvedValue([provider])
    vi.spyOn(connectorsApi, 'listConnectors').mockResolvedValue([connector])
    vi.spyOn(connectorsApi, 'getSyncLogs').mockResolvedValue(lastScan)
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

  it('does not offer a fake claim: the scan reports counts, not agent identities', async () => {
    renderPage()
    const claim = await screen.findByRole('button', { name: /Claim to Tenant/i })
    expect(claim).toBeDisabled()
    expect(screen.getByTestId('live-claim-explanation')).toHaveTextContent(/Discovery/)
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
