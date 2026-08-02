/**
 * ApiKeyRotateModal — lets a tenant admin revoke their current API key
 * and generate a new one (Q6 follow-on, ClickUp 86caac5f9).
 *
 * Usage: pass an `onRotated` callback to receive the new key details,
 * and a `currentPrefixHint` string to show the user which key they're revoking.
 *
 *   <ApiKeyRotateModal
 *     currentPrefixHint="sl_live_xbc1ab"
 *     onRotated={(result) => console.log(result.key)}
 *     onClose={() => setOpen(false)}
 *   />
 *
 * Three phases:
 *   1. Confirm — warns the user that their current key will be permanently revoked.
 *   2. Reveal  — shows the new key (same one-time-reveal UX as the initial modal).
 *   3. Closed  — parent controls visibility via onClose.
 */
import { useState } from 'react'
import type { RotateApiKeyResponse } from '../types/api'

type Phase = 'confirm' | 'reveal'

interface Props {
  currentPrefixHint: string
  onRotated?: (result: RotateApiKeyResponse) => void
  onClose: () => void
  /** Async function that calls POST /api/tenants/{id}/api-keys/rotate */
  doRotate: () => Promise<RotateApiKeyResponse>
}

export default function ApiKeyRotateModal({
  currentPrefixHint,
  onRotated,
  onClose,
  doRotate,
}: Props) {
  const [phase, setPhase] = useState<Phase>('confirm')
  const [result, setResult] = useState<RotateApiKeyResponse | null>(null)
  const [copied, setCopied] = useState(false)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleConfirmRotate() {
    setLoading(true)
    setError(null)
    try {
      const newKey = await doRotate()
      setResult(newKey)
      setPhase('reveal')
      onRotated?.(newKey)
    } catch (err: unknown) {
      const status = (err as { response?: { status?: number } })?.response?.status
      if (status === 429) {
        setError('Key was rotated very recently — please wait a moment before rotating again.')
      } else {
        setError('Rotation failed. Please try again or contact support.')
      }
    } finally {
      setLoading(false)
    }
  }

  async function handleCopy() {
    if (!result) return
    await navigator.clipboard.writeText(result.key)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <div
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.53)', backdropFilter: 'blur(6px)',
        display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 2000,
      }}
    >
      <div
        className="card slide-up"
        style={{ width: 520, maxWidth: '95vw', padding: 28 }}
        role="dialog"
        aria-modal="true"
        aria-labelledby="rotate-key-modal-title"
      >
        {phase === 'confirm' && (
          <>
            <h2 id="rotate-key-modal-title" style={{ fontSize: 17, fontWeight: 700, marginBottom: 8 }}>
              Rotate API Key
            </h2>

            <p style={{ fontSize: 13, fontWeight: 600, color: 'var(--warning, #f59e0b)', marginBottom: 12 }}>
              Your current key will be permanently revoked — any integrations using it will stop
              working immediately.
            </p>

            <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 20 }}>
              Current key prefix:{' '}
              <code style={{ fontFamily: 'monospace' }}>{currentPrefixHint}…</code>
            </p>

            {error && (
              <p style={{ fontSize: 13, color: 'var(--danger, #ef4444)', marginBottom: 16 }}>
                {error}
              </p>
            )}

            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
              <button
                className="btn btn-secondary"
                onClick={onClose}
                disabled={loading}
              >
                Cancel
              </button>
              <button
                className="btn btn-danger"
                onClick={handleConfirmRotate}
                disabled={loading}
                style={{ minWidth: 130 }}
              >
                {loading ? 'Rotating…' : 'Revoke & rotate'}
              </button>
            </div>
          </>
        )}

        {phase === 'reveal' && result && (
          <>
            <h2 id="rotate-key-modal-title" style={{ fontSize: 17, fontWeight: 700, marginBottom: 8 }}>
              New API Key
            </h2>

            <p style={{ fontSize: 13, fontWeight: 600, color: 'var(--warning, #f59e0b)', marginBottom: 20 }}>
              This is the only time you will see this key — store it securely now.
              Your old key is already revoked.
            </p>

            <div style={{
              background: 'var(--surface2)', border: '1px solid var(--border)',
              borderRadius: 6, padding: '12px 14px',
              fontFamily: 'monospace', fontSize: 13,
              wordBreak: 'break-all', lineHeight: 1.6,
              color: 'var(--text)', marginBottom: 20,
              userSelect: 'all',
            }}>
              {result.key}
            </div>

            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end', marginBottom: 16 }}>
              <button
                className="btn btn-primary"
                onClick={handleCopy}
                style={{ minWidth: 110 }}
              >
                {copied ? 'Copied!' : 'Copy key'}
              </button>
              <button
                className="btn btn-secondary"
                onClick={onClose}
              >
                I've saved it — close
              </button>
            </div>

            <p style={{ fontSize: 11, color: 'var(--muted)', textAlign: 'center' }}>
              Prefix for reference:{' '}
              <code style={{ fontFamily: 'monospace' }}>{result.prefix_hint}…</code>
              {' · '}
              Scope: <code style={{ fontFamily: 'monospace' }}>{result.scope}</code>
            </p>
          </>
        )}
      </div>
    </div>
  )
}
