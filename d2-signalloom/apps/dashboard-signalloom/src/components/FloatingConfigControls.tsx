import { useState, useEffect } from 'react'
import { useLocation } from 'react-router-dom'
import DemoToggle from './DemoToggle'
import ThemeToggle from './ThemeToggle'
import WidthToggle from './WidthToggle'

export const CONFIG_CONTROLS_COLLAPSED_STORAGE_KEY = 'signalloom.config-controls-collapsed'
const NARROW_VIEWPORT_MAX_WIDTH = 600
const SIDEBAR_FOOTER_GAP = 16

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
  const [sidebarFooterClearance, setSidebarFooterClearance] = useState(0)

  useEffect(() => {
    if (typeof document === 'undefined') return
    const checkDockingObstacles = () => {
      const drawer = document.querySelector('[data-testid="agent-evidence-drawer"], [data-testid="evidence-drawer"]')
      setHasDrawerInDom(Boolean(drawer))

      const sidebarFooter = document.querySelector<HTMLElement>(
        'nav[aria-label="Primary navigation"] > div:last-child'
      )
      if (window.innerWidth > NARROW_VIEWPORT_MAX_WIDTH || !sidebarFooter) {
        setSidebarFooterClearance(0)
        return
      }

      const footerTop = sidebarFooter.getBoundingClientRect().top
      const clearance = Math.max(0, Math.ceil(window.innerHeight - footerTop + SIDEBAR_FOOTER_GAP))
      setSidebarFooterClearance(clearance)
    }
    checkDockingObstacles()
    const observer = new MutationObserver(checkDockingObstacles)
    observer.observe(document.body, { childList: true, subtree: true })
    window.addEventListener('resize', checkDockingObstacles)
    return () => {
      observer.disconnect()
      window.removeEventListener('resize', checkDockingObstacles)
    }
  }, [])

  const hasDrawer = forceDrawerOffset ?? (hasDrawerParam || hasDrawerInDom)
  // When a drawer is open, dock at bottom: 70 to fully clear the drawer's footer actions.
  // When no drawer is open, dock comfortably at bottom: 16.
  const bottom = Math.max(hasDrawer ? 70 : 16, sidebarFooterClearance)

  function handleToggle() {
    setCollapsed((prev) => {
      const next = !prev
      storeConfigCollapsed(next)
      return next
    })
  }

  const toolbarStyle: React.CSSProperties = {
    position: 'fixed',
    bottom,
    right: 16,
    zIndex: 4000,
    display: 'flex',
    flexWrap: 'wrap',
    justifyContent: 'flex-end',
    alignItems: 'center',
    gap: 8,
    width: 'max-content',
    maxWidth: 'calc(100vw - 32px)',
    boxSizing: 'border-box',
    transition: 'bottom 0.15s ease-out',
  }

  const buttonStyle: React.CSSProperties = {
    position: 'static',
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
  }

  if (collapsed) {
    return (
      <div
        data-testid="floating-config-controls"
        role="group"
        aria-label="Dashboard configuration"
        style={toolbarStyle}
      >
        <button
          type="button"
          data-testid="config-collapse-toggle"
          onClick={handleToggle}
          aria-expanded={false}
          aria-label="Show configuration options"
          title="Show configuration options (Theme, Width, Demo)"
          style={buttonStyle}
        >
          <span aria-hidden="true" style={{ fontSize: 13 }}>⚙</span>
          <span>Config</span>
        </button>
      </div>
    )
  }

  return (
    <div
      data-testid="floating-config-controls"
      role="group"
      aria-label="Dashboard configuration"
      style={toolbarStyle}
    >
      <button
        type="button"
        data-testid="config-collapse-toggle"
        onClick={handleToggle}
        aria-expanded={true}
        aria-label="Hide configuration options"
        title="Hide configuration options"
        style={buttonStyle}
      >
        <span aria-hidden="true" style={{ fontSize: 11 }}>▾</span>
        <span>Hide</span>
      </button>
      <WidthToggle embedded />
      <ThemeToggle embedded />
      <DemoToggle embedded />
    </div>
  )
}
