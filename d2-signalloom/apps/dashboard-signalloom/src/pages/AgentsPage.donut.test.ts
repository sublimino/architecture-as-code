import { describe, it, expect } from 'vitest'
import { DONUT_COLORS } from './AgentsPage'
import { colors } from '../styles/tokens'
import { THEMES } from '../styles/themes'

const VAR_REF = /^var\(--[a-z-]+\)$/

function hexToRgb(hex: string): [number, number, number] {
  const clean = hex.replace('#', '')
  return [
    parseInt(clean.slice(0, 2), 16),
    parseInt(clean.slice(2, 4), 16),
    parseInt(clean.slice(4, 6), 16),
  ]
}

function relativeLuminance(hex: string): number {
  const [r, g, b] = hexToRgb(hex).map((channel) => {
    const s = channel / 255
    return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4)
  })
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

function contrastRatio(a: string, b: string): number {
  const la = relativeLuminance(a)
  const lb = relativeLuminance(b)
  const [hi, lo] = la > lb ? [la, lb] : [lb, la]
  return (hi + 0.05) / (lo + 0.05)
}

describe('lifecycle donut colour sourcing', () => {
  it('takes every colour from a theme variable, not a tokens.ts literal', () => {
    for (const [key, value] of Object.entries(DONUT_COLORS)) {
      expect(value, `${key} must be a theme variable`).toMatch(VAR_REF)
    }
  })

  // The reported defect: the centre count was fill="#F8FAFC" (electricWhite),
  // so under a white background it rendered white-on-white.
  it('drives the centre count from --text so it inverts with the theme', () => {
    expect(DONUT_COLORS.centreLabel).toBe('var(--text)')
    expect(DONUT_COLORS.caption).toBe('var(--muted)')
  })

  it('gives the centre count readable contrast in all three themes', () => {
    for (const theme of ['dark', 'light', 'andy'] as const) {
      const vars = THEMES[theme]
      expect(
        contrastRatio(vars['--text'], vars['--bg']),
        `${theme}: centre count on background`,
      ).toBeGreaterThan(4.5)
      expect(
        contrastRatio(vars['--muted'], vars['--bg']),
        `${theme}: caption on background`,
      ).toBeGreaterThan(3)
    }
  })
})

describe('Dark theme is unchanged by the donut indirection', () => {
  it('maps each replaced literal onto an identical Dark variable value', () => {
    expect(THEMES.dark['--teal']).toBe(colors.tealLoom)
    expect(THEMES.dark['--cyan']).toBe(colors.cyanLoom)
    expect(THEMES.dark['--amber']).toBe(colors.amber)
    expect(THEMES.dark['--error']).toBe(colors.red)
    // The centre count was electricWhite and the caption was muted.
    expect(THEMES.dark['--text']).toBe(colors.electricWhite)
    expect(THEMES.dark['--muted']).toBe(colors.muted)
    // The empty-state ring literal.
    expect(THEMES.dark['--border-subtle']).toBe('#334155')
  })
})

describe('Andy theme donut', () => {
  it('no longer inherits the dark palette teal/cyan/amber', () => {
    // Same variables, different values — the donut repaints with the theme.
    expect(THEMES.andy['--teal']).not.toBe(colors.tealLoom)
    expect(THEMES.andy['--cyan']).not.toBe(colors.cyanLoom)
    expect(THEMES.andy['--amber']).not.toBe(colors.amber)
  })
})
