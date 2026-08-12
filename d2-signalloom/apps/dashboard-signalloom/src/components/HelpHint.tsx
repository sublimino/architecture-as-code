import { useId, useState } from 'react'

interface Props {
  label: string
  children: string
  testId?: string
}

/** A compact, keyboard-accessible explanation for nearby dashboard controls. */
export default function HelpHint({ label, children, testId }: Props) {
  const [open, setOpen] = useState(false)
  const id = useId()

  return (
    <span style={{ position: 'relative', display: 'inline-flex', alignItems: 'center' }}>
      <span onMouseEnter={() => setOpen(true)} onMouseLeave={() => setOpen(false)}>
        <button
          type="button"
          aria-label={label}
          aria-describedby={open ? id : undefined}
          data-testid={testId}
          onBlur={() => setOpen(false)}
          onFocus={() => setOpen(true)}
          style={{
            width: 18, height: 18, borderRadius: '50%', padding: 0,
            border: '1px solid var(--cyan)', background: 'transparent', color: 'var(--cyan)',
            fontSize: 12, fontWeight: 700, lineHeight: 1, cursor: 'help',
          }}
        >
          ?
        </button>
      </span>
      {open && (
        <span
          id={id}
          role="tooltip"
          style={{
            position: 'absolute', zIndex: 10, top: 'calc(100% + 6px)', left: 0,
            width: 260, padding: '8px 10px', borderRadius: 4,
            background: 'var(--surface)', border: '1px solid var(--border)', color: 'var(--text)',
            boxShadow: '0 6px 18px rgba(0, 0, 0, 0.25)', fontSize: 12, lineHeight: 1.4,
          }}
        >
          {children}
        </span>
      )}
    </span>
  )
}
