import { useEffect, useRef, useState } from 'react'

// "Manage Credentials ▾" — replaces the old side-by-side Issue/Revoke
// Credential buttons (ClickUp 86cak75u7) with a single dropdown, matching
// the Actions ▾ pattern already used by TriageMenu.tsx. Revoke is styled
// as destructive and separated by a divider, same convention as Dismiss
// in TriageMenu.
//
// Credential rotation (issue a replacement + revoke the old one in one
// step) is a separate, not-yet-built action — tracked in ClickUp. When it
// ships, it slots in here as a third menu item.

export default function CredentialActionsMenu({ onIssue, onRevoke }: {
  onIssue: () => void
  onRevoke: () => void
}) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    function handle(e: MouseEvent) {
      if (!ref.current?.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', handle)
    return () => document.removeEventListener('mousedown', handle)
  }, [open])

  const item: React.CSSProperties = {
    display: 'block', width: '100%', padding: '8px 14px',
    background: 'none', border: 'none', textAlign: 'left',
    fontSize: 13, cursor: 'pointer', fontFamily: 'inherit',
    color: 'var(--text)', transition: 'background 0.1s',
  }

  return (
    <div ref={ref} style={{ position: 'relative', display: 'inline-block' }}>
      <button
        className="btn btn-secondary"
        style={{ fontSize: 12, padding: '6px 14px', whiteSpace: 'nowrap', gap: 4 }}
        onClick={() => setOpen(!open)}
      >
        Manage Credentials ▾
      </button>
      {open && (
        <div style={{
          position: 'absolute', right: 0, top: '100%', marginTop: 4,
          background: 'var(--surface)', border: '1px solid var(--border-subtle)',
          borderRadius: 8, zIndex: 100, minWidth: 180,
          boxShadow: '0 8px 24px rgba(0,0,0,0.4)',
          overflow: 'hidden',
        }}>
          <button
            style={item}
            onClick={() => { onIssue(); setOpen(false) }}
            onMouseEnter={e => (e.currentTarget.style.background = 'var(--surface2)')}
            onMouseLeave={e => (e.currentTarget.style.background = 'none')}
          >
            Issue Credential
          </button>
          <button
            style={{ ...item, color: 'var(--red-base)', borderTop: '1px solid var(--border)' }}
            onClick={() => { onRevoke(); setOpen(false) }}
            onMouseEnter={e => (e.currentTarget.style.background = 'var(--surface2)')}
            onMouseLeave={e => (e.currentTarget.style.background = 'none')}
          >
            Revoke Credential
          </button>
        </div>
      )}
    </div>
  )
}
