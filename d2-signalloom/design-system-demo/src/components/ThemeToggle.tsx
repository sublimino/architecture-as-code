import { Moon, Sun } from 'lucide-react'
import { usePreferences } from '../state/preferences'

export function ThemeToggle() {
  const { theme, setTheme } = usePreferences()
  const light = theme === 'light'
  return (
    <button
      type="button"
      className="theme-toggle"
      aria-label={`Switch to ${light ? 'dark' : 'light'} theme`}
      aria-pressed={light}
      onClick={() => setTheme(light ? 'dark' : 'light')}
      data-testid="theme-toggle"
      title={`Current theme: ${theme}`}
    >
      {light ? <Sun size={16} aria-hidden="true" /> : <Moon size={16} aria-hidden="true" />}
      <span>{light ? 'Light' : 'Dark'}</span>
    </button>
  )
}
