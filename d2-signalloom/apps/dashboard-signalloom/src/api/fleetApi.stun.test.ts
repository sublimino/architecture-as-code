import { afterEach, describe, expect, it, vi } from 'vitest'
import { stunFleetAgent } from './fleetApi'

// fleet-manager now answers 400 to a stun with no body, and records the
// reason on the stun-reason annotations. These pin the request the dashboard
// sends and how each verdict status reaches the page.

const json = (status: number, body: unknown) =>
  ({
    ok: status >= 200 && status < 300,
    status,
    statusText: String(status),
    headers: new Headers({ 'content-type': 'application/json' }),
    json: async () => body,
    text: async () => JSON.stringify(body),
  }) as unknown as Response

const CASCADE = {
  target_agent: 'agent-cardvault',
  affected_agents: ['agent-cardvault', 'agent-pipeline'],
  duration_ms: 420,
  overall_outcome: 'partial',
  planes: [
    { plane: 'gitops', outcome: 'contained', timestamp: '2026-09-29T10:00:00Z' },
    { plane: 'gitops', outcome: 'not_found', timestamp: '2026-09-29T10:00:01Z', error: 'no Kustomization owns it' },
  ],
}

afterEach(() => vi.unstubAllGlobals())

describe('stunFleetAgent', () => {
  it('POSTs exactly {agent_id, reason} with the bearer token', async () => {
    const fetchMock = vi.fn().mockResolvedValue(json(207, CASCADE))
    vi.stubGlobal('fetch', fetchMock)

    await stunFleetAgent('agent-cardvault', 'tok', 'exfiltration to unknown host')

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toMatch(/\/stun\/agent-cardvault$/)
    expect(init.method).toBe('POST')
    expect(JSON.parse(String(init.body))).toEqual({ agent_id: 'agent-cardvault', reason: 'exfiltration to unknown host' })
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer tok')
    expect((init.headers as Record<string, string>)['Content-Type']).toBe('application/json')
  })

  it('returns the per-plane result of a partial (207) stun', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json(207, CASCADE)))
    const res = await stunFleetAgent('agent-cardvault', 'tok', 'r')
    expect(res.overall_outcome).toBe('partial')
    expect(res.planes).toHaveLength(2)
  })

  // A failed or not-found cascade is still a full report: fleet-manager writes
  // the body under 500/404. Throwing it away would hide which plane failed.
  it('returns a failed cascade report rather than discarding it', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json(500, { ...CASCADE, overall_outcome: 'failed' })))
    const res = await stunFleetAgent('agent-cardvault', 'tok', 'r')
    expect(res.overall_outcome).toBe('failed')
  })

  it('throws on a 400 rejection, naming the server error', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json(400, { error: 'reason is 300 characters, maximum 256' })))
    await expect(stunFleetAgent('agent-cardvault', 'tok', 'r')).rejects.toThrow(/Fleet API 400: .*maximum 256/)
  })
})
