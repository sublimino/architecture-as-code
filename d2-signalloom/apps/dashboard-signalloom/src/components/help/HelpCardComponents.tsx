import { useState } from 'react'

export interface CopyableCodeBlockProps {
  code: string
  language?: string
  title?: string
  testId?: string
}

export function CopyableCodeBlock({ code, language = 'bash', title, testId }: CopyableCodeBlockProps) {
  const [copied, setCopied] = useState(false)

  const handleCopy = async () => {
    try {
      if (typeof navigator !== 'undefined' && navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(code)
        setCopied(true)
        setTimeout(() => setCopied(false), 2000)
      }
    } catch {
      // clipboard access error / fallback
    }
  }

  return (
    <div
      data-testid={testId || 'copyable-code-block'}
      style={{
        borderRadius: 8,
        border: '1px solid var(--border)',
        background: 'var(--surface2)',
        marginBottom: 16,
        overflow: 'hidden',
      }}
    >
      <div
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          padding: '6px 12px',
          borderBottom: '1px solid var(--border)',
          background: 'rgba(255, 255, 255, 0.03)',
        }}
      >
        <span
          style={{
            fontSize: 11,
            fontWeight: 600,
            color: 'var(--muted)',
            textTransform: 'uppercase',
            letterSpacing: '0.05em',
          }}
        >
          {title || language}
        </span>
        <button
          type="button"
          onClick={handleCopy}
          aria-label={copied ? 'Copied code to clipboard' : 'Copy code to clipboard'}
          className="btn btn-secondary"
          style={{
            padding: '2px 10px',
            fontSize: 11,
            cursor: 'pointer',
            height: 24,
            display: 'inline-flex',
            alignItems: 'center',
            gap: 4,
          }}
        >
          {copied ? '✓ Copied' : 'Copy'}
        </button>
      </div>
      <pre
        style={{
          margin: 0,
          padding: '12px 14px',
          fontSize: 12.5,
          lineHeight: 1.55,
          overflowX: 'auto',
          fontFamily: 'var(--font-mono, monospace)',
          color: 'var(--text)',
        }}
      >
        <code>{code}</code>
      </pre>
    </div>
  )
}

export interface DocLinkCardProps {
  title: string
  description: string
  href: string
  badge?: string
  testId?: string
}

export function DocLinkCard({ title, description, href, badge, testId }: DocLinkCardProps) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer"
      data-testid={testId || 'doc-link-card'}
      style={{
        display: 'block',
        padding: '14px 18px',
        borderRadius: 8,
        border: '1px solid var(--border)',
        background: 'var(--surface2)',
        textDecoration: 'none',
        transition: 'border-color 0.15s ease, background 0.15s ease',
      }}
      onMouseEnter={(e) => {
        e.currentTarget.style.borderColor = 'var(--cyan)'
        e.currentTarget.style.background = 'var(--surface)'
      }}
      onMouseLeave={(e) => {
        e.currentTarget.style.borderColor = 'var(--border)'
        e.currentTarget.style.background = 'var(--surface2)'
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 4 }}>
        <span style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--cyan)' }}>
          {title} ↗
        </span>
        {badge && (
          <span
            style={{
              fontSize: 10,
              fontWeight: 700,
              textTransform: 'uppercase',
              padding: '1px 6px',
              borderRadius: 4,
              background: 'var(--surface)',
              color: 'var(--muted)',
              border: '1px solid var(--border)',
            }}
          >
            {badge}
          </span>
        )}
      </div>
      <p style={{ fontSize: 12, color: 'var(--muted)', margin: 0, lineHeight: 1.45 }}>
        {description}
      </p>
    </a>
  )
}
