// ─────────────────────────────────────────────────────────────────────────────
// STREAMING LOG BLOCK — the demo runner's output, as it arrives.
//
// Instructor Controls used to render the run log as one `<pre>`: a grey wall
// that grew without limit, gave no sign it was still moving, and could only be
// read, never taken away. On stage that is three separate problems. A phase
// runs for minutes, so "is anything still happening?" is the question the
// instructor is actually asking; and when a phase fails, the log is the thing
// they want in a paste buffer, not on a screen behind them.
//
// So: line numbers (so a room can be pointed at a line), a reveal on each line
// as it lands, a caret on the last line while the run is live, a Copy button,
// and a hard bound on how many lines are in the DOM.
//
// THE REVEAL IS NOT A TIMER. Every line is rendered the instant the chunk
// carrying it lands, and lines are keyed by their absolute position in the
// stream — so a line React has already mounted is never remounted, and its
// entry animation therefore runs exactly once, when it genuinely arrived. A
// staggered or timed reveal would look better and would be a lie: it would
// report progress the runner has not made. If ten lines arrive in one chunk,
// ten lines appear at once, because that is what happened.
//
// PORTING NOTE. Same story as PixelLoader. The source was a Next.js +
// Tailwind demo with a hardcoded LINES array, a setTimeout loop that looped
// forever, and a hand-rolled TypeScript tokeniser. `"use client"` is inert
// under Vite, this app has no Tailwind, and `--accent-ink` / `--green` /
// `--ink-3` are tokens no theme here declares — referencing them would
// reproduce the `var(--card, #1a1a1a)` bug DemoToggle shipped with. Mapped to
// this app's real tokens (--cyan / --teal / --muted) and inline styles;
// src/styles/cssVarUsage.test.ts enforces that.
//
// COLOURING. Our content is shell output, not TypeScript, so there is no
// syntax to highlight and this does not pretend otherwise. What it does
// instead is re-derive the colour the runner ITSELF emitted and we then
// stripped: scripts/supercred-demo.sh writes `\033[1;36m[supercred]\033[0m`,
// `\033[1;32m[supercred] ✓\033[0m` and `\033[1;31m[supercred] FAILED:\033[0m`
// — prefix and marker coloured, message plain. Reproducing exactly those spans
// means the browser shows what a terminal shows, and nothing is being guessed
// about the rest of the line. Anything unrecognised renders plain.
// ─────────────────────────────────────────────────────────────────────────────

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties } from 'react'
import { usePrefersReducedMotion } from './PixelLoader'

// The lifecycle scripts colour terminal output with ANSI sequences. A browser
// renders those bytes literally, so they are removed for display only — the
// raw runner bytes and the offsets that index them are never modified, and
// Copy hands over the raw string.
// eslint-disable-next-line no-control-regex -- \u001B IS the escape byte this regex strips from runner log output; matching it literally is the point
const ANSI_SGR = /\u001B\[[0-?]*[ -/]*[@-~]/g

export function stripAnsi(log: string): string {
  return log.replace(ANSI_SGR, '')
}

/**
 * How many lines stay in the DOM.
 *
 * A full five-phase run is thousands of lines of kubectl and OpenBao output.
 * Every one of them as a live DOM node is an unbounded structure on a page
 * that must stay responsive for the length of a demo, and nobody scrolls back
 * two thousand lines in front of an audience — they press Copy. So the view is
 * a tail and the clipboard is the archive. The count is generous enough that a
 * whole phase's meaningful output fits.
 */
export const MAX_VISIBLE_LINES = 200

/** How long "Copied" stays up before the button offers itself again. */
const COPY_FEEDBACK_MS = 2000

export type LogTokenKind = 'time' | 'prefix' | 'ok' | 'error' | 'warn' | 'plain'

export interface LogToken {
  text: string
  kind: LogTokenKind
}

const TOKEN_COLOURS: Record<LogTokenKind, string> = {
  time: 'var(--muted)',
  prefix: 'var(--cyan)',
  ok: 'var(--teal)',
  error: 'var(--error)',
  warn: 'var(--amber)',
  plain: 'var(--text)',
}

/** A bracketed source tag — `[supercred]` and friends. */
const PREFIX = /^\[[A-Za-z][A-Za-z0-9_.-]*\]/
const PREFIX_ANYWHERE = /\[[A-Za-z][A-Za-z0-9_.-]*\]/

/**
 * Explicit timestamp shapes, for a line that carries a stamp but no tag —
 * `04:12:33 Error: no such entry` is what kubectl on stderr looks like once
 * something upstream starts stamping. Bare, bracketed or parenthesised;
 * ISO date optional; fractional seconds and zone optional.
 */
const CLOCK = String.raw`(?:\d{4}-\d{2}-\d{2}[T ])?\d{2}:\d{2}:\d{2}(?:[.,]\d{1,6})?(?:Z|[+-]\d{2}:?\d{2})?`
const ELAPSED = String.raw`\+?\d+(?:\.\d+)?m?s`
const TIMESTAMP = new RegExp(
  `^(?:\\[(?:${CLOCK}|${ELAPSED})\\]|\\((?:${CLOCK}|${ELAPSED})\\)|${CLOCK})\\s*`,
)

/**
 * Only these characters may sit between the head of a line and its tag for
 * that run to be called a timestamp. No letters except the T and Z that ISO
 * 8601 itself uses — which is what stops `pod/agent-cardvault [Ready] met`
 * from having "pod/agent-cardvault " recoloured as if it were a clock.
 */
const TIMESTAMP_SHAPED = /^[\d\s:.,+\-TZ()[\]]*$/

/**
 * How many characters at the head of the line are a timestamp.
 *
 * Written against the fact that we do not know the format. Timestamps are
 * being added to the runner's output by other work, and a tokeniser anchored
 * at position 0 fails SILENTLY when one appears: `[supercred]` stops being at
 * the head, the tag loses its colour, the marker after it loses its colour,
 * and every line renders plain. Nothing throws, nothing looks broken, the log
 * is simply monochrome from then on.
 *
 * So the tag is located rather than assumed, and whatever precedes it is
 * accepted as a stamp only if it is made of clock characters. That holds for
 * every format the runner could plausibly choose — ISO, bare clock, bracketed,
 * parenthesised, elapsed seconds — without this file needing to know which one
 * landed. A format outside all of it degrades to a plain line, which is what
 * the block already does with unrecognised output.
 */
export function leadingMetaLength(line: string): number {
  const tagAt = line.search(PREFIX_ANYWHERE)
  if (tagAt === 0) return 0
  if (tagAt > 0 && TIMESTAMP_SHAPED.test(line.slice(0, tagAt))) return tagAt
  return line.match(TIMESTAMP)?.[0].length ?? 0
}

/**
 * Status markers, matched only where the runner puts them: immediately after
 * the prefix (or at the head of a prefix-less line, which is what a bare
 * `Error: …` from kubectl on stderr looks like). Anchored, so the word
 * "failed" inside a sentence is not silently recoloured — a log that paints
 * arbitrary prose red is worse than one that paints nothing.
 */
const MARKERS: ReadonlyArray<readonly [RegExp, LogTokenKind]> = [
  [/^\s*(?:✓|✔|✅)/, 'ok'],
  [/^\s*(?:✗|✘|❌|FAILED:|ERROR:|Error:|error:)/, 'error'],
  [/^\s*(?:WARNING:|WARN:|warning:|!(?=\s))/, 'warn'],
]

/**
 * Split one line into coloured spans.
 *
 * Deliberately shallow: an optional timestamp, an optional tag, at most one
 * marker, and the rest verbatim. Every token is a slice of the input and the
 * tokens concatenate back to it exactly — nothing is dropped, reordered or
 * rewritten, so a timestamp arriving from elsewhere is displayed, not stripped.
 * Exported so the rules are testable without a DOM, and so the next person
 * adding a marker has one obvious place to add it.
 */
export function tokeniseLine(line: string): LogToken[] {
  const tokens: LogToken[] = []
  let rest = line

  const metaLength = leadingMetaLength(rest)
  if (metaLength > 0) {
    tokens.push({ text: rest.slice(0, metaLength), kind: 'time' })
    rest = rest.slice(metaLength)
  }

  const prefix = rest.match(PREFIX)
  if (prefix) {
    tokens.push({ text: prefix[0], kind: 'prefix' })
    rest = rest.slice(prefix[0].length)
  }

  for (const [pattern, kind] of MARKERS) {
    const marker = rest.match(pattern)
    if (!marker) continue
    tokens.push({ text: marker[0], kind })
    rest = rest.slice(marker[0].length)
    break
  }

  if (rest !== '') tokens.push({ text: rest, kind: 'plain' })
  // An empty line still needs a token, or the row renders as nothing and the
  // blank line the script printed disappears from the numbering.
  return tokens.length > 0 ? tokens : [{ text: '', kind: 'plain' }]
}

/**
 * The display lines, and how many were dropped off the front.
 *
 * A trailing newline is a line TERMINATOR, not an empty line — splitting on it
 * naively invents a blank final row that then carries the caret, which reads as
 * "the runner is producing nothing" when it is producing plenty. A log that
 * genuinely ends mid-line (the common case while streaming) keeps its partial
 * last line, because that partial line is the live edge.
 */
export function visibleLines(log: string, maxLines: number): { lines: string[]; hidden: number } {
  const all = stripAnsi(log).split('\n')
  if (all.length > 1 && all[all.length - 1] === '') all.pop()
  if (all.length <= maxLines) return { lines: all, hidden: 0 }
  return { lines: all.slice(all.length - maxLines), hidden: all.length - maxLines }
}

// Keyframes live with the component, as in PixelLoader: dropping this file into
// a page cannot leave it silently motionless because someone forgot the CSS,
// and global.css is a shared file that concurrent work is editing. `sl-`
// prefixed so the names cannot collide.
const KEYFRAMES = `
@keyframes sl-log-line-in {
  from { opacity: 0; transform: translateY(2px); }
  to   { opacity: 1; transform: none; }
}
@keyframes sl-log-caret {
  0%, 49%   { opacity: 1; }
  50%, 100% { opacity: 0; }
}
`

export interface StreamingLogBlockProps {
  /** Raw runner bytes, ANSI and all. Copy hands over exactly this. */
  log: string
  /** Whether output is still arriving — drives the caret, nothing else. */
  streaming?: boolean
  /**
   * What is producing this output — "Phase 4 · Stun", "Reset".
   *
   * The header of the component this is adapted from carried a filename and a
   * language. Neither exists here, and inventing one ("run.log", "Shell")
   * would be decoration that reads as fact. What an audience actually needs
   * named is which phase they are watching, so that is what the header says.
   */
  title?: string
  /** The run's own status word — `running`, `succeeded`, `failed`. */
  status?: string
  /**
   * Colour for the status word. Must be a `var(--token)` string: a bare hex
   * here fails src/styles/cssVarUsage.test.ts, and would be wrong in two of
   * the three themes anyway.
   */
  statusTone?: string
  /** Accessible name for the scroll region and the Copy button. */
  label?: string
  /**
   * What the body says while the log is empty and output is still expected.
   *
   * The block is now mounted when a run STARTS rather than when its first byte
   * lands, so there is a real interval — a slow first phase spends it inside
   * kubectl — where there is a block and nothing to put in it. Rendering the
   * empty log as-is produces one blank numbered row carrying the caret, which
   * reads as "the runner is producing nothing"; an empty bordered box is worse
   * than no box. This says what is actually true and claims nothing else: no
   * invented line, no fake timestamp, no progress figure.
   *
   * Omitted, the block behaves exactly as it did before this prop existed.
   */
  placeholder?: string
  testId?: string
  /** Override for the DOM bound. Present for tests; production uses the default. */
  maxLines?: number
  style?: CSSProperties
}

export default function StreamingLogBlock({
  log,
  streaming = false,
  title,
  status,
  statusTone = 'var(--muted)',
  label = 'Run log',
  placeholder,
  testId = 'streaming-log',
  maxLines = MAX_VISIBLE_LINES,
  style,
}: StreamingLogBlockProps) {
  const reducedMotion = usePrefersReducedMotion()
  const [copyState, setCopyState] = useState<'idle' | 'copied' | 'failed'>('idle')

  const { lines, hidden } = useMemo(() => visibleLines(log, maxLines), [log, maxLines])

  const scrollRef = useRef<HTMLDivElement | null>(null)
  // Pinned to the bottom unless the instructor has scrolled up to read
  // something — in which case new output must not yank the view away from
  // whatever they are reading. Re-pins as soon as they scroll back down.
  const pinnedRef = useRef(true)

  const onScroll = useCallback(() => {
    const el = scrollRef.current
    if (!el) return
    pinnedRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 24
  }, [])

  useLayoutEffect(() => {
    const el = scrollRef.current
    if (el && pinnedRef.current) el.scrollTop = el.scrollHeight
  }, [lines])

  const copy = useCallback(() => {
    void (async () => {
      try {
        // The RAW log: untailed and un-stripped. Whoever presses this is about
        // to paste it into a terminal, an issue or a message to us, and the
        // lines the tail dropped are exactly the ones that explain a failure
        // that started early. The escape bytes come along because they are what
        // the runner actually emitted, and a terminal renders them correctly.
        await navigator.clipboard.writeText(log)
        setCopyState('copied')
      } catch {
        // Clipboard access is refused outside a secure context and by some
        // policies. Saying so beats a button that silently does nothing.
        setCopyState('failed')
      }
    })()
  }, [log])

  useEffect(() => {
    if (copyState === 'idle') return
    const timer = setTimeout(() => setCopyState('idle'), COPY_FEEDBACK_MS)
    return () => clearTimeout(timer)
  }, [copyState])

  // Absolute position in the stream, so the numbers stay true under the tail
  // and — the load-bearing part — so React keys identify a LINE rather than a
  // slot. Keyed by slot, dropping a line off the front would shuffle every
  // remaining line into its neighbour's node, no node would be new, and the
  // reveal would stop firing entirely once the bound was reached.
  const firstLineNumber = hidden + 1

  return (
    <div data-testid={testId} style={{ ...block, ...style }}>
      <style>{KEYFRAMES}</style>

      <div style={header}>
        <span style={{ display: 'inline-flex', alignItems: 'baseline', gap: 8, minWidth: 0 }}>
          <span data-testid={`${testId}-title`} style={headerTitle}>
            {title ?? label}
          </span>
          {status && (
            <span data-testid={`${testId}-status`} style={{ ...headerStatus, color: statusTone }}>
              {status}
            </span>
          )}
        </span>
        <button
          type="button"
          className="btn btn-secondary"
          data-testid={`${testId}-copy`}
          data-copy-state={copyState}
          onClick={copy}
          aria-label={`Copy the full ${label.toLowerCase()} to the clipboard`}
          style={copyButton}
        >
          <CopyGlyph state={copyState} />
          {copyState === 'copied' ? 'Copied' : copyState === 'failed' ? 'Copy failed' : 'Copy'}
        </button>
      </div>

      {hidden > 0 && (
        <div data-testid={`${testId}-truncation`} style={truncationNote}>
          Showing the last {lines.length} lines. {hidden} earlier{' '}
          {hidden === 1 ? 'line is' : 'lines are'} off screen — Copy takes the whole log.
        </div>
      )}

      {/* Focusable and labelled: this scrolls, and a scrollable region that
          cannot be reached or named from the keyboard is unusable without a
          mouse. Not role="log" — that is a live region, and announcing every
          kubectl line during a demo is noise, not access. */}
      <div
        ref={scrollRef}
        onScroll={onScroll}
        role="region"
        aria-label={title ? `${label} — ${title}` : label}
        tabIndex={0}
        data-testid={`${testId}-scroll`}
        style={scroll}
      >
        {log === '' && placeholder !== undefined ? (
          // Deliberately not a numbered row: numbering it would assert that
          // line 1 of the runner's output exists and is blank. Nothing here
          // animates — a pulsing "waiting" is decoration that reads as
          // activity, and the activity indicator is PixelLoader's job.
          <div data-testid={`${testId}-waiting`} style={waiting}>
            {placeholder}
          </div>
        ) : lines.map((line, i) => {
          const number = firstLineNumber + i
          const isLast = i === lines.length - 1
          return (
            <div
              key={number}
              data-testid={`${testId}-line`}
              data-line={number}
              data-reveal={reducedMotion ? 'none' : 'fade'}
              style={{
                display: 'flex',
                gap: 10,
                ...(reducedMotion ? null : { animation: 'sl-log-line-in 180ms ease-out' }),
              }}
            >
              <span aria-hidden="true" style={gutter}>
                {number}
              </span>
              <span style={content}>
                {tokeniseLine(line).map((token, t) => (
                  <span key={t} data-kind={token.kind} style={{ color: TOKEN_COLOURS[token.kind] }}>
                    {token.text}
                  </span>
                ))}
                {streaming && isLast && (
                  // Solid rather than blinking under reduced motion: the caret
                  // says "the runner has not finished", which is information,
                  // and information does not have to flash to be readable.
                  <span
                    aria-hidden="true"
                    data-testid={`${testId}-caret`}
                    data-motion={reducedMotion ? 'static' : 'blinking'}
                    style={{
                      ...caret,
                      ...(reducedMotion ? null : { animation: 'sl-log-caret 1s step-end infinite' }),
                    }}
                  />
                )}
              </span>
            </div>
          )
        })}
      </div>
    </div>
  )
}

/**
 * The clipboard, and the tick that replaces it on success.
 *
 * currentColor throughout, so the glyph is whatever the button's text colour
 * already resolved to and no colour decision is duplicated here. aria-hidden
 * because the button's own label already says what state it is in — a screen
 * reader does not need the picture as well.
 */
function CopyGlyph({ state }: { state: 'idle' | 'copied' | 'failed' }) {
  return (
    <svg
      aria-hidden="true"
      data-testid="copy-glyph"
      data-glyph={state === 'copied' ? 'tick' : 'clipboard'}
      width="11"
      height="11"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      {state === 'copied' ? (
        <polyline points="3,8.5 6.5,12 13,4" />
      ) : (
        <>
          <rect x="5" y="2" width="9" height="11" rx="1.5" />
          <path d="M11 13v1a1.5 1.5 0 0 1-1.5 1.5H3.5A1.5 1.5 0 0 1 2 14V5.5A1.5 1.5 0 0 1 3.5 4H5" />
        </>
      )}
    </svg>
  )
}

// Measured across all three themes rather than eyeballed in whichever one the
// author had open — that is how DemoToggle shipped at 1.03:1.
//
// Three tiers, matching the source's card / bar / inset structure: the card
// behind this is --surface, the header bar is --surface2 (raised), the code
// body is --bg (inset). That the inset also happens to be the highest-contrast
// choice is the reason it is not merely cosmetic. Dark's --error — the single
// most important glyph in a failure log — is 3.03:1 on --surface2 and 3.70:1
// on --surface, but 4.18:1 on --bg, and every other token rises with it
// (--text 13.98 → 19.28, --cyan 6.03 → 8.31). --border-subtle rather than
// --border keeps the block delimited from the card it sits on.
//
// RESIDUAL, and it is not fixable here: even on --bg, --error tops out at
// 4.18:1 in Dark and --cyan / --amber at ~4.1-4.2:1 in Andy — all just under
// AA. Those are properties of the palettes in themes.ts, shared by every
// accent-coloured string in the app (ProofConsole, StatusBadge, the phase
// status chips), and inventing a brighter red here would put a bare hex in an
// inline style, which is the exact thing cssVarUsage.test.ts exists to stop.
// Nothing in this block encodes meaning in colour ALONE: the markers it
// colours are the literal text "FAILED:", "Error:" and "✓", which read the
// same in monochrome.
const block: CSSProperties = {
  borderRadius: 6,
  background: 'var(--surface)',
  border: '1px solid var(--border-subtle)',
  overflow: 'hidden',
}

const header: CSSProperties = {
  display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12,
  padding: '6px 10px', borderBottom: '1px solid var(--border-subtle)', background: 'var(--surface2)',
}

const headerTitle: CSSProperties = {
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  fontSize: 11, fontWeight: 600, color: 'var(--text)',
  overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
}

const headerStatus: CSSProperties = {
  fontSize: 10, fontWeight: 600, letterSpacing: '0.06em', textTransform: 'uppercase',
  flexShrink: 0,
}

const copyButton: CSSProperties = {
  fontSize: 11, padding: '2px 10px',
}

const truncationNote: CSSProperties = {
  padding: '4px 10px', fontSize: 10, color: 'var(--muted)',
  // Chrome, not content: it describes the body rather than being part of it,
  // so it stays on the header's surface and above the inset.
  background: 'var(--surface2)', borderBottom: '1px solid var(--border-subtle)',
}

const scroll: CSSProperties = {
  maxHeight: 260, overflow: 'auto', padding: '8px 10px',
  background: 'var(--bg)',
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  fontSize: 11, lineHeight: 1.55,
}

const gutter: CSSProperties = {
  flexShrink: 0, minWidth: 28, textAlign: 'right',
  // --muted, not --dim. The numbers exist so a room can be pointed at a line,
  // which only works if the room can read them: --dim is 4.24:1 against --bg
  // in Dark and 4.41:1 in Andy, both under AA; --muted clears it in all three
  // (7.87 / 7.58 / 7.37) and is still visibly subordinate to --text.
  color: 'var(--muted)', fontVariantNumeric: 'tabular-nums', userSelect: 'none',
}

const content: CSSProperties = {
  // pre-wrap keeps the script's own indentation; break-word stops a single
  // 300-character kubectl line from giving the whole block a horizontal
  // scrollbar nobody will find on a projector.
  whiteSpace: 'pre-wrap', wordBreak: 'break-word', minWidth: 0,
}

const waiting: CSSProperties = {
  // --muted, for the same reason the gutter uses it: subordinate to real
  // output but readable from the back of a room (7.87 / 7.58 / 7.37 against
  // --bg across the three themes). Italic so it is visibly not a log line.
  color: 'var(--muted)', fontStyle: 'italic',
}

const caret: CSSProperties = {
  display: 'inline-block', width: 6, height: '1em', marginLeft: 2,
  background: 'var(--cyan)', verticalAlign: 'text-bottom',
}
