import { useState, type CSSProperties, FormEvent } from 'react'
import { useSearchParams } from 'react-router-dom'

const API_BASE = import.meta.env.VITE_API_BASE_URL || ''
const INVITE_CODE_RE = /^SL-[A-Z0-9]{4}-[A-Z0-9]{4}$/

type DataRegion = 'us' | 'eu'

interface FormState {
  org_name: string
  admin_email: string
  admin_name: string
  data_region: DataRegion
}

interface ApiError {
  error?: string
  message?: string
  retry_after_seconds?: number
}

const inputStyle: CSSProperties = {
  width: '100%',
  padding: '10px 12px',
  background: 'var(--bg-secondary, #1a1a2e)',
  border: '1px solid var(--border, #2a2a4a)',
  borderRadius: 6,
  color: 'var(--text, #e0e0e0)',
  fontSize: 14,
  boxSizing: 'border-box',
}

const labelStyle: CSSProperties = {
  display: 'block',
  fontSize: 13,
  color: 'var(--text-muted, #888)',
  marginBottom: 6,
  fontWeight: 500,
}

const fieldStyle: CSSProperties = { marginBottom: 20 }

function formatRetryAfter(seconds: number): string {
  if (seconds >= 3600) {
    const h = Math.ceil(seconds / 3600)
    return `${h} hour${h !== 1 ? 's' : ''}`
  }
  if (seconds >= 60) {
    const m = Math.ceil(seconds / 60)
    return `${m} minute${m !== 1 ? 's' : ''}`
  }
  return `${seconds} second${seconds !== 1 ? 's' : ''}`
}

export default function RedeemInvite() {
  const [searchParams] = useSearchParams()
  const rawCode = searchParams.get('code') ?? ''

  const [form, setForm] = useState<FormState>({
    org_name: '',
    admin_email: '',
    admin_name: '',
    data_region: 'us',
  })
  const [submitting, setSubmitting] = useState(false)
  const [success, setSuccess] = useState(false)
  const [errors, setErrors] = useState<Partial<Record<keyof FormState | '_global', string>>>({})

  function validate(): boolean {
    const next: typeof errors = {}
    if (!form.org_name.trim() || form.org_name.trim().length < 2)
      next.org_name = 'Organization name must be at least 2 characters.'
    if (!form.admin_name.trim())
      next.admin_name = 'Your name is required.'
    if (!form.admin_email.trim() || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(form.admin_email))
      next.admin_email = 'A valid email address is required.'
    setErrors(next)
    return Object.keys(next).length === 0
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!validate()) return
    setSubmitting(true)
    setErrors({})

    try {
      const resp = await fetch(`${API_BASE}/api/registry/signup`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ...form, invite_code: rawCode }),
      })

      if (resp.status === 400) {
        const body: ApiError = await resp.json().catch(() => ({}))
        setErrors({ _global: body.message || 'This invite code is invalid or has already been used.' })
        return
      }

      if (resp.status === 429) {
        const body: ApiError = await resp.json().catch(() => ({}))
        const wait = body.retry_after_seconds
          ? `Please try again in ${formatRetryAfter(body.retry_after_seconds)}.`
          : 'You have been rate limited. Please try again later.'
        setErrors({ _global: wait })
        return
      }

      if (!resp.ok) {
        const body: ApiError = await resp.json().catch(() => ({}))
        setErrors({ _global: body.message || 'Something went wrong, please try again.' })
        return
      }

      setSuccess(true)
    } catch {
      setErrors({ _global: 'Network error. Please check your connection and try again.' })
    } finally {
      setSubmitting(false)
    }
  }

  function field(key: keyof FormState) {
    return (v: string) => setForm(f => ({ ...f, [key]: v }))
  }

  if (!rawCode) {
    return (
      <div style={{ maxWidth: 480, margin: '80px auto', textAlign: 'center', padding: '0 24px' }}>
        <h1 style={{ fontSize: 24, marginBottom: 12, color: 'var(--text, #e0e0e0)' }}>
          Invite link required
        </h1>
        <p style={{ color: 'var(--text-muted, #888)', lineHeight: 1.6 }}>
          No invite code was found. Please use the invite link provided by your operator.
        </p>
      </div>
    )
  }

  if (!INVITE_CODE_RE.test(rawCode)) {
    return (
      <div style={{ maxWidth: 480, margin: '80px auto', textAlign: 'center', padding: '0 24px' }}>
        <h1 style={{ fontSize: 24, marginBottom: 12, color: 'var(--text, #e0e0e0)' }}>
          Invalid invite code
        </h1>
        <p style={{ color: 'var(--text-muted, #888)', lineHeight: 1.6 }}>
          The code "{rawCode}" is not a valid Signal Loom invite code. Check the invite link sent by your operator.
        </p>
      </div>
    )
  }

  if (success) {
    return (
      <div style={{ maxWidth: 480, margin: '80px auto', textAlign: 'center', padding: '0 24px' }}>
        <div style={{ fontSize: 48, marginBottom: 24 }}>&#x1F4EC;</div>
        <h1 style={{ fontSize: 24, marginBottom: 12, color: 'var(--text, #e0e0e0)' }}>
          Check your email
        </h1>
        <p style={{ color: 'var(--text-muted, #888)', lineHeight: 1.6 }}>
          We've sent a password setup link to <strong>{form.admin_email}</strong>.
          Follow the link to set your password and sign in to your new workspace.
        </p>
      </div>
    )
  }

  return (
    <div style={{ maxWidth: 480, margin: '60px auto', padding: '0 24px' }}>
      <div style={{ marginBottom: 36 }}>
        <h1 style={{ fontSize: 28, fontWeight: 700, color: 'var(--text, #e0e0e0)', marginBottom: 8 }}>
          Create your workspace
        </h1>
        <p style={{ color: 'var(--text-muted, #888)', fontSize: 14 }}>
          Invite code:{' '}
          <code style={{ color: 'var(--cyan, #00d4ff)', fontFamily: 'monospace' }}>{rawCode}</code>
        </p>
      </div>

      {errors._global && (
        <div style={{
          background: 'rgba(220,50,50,0.1)',
          border: '1px solid rgba(220,50,50,0.4)',
          borderRadius: 6,
          padding: '12px 16px',
          marginBottom: 20,
          color: '#ff6b6b',
          fontSize: 14,
        }}>
          {errors._global}
        </div>
      )}

      <form onSubmit={handleSubmit} noValidate>
        <div style={fieldStyle}>
          <label htmlFor="org_name" style={labelStyle}>Organization name *</label>
          <input
            id="org_name"
            type="text"
            value={form.org_name}
            onChange={e => field('org_name')(e.target.value)}
            placeholder="Acme Corp"
            style={{ ...inputStyle, borderColor: errors.org_name ? '#ff6b6b' : undefined }}
            disabled={submitting}
          />
          {errors.org_name && (
            <span style={{ color: '#ff6b6b', fontSize: 12, marginTop: 4, display: 'block' }}>
              {errors.org_name}
            </span>
          )}
        </div>

        <div style={fieldStyle}>
          <label htmlFor="admin_name" style={labelStyle}>Your name *</label>
          <input
            id="admin_name"
            type="text"
            value={form.admin_name}
            onChange={e => field('admin_name')(e.target.value)}
            placeholder="Jane Smith"
            style={{ ...inputStyle, borderColor: errors.admin_name ? '#ff6b6b' : undefined }}
            disabled={submitting}
          />
          {errors.admin_name && (
            <span style={{ color: '#ff6b6b', fontSize: 12, marginTop: 4, display: 'block' }}>
              {errors.admin_name}
            </span>
          )}
        </div>

        <div style={fieldStyle}>
          <label htmlFor="admin_email" style={labelStyle}>Work email *</label>
          <input
            id="admin_email"
            type="email"
            value={form.admin_email}
            onChange={e => field('admin_email')(e.target.value)}
            placeholder="jane@acme.com"
            style={{ ...inputStyle, borderColor: errors.admin_email ? '#ff6b6b' : undefined }}
            disabled={submitting}
          />
          {errors.admin_email && (
            <span style={{ color: '#ff6b6b', fontSize: 12, marginTop: 4, display: 'block' }}>
              {errors.admin_email}
            </span>
          )}
        </div>

        <div style={fieldStyle}>
          <span style={labelStyle}>Data region</span>
          <div style={{ display: 'flex', gap: 16 }}>
            {(['us', 'eu'] as DataRegion[]).map(region => (
              <label
                key={region}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 8,
                  cursor: 'pointer',
                  color: 'var(--text, #e0e0e0)',
                  fontSize: 14,
                }}
              >
                <input
                  type="radio"
                  name="data_region"
                  value={region}
                  checked={form.data_region === region}
                  onChange={() => field('data_region')(region)}
                  disabled={submitting}
                />
                {region.toUpperCase()}
              </label>
            ))}
          </div>
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
            color: submitting ? 'var(--text-muted, #888)' : '#000',
            fontSize: 15,
            fontWeight: 600,
            cursor: submitting ? 'not-allowed' : 'pointer',
            transition: 'background 0.2s',
          }}
        >
          {submitting ? 'Creating workspace...' : 'Create workspace'}
        </button>
      </form>

      <p style={{ marginTop: 24, textAlign: 'center', fontSize: 13, color: 'var(--text-muted, #888)' }}>
        Already have an account?{' '}
        <a href="/" style={{ color: 'var(--cyan, #00d4ff)', textDecoration: 'none' }}>Sign in</a>
      </p>
    </div>
  )
}
