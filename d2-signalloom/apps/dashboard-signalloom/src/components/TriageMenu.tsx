import { useEffect, useRef, useState } from 'react'
import { colors } from '../styles/tokens'

export type TriageAction = 'enroll' | 'dismiss' | 'review'

export default function TriageMenu({ accountId, onAction }: {
  accountId: string
  onAction: (action: TriageAction, id: string) => void
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
        style={{ fontSize: 11, padding: '4px 10px', gap: 4 }}
        onClick={() => setOpen(!open)}
      >
        Actions ▾
      </button>
      {open && (
        <div style={{
          position: 'absolute', right: 0, top: '100%', marginTop: 4,
          background: 'var(--surface)', border: '1px solid var(--border-subtle)',
          borderRadius: 8, zIndex: 100, minWidth: 170,
          boxShadow: '0 8px 24px rgba(0,0,0,0.4)',
          overflow: 'hidden',
        }}>
          <button style={item} onClick={() => { onAction('review', accountId); setOpen(false) }}
            onMouseEnter={e => (e.currentTarget.style.background = 'var(--surface2)')}
            onMouseLeave={e => (e.currentTarget.style.background = 'none')}>
            Mark as Reviewed
          </button>
          <button style={item} onClick={() => { onAction('enroll', accountId); setOpen(false) }}
            onMouseEnter={e => (e.currentTarget.style.background = 'var(--surface2)')}
            onMouseLeave={e => (e.currentTarget.style.background = 'none')}>
            Request Enrollment
          </button>
          <button
            style={{ ...item, color: colors.amber, borderTop: '1px solid var(--border)' }}
            onClick={() => { onAction('dismiss', accountId); setOpen(false) }}
            onMouseEnter={e => (e.currentTarget.style.background = 'var(--surface2)')}
            onMouseLeave={e => (e.currentTarget.style.background = 'none')}
          >
            Dismiss
          </button>
        </div>
      )}
    </div>
  )
}
