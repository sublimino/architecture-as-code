import { useAuth0 } from './oidc'

interface Props {
  children: React.ReactNode
}

export default function ProtectedRoute({ children }: Props) {
  const { isAuthenticated, isLoading, loginWithRedirect } = useAuth0()

  if (isLoading) return null

  if (!isAuthenticated) {
    loginWithRedirect({ appState: { returnTo: window.location.pathname } })
    return null
  }

  return <>{children}</>
}
