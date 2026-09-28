import { useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth0, LOGGED_OUT_KEY } from '../auth/oidc'
import PixelLoader from '../components/PixelLoader'

export default function LoginPage() {
  const { isAuthenticated, isLoading, loginWithRedirect } = useAuth0()
  const navigate = useNavigate()

  useEffect(() => {
    if (isAuthenticated) {
      navigate('/agents', { replace: true })
    }
  }, [isAuthenticated, navigate])

  if (isLoading) {
    return (
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          minHeight: '80vh',
          background: 'var(--bg)',
        }}
      >
        <PixelLoader label="Signing in" testId="login-loading" />
      </div>
    )
  }

  const handleSignIn = () => {
    try {
      sessionStorage.removeItem(LOGGED_OUT_KEY)
    } catch {}
    loginWithRedirect()
  }

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        minHeight: '80vh',
        background: 'var(--bg)',
      }}
    >
      <div
        style={{
          maxWidth: 440,
          width: '100%',
          padding: '40px 32px',
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 12,
          textAlign: 'center',
        }}
      >
        <div
          style={{
            display: 'inline-flex',
            alignItems: 'center',
            justifyContent: 'center',
            width: 48,
            height: 48,
            borderRadius: 10,
            background: 'var(--violet)',
            color: 'var(--on-accent)',
            fontSize: 22,
            fontWeight: 700,
            marginBottom: 20,
          }}
        >
          SL
        </div>
        <h1
          style={{
            fontSize: 22,
            fontWeight: 600,
            color: 'var(--text)',
            margin: '0 0 8px',
          }}
        >
          Signal Loom
        </h1>
        <p
          style={{
            fontSize: 14,
            color: 'var(--muted)',
            margin: '0 0 28px',
            lineHeight: 1.5,
          }}
        >
          You are currently signed out.
        </p>

        <button
          type="button"
          onClick={handleSignIn}
          data-testid="login-dex-btn"
          style={{
            width: '100%',
            padding: '12px 16px',
            background: 'var(--cyan)',
            color: 'var(--bg)',
            border: 'none',
            borderRadius: 8,
            fontSize: 14,
            fontWeight: 600,
            cursor: 'pointer',
          }}
        >
          Sign in with Dex
        </button>
      </div>
    </div>
  )
}
