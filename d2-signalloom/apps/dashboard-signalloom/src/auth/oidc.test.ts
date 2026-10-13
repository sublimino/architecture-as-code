import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import * as reactOidc from 'react-oidc-context'
import {
  isPublicRoute,
  useAuth0,
  useApi,
  resetOidcRedirectGuardForTests,
  REDIRECT_COOLDOWN_MS,
} from './oidc'

vi.mock('react-oidc-context', async () => {
  const actual = await vi.importActual<typeof import('react-oidc-context')>('react-oidc-context')
  return {
    ...actual,
    useAuth: vi.fn(),
  }
})

describe('isPublicRoute', () => {
  it('identifies public invitation and signup routes', () => {
    expect(isPublicRoute('/redeem-invite')).toBe(true)
    expect(isPublicRoute('/redeem-invite?token=abc')).toBe(true)
    expect(isPublicRoute('/redeem-invite/123')).toBe(true)
    expect(isPublicRoute('/signup')).toBe(true)
    expect(isPublicRoute('/signup/')).toBe(true)
    expect(isPublicRoute('/login')).toBe(true)
    expect(isPublicRoute('/login/')).toBe(true)
    expect(isPublicRoute('/callback')).toBe(true)
    expect(isPublicRoute('/callback?code=abc&state=123')).toBe(true)
  })

  it('rejects protected routes as non-public', () => {
    expect(isPublicRoute('/agents')).toBe(false)
    expect(isPublicRoute('/governance')).toBe(false)
    expect(isPublicRoute('/compliance')).toBe(false)
    expect(isPublicRoute('/onboarding')).toBe(false)
    expect(isPublicRoute('/settings')).toBe(false)
    expect(isPublicRoute('/')).toBe(false)
  })
})

describe('useAuth0 & useApi', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    resetOidcRedirectGuardForTests()
    window.history.replaceState({}, '', '/agents')
    try {
      window.sessionStorage?.removeItem('signalloom:logged-out')
      window.localStorage?.removeItem('signalloom-return-to')
    } catch {}
  })

  it('keeps getAccessTokenSilently, loginWithRedirect, and logout referentially stable across auth state object updates', () => {
    const signinRedirect1 = vi.fn().mockResolvedValue(undefined)
    const signinRedirect2 = vi.fn().mockResolvedValue(undefined)

    const useAuthMock = vi.mocked(reactOidc.useAuth)
    useAuthMock.mockReturnValue({
      isAuthenticated: true,
      isLoading: false,
      activeNavigator: undefined,
      user: { access_token: 'jwt-123', expired: false, profile: { sub: 'u1' } },
      signinRedirect: signinRedirect1,
    } as unknown as ReturnType<typeof reactOidc.useAuth>)

    const { result, rerender } = renderHook(() => useAuth0())
    const firstGetToken = result.current.getAccessTokenSilently
    const firstLogin = result.current.loginWithRedirect
    const firstLogout = result.current.logout

    // Simulate react-oidc-context returning a fresh context object with same token
    useAuthMock.mockReturnValue({
      isAuthenticated: true,
      isLoading: false,
      activeNavigator: undefined,
      user: { access_token: 'jwt-123', expired: false, profile: { sub: 'u1' } },
      signinRedirect: signinRedirect2,
    } as unknown as ReturnType<typeof reactOidc.useAuth>)

    rerender()

    expect(result.current.getAccessTokenSilently).toBe(firstGetToken)
    expect(result.current.loginWithRedirect).toBe(firstLogin)
    expect(result.current.logout).toBe(firstLogout)
  })

  it('reports isAuthenticated as false when user token is expired or within the 30s expiry window', () => {
    vi.mocked(reactOidc.useAuth).mockReturnValue({
      isAuthenticated: true,
      isLoading: false,
      activeNavigator: undefined,
      user: {
        access_token: 'nearly-expired-jwt',
        expired: false,
        expires_at: Math.floor(Date.now() / 1000) + 10,
      },
      signinRedirect: vi.fn().mockResolvedValue(undefined),
    } as unknown as ReturnType<typeof reactOidc.useAuth>)

    const { result } = renderHook(() => useAuth0())
    expect(result.current.isAuthenticated).toBe(false)
  })

  it('enforces single-flight signinRedirect during cooldown and allows retry after cooldown expires', async () => {
    let resolveRedirect!: () => void
    const redirectPromise = new Promise<void>((resolve) => {
      resolveRedirect = resolve
    })
    const signinRedirect = vi.fn().mockReturnValue(redirectPromise)

    vi.mocked(reactOidc.useAuth).mockReturnValue({
      isAuthenticated: false,
      isLoading: false,
      activeNavigator: undefined,
      user: { access_token: 'expired-jwt', expired: true },
      signinRedirect,
    } as unknown as ReturnType<typeof reactOidc.useAuth>)

    const { result } = renderHook(() => useAuth0())

    await expect(result.current.getAccessTokenSilently()).rejects.toThrow(
      'Token expired: re-authenticating',
    )
    // Concurrent call while first redirect is still in flight
    result.current.loginWithRedirect()

    expect(signinRedirect).toHaveBeenCalledTimes(1)
    resolveRedirect()
    await redirectPromise

    // Immediate call within REDIRECT_COOLDOWN_MS is still suppressed
    result.current.loginWithRedirect()
    expect(signinRedirect).toHaveBeenCalledTimes(1)

    // After cooldown expires, a subsequent redirect is allowed (not permanently deadlocked)
    const nowSpy = vi.spyOn(Date, 'now').mockReturnValue(Date.now() + REDIRECT_COOLDOWN_MS + 100)
    try {
      result.current.loginWithRedirect()
      expect(signinRedirect).toHaveBeenCalledTimes(2)
    } finally {
      nowSpy.mockRestore()
    }
  })

  it('aborts unauthenticated request in useApi when getAccessTokenSilently rejects', async () => {
    const signinRedirect = vi.fn().mockResolvedValue(undefined)
    vi.mocked(reactOidc.useAuth).mockReturnValue({
      isAuthenticated: false,
      isLoading: false,
      activeNavigator: undefined,
      user: { access_token: 'expired-jwt', expired: true },
      signinRedirect,
    } as unknown as ReturnType<typeof reactOidc.useAuth>)

    const { result } = renderHook(() => useApi())
    const adapterSpy = vi.fn()
    result.current.defaults.adapter = adapterSpy

    await expect(result.current.get('/api/v1/agents')).rejects.toThrow(
      'Token expired: re-authenticating',
    )
    // Must not dispatch the unauthenticated HTTP request to the adapter
    expect(adapterSpy).not.toHaveBeenCalled()
    expect(signinRedirect).toHaveBeenCalledTimes(1)
  })
})
