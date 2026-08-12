import { useCallback, useEffect, useRef, useState } from 'react'
import type { KeyboardEvent as ReactKeyboardEvent } from 'react'

/**
 * Global "press ? for shortcuts" overlay.
 *
 * Source of truth for the documented keys is Sidebar.tsx's window keydown
 * handler — `/` focuses quick search and `1`..`N` navigate to the Nth
 * non-superadmin nav item. Nothing is listed here that the app does not
 * actually bind. Keep this table in step with that handler.
 */
interface Shortcut {
  keys: string[]
  /** Rendered between keys, e.g. `1` … `9`. */
  separator?: string
  description: string
}

const SHORTCUTS: Shortcut[] = [
  { keys: ['/'], description: 'Focus the sidebar Quick search box' },
  { keys: ['1', '9'], separator: '…', description: 'Jump to the nth item in the sidebar navigation' },
  { keys: ['?'], description: 'Open this keyboard shortcuts overlay' },
  { keys: ['Esc'], description: 'Close this overlay' },
  { keys: ['Tab'], description: 'Move between controls — focus stays inside this overlay while it is open' },
]

const FOCUSABLE = 'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'

/** Mirrors Sidebar.tsx so typing `?` into a field never hijacks the keystroke. */
function isTypingTarget(target: EventTarget | null) {
  const element = target as HTMLElement | null
  const tag = element?.tagName
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || Boolean(element?.isContentEditable)
}

/** Matches the sidebar's <kbd> chrome so the app reads as one product. */
function Key({ children }: { children: string }) {
  return (
    <kbd
      data-testid="keyboard-shortcuts-key"
      style={{
        background: 'var(--surface)',
        border: '1px solid var(--border)',
        borderRadius: 4,
        color: 'var(--dim)',
        fontSize: 11,
        lineHeight: '18px',
        minWidth: 18,
        padding: '0 5px',
        textAlign: 'center',
        display: 'inline-block',
      }}
    >
      {children}
    </kbd>
  )
}

export default function KeyboardShortcutsOverlay() {
  const [open, setOpen] = useState(false)
  const openRef = useRef(false)
  const dialogRef = useRef<HTMLDivElement>(null)
  const closeRef = useRef<HTMLButtonElement>(null)
  const restoreFocusRef = useRef<HTMLElement | null>(null)

  const close = useCallback(() => {
    if (!openRef.current) return
    openRef.current = false
    setOpen(false)
    // Return focus to whatever the user was on before the overlay stole it.
    restoreFocusRef.current?.focus()
    restoreFocusRef.current = null
  }, [])

  // One window listener for the component's lifetime — opening is idempotent,
  // so a repeated `?` can never stack a second dialog or a second listener.
  useEffect(() => {
    function handleKeyDown(e: globalThis.KeyboardEvent) {
      if (e.key === 'Escape' && openRef.current) {
        e.preventDefault()
        close()
        return
      }
      if (e.metaKey || e.ctrlKey || e.altKey) return
      if (isTypingTarget(e.target)) return
      // `?` is Shift+/ on most layouts but not all — match the produced
      // character rather than the physical key combination.
      if (e.key === '?' && !openRef.current) {
        e.preventDefault()
        restoreFocusRef.current = document.activeElement as HTMLElement | null
        openRef.current = true
        setOpen(true)
      }
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [close])

  useEffect(() => {
    if (open) closeRef.current?.focus()
  }, [open])

  if (!open) return null

  function trapTab(e: ReactKeyboardEvent<HTMLDivElement>) {
    if (e.key !== 'Tab') return
    const dialog = dialogRef.current
    if (!dialog) return
    const focusable = Array.from(dialog.querySelectorAll<HTMLElement>(FOCUSABLE))
    if (focusable.length === 0) {
      e.preventDefault()
      return
    }
    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    const active = document.activeElement
    if (e.shiftKey && (active === first || !dialog.contains(active))) {
      e.preventDefault()
      last.focus()
    } else if (!e.shiftKey && (active === last || !dialog.contains(active))) {
      e.preventDefault()
      first.focus()
    }
  }

  return (
    <div
      data-testid="keyboard-shortcuts-backdrop"
      style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.53)', backdropFilter: 'blur(6px)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1000 }}
      onClick={e => { if (e.target === e.currentTarget) close() }}
    >
      <div
        ref={dialogRef}
        data-testid="keyboard-shortcuts-overlay"
        role="dialog"
        aria-modal="true"
        aria-labelledby="keyboard-shortcuts-title"
        onKeyDown={trapTab}
        className="card slide-up"
        style={{ width: 460, maxWidth: '95vw', maxHeight: '85vh', display: 'flex', flexDirection: 'column', position: 'relative', padding: 0, overflow: 'hidden' }}
      >
        <div style={{ padding: '20px 24px 0', flexShrink: 0 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
            <h2 id="keyboard-shortcuts-title" style={{ fontSize: 17, fontWeight: 700 }}>Keyboard shortcuts</h2>
            <button
              ref={closeRef}
              data-testid="keyboard-shortcuts-close"
              onClick={close}
              aria-label="Close keyboard shortcuts"
              style={{ background: 'none', border: 'none', color: 'var(--muted)', fontSize: 22, lineHeight: 1, cursor: 'pointer', padding: '0 4px' }}
            >
              ×
            </button>
          </div>
        </div>

        <div style={{ flex: 1, overflow: 'auto', padding: '4px 24px 24px' }}>
          <dl style={{ display: 'flex', flexDirection: 'column', gap: 2, margin: 0 }}>
            {SHORTCUTS.map(({ keys, separator, description }) => (
              <div
                key={keys.join('-')}
                style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '9px 0', borderBottom: '1px solid var(--border)' }}
              >
                <dt style={{ display: 'flex', alignItems: 'center', gap: 5, flexShrink: 0, minWidth: 78 }}>
                  {keys.map((key, i) => (
                    <span key={key} style={{ display: 'inline-flex', alignItems: 'center', gap: 5 }}>
                      {i > 0 && separator && <span aria-hidden="true" style={{ color: 'var(--muted)', fontSize: 12 }}>{separator}</span>}
                      <Key>{key}</Key>
                    </span>
                  ))}
                </dt>
                <dd style={{ margin: 0, fontSize: 13, color: 'var(--muted)', lineHeight: 1.5 }}>{description}</dd>
              </div>
            ))}
          </dl>
          <p style={{ fontSize: 12, color: 'var(--muted)', marginTop: 14, textAlign: 'center' }}>
            Shortcuts are ignored while you are typing in a field.
          </p>
        </div>
      </div>
    </div>
  )
}
