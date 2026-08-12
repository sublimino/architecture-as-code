import { useCallback, useEffect, useMemo, useRef, type ReactNode } from 'react'
import axios, { type AxiosInstance } from 'axios'
import { AuthProvider, useAuth, hasAuthParams } from 'react-oidc-context'
import { WebStorageStateStore } from 'oidc-client-ts'

interface Props {
  children: ReactNode
}

// The dashboard is served single-origin behind a port-forward at :5173, with
// nginx proxying /dex to the in-cluster Dex. Dex's issuer is set to this origin
// so the browser reaches every endpoint here. We supply the OIDC metadata
// explicitly (instead of relying on discovery) so signinRedirect builds the
// authorization URL synchronously — discovery-on-load was intermittently hanging.
const AUTHORITY = `${window.location.origin}/dex`
const oidcConfig = {
  authority: AUTHORITY,
  metadata: {
    issuer: AUTHORITY,
    authorization_endpoint: `${AUTHORITY}/auth`,
    token_endpoint: `${AUTHORITY}/token`,
    jwks_uri: `${AUTHORITY}/keys`,
    userinfo_endpoint: `${AUTHORITY}/userinfo`,
    // Dex does not implement OIDC RP-Initiated Logout — omit end_session_endpoint
    // so signoutRedirect() falls back to the client-side session clear below.
  },
  client_id: 'signalloom-dashboard',
  redirect_uri: `${window.location.origin}/callback`,
  post_logout_redirect_uri: `${window.location.origin}/`,
  response_type: 'code',
  scope: 'openid profile email groups audience:server:client_id:signalloom-api',
  // Evidence links open in new tabs during the demo. sessionStorage is
  // tab-scoped, so the new tab appeared anonymous and restarted OIDC. Same-
  // origin localStorage lets dashboard tabs share a session without leaking it
  // to another origin.
  userStore: new WebStorageStateStore({ store: window.localStorage }),
  stateStore: new WebStorageStateStore({ store: window.localStorage }),
  // Force Dex to re-authenticate rather than silently reusing its own server
  // side session cookie. Without this, clearing the client store still bounced
  // straight back through /dex/auth with a fresh token and no prompt, because
  // Dex remembered the browser independently of the SPA.
  extraQueryParams: { prompt: 'login' },
  automaticSilentRenew: false,
  onSigninCallback: () => {
    const returnTo = window.localStorage.getItem('signalloom-return-to') ?? '/agents'
    window.localStorage.removeItem('signalloom-return-to')
    window.history.replaceState({}, document.title, returnTo)
  },
}

// Automatically start the Dex login when the user is not authenticated. This is
// the documented react-oidc-context SPA pattern — the library does not redirect
// on its own, and relying on a route guard fails when a loading gate keeps the
// guard unmounted. Mounted alongside the app so it always runs.
function AutoSignIn({ children }: Props) {
  const auth = useAuth()
  const triggered = useRef(false)
  useEffect(() => {
    if (
      !triggered.current &&
      !hasAuthParams() &&
      !auth.isAuthenticated &&
      !auth.activeNavigator &&
      !auth.isLoading &&
      !auth.error
    ) {
      triggered.current = true
      window.localStorage.setItem('signalloom-return-to', `${window.location.pathname}${window.location.search}`)
      auth.signinRedirect().catch((e) => console.error('[oidc-signin-error]', e))
    }
  }, [auth.isAuthenticated, auth.activeNavigator, auth.isLoading, auth.error, auth])
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
  const auth = useAuth()
  const { signinRedirect } = auth
  // Stable across renders unless the token itself changes. The Auth0 SDK this
  // shim replaces returned stable callbacks; consumers put getAccessTokenSilently
  // in useCallback/useEffect deps, so an unstable ref causes an infinite refetch
  // loop. Keep these referentially stable to preserve the original behaviour.
  const token = auth.user?.access_token ?? auth.user?.id_token ?? ''
  const getAccessTokenSilently = useCallback(async () => token, [token])
  // Accept (and ignore) the Auth0-style options arg the call sites still pass.
  const loginWithRedirect = useCallback(
    (opts?: unknown): void => {
      void opts
      signinRedirect()
    },
    [signinRedirect],
  )
  const { removeUser } = auth
  const logout = useCallback(
    (opts?: unknown): void => {
      void opts
      removeUser().then(() => {
        window.location.href = '/'
      })
    },
    [removeUser],
  )
  const profile = auth.user?.profile

  return useMemo(
    () => ({
      isAuthenticated: auth.isAuthenticated,
      isLoading: auth.isLoading || auth.activeNavigator === 'signinRedirect',
      loginWithRedirect,
      logout,
      getAccessTokenSilently,
      user: profile,
    }),
    [
      auth.isAuthenticated,
      auth.isLoading,
      auth.activeNavigator,
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
      } catch {
        loginWithRedirect({ appState: { returnTo: window.location.pathname } })
      }
      return config
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
