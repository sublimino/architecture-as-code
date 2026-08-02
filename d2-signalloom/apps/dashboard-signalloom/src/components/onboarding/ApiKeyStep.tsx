import { useState } from 'react'
import StepIcon from './StepIcon'

export interface RevealedKey {
  key: string
  prefix_hint: string
}

interface Props {
  revealed: RevealedKey | null
  revealing: boolean
  error?: string
  onReveal: () => void
  onContinue: () => void
  onBack: () => void
}

// Wizard step referencing the API key (86caytfw5 acceptance criterion 4 —
// "if the onboarding wizard ships in the same window, include an opt-in
// step referencing the API key. NOT force-reveal."). Missed in Slice 1a
// (only the Settings side shipped); this closes that gap.
//
// Two-phase, matching the "agree before showing" requirement: a confirm
// screen first ("this can only be shown once"), then the actual reveal —
// same one-time-reveal semantics as Settings' action, just reachable here
// too. Opting out tells the user exactly where to get it later.
export default function ApiKeyStep({ revealed, revealing, error, onReveal, onContinue, onBack }: Props) {
  const [confirming, setConfirming] = useState(false)
  const [copied, setCopied] = useState(false)

  async function handleCopy() {
    if (!revealed) return
    await navigator.clipboard.writeText(revealed.key)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <div style={{ maxWidth: 560 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginBottom: 6 }}>
        <StepIcon kind="api-key" />
        <h1 style={{ fontSize: 24, fontWeight: 700, color: 'var(--text)' }}>
          Your API key
        </h1>
      </div>
      <p style={{ color: 'var(--muted)', fontSize: 13, marginBottom: 20 }}>
        Signal Loom issued an API key for programmatic access to your agent registry — you'll
        need it if you plan to integrate with our API. It's optional right now; you can always
        reveal it later from Settings → API Access.
      </p>

      {revealed ? (
        <>
          <p style={{ fontSize: 13, fontWeight: 600, color: 'var(--warning, #f59e0b)', marginBottom: 12 }}>
            This is the only time you'll see this key — store it securely now.
          </p>
          <div style={{
            background: 'var(--surface2)', border: '1px solid var(--border)',
            borderRadius: 6, padding: '12px 14px',
            fontFamily: 'monospace', fontSize: 13,
            wordBreak: 'break-all', lineHeight: 1.6,
            color: 'var(--text)', marginBottom: 16,
            userSelect: 'all',
          }}>
            {revealed.key}
          </div>
          <button className="btn btn-primary" onClick={handleCopy} style={{ minWidth: 110, marginBottom: 8 }}>
            {copied ? 'Copied!' : 'Copy key'}
          </button>
        </>
      ) : confirming ? (
        <div style={{ marginBottom: 16 }}>
          <p style={{ fontSize: 13, fontWeight: 600, color: 'var(--warning, #f59e0b)', marginBottom: 16 }}>
            This is the only time you'll be able to see this key — make sure you're ready to
            store it securely before continuing.
          </p>
          {error && (
            <p style={{ fontSize: 13, color: '#ff6b6b', marginBottom: 12 }}>{error}</p>
          )}
          <div style={{ display: 'flex', gap: 10 }}>
            <button className="btn btn-secondary" onClick={() => setConfirming(false)} disabled={revealing}>
              Never mind
            </button>
            <button className="btn btn-primary" onClick={onReveal} disabled={revealing}>
              {revealing ? 'Revealing…' : 'Yes, reveal it'}
            </button>
          </div>
        </div>
      ) : (
        <button className="btn btn-primary" onClick={() => setConfirming(true)} style={{ marginBottom: 16 }}>
          Reveal my API key
        </button>
      )}

      <div style={{ display: 'flex', gap: 10, marginTop: 24 }}>
        <button type="button" className="btn btn-secondary" onClick={onBack}>
          Back
        </button>
        <button type="button" className="btn btn-primary" onClick={onContinue}>
          {revealed ? 'Continue' : "I'll do this later"}
        </button>
      </div>
    </div>
  )
}
