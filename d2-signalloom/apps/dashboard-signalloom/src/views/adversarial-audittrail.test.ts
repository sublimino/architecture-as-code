/**
 * Adversarial tests for AuditTrail — structural invariants and the
 * EVENT_TYPES / EVENT_COLORS synchronisation contract.
 *
 * These tests import the source file directly and check the exported module
 * rather than rendering the component, since the invariants are about data
 * structure, not about DOM rendering.
 *
 * Round 3 adversarial testing.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

// AuditTrail.tsx does not export EVENT_TYPES or EVENT_COLORS, so we parse the
// source directly — the same structural-test pattern DemoToggle.test.tsx uses.
const src = readFileSync(
  join(__dirname, 'AuditTrail.tsx'),
  'utf8',
)

function extractArray(name: string): string[] {
  const pattern = new RegExp(`const ${name}\\s*=\\s*\\[([\\s\\S]*?)\\]`)
  const match = src.match(pattern)
  if (!match) throw new Error(`Could not find ${name} in AuditTrail.tsx`)
  const items = match[1].match(/'([^']+)'/g)
  return items ? items.map(s => s.replace(/'/g, '')) : []
}

function extractRecordKeys(name: string): string[] {
  // Matches both 'quoted.key': and unquoted_key:
  const pattern = new RegExp(`const ${name}[^{]*\\{([\\s\\S]*?)\\}`)
  const match = src.match(pattern)
  if (!match) throw new Error(`Could not find ${name} in AuditTrail.tsx`)
  const keys = match[1].match(/(?:'([^']+)'|(\w[\w.]*))(?=\s*:)/g)
  return keys ? keys.map(k => k.replace(/'/g, '')) : []
}

/** The right-hand side of each `key: 'value'` pair, for the maps that chain. */
function extractRecordValues(name: string): string[] {
  const pattern = new RegExp(`const ${name}[^{]*\\{([\\s\\S]*?)\\}`)
  const match = src.match(pattern)
  if (!match) throw new Error(`Could not find ${name} in AuditTrail.tsx`)
  const values = match[1].match(/:\s*'([^']+)'/g)
  return values ? values.map(v => v.replace(/^:\s*'/, '').replace(/'$/, '')) : []
}

const EVENT_TYPES = extractArray('EVENT_TYPES')
const EVENT_COLORS = extractRecordKeys('EVENT_COLORS')

// ── Synchronisation invariants ──────────────────────────────────────────────

describe('AuditTrail — EVENT_TYPES / EVENT_COLORS sync', () => {
  // The code comment says: "A new type must be added to BOTH lists — one
  // missing from EVENT_COLORS renders grey, one missing from EVENT_TYPES
  // cannot be filtered at all."

  it('every EVENT_TYPE has a corresponding EVENT_COLORS entry', () => {
    const missing = EVENT_TYPES.filter(t => !EVENT_COLORS.includes(t))
    expect(missing).toEqual([])
  })

  it('every EVENT_COLORS key is present in EVENT_TYPES', () => {
    const orphaned = EVENT_COLORS.filter(c => !EVENT_TYPES.includes(c))
    expect(orphaned).toEqual([])
  })

  it('EVENT_TYPES has no duplicates', () => {
    const seen = new Set<string>()
    const dups: string[] = []
    for (const t of EVENT_TYPES) {
      if (seen.has(t)) dups.push(t)
      seen.add(t)
    }
    expect(dups).toEqual([])
  })

  it('EVENT_COLORS has no duplicate keys', () => {
    const seen = new Set<string>()
    const dups: string[] = []
    for (const c of EVENT_COLORS) {
      if (seen.has(c)) dups.push(c)
      seen.add(c)
    }
    expect(dups).toEqual([])
  })
})

// ── fmtTs edge cases ────────────────────────────────────────────────────────
// fmtTs is not exported, so we test the pattern it uses.

describe('AuditTrail — timestamp formatting safety', () => {
  it('new Date("") produces Invalid Date', () => {
    // This is what fmtTs would produce for an empty timestamp
    const d = new Date('')
    expect(isNaN(d.getTime())).toBe(true)
    // toLocaleString of Invalid Date produces "Invalid Date"
    const result = d.toLocaleString('en-GB', {
      day: '2-digit', month: 'short', year: 'numeric',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
    })
    expect(result).toBe('Invalid Date')
  })

  it('valid ISO timestamp formats correctly', () => {
    const d = new Date('2026-07-27T12:00:00Z')
    const result = d.toLocaleString('en-GB', {
      day: '2-digit', month: 'short', year: 'numeric',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
    })
    // Should contain the date parts
    expect(result).toContain('2026')
    expect(result).toContain('Jul')
  })

  // BUG: fmtTs passes the ISO string directly to new Date() with no validation.
  // If the API returns an empty or malformed timestamp, the user sees "Invalid Date".
  it('the source code has no guard against invalid timestamps', () => {
    // Check if fmtTs has any validation before creating the Date
    const fmtTsMatch = src.match(/function fmtTs\([\s\S]*?\n\}/)
    expect(fmtTsMatch).not.toBeNull()
    const body = fmtTsMatch![0]
    // If there is no isNaN or 'Invalid' check, this is a bug we should fix
    const hasValidation = body.includes('isNaN') || body.includes('Invalid') || body.includes('isValid')
    // This test documents the current state — fmtTs has NO validation
    expect(hasValidation).toBe(false)
  })
})

// ── Event type vocabulary completeness ──────────────────────────────────────

describe('AuditTrail — vocabulary', () => {
  it('has at least 20 current event types', () => {
    // The dotted names are current; undotted are legacy
    const current = EVENT_TYPES.filter(t => t.includes('.') || t.startsWith('onboarding'))
    expect(current.length).toBeGreaterThanOrEqual(20)
  })

  it('includes the critical enforcement event types', () => {
    expect(EVENT_TYPES).toContain('agent.stunned')
    expect(EVENT_TYPES).toContain('agent.credential_revoked')
    expect(EVENT_TYPES).toContain('violation.acknowledged')
  })

  it('includes onboarding events', () => {
    expect(EVENT_TYPES).toContain('onboarding_completed')
    expect(EVENT_TYPES).toContain('onboarding_skipped')
  })
})

// ── The class facet, which is derived rather than declared ──────────────────
//
// The chip vocabulary is looked up THROUGH EVENT_COLORS, so a new event type
// classifies itself from the colour it was already given. The one way to break
// that is to introduce a sixth colour and not give it a class, which would
// quietly file those events under `other` — a bucket a reader would read as
// "unrecognised by the server" rather than "unrecognised by this map".

const EVENT_COLOR_VALUES = extractRecordValues('EVENT_COLORS')
const CLASS_OF_COLOR_KEYS = extractRecordKeys('CLASS_OF_COLOR')
const CLASS_OF_COLOR_VALUES = extractRecordValues('CLASS_OF_COLOR')
const EVENT_CLASSES = extractArray('EVENT_CLASSES')

describe('AuditTrail — event class taxonomy', () => {
  it('extracted something to test, rather than passing on an empty set', () => {
    // Every assertion below is a subset check, and a subset check over nothing
    // is vacuously true. These four guard the guards: a rename that broke the
    // extractors would otherwise turn this whole block green and silent.
    expect(EVENT_COLOR_VALUES.length).toBeGreaterThan(20)
    expect(CLASS_OF_COLOR_KEYS.length).toBeGreaterThan(0)
    expect(CLASS_OF_COLOR_VALUES.length).toBe(CLASS_OF_COLOR_KEYS.length)
    expect(EVENT_CLASSES.length).toBeGreaterThan(2)
  })

  it('gives every colour EVENT_COLORS uses a class', () => {
    const unmapped = [...new Set(EVENT_COLOR_VALUES)].filter(c => !CLASS_OF_COLOR_KEYS.includes(c))
    expect(unmapped).toEqual([])
  })

  it('maps no colour EVENT_COLORS does not use', () => {
    const orphaned = CLASS_OF_COLOR_KEYS.filter(c => !EVENT_COLOR_VALUES.includes(c))
    expect(orphaned).toEqual([])
  })

  it('only produces classes the chip vocabulary offers', () => {
    const unreachable = CLASS_OF_COLOR_VALUES.filter(c => !EVENT_CLASSES.includes(c))
    expect(unreachable).toEqual([])
  })

  it('offers `all` first and keeps `other` for a colour it has never seen', () => {
    // `all` first so the row of chips reads as a ranking from its own left
    // edge; `other` present so `classOf` is total and a type from a newer
    // server is still reachable.
    expect(EVENT_CLASSES[0]).toBe('all')
    expect(EVENT_CLASSES).toContain('other')
    // `other` is the fall-through, so nothing may map to it explicitly —
    // that would make one bucket mean two different things.
    expect(CLASS_OF_COLOR_VALUES).not.toContain('other')
  })
})

// ── The composition the Design System's third specimen prescribes ───────────

describe('AuditTrail — conforms to the super DataTable pattern', () => {
  it('passes the strip through DataTable rather than stacking it above', () => {
    // The regression this guards is a revert to the old filter card: a strip
    // rendered as a sibling of the table disappears on the empty branch,
    // taking with it the only control that could undo the filter that emptied
    // it. Behavioural tests cover the consequence; this catches the shape,
    // because the consequence is only visible in one state.
    expect(src).toMatch(/toolbar=\{filterStrip\}/)
    expect(src).toMatch(/emptyState=\{/)
  })

  it('hands DataTable the narrowed array, not the raw one', () => {
    // `data={events}` would pass every test in AuditTrail.test.tsx that does
    // not filter, which is most of them.
    expect(src).toMatch(/data=\{visibleEvents\}/)
    expect(src).not.toMatch(/data=\{events\}/)
  })

  it('keeps the predicate on this page, where DataTableToolbar cannot reach it', () => {
    // The survey's one hard prohibition: the shared toolbar never sees a row.
    // If a predicate ever migrates into it, the two useFilter hooks that
    // already diverged on their type become three.
    const toolbarSrc = readFileSync(join(__dirname, '..', 'components', 'DataTableToolbar.tsx'), 'utf8')
    expect(toolbarSrc).not.toMatch(/\bdata\b\s*:/)
    expect(src).toMatch(/const visibleEvents = useMemo/)
  })
})
