import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { request } = vi.hoisted(() => ({ request: vi.fn() }))
vi.mock('axios', () => ({
  default: { create: () => ({ request }) },
}))

import { api } from './client'
import { setDemoMode } from './demoMode'

const TOKEN = 'test-token'

describe('policy compliance API — live mode', () => {
  beforeEach(() => {
    setDemoMode(false)
    request.mockReset()
    request.mockResolvedValue({ data: {} })
  })

  afterEach(() => setDemoMode(false))

  it('requests the policy frameworks compatibility contract', async () => {
    await api.compliancePolicy.frameworks(TOKEN)

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/compliance/policy/frameworks',
      method: 'GET',
      headers: expect.objectContaining({ Authorization: `Bearer ${TOKEN}` }),
    }))
  })

  it('requests the policy summary compatibility contract', async () => {
    await api.compliancePolicy.summary(TOKEN)

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/compliance/policy/summary',
      method: 'GET',
      headers: expect.objectContaining({ Authorization: `Bearer ${TOKEN}` }),
    }))
  })
})
