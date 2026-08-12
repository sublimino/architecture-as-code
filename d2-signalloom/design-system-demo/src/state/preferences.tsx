import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'

export type Theme = 'dark' | 'light'

const THEME_KEY = 'signalloom.design-demo.theme'
const SUPERADMIN_KEY = 'signalloom.superadmin'

function safeRead(key: string): string | null {
  try {
    return window.localStorage.getItem(key)
  } catch {
    return null
  }
}

function safeWrite(key: string, value: string): void {
  try {
    window.localStorage.setItem(key, value)
  } catch {
    // In-memory state remains authoritative when browser storage is blocked.
  }
}

export function readTheme(): Theme {
  return safeRead(THEME_KEY) === 'light' ? 'light' : 'dark'
}

export function readSuperadmin(): boolean {
  return safeRead(SUPERADMIN_KEY) === 'true'
}

type PreferencesValue = {
  theme: Theme
  setTheme: (theme: Theme) => void
  superadmin: boolean
  setSuperadmin: (enabled: boolean) => void
}

const PreferencesContext = createContext<PreferencesValue | null>(null)

export function PreferencesProvider({ children }: { children: React.ReactNode }) {
  const [theme, setThemeState] = useState<Theme>(readTheme)
  const [superadmin, setSuperadminState] = useState(readSuperadmin)

  useEffect(() => {
    document.documentElement.dataset.theme = theme
    document.documentElement.style.colorScheme = theme
  }, [theme])

  const setTheme = useCallback((next: Theme) => {
    setThemeState(next)
    safeWrite(THEME_KEY, next)
  }, [])

  const setSuperadmin = useCallback((enabled: boolean) => {
    setSuperadminState(enabled)
    safeWrite(SUPERADMIN_KEY, String(enabled))
  }, [])

  const value = useMemo(
    () => ({ theme, setTheme, superadmin, setSuperadmin }),
    [theme, setTheme, superadmin, setSuperadmin],
  )

  return <PreferencesContext.Provider value={value}>{children}</PreferencesContext.Provider>
}

export function usePreferences(): PreferencesValue {
  const value = useContext(PreferencesContext)
  if (!value) throw new Error('usePreferences must be used inside PreferencesProvider')
  return value
}

export const preferenceKeys = { theme: THEME_KEY, superadmin: SUPERADMIN_KEY }
