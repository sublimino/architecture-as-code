import { useId, useState, type FormEvent } from 'react'

/** Server contract: 1..256 characters after trimming, 422 otherwise. */
export const STUN_REASON_MAX = 256

/** Starting points only; free text is always accepted. */
export const SUGGESTED_STUN_REASONS = [
  'Compliance failure: securityContext not set',
  'Anomalous egress to an unknown host',
  'Credential misuse suspected',
  'Incident response drill',
] as const

export type StunReasonCheck = { ok: true; reason: string } | { ok: false; error: string }

export function validateStunReason(raw: string): StunReasonCheck {
  const reason = raw.trim()
  if (reason.length === 0) return { ok: false, error: 'A reason is required before an agent can be stunned.' }
  if (reason.length > STUN_REASON_MAX) {
    return { ok: false, error: `Keep the reason to ${STUN_REASON_MAX} characters or fewer (currently ${reason.length}).` }
  }
  return { ok: true, reason }
}

interface Props {
  agentName: string
  onConfirm: (reason: string) => void
  onCancel: () => void
  busy?: boolean
}

/**
 * The stun confirm step. A stun has no undo, and the server records the
 * operator's reason against their identity, so the reason is asked for here,
 * validated to the server's own bounds, and only then sent.
 */
export default function StunReasonForm({ agentName, onConfirm, onCancel, busy = false }: Props) {
  const [value, setValue] = useState('')
  const [error, setError] = useState<string | null>(null)
  const inputId = useId()
  const errorId = useId()

  function submit(e: FormEvent) {
    e.preventDefault()
    const check = validateStunReason(value)
    if (!check.ok) {
      setError(check.error)
      return
    }
    setError(null)
    onConfirm(check.reason)
  }

  const length = value.trim().length

  return (
    <form
      data-testid="supercred-stun-confirm"
      onSubmit={submit}
      noValidate
      className="card"
      style={{
        padding: '14px 18px', marginTop: 12,
        border: '1px solid color-mix(in srgb, var(--error) 40%, transparent)',
        background: 'color-mix(in srgb, var(--error) 5%, transparent)',
      }}
    >
      <label htmlFor={inputId} style={{ display: 'block', fontSize: 13, fontWeight: 600, marginBottom: 6, color: 'var(--text)' }}>
        Reason for stunning {agentName}
      </label>
      <input
        id={inputId}
        data-testid="stun-reason-input"
        type="text"
        value={value}
        autoFocus
        aria-invalid={error !== null}
        aria-describedby={error ? errorId : undefined}
        onChange={e => {
          setValue(e.target.value)
          if (error) setError(null)
        }}
        placeholder="Why is this agent being stunned? Recorded on the audit trail."
        style={{
          width: '100%', boxSizing: 'border-box', padding: '6px 10px', fontSize: 13,
          background: 'var(--surface)', color: 'var(--text)',
          border: `1px solid ${error ? 'var(--error)' : 'var(--border)'}`, borderRadius: 4,
        }}
      />
      <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11, color: 'var(--muted)', margin: '4px 0 8px' }}>
        <span>Recorded verbatim with your identity. There is no undo.</span>
        <span data-testid="stun-reason-count">{length}/{STUN_REASON_MAX}</span>
      </div>
      {error && (
        <p id={errorId} role="alert" data-testid="stun-reason-error" style={{ fontSize: 12, color: 'var(--text)', margin: '0 0 8px', fontWeight: 600 }}>
          {error}
        </p>
      )}
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginBottom: 10 }}>
        {SUGGESTED_STUN_REASONS.map(s => (
          <button
            key={s}
            type="button"
            className="btn btn-secondary"
            aria-label={`Use reason: ${s}`}
            onClick={() => {
              setValue(s)
              setError(null)
            }}
            style={{ fontSize: 11, padding: '3px 8px' }}
          >
            {s}
          </button>
        ))}
      </div>
      <div style={{ display: 'flex', gap: 8 }}>
        <button
          type="submit"
          className="btn btn-secondary"
          disabled={busy}
          style={{ fontSize: 12, padding: '5px 12px', color: 'var(--error)', borderColor: 'var(--error)' }}
        >
          Confirm stun
        </button>
        <button type="button" className="btn btn-secondary" onClick={onCancel} disabled={busy} style={{ fontSize: 12, padding: '5px 12px' }}>
          Cancel
        </button>
      </div>
    </form>
  )
}
