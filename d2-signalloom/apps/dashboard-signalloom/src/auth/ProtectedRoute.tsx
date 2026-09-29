import { useEffect, useRef } from 'react'
import { hasAuthParams } from 'react-oidc-context'
import { useAuth0 } from './oidc'
import { Navigate, useLocation } from 'react-router-dom'
import { useAppContext } from '../App'
import PixelLoader from '../components/PixelLoader'

const LOGGED_OUT_KEY = 'signalloom:logged-out'

interface Props {
  children: React.ReactNode
  // Set on /onboarding and /help/connectors/:provider: the wizard itself
  // and its in-app setup-guide pages must never redirect back into
  // themselves (US-ENHC-011 closeout, auto-trigger gate).
  exemptFromOnboardingGate?: boolean
}

export default function ProtectedRoute({ children, exemptFromOnboardingGate }: Props) {
  const { isAuthenticated, isLoading, loginWithRedirect } = useAuth0()
  const { needsOnboarding } = useAppContext()
  const location = useLocation()
  const redirecting = useRef(false)

  const inAuthCallback = typeof hasAuthParams === 'function' ? hasAuthParams() : false
  let isLoggedOut = false
  try {
    isLoggedOut = sessionStorage.getItem(LOGGED_OUT_KEY) === 'true'
  } catch {}

  useEffect(() => {
    if (!isLoading && !isAuthenticated && !inAuthCallback && !isLoggedOut && !redirecting.current) {
      redirecting.current = true
      loginWithRedirect({ appState: { returnTo: `${location.pathname}${location.search}` } })
    }
  }, [isLoading, isAuthenticated, inAuthCallback, isLoggedOut, location.pathname, location.search, loginWithRedirect])

  if (isLoading || inAuthCallback) {
    return (
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          minHeight: '60vh',
          background: 'var(--bg)',
        }}
      >
        <PixelLoader label="Signing in" testId="route-loading" />
      </div>
    )
  }

  if (isLoggedOut) {
    return <Navigate to="/login" state={{ returnTo: location.pathname }} replace />
  }

  if (!isAuthenticated) {
    return (
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          minHeight: '60vh',
          background: 'var(--bg)',
        }}
      >
        <PixelLoader label="Signing in" testId="route-loading" />
      </div>
    )
  }

  // needsOnboarding === null means "not yet checked"; don't redirect on
  // that first render, or every protected page would flash through
  // /onboarding before the check resolves.
  if (needsOnboarding === true && !exemptFromOnboardingGate) {
    return <Navigate to="/onboarding" state={{ returnTo: location.pathname }} replace />
  }

  return <>{children}</>
}
