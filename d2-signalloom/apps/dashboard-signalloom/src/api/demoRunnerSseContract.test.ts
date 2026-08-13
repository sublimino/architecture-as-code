// ─────────────────────────────────────────────────────────────────────────────
// THE SEAM NOBODY WAS TESTING.
//
// Three suites cover the SSE path and none of them cover the join between its
// two halves. The runner's tests exercise the Python emitter against Python
// assertions. This module's other tests exercise the parser against handwritten
// strings. The acceptance harness drives the real components against a
// handwritten SSE *double* — and that double shipped emitting `event: chunk`
// while this client dispatches on `log` and `end`, so the stream connected,
// delivered every byte, and displayed nothing. The spec still passed, because
// the client fell back to polling and the log filled anyway. Three green layers
// over an untested seam, and a wire-format mismatch hiding under all of them.
//
// So this file tests the client against bytes the REAL emitter actually wrote.
// `__fixtures__/sse-transcript.txt` was captured from
// `GET /api/demo/supercred/runs/{id}/stream` driven by a script chosen for the
// two cases that break naive implementations: a three-byte ✓ split across a
// pause in the child, and a final line with no trailing newline. The only edit
// is the run_id, replaced with a fixed value so the fixture is stable.
//
// If the emitter's wire format changes, this goes red — which is the point. The
// Python side has `test_the_transcript_this_client_is_tested_against_is_current`
// asserting the same fixture still matches what it emits, so neither half can
// drift without one of the two failing.
// ─────────────────────────────────────────────────────────────────────────────

import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { parseSseFrames, type DemoRunLogChunk, type DemoRunStreamEnd } from './demoRunner'

// Read from the package root rather than `import.meta.url`: this suite runs
// under jsdom, where `import.meta.url` is not a file: URL and readFileSync
// rejects it outright.
const TRANSCRIPT = readFileSync('src/api/__fixtures__/sse-transcript.txt', 'utf8')

/** What the captured run actually printed, reassembled. */
const EXPECTED_LOG = '[supercred] starting ✓\n[supercred] ✓ done\nno trailing newline'

/**
 * Drive the parser exactly as the transport does: bytes in, frames out, rest
 * carried forward. `chunkSize` forces the split points, because a frame
 * boundary landing mid-`data:` line is the routine case over a real socket and
 * the one a test that feeds the whole string at once can never produce.
 */
function replay(transcript: string, chunkSize: number) {
  const chunks: DemoRunLogChunk[] = []
  let end: DemoRunStreamEnd | undefined
  let buffer = ''
  for (let i = 0; i < transcript.length; i += chunkSize) {
    buffer += transcript.slice(i, i + chunkSize)
    const parsed = parseSseFrames(buffer)
    buffer = parsed.rest
    for (const frame of parsed.frames) {
      if (frame.event === 'log') chunks.push(JSON.parse(frame.data) as DemoRunLogChunk)
      else if (frame.event === 'end') end = JSON.parse(frame.data) as DemoRunStreamEnd
    }
  }
  return { chunks, end, leftover: buffer }
}

describe('the real emitter and the real parser agree', () => {
  it('reassembles the runner’s output from bytes the runner actually wrote', () => {
    const { chunks, end } = replay(TRANSCRIPT, TRANSCRIPT.length)
    expect(chunks.map(c => c.chunk).join('')).toBe(EXPECTED_LOG)
    expect(end?.eof).toBe(true)
    expect(end?.status).toBe('succeeded')
    expect(end?.exit_code).toBe(0)
  })

  it('names its events `log` and `end`, which is what this client dispatches on', () => {
    // Asserted directly against the transcript rather than through the parser,
    // so a rename on the Python side fails here with the actual wire text in
    // the diff instead of as an empty log somewhere downstream.
    expect(TRANSCRIPT).toContain('event: log\n')
    expect(TRANSCRIPT).toContain('event: end\n')
    expect(TRANSCRIPT).not.toContain('event: chunk\n')
  })

  it('advances the cursor with no gap and no repeat', () => {
    const { chunks, end } = replay(TRANSCRIPT, TRANSCRIPT.length)
    let cursor = 0
    for (const chunk of chunks) {
      expect(chunk.offset).toBe(cursor)
      cursor = chunk.next_offset
    }
    // The terminal frame carries no bytes and must not move the cursor, or a
    // caller resuming from it would re-read the tail it has already displayed.
    expect(end?.offset).toBe(cursor)
    expect(end?.next_offset).toBe(cursor)
  })

  it('holds a split multi-byte character back rather than replacing it', () => {
    // The capture script printed the first two bytes of ✓, paused, then the
    // third. The emitter must not have decoded that with errors="replace" — if
    // it did, U+FFFD is in the transcript and no client can undo it.
    expect(TRANSCRIPT).not.toContain('�')
    const { chunks } = replay(TRANSCRIPT, TRANSCRIPT.length)
    expect(chunks[0].chunk).toBe('[supercred] starting ')
    expect(chunks[1].chunk.startsWith('✓')).toBe(true)
  })

  it('parses identically however the socket happens to split the bytes', () => {
    // Every split point from one byte at a time upwards. A parser that assumes
    // a network read contains whole frames passes the single-shot case above
    // and fails here, which is the failure a real socket produces.
    for (const size of [1, 3, 7, 17, 64, 137, 512]) {
      const { chunks, end, leftover } = replay(TRANSCRIPT, size)
      expect(chunks.map(c => c.chunk).join(''), `split at ${size}`).toBe(EXPECTED_LOG)
      expect(end?.eof, `split at ${size}`).toBe(true)
      expect(leftover, `split at ${size}`).toBe('')
    }
  })

  it('drops keepalive comments without treating them as frames', () => {
    // The emitter writes `: keepalive\n\n` on an idle stream. A parser that
    // mistook one for a frame would hand `JSON.parse` an empty string and throw
    // in the middle of a demo, on the quietest part of a phase.
    const withKeepalive = ': keepalive\n\n' + TRANSCRIPT.replace(
      'event: end', ': keepalive\n\nevent: end',
    )
    const { chunks, end } = replay(withKeepalive, 5)
    expect(chunks.map(c => c.chunk).join('')).toBe(EXPECTED_LOG)
    expect(end?.eof).toBe(true)
  })
})
