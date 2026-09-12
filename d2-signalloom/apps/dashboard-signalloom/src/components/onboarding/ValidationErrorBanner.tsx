import React from 'react'

interface ValidationErrorBannerProps {
  errors: string[]
  onDismiss?: () => void
}

export default function ValidationErrorBanner({ errors, onDismiss }: ValidationErrorBannerProps) {
  if (!errors || errors.length === 0) return null

  return (
    <div
      role="alert"
      aria-live="assertive"
      data-testid="validation-error-banner"
      style={{
        background: 'rgba(239, 68, 68, 0.12)',
        border: '1px solid var(--error, #EF4444)',
        borderRadius: 8,
        padding: '12px 16px',
        marginBottom: 20,
        color: 'var(--text)',
        fontSize: 13,
      }}
    >
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12 }}>
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: 10 }}>
          <svg
            width="18"
            height="18"
            viewBox="0 0 24 24"
            fill="none"
            stroke="var(--error, #EF4444)"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            style={{ flexShrink: 0, marginTop: 1 }}
            aria-hidden="true"
          >
            <circle cx="12" cy="12" r="10" />
            <line x1="12" y1="8" x2="12" y2="12" />
            <line x1="12" y1="16" x2="12.01" y2="16" />
          </svg>
          <div>
            <div style={{ fontWeight: 600, color: 'var(--error, #EF4444)', marginBottom: errors.length > 1 ? 4 : 0 }}>
              {errors.length === 1 ? errors[0] : 'Please correct the following errors before continuing:'}
            </div>
            {errors.length > 1 && (
              <ul style={{ margin: '4px 0 0', paddingLeft: 18, color: 'var(--text)' }}>
                {errors.map((err, i) => (
                  <li key={i} style={{ marginTop: 2 }}>{err}</li>
                ))}
              </ul>
            )}
          </div>
        </div>
        {onDismiss && (
          <button
            type="button"
            onClick={onDismiss}
            aria-label="Dismiss error"
            style={{
              background: 'none',
              border: 'none',
              color: 'var(--muted)',
              cursor: 'pointer',
              padding: 2,
              display: 'flex',
              alignItems: 'center',
            }}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <line x1="18" y1="6" x2="6" y2="18" />
              <line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        )}
      </div>
    </div>
  )
}
