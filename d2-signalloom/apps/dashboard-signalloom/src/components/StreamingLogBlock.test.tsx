/**
 * The streaming code block that renders the demo runner's output.
 *
 * The component is adapted from a Next.js + Tailwind demo, and the demo's
 * central mechanism is the thing that must NOT survive the port: it held a
 * hardcoded array of lines and revealed them one at a time on a setTimeout
 * loop. Here the lines are a live cluster's output arriving over HTTP, and a
 * timed reveal would report progress the runner has not made — an instructor
 * would read "3 of 9 lines" as "the script is on step 3" when the script has
 * already printed all nine and possibly failed. Several tests below exist
 * solely to kill that implementation if anyone reintroduces it.
 *
 * The rest pin the things that make the block usable rather than pretty: Copy
 * hands over the RAW log (the failure explaining a run usually scrolled off
 * the top long ago), the DOM stays bounded on a run that emits thousands of
 * lines, and nothing animates for someone who asked for no animation.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import StreamingLogBlock, {
  MAX_VISIBLE_LINES,
  stripAnsi,
  tokeniseLine,
  visibleLines,
} from './StreamingLogBlock'

/** Swap the global matchMedia stub for one that reports a given preference. */
function setReducedMotion(reduced: boolean) {
  const original = globalThis.matchMedia
  globalThis.matchMedia = ((query: string) => ({
    matches: reduced && query.includes('prefers-reduced-motion'),
    media: query,
    onchange: null,
    addListener: vi.fn(),
    removeListener: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    dispatchEvent: vi.fn(),
  })) as unknown as typeof globalThis.matchMedia
  return () => {
    globalThis.matchMedia = original
  }
}

/** jsdom has no clipboard at all, so one is installed and recorded. */
function stubClipboard(behaviour: 'ok' | 'refused' = 'ok') {
  const writeText = vi.fn(async (text: string) => {
    if (behaviour === 'refused') throw new Error(`clipboard blocked for ${text.length} bytes`)
  })
  Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true })
  return writeText
}

function lineNodes(testId = 'streaming-log'): HTMLElement[] {
  return screen.queryAllByTestId(`${testId}-line`)
}

/** What one rendered row says, gutter number excluded. */
function lineText(node: HTMLElement): string {
  return (node.lastElementChild?.textContent ?? '').trim()
}

const ESC = '\u001B'

beforeEach(() => {
  Object.defineProperty(navigator, 'clipboard', { value: undefined, configurable: true })
})

// ─── Pure helpers ─────────────────────────────────────────────────────────────

describe('stripAnsi', () => {
  it('removes the SGR sequences the lifecycle scripts emit', () => {
    expect(stripAnsi(`${ESC}[1;36m[supercred]${ESC}[0m tearing down\n`)).toBe('[supercred] tearing down\n')
  })

  it('leaves text with no escape bytes exactly as it was', () => {
    expect(stripAnsi('plain output\n')).toBe('plain output\n')
  })
})

describe('visibleLines', () => {
  it('treats a trailing newline as a terminator, not an empty final line', () => {
    // A blank final row would carry the caret, which reads as "the runner is
    // producing nothing" at precisely the moment it is producing plenty.
    expect(visibleLines('one\ntwo\n', 10)).toEqual({ lines: ['one', 'two'], hidden: 0 })
  })

  it('keeps a partial last line, because that is the live edge of the stream', () => {
    expect(visibleLines('one\ntw', 10)).toEqual({ lines: ['one', 'tw'], hidden: 0 })
  })

  it('reports how many lines the tail dropped', () => {
    const log = Array.from({ length: 5 }, (_, i) => `line ${i + 1}`).join('\n')
    expect(visibleLines(log, 2)).toEqual({ lines: ['line 4', 'line 5'], hidden: 3 })
  })
})

describe('tokeniseLine', () => {
  // The rule is "reproduce the spans the runner itself coloured", not "guess".
  // scripts/supercred-demo.sh colours prefix and marker and leaves the message
  // plain; these assert exactly that split.
  it('colours the bracketed source tag and leaves the message plain', () => {
    expect(tokeniseLine('[supercred] deploying the agent')).toEqual([
      { text: '[supercred]', kind: 'prefix' },
      { text: ' deploying the agent', kind: 'plain' },
    ])
  })

  it('colours a success tick without colouring what it succeeded at', () => {
    expect(tokeniseLine('[supercred] ✓ credential chain complete')).toEqual([
      { text: '[supercred]', kind: 'prefix' },
      { text: ' ✓', kind: 'ok' },
      { text: ' credential chain complete', kind: 'plain' },
    ])
  })

  it('marks a FAILED: line as an error', () => {
    expect(tokeniseLine('[supercred] FAILED: no such SPIRE entry')).toEqual([
      { text: '[supercred]', kind: 'prefix' },
      { text: ' FAILED:', kind: 'error' },
      { text: ' no such SPIRE entry', kind: 'plain' },
    ])
  })

  it('marks a bare stderr error line, which carries no prefix at all', () => {
    expect(tokeniseLine('Error: no such entry')).toEqual([
      { text: 'Error:', kind: 'error' },
      { text: ' no such entry', kind: 'plain' },
    ])
  })

  it('marks a warning', () => {
    expect(tokeniseLine('[supercred] ! the pod is still terminating')).toEqual([
      { text: '[supercred]', kind: 'prefix' },
      { text: ' !', kind: 'warn' },
      { text: ' the pod is still terminating', kind: 'plain' },
    ])
  })

  it('does not recolour prose that merely contains a marker word', () => {
    // A log that paints arbitrary sentences red is worse than one that paints
    // nothing: the instructor stops believing the colour.
    expect(tokeniseLine('[supercred] the previous run failed, cleaning up')).toEqual([
      { text: '[supercred]', kind: 'prefix' },
      { text: ' the previous run failed, cleaning up', kind: 'plain' },
    ])
  })

  it('leaves an unrecognised line entirely plain', () => {
    expect(tokeniseLine('pod/agent-cardvault condition met')).toEqual([
      { text: 'pod/agent-cardvault condition met', kind: 'plain' },
    ])
  })

  // Every token is a slice of the input and nothing is dropped, reordered or
  // rewritten. This is what makes it safe to tokenise output whose format we
  // do not control: the worst a rule can do is colour the wrong span, never
  // change what the line SAYS.
  it('reassembles every line it splits, byte for byte', () => {
    const lines = [
      '[supercred] ✓ credential chain complete',
      '2026-08-13T04:12:33Z [supercred] FAILED: no such entry',
      '   indented kubectl output',
      '',
      'Error: no such entry',
      '04:12:33.123 pod/agent-cardvault condition met',
    ]
    for (const line of lines) {
      expect(tokeniseLine(line).map(t => t.text).join('')).toBe(line)
    }
  })
})

// ─── Timestamps added by other work ───────────────────────────────────────────

// Timestamps are being added to the runner's output elsewhere. A tokeniser
// anchored at position 0 fails SILENTLY when one lands: `[supercred]` is no
// longer at the head, so the tag loses its colour, the marker after it loses
// its colour, and every line goes monochrome. Nothing throws and nothing looks
// broken — it just stops working. These pin the formats a shell script or a
// Python runner would plausibly emit, and the fact that the stamp is DISPLAYED
// rather than stripped.
describe('a leading timestamp does not disarm the colouring', () => {
  const stamped: [string, string][] = [
    ['ISO with a zone', '2026-08-13T04:12:33Z '],
    ['ISO with an offset', '2026-08-13T04:12:33+01:00 '],
    ['ISO with millis', '2026-08-13 04:12:33.123 '],
    ['bare clock', '04:12:33 '],
    ['bracketed clock', '[04:12:33] '],
    ['parenthesised clock', '(04:12:33) '],
    ['bracketed elapsed', '[+12.4s] '],
  ]

  for (const [name, stamp] of stamped) {
    it(`keeps the tag and the marker coloured behind a ${name}`, () => {
      const tokens = tokeniseLine(`${stamp}[supercred] ✓ credential chain complete`)
      expect(tokens).toEqual([
        { text: stamp, kind: 'time' },
        { text: '[supercred]', kind: 'prefix' },
        { text: ' ✓', kind: 'ok' },
        { text: ' credential chain complete', kind: 'plain' },
      ])
    })
  }

  it('colours the marker on a stamped line that carries no tag', () => {
    expect(tokeniseLine('04:12:33 Error: no such entry')).toEqual([
      { text: '04:12:33 ', kind: 'time' },
      { text: 'Error:', kind: 'error' },
      { text: ' no such entry', kind: 'plain' },
    ])
  })

  it('displays the timestamp rather than stripping it', () => {
    render(<StreamingLogBlock log={'2026-08-13T04:12:33Z [supercred] deploying\n'} />)
    expect(screen.getByTestId('streaming-log')).toHaveTextContent(
      '2026-08-13T04:12:33Z [supercred] deploying',
    )
  })

  it('will not read prose before a bracketed word as if it were a clock', () => {
    // Only clock characters may precede a tag. Otherwise the first bracketed
    // word in any sentence would grey out everything before it.
    expect(tokeniseLine('pod/agent-cardvault [Ready] condition met')).toEqual([
      { text: 'pod/agent-cardvault [Ready] condition met', kind: 'plain' },
    ])
  })
})

// ─── The reveal follows the stream, not a clock ───────────────────────────────

describe('the reveal is driven by arriving chunks, never by a timer', () => {
  it('shows every line the log already carries, in the same tick', () => {
    // Synchronous on purpose — no waitFor, no timer advance. A staggered or
    // timed reveal shows one line here and fails.
    render(<StreamingLogBlock log={'[supercred] one\n[supercred] two\n[supercred] three\n'} />)
    expect(lineNodes()).toHaveLength(3)
    expect(lineText(lineNodes()[2])).toBe('[supercred] three')
  })

  it('gains a line when, and only when, the log gains one', async () => {
    const chunk1 = 'step 1: deploy\ndeleting the previous run\napplying NetworkPolicy\n'
    const { rerender } = render(<StreamingLogBlock log={chunk1} streaming />)
    expect(lineNodes()).toHaveLength(3)

    // Real elapsed time with no new chunk. A self-driving reveal would have
    // moved by now, in either direction; a chunk-driven one cannot.
    await new Promise(resolve => setTimeout(resolve, 300))
    expect(lineNodes()).toHaveLength(3)

    rerender(<StreamingLogBlock log={`${chunk1}registering SPIRE entry\n`} streaming />)
    expect(lineNodes()).toHaveLength(4)
    expect(lineText(lineNodes()[3])).toBe('registering SPIRE entry')
  })

  it('extends the live edge in place as a partial line completes', () => {
    // The runner flushes mid-line constantly. A partial line must grow, not
    // spawn a second row.
    const { rerender } = render(<StreamingLogBlock log={'registering SPIRE ent'} streaming />)
    expect(lineNodes()).toHaveLength(1)

    rerender(<StreamingLogBlock log={'registering SPIRE entry\n'} streaming />)
    expect(lineNodes()).toHaveLength(1)
    expect(lineText(lineNodes()[0])).toBe('registering SPIRE entry')
  })

  it('numbers lines by absolute stream position, so the numbers survive the tail', () => {
    const log = Array.from({ length: MAX_VISIBLE_LINES + 5 }, (_, i) => `line ${i + 1}`).join('\n') + '\n'
    render(<StreamingLogBlock log={log} />)
    const nodes = lineNodes()
    expect(nodes[0].getAttribute('data-line')).toBe('6')
    expect(nodes[nodes.length - 1].getAttribute('data-line')).toBe(String(MAX_VISIBLE_LINES + 5))
  })

  it('strips the escape bytes it displays', () => {
    render(<StreamingLogBlock log={`${ESC}[1;36m[supercred]${ESC}[0m tearing down\n`} />)
    expect(screen.getByTestId('streaming-log')).toHaveTextContent('[supercred] tearing down')
    expect(screen.getByTestId('streaming-log')).not.toHaveTextContent(ESC)
  })
})

// ─── The caret ────────────────────────────────────────────────────────────────

describe('the caret says whether output is still coming', () => {
  it('sits on the last line while the run streams', () => {
    render(<StreamingLogBlock log={'one\ntwo\n'} streaming />)
    const caret = screen.getByTestId('streaming-log-caret')
    expect(lineNodes()[1]).toContainElement(caret)
  })

  it('is gone once the run is over, so a finished log does not look live', () => {
    render(<StreamingLogBlock log={'one\ntwo\n'} streaming={false} />)
    expect(screen.queryByTestId('streaming-log-caret')).toBeNull()
  })
})

// ─── Copy ─────────────────────────────────────────────────────────────────────

describe('Copy hands over the raw log', () => {
  it('copies the untailed log, including the lines the view dropped', async () => {
    const writeText = stubClipboard()
    // Long enough that the head is off screen — which is exactly where the
    // first failure of a long run is.
    const log =
      '[supercred] FAILED: could not reach OpenBao\n' +
      Array.from({ length: MAX_VISIBLE_LINES + 50 }, (_, i) => `noise ${i}`).join('\n') +
      '\n'
    render(<StreamingLogBlock log={log} />)

    await userEvent.click(screen.getByTestId('streaming-log-copy'))

    expect(writeText).toHaveBeenCalledTimes(1)
    expect(writeText.mock.calls[0][0]).toBe(log)
  })

  it('copies the escape bytes verbatim rather than the stripped display text', async () => {
    // The clipboard is for a terminal, an issue or a message to us; the bytes
    // the runner actually emitted are the honest artefact, and a terminal
    // renders them correctly.
    const writeText = stubClipboard()
    const log = `${ESC}[1;31m[supercred] FAILED:${ESC}[0m no such SPIRE entry\n`
    render(<StreamingLogBlock log={log} />)

    await userEvent.click(screen.getByTestId('streaming-log-copy'))

    expect(writeText.mock.calls[0][0]).toBe(log)
    expect(writeText.mock.calls[0][0]).not.toBe(stripAnsi(log))
  })

  it('confirms the copy, so the instructor knows it landed', async () => {
    stubClipboard()
    render(<StreamingLogBlock log={'one\n'} />)
    await userEvent.click(screen.getByTestId('streaming-log-copy'))
    await waitFor(() => expect(screen.getByTestId('streaming-log-copy')).toHaveTextContent('Copied'))
  })

  it('says so when the browser refuses the clipboard', async () => {
    // Refused outside a secure context and by some enterprise policies. A
    // button that silently does nothing is worse than one that admits it.
    stubClipboard('refused')
    render(<StreamingLogBlock log={'one\n'} />)
    await userEvent.click(screen.getByTestId('streaming-log-copy'))
    await waitFor(() => expect(screen.getByTestId('streaming-log-copy')).toHaveTextContent('Copy failed'))
  })
})

// ─── Bounded DOM ──────────────────────────────────────────────────────────────

describe('the DOM stays bounded on a long run', () => {
  it('keeps at most MAX_VISIBLE_LINES rows however much the runner prints', () => {
    const log = Array.from({ length: 2000 }, (_, i) => `line ${i + 1}`).join('\n') + '\n'
    render(<StreamingLogBlock log={log} />)
    expect(lineNodes()).toHaveLength(MAX_VISIBLE_LINES)
  })

  it('keeps the newest output and drops the oldest', () => {
    const log = Array.from({ length: 2000 }, (_, i) => `line ${i + 1}`).join('\n') + '\n'
    render(<StreamingLogBlock log={log} />)
    const nodes = lineNodes()
    expect(lineText(nodes[nodes.length - 1])).toBe('line 2000')
    expect(lineText(nodes[0])).toBe(`line ${2000 - MAX_VISIBLE_LINES + 1}`)
  })

  it('says the earlier lines are off screen and that Copy still has them', () => {
    const log = Array.from({ length: 2000 }, (_, i) => `line ${i + 1}`).join('\n') + '\n'
    render(<StreamingLogBlock log={log} />)
    expect(screen.getByTestId('streaming-log-truncation')).toHaveTextContent(
      `${2000 - MAX_VISIBLE_LINES} earlier lines are off screen`,
    )
  })

  it('says nothing about truncation when nothing is truncated', () => {
    render(<StreamingLogBlock log={'one\ntwo\n'} />)
    expect(screen.queryByTestId('streaming-log-truncation')).toBeNull()
  })
})

// ─── Reduced motion ───────────────────────────────────────────────────────────

describe('prefers-reduced-motion: reduce', () => {
  let restore = () => {}
  afterEach(() => restore())

  it('reveals lines with no animation at all', () => {
    restore = setReducedMotion(true)
    render(<StreamingLogBlock log={'one\ntwo\n'} streaming />)
    for (const node of lineNodes()) {
      expect(node.getAttribute('data-reveal')).toBe('none')
      expect(node.style.animation).toBe('')
    }
  })

  it('keeps the caret solid rather than blinking — it still means "not finished"', () => {
    restore = setReducedMotion(true)
    render(<StreamingLogBlock log={'one\n'} streaming />)
    const caret = screen.getByTestId('streaming-log-caret')
    expect(caret.getAttribute('data-motion')).toBe('static')
    expect(caret.style.animation).toBe('')
  })

  it('still shows every line — reduced motion removes animation, not content', () => {
    restore = setReducedMotion(true)
    render(<StreamingLogBlock log={'one\ntwo\nthree\n'} />)
    expect(lineNodes()).toHaveLength(3)
  })

  it('animates when no such preference is expressed', () => {
    restore = setReducedMotion(false)
    render(<StreamingLogBlock log={'one\n'} streaming />)
    expect(lineNodes()[0].getAttribute('data-reveal')).toBe('fade')
    expect(lineNodes()[0].style.animation).toContain('sl-log-line-in')
    expect(screen.getByTestId('streaming-log-caret').style.animation).toContain('sl-log-caret')
  })
})

// ─── The header says something true ───────────────────────────────────────────

describe('the header names the run, not a filename', () => {
  // The component this is adapted from headed its block with `churn.ts` and
  // `TypeScript`. There is no file and no language here, and inventing one
  // would be decoration that reads as fact.
  it('names the phase being run and its status', () => {
    render(<StreamingLogBlock log={'one\n'} title="Phase 4 · Stun" status="running" />)
    expect(screen.getByTestId('streaming-log-title')).toHaveTextContent('Phase 4 · Stun')
    expect(screen.getByTestId('streaming-log-status')).toHaveTextContent('running')
  })

  it('colours the status with the tone it was given', () => {
    render(<StreamingLogBlock log={'one\n'} title="Phase 4" status="failed" statusTone="var(--error)" />)
    expect(screen.getByTestId('streaming-log-status').style.color).toBe('var(--error)')
  })

  it('falls back to the accessible name when no run is known', () => {
    render(<StreamingLogBlock log={'one\n'} />)
    expect(screen.getByTestId('streaming-log-title')).toHaveTextContent('Run log')
    expect(screen.queryByTestId('streaming-log-status')).toBeNull()
  })
})

// ─── Copy affordance ──────────────────────────────────────────────────────────

describe('Copy shows a tick when it worked', () => {
  it('swaps the clipboard glyph for a tick on success', async () => {
    stubClipboard()
    render(<StreamingLogBlock log={'one\n'} />)
    const glyph = () => screen.getByTestId('copy-glyph').getAttribute('data-glyph')
    expect(glyph()).toBe('clipboard')

    await userEvent.click(screen.getByTestId('streaming-log-copy'))
    await waitFor(() => expect(glyph()).toBe('tick'))
  })

  it('keeps the clipboard glyph when the copy was refused', async () => {
    stubClipboard('refused')
    render(<StreamingLogBlock log={'one\n'} />)
    await userEvent.click(screen.getByTestId('streaming-log-copy'))
    await waitFor(() => expect(screen.getByTestId('streaming-log-copy')).toHaveTextContent('Copy failed'))
    expect(screen.getByTestId('copy-glyph').getAttribute('data-glyph')).toBe('clipboard')
  })
})

// ─── No replay ────────────────────────────────────────────────────────────────

describe('the view never rewinds', () => {
  // The source component's timer reset its counter to 0 after a hold and
  // replayed the whole thing, forever. That is a marketing loop. An instructor
  // watching a real run must never see the log restart — they would read the
  // replay as a second run, or as the script retrying.
  it('only ever grows as the run proceeds, and holds when it ends', async () => {
    const chunks = [
      '[supercred] step 1\n',
      '[supercred] step 1\n[supercred] step 2\n',
      '[supercred] step 1\n[supercred] step 2\n[supercred] ✓ done\n',
    ]
    const { rerender } = render(<StreamingLogBlock log={chunks[0]} streaming />)
    let seen = lineNodes().length

    for (const chunk of chunks.slice(1)) {
      rerender(<StreamingLogBlock log={chunk} streaming />)
      expect(lineNodes().length).toBeGreaterThanOrEqual(seen)
      seen = lineNodes().length
    }

    // The run ends. Nothing may restart, replay or clear.
    rerender(<StreamingLogBlock log={chunks[2]} streaming={false} />)
    await new Promise(resolve => setTimeout(resolve, 350))
    expect(lineNodes()).toHaveLength(3)
    expect(lineText(lineNodes()[2])).toBe('[supercred] ✓ done')
  })
})

// ─── Accessibility ────────────────────────────────────────────────────────────

describe('the block is reachable without a mouse', () => {
  it('names the scroll region and puts it in the tab order', () => {
    render(<StreamingLogBlock log={'one\n'} label="Run log" />)
    const region = screen.getByRole('region', { name: 'Run log' })
    expect(region).toHaveAttribute('tabindex', '0')
  })

  it('adds the run to the region name when there is one', () => {
    render(<StreamingLogBlock log={'one\n'} label="Run log" title="Phase 4 · Stun" />)
    expect(screen.getByRole('region', { name: 'Run log — Phase 4 · Stun' })).toBeInTheDocument()
  })

  it('gives Copy a label that says what it copies', () => {
    render(<StreamingLogBlock log={'one\n'} label="Run log" />)
    expect(screen.getByTestId('streaming-log-copy')).toHaveAccessibleName(
      'Copy the full run log to the clipboard',
    )
  })
})
