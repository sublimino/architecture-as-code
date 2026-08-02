import { describe, it, expect, beforeEach, vi } from 'vitest'

const { requestMock } = vi.hoisted(() => ({
  requestMock: vi.fn(),
}))

// Prove the demo toggle renders data even when the API is completely down:
// every real HTTP call rejects, yet demo mode still resolves fixtures.
vi.mock('axios', () => ({
  default: {
    create: () => ({
      request: requestMock,
    }),
  },
}))

import { api } from './client'
import { setDemoMode } from './demoMode'
import { FAKE_ROUTE_COUNT, resolveFake } from './fakeData'

const INVENTORY_AGENT_ID = 'tenant-demo:agent-inventory'
const TRIAGE_AGENT_ID = 'tenant-demo:agent-triage'
const SANDBOX_AGENT_ID = 'tenant-demo:agent-sandbox'
const REPORTER_AGENT_ID = 'tenant-demo:agent-reporter'

describe('demo mode', () => {
  beforeEach(() => {
    setDemoMode(false)
    requestMock.mockReset()
    requestMock.mockRejectedValue(new Error('API down'))
  })

  it('covers the full 36-route client fixture surface', () => {
    expect(FAKE_ROUTE_COUNT).toBe(36)
  })

  it('renders fixtures even though every HTTP call fails', async () => {
    setDemoMode(true)
    const agents = await api.agents.list('tok')
    expect(agents.total).toBe(6)
    expect(agents.agents).toHaveLength(6)
    expect(agents.agents[0].compliance_summary.passing).toBe(10)

    const summary = await api.compliance.summary('tok')
    expect(summary).toHaveProperty('controls_passing')

    const audit = await api.audit('tok', { page: 1 })
    expect(audit.events[0]).toHaveProperty('timestamp')

    const settings = await api.settings('tok')
    expect(settings.tenant_id).toBe('tenant-demo')
  })

  it('reflects a PATCH body in the fixture (stateful-ish)', async () => {
    setDemoMode(true)
    const s = await api.patchFrameworks('tok', ['soc2', 'eu-ai-act'])
    expect(s.selected_frameworks).toEqual(['soc2', 'eu-ai-act'])
  })

  it('falls through to the live API when demo mode is off', async () => {
    setDemoMode(false)
    await expect(api.agents.list('tok')).rejects.toThrow('API down')
  })

  it('matches the revoke fixture for POST /agents/{id}/credentials/revoke', () => {
    const response = resolveFake('POST', `/agents/${INVENTORY_AGENT_ID}/credentials/revoke`)

    expect(response).toBeDefined()
    expect(response).toMatchObject({
      agent_id: INVENTORY_AGENT_ID,
      tokens_revoked: 1,
      simulated: true,
    })
    expect(response).not.toHaveProperty('identity_token')
  })

  it('resolves revoke in demo mode without touching the live HTTP client', async () => {
    setDemoMode(true)

    const response = await api.agents.revokeCredential('tok', INVENTORY_AGENT_ID)

    expect(response).toMatchObject({
      agent_id: INVENTORY_AGENT_ID,
      tokens_revoked: 1,
      simulated: true,
    })
    expect(requestMock).not.toHaveBeenCalled()
  })

  it('tracks active credential count across issue and revoke operations in demo mode', async () => {
    setDemoMode(true)

    const firstRevoke = await api.agents.revokeCredential('tok', TRIAGE_AGENT_ID)
    expect(firstRevoke.tokens_revoked).toBe(2)

    const secondRevoke = await api.agents.revokeCredential('tok', TRIAGE_AGENT_ID)
    expect(secondRevoke.tokens_revoked).toBe(0)

    await api.agents.issueCredential('tok', INVENTORY_AGENT_ID)
    const revokeAfterIssue = await api.agents.revokeCredential('tok', INVENTORY_AGENT_ID)
    expect(revokeAfterIssue.tokens_revoked).toBe(2)
  })

  it('returns the requested agent id in demo mode instead of the first agent', async () => {
    setDemoMode(true)

    const agent = await api.agents.get('tok', REPORTER_AGENT_ID)

    expect(agent.id).toBe(REPORTER_AGENT_ID)
    expect(agent.name).toBe('Compliance Reporter')
  })

  it('fails loudly with a 404 when a demo agent id is unknown', async () => {
    setDemoMode(true)

    try {
      await api.agents.get('tok', 'tenant-demo:missing-agent')
      throw new Error('Expected api.agents.get to reject for an unknown demo agent id.')
    } catch (err: unknown) {
      expect(err).toBeInstanceOf(Error)
      expect(err).toMatchObject({
        status: 404,
        response: { status: 404 },
      })
      expect((err as Error).message).toContain('Demo fixture not found for GET /agents/tenant-demo:missing-agent')
    }
  })

  it('applies demo transitions so a following GET reflects the new lifecycle state', async () => {
    setDemoMode(true)

    const transition = await api.agents.transition('tok', SANDBOX_AGENT_ID, {
      to_state: 'active',
      reason: 'Operator approved activation',
    })
    const updated = await api.agents.get('tok', SANDBOX_AGENT_ID)

    expect(transition).toMatchObject({
      agent_id: SANDBOX_AGENT_ID,
      from_state: 'enrolled',
      to_state: 'active',
      reason: 'Operator approved activation',
      simulated: true,
    })
    expect(updated.lifecycle_state).toBe('active')
  })

  it('rejects a demo transition with a missing to_state', async () => {
    setDemoMode(true)

    await expect(
      api.agents.transition('tok', SANDBOX_AGENT_ID, { reason: 'Missing target state' } as never),
    ).rejects.toThrow('Demo transition requires a non-empty to_state.')
  })

  it('rejects a demo transition with a blank reason', async () => {
    setDemoMode(true)

    await expect(
      api.agents.transition('tok', SANDBOX_AGENT_ID, {
        to_state: 'active',
        reason: '   ',
      }),
    ).rejects.toThrow('Demo transition requires a non-empty reason.')
  })

  it('persists registered demo agents in subsequent list and detail calls', async () => {
    setDemoMode(true)

    const created = await api.agents.register('tok', {
      name: 'Budget Bot',
      type: 'Custom',
      description: 'Tracks spend',
      owner: 'finance-team',
    })
    const createdDuplicate = await api.agents.register('tok', {
      name: 'Budget Bot',
      type: 'Custom',
      description: 'Tracks spend again',
      owner: 'finance-team',
    })
    const listed = await api.agents.list('tok')
    const fetched = await api.agents.get('tok', created.id)

    expect(created.id).toBe('tenant-demo:agent-budget-bot')
    expect(createdDuplicate.id).toBe('tenant-demo:agent-budget-bot-2')
    expect(createdDuplicate.id).not.toBe(created.id)
    expect(listed.total).toBe(8)
    expect(listed.agents.map((agent) => agent.id)).toEqual(
      expect.arrayContaining([created.id, createdDuplicate.id]),
    )
    expect(fetched).toEqual(created)
  })

  it('uses the live HTTP client unchanged for credential issue', async () => {
    setDemoMode(false)
    const payload = {
      agent_id: INVENTORY_AGENT_ID,
      name: 'Inventory Agent',
      identity_token: 'live.jwt.token',
      token_expires_at: '2026-08-27T12:00:00Z',
      token_note: 'Live token',
    }
    requestMock.mockResolvedValueOnce({ data: payload })

    const result = await api.agents.issueCredential('live-token', INVENTORY_AGENT_ID)

    expect(requestMock).toHaveBeenCalledWith(expect.objectContaining({
      url: `/api/agents/${INVENTORY_AGENT_ID}/credentials`,
      method: 'POST',
      headers: expect.objectContaining({
        Authorization: 'Bearer live-token',
        'Content-Type': 'application/json',
      }),
    }))
    expect(result).toBe(payload)
    expect(result).not.toHaveProperty('simulated')
  })

  it('uses the live HTTP client unchanged for credential revoke', async () => {
    setDemoMode(false)
    const payload = {
      agent_id: INVENTORY_AGENT_ID,
      name: 'Inventory Agent',
      tokens_revoked: 3,
    }
    requestMock.mockResolvedValueOnce({ data: payload })

    const result = await api.agents.revokeCredential('live-token', INVENTORY_AGENT_ID)

    expect(requestMock).toHaveBeenCalledWith(expect.objectContaining({
      url: `/api/agents/${INVENTORY_AGENT_ID}/credentials/revoke`,
      method: 'POST',
      headers: expect.objectContaining({
        Authorization: 'Bearer live-token',
        'Content-Type': 'application/json',
      }),
    }))
    expect(result).toBe(payload)
    expect(result).not.toHaveProperty('simulated')
  })

  it('uses the live HTTP client unchanged for transitions', async () => {
    setDemoMode(false)
    const transitionBody = { to_state: 'suspended', reason: 'Incident response' }
    const payload = {
      agent_id: INVENTORY_AGENT_ID,
      from_state: 'active',
      to_state: 'suspended',
      actor: 'ops@acme.co',
      reason: 'Incident response',
      timestamp: '2026-08-02T12:00:00Z',
    }
    requestMock.mockResolvedValueOnce({ data: payload })

    const result = await api.agents.transition('live-token', INVENTORY_AGENT_ID, transitionBody)

    expect(requestMock).toHaveBeenCalledWith(expect.objectContaining({
      url: `/api/agents/${INVENTORY_AGENT_ID}/transition`,
      method: 'POST',
      data: transitionBody,
      headers: expect.objectContaining({
        Authorization: 'Bearer live-token',
        'Content-Type': 'application/json',
      }),
    }))
    expect(result).toBe(payload)
    expect(result).not.toHaveProperty('simulated')
  })
})
