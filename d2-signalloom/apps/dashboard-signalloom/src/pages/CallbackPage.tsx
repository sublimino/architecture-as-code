import { useEffect } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import { useAuth } from 'react-oidc-context'
import { LOGGED_OUT_KEY } from '../auth/oidc'
import PixelLoader from '../components/PixelLoader'

export default function CallbackPage() {
  const auth = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    if (auth.isAuthenticated) {
      try {
        sessionStorage.removeItem(LOGGED_OUT_KEY)
      } catch {}
      const returnTo = window.localStorage.getItem('signalloom-return-to') || '/agents'
      window.localStorage.removeItem('signalloom-return-to')
      navigate(returnTo, { replace: true })
    }
  }, [auth.isAuthenticated, navigate])

  if (auth.error) {
    const handleRetry = () => {
      try {
        sessionStorage.removeItem(LOGGED_OUT_KEY)
      } catch {}
      window.localStorage.removeItem('signalloom-return-to')
      if (typeof auth.signinRedirect === 'function') {
        auth.signinRedirect({ extraQueryParams: { prompt: 'login' } }).catch(() => {
          navigate('/login', { replace: true })
        })
      } else {
        navigate('/login', { replace: true })
      }
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
            maxWidth: 460,
            width: '100%',
            padding: '36px 32px',
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
              background: 'var(--surface2)',
              color: 'var(--error)',
              fontSize: 22,
              marginBottom: 18,
            }}
          >
            !
          </div>
          <h1
            style={{
              fontSize: 20,
              fontWeight: 600,
              color: 'var(--text)',
              margin: '0 0 10px',
            }}
          >
            Authentication Error
          </h1>
          <p
            style={{
              fontSize: 14,
              color: 'var(--muted)',
              margin: '0 0 24px',
              lineHeight: 1.5,
              wordBreak: 'break-word',
            }}
          >
            {auth.error.message || 'Unable to complete sign-in. Your session may have expired.'}
          </p>

          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <button
              type="button"
              onClick={handleRetry}
              data-testid="callback-retry-btn"
              style={{
                width: '100%',
                padding: '10px 16px',
                background: 'var(--cyan)',
                color: 'var(--bg)',
                border: 'none',
                borderRadius: 8,
                fontSize: 14,
                fontWeight: 600,
                cursor: 'pointer',
              }}
            >
              Try again
            </button>
            <Link
              to="/login"
              data-testid="callback-login-link"
              style={{
                fontSize: 13,
                color: 'var(--muted)',
                textDecoration: 'none',
              }}
            >
              Return to login
            </Link>
          </div>
        </div>
      </div>
    )
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
      <PixelLoader label="Completing sign in..." testId="callback-loading" />
    </div>
  )
}
