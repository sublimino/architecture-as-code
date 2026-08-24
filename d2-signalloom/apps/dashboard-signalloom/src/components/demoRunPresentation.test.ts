/**
 * The presentation rules shared by every demo-runner panel.
 *
 * These four helpers were private to SuperCredInstructorPanel. Signal Fusion
 * needed all four, and the alternative to extracting them was a second copy —
 * which is how the colour of `timed_out`, the number of tail lines, and the
 * 401-vs-403 triage would have drifted between two panels driving the SAME
 * runner. Tested here rather than only through a panel because that is what
 * makes the extraction worth anything: a rule with its own test is a rule, a
 * rule reached only through two components is two conventions.
 */
import { describe, it, expect } from 'vitest'
import { colors } from '../styles/tokens'
import {
  LOG_TAIL_LINES,
  RUN_STATUS_COLORS,
  describeRunnerError,
  logTail,
  runStartedAt,
  runStatusTone,
} from './demoRunPresentation'
import type { DemoRunView } from '../api/demoRunner'

function run(overrides: Partial<DemoRunView> = {}): DemoRunView {
  return {
    run_id: 'run-1',
    step_id: '1',
    kind: 'step',
    status: 'running',
    started_at: '2026-08-02T10:00:00Z',
    finished_at: null,
    exit_code: null,
    error: null,
    ...overrides,
  }
}

describe('RUN_STATUS_COLORS', () => {
  // A run that ended without succeeding must never be painted with the colour
  // of one that did. Asserted per status rather than as "the map has 5 keys",
  // so swapping two values is a failure and not a rename.
  it('separates success from every way a run can fail to succeed', () => {
    expect(RUN_STATUS_COLORS.succeeded).toBe(colors.tealLoom)
    expect(RUN_STATUS_COLORS.running).toBe(colors.cyanLoom)
    expect(RUN_STATUS_COLORS.failed).toBe(colors.red)
    expect(RUN_STATUS_COLORS.timed_out).toBe(colors.amber)
    expect(RUN_STATUS_COLORS.cancelled).toBe(colors.amber)
    expect(RUN_STATUS_COLORS.failed).not.toBe(RUN_STATUS_COLORS.succeeded)
    expect(RUN_STATUS_COLORS.timed_out).not.toBe(RUN_STATUS_COLORS.succeeded)
    expect(RUN_STATUS_COLORS.cancelled).not.toBe(RUN_STATUS_COLORS.succeeded)
  })

  // Every value has to be a var(--token): src/styles/cssVarUsage.test.ts
  // rejects a bare hex in an inline style, and a hex would be wrong in two of
  // the three themes anyway.
  it('is expressed entirely in theme tokens', () => {
    for (const [status, tone] of Object.entries(RUN_STATUS_COLORS)) {
      expect(tone, `${status} must be a theme token`).toMatch(/^var\(--[a-z-]+\)$/)
    }
  })
})

describe('runStatusTone', () => {
  it('answers the token for a known status', () => {
    expect(runStatusTone('succeeded')).toBe(colors.tealLoom)
    expect(runStatusTone('failed')).toBe(colors.red)
  })

  // An unknown status is the runner having grown a state this build has never
  // heard of. Muted says "no opinion", which is true; anything else claims one.
  it('falls back to muted for a status it does not know, and for none at all', () => {
    expect(runStatusTone('quantum_superposition')).toBe('var(--muted)')
    expect(runStatusTone(undefined)).toBe('var(--muted)')
  })
})

describe('runStartedAt', () => {
  it('reads the runner’s own stamp, not the caller’s clock', () => {
    expect(runStartedAt(run({ started_at: '2026-08-02T10:00:00Z' })))
      .toBe(Date.parse('2026-08-02T10:00:00Z'))
  })

  // Undefined rather than Date.now(): PixelLoader treats undefined as "start
  // the clock at mount", which understates the age of an adopted run but does
  // not fabricate a figure. A NaN would render "NaNs" on stage.
  it('answers undefined rather than a fabricated time when the stamp is absent or unusable', () => {
    expect(runStartedAt(run({ started_at: null }))).toBeUndefined()
    expect(runStartedAt(run({ started_at: 'not a date' }))).toBeUndefined()
    expect(runStartedAt(null)).toBeUndefined()
    expect(runStartedAt(undefined)).toBeUndefined()
  })
})

describe('logTail', () => {
  // The lines that explain a failure are the LAST ones. Exact expected output,
  // so shortening or lengthening the window is a failure rather than a
  // difference of opinion nobody notices.
  it('keeps the last LOG_TAIL_LINES lines and drops the earlier ones', () => {
    const log = Array.from({ length: 20 }, (_, i) => `line ${i + 1}`).join('\n')
    const tail = logTail(log).split('\n')

    expect(tail).toHaveLength(LOG_TAIL_LINES)
    expect(tail[0]).toBe(`line ${20 - LOG_TAIL_LINES + 1}`)
    expect(tail[tail.length - 1]).toBe('line 20')
    expect(tail).not.toContain('line 1')
  })

  it('returns a short log whole', () => {
    expect(logTail('only\ntwo')).toBe('only\ntwo')
  })

  // Blank lines are the runner's spacing, and spending the tail budget on them
  // is how a 12-line window shows four lines of output.
  it('does not spend the window on blank lines', () => {
    expect(logTail('a\n\n   \nb\n\n')).toBe('a\nb')
  })

  // The runner emits colour. Escape bytes rendered into the DOM are visible
  // mojibake, and stripping them HERE with the same regex the streaming block
  // uses is why there is one convention rather than two.
  it('strips the ANSI colour the runner emits', () => {
    const tail = logTail(`\u001b[32m[ok]\u001b[0m deployed`)
    expect(tail).toBe('[ok] deployed')
    expect(tail).not.toContain(`\u001b`)
  })

  it('honours an explicit window when a caller has less room', () => {
    expect(logTail('a\nb\nc\nd', 2)).toBe('c\nd')
  })
})

describe('describeRunnerError', () => {
  // The three causes need three different actions from the instructor, and
  // reporting all of them as "not reachable" sends them to debug a network
  // that is fine. Asserted on the ACTION each answer names, because that is
  // the part a wrong branch gets wrong.
  it('names a stale session for 401, and says the runner itself is fine', () => {
    const answer = describeRunnerError('Demo status failed: 401 — invalid_token')
    expect(answer).toMatch(/sign out and back in/i)
    expect(answer).toMatch(/demo runner itself is fine/i)
    expect(answer).not.toMatch(/not reachable/i)
  })

  it('recognises a 401 reported only in words', () => {
    expect(describeRunnerError('token is invalid')).toMatch(/sign out and back in/i)
  })

  it('names the account, not the network, for 403', () => {
    const answer = describeRunnerError('403 superadmin_required')
    expect(answer).toMatch(/not a superadmin/i)
    expect(answer).not.toMatch(/sign out and back in/i)
    expect(answer).not.toMatch(/not reachable/i)
  })

  // The fallback must carry the original text through. A generic "something
  // went wrong" is the failure mode this whole function exists to remove.
  it('falls back to unreachable and quotes the underlying failure verbatim', () => {
    const answer = describeRunnerError('Failed to fetch')
    expect(answer).toMatch(/not reachable/i)
    expect(answer).toContain('Failed to fetch')
  })

  // "1401" is not a 401 and "4030" is not a 403; a substring match would
  // route both to the wrong advice.
  it('does not mistake a longer number for an auth status', () => {
    expect(describeRunnerError('upstream said 1401')).toMatch(/not reachable/i)
    expect(describeRunnerError('port 4030 refused')).toMatch(/not reachable/i)
  })
})
