import { useState, type CSSProperties } from 'react'
import PixelLoader from './PixelLoader'

/**
 * The "how do we know?" console — one or more commands, and what they printed.
 *
 * Shared deliberately. The Credential Lifecycle card and the Credential
 * Inventory page both make claims about the same credential chain at different
 * altitudes, and a viewer who opens the proof on one and then the other should
 * not have to learn two consoles. One component also means one place where the
 * rule "show the command, verbatim, un-truncated" is enforced.
 *
 * Several proofs render as tabs rather than a stack: a verdict that rests on
 * three commands has a PRIMARY one (the mechanism) and the rest corroborate it,
 * and a stack flattens that ordering into "here is a wall of output". The first
 * tab is the primary proof and opens selected. With a single proof there are no
 * tabs at all — a tab strip with one tab is furniture, not information.
 *
 * INCREMENTAL OUTPUT. A proof whose command is still running is a different
 * claim from one that finished, and rendering them identically is the failure
 * worth designing against: a half-collected proof that looks complete is a
 * viewer reading a partial answer as the whole answer. `Proof.stream` says
 * which, and it is optional — omit it and this renders exactly what it always
 * did, which is what every current caller gets. There is deliberately no
 * transport in here: this component is handed a string that grew, and does not
 * care whether the caller grew it by polling, by a socket or from a fixture.
 * See DesignSystemPage's streaming section for the worked example, and
 * StreamingLogBlock for the heavier treatment (line numbers, a tail bound and
 * Copy) that a full multi-thousand-line run log needs instead of this.
 */

/**
 * Where a streaming proof is up to.
 *
 * Three, not four. `stalled` covers every way output stops arriving without
 * finishing — the process died, the poll 404'd, nothing has been emitted for
 * long enough that we will not claim it is still working — because the
 * treatment is identical in all of them and `streamNote` says which one it was.
 * Splitting it into `failed` and `stalled` would be two near-identical branches
 * that drift, which is the mistake this codebase has already paid for twice.
 */
export type ProofStreamPhase = 'streaming' | 'complete' | 'stalled'

export interface Proof {
  /** Short name for the tab — what this command is evidence OF. */
  label: string
  /** The literal command, verbatim and un-truncated, so it can be pasted. */
  command: string
  /** Raw output. */
  detail: string
  /**
   * Whether this output is still arriving. Omit for a finished, static proof.
   *
   * Absent and `'complete'` render the same body; the difference is that
   * `'complete'` states the stream closed, which only means something if the
   * viewer watched it open.
   */
  stream?: ProofStreamPhase
  /** Why a stalled stream stopped. Shown only when `stream` is `'stalled'`. */
  streamNote?: string
}

export function ProofConsole({
  proofs,
  testId,
  announce = false,
}: {
  proofs: Proof[]
  testId: string
  /**
   * Whether to announce stream phase changes to a screen reader.
   *
   * Default false, and that default is the whole point: the console body is
   * never a live region under any setting, because an auto-appending log
   * wrapped in one is read out line by line over whatever the user was doing.
   * What this opts into is a single polite region carrying the phase word and
   * nothing else, which is the one part a caret cannot convey — a stream that
   * quietly stops looks, without sound, exactly like one that is still going.
   *
   * Off by default so that adding streaming to a page is never accidentally
   * also adding a region to a page that already has one. Pass it on the
   * console that is the primary thing the user is waiting for, and leave it off
   * everywhere else.
   */
  announce?: boolean
}) {
  const [active, setActive] = useState(0)
  // A re-check can shorten the proof list while a later tab is selected, and an
  // out-of-range index would render an empty console that looks like a probe
  // returning nothing. Clamp rather than reset: the first proof is the primary
  // one, so falling back to it is always meaningful.
  const index = active < proofs.length ? active : 0
  const current = proofs[index]

  if (!current) {
    return (
      <div data-testid={testId} style={consoleBox}>
        <div style={{ color: 'var(--muted)' }}>(no proof was recorded for this step)</div>
      </div>
    )
  }

  return (
    <div data-testid={testId} style={consoleBox}>
      {proofs.length > 1 && (
        <div role="tablist" aria-label="Proofs" style={tabStrip}>
          {proofs.map((proof, i) => (
            <button
              key={`${proof.label}-${i}`}
              type="button"
              role="tab"
              aria-selected={i === index}
              data-testid={`${testId}-tab-${i}`}
              onClick={() => setActive(i)}
              style={{ ...tab, ...(i === index ? tabActive : {}) }}
            >
              {proof.label || `Proof ${i + 1}`}
            </button>
          ))}
        </div>
      )}
      <div role={proofs.length > 1 ? 'tabpanel' : undefined} data-testid={`${testId}-panel`}>
        {/* A <pre>, not a <div>: a proof can be more than one command (revoking
            a credential is two Bao calls), and collapsing those onto one line
            produces something that cannot be pasted and rerun. */}
        <pre style={{ margin: 0, whiteSpace: 'pre-wrap', wordBreak: 'break-word', color: 'var(--cyan)' }}>
          $ {current.command}
        </pre>
        {/* Its own testid, not just the panel's: while a stream is open this is
            the element that changes, and an assertion scoped to the panel is
            really an assertion about the command and the status row too. */}
        <pre
          data-testid={`${testId}-detail`}
          style={{ margin: '6px 0 0', whiteSpace: 'pre-wrap', wordBreak: 'break-word', color: 'var(--text)' }}
        >
          {/* While a stream is open, empty means "nothing yet", not "this
              command printed nothing" — and "(no output)" is a verdict. */}
          {current.detail || (current.stream === 'streaming' ? '' : '(no output)')}
        </pre>
        {current.stream && <StreamStatus phase={current.stream} note={current.streamNote} testId={testId} />}
      </div>
      {announce && current.stream && (
        // Visually hidden rather than a second on-screen line: the loader and
        // the phase word above already say this to anyone who can see them, and
        // a duplicate sentence is clutter. It is a SIBLING of the status row,
        // not a wrapper around it, because PixelLoader rewrites its elapsed
        // figure ten times a second — a region wrapping that announces ten
        // times a second. And it is mounted for every phase rather than created
        // on completion: a live region born at the same instant as its content
        // is announced unreliably or not at all.
        <span className="sr-only" role="status" aria-live="polite" data-testid={`${testId}-stream-announce`}>
          {ANNOUNCEMENTS[current.stream]}
        </span>
      )}
    </div>
  )
}

const ANNOUNCEMENTS: Record<ProofStreamPhase, string> = {
  streaming: 'Collecting proof. Output is still arriving.',
  complete: 'Proof complete. The command finished and the output below is all of it.',
  stalled: 'Proof stopped early. The output below is incomplete.',
}

/**
 * The line under the output that says whether there is more coming.
 *
 * Never colour alone, and here that is a contrast finding rather than a
 * principle. Measured against themes.ts on this console's --surface2 body:
 * --teal is 5.77 / 5.01 / 7.45 across Dark, Light and Andy and clears AA
 * everywhere, but --error is 5.91 in Light and 4.89 in Andy and only 3.03:1 in
 * Dark — under AA for a 10px bold word, on the one state a viewer must not
 * miss. That figure is a property of the palette, not of this file: --cyan on
 * the same surface is 3.79:1 in Andy, so the command line directly above has
 * always sat there too, and StreamingLogBlock records the same residual after
 * moving its body to the highest-contrast token available. Raising it means
 * changing themes.ts, which is shared.
 *
 * So the meaning is carried by the literal word "Stopped", which reads
 * identically at 3:1, in monochrome and on a projector, and the colour only
 * reinforces it. A coloured dot would have put the whole signal in the channel
 * that is failing.
 */
function StreamStatus({ phase, note, testId }: { phase: ProofStreamPhase; note?: string; testId: string }) {
  return (
    <div data-testid={`${testId}-stream`} data-stream={phase} style={streamRow}>
      {phase === 'streaming' ? (
        // The house wait treatment, at the size that sits inside a line. It
        // counts elapsed seconds, which is the entire reason it beats a caret
        // here: a stream that has produced nothing for ninety seconds is
        // probably not going to, and the figure is what tells you that.
        // announce={false} without exception — this component's own region
        // above is the one that speaks, and two nested regions read twice.
        <PixelLoader
          size="sm"
          variant="Loom"
          label="Streaming"
          announce={false}
          testId={`${testId}-stream-wait`}
        />
      ) : (
        <span style={{ ...streamWord, color: phase === 'complete' ? 'var(--teal)' : 'var(--error)' }}>
          {phase === 'complete' ? 'Complete' : 'Stopped'}
        </span>
      )}
      {phase === 'stalled' && note && (
        <span data-testid={`${testId}-stream-note`} style={{ color: 'var(--muted)' }}>
          {note}
        </span>
      )}
    </div>
  )
}

const consoleBox: CSSProperties = {
  marginTop: 8, padding: '8px 10px', borderRadius: 4,
  // --surface2 with --text is the pairing the theme guarantees contrast for;
  // a hardcoded slate console rendered 1.03:1 against the light theme's text
  // when this repo last hardcoded a panel colour.
  background: 'var(--surface2)', border: '1px solid var(--border)',
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  fontSize: 10, lineHeight: 1.5, overflowX: 'auto',
}

const tabStrip: CSSProperties = {
  display: 'flex', gap: 4, flexWrap: 'wrap',
  marginBottom: 8, paddingBottom: 6, borderBottom: '1px solid var(--border)',
}

const tab: CSSProperties = {
  fontSize: 10, padding: '3px 8px', borderRadius: 4, cursor: 'pointer',
  // Long-hand, not the `border` shorthand: the selected tab overrides only the
  // colour, and React warns (correctly) that mixing the two drops the shorthand
  // on re-render — which would leave a tab with no border at all mid-switch.
  borderWidth: 1, borderStyle: 'solid', borderColor: 'var(--border)',
  background: 'transparent', color: 'var(--muted)', fontFamily: 'inherit',
}

const streamRow: CSSProperties = {
  display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap',
  marginTop: 8, paddingTop: 6, borderTop: '1px solid var(--border)',
}

const streamWord: CSSProperties = {
  fontWeight: 700, letterSpacing: '0.06em', textTransform: 'uppercase', fontSize: 10,
}

const tabActive: CSSProperties = {
  // Border-and-text, not a filled pill: the amber/black fill this repo reached
  // for first is 4.06:1 in the Andy theme and fails AA.
  borderColor: 'var(--cyan)', color: 'var(--cyan)', fontWeight: 700,
}
