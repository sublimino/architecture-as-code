import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { AxiosError, AxiosHeaders } from 'axios'
import { claimRemoteAgent, connectorsApi, liveConnectorsApi, mockConnectorsApi, http, type RemoteAgentsSnapshot } from './connectorsClient'
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

describe('claimRemoteAgent', () => {
  const CLAIM = {
    agent_id: '5b1c0d9e-0000-5000-8000-000000000001', agent_name: 'claude:agent_1@tenant-a', display_name: 'Triage',
    provider_id: 'claude', connector_id: 'conn-claude-01', external_id: 'agent_1', kind: 'agent',
    model: 'claude-opus-4-7', claimed_at: '2026-10-16T10:00:00Z', created: true,
  }

  it('POSTs the claim for that provider and external id with the bearer token', async () => {
    setDemoMode(false)
    const spy = vi.spyOn(http, 'request').mockResolvedValue({ data: CLAIM })
    await expect(claimRemoteAgent('tok', 'claude', 'agent/1')).resolves.toEqual(CLAIM)
    expect(spy).toHaveBeenCalledWith(
      expect.objectContaining({
        url: '/api/connectors/claude/remote-agents/agent%2F1/claim',
        method: 'POST',
        headers: expect.objectContaining({ Authorization: 'Bearer tok' }),
      }),
    )
  })

  it('propagates a refusal (409 remote_agent_gone) rather than reporting success', async () => {
    setDemoMode(false)
    vi.spyOn(http, 'request').mockRejectedValue(httpError(409, 'remote_agent_gone'))
    await expect(claimRemoteAgent('tok', 'claude', 'agent_1')).rejects.toBeInstanceOf(AxiosError)
  })

  it('never fakes a claim in demo mode', async () => {
    setDemoMode(true)
    const spy = vi.spyOn(http, 'request')
    await expect(claimRemoteAgent('demo', 'claude', 'agent_1')).rejects.toThrow(/demo/i)
    expect(spy).not.toHaveBeenCalled()
  })
})
