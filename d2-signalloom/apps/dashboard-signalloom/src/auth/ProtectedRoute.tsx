import { useAuth0 } from './oidc'
import { Navigate, useLocation } from 'react-router-dom'
import { useAppContext } from '../App'

interface Props {
  children: React.ReactNode
  // Set on /onboarding and /help/connectors/:provider — the wizard itself
  // and its in-app setup-guide pages must never redirect back into
  // themselves (US-ENHC-011 closeout, auto-trigger gate).
  exemptFromOnboardingGate?: boolean
}

export default function ProtectedRoute({ children, exemptFromOnboardingGate }: Props) {
  const { isAuthenticated, isLoading, loginWithRedirect } = useAuth0()
  const { needsOnboarding } = useAppContext()
  const location = useLocation()

  if (isLoading) return null

  if (!isAuthenticated) {
    loginWithRedirect({ appState: { returnTo: window.location.pathname } })
    return null
  }

  // needsOnboarding === null means "not yet checked" — don't redirect on
  // that first render, or every protected page would flash through
  // /onboarding before the check resolves.
  if (needsOnboarding === true && !exemptFromOnboardingGate) {
    return <Navigate to="/onboarding" state={{ returnTo: location.pathname }} replace />
  }

  return <>{children}</>
}
