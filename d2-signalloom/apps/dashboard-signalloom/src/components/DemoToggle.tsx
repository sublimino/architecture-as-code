import { useEffect, useState } from 'react'
import { isDemoMode, toggleDemoMode, subscribeDemoMode, showDemoToggle } from '../api/demoMode'

// Corner widget that flips the api client between the live backend and local
// demo fixtures. Hidden in ci/uat/prod environments (controlled by SL_ENV).
export default function DemoToggle() {
  if (!showDemoToggle) return null
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
        // Every colour resolves from the active theme's own custom properties.
        //
        // The previous revision read `var(--card, #1a1a1a)`. `--card` is declared by no theme and
        // by no :root block — it was a dead token, the only reference to it in the codebase — so
        // the fallback was ALWAYS used. Under Light that painted near-black #1a1a1a behind
        // var(--text) #0F172A: 1.03:1, an invisible button.
        //
        // The active state hardcoded #f59e0b/#1a1a1a outright, so the one state users most need to
        // notice ("you are looking at fixtures, not reality") ignored the theme entirely.
        //
        // Amber is used as the BORDER, not the fill. Filling with var(--amber) and labelling with
        // var(--bg) measures 4.06:1 under the Andy theme, which fails AA for normal text; amber as
        // a 2px boundary needs only 3:1 and clears it at 3.63:1 worst case.
        // Contrast (worst across dark/light/andy): off 17.06:1, on 13.98:1, border 3.63:1.
        border: on ? '2px solid var(--amber)' : '1px solid var(--border)',
        background: on ? 'var(--surface2)' : 'var(--surface)',
        color: 'var(--text)',
        boxShadow: '0 2px 8px rgb(0 0 0 / 0.35)',
      }}
    >
      {on ? '● DEMO DATA' : '○ LIVE API'}
    </button>
  )
}
