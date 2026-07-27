interface Props {
  message: string
  onRetry?: () => void
}

export default function ErrorState({ message, onRetry }: Props) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '48px 24px', gap: 14 }}>
      <span style={{ fontSize: 36 }}>⚠️</span>
      <p style={{ color: 'var(--error)', fontWeight: 600 }}>Failed to load</p>
      <p style={{ color: 'var(--muted)', fontSize: 13, maxWidth: 400, textAlign: 'center' }}>{message}</p>
      {onRetry && (
        <button className="btn btn-secondary" onClick={onRetry}>
          Retry
        </button>
      )}
    </div>
  )
}
