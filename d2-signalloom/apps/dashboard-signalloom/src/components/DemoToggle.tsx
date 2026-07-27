import { useEffect, useState } from 'react'
import { isDemoMode, toggleDemoMode, subscribeDemoMode } from '../api/demoMode'

// Corner widget that flips the api client between the live backend and local
// demo fixtures. Lets the dashboard be shown end-to-end even while the API is
// still in development — an early, visible proof that the UI renders.
export default function DemoToggle() {
  const [on, setOn] = useState(isDemoMode())
  useEffect(() => subscribeDemoMode(setOn), [])

  function handleClick() {
    toggleDemoMode()
    // Reload so every on-mount query re-runs against the newly selected source.
    window.location.reload()
  }

  return (
    <button
      type="button"
      onClick={handleClick}
      data-testid="demo-toggle"
      title={
        on
          ? 'Demo data ON — showing fixtures. Click to use the live API.'
          : 'Click to render with demo data (works even if the API is unavailable).'
      }
      style={{
        position: 'fixed',
        bottom: 16,
        right: 16,
        zIndex: 4000,
        padding: '8px 12px',
        borderRadius: 8,
        cursor: 'pointer',
        fontSize: 12,
        fontWeight: 700,
        letterSpacing: 0.3,
        border: `1px solid ${on ? '#f59e0b' : 'var(--border, #333)'}`,
        background: on ? '#f59e0b' : 'var(--card, #1a1a1a)',
        color: on ? '#1a1a1a' : 'var(--text, #ddd)',
        boxShadow: '0 2px 8px rgba(0,0,0,0.4)',
      }}
    >
      {on ? '● DEMO DATA' : '○ LIVE API'}
    </button>
  )
}
