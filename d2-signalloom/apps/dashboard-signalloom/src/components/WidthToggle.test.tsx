import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import WidthToggle, { WIDTH_TOGGLE_RIGHT_OFFSET } from './WidthToggle'
import {
  LAYOUT_WIDTH_STORAGE_KEY,
  LAYOUT_WIDTH_NAMES,
  LAYOUT_WIDTH_LABELS,
} from '../styles/layoutWidth'

function toggle(): HTMLSelectElement {
  return screen.getByTestId('width-toggle') as HTMLSelectElement
}

function rootVar(name: string): string {
  return document.documentElement.style.getPropertyValue(name)
}

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

let localStorageMock: Storage

beforeEach(() => {
  localStorageMock = installLocalStorage()
  document.documentElement.removeAttribute('data-layout-width')
  document.documentElement.removeAttribute('style')
})

afterEach(() => {
  cleanup()
})

describe('WidthToggle component', () => {
  it('renders exactly three options matching LAYOUT_WIDTH_NAMES', () => {
    render(<WidthToggle />)
    const select = toggle()
    const options = Array.from(select.querySelectorAll('option'))
    expect(options.map((o) => o.value)).toEqual(LAYOUT_WIDTH_NAMES)
    expect(options.map((o) => o.textContent?.trim())).toEqual(
      LAYOUT_WIDTH_NAMES.map((name) => LAYOUT_WIDTH_LABELS[name])
    )
  })

  it('selects Standard (1600px) by default and sets --content-max-width to 1600px', () => {
    render(<WidthToggle />)
    expect(toggle().value).toBe('standard')
    expect(rootVar('--content-max-width')).toBe('1600px')
    expect(document.documentElement.getAttribute('data-layout-width')).toBe('standard')
  })

  it('applies 100% max-width and updates storage when Full Width is selected', () => {
    render(<WidthToggle />)
    fireEvent.change(toggle(), { target: { value: 'full' } })

    expect(toggle().value).toBe('full')
    expect(rootVar('--content-max-width')).toBe('100%')
    expect(document.documentElement.getAttribute('data-layout-width')).toBe('full')
    expect(localStorageMock.getItem(LAYOUT_WIDTH_STORAGE_KEY)).toBe('full')
  })

  it('applies 1172px max-width when Compact is selected', () => {
    render(<WidthToggle />)
    fireEvent.change(toggle(), { target: { value: 'compact' } })

    expect(toggle().value).toBe('compact')
    expect(rootVar('--content-max-width')).toBe('1172px')
    expect(document.documentElement.getAttribute('data-layout-width')).toBe('compact')
    expect(localStorageMock.getItem(LAYOUT_WIDTH_STORAGE_KEY)).toBe('compact')
  })

  it('restores stored layout width preference from localStorage on mount', () => {
    localStorageMock.setItem(LAYOUT_WIDTH_STORAGE_KEY, 'full')
    render(<WidthToggle />)

    expect(toggle().value).toBe('full')
    expect(rootVar('--content-max-width')).toBe('100%')
  })

  it('falls back to standard when stored value is corrupted', () => {
    localStorageMock.setItem(LAYOUT_WIDTH_STORAGE_KEY, 'invalid-width-mode')
    render(<WidthToggle />)

    expect(toggle().value).toBe('standard')
    expect(rootVar('--content-max-width')).toBe('1600px')
  })

  it('positions itself with appropriate right clearance to avoid colliding with ThemeToggle', () => {
    render(<WidthToggle />)
    const select = toggle()
    expect(WIDTH_TOGGLE_RIGHT_OFFSET).toBe(250)
    expect(select.style.position).toBe('fixed')
    expect(select.style.bottom).toBe('16px')
    expect(select.style.right).toBe('250px')
    expect(select.style.zIndex).toBe('4000')
  })

  it('includes proper accessible attributes', () => {
    render(<WidthToggle />)
    const select = toggle()
    expect(select.getAttribute('aria-label')).toBe('Layout width')
    expect(select.getAttribute('title')).toBe('Change the dashboard content width')
  })
})
