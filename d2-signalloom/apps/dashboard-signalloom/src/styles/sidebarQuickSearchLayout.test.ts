import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { EXPANDED_WIDTH } from '../components/Sidebar'

// The quick-search row overflowed its rail twice over, and both causes were
// arithmetic nobody had written down.
//
// First, the row is a stretched column-flex child of a <nav> that has no
// padding of its own. Every other block in the rail supplies its own inset,
// but the search row declared `margin-top` only — so it ran the full rail
// width, edge to edge, and its 2px outset :focus-within ring was clipped on
// both sides by the rail's `overflow: hidden`.
//
// Second, the row had no declared width budget. The clear "x" button was added
// to it without anyone revisiting what the row costs, and the magnifier and
// the <kbd> still carried the default `flex-shrink: 1`, so under pressure they
// squeezed instead of the input.
//
// jsdom has no layout engine, so this suite does what jsdom cannot: it reads
// the declarations out of global.css and does the box arithmetic itself. That
// makes the budget a checked fact rather than a comment, and the next control
// added to this row fails here rather than in Andy's browser.

const CSS = readFileSync(join(__dirname, 'global.css'), 'utf8')

/** Declarations of the first rule whose selector list matches exactly. */
function rule(selector: string): Record<string, string> {
  // Anchored on a newline so `.sl-sidebar__quick-search` cannot match the
  // longer `.sl-sidebar__quick-search:focus-within` rule that follows it.
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const match = CSS.match(new RegExp(`(?:^|\\n)${escaped}\\s*\\{([^}]*)\\}`))
  if (!match) throw new Error(`No rule in global.css for selector: ${selector}`)
  const out: Record<string, string> = {}
  for (const decl of match[1].split(';')) {
    const idx = decl.indexOf(':')
    if (idx === -1) continue
    out[decl.slice(0, idx).trim()] = decl.slice(idx + 1).trim()
  }
  return out
}

const px = (value: string | undefined): number => {
  const n = Number.parseFloat(value ?? '')
  if (Number.isNaN(n)) throw new Error(`Not a px length: ${value}`)
  return n
}

const row = rule('.sl-sidebar__quick-search')
const rowFocus = rule('.sl-sidebar__quick-search:focus-within')
const rowSvg = rule('.sl-sidebar__quick-search svg')
const rowInput = rule('.sl-sidebar__quick-search input')
const rowKbd = rule('.sl-sidebar__quick-search > kbd')
const kbdShared = rule('.sl-sidebar__quick-search kbd, .sl-sidebar__shortcut')
const clearButton = rule('.sl-sidebar__search-clear')

/** `margin: 9px 12px 0` -> 12. */
const marginX = px(row.margin.split(/\s+/)[1])
/** `padding: 0 8px` -> 8. */
const paddingX = px(row.padding.split(/\s+/)[1])
/** `border: 1px solid var(--border)` -> 1. */
const borderX = px(row.border.split(/\s+/)[0])
const gap = px(row.gap)
/** `box-shadow: 0 0 0 2px var(--cyan-focus)` -> the 2px spread, drawn outset. */
const focusRingSpread = px(rowFocus['box-shadow'].split(/\s+/)[3])

// The row holds a magnifier, the input, and exactly one trailing control:
// either the <kbd>/</kbd> hint or the clear button, never both (Sidebar.tsx
// renders them from one ternary). Budget against the wider of the two.
const magnifierWidth = px(rowSvg.width)
const trailingWidth = Math.max(px(kbdShared['min-width']), px(clearButton.width))
const IN_FLOW_CHILDREN = 3 // magnifier, input, trailing control (.sr-only is position:absolute)

/** Width left for the input once every fixed cost in the row is paid. */
function inputWidthAt(railWidth: number): number {
  const rowOuter = railWidth - marginX * 2
  const flexLine = rowOuter - borderX * 2 - paddingX * 2
  const fixed = magnifierWidth + trailingWidth + gap * (IN_FLOW_CHILDREN - 1)
  return flexLine - fixed
}

/** The 224px `!important` rail from global.css's max-width: 900px block. */
function narrowRailWidth(): number {
  const block = CSS.match(/@media \(max-width: 900px\) \{([\s\S]*?)\n\}/)
  if (!block) throw new Error('No max-width: 900px block in global.css')
  const width = block[1].match(/\.sl-sidebar \{[^}]*?width:\s*(\d+)px/)
  if (!width) throw new Error('No .sl-sidebar width in the 900px block')
  return Number(width[1])
}

describe('sidebar quick-search width budget', () => {
  it('insets the row from the rail so nothing sits flush against its edge', () => {
    // The regression: `margin-top: 9px` with no horizontal margin at all.
    expect(marginX).toBeGreaterThan(0)
    expect(row.margin.split(/\s+/)).toHaveLength(3)
  })

  it('leaves room for the outset focus ring the rail would otherwise clip', () => {
    // .sl-sidebar sets overflow: hidden, so a ring drawn outside the row's
    // border box is cut off unless the inset is at least as wide as the ring.
    expect(focusRingSpread).toBeGreaterThan(0)
    expect(marginX).toBeGreaterThanOrEqual(focusRingSpread)
  })

  it('fits inside the expanded rail with the clear button present', () => {
    const available = inputWidthAt(EXPANDED_WIDTH)
    expect(available).toBeGreaterThan(0)
    // Headroom, not just non-negative: an input narrower than this shows only
    // a few characters of the query and the placeholder truncates.
    expect(available).toBeGreaterThanOrEqual(120)
  })

  it('fits inside the narrow-viewport rail too', () => {
    const narrow = narrowRailWidth()
    expect(narrow).toBeLessThan(EXPANDED_WIDTH)
    expect(inputWidthAt(narrow)).toBeGreaterThanOrEqual(100)
  })

  it('budgets the clear button, which is the wider of the two trailing controls', () => {
    // Guards the specific oversight: the clear button was added to the row
    // without the budget being revisited, so it has to be the one costed.
    expect(px(clearButton.width)).toBeGreaterThanOrEqual(px(kbdShared['min-width']))
    expect(trailingWidth).toBe(px(clearButton.width))
  })

  it('pins every fixed-width child so only the input flexes', () => {
    // Default flex-shrink is 1. Left at the default, the magnifier and the
    // <kbd> squash before the input does, which is backwards — the input is
    // the elastic thing in the row and everything else is a fixed cost.
    expect(rowSvg.flex).toBe('0 0 auto')
    expect(rowKbd.flex).toBe('0 0 auto')
    expect(clearButton.flex).toBe('0 0 auto')
    expect(rowInput.flex).toBe('1 1 0')
    // Without min-width: 0 an input's default `size` gives it an intrinsic
    // min-content width of roughly 170px, which no flex basis can shrink past.
    expect(rowInput['min-width']).toBe('0')
  })

  it('keeps the row inside its container even if a future child overruns', () => {
    expect(row['max-width']).toBe('100%')
  })
})
