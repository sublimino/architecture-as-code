import { useState } from 'react'
import { useAppContext } from '../App'

export default function ApiKeyRevealModal() {
  const { apiKeyReveal, setApiKeyReveal } = useAppContext()
  const [copied, setCopied] = useState(false)

  if (!apiKeyReveal) return null

  async function handleCopy() {
    await navigator.clipboard.writeText(apiKeyReveal!.key)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  function dismiss() {
    setApiKeyReveal(null)
  }

  return (
    <div
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.8)',
        display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 2000,
      }}
    >
      <div
        className="card"
        style={{ width: 520, maxWidth: '95vw', padding: 28 }}
        role="dialog"
        aria-modal="true"
        aria-labelledby="api-key-modal-title"
      >
        <h2 id="api-key-modal-title" style={{ fontSize: 17, fontWeight: 700, marginBottom: 8 }}>
          Your API Key
        </h2>

        <p style={{ fontSize: 13, fontWeight: 600, color: 'var(--warning, #f59e0b)', marginBottom: 20 }}>
          This is the only time you will see this key — store it securely now.
          It cannot be shown again after you dismiss this dialog.
        </p>

        {/* Key display */}
        <div style={{
          background: 'var(--surface2)', border: '1px solid var(--border)',
          borderRadius: 6, padding: '12px 14px',
          fontFamily: 'monospace', fontSize: 13,
          wordBreak: 'break-all', lineHeight: 1.6,
          color: 'var(--text)', marginBottom: 20,
          userSelect: 'all',
        }}>
          {apiKeyReveal.key}
        </div>

        {/* Actions */}
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
            onClick={dismiss}
          >
            I've saved it — dismiss
          </button>
        </div>

        <p style={{ fontSize: 11, color: 'var(--muted)', textAlign: 'center' }}>
          Prefix for reference:{' '}
          <code style={{ fontFamily: 'monospace' }}>{apiKeyReveal.prefix_hint}…</code>
        </p>
      </div>
    </div>
  )
}
