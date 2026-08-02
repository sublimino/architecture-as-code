import { useLayoutEffect, useState } from 'react'
import {
  DEFAULT_THEME,
  THEME_LABELS,
  THEME_NAMES,
  applyTheme,
  isThemeName,
  readStoredTheme,
  storeTheme,
} from '../styles/themes'
import type { ThemeName } from '../styles/themes'

// Horizontal clearance for the DemoToggle, which is pinned at right: 16 and
// measures ~125px at its widest label ("● DEMO DATA"). 140 leaves the two
// corner widgets side by side without touching DemoToggle's own positioning.
const RIGHT_OFFSET = 140

// Corner widget that repaints the app palette. Purely client-side: it writes
// the selected theme's CSS custom properties onto <html> and remembers the
// choice in localStorage. No reload, no API call, no stored user preference.
export default function ThemeToggle() {
  const [theme, setTheme] = useState<ThemeName>(() => readStoredTheme())

  useLayoutEffect(() => {
    applyTheme(theme)
  }, [theme])

  function handleChange(event: React.ChangeEvent<HTMLSelectElement>) {
    const next = isThemeName(event.target.value) ? event.target.value : DEFAULT_THEME
    setTheme(next)
    storeTheme(next)
  }

  return (
    <select
      value={theme}
      onChange={handleChange}
      data-testid="theme-toggle"
      aria-label="Colour theme"
      title="Change the dashboard colour theme"
      style={{
        position: 'fixed',
        bottom: 16,
        right: RIGHT_OFFSET,
        zIndex: 4000,
        padding: '8px 12px',
        borderRadius: 8,
        cursor: 'pointer',
        fontSize: 12,
        fontWeight: 700,
        letterSpacing: 0.3,
        border: '1px solid var(--border-subtle, #333)',
        background: 'var(--surface2, #1a1a1a)',
        color: 'var(--text, #ddd)',
        boxShadow: '0 2px 8px rgba(0,0,0,0.4)',
      }}
    >
      {THEME_NAMES.map((name) => (
        <option key={name} value={name}>
          {THEME_LABELS[name]}
        </option>
      ))}
    </select>
  )
}
