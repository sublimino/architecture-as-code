import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import ThemeToggle from './ThemeToggle'
import { CSS_VAR_NAMES, THEMES, THEME_STORAGE_KEY } from '../styles/themes'

function hexToRgb(hex: string): [number, number, number] {
  const clean = hex.trim().replace('#', '')
  return [
    parseInt(clean.slice(0, 2), 16),
    parseInt(clean.slice(2, 4), 16),
    parseInt(clean.slice(4, 6), 16),
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

function toggle(): HTMLSelectElement {
  return screen.getByTestId('theme-toggle') as HTMLSelectElement
}

function rootVar(name: string): string {
  return document.documentElement.style.getPropertyValue(name)
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

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('ThemeToggle', () => {
  it('renders exactly three options in Dark, Light, Andy order', () => {
    render(<ThemeToggle />)
    const options = Array.from(toggle().options)
    expect(options.map((o) => o.textContent)).toEqual(['Dark', 'Light', 'Andy'])
    expect(options.map((o) => o.value)).toEqual(['dark', 'light', 'andy'])
  })

  it('selects Dark by default and applies the shipped palette', () => {
    render(<ThemeToggle />)
    expect(toggle().value).toBe('dark')
    expect(document.documentElement.getAttribute('data-theme')).toBe('dark')
    for (const key of CSS_VAR_NAMES) {
      expect(rootVar(key)).toBe(THEMES.dark[key])
    }
  })

  it('applies a near-white background when Light is selected', () => {
    render(<ThemeToggle />)
    fireEvent.change(toggle(), { target: { value: 'light' } })
    expect(document.documentElement.getAttribute('data-theme')).toBe('light')
    expect(relativeLuminance(rootVar('--bg'))).toBeGreaterThan(0.9)
    expect(relativeLuminance(rootVar('--text'))).toBeLessThan(0.1)
  })

  it('applies a dark background and a Signal Loom accent when Andy is selected', () => {
    render(<ThemeToggle />)
    fireEvent.change(toggle(), { target: { value: 'andy' } })
    expect(document.documentElement.getAttribute('data-theme')).toBe('andy')
    expect(relativeLuminance(rootVar('--bg'))).toBeLessThan(0.05)
    // Was `accentHue <= 20 || accentHue >= 340` — the red band — when Andy was
    // a red-on-black theme. Andy is now built on the Signal Loom brand ramp
    // (violet -> periwinkle -> teal, sampled from the logo), so the band moves
    // with it. Still a hue assertion on the painted --cyan: the point of this
    // test is that applyTheme really wrote Andy's accent onto the root, and a
    // check that pinned nothing would not show that.
    const accentHue = hue(rootVar('--cyan'))
    expect(accentHue >= 150 && accentHue <= 275).toBe(true)
  })

  it('switches without reloading or remounting the control', () => {
    render(<ThemeToggle />)
    const before = toggle()
    // jsdom's Location methods cannot be spied on individually, so swap the
    // whole object for the duration of the assertion.
    const realLocation = window.location
    const reload = vi.fn()
    const assign = vi.fn()
    Object.defineProperty(window, 'location', {
      value: { href: realLocation.href, reload, assign, replace: vi.fn() },
      configurable: true,
      writable: true,
    })
    try {
      fireEvent.change(before, { target: { value: 'light' } })
      expect(reload).not.toHaveBeenCalled()
      expect(assign).not.toHaveBeenCalled()
    } finally {
      Object.defineProperty(window, 'location', {
        value: realLocation,
        configurable: true,
        writable: true,
      })
    }
    // Same DOM node — the switch is a live style update, not a page reload.
    expect(toggle()).toBe(before)
    expect(document.documentElement.getAttribute('data-theme')).toBe('light')
  })

  it('makes no network call when the theme changes', () => {
    const fetchSpy = vi.fn()
    vi.stubGlobal('fetch', fetchSpy)
    const xhrOpen = vi.spyOn(XMLHttpRequest.prototype, 'open')
    const xhrSend = vi.spyOn(XMLHttpRequest.prototype, 'send')
    render(<ThemeToggle />)
    fireEvent.change(toggle(), { target: { value: 'andy' } })
    fireEvent.change(toggle(), { target: { value: 'light' } })
    expect(fetchSpy).not.toHaveBeenCalled()
    expect(xhrOpen).not.toHaveBeenCalled()
    expect(xhrSend).not.toHaveBeenCalled()
    vi.unstubAllGlobals()
  })

  it('persists the selection across a remount', () => {
    render(<ThemeToggle />)
    fireEvent.change(toggle(), { target: { value: 'andy' } })
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('andy')
    cleanup()
    document.documentElement.removeAttribute('data-theme')
    document.documentElement.removeAttribute('style')

    render(<ThemeToggle />)
    expect(toggle().value).toBe('andy')
    expect(document.documentElement.getAttribute('data-theme')).toBe('andy')
    expect(rootVar('--bg')).toBe(THEMES.andy['--bg'])
  })

  it('falls back to Dark when the stored value is unknown', () => {
    localStorage.setItem(THEME_STORAGE_KEY, 'solarized')
    render(<ThemeToggle />)
    expect(toggle().value).toBe('dark')
    expect(document.documentElement.getAttribute('data-theme')).toBe('dark')
  })

  it('sits clear of the demo toggle in the bottom-right corner', () => {
    render(<ThemeToggle />)
    const style = toggle().style
    expect(style.position).toBe('fixed')
    expect(style.bottom).toBe('16px')
    // DemoToggle owns right: 16 and is ~125px wide; this must clear it.
    expect(parseInt(style.right, 10)).toBeGreaterThanOrEqual(136)
  })
})
