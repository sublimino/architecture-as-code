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

// Locator only. `reason` and `outcome` were removed from StunAgentRequest —
// the server authors the narrative from what it observed, and the endpoint is
// extra="forbid", so sending them now fails the request outright.
const STUN_BODY = {
  agent_name: 'Cardvault Agent',
  namespace: 'fe-signalloom',
}

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
    const res = await api.agents.stun(TOKEN, 'agent-cardvault', STUN_BODY)
    expect(request).not.toHaveBeenCalled()
    expect(res.agent_id).toBe('agent-cardvault')
    expect(res.to_state).toBe('suspended')
    expect(res.event.event_type).toBe('agent.stunned')
  })

  it('records an event carrying timestamp, agent id, action, actor and outcome', async () => {
    await api.agents.stun(TOKEN, 'agent-cardvault', STUN_BODY)

    const [event] = demoActivityEvents()
    expect(event.event_type).toBe('agent.stunned')
    expect(event.agent_id).toBe('agent-cardvault')
    expect(event.agent_name).toBe('Cardvault Agent')
    expect(event.actor).toMatch(/\S/)
    // Authored by the fixture standing in for the server, not echoed from the
    // request — STUN_BODY no longer has an `outcome` to echo.
    expect(event.detail).toMatchObject({ outcome: 'stunned', reason: 'operator-initiated stun' })
    expect(Number.isNaN(Date.parse(event.timestamp))).toBe(false)
  })

  it('surfaces the recorded event through the audit list the timeline reads', async () => {
    const before = await api.audit(TOKEN, { page: 1, limit: 50 })
    const baseline = before.total

    await api.agents.stun(TOKEN, 'agent-cardvault', STUN_BODY)

    const after = await api.audit(TOKEN, { page: 1, limit: 50 })
    expect(after.total).toBe(baseline + 1)
    // Newest first — a fresh action belongs at the top of the trail.
    expect(after.events[0].event_type).toBe('agent.stunned')
    expect(after.events[0].agent_id).toBe('agent-cardvault')
  })

  it('keeps the pre-existing fixture events alongside the recorded one', async () => {
    await api.agents.stun(TOKEN, 'agent-cardvault', STUN_BODY)
    const after = await api.audit(TOKEN, { page: 1, limit: 50 })
    expect(after.events.map(e => e.event_type)).toContain('agent.registered')
  })
})

describe('stun activity — live mode', () => {
  beforeEach(() => {
    setDemoMode(false)
  })

  it('POSTs to the fe-signalloom stun endpoint that writes the audit row', async () => {
    await api.agents.stun(TOKEN, 'agent-cardvault', STUN_BODY)

    expect(request).toHaveBeenCalledWith(
      expect.objectContaining({
        url: '/api/agents/agent-cardvault/stun',
        method: 'POST',
        data: STUN_BODY,
      }),
    )
  })

  it('carries the bearer token so the audit row is attributed to the tenant', async () => {
    await api.agents.stun(TOKEN, 'agent-cardvault', STUN_BODY)

    expect(request).toHaveBeenCalledWith(
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: `Bearer ${TOKEN}` }),
      }),
    )
  })

  it('records nothing in the demo log — the backend owns the live trace', async () => {
    await api.agents.stun(TOKEN, 'agent-cardvault', STUN_BODY)

    expect(demoActivityEvents()).toEqual([])
  })
})
