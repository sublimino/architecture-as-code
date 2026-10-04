/**
 * /redeem-invite: bind the signed-in Dex identity to a tenant.
 *
 * The page sits behind ProtectedRoute, so the caller already holds a Dex ID
 * token. It posts the one-time invite token to POST /api/v1/invites/redeem with
 * that bearer; the server verifies the identity, looks the token up by hash,
 * and writes the subject -> tenant binding (migration 053). Nothing here
 * creates a tenant or an identity: the tenant is the one the invite names, and
 * the identity is the one Dex already issued.
 *
 * The earlier version of this page posted an org form to /api/registry/signup,
 * a route that does not exist in this tree. docs/EAP/onboarding.md said so.
 */
import { useEffect, useState, type CSSProperties, type FormEvent } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'

const API_BASE = import.meta.env.VITE_API_BASE_URL || ''
const REDEEM_PATH = '/api/v1/invites/redeem'
//: Anything shorter cannot be a token the API issued (32 url-safe bytes).
const MIN_TOKEN_LENGTH = 16

interface ApiErrorBody {
  error?: { code?: string; message?: string }
  message?: string
}

export interface RedeemResult {
  subject: string
  tenant: string
  bound_via: string
  bound_at: string
  email?: string | null
}

const inputStyle: CSSProperties = {
  width: '100%',
  padding: '10px 12px',
  background: 'var(--surface2, #1a1a2e)',
  border: '1px solid var(--border, #2a2a4a)',
  borderRadius: 6,
  color: 'var(--text, #e0e0e0)',
  fontSize: 14,
  boxSizing: 'border-box',
  fontFamily: 'var(--font-mono, monospace)',
}

const labelStyle: CSSProperties = {
  display: 'block',
  fontSize: 13,
  color: 'var(--muted, #888)',
  marginBottom: 6,
  fontWeight: 500,
}

const pageStyle: CSSProperties = { maxWidth: 480, margin: '60px auto', padding: '0 24px' }
const headingStyle: CSSProperties = { fontSize: 24, marginBottom: 12, color: 'var(--text, #e0e0e0)' }
const mutedStyle: CSSProperties = { color: 'var(--muted, #888)', lineHeight: 1.6, fontSize: 14 }

/** The message a given refusal deserves. Exported so the test can pin the mapping. */
export function messageFor(status: number, body: ApiErrorBody): string {
  const code = body.error?.code
  const serverMessage = body.error?.message ?? body.message
  switch (status) {
    case 401:
      return 'Your session has expired. Sign in again, then reopen the invite link.'
    case 403:
      if (code === 'invite_email_mismatch')
        return 'This invite was issued to a different email address. Sign in with the account it was sent to.'
      return serverMessage || 'This identity is not allowed to redeem the invite.'
    case 404:
      return 'No invite matches this token. Check the link, or ask your operator for a new invite.'
    case 409:
      return serverMessage || 'Your account is already bound to a different tenant. Ask your operator to move it.'
    case 410:
      if (code === 'invite_expired') return 'This invite has expired. Ask your operator for a new one.'
      return 'This invite has already been redeemed.'
    case 503:
      return 'The portal cannot reach its database right now. Try again in a few minutes.'
    default:
      return serverMessage || 'Something went wrong, please try again.'
  }
}

export default function RedeemInvite() {
  const [searchParams] = useSearchParams()
  const { getAccessTokenSilently } = useAuth0()
  // `token` is the current parameter; `code` is kept so an older link still lands.
  const fromLink = searchParams.get('token') ?? searchParams.get('code') ?? ''

  const [token, setToken] = useState(fromLink)
  const [submitting, setSubmitting] = useState(false)
  const [result, setResult] = useState<RedeemResult | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    setToken(fromLink)
  }, [fromLink])

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    const candidate = token.trim()
    if (candidate.length < MIN_TOKEN_LENGTH) {
      setError('Paste the full invite token from your operator.')
      return
    }
    setSubmitting(true)
    setError(null)
    try {
      const bearer = await getAccessTokenSilently()
      const resp = await fetch(`${API_BASE}${REDEEM_PATH}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${bearer}` },
        body: JSON.stringify({ token: candidate }),
      })
      if (!resp.ok) {
        const body: ApiErrorBody = await resp.json().catch(() => ({}))
        setError(messageFor(resp.status, body))
        return
      }
      setResult((await resp.json()) as RedeemResult)
    } catch {
      setError('Network error. Please check your connection and try again.')
    } finally {
      setSubmitting(false)
    }
  }

  if (result) {
    return (
      <div style={{ ...pageStyle, textAlign: 'center', marginTop: 80 }} data-testid="redeem-success">
        <h1 style={headingStyle}>You are in</h1>
        <p style={mutedStyle}>
          <strong>{result.email ?? result.subject}</strong> is now bound to tenant{' '}
          <strong data-testid="bound-tenant">{result.tenant}</strong>. The binding is live on your
          next request; no sign-out is needed.
        </p>
        <a
          href="/"
          style={{
            display: 'inline-block',
            marginTop: 24,
            padding: '10px 20px',
            background: 'var(--cyan, #00d4ff)',
            color: 'var(--bg)',
            borderRadius: 6,
            textDecoration: 'none',
            fontWeight: 600,
          }}
        >
          Open the dashboard
        </a>
      </div>
    )
  }

  return (
    <div style={pageStyle}>
      <div style={{ marginBottom: 36 }}>
        <h1 style={{ ...headingStyle, fontSize: 28, fontWeight: 700, marginBottom: 8 }}>Redeem your invite</h1>
        <p style={mutedStyle}>
          Your operator issued a one-time token that binds the account you are signed in with to a tenant.
          {fromLink ? ' The token from your link is filled in below.' : ' Paste it here.'}
        </p>
      </div>

      {error && (
        <div
          role="alert"
          style={{
            background: 'rgba(255, 71, 87, 0.1)',
            border: '1px solid var(--error, #ff4757)',
            borderRadius: 6,
            padding: '12px 16px',
            marginBottom: 24,
            color: 'var(--error, #ff4757)',
            fontSize: 14,
          }}
        >
          {error}
        </div>
      )}

      <form onSubmit={handleSubmit} noValidate>
        <div style={{ marginBottom: 20 }}>
          <label htmlFor="invite_token" style={labelStyle}>Invite token *</label>
          <input
            id="invite_token"
            type="text"
            autoComplete="off"
            spellCheck={false}
            value={token}
            onChange={e => setToken(e.target.value)}
            placeholder="paste the token from your invite"
            style={inputStyle}
            disabled={submitting}
          />
        </div>

        <button
          type="submit"
          disabled={submitting}
          style={{
            width: '100%',
            padding: '12px 0',
            background: submitting ? 'var(--border, #2a2a4a)' : 'var(--cyan, #00d4ff)',
            border: 'none',
            borderRadius: 6,
            color: submitting ? 'var(--muted, #888)' : 'var(--bg)',
            fontSize: 15,
            fontWeight: 600,
            cursor: submitting ? 'not-allowed' : 'pointer',
            transition: 'background 0.2s',
          }}
        >
          {submitting ? 'Redeeming...' : 'Redeem invite'}
        </button>
      </form>

      <p style={{ marginTop: 24, textAlign: 'center', fontSize: 13, color: 'var(--muted, #888)' }}>
        Already bound to a tenant?{' '}
        <a href="/" style={{ color: 'var(--cyan, #00d4ff)', textDecoration: 'none' }}>Open the dashboard</a>
      </p>
    </div>
  )
}
