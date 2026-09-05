// Single source of truth for dashboard container layout width options.
//
// Allows the user to toggle between:
// - standard: bounded 1600px ceiling (comfortable reading line-length + spacious tables)
// - full: unconstrained 100% width (utilizes entire desktop / ultrawide viewport)
// - compact: legacy 1172px width (for focused, narrow viewing)
//
// Preferences are client-side only and persisted in localStorage under 'signalloom.layout_width'.

export type LayoutWidth = 'standard' | 'full' | 'compact'

export const LAYOUT_WIDTH_NAMES: readonly LayoutWidth[] = ['standard', 'full', 'compact']

export const LAYOUT_WIDTH_LABELS: Record<LayoutWidth, string> = {
  standard: 'Standard (1600px)',
  full: 'Full Width',
  compact: 'Compact (1172px)',
}

export const LAYOUT_WIDTH_VALUES: Record<LayoutWidth, string> = {
  standard: '1600px',
  full: '100%',
  compact: '1172px',
}

export const DEFAULT_LAYOUT_WIDTH: LayoutWidth = 'standard'

export const LAYOUT_WIDTH_STORAGE_KEY = 'signalloom.layout_width'

export function isLayoutWidth(val: unknown): val is LayoutWidth {
  return val === 'standard' || val === 'full' || val === 'compact'
}

export function readStoredLayoutWidth(): LayoutWidth {
  try {
    const stored = typeof localStorage !== 'undefined' ? localStorage.getItem(LAYOUT_WIDTH_STORAGE_KEY) : null
    return isLayoutWidth(stored) ? stored : DEFAULT_LAYOUT_WIDTH
  } catch {
    return DEFAULT_LAYOUT_WIDTH
  }
}

export function storeLayoutWidth(width: LayoutWidth): void {
  try {
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(LAYOUT_WIDTH_STORAGE_KEY, width)
    }
  } catch {
    // Storage may be unavailable in sandboxed environments or private browsing
  }
}

export function applyLayoutWidth(width: LayoutWidth): void {
  const value = LAYOUT_WIDTH_VALUES[width] ?? LAYOUT_WIDTH_VALUES[DEFAULT_LAYOUT_WIDTH]
  if (typeof document !== 'undefined' && document.documentElement) {
    document.documentElement.style.setProperty('--content-max-width', value)
    document.documentElement.setAttribute('data-layout-width', width)
  }
}
