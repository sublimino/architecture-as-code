import { describe, it, expect, beforeEach } from 'vitest'
import {
  DEFAULT_LAYOUT_WIDTH,
  LAYOUT_WIDTH_LABELS,
  LAYOUT_WIDTH_NAMES,
  LAYOUT_WIDTH_STORAGE_KEY,
  LAYOUT_WIDTH_VALUES,
  applyLayoutWidth,
  isLayoutWidth,
  readStoredLayoutWidth,
  storeLayoutWidth,
} from './layoutWidth'

// Test-isolated in-memory storage mock
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

describe('layoutWidth configuration and helpers', () => {
  beforeEach(() => {
    installLocalStorage()
    document.documentElement.removeAttribute('data-layout-width')
    document.documentElement.removeAttribute('style')
  })

  it('declares standard, full, and compact as valid layout widths', () => {
    expect(LAYOUT_WIDTH_NAMES).toEqual(['standard', 'full', 'compact'])
    expect(DEFAULT_LAYOUT_WIDTH).toBe('standard')
  })

  it('maps widths to expected CSS max-width values', () => {
    expect(LAYOUT_WIDTH_VALUES.standard).toBe('1600px')
    expect(LAYOUT_WIDTH_VALUES.full).toBe('100%')
    expect(LAYOUT_WIDTH_VALUES.compact).toBe('1172px')
  })

  it('maps widths to descriptive user labels', () => {
    expect(LAYOUT_WIDTH_LABELS.standard).toContain('1600px')
    expect(LAYOUT_WIDTH_LABELS.full).toContain('Full Width')
    expect(LAYOUT_WIDTH_LABELS.compact).toContain('1172px')
  })

  it('identifies valid layout width values via isLayoutWidth', () => {
    expect(isLayoutWidth('standard')).toBe(true)
    expect(isLayoutWidth('full')).toBe(true)
    expect(isLayoutWidth('compact')).toBe(true)
    expect(isLayoutWidth('ultrawide')).toBe(false)
    expect(isLayoutWidth(null)).toBe(false)
    expect(isLayoutWidth(undefined)).toBe(false)
    expect(isLayoutWidth(1600)).toBe(false)
  })

  it('reads stored layout width from localStorage and falls back to default', () => {
    expect(readStoredLayoutWidth()).toBe('standard')

    localStorage.setItem(LAYOUT_WIDTH_STORAGE_KEY, 'full')
    expect(readStoredLayoutWidth()).toBe('full')

    localStorage.setItem(LAYOUT_WIDTH_STORAGE_KEY, 'compact')
    expect(readStoredLayoutWidth()).toBe('compact')

    localStorage.setItem(LAYOUT_WIDTH_STORAGE_KEY, 'unknown_value')
    expect(readStoredLayoutWidth()).toBe('standard')
  })

  it('persists layout width to localStorage', () => {
    storeLayoutWidth('full')
    expect(localStorage.getItem(LAYOUT_WIDTH_STORAGE_KEY)).toBe('full')

    storeLayoutWidth('standard')
    expect(localStorage.getItem(LAYOUT_WIDTH_STORAGE_KEY)).toBe('standard')
  })

  it('applies layout width custom property and data attribute to documentElement', () => {
    applyLayoutWidth('standard')
    expect(document.documentElement.style.getPropertyValue('--content-max-width')).toBe('1600px')
    expect(document.documentElement.getAttribute('data-layout-width')).toBe('standard')

    applyLayoutWidth('full')
    expect(document.documentElement.style.getPropertyValue('--content-max-width')).toBe('100%')
    expect(document.documentElement.getAttribute('data-layout-width')).toBe('full')

    applyLayoutWidth('compact')
    expect(document.documentElement.style.getPropertyValue('--content-max-width')).toBe('1172px')
    expect(document.documentElement.getAttribute('data-layout-width')).toBe('compact')
  })
})
