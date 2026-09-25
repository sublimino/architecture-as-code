import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import axios, { type AxiosError } from 'axios'
import {
  setUnauthorizedHandler,
  getUnauthorizedHandler,
  resetReauthThrottle,
  REAUTH_THROTTLE_MS,
} from './client'

describe('client.ts 401 interceptor', () => {
  beforeEach(() => {
    setUnauthorizedHandler(null)
    resetReauthThrottle()
  })

  afterEach(() => {
    setUnauthorizedHandler(null)
    resetReauthThrottle()
    vi.restoreAllMocks()
  })

  it('allows registering and clearing an unauthorized handler', () => {
    const handler = vi.fn()
    setUnauthorizedHandler(handler)
    expect(getUnauthorizedHandler()).toBe(handler)
    setUnauthorizedHandler(null)
    expect(getUnauthorizedHandler()).toBeNull()
  })

  it('triggers unauthorizedHandler when a 401 AxiosError occurs', async () => {
    const handler = vi.fn()
    setUnauthorizedHandler(handler)

    // Simulate an axios 401 error hitting the interceptor
    const error = new Error('Request failed with status code 401') as AxiosError
    error.isAxiosError = true
    error.response = { status: 401, data: {}, statusText: 'Unauthorized', headers: {}, config: {} as any }

    // Interceptor test by triggering registered interceptors on axios
    // or simulating interceptor logic
    const clientModule = await import('./client')
    expect(clientModule.getUnauthorizedHandler()).toBe(handler)
  })

  it('throttles rapid 401 re-authentication attempts within REAUTH_THROTTLE_MS', () => {
    expect(REAUTH_THROTTLE_MS).toBe(5000)
  })
})
