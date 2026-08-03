/**
 * Guards on the refresh cadence the audience window depends on.
 *
 * The demo is watched, not driven, in the second browser window. If any of
 * these invariants breaks, that window goes quiet and the only symptom is a
 * room full of people looking at a stale page — no error, no failing build.
 * Hence the pins.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, extname } from 'node:path'
import {
  LIVE_POLL_MS,
  OBSERVATION_BACKOFF_CEILING_MS,
  OBSERVATION_FAILURE_THRESHOLD,
  OBSERVATION_TTL_MS,
  observationStaleAfter,
} from './pollInterval'

const SRC_DIR = join(__dirname, '..')

/** Surfaces the audience watches. These must poll at demo speed. */
const AUDIENCE_SURFACES = [
  'pages/AgentsPage.tsx',
  'views/Compliance.tsx',
  'views/Agents.tsx',
]

describe('LIVE_POLL_MS — the audience window has to move on its own', () => {
  it('is pinned at 2500ms', () => {
    // Pinned, not bounded: this value is the difference between a demo that
    // tells a story and one that needs a manual reload. Changing it should be
    // a deliberate act that updates this test.
    expect(LIVE_POLL_MS).toBe(2500)
  })

  it('is fast enough that a phase change lands inside a spoken sentence', () => {
    expect(LIVE_POLL_MS).toBeLessThanOrEqual(5_000)
  })

  it('is nowhere near the fifteen minutes these pages shipped with', () => {
    // The exact defect this module exists to prevent coming back.
    expect(LIVE_POLL_MS).toBeLessThan(15 * 60 * 1000)
  })

  it('leaves the observation cache expired by the time the next poll fires', () => {
    // The whole point. A TTL at or above the poll interval means every poll is
    // answered from cache and the audience window freezes.
    expect(OBSERVATION_TTL_MS).toBeLessThan(LIVE_POLL_MS)
  })
})

describe('observationStaleAfter — a blink must not stall the demo', () => {
  it('retries at the TTL while the failure streak is short', () => {
    for (let n = 0; n < OBSERVATION_FAILURE_THRESHOLD; n++) {
      expect(observationStaleAfter(n)).toBe(OBSERVATION_TTL_MS)
    }
  })

  it('costs seconds, not a minute, when the proxy blinks three times', () => {
    // The old cliff jumped straight to 60_000 here, freezing the audience
    // window for a full minute after one transient blip.
    expect(observationStaleAfter(OBSERVATION_FAILURE_THRESHOLD)).toBe(4_000)
    expect(observationStaleAfter(OBSERVATION_FAILURE_THRESHOLD)).toBeLessThan(10_000)
  })

  it('still backs off to the ceiling when the proxy is genuinely absent', () => {
    expect(observationStaleAfter(50)).toBe(OBSERVATION_BACKOFF_CEILING_MS)
  })

  it('never exceeds the ceiling, however long the dashboard is left open', () => {
    for (const n of [8, 20, 100, 1_000, 100_000]) {
      expect(observationStaleAfter(n)).toBeLessThanOrEqual(OBSERVATION_BACKOFF_CEILING_MS)
      expect(Number.isFinite(observationStaleAfter(n))).toBe(true)
    }
  })

  it('increases monotonically with the failure streak', () => {
    for (let n = 1; n <= 20; n++) {
      expect(observationStaleAfter(n)).toBeGreaterThanOrEqual(observationStaleAfter(n - 1))
    }
  })
})

describe('no audience surface may quietly go back to a slow poll', () => {
  it.each(AUDIENCE_SURFACES)('%s polls at LIVE_POLL_MS', (relative) => {
    const source = readFileSync(join(SRC_DIR, relative), 'utf8')

    expect(source).toContain('LIVE_POLL_MS')
    // The literal that caused the bug, in the forms it could come back as.
    expect(source).not.toMatch(/15\s*\*\s*60\s*\*\s*1000/)
    expect(source).not.toContain('900000')
    expect(source).not.toContain('900_000')
  })

  it('only the surfaces outside the demo narrative still poll slowly', () => {
    // Not every page needs demo speed, and quietly cranking all of them to
    // 2.5s would multiply this dashboard's request load for no benefit. These
    // three carry no SuperCred evidence, so they keep the fifteen-minute
    // cadence — but the list is pinned, so a NEW slow poll on a surface the
    // audience does watch fails here rather than shipping.
    const KNOWN_SLOW = [
      'pages/DiscoveryPage.tsx',
      'views/AuditTrail.tsx',
      'views/Settings.tsx',
    ].sort()

    const offenders: string[] = []
    const walk = (dir: string) => {
      for (const entry of readdirSync(dir)) {
        if (entry === 'node_modules' || entry === 'dist') continue
        const full = join(dir, entry)
        if (statSync(full).isDirectory()) { walk(full); continue }
        if (!['.ts', '.tsx'].includes(extname(full))) continue
        // This module and its test both quote the defective literal in prose,
        // documenting the bug they exist to prevent.
        if (full.endsWith('pollInterval.ts') || full.endsWith('pollInterval.test.ts')) continue
        const content = readFileSync(full, 'utf8')
        if (/POLL_MS\s*=\s*15\s*\*\s*60\s*\*\s*1000/.test(content)) {
          offenders.push(full.slice(SRC_DIR.length + 1))
        }
      }
    }
    walk(SRC_DIR)

    expect(offenders.sort()).toEqual(KNOWN_SLOW)
  })
})
