import { useState, useEffect } from 'react'
import { useLocation } from 'react-router-dom'
import DemoToggle from './DemoToggle'
import ThemeToggle from './ThemeToggle'
import WidthToggle from './WidthToggle'

export const CONFIG_CONTROLS_COLLAPSED_STORAGE_KEY = 'signalloom.config-controls-collapsed'

export function readStoredConfigCollapsed(): boolean {
  if (typeof window === 'undefined' || !window.localStorage) return false
  try {
    return window.localStorage.getItem(CONFIG_CONTROLS_COLLAPSED_STORAGE_KEY) === 'true'
  } catch {
    return false
  }
}

export function storeConfigCollapsed(collapsed: boolean): void {
  if (typeof window === 'undefined' || !window.localStorage) return
  try {
    window.localStorage.setItem(CONFIG_CONTROLS_COLLAPSED_STORAGE_KEY, String(collapsed))
  } catch {
    // Ignore localStorage write failures
  }
}

export interface FloatingConfigControlsProps {
  initialCollapsed?: boolean
  forceDrawerOffset?: boolean
}

export default function FloatingConfigControls({
  initialCollapsed,
  forceDrawerOffset,
}: FloatingConfigControlsProps = {}) {
  const location = useLocation()
  const [collapsed, setCollapsed] = useState<boolean>(() => {
    if (initialCollapsed !== undefined) return initialCollapsed
    return readStoredConfigCollapsed()
  })

  // Detect whether the quick evidence drawer or other right drawer is active
  const hasDrawerParam = new URLSearchParams(location.search).has('drawer')
  const [hasDrawerInDom, setHasDrawerInDom] = useState(false)

  useEffect(() => {
    if (typeof document === 'undefined') return
    const checkDrawer = () => {
      const el = document.querySelector('[data-testid="agent-evidence-drawer"], [data-testid="evidence-drawer"]')
      setHasDrawerInDom(Boolean(el))
    }
    checkDrawer()
    const observer = new MutationObserver(checkDrawer)
    observer.observe(document.body, { childList: true, subtree: true })
    return () => observer.disconnect()
  }, [])

  const hasDrawer = forceDrawerOffset ?? (hasDrawerParam || hasDrawerInDom)
  // When a drawer is open, dock at bottom: 70 to fully clear the drawer's footer actions.
  // When no drawer is open, dock comfortably at bottom: 16.
  const bottom = hasDrawer ? 70 : 16

  function handleToggle() {
    setCollapsed((prev) => {
      const next = !prev
      storeConfigCollapsed(next)
      return next
    })
  }

  const buttonStyle: React.CSSProperties = {
    position: 'fixed',
    bottom,
    zIndex: 4000,
    padding: '8px 12px',
    borderRadius: 8,
    cursor: 'pointer',
    fontSize: 12,
    fontWeight: 700,
    letterSpacing: 0.3,
    border: '1px solid var(--border-subtle, var(--border, #333))',
    background: 'var(--surface2, #1a1a1a)',
    color: 'var(--text, #ddd)',
    boxShadow: '0 2px 8px rgba(0,0,0,0.4)',
    display: 'inline-flex',
    alignItems: 'center',
    gap: 6,
    transition: 'bottom 0.15s ease-out',
  }

  if (collapsed) {
    return (
      <button
        type="button"
        data-testid="config-collapse-toggle"
        onClick={handleToggle}
        aria-expanded={false}
        aria-label="Show configuration options"
        title="Show configuration options (Theme, Width, Demo)"
        style={{
          ...buttonStyle,
          right: 16,
        }}
      >
        <span aria-hidden="true" style={{ fontSize: 13 }}>⚙</span>
        <span>Config</span>
      </button>
    )
  }

  return (
    <div data-testid="floating-config-controls">
      <WidthToggle bottom={bottom} />
      <ThemeToggle bottom={bottom} />
      <DemoToggle bottom={bottom} />
      <button
        type="button"
        data-testid="config-collapse-toggle"
        onClick={handleToggle}
        aria-expanded={true}
        aria-label="Hide configuration options"
        title="Hide configuration options"
        style={{
          ...buttonStyle,
          right: 355,
        }}
      >
        <span aria-hidden="true" style={{ fontSize: 11 }}>▾</span>
        <span>Hide</span>
      </button>
    </div>
  )
}
