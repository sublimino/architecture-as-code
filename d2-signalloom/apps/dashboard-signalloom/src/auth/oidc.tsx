import { useCallback, useEffect, useMemo, useRef, type ReactNode } from 'react'
import axios, { type AxiosInstance } from 'axios'
import { AuthProvider, useAuth, hasAuthParams } from 'react-oidc-context'
import { WebStorageStateStore } from 'oidc-client-ts'
import { setUnauthorizedHandler } from '../api/client'

export { hasAuthParams }
export const LOGGED_OUT_KEY = 'signalloom:logged-out'

interface Props {
  children: ReactNode
}

// The dashboard is served single-origin behind a port-forward at :5173, with
// nginx proxying /dex to the in-cluster Dex. Dex's issuer is set to this origin
// so the browser reaches every endpoint here. We supply the OIDC metadata
// explicitly (instead of relying on discovery) so signinRedirect builds the
// authorization URL synchronously: discovery-on-load was intermittently hanging.
const AUTHORITY = `${window.location.origin}/dex`
export const oidcConfig = {
  authority: AUTHORITY,
  metadata: {
    issuer: AUTHORITY,
    authorization_endpoint: `${AUTHORITY}/auth`,
    token_endpoint: `${AUTHORITY}/token`,
    jwks_uri: `${AUTHORITY}/keys`,
    userinfo_endpoint: `${AUTHORITY}/userinfo`,
    // Dex does not implement OIDC RP-Initiated Logout; omit end_session_endpoint
    // so signoutRedirect() falls back to the client-side session clear below.
  },
  client_id: 'signalloom-dashboard',
  redirect_uri: `${window.location.origin}/callback`,
  silent_redirect_uri: `${window.location.origin}/callback`,
  post_logout_redirect_uri: `${window.location.origin}/`,
  response_type: 'code',
  scope: 'openid profile email groups audience:server:client_id:signalloom-api',
  // Evidence links open in new tabs during the demo. sessionStorage is
  // tab-scoped, so the new tab appeared anonymous and restarted OIDC. Same-
  // origin localStorage lets dashboard tabs share a session without leaking it
  // to another origin.
  userStore: new WebStorageStateStore({ store: window.localStorage }),
  stateStore: new WebStorageStateStore({ store: window.localStorage }),
  automaticSilentRenew: false,
  onSigninCallback: () => {
    redirectInFlightPromise = null
    lastRedirectTime = 0
    try {
      sessionStorage.removeItem(LOGGED_OUT_KEY)
    } catch {}
    const returnTo = window.localStorage.getItem('signalloom-return-to') ?? '/agents'
    window.localStorage.removeItem('signalloom-return-to')
    window.history.replaceState({}, document.title, returnTo)
  },
}

// Automatically start the Dex login when the user is not authenticated. This is
// the documented react-oidc-context SPA pattern: the library does not redirect
// on its own, and relying on a route guard fails when a loading gate keeps the
// guard unmounted. Mounted alongside the app so it always runs.
const PUBLIC_PATHS = ['/redeem-invite', '/signup', '/login', '/callback']

export function isPublicRoute(pathname: string): boolean {
  const clean = pathname.split('?')[0].split('#')[0].replace(/\/+$/, '') || '/'
  return PUBLIC_PATHS.some((p) => clean === p || clean.startsWith(`${p}/`))
}

let redirectInFlightPromise: Promise<void> | null = null
let lastRedirectTime = 0
export const REDIRECT_COOLDOWN_MS = 3000

export function resetOidcRedirectGuardForTests(): void {
  redirectInFlightPromise = null
  lastRedirectTime = 0
}

function triggerSigninRedirect(
  auth: ReturnType<typeof useAuth> | undefined,
  extraQueryParams: Record<string, string> = { prompt: 'login' },
): Promise<void> {
  const now = Date.now()
  if (
    redirectInFlightPromise ||
    auth?.activeNavigator ||
    (lastRedirectTime > 0 && now - lastRedirectTime < REDIRECT_COOLDOWN_MS)
  ) {
    return redirectInFlightPromise ?? Promise.resolve()
  }
  if (typeof auth?.signinRedirect !== 'function') {
    return Promise.reject(new Error('signinRedirect unavailable'))
  }
  lastRedirectTime = now
  const p = Promise.resolve(auth.signinRedirect({ extraQueryParams }))
    .then(() => {
      redirectInFlightPromise = null
    })
    .catch((err) => {
      redirectInFlightPromise = null
      lastRedirectTime = 0
      throw err
    })
  redirectInFlightPromise = p
  return p
}

function AutoSignIn({ children }: Props) {
  const auth = useAuth()
  const triggered = useRef(false)

  useEffect(() => {
    const handleUnauthorized = () => {
      if (isPublicRoute(window.location.pathname)) {
        return
      }
      try {
        if (sessionStorage.getItem(LOGGED_OUT_KEY) === 'true') {
          return
        }
      } catch {}

      if (typeof auth?.signinRedirect === 'function') {
        try {
          window.localStorage?.setItem('signalloom-return-to', `${window.location.pathname}${window.location.search}`)
        } catch {}
        triggerSigninRedirect(auth).catch(() => {
          window.location.href = '/login'
        })
      } else {
        window.location.href = '/login'
      }
    }

    setUnauthorizedHandler(handleUnauthorized)
    return () => {
      setUnauthorizedHandler(null)
    }
  }, [auth])

  useEffect(() => {
    if (isPublicRoute(window.location.pathname)) {
      return
    }
    try {
      if (sessionStorage.getItem(LOGGED_OUT_KEY) === 'true') {
        return
      }
    } catch {}

    if (
      !triggered.current &&
      !hasAuthParams() &&
      !auth?.isAuthenticated &&
      !auth?.activeNavigator &&
      !auth?.isLoading &&
      !auth?.error
    ) {
      triggered.current = true
      try {
        window.localStorage?.setItem('signalloom-return-to', `${window.location.pathname}${window.location.search}`)
      } catch {}
      triggerSigninRedirect(auth).catch((e) => console.error('[oidc-signin-error]', e))
    }
  }, [auth?.isAuthenticated, auth?.activeNavigator, auth?.isLoading, auth?.error, auth])
  return <>{children}</>
}

export function OidcProvider({ children }: Props) {
  return (
    <AuthProvider {...oidcConfig}>
      <AutoSignIn>{children}</AutoSignIn>
    </AuthProvider>
  )
}

export function useAuth0() {
  let auth: ReturnType<typeof useAuth> | undefined
  try { auth = useAuth() } catch {}
  const authRef = useRef(auth)
  authRef.current = auth

  const user = auth?.user
  const isExpired = Boolean(
    user?.expired || (user?.expires_at ? user.expires_at - Date.now() / 1000 < 30 : false),
  )
  const isAuthenticated = Boolean(auth?.isAuthenticated && !isExpired)

  // Stable across renders unless the token itself changes. The Auth0 SDK this
  // shim replaces returned stable callbacks; consumers put getAccessTokenSilently
  // in useCallback/useEffect deps, so an unstable ref causes an infinite refetch
  // loop. Keep these referentially stable to preserve the original behaviour.
  const token = user?.access_token ?? user?.id_token ?? ''
  const getAccessTokenSilently = useCallback(async (): Promise<string> => {
    const currentAuth = authRef.current
    const currentUser = currentAuth?.user
    const currentIsExpired = Boolean(
      currentUser?.expired ||
        (currentUser?.expires_at ? currentUser.expires_at - Date.now() / 1000 < 30 : false),
    )

    if (token && !currentIsExpired) {
      return token
    }

    if (currentIsExpired && typeof currentAuth?.signinRedirect === 'function') {
      let isLoggedOut = false
      try {
        isLoggedOut = sessionStorage.getItem(LOGGED_OUT_KEY) === 'true'
      } catch {}

      if (!isPublicRoute(window.location.pathname) && !isLoggedOut) {
        try {
          window.localStorage?.setItem('signalloom-return-to', `${window.location.pathname}${window.location.search}`)
        } catch {}
        triggerSigninRedirect(currentAuth).catch(() => {})
      }
      throw new Error('Token expired: re-authenticating')
    }

    return token
  }, [token])

  // Accept (and ignore) the Auth0-style options arg the call sites still pass.
  const loginWithRedirect = useCallback(
    (opts?: unknown): void => {
      void opts
      try {
        sessionStorage.removeItem(LOGGED_OUT_KEY)
      } catch {}
      triggerSigninRedirect(authRef.current).catch(() => {})
    },
    [],
  )

  const logout = useCallback(
    (opts?: unknown): void => {
      void opts
      try {
        sessionStorage.setItem(LOGGED_OUT_KEY, 'true')
      } catch {}
      const removeUser = authRef.current?.removeUser ?? (() => Promise.resolve())
      removeUser().then(() => {
        window.location.href = '/login'
      })
    },
    [],
  )
  const profile = user?.profile

  return useMemo(
    () => ({
      isAuthenticated,
      isLoading: Boolean(auth?.isLoading || auth?.activeNavigator === 'signinRedirect'),
      loginWithRedirect,
      logout,
      getAccessTokenSilently,
      user: profile,
    }),
    [
      isAuthenticated,
      auth?.isLoading,
      auth?.activeNavigator,
      profile,
      getAccessTokenSilently,
      loginWithRedirect,
      logout,
    ],
  )
}

export function useApi(): AxiosInstance {
  const { getAccessTokenSilently, loginWithRedirect } = useAuth0()

  return useMemo(() => {
    const instance = axios.create({ baseURL: import.meta.env.VITE_API_BASE_URL ?? '' })

    instance.interceptors.request.use(async (config) => {
      try {
        const token = await getAccessTokenSilently()
        config.headers.Authorization = `Bearer ${token}`
        return config
      } catch (err) {
        loginWithRedirect({ appState: { returnTo: window.location.pathname } })
        return Promise.reject(err)
      }
    })

    instance.interceptors.response.use(undefined, (err) => {
      if (axios.isAxiosError(err) && err.response?.status === 401) {
        loginWithRedirect({ appState: { returnTo: window.location.pathname } })
      }
      return Promise.reject(err)
    })

    return instance
  }, [getAccessTokenSilently, loginWithRedirect])
}
