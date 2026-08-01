import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import StatusBadge, { getStatusColor, tint } from './StatusBadge'
import { colors } from '../styles/tokens'
import { THEMES } from '../styles/themes'

// Every status the app actually renders a pill for.
const STATUSES: Array<[string, string | undefined]> = [
  ['enrolled', 'lifecycle'],
  ['active', 'lifecycle'],
  ['suspended', 'lifecycle'],
  ['revoked', 'lifecycle'],
  ['minimal_risk', 'risk'],
  ['limited_risk', 'risk'],
  ['high_risk', 'risk'],
  ['unacceptable_risk', 'risk'],
  ['gpai', 'risk'],
  ['standard', 'privilege'],
  ['elevated', 'privilege'],
  ['domain_admin', 'privilege'],
  ['enterprise_admin', 'privilege'],
  ['new', 'violation'],
  ['acknowledged', 'violation'],
  ['resolved', 'violation'],
  ['pass', 'compliance'],
  ['fail', 'compliance'],
  ['pending', 'compliance'],
  ['reassessment_requested', 'compliance'],
  ['discovered', 'nhi'],
  ['enrollment_requested', 'nhi'],
  ['dismissed', 'nhi'],
]

// The one documented exception: no theme variable carries this orange.
const LITERAL_EXCEPTIONS = new Set(['#f97316'])

const VAR_REF = /^var\(--[a-z-]+\)$/

describe('StatusBadge colour sourcing', () => {
  it('resolves every pill text colour from a theme variable, not a literal', () => {
    for (const [status, variant] of STATUSES) {
      const { color } = getStatusColor(status, variant)
      if (LITERAL_EXCEPTIONS.has(color)) continue
      expect(color, `${variant}/${status} text colour must be a theme variable`).toMatch(VAR_REF)
    }
  })

  it('resolves every pill background from a theme variable', () => {
    for (const [status, variant] of STATUSES) {
      const { bg } = getStatusColor(status, variant)
      expect(bg, `${variant}/${status} background must be theme-derived`).toMatch(
        /^color-mix\(in srgb, var\(--[a-z-]+\) [\d.]+%, transparent\)$/,
      )
    }
  })

  it('never emits a bare hex literal outside the documented exception', () => {
    for (const [status, variant] of STATUSES) {
      const { bg, color } = getStatusColor(status, variant)
      for (const value of [bg, color]) {
        const literals = value.match(/#[0-9A-Fa-f]{3,8}/g) ?? []
        for (const literal of literals) {
          expect(LITERAL_EXCEPTIONS.has(literal), `${status} leaked literal ${literal}`).toBe(true)
        }
      }
    }
  })
})

// The compliance pills are the reported defect: AgentsPage emits `compliant` /
// `non_compliant`, which no map defines, so they fall through to the default.
describe('compliance pills (the reported light-theme defect)', () => {
  it('routes the unmapped compliance statuses through --muted, not a grey literal', () => {
    for (const status of ['compliant', 'non_compliant', 'pending']) {
      const { color, bg } = getStatusColor(status, 'compliance')
      expect(color, `${status} must not be a hard-coded grey`).toBe('var(--muted)')
      expect(bg).toContain('var(--slate-gray)')
    }
  })

  it('gives those pills a dark-on-light pairing under the Light theme', () => {
    // --muted resolves to a dark slate under Light, so the text reads against
    // the pale chip instead of vanishing into it.
    expect(relativeLuminance(THEMES.light['--muted'])).toBeLessThan(0.25)
    expect(relativeLuminance(THEMES.light['--bg'])).toBeGreaterThan(0.9)
    // Under Dark the same variable keeps the exact literal it replaced.
    expect(THEMES.dark['--muted']).toBe(colors.muted)
  })
})

describe('Dark theme is unchanged by the variable indirection', () => {
  it('maps each replaced token literal onto an identical Dark variable value', () => {
    expect(THEMES.dark['--cyan']).toBe(colors.cyanLoom)
    expect(THEMES.dark['--teal']).toBe(colors.tealLoom)
    expect(THEMES.dark['--amber']).toBe(colors.amber)
    expect(THEMES.dark['--error']).toBe(colors.red)
    expect(THEMES.dark['--violet']).toBe(colors.irisViolet)
    expect(THEMES.dark['--muted']).toBe(colors.muted)
    expect(THEMES.dark['--slate-gray']).toBe(colors.slateGray)
  })

  it('quantises the tint alpha to the same n/255 step the old hex suffix used', () => {
    // Old: '#10B981' + Math.round(0.12 * 255).toString(16) === '#10B9811f',
    // i.e. alpha 31/255. color-mix must land on the same fraction.
    const legacyAlpha = Math.round(0.12 * 255) / 255
    const pct = Number(tint('var(--teal)', 0.12).match(/ ([\d.]+)%/)![1])
    expect(pct / 100).toBeCloseTo(legacyAlpha, 12)

    const legacy15 = Math.round(0.15 * 255) / 255
    const pct15 = Number(tint('var(--slate-gray)', 0.15).match(/ ([\d.]+)%/)![1])
    expect(pct15 / 100).toBeCloseTo(legacy15, 12)
  })
})

describe('StatusBadge rendering', () => {
  it('renders the status text with underscores humanised', () => {
    render(<StatusBadge status="non_compliant" variant="compliance" />)
    expect(screen.getByText('non compliant')).toBeInTheDocument()
  })

  it('keeps the .tag class so the shared pill styling applies', () => {
    render(<StatusBadge status="active" variant="lifecycle" />)
    expect(screen.getByText('active')).toHaveClass('tag')
  })
})

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
