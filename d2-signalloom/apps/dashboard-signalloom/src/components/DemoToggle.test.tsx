import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import DemoToggle from './DemoToggle'
import { setDemoMode } from '../api/demoMode'

// The bug this whole file guards against: DemoToggle used to read
// `var(--card, #1a1a1a)` for its background. `--card` is declared nowhere —
// not by any theme, not by global.css's :root block — so the fallback always
// won, and under the Light theme that painted var(--text) #0F172A on
// #1a1a1a: 1.03:1, an invisible button. The active ("DEMO DATA") state
// hardcoded #f59e0b/#1a1a1a outright, so the state users most need to notice
// ignored the theme entirely too. Both are now theme tokens (see the comment
// block inside DemoToggle.tsx) — these tests pin that down structurally, and
// src/styles/cssVarUsage.test.ts pins it down repo-wide.

function toggleButton(): HTMLButtonElement {
  return screen.getByTestId('demo-toggle') as HTMLButtonElement
}

// Matches any bare hex colour literal (#fff, #1a1a1a, ...) — used to prove a
// style value is a token reference, not a hardcoded fallback colour "winning"
// silently the way `--card`'s did.
const HEX_COLOUR = /#[0-9a-fA-F]{3,8}\b/

beforeEach(() => setDemoMode(false))

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('DemoToggle', () => {
  it('renders the LIVE API state entirely from theme tokens, no hardcoded colours', () => {
    render(<DemoToggle />)
    const btn = toggleButton()
    expect(btn.textContent).toBe('○ LIVE API')
    expect(btn.style.background).toBe('var(--surface)')
    expect(btn.style.color).toBe('var(--text)')
    expect(btn.style.border).toBe('1px solid var(--border)')
    for (const prop of ['background', 'color', 'border'] as const) {
      expect(btn.style[prop]).not.toMatch(HEX_COLOUR)
    }
  })

  it('renders the DEMO DATA state entirely from theme tokens, no hardcoded colours', () => {
    setDemoMode(true)
    render(<DemoToggle />)
    const btn = toggleButton()
    expect(btn.textContent).toBe('● DEMO DATA')
    expect(btn.style.background).toBe('var(--surface2)')
    expect(btn.style.color).toBe('var(--text)')
    expect(btn.style.border).toBe('2px solid var(--amber)')
    for (const prop of ['background', 'color', 'border'] as const) {
      expect(btn.style[prop]).not.toMatch(HEX_COLOUR)
    }
  })

  it('reflects state in the title tooltip for both Live and Demo', () => {
    const { unmount } = render(<DemoToggle />)
    expect(toggleButton().title).toMatch(/render with demo data/i)
    unmount()

    setDemoMode(true)
    render(<DemoToggle />)
    expect(toggleButton().title).toMatch(/Demo data ON/i)
  })

  it('reloads the page on click so every on-mount query re-runs against the new source', () => {
    render(<DemoToggle />)
    const realLocation = window.location
    const reload = vi.fn()
    Object.defineProperty(window, 'location', {
      value: { ...realLocation, reload },
      configurable: true,
      writable: true,
    })
    try {
      fireEvent.click(toggleButton())
      expect(reload).toHaveBeenCalledTimes(1)
    } finally {
      Object.defineProperty(window, 'location', { value: realLocation, configurable: true, writable: true })
    }
  })
})

describe('DemoToggle focus ring', () => {
  // jsdom does not execute global.css during a component test (no bundler CSS
  // pipeline in the vitest run), so this asserts against the stylesheet
  // source directly rather than a computed style — the same technique
  // cssVarUsage.test.ts uses for the same reason. It exists because the
  // button is styled entirely via inline styles and therefore cannot express
  // a `:focus-visible` rule itself; the ring has to live in global.css.
  it('declares a :focus-visible ring for the demo toggle, built from a theme token', () => {
    const css = readFileSync(join(__dirname, '..', 'styles', 'global.css'), 'utf8')
    const rule = css.match(/\[data-testid="demo-toggle"\]:focus-visible\s*\{([\s\S]*?)\}/)
    expect(rule, 'expected a [data-testid="demo-toggle"]:focus-visible rule in global.css').not.toBeNull()
    const body = rule![1]
    // Must set outline to something, not remove it.
    expect(body).toMatch(/outline\s*:\s*(?!none)/)
    expect(body).not.toMatch(/outline\s*:\s*none/)
    // Must reference a var(--...) token rather than a bare hex.
    expect(body).toMatch(/var\(--[a-zA-Z0-9-]+\)/)
    expect(body).not.toMatch(HEX_COLOUR)
  })
})
