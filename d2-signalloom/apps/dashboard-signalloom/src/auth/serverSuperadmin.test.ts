// The dashboard's superadmin flag follows the server.
//
// Before this it was a name match in the browser against
// demo-user@signalloom.local, which is fine as a pre-flight answer and wrong as
// authority: the moment API_SUPERADMIN_EMAILS / API_SUPERADMIN_SUBJECTS name
// anyone else, the client's verdict and the API's diverge, in both directions.
// GET /api/v1/me reports the same decision require_superadmin applies.
import { renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { fetchMe, isSuperadminEligible, useServerSuperadmin } from './superadmin'

const DEMO = { email: 'demo-user@signalloom.local' }
const OTHER = { email: 'auditor@bank.example' }

function mockMe(body: unknown, ok = true) {
  const fetchMock = vi.fn().mockResolvedValue({
    ok,
    status: ok ? 200 : 500,
    json: async () => body,
  })
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

const token = async () => 'test-token'

beforeEach(() => {
  vi.unstubAllGlobals()
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('fetchMe', () => {
  it('sends the bearer token and returns the identity triple', async () => {
    const fetchMock = mockMe({
      subject: 'kusari-operator',
      tenant: 'kusari',
      email: 'kusari-operator@signalloom.local',
      superadmin: false,
    })

    const me = await fetchMe('tok')

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/v1/me',
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: 'Bearer tok' }),
      }),
    )
    expect(me.tenant).toBe('kusari')
    expect(me.superadmin).toBe(false)
  })

  it('throws rather than defaulting when the route refuses', async () => {
    mockMe({}, false)
    await expect(fetchMe('tok')).rejects.toThrow('/api/v1/me 500')
  })
})

describe('useServerSuperadmin', () => {
  it('promotes a user the server names, whom the name match would refuse', async () => {
    // The whole point: an allow-list entry that is not the demo user.
    mockMe({ subject: 'alice', tenant: 'tenant-a', email: null, superadmin: true })
    expect(isSuperadminEligible(OTHER)).toBe(false)

    const { result } = renderHook(() => useServerSuperadmin(OTHER, token))

    // Pre-flight: the name match, not yet authority.
    expect(result.current).toEqual({ superadmin: false, resolved: false })
    await waitFor(() => expect(result.current.resolved).toBe(true))
    expect(result.current.superadmin).toBe(true)
  })

  it('demotes the demo user when the server does not name them', async () => {
    mockMe({ subject: 'demo-user', tenant: 'tenant-demo', email: null, superadmin: false })
    expect(isSuperadminEligible(DEMO)).toBe(true)

    const { result } = renderHook(() => useServerSuperadmin(DEMO, token))

    await waitFor(() => expect(result.current.resolved).toBe(true))
    expect(result.current.superadmin).toBe(false)
  })

  it('does not promote on a failed request', async () => {
    // An unreachable identity route is not evidence of elevation, so the
    // pre-flight answer stands and `resolved` stays false.
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('offline')))

    const { result } = renderHook(() => useServerSuperadmin(OTHER, token))

    await waitFor(() => expect(result.current.superadmin).toBe(false))
    expect(result.current.resolved).toBe(false)
  })

  it('reports the pre-flight answer when there is no token to present', async () => {
    const fetchMock = mockMe({ superadmin: true })

    const { result } = renderHook(() => useServerSuperadmin(DEMO, null))

    expect(result.current).toEqual({ superadmin: true, resolved: false })
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('treats a non-boolean superadmin field as not superadmin', async () => {
    // Strict comparison, so a truthy string from a mangled proxy response
    // cannot elevate.
    mockMe({ subject: 'alice', tenant: 'tenant-a', email: null, superadmin: 'yes' })

    const { result } = renderHook(() => useServerSuperadmin(OTHER, token))

    await waitFor(() => expect(result.current.resolved).toBe(true))
    expect(result.current.superadmin).toBe(false)
  })
})
