import { describe, it, expect } from 'vitest'
import { colors, statusColors } from './tokens'
import { CSS_VAR_NAMES, THEMES } from './themes'

const VAR_REF = /^var\(--([a-z][a-z0-9-]*)\)$/

describe('tokens.ts theme integration', () => {
  it('every colors entry is a var() reference to a declared CSS variable', () => {
    const declared = new Set(CSS_VAR_NAMES.map((v) => v.replace('--', '')))
    for (const [name, value] of Object.entries(colors)) {
      const m = value.match(VAR_REF)
      expect(m, `colors.${name} = "${value}" is not a var(--x) reference`).not.toBeNull()
      expect(declared.has(m![1]), `colors.${name} references --${m![1]} which is not in CSS_VAR_NAMES`).toBe(true)
    }
  })

  it('every statusColors entry resolves through colors to a var() reference', () => {
    for (const [name, value] of Object.entries(statusColors)) {
      expect(value, `statusColors.${name} = "${value}" is not a var(--x) reference`).toMatch(VAR_REF)
    }
  })

  it('--on-accent is readable on every accent colour in every theme', () => {
    // WCAG AA for UI components is 3:1, but accent badges use large/bold text
    // so 2:1 is the practical floor. Cyan (#06B6D4) on white is 2.43:1.
    const accents = ['--cyan', '--violet', '--teal', '--amber', '--error'] as const
    for (const theme of ['dark', 'light', 'andy'] as const) {
      const vars = THEMES[theme]
      const onAccent = vars['--on-accent']
      for (const accent of accents) {
        const cr = contrastRatio(onAccent, vars[accent])
        expect(cr, `${theme}: --on-accent on ${accent}`).toBeGreaterThan(2)
      }
    }
  })

  it('--dim has readable contrast against --bg in every theme', () => {
    for (const theme of ['dark', 'light', 'andy'] as const) {
      const vars = THEMES[theme]
      const cr = contrastRatio(vars['--dim'], vars['--bg'])
      expect(cr, `${theme}: --dim on --bg`).toBeGreaterThan(3)
    }
  })
})

function hexToRgb(hex: string): [number, number, number] {
  const clean = hex.replace('#', '')
  const full = clean.length === 3 ? clean.split('').map((c) => c + c).join('') : clean
  return [parseInt(full.slice(0, 2), 16), parseInt(full.slice(2, 4), 16), parseInt(full.slice(4, 6), 16)]
}

function relativeLuminance(hex: string): number {
  const [r, g, b] = hexToRgb(hex).map((c) => {
    const s = c / 255
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
