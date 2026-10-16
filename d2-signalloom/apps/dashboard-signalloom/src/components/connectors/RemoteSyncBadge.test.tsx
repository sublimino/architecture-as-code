import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor, cleanup } from '@testing-library/react'
import { connectorsApi, type ConnectorSyncState } from '../../api/connectorsClient'
import { setDemoMode } from '../../api/demoMode'
import { createSseTestServer, type SseTestServer } from '../../api/__fixtures__/sseServer'
import { connectorStreamStore } from '../../hooks/useConnectorStream'
import RemoteSyncBadge from './RemoteSyncBadge'

vi.mock('../../auth/oidc', () => ({ useAuth0: () => ({ getAccessTokenSilently: () => Promise.resolve('t') }) }))

let server: SseTestServer
const state = (over: Partial<ConnectorSyncState>): ConnectorSyncState => ({
  mode: 'stream',
  last_poll_at: null,
  last_success_at: '2026-10-16T10:00:00Z',
  last_error: null,
  next_poll_at: null,
  ...over,
})
function withState(sync_state: ConnectorSyncState) {
  vi.spyOn(connectorsApi, 'listRemoteAgents').mockResolvedValue({ provider_id: 'claude', connector_id: 'c', sync_state, agents: [] })
}
const badge = () => screen.getByTestId('remote-sync-claude')

beforeEach(() => {
  vi.restoreAllMocks()
  setDemoMode(false)
  server = createSseTestServer()
  vi.stubGlobal('fetch', server.fetch)
})

afterEach(() => {
  cleanup()
  connectorStreamStore.reset()
  vi.unstubAllGlobals()
  setDemoMode(true)
})

describe('RemoteSyncBadge', () => {
  it('says Live for a streaming upstream on an open connection', async () => {
    withState(state({ mode: 'stream' }))
    render(<RemoteSyncBadge providerId="claude" />)
    await waitFor(() => expect(badge()).toHaveTextContent(/^Live$/))
  })

  it('says Polling with the interval for a polled upstream', async () => {
    withState(state({ mode: 'poll', last_poll_at: '2026-10-16T10:00:00Z', next_poll_at: '2026-10-16T10:01:00Z' }))
    render(<RemoteSyncBadge providerId="claude" />)
    await waitFor(() => expect(badge()).toHaveTextContent('Polling every 60 s'))
  })

  it('says Error with the message when the last sync failed', async () => {
    withState(state({ last_error: 'HTTP 401 from provider' }))
    render(<RemoteSyncBadge providerId="claude" />)
    await waitFor(() => expect(badge()).toHaveTextContent('Sync error: HTTP 401 from provider'))
    expect(badge()).toHaveAttribute('title', 'HTTP 401 from provider')
  })

  it('does not claim Live while the browser stream is reconnecting', async () => {
    withState(state({ mode: 'stream' }))
    connectorStreamStore.configure({ initialRetryMs: 10_000 })
    render(<RemoteSyncBadge providerId="claude" />)
    await waitFor(() => expect(badge()).toHaveTextContent(/^Live$/))
    server.connections[0].fail()
    await waitFor(() => expect(badge()).toHaveTextContent('Reconnecting'))
  })

  it('does not claim Live before this tab has a stream at all', async () => {
    withState(state({ mode: 'stream' }))
    vi.stubGlobal('fetch', () => new Promise(() => undefined))
    render(<RemoteSyncBadge providerId="claude" />)
    await waitFor(() => expect(badge()).toHaveTextContent('Connecting'))
  })

  it('reports an unavailable sync state rather than hiding a failure', async () => {
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockRejectedValue(new Error('down'))
    render(<RemoteSyncBadge providerId="claude" />)
    await waitFor(() => expect(badge()).toHaveTextContent('Sync state unavailable'))
  })

  it('announces changes politely', async () => {
    withState(state({}))
    render(<RemoteSyncBadge providerId="claude" />)
    await waitFor(() => expect(badge()).toHaveAttribute('aria-live', 'polite'))
  })
})
