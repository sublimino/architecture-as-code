// The Stun action must leave an auditable trace in BOTH modes.
//
// Demo mode short-circuits in client.ts to resolveFake(); live mode issues a
// real POST. This file pins down the demo half end-to-end — stun, then read the
// audit list back through the very same api.audit() call the Audit Trail page
// makes — and pins down that the live half issues the request the backend
// endpoint expects. The rendering half is covered by
// SuperCredPage.test.tsx and AuditTrail rendering.

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'

// client.ts builds its axios instance once at module load, and axios.create()
// binds `request` onto that instance — patching Axios.prototype afterwards has
// no effect. Replace the module so the instance client.ts holds is ours.
const { request } = vi.hoisted(() => ({ request: vi.fn() }))
vi.mock('axios', () => ({
  default: { create: () => ({ request }) },
}))

import { api } from './client'
import { setDemoMode } from './demoMode'
import { clearDemoActivity, demoActivityEvents } from './demoActivity'

const TOKEN = 'test-token'
// Operator input, not a claim about what happened: the server requires it
// (422 without it) and records it alongside the actor it read off the token.
const REASON = 'exfiltration to unknown host'

beforeEach(() => {
  clearDemoActivity()
  request.mockReset()
  request.mockResolvedValue({ data: { agent_id: 'agent-cardvault' } })
})

afterEach(() => {
  setDemoMode(false)
})

describe('stun activity — demo mode', () => {
  beforeEach(() => {
    setDemoMode(true)
  })

  it('resolves a fixture rather than issuing HTTP', async () => {
    const res = await api.agents.stun(TOKEN, 'agent-cardvault', REASON)
    expect(request).not.toHaveBeenCalled()
    expect(res.agent_id).toBe('agent-cardvault')
    expect(res.to_state).toBe('suspended')
    expect(res.event.event_type).toBe('agent.stunned')
  })

  it('records an event carrying timestamp, agent id, action, actor and outcome', async () => {
    await api.agents.stun(TOKEN, 'agent-cardvault', REASON)

    const [event] = demoActivityEvents()
    expect(event.event_type).toBe('agent.stunned')
    expect(event.agent_id).toBe('agent-cardvault')
    expect(event.agent_name).toBe('Cardvault Agent')
    expect(event.actor).toMatch(/\S/)
    // `outcome` is authored by the fixture standing in for the server. The
    // reason is the operator's own input, which the server records verbatim.
    expect(event.detail).toMatchObject({ outcome: 'stunned', reason: REASON })
    expect(Number.isNaN(Date.parse(event.timestamp))).toBe(false)
  })

  it('surfaces the recorded event through the audit list the timeline reads', async () => {
    const before = await api.audit(TOKEN, { page: 1, limit: 50 })
    const baseline = before.total

    await api.agents.stun(TOKEN, 'agent-cardvault', REASON)

    const after = await api.audit(TOKEN, { page: 1, limit: 50 })
    expect(after.total).toBe(baseline + 1)
    // Newest first — a fresh action belongs at the top of the trail.
    expect(after.events[0].event_type).toBe('agent.stunned')
    expect(after.events[0].agent_id).toBe('agent-cardvault')
  })

  it('answers with a per-plane report, and a realistic partial one', async () => {
    const res = await api.agents.stun(TOKEN, 'agent-cardvault', REASON)
    expect(res.reason).toBe(REASON)
    expect(res.overall_outcome).toBe('partial')
    expect(res.planes.map(p => p.plane)).toEqual(['freeze', 'bao', 'spire', 'mesh', 'admission', 'gitops'])
    // Partial means at least one plane did not contain, or the overall word lies.
    expect(res.planes.some(p => p.outcome !== 'contained')).toBe(true)
    for (const p of res.planes) expect(Number.isNaN(Date.parse(p.timestamp))).toBe(false)
    // The audit event carries the same planes the Audit Trail strip reads.
    expect(res.event.detail).toMatchObject({ overall_outcome: 'partial', planes: res.planes })
  })

  it('refuses a stun with no reason, as the server does', async () => {
    await expect(api.agents.stun(TOKEN, 'agent-cardvault', '   ')).rejects.toThrow(/reason/i)
    expect(demoActivityEvents()).toEqual([])
  })

  it('keeps the pre-existing fixture events alongside the recorded one', async () => {
    await api.agents.stun(TOKEN, 'agent-cardvault', REASON)
    const after = await api.audit(TOKEN, { page: 1, limit: 50 })
    expect(after.events.map(e => e.event_type)).toContain('agent.registered')
  })
})

describe('stun activity — live mode', () => {
  beforeEach(() => {
    setDemoMode(false)
  })

  it('POSTs to the fe-signalloom stun endpoint that performs and records the stun', async () => {
    await api.agents.stun(TOKEN, 'agent-cardvault', REASON)

    expect(request).toHaveBeenCalledWith(
      expect.objectContaining({
        url: '/api/agents/agent-cardvault/stun',
        method: 'POST',
      }),
    )
  })

  it('sends the operator reason as the whole JSON body, and nothing else', async () => {
    await api.agents.stun(TOKEN, 'agent-cardvault', REASON)

    // Exact equality, not objectContaining: the reason is operator input the
    // server requires, and nothing that narrates an outcome may ride along.
    const [config] = request.mock.calls[0] as [{ data?: unknown }]
    expect(config.data).toEqual({ reason: REASON })
  })

  it('carries the bearer token so the audit row is attributed to the tenant', async () => {
    await api.agents.stun(TOKEN, 'agent-cardvault', REASON)

    expect(request).toHaveBeenCalledWith(
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: `Bearer ${TOKEN}` }),
      }),
    )
  })

  it('records nothing in the demo log — the backend owns the live trace', async () => {
    await api.agents.stun(TOKEN, 'agent-cardvault', REASON)

    expect(demoActivityEvents()).toEqual([])
  })
})
