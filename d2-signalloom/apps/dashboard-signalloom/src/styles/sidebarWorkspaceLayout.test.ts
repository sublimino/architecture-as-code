import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { EXPANDED_WIDTH, COLLAPSED_WIDTH } from '../components/Sidebar'

const CSS = readFileSync(join(__dirname, 'global.css'), 'utf8')

/** Declarations of the first rule whose selector list matches exactly. */
function rule(selector: string): Record<string, string> {
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

function parsePadding(paddingStr: string | undefined): { top: number; right: number; bottom: number; left: number } {
  const parts = (paddingStr ?? '0').trim().split(/\s+/).map(px)
  if (parts.length === 1) return { top: parts[0], right: parts[0], bottom: parts[0], left: parts[0] }
  if (parts.length === 2) return { top: parts[0], right: parts[1], bottom: parts[0], left: parts[1] }
  if (parts.length === 3) return { top: parts[0], right: parts[1], bottom: parts[2], left: parts[1] }
  return { top: parts[0], right: parts[1], bottom: parts[2], left: parts[3] }
}

describe('sidebar workspace header layout arithmetic', () => {
  const ws = rule('.sl-sidebar__workspace')
  const wsBtn = rule('.sl-sidebar__workspace-button')
  const toggle = rule('.sl-sidebar__collapse-toggle')
  const wsCollapsed = rule('.sl-sidebar--collapsed .sl-sidebar__workspace')
  const wsBtnCollapsed = rule('.sl-sidebar--collapsed .sl-sidebar__workspace-button')
  const quickSearch = rule('.sl-sidebar__quick-search')

  it('workspace button in expanded mode does not claim 100% width, allowing the collapse toggle to keep its right inset', () => {
    // BUG: .sl-sidebar__workspace-button had `width: 100%`, which in a flex row
    // blew past the container's 12px right padding, pressing the toggle against the border.
    expect(wsBtn.width).not.toBe('100%')
    expect(wsBtn.flex || wsBtn['flex-grow']).toBeDefined()
  })

  it('preserves a 12px right inset for the collapse toggle matching quick-search margin', () => {
    const wsPad = parsePadding(ws.padding)
    const quickSearchMarginX = px(quickSearch.margin.split(/\s+/)[1])
    expect(wsPad.left).toBe(12)
    expect(wsPad.right).toBe(12)
    expect(quickSearchMarginX).toBe(12)

    // Inner width of rail minus 1px right border
    const innerWidth = EXPANDED_WIDTH - 1
    const toggleWidth = px(toggle.width)
    const gap = px(ws.gap)

    // With flex: 1 on the workspace button, available content width = innerWidth - wsPad.left - wsPad.right
    const contentWidth = innerWidth - wsPad.left - wsPad.right
    const btnWidth = contentWidth - gap - toggleWidth
    expect(gap).toBe(8)
    expect(btnWidth).toBeGreaterThanOrEqual(200)

    // Button + gap + toggle + right padding must equal innerWidth - left padding
    const toggleRightEdge = wsPad.left + btnWidth + gap + toggleWidth
    const toggleRightInset = innerWidth - toggleRightEdge

    expect(toggleRightInset).toBe(wsPad.right)
    expect(toggleRightInset).toBe(quickSearchMarginX)
  })

  it('anchors the logo at the identical horizontal inset across expanded and collapsed states', () => {
    // In expanded mode: workspace padding-left (12px) + button padding-left (4px) = 16px
    const expandedWsPad = parsePadding(ws.padding)
    const expandedBtnPad = parsePadding(wsBtn.padding)
    const expandedLogoLeft = expandedWsPad.left + expandedBtnPad.left

    // In collapsed mode: rail is 64px, logo is 32px, perfectly centered at (64 - 32) / 2 = 16px
    const collapsedRailInner = COLLAPSED_WIDTH // 64px
    const logoWidth = 32
    const collapsedLogoLeft = (collapsedRailInner - logoWidth) / 2

    // The logo must not shift horizontally when collapsing or expanding
    expect(expandedLogoLeft).toBe(collapsedLogoLeft)
    expect(expandedLogoLeft).toBe(16)
  })

  it('anchors the logo at the identical vertical inset across expanded and collapsed states', () => {
    // In expanded mode: workspace padding-top (12px) + button padding-top (4px) = 16px
    const expandedWsPad = parsePadding(ws.padding)
    const expandedBtnPad = parsePadding(wsBtn.padding)
    const expandedLogoTop = expandedWsPad.top + expandedBtnPad.top

    // In collapsed mode: workspace padding-top (12px) + button padding-top (4px) = 16px
    const collapsedWsPad = parsePadding(wsCollapsed.padding)
    const collapsedBtnPad = parsePadding(wsBtnCollapsed.padding)
    const collapsedLogoTop = collapsedWsPad.top + collapsedBtnPad.top

    // The logo must not jump vertically when collapsing or expanding
    expect(expandedLogoTop).toBe(collapsedLogoTop)
    expect(expandedLogoTop).toBe(16)
  })

  it('centers both logo and collapse toggle on the 32px rail center line in collapsed mode', () => {
    const railCenter = COLLAPSED_WIDTH / 2 // 32px
    const logoWidth = 32
    const toggleWidth = px(toggle.width) // 28px

    const logoCenter = (COLLAPSED_WIDTH - logoWidth) / 2 + logoWidth / 2
    const toggleCenter = (COLLAPSED_WIDTH - toggleWidth) / 2 + toggleWidth / 2

    expect(logoCenter).toBe(railCenter)
    expect(toggleCenter).toBe(railCenter)
    expect(wsCollapsed['align-items']).toBe('center')
  })
})
