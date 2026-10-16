import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { connectorsApi, type RemoteAgent, type RemoteAgentsSnapshot } from '../api/connectorsClient'
import { setDemoMode } from '../api/demoMode'
import { createSseTestServer, type SseTestServer } from '../api/__fixtures__/sseServer'
import { connectorStreamStore, useRemoteAgents } from './useConnectorStream'

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently: () => Promise.resolve('hook-token') }),
}))

function agent(external_id: string, over: Partial<RemoteAgent> = {}): RemoteAgent {
  return {
    external_id,
    kind: 'agent',
    name: external_id,
    model: 'claude-sonnet-4-5',
    status: 'idle',
    version: 1,
    external_updated_at: null,
    first_seen_at: '2026-10-16T09:00:00Z',
    last_seen_at: '2026-10-16T10:00:00Z',
    last_changed_at: '2026-10-16T09:30:00Z',
    gone_at: null,
    ...over,
  }
}

function snapshot(providerId: string, agents: RemoteAgent[], connectorId = `conn-${providerId}`): RemoteAgentsSnapshot {
  return {
    provider_id: providerId,
    connector_id: connectorId,
    sync_state: { mode: 'stream', last_poll_at: null, last_success_at: '2026-10-16T10:00:00Z', last_error: null, next_poll_at: null },
    agents,
  }
}

function frame(event: string, body: unknown, id?: string): string {
  return `${id ? `id: ${id}\n` : ''}event: ${event}\ndata: ${JSON.stringify(body)}\n\n`
}

const upsert = (providerId: string, a: RemoteAgent, connectorId = `conn-${providerId}`) =>
  frame('remote_agent.upserted', { provider_id: providerId, connector_id: connectorId, agent: a })

let server: SseTestServer
const token = () => Promise.resolve('tok')
const unsubs: Array<() => void> = []
const sub = (providerId: string) => {
  const u = connectorStreamStore.subscribe(providerId, token)
  unsubs.push(u)
  return u
}
const view = (providerId: string) => connectorStreamStore.getState().providers[providerId]
const names = (providerId: string) => view(providerId)?.agents.map((a) => `${a.external_id}:${a.status}${a.gone_at ? ':gone' : ''}`)

beforeEach(() => {
  vi.restoreAllMocks()
  server = createSseTestServer()
  vi.stubGlobal('fetch', server.fetch)
  setDemoMode(false)
})

afterEach(() => {
  unsubs.splice(0).forEach((u) => u())
  connectorStreamStore.reset()
  vi.unstubAllGlobals()
  setDemoMode(true)
})

describe('connector stream store (live mode)', () => {
  it('loads the snapshot and opens exactly one authenticated stream', async () => {
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockResolvedValue(snapshot('claude', [agent('a1')]))
    sub('claude')
    await vi.waitFor(() => expect(view('claude')?.status).toBe('ready'))
    expect(names('claude')).toEqual(['a1:idle'])
    expect(view('claude')?.syncState?.mode).toBe('stream')
    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('open'))
    expect(server.connections).toHaveLength(1)
    expect(server.connections[0].headers.Authorization).toBe('Bearer tok')
  })

  it('shares one connection across every subscriber and provider in the tab', async () => {
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockImplementation(async (_t, p) => snapshot(p, []))
    sub('claude')
    sub('claude')
    sub('openai')
    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('open'))
    expect(server.connections).toHaveLength(1)
  })

  it('applies upserts in place and appends agents it has not seen', async () => {
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockResolvedValue(snapshot('claude', [agent('a1'), agent('a2')]))
    sub('claude')
    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('open'))
    await vi.waitFor(() => expect(view('claude')?.status).toBe('ready'))
    server.connections[0].send(upsert('claude', agent('a1', { status: 'running' })))
    server.connections[0].send(upsert('claude', agent('a3', { status: 'running' })))
    await vi.waitFor(() => expect(names('claude')).toEqual(['a1:running', 'a2:idle', 'a3:running']))
  })

  it('marks gone agents as gone and keeps them in place', async () => {
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockResolvedValue(snapshot('claude', [agent('a1'), agent('a2')]))
    sub('claude')
    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('open'))
    await vi.waitFor(() => expect(view('claude')?.status).toBe('ready'))
    server.connections[0].send(
      frame('remote_agent.gone', { provider_id: 'claude', connector_id: 'conn-claude', external_id: 'a1', gone_at: '2026-10-16T11:00:00Z' }),
    )
    await vi.waitFor(() => expect(names('claude')).toEqual(['a1:idle:gone', 'a2:idle']))
    expect(view('claude')?.agents[0].gone_at).toBe('2026-10-16T11:00:00Z')
  })

  it('routes events by provider: another provider never changes this one, unsubscribed providers are not created', async () => {
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockImplementation(async (_t, p) => snapshot(p, [agent(`${p}-1`)]))
    sub('claude')
    sub('openai')
    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('open'))
    await vi.waitFor(() => expect(view('openai')?.status).toBe('ready'))
    await vi.waitFor(() => expect(view('claude')?.status).toBe('ready'))
    server.connections[0].send(upsert('openai', agent('o-new')))
    server.connections[0].send(upsert('mistral', agent('m-1')))
    await vi.waitFor(() => expect(names('openai')).toEqual(['openai-1:idle', 'o-new:idle']))
    expect(names('claude')).toEqual(['claude-1:idle'])
    expect(view('mistral')).toBeUndefined()
  })

  it('replaces sync state from connector.sync_state events', async () => {
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockResolvedValue(snapshot('claude', []))
    sub('claude')
    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('open'))
    await vi.waitFor(() => expect(view('claude')?.status).toBe('ready'))
    const sync_state = { mode: 'poll', last_poll_at: '2026-10-16T11:00:00Z', last_success_at: null, last_error: 'HTTP 429 from provider', next_poll_at: '2026-10-16T11:01:00Z' }
    server.connections[0].send(frame('connector.sync_state', { provider_id: 'claude', connector_id: 'conn-claude', sync_state }))
    await vi.waitFor(() => expect(view('claude')?.syncState).toEqual(sync_state))
  })

  it('refetches the snapshot after a reconnect so missed changes cannot drift', async () => {
    // The server's state changes while the stream is down; only a refetch can see it.
    let serverState = snapshot('claude', [agent('a1')])
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockImplementation(async () => serverState)
    connectorStreamStore.configure({ initialRetryMs: 5 })
    sub('claude')
    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('open'))
    await vi.waitFor(() => expect(names('claude')).toEqual(['a1:idle']))
    await new Promise((r) => setTimeout(r, 10))
    serverState = snapshot('claude', [agent('a1', { status: 'running' }), agent('a2')])
    server.connections[0].fail()
    await vi.waitFor(() => expect(server.connections).toHaveLength(2))
    await vi.waitFor(() => expect(names('claude')).toEqual(['a1:running', 'a2:idle']))
  })

  it('refetches every subscribed snapshot on stream.reset, on the same open connection', async () => {
    // The server could not replay from our Last-Event-ID: whatever it would have
    // sent is lost, so only a fresh snapshot is correct.
    let claudeState = snapshot('claude', [agent('a1')])
    const list = vi
      .spyOn(connectorsApi, 'listRemoteAgents')
      .mockImplementation(async (_t, p) => (p === 'claude' ? claudeState : snapshot(p, [agent('o1')])))
    sub('claude')
    sub('openai')
    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('open'))
    await vi.waitFor(() => expect(names('claude')).toEqual(['a1:idle']))
    await vi.waitFor(() => expect(view('openai')?.status).toBe('ready'))
    const callsBefore = list.mock.calls.length
    claudeState = snapshot('claude', [agent('a1', { status: 'running' }), agent('a2')])
    server.connections[0].send(frame('stream.reset', {}))
    await vi.waitFor(() => expect(names('claude')).toEqual(['a1:running', 'a2:idle']))
    const refetched = list.mock.calls.slice(callsBefore).map((c) => c[1]).sort()
    expect(refetched).toEqual(['claude', 'openai'])
    expect(server.connections).toHaveLength(1)
  })

  it('replays events that arrive while a snapshot is in flight on top of it', async () => {
    const pending: Array<(s: RemoteAgentsSnapshot) => void> = []
    const list = vi
      .spyOn(connectorsApi, 'listRemoteAgents')
      .mockResolvedValueOnce(snapshot('claude', [agent('a1')]))
      .mockImplementation(() => new Promise((r) => pending.push(r)))
    sub('claude')
    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('open'))
    // Opening the stream starts a refetch; it is still in flight.
    await vi.waitFor(() => expect(list).toHaveBeenCalledTimes(2))
    await vi.waitFor(() => expect(names('claude')).toEqual(['a1:idle']))
    server.connections[0].send(upsert('claude', agent('a1', { status: 'running' })))
    await vi.waitFor(() => expect(names('claude')).toEqual(['a1:running']))
    // That snapshot was read before the event: it must not roll a1 back.
    act(() => pending[0](snapshot('claude', [agent('a1', { status: 'idle' }), agent('a9')])))
    await vi.waitFor(() => expect(names('claude')).toEqual(['a1:running', 'a9:idle']))
  })

  it('refetches instead of applying an event from a different connector', async () => {
    let serverState = snapshot('claude', [agent('a1')], 'conn-old')
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockImplementation(async () => serverState)
    sub('claude')
    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('open'))
    await vi.waitFor(() => expect(view('claude')?.connectorId).toBe('conn-old'))
    await new Promise((r) => setTimeout(r, 10))
    serverState = snapshot('claude', [agent('b1')], 'conn-new')
    server.connections[0].send(upsert('claude', agent('b2'), 'conn-new'))
    await vi.waitFor(() => expect(view('claude')?.connectorId).toBe('conn-new'))
    expect(names('claude')).toEqual(['b1:idle'])
  })

  it('reports not_configured when the API says the provider has no connector', async () => {
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockResolvedValue(null)
    sub('claude')
    await vi.waitFor(() => expect(view('claude')?.status).toBe('not_configured'))
  })

  it('reports a snapshot failure as an error, not an empty list', async () => {
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockRejectedValue(new Error('boom from API'))
    sub('claude')
    await vi.waitFor(() => expect(view('claude')?.status).toBe('error'))
    expect(view('claude')?.error).toMatch(/boom from API/)
  })

  it('shows reconnecting with the reason while the stream is down', async () => {
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockResolvedValue(snapshot('claude', []))
    connectorStreamStore.configure({ initialRetryMs: 10_000 })
    sub('claude')
    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('open'))
    server.connections[0].fail(new TypeError('network down'))
    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('reconnecting'))
    expect(connectorStreamStore.getState().connection.error).toMatch(/network down/)
    expect(connectorStreamStore.getState().connection.retryInMs).toBe(10_000)
  })

  it('closes the stream when the last subscriber leaves', async () => {
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockResolvedValue(snapshot('claude', []))
    const a = sub('claude')
    const b = sub('openai')
    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('open'))
    a()
    expect(server.connections[0].signal?.aborted).toBe(false)
    b()
    expect(server.connections[0].signal?.aborted).toBe(true)
    expect(connectorStreamStore.getState().connection.status).toBe('idle')
  })
})

describe('connector stream store (demo mode)', () => {
  it('opens no stream and answers from the demo fixture through the client', async () => {
    setDemoMode(true)
    sub('claude')
    await vi.waitFor(() => expect(view('claude')?.status).toBe('ready'))
    expect(view('claude')?.agents.map((a) => a.name)).toContain('Daily News Jokester')
    expect(connectorStreamStore.getState().connection.status).toBe('demo')
    expect(server.connections).toHaveLength(0)
  })

  it('drops demo state and goes live when demo mode is switched off without a reload', async () => {
    setDemoMode(true)
    sub('claude')
    await vi.waitFor(() => expect(view('claude')?.status).toBe('ready'))
    const live = vi.spyOn(connectorsApi, 'listRemoteAgents').mockResolvedValue(snapshot('claude', [agent('live-1')]))

    act(() => setDemoMode(false))

    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('open'))
    await vi.waitFor(() => expect(names('claude')).toEqual(['live-1:idle']))
    expect(live).toHaveBeenCalled()
    expect(JSON.stringify(connectorStreamStore.getState())).not.toContain('Daily News Jokester')
  })

  it('closes the live stream and drops live state when demo mode is switched on', async () => {
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockResolvedValueOnce(snapshot('claude', [agent('live-1')]))
    sub('claude')
    await vi.waitFor(() => expect(connectorStreamStore.getState().connection.status).toBe('open'))
    vi.mocked(connectorsApi.listRemoteAgents).mockRestore()

    act(() => setDemoMode(true))

    expect(server.connections[0].signal?.aborted).toBe(true)
    await vi.waitFor(() => expect(view('claude')?.agents.map((a) => a.name)).toContain('Daily News Jokester'))
    expect(names('claude')).not.toContain('live-1:idle')
    expect(connectorStreamStore.getState().connection.status).toBe('demo')
  })
})

describe('useRemoteAgents', () => {
  it('subscribes with the session token and unsubscribes on unmount', async () => {
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockResolvedValue(snapshot('claude', [agent('a1')]))
    const { result, unmount } = renderHook(() => useRemoteAgents('claude'))
    await vi.waitFor(() => expect(result.current.view.status).toBe('ready'))
    expect(result.current.view.agents.map((a) => a.external_id)).toEqual(['a1'])
    await vi.waitFor(() => expect(result.current.connection.status).toBe('open'))
    expect(server.connections[0].headers.Authorization).toBe('Bearer hook-token')
    unmount()
    expect(server.connections[0].signal?.aborted).toBe(true)
  })

  it('reports loading before the first snapshot', () => {
    vi.spyOn(connectorsApi, 'listRemoteAgents').mockReturnValue(new Promise(() => undefined))
    const { result } = renderHook(() => useRemoteAgents('claude'))
    expect(result.current.view.status).toBe('loading')
    expect(result.current.view.agents).toEqual([])
  })
})
