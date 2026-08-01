// Single source of truth for every selectable colour theme.
//
// Adding a fourth theme means editing this file only: extend the ThemeName
// union, add its label to THEME_LABELS, add its full variable map to THEMES.
// Every theme supplies a value for all of the CSS custom properties declared
// in global.css's :root block — no theme is allowed to fall back to another's
// values — so a future theme can restyle the whole sheet, not just an accent.

export const CSS_VAR_NAMES = [
  '--bg',
  '--surface',
  '--surface2',
  '--border',
  '--border-subtle',
  '--cyan',
  '--violet',
  '--teal',
  '--amber',
  '--error',
  '--text',
  '--muted',
  '--slate-gray',
  '--warning',
] as const

export type CssVarName = (typeof CSS_VAR_NAMES)[number]

export type ThemeName = 'dark' | 'light' | 'andy'

/** Selection order in the dropdown. */
export const THEME_NAMES: readonly ThemeName[] = ['dark', 'light', 'andy']

export const THEME_LABELS: Record<ThemeName, string> = {
  dark: 'Dark',
  light: 'Light',
  andy: 'Andy',
}

export const DEFAULT_THEME: ThemeName = 'dark'

export const THEME_STORAGE_KEY = 'signalloom.theme'

export const THEMES: Record<ThemeName, Record<CssVarName, string>> = {
  // Byte-for-byte the palette shipped in global.css's :root block. Changing a
  // value here without changing global.css (or vice versa) fails themes.test.ts.
  dark: {
    '--bg': '#020617',
    '--surface': '#0F172A',
    '--surface2': '#1E293B',
    '--border': '#1E293B',
    '--border-subtle': '#334155',
    '--cyan': '#06B6D4',
    '--violet': '#8B5CF6',
    '--teal': '#10B981',
    '--amber': '#D97706',
    '--error': '#DC2626',
    '--text': '#F8FAFC',
    '--muted': '#94A3B8',
    '--slate-gray': '#475569',
    '--warning': '#D97706',
  },
  // Near-white surfaces with darkened accents so links, tags and chart series
  // stay legible against white.
  light: {
    '--bg': '#FFFFFF',
    '--surface': '#F8FAFC',
    '--surface2': '#F1F5F9',
    '--border': '#D9E2EC',
    '--border-subtle': '#B6C2CF',
    '--cyan': '#0E7490',
    '--violet': '#6D28D9',
    '--teal': '#047857',
    '--amber': '#B45309',
    '--error': '#B91C1C',
    '--text': '#0F172A',
    '--muted': '#475569',
    '--slate-gray': '#64748B',
    '--warning': '#B45309',
  },
  // Red on black. Red takes over cyan's primary-accent role; the remaining
  // accents stay inside the warm band so the palette reads as one family.
  andy: {
    '--bg': '#000000',
    '--surface': '#0A0A0A',
    '--surface2': '#161010',
    '--border': '#2B0F0F',
    '--border-subtle': '#5A1A1A',
    '--cyan': '#E10600',
    '--violet': '#FF4D6D',
    '--teal': '#FF7A7A',
    '--amber': '#C2410C',
    '--error': '#FF1E1E',
    '--text': '#F5F5F5',
    '--muted': '#B09292',
    '--slate-gray': '#6B5252',
    '--warning': '#C2410C',
  },
}

export function isThemeName(value: unknown): value is ThemeName {
  return typeof value === 'string' && (THEME_NAMES as readonly string[]).includes(value)
}

/**
 * Paint a theme onto the document root: a `data-theme` hook for CSS selectors
 * plus the variable values as inline custom properties, which outrank the
 * :root block in global.css. Purely local — no reload, no network.
 */
export function applyTheme(name: ThemeName): void {
  const root = document.documentElement
  const vars = THEMES[name]
  root.setAttribute('data-theme', name)
  for (const key of CSS_VAR_NAMES) {
    root.style.setProperty(key, vars[key])
  }
}

export function readStoredTheme(): ThemeName {
  try {
    const stored = window.localStorage.getItem(THEME_STORAGE_KEY)
    return isThemeName(stored) ? stored : DEFAULT_THEME
  } catch {
    // Storage blocked (private mode / disabled cookies) — fall back to default.
    return DEFAULT_THEME
  }
}

export function storeTheme(name: ThemeName): void {
  try {
    window.localStorage.setItem(THEME_STORAGE_KEY, name)
  } catch {
    // Storage blocked — the selection stays session-only.
  }
}
