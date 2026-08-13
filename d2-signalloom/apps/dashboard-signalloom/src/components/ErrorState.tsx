interface Props {
  message: string
  onRetry?: () => void
  /**
   * How to send the operator back to sign-in.
   *
   * Optional so this component stays presentational and renders outside an
   * auth provider (its tests do exactly that). When absent, `startLogin` below
   * is used, which needs no hooks.
   */
  onLogin?: () => void
}

/**
 * Is this failure "we would not let you look", rather than "it went wrong"?
 *
 * A 401 is the one error where **Retry is guaranteed to fail**: the request was
 * rejected before anything was attempted, and pressing a button that repeats it
 * unchanged just reproduces the same rejection. Offering Retry there teaches the
 * operator that the app is flaky when in fact their session has simply expired.
 *
 * Matched patterns are specific rather than a bare `401`, so a message that
 * merely contains the number — "401 roles scanned" — is not mistaken for an
 * auth failure. Each pattern is a spelling that actually occurs here:
 *   - axios throws literally "Request failed with status code 401"
 *   - our own surfaces render "(HTTP 401)"
 *   - the API returns {"code": "authentication_required"}
 */
export function isAuthError(message: string): boolean {
  return (
    /status code 401\b/i.test(message) ||
    /\bHTTP 401\b/i.test(message) ||
    /\b401 unauthori[sz]ed\b/i.test(message) ||
    /authentication[_ ]required/i.test(message)
  )
}

/**
 * Send the browser back through sign-in without needing the auth context.
 *
 * Dropping the stored OIDC user is what makes this reliable: `AutoSignIn` only
 * redirects to Dex when it sees no authenticated user, so navigating to `/`
 * while a stale-but-present token sits in localStorage would land back on the
 * same signed-out page. Clearing first guarantees the redirect happens.
 */
export function redirectToLogin(): void {
  try {
    // Iterate with the Storage API rather than Object.keys: `key(i)` is the
    // canonical accessor, and removing entries reindexes the store, so walk
    // backwards to avoid skipping one.
    const storage = window.localStorage
    for (let i = storage.length - 1; i >= 0; i -= 1) {
      const key = storage.key(i)
      if (key?.startsWith('oidc.user')) storage.removeItem(key)
    }
  } catch {
    // Storage can be unavailable (private mode, embedded contexts). The
    // navigation below is still worth attempting.
  }
  window.location.assign('/')
}

export default function ErrorState({ message, onRetry, onLogin }: Props) {
  const authFailure = isAuthError(message)

  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '48px 24px', gap: 14 }}>
      <span style={{ fontSize: 36 }}>{authFailure ? '🔒' : '⚠️'}</span>
      {/* "Failed to load" is wrong for a 401 in the same way Retry is: nothing
          failed to load, the session ended. */}
      <p style={{ color: 'var(--error)', fontWeight: 600 }}>
        {authFailure ? 'Your session has expired' : 'Failed to load'}
      </p>
      {/* The raw message stays reachable on hover rather than on screen: an
          engineer still needs "Request failed with status code 401", an
          executive should never have to read it. */}
      <p
        title={authFailure ? message : undefined}
        style={{ color: 'var(--muted)', fontSize: 13, maxWidth: 400, textAlign: 'center' }}
      >
        {authFailure ? 'You were signed out, so this could not be loaded. Sign in again to continue.' : message}
      </p>
      {authFailure ? (
        <button className="btn btn-primary" data-testid="error-login" onClick={onLogin ?? redirectToLogin}>
          Log in
        </button>
      ) : (
        onRetry && (
          <button className="btn btn-secondary" data-testid="error-retry" onClick={onRetry}>
            Retry
          </button>
        )
      )}
    </div>
  )
}
