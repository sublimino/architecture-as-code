import { useState, type CSSProperties } from 'react'

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
 */

export interface Proof {
  /** Short name for the tab — what this command is evidence OF. */
  label: string
  /** The literal command, verbatim and un-truncated, so it can be pasted. */
  command: string
  /** Raw output. */
  detail: string
}

export function ProofConsole({ proofs, testId }: { proofs: Proof[]; testId: string }) {
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
        <pre style={{ margin: '6px 0 0', whiteSpace: 'pre-wrap', wordBreak: 'break-word', color: 'var(--text)' }}>
          {current.detail || '(no output)'}
        </pre>
      </div>
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

const tabActive: CSSProperties = {
  // Border-and-text, not a filled pill: the amber/black fill this repo reached
  // for first is 4.06:1 in the Andy theme and fails AA.
  borderColor: 'var(--cyan)', color: 'var(--cyan)', fontWeight: 700,
}
