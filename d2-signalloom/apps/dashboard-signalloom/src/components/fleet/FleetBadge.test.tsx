import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import FleetBadge, { stateToken, trustToken } from './FleetBadge'
import type { AgentState } from '../../api/fleetApi'

// ── Drift guard ─────────────────────────────────────────────────────────────
//
// The whole justification for this component existing instead of StatusBadge is
// that it matches the DIAGRAM. If the diagram's palette moves and this does not,
// the same agent is one colour as a card and another as a row, which is worse
// than the grey-everything default we started from. So the maps are checked
// against FleetTopology's source rather than against a copy of it.
//
// Read from disk, in the same spirit as styles/cssVarUsage.test.ts, because
// `stateColour` and `trustBadgeColour` are private to that module and exporting
// them purely to be tested would widen its API for the benefit of this file.

function topologySource(): string {
  return readFileSync(join(__dirname, 'FleetTopology.tsx'), 'utf8')
}

/** Pull `case 'x': return 'var(--y)'` pairs out of a named function's body. */
function switchMap(source: string, fnName: string): Record<string, string> {
  const start = source.indexOf(`function ${fnName}(`)
  expect(start, `${fnName} should still exist in FleetTopology.tsx`).toBeGreaterThan(-1)
  const body = source.slice(start, source.indexOf('\n}', start))
  const out: Record<string, string> = {}
  for (const m of body.matchAll(/case '([a-z-]+)':\s*return '(var\(--[a-z0-9-]+\))'/g)) {
    out[m[1]] = m[2]
  }
  return out
}

describe('FleetBadge tracks the topology diagram', () => {
  it('uses the diagram colour for every state the diagram colours', () => {
    const diagram = switchMap(topologySource(), 'stateColour')
    expect(Object.keys(diagram).length).toBeGreaterThan(0)

    for (const [state, token] of Object.entries(diagram)) {
      // `absent` is the documented divergence: --surface2 text on a --surface2
      // fill is invisible in a cell, so the table says muted instead.
      if (state === 'absent') continue
      expect(stateToken(state as AgentState['state']), state).toBe(token)
    }
  })

  it('uses the diagram colour for every trust profile', () => {
    const diagram = switchMap(topologySource(), 'trustBadgeColour')
    expect(Object.keys(diagram)).toEqual(expect.arrayContaining(['high', 'medium', 'low']))

    for (const [profile, token] of Object.entries(diagram)) {
      expect(trustToken(profile as AgentState['trustProfile']), profile).toBe(token)
    }
  })

  it('keeps high trust and high risk apart, which is why StatusBadge cannot do this', () => {
    // High trust is good and reads teal. If this ever renders amber, someone has
    // reached for the `risk` map, where `high` means the opposite thing.
    expect(trustToken('high')).toBe('var(--teal)')
    expect(trustToken('low')).toBe('var(--error)')
  })
})

describe('FleetBadge rendering', () => {
  it('carries the shared tag class so it matches every other badge in the product', () => {
    render(<FleetBadge label="active" token="var(--cyan)" testId="b" />)
    expect(screen.getByTestId('b')).toHaveClass('tag')
    expect(screen.getByTestId('b')).toHaveTextContent('active')
  })

  it('states its colours as tokens only, never as literal hex', () => {
    render(<FleetBadge label="stunned" token="var(--error)" testId="b" />)
    const style = screen.getByTestId('b').getAttribute('style') ?? ''
    expect(style).not.toMatch(/#[0-9a-f]{3,8}\b/i)
    expect(style).toMatch(/var\(--error\)/)
  })

  it('keeps the API word intact, hyphen and all', () => {
    // StatusBadge rewrites underscores to spaces. The fleet API's states are
    // hyphenated (`non-compliant`, `grace-period`) and the hyphen is part of
    // the word the operator will search for in the toolbar.
    render(<FleetBadge label="non-compliant" token="var(--amber)" testId="b" />)
    expect(screen.getByTestId('b')).toHaveTextContent('non-compliant')
  })
})
