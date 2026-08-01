import { describe, it, expect, beforeEach } from 'vitest'
import {
  CSS_VAR_NAMES,
  DEFAULT_THEME,
  THEME_LABELS,
  THEME_NAMES,
  THEME_STORAGE_KEY,
  THEMES,
  applyTheme,
  isThemeName,
  readStoredTheme,
  storeTheme,
} from './themes'
import type { CssVarName } from './themes'

// Literal copy of the :root block in src/styles/global.css. This is the
// regression guard: if the Dark theme ever drifts from the shipped palette,
// this fails. Update both together, never one alone.
const GLOBAL_CSS_ROOT: Record<CssVarName, string> = {
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
}

function hexToRgb(hex: string): [number, number, number] {
  const clean = hex.trim().replace('#', '')
  const full = clean.length === 3 ? clean.split('').map((c) => c + c).join('') : clean
  return [
    parseInt(full.slice(0, 2), 16),
    parseInt(full.slice(2, 4), 16),
    parseInt(full.slice(4, 6), 16),
  ]
}

// WCAG relative luminance, 0 (black) to 1 (white).
function relativeLuminance(hex: string): number {
  const [r, g, b] = hexToRgb(hex).map((channel) => {
    const s = channel / 255
    return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4)
  })
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

// Hue in degrees, 0-360.
function hue(hex: string): number {
  const [r, g, b] = hexToRgb(hex).map((c) => c / 255)
  const max = Math.max(r, g, b)
  const min = Math.min(r, g, b)
  const delta = max - min
  if (delta === 0) return 0
  let h: number
  if (max === r) h = ((g - b) / delta) % 6
  else if (max === g) h = (b - r) / delta + 2
  else h = (r - g) / delta + 4
  h *= 60
  return h < 0 ? h + 360 : h
}

// Red band wraps zero.
function isRedFamily(hex: string): boolean {
  const h = hue(hex)
  return h <= 20 || h >= 340
}

// This runner's `localStorage` global is a methodless stub (Node's built-in Web
// Storage shadows jsdom's implementation), so each test gets a real in-memory
// one. Scoped to this file — the shared test-setup is left alone.
function installLocalStorage(): Storage {
  const store = new Map<string, string>()
  const mock: Storage = {
    getItem: (key) => (store.has(key) ? (store.get(key) as string) : null),
    setItem: (key, value) => void store.set(key, String(value)),
    removeItem: (key) => void store.delete(key),
    clear: () => store.clear(),
    key: (index) => Array.from(store.keys())[index] ?? null,
    get length() {
      return store.size
    },
  }
  Object.defineProperty(window, 'localStorage', { value: mock, configurable: true, writable: true })
  return mock
}

let localStorage: Storage

beforeEach(() => {
  localStorage = installLocalStorage()
  document.documentElement.removeAttribute('data-theme')
  document.documentElement.removeAttribute('style')
})

describe('themes data structure', () => {
  it('exposes exactly three themes in Dark, Light, Andy order', () => {
    expect(THEME_NAMES).toEqual(['dark', 'light', 'andy'])
    expect(THEME_NAMES.map((n) => THEME_LABELS[n])).toEqual(['Dark', 'Light', 'Andy'])
  })

  it('defaults to Dark', () => {
    expect(DEFAULT_THEME).toBe('dark')
  })

  it('reproduces the shipped global.css :root palette in the Dark theme', () => {
    expect(THEMES.dark).toEqual(GLOBAL_CSS_ROOT)
  })

  it('declares all fourteen variables in every theme', () => {
    expect(CSS_VAR_NAMES).toHaveLength(14)
    for (const name of THEME_NAMES) {
      const vars = THEMES[name]
      expect(Object.keys(vars).sort()).toEqual([...CSS_VAR_NAMES].sort())
      for (const key of CSS_VAR_NAMES) {
        expect(vars[key], `${name} is missing ${key}`).toMatch(/^#[0-9A-Fa-f]{6}$/)
      }
    }
  })

  it('gives Light a near-white background and dark text', () => {
    expect(relativeLuminance(THEMES.light['--bg'])).toBeGreaterThan(0.9)
    expect(relativeLuminance(THEMES.light['--text'])).toBeLessThan(0.1)
    // Borders must remain visible against the near-white background.
    expect(relativeLuminance(THEMES.light['--border'])).toBeLessThan(0.85)
    expect(relativeLuminance(THEMES.light['--border-subtle'])).toBeLessThan(0.7)
  })

  it('gives Andy black backgrounds, a red primary accent and light text', () => {
    expect(relativeLuminance(THEMES.andy['--bg'])).toBeLessThan(0.05)
    expect(relativeLuminance(THEMES.andy['--surface'])).toBeLessThan(0.1)
    expect(isRedFamily(THEMES.andy['--cyan'])).toBe(true)
    expect(isRedFamily(THEMES.andy['--error'])).toBe(true)
    expect(relativeLuminance(THEMES.andy['--text'])).toBeGreaterThan(0.8)
  })
})

describe('applyTheme', () => {
  it('sets data-theme and every variable on the root element', () => {
    applyTheme('light')
    const root = document.documentElement
    expect(root.getAttribute('data-theme')).toBe('light')
    for (const key of CSS_VAR_NAMES) {
      expect(root.style.getPropertyValue(key)).toBe(THEMES.light[key])
    }
  })

  it('fully replaces the previous theme when switching', () => {
    applyTheme('andy')
    expect(document.documentElement.style.getPropertyValue('--bg')).toBe(THEMES.andy['--bg'])
    applyTheme('dark')
    expect(document.documentElement.getAttribute('data-theme')).toBe('dark')
    expect(document.documentElement.style.getPropertyValue('--bg')).toBe(THEMES.dark['--bg'])
  })
})

describe('persistence helpers', () => {
  it('round-trips a selection through localStorage under a namespaced key', () => {
    storeTheme('andy')
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('andy')
    expect(THEME_STORAGE_KEY).toBe('signalloom.theme')
    expect(readStoredTheme()).toBe('andy')
  })

  it('falls back to Dark when nothing is stored', () => {
    expect(readStoredTheme()).toBe('dark')
  })

  it('falls back to Dark when the stored value is unknown', () => {
    localStorage.setItem(THEME_STORAGE_KEY, 'solarized')
    expect(readStoredTheme()).toBe('dark')
  })

  it('narrows unknown values with isThemeName', () => {
    expect(isThemeName('dark')).toBe(true)
    expect(isThemeName('andy')).toBe(true)
    expect(isThemeName('nope')).toBe(false)
    expect(isThemeName(null)).toBe(false)
    expect(isThemeName(7)).toBe(false)
  })
})
