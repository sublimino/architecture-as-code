import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { AxiosError, AxiosHeaders } from 'axios'
import { connectorsApi, liveConnectorsApi, mockConnectorsApi, http, type RemoteAgentsSnapshot } from './connectorsClient'
import { setDemoMode } from './demoMode'
import { remoteEnvironmentFixtures } from './fakeData'

function httpError(status: number, code: string): AxiosError {
  return new AxiosError(`Request failed with status code ${status}`, 'ERR_BAD_RESPONSE', undefined, undefined, {
    status,
    statusText: '',
    headers: {},
    config: { headers: new AxiosHeaders() },
    data: { error: { code, message: code } },
  })
}

const SNAPSHOT: RemoteAgentsSnapshot = {
  provider_id: 'claude',
  connector_id: 'conn-live-7',
  sync_state: { mode: 'poll', last_poll_at: '2026-10-16T10:00:00Z', last_success_at: '2026-10-16T10:00:00Z', last_error: null, next_poll_at: '2026-10-16T10:00:30Z' },
  agents: [],
}

beforeEach(() => vi.restoreAllMocks())
afterEach(() => setDemoMode(true))

describe('listRemoteAgents (live)', () => {
  it('GETs the provider remote-agents snapshot with the bearer token', async () => {
    const spy = vi.spyOn(http, 'request').mockResolvedValue({ data: SNAPSHOT })
    await expect(liveConnectorsApi.listRemoteAgents('tok', 'claude')).resolves.toEqual(SNAPSHOT)
    expect(spy).toHaveBeenCalledWith(
      expect.objectContaining({
        url: '/api/connectors/claude/remote-agents',
        method: 'GET',
        headers: expect.objectContaining({ Authorization: 'Bearer tok' }),
      }),
    )
  })

  it('returns null for 404 connector_not_configured, an honest "not connected"', async () => {
    vi.spyOn(http, 'request').mockRejectedValue(httpError(404, 'connector_not_configured'))
    await expect(liveConnectorsApi.listRemoteAgents('tok', 'claude')).resolves.toBeNull()
  })

  it('propagates every other failure', async () => {
    vi.spyOn(http, 'request').mockRejectedValue(httpError(502, 'upstream_error'))
    await expect(liveConnectorsApi.listRemoteAgents('tok', 'claude')).rejects.toBeInstanceOf(AxiosError)
  })
})

describe('listRemoteAgents (mode dispatch)', () => {
  it('never touches HTTP in demo mode and answers from the demo fixture', async () => {
    setDemoMode(true)
    const spy = vi.spyOn(http, 'request')
    const snap = await connectorsApi.listRemoteAgents('demo', 'claude')
    expect(spy).not.toHaveBeenCalled()
    expect(snap?.agents.map((a) => a.name)).toContain('Daily News Jokester')
  })

  it('goes to HTTP in live mode', async () => {
    setDemoMode(false)
    const spy = vi.spyOn(http, 'request').mockResolvedValue({ data: SNAPSHOT })
    await connectorsApi.listRemoteAgents('tok', 'claude')
    expect(spy).toHaveBeenCalledTimes(1)
  })

  it('keeps the demo snapshot consistent with the demo environment fixture', async () => {
    for (const providerId of ['claude', 'openai'] as const) {
      const snap = await mockConnectorsApi.listRemoteAgents('demo', providerId)
      const present = snap!.agents.filter((a) => a.gone_at === null).map((a) => a.name)
      expect(present, providerId).toEqual(remoteEnvironmentFixtures[providerId].connectedAgents.map((a) => a.name))
      expect(snap!.provider_id).toBe(providerId)
    }
  })

  it('has no demo snapshot for providers without a remote environment', async () => {
    await expect(mockConnectorsApi.listRemoteAgents('demo', 'okta')).resolves.toBeNull()
  })
})
