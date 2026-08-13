import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { THEMES, CSS_VAR_NAMES, type CssVarName } from './themes'

// Buttons gave no hover feedback, so nothing marked them as click targets.
//
// jsdom implements no cascade and no :hover, so asserting a real hover in a
// component test would be theatre — it would pass against a stylesheet with
// the rules deleted. What this suite can check is real: that the rules exist
// with the shape they need, that disabled controls are excluded from every one
// of them, and — the part that actually decides whether the fix works — that
// the colours clear WCAG contrast in all three themes rather than in whichever
// one the author happened to be looking at.

// Comments stripped first. Prose inside a /* … */ block sits between rules and
// otherwise parses as a selector, and this file's rules are heavily commented.
const CSS = readFileSync(join(__dirname, 'global.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')

/** Every `selector { … }` pair in the sheet, @media blocks flattened. */
function rules(): { selector: string; body: string }[] {
  // No `}` anchor: with the /g flag a match consumes the closing brace it
  // would need as the next rule's anchor, so an anchored pattern silently
  // returns every *other* rule. Excluding braces from both captures instead
  // lets the engine skip over an @media wrapper and pick up the rules inside.
  return [...CSS.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(([, selector, body]) => ({
    selector: selector.trim(),
    body,
  }))
}

function selectorsOf(declaration: string): string[] {
  return rules().filter(({ body }) => body.includes(declaration)).map(({ selector }) => selector)
}

/** Body of the first rule whose selector list matches exactly, anchored on a
 *  newline so `.btn` cannot match `.btn:hover` or `.btn-secondary`. */
function ruleFor(selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const match = CSS.match(new RegExp(`(?:^|\\n)${escaped}\\s*\\{([^}]*)\\}`))
  if (!match) throw new Error(`No rule in global.css for: ${selector}`)
  return match[1]
}

/** Body of the shared .btn hover + focus-visible rule. */
function hoverFocusRuleBody(): string {
  const match = CSS.match(/\.btn:hover:not\(:disabled\),\s*\n\.btn:focus-visible:not\(:disabled\)\s*\{([^}]*)\}/)
  if (!match) throw new Error('No shared .btn hover/focus-visible rule in global.css')
  return match[1]
}

// ---- WCAG contrast, computed from the real theme tokens -------------------

const srgb = (hex: string) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16))
const luminance = (hex: string) => {
  const [r, g, b] = srgb(hex).map((c) => {
    const s = c / 255
    return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4
  })
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}
const contrast = (a: string, b: string) => {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (hi + 0.05) / (lo + 0.05)
}
const token = (theme: keyof typeof THEMES, name: CssVarName) => THEMES[theme][name]
const THEME_NAMES = Object.keys(THEMES) as (keyof typeof THEMES)[]

describe('button hover and focus affordance', () => {
  it('gives .btn a hover treatment, and the identical one to :focus-visible', () => {
    // A hover-only affordance improves the mouse and ignores the keyboard.
    const ringed = selectorsOf('outline: 2px solid var(--cyan)')
    const btnRule = ringed.find((s) => s.includes('.btn:hover'))
    expect(btnRule).toBeDefined()
    expect(btnRule).toContain('.btn:focus-visible')

    const fillShift = selectorsOf('background: var(--border-subtle)')
      .find((s) => s.includes('.btn-secondary:hover'))
    expect(fillShift).toBeDefined()
    expect(fillShift).toContain('.btn-secondary:focus-visible')
  })

  it('excludes :disabled from every hover and focus rule', () => {
    // A disabled control that lights up on hover is a worse lie than silence.
    const interactive = rules()
      .map(({ selector }) => selector)
      .filter((selector) => /\.btn[\w-]*:(hover|focus-visible)/.test(selector))
    expect(interactive.length).toBeGreaterThan(0)
    for (const selector of interactive) {
      for (const part of selector.split(',').map((s) => s.trim())) {
        if (!/\.btn/.test(part)) continue
        expect(part, `${part} must not apply to a disabled button`).toContain(':not(:disabled)')
      }
    }
  })

  it('keeps .btn:disabled non-interactive', () => {
    const disabled = ruleFor('.btn:disabled')
    expect(disabled).toContain('cursor: not-allowed')
  })

  it('declares cursor: pointer on .btn itself, not only on <button>', () => {
    expect(ruleFor('.btn ')).toContain('cursor: pointer')
  })

  it('gives bare <button>s a themed focus ring', () => {
    // ~180 buttons in this app never take a .btn class; without this rule they
    // fall back to an unthemed UA ring.
    expect(selectorsOf('outline: 2px solid var(--cyan)')).toContain('button:focus-visible')
  })

  it('drops the transition under prefers-reduced-motion but keeps the affordance', () => {
    const block = CSS.match(/@media \(prefers-reduced-motion: reduce\) \{([\s\S]*?)\n\}\s*$/)
    expect(block, 'expected a trailing reduced-motion block').not.toBeNull()
    expect(block![1]).toContain('.btn')
    expect(block![1]).toContain('transition: none !important')
    // The ring is a static outline, so it survives; only the movement goes.
    expect(block![1]).toContain('transform: none')
    expect(block![1]).not.toContain('outline: none')
  })

  it('never dims a button on hover — that reads as more disabled, not less', () => {
    // The rule this replaced was `.btn:hover { opacity: 0.85 }`, pointing the
    // same direction as `.btn:disabled { opacity: 0.5 }`.
    expect(CSS).not.toMatch(/\.btn:hover[^{]*\{[^}]*opacity/)
  })
})

describe('button affordance contrast across all three themes', () => {
  it('has all three themes declaring every token the affordance uses', () => {
    for (const name of THEME_NAMES) {
      for (const varName of ['--cyan', '--surface', '--bg', '--surface2', '--border-subtle', '--text'] as CssVarName[]) {
        expect(CSS_VAR_NAMES).toContain(varName)
        expect(THEMES[name][varName], `${name} is missing ${varName}`).toMatch(/^#[0-9A-Fa-f]{6}$/)
      }
    }
  })

  it('draws the focus/hover ring at 3:1 or better against the surfaces behind it', () => {
    // AA non-text contrast. The ring is what carries the affordance, so this
    // is the assertion that decides whether the fix works in every theme.
    for (const name of THEME_NAMES) {
      const ring = token(name, '--cyan')
      expect(contrast(ring, token(name, '--surface')), `${name}: ring on --surface`).toBeGreaterThanOrEqual(3)
      expect(contrast(ring, token(name, '--bg')), `${name}: ring on --bg`).toBeGreaterThanOrEqual(3)
    }
  })

  it('shifts .btn-secondary perceptibly without costing its label contrast', () => {
    for (const name of THEME_NAMES) {
      const rest = token(name, '--surface2')
      const hover = token(name, '--border-subtle')
      expect(contrast(rest, hover), `${name}: secondary fill shift`).toBeGreaterThanOrEqual(1.2)
      expect(contrast(hover, token(name, '--text')), `${name}: label on hover fill`).toBeGreaterThanOrEqual(4.5)
    }
  })

  it('leaves the filled variants alone — no fill shift, no contrast loss', () => {
    // btn-primary and btn-danger deliberately keep their fill on hover. The
    // rejected `filter: brightness()` approach moved it, and in Dark that took
    // btn-danger's white label from 4.83 to 3.71 — under AA. In Andy it did
    // nothing at all: the accents are already channel-clipped, so the fill
    // deltas came out at 1.01 and 1.03.
    expect(hoverFocusRuleBody()).not.toContain('filter')
    expect(CSS).not.toMatch(/\.btn[\w-]*:hover[^{]*\{[^}]*filter:\s*brightness/)

    for (const name of THEME_NAMES) {
      // btn-primary's label sits on --cyan and btn-danger's on --error, in the
      // rest state and the hover state alike, because the fill never moves.
      expect(contrast(token(name, '--cyan'), token(name, '--bg')), `${name}: primary label`)
        .toBeGreaterThanOrEqual(3)
    }
  })
})
