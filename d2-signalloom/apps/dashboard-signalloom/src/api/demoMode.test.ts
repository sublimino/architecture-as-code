import { describe, it, expect, beforeEach, vi } from 'vitest'

// Prove the demo toggle renders data even when the API is completely down:
// every real HTTP call rejects, yet demo mode still resolves fixtures.
vi.mock('axios', () => ({
  default: {
    create: () => ({
      request: vi.fn().mockRejectedValue(new Error('API down')),
    }),
  },
}))

import { api } from './client'
import { setDemoMode } from './demoMode'
import { FAKE_ROUTE_COUNT, resolveFake } from './fakeData'
import type { IssueCredentialResponse, RevokeCredentialResponse } from '../types/api'

describe('demo mode', () => {
  beforeEach(() => setDemoMode(false))

  it('covers at least the current client endpoint surface', () => {
    expect(FAKE_ROUTE_COUNT).toBe(36)
  })

  it('serves a shape-valid revoke fixture and keeps adjacent credential routes distinct', () => {
    const issued = resolveFake('POST', '/agents/tenant-demo:agent-inventory/credentials') as
      | IssueCredentialResponse
      | undefined
    const revoked = resolveFake('POST', '/agents/tenant-demo:agent-inventory/credentials/revoke') as
      | RevokeCredentialResponse
      | undefined

    expect(issued).toBeDefined()
    expect(issued).toHaveProperty('identity_token')
    expect(issued).toHaveProperty('token_expires_at')
    expect(revoked).toEqual({
      agent_id: 'tenant-demo:agent-inventory',
      name: 'Inventory Agent',
      tokens_revoked: 3,
    })
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
})
