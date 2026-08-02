// Generic confirm-before-destructive-action dialog (Slice 1a, Settings
// disconnect flow). Same modal chrome as ApiKeyRotateModal/ApiKeyRevealModal
// so confirm dialogs across the app look consistent.
interface Props {
  title: string
  body: string
  confirmLabel?: string
  loading?: boolean
  onConfirm: () => void
  onCancel: () => void
}

export default function ConfirmDialog({
  title,
  body,
  confirmLabel = 'Confirm',
  loading = false,
  onConfirm,
  onCancel,
}: Props) {
  return (
    <div
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.53)', backdropFilter: 'blur(6px)',
        display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 2000,
      }}
    >
      <div
        className="card slide-up"
        style={{ width: 440, maxWidth: '95vw', padding: 28 }}
        role="dialog"
        aria-modal="true"
        aria-labelledby="confirm-dialog-title"
      >
        <h2 id="confirm-dialog-title" style={{ fontSize: 17, fontWeight: 700, marginBottom: 12 }}>
          {title}
        </h2>

        <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 20 }}>{body}</p>

        <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
          <button className="btn btn-secondary" onClick={onCancel} disabled={loading}>
            Cancel
          </button>
          <button className="btn btn-danger" onClick={onConfirm} disabled={loading} style={{ minWidth: 100 }}>
            {loading ? 'Working…' : confirmLabel}
          </button>
        </div>
      </div>
    </div>
  )
}
