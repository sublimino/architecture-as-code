import { beforeEach, describe, expect, it, vi } from 'vitest'

const { requestMock } = vi.hoisted(() => ({ requestMock: vi.fn() }))

vi.mock('axios', () => ({
  default: { create: () => ({ request: requestMock }) },
}))

import { api } from './client'
import { setDemoMode } from './demoMode'

describe('NHI API client', () => {
  beforeEach(() => {
    setDemoMode(false)
    requestMock.mockReset()
    requestMock.mockResolvedValue({ data: {} })
  })

  it('uses the discovered-account detail API path', async () => {
    await api.nhi.getAccount('test-token', 'e0000000-0000-0000-0000-000000000005')

    expect(requestMock).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/nhi/discovered/e0000000-0000-0000-0000-000000000005',
      method: 'GET',
      headers: expect.objectContaining({ Authorization: 'Bearer test-token' }),
    }))
  })
})
