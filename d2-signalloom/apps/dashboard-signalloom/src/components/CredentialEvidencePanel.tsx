import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import HelpHint from './HelpHint'
import {
  EVIDENCE_ENDPOINT,
  evidenceSummary,
  parseEvidence,
  type CredentialEvidence,
  type EvidenceState,
  type EvidenceStep,
} from '../api/credentialEvidence'
import ButtonWait from './ButtonWait'
import PixelLoader from './PixelLoader'
import { ProofConsole } from './ProofConsole'

// One card, two audiences.
//
// An executive reads the headline sentence and the six coloured rows and learns
// whether the credential chain is real. An engineer opens a row and gets the
// literal command that decided it plus the raw output, so they can paste it into
// a terminal and disagree with us. Same data, same request, no second source of
// truth — the identical script backs `make demo-signalloom-supercred-evidence`.
//
// The card this replaces derived all six steps from `!!agent.id` and printed
// hardcoded timestamps, so it showed everything completed the instant an agent
// existed. Nothing here renders progress without a probe behind it.

const STATE_STYLE: Record<EvidenceState, { label: string; bg: string; border: string; dot: string }> = {
  // Deliberately not green/red/grey by "goodness": these encode EPISTEMIC
  // status, not desirability. `absent` is often the correct and expected state
  // (no stun yet), so it must not read as failure.
  observed: { label: 'observed', bg: 'rgba(34,197,94,0.10)', border: 'rgba(34,197,94,0.35)', dot: '#22c55e' },
  absent: { label: 'not present', bg: 'rgba(148,163,184,0.10)', border: 'rgba(148,163,184,0.30)', dot: '#94a3b8' },
  unavailable: { label: 'unverified', bg: 'rgba(245,158,11,0.10)', border: 'rgba(245,158,11,0.35)', dot: '#f59e0b' },
}

/**
 * What a failed request MEANS, not just what it returned.
 *
 * "Evidence unavailable (HTTP 500)" and "Evidence unavailable (HTTP 401)" read
 * as the same sentence with a different number, and they are not remotely the
 * same event: one says the platform is broken, the other says it would not let
 * you look. An operator in front of an audience has to tell them apart at a
 * glance. The status code stays in the text — an engineer still needs it — but
 * it no longer carries the whole meaning on its own.
 *
 * None of these are findings about the credential chain, which is why every
 * `detail` says so in its own words.
 */
function describeFailure(status: number): { title: string; detail: string } {
  if (status === 401) {
    return {
      title: 'The platform did not accept this session (HTTP 401)',
      detail: 'Your sign-in was rejected, so no probe was ever run. Sign in again, then re-check.',
    }
  }
  if (status === 403) {
    return {
      title: 'This session is not permitted to read the evidence (HTTP 403)',
      detail: 'The sign-in was accepted but refused. Check which tenant this session belongs to. The cluster was never queried.',
    }
  }
  if (status === 404) {
    return {
      title: `The evidence probe could not be reached (HTTP ${status})`,
      detail: 'The request never arrived at the service that runs the probe. That is a routing fault in the platform.',
    }
  }
  if (status === 408 || status === 504) {
    return {
      title: `The evidence probe timed out (HTTP ${status})`,
      detail: 'The cluster did not answer in time. Nothing was disproved — the probe simply did not finish.',
    }
  }
  if (status >= 500) {
    return {
      title: `The platform failed while collecting evidence (HTTP ${status})`,
      detail: 'The probe errored before it could report. This is a fault in the platform, not a verdict on the credential chain.',
    }
  }
  return {
    title: `The evidence probe did not complete (HTTP ${status})`,
    detail: 'The platform returned a response this card does not know how to read.',
  }
}

// ─── Waiting ────────────────────────────────────────────────────────────────
//
// "Checking the credential chain…" reads identically at second two and at
// second ninety, and the probe shells out to kubectl six times — it is not
// fast. Both of this card's waits now carry a live elapsed figure.
//
// The button's wait is `ButtonWait`, shared with the other three pages that
// had each grown their own version of it: no visible word, a reserved width,
// an accessible name, no live region. The headline below is NOT one of those —
// it is a panel-level wait with a whole line to itself, so it stays a plain
// PixelLoader and keeps the full sentence.

/** Matches the in-button wait's own gap, so the two read as one family. */
const LOADER_GAP = 6
/** Fits the wait plus the button's padding, and the idle label too, so the
 *  header does not shuffle when Re-check becomes a loader. */
const REFRESH_BUTTON_W = 96

function headline(steps: EvidenceStep[], failed: boolean, loading: boolean): string {
  const { observed, unavailable, total } = evidenceSummary(steps)
  // On failure the count is zero because nothing ran — saying "none collected
  // yet" would describe a clean starting state, which is the one reading this
  // card must never produce for a probe that broke.
  if (failed) return 'No evidence could be collected — the check itself failed. See below.'
  // Before the first probe resolves the count is zero, which would otherwise
  // render the same false clean state the failure branch above exists to stop.
  if (loading && total === 0) return 'Checking the credential chain…'
  if (total === 0) return 'No evidence has been collected yet.'
  if (unavailable === total) return 'Nothing could be checked — the platform could not reach the cluster.'
  const base = `${observed} of ${total} steps in the credential chain are confirmed by direct inspection`
  return unavailable > 0
    ? `${base}; ${unavailable} could not be checked.`
    : `${base}.`
}

export function CredentialEvidencePanel({
  fetcher = fetch,
  autoLoad = true,
  getToken,
}: {
  fetcher?: typeof fetch
  autoLoad?: boolean
  /**
   * Supplies the OIDC access token for the evidence request.
   *
   * The evidence route sits behind `authenticated_tenant` exactly
   * like every other route on that router, so an unauthenticated request comes
   * back 401 and the card renders "No evidence has been collected yet." — which
   * reads as "the credential chain does not exist" rather than "we were not
   * allowed to look". That is precisely the conflation this component was built
   * to end, so the token is not optional in practice; it is optional only in the
   * type, to keep the component renderable in isolation.
   */
  getToken?: () => Promise<string | undefined | null>
}) {
  const [evidence, setEvidence] = useState<CredentialEvidence | null>(null)
  const [error, setError] = useState<{ title: string; detail?: string } | null>(null)
  const [loading, setLoading] = useState(false)
  /**
   * Which consoles are open — the ONLY source of truth for that, keyed by step
   * number.
   *
   * There used to be a second one: a global `showAllCommands` flag, combined as
   * `showAllCommands || open[step]`. While the flag was set the `||` re-asserted
   * "open" on every render regardless of the map, so after "Show commands" a
   * row's own "Hide proof" wrote `false` into the map and changed nothing on
   * screen. The row control was dead for as long as the global one was on.
   *
   * The global button now SEEDS this map (see `toggleAllCommands`) instead of
   * outranking it, so nothing derived can contradict a click. On a card whose
   * entire purpose is showing an engineer the evidence rather than asking for
   * trust, a control that looks like it works and does not is the worst defect
   * available.
   */
  const [open, setOpen] = useState<Record<number, boolean>>({})

  // Held in a ref so a caller passing an inline arrow (a new identity every
  // render) cannot change `load`'s identity, retrigger the autoLoad effect and
  // spin the endpoint in a loop.
  const getTokenRef = useRef(getToken)
  getTokenRef.current = getToken

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      // A token failure must not abort the probe silently: fall through with no
      // Authorization header and let the 401 be reported, rather than throwing
      // away the request and leaving the card looking merely empty.
      let token: string | undefined | null
      try {
        token = await getTokenRef.current?.()
      } catch {
        token = undefined
      }
      const response = await fetcher(EVIDENCE_ENDPOINT, {
        headers: {
          Accept: 'application/json',
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
      })
      if (!response.ok) {
        // Surface what the status MEANS rather than falling back to a blank
        // lifecycle: an empty card reads exactly like "nothing is deployed",
        // which is the confusion this component exists to end.
        setError(describeFailure(response.status))
        setEvidence(null)
        return
      }
      setEvidence(parseEvidence(await response.json()))
    } catch (err) {
      setError({
        title: err instanceof Error ? err.message : 'Evidence request failed',
        detail: 'The request never completed, so nothing was observed either way.',
      })
      setEvidence(null)
    } finally {
      setLoading(false)
    }
  }, [fetcher])

  useEffect(() => {
    if (autoLoad) void load()
  }, [autoLoad, load])

  // Memoised so the `?? []` fallback does not produce a fresh array identity on
  // every render and re-run the summary needlessly.
  const steps = useMemo(() => evidence?.steps ?? [], [evidence])
  const summary = useMemo(() => evidenceSummary(steps), [steps])

  // Computed over the RENDERED rows, never over the whole map. A re-check that
  // drops a step leaves its remembered `true` behind, and a vanished row must
  // not be what makes this button offer to hide something — that is the same
  // "stale state outranks what is on screen" fault the `||` had, one level up.
  const anyCommandsOpen = useMemo(() => steps.some((s) => open[s.step] === true), [steps, open])

  /**
   * Seeds every row at once: open them all, or close them all.
   *
   * Replaces the map rather than merging into it, which also drops the entries
   * for steps a re-check no longer returns.
   */
  const toggleAllCommands = useCallback(() => {
    const next = !anyCommandsOpen
    setOpen(Object.fromEntries(steps.map((s) => [s.step, next])))
  }, [anyCommandsOpen, steps])

  return (
    <div data-testid="credential-evidence-panel">
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, marginBottom: 8 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Credential Lifecycle</h2>
          {/* The three badges are the subtle part of this card, and the
              dangerous confusion is "unverified" reading as "absent". The
              distinction is spelled out here rather than in the rows, because
              it is one rule that governs every row. */}
          <HelpHint label="What the three evidence badges mean" testId="evidence-states-help">
            Each row is one probe run against the cluster just now. Observed means the probe found it. Not present means the probe ran and it was not there — often the correct answer, such as before a stun. Unverified means the probe could not run, so nothing was proved either way; it is not the same as absent.
          </HelpHint>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          {/* Disabled with no rows: the toggle only expands per-step commands,
              so with an empty chain it is inert and reads as a broken button —
              which is exactly how it looked while the endpoint was 500ing.
              Disabled rather than hidden: hiding it would shift the header on
              every re-check, and mid-demo jitter reads as a fault of its own.
              The title sits on the wrapper because browsers suppress hover
              events on a disabled control, so a title on the button itself
              would never be shown to the person who needs it. */}
          <span title={steps.length === 0 ? 'Nothing has been collected, so there are no commands to show' : undefined}>
            <button
              type="button"
              data-testid="evidence-toggle-commands"
              onClick={toggleAllCommands}
              disabled={steps.length === 0}
              style={{ ...btn, ...(steps.length === 0 ? { opacity: 0.45, cursor: 'not-allowed' } : {}) }}
            >
              {/* Read off the rows themselves, so the label always describes what
                  the press will do. Opening every console and then hitting a
                  failing Re-check leaves nothing rendered and nothing to hide,
                  and this says so.

                  ANY open row makes it "Hide commands", not only a full house:
                  a button reading "Show commands" over five open rows would
                  visibly do almost nothing when pressed, which is the same dead
                  control this component just stopped shipping. One press always
                  clears the screen. */}
              {anyCommandsOpen ? 'Hide commands' : 'Show commands'}
            </button>
          </span>
          {/* Explains this button AND the per-row "How do we know?", which is
              the same disclosure scoped to one row. Six identical hints down
              the rows would be noise; one hint on the control that opens them
              all is not. */}
          <HelpHint label="What showing the proof does" testId="evidence-commands-help">
            Opens the literal command that decided each row, and the raw output it returned, for every row at once. A row’s own “How do we know?” button opens the same proof for that row alone. Paste the command into a terminal to check the platform rather than trust it.
          </HelpHint>
                    <button
            type="button"
            data-testid="evidence-refresh"
            onClick={() => void load()}
            disabled={loading}
            style={{
              ...btn,
              minWidth: REFRESH_BUTTON_W,
              display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
            }}
          >
            {loading
              ? <ButtonWait testId="evidence-recheck-loader" label="Checking" />
              : 'Re-check'}
          </button>
        </div>
      </div>

      {/* The executive line: one sentence, no jargon, no counts of things that
          were not checked hidden inside a "completed".

          A div rather than a p: the first-pass wait renders PixelLoader here,
          whose root is a div, and a paragraph may not contain one — the
          browser would close the paragraph early and the styling with it. The
          test id, the sentence and the styling are otherwise unchanged, and on
          a RE-check the line keeps showing the previous counts rather than
          throwing them away. */}
      <div data-testid="evidence-headline" style={{ fontSize: 12, color: 'var(--muted)', margin: '0 0 4px', lineHeight: 1.5 }}>
        {error === null && loading && summary.total === 0
          ? (
            <PixelLoader
              testId="evidence-headline-loader"
              label="Checking the credential chain"
              style={{ gap: LOADER_GAP }}
            />
          )
          : headline(steps, error !== null, loading)}
      </div>
      {/* A claim about rows, so it is only made when there are rows. With an
          empty chain it asserted that six absent rows had each been decided by
          a command that never ran. */}
      {steps.length > 0 && (
      <p style={{ fontSize: 11, color: 'var(--muted)', margin: '0 0 12px', lineHeight: 1.5 }}>
        Every row below was decided by running a command against the cluster just now — not by
        what the operator clicked. Open a row, or run{' '}
        <code style={code}>make demo-signalloom-supercred-evidence</code> for the same result in a terminal.
      </p>
      )}

      {error && (
        <div role="alert" data-testid="evidence-error" style={{
          padding: '10px 14px', borderRadius: 6, marginBottom: 12,
          background: 'rgba(245,158,11,0.10)', border: '1px solid rgba(245,158,11,0.35)',
          fontSize: 12, lineHeight: 1.5,
        }}>
          <strong>{error.title}.</strong>{error.detail ? ` ${error.detail}` : ''} No lifecycle state
          is shown, because none was observed. This is not the same as the chain being absent.
        </div>
      )}

      <div data-testid="evidence-steps" style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {steps.map((step) => {
          const sc = STATE_STYLE[step.state]
          const isOpen = open[step.step] === true
          return (
            <div
              key={step.step}
              data-testid={`evidence-step-${step.step}`}
              style={{ padding: '10px 14px', borderRadius: 6, background: sc.bg, border: `1px solid ${sc.border}` }}
            >
              <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12 }}>
                <div style={{ width: 10, height: 10, borderRadius: '50%', background: sc.dot, marginTop: 4, flexShrink: 0 }} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                    <span style={{ fontWeight: 600, fontSize: 13 }}>
                      Step {step.step}: {step.label}
                    </span>
                    <span
                      data-testid={`evidence-state-${step.step}`}
                      style={{
                        fontSize: 10, fontWeight: 600, textTransform: 'uppercase',
                        padding: '1px 6px', borderRadius: 3, background: sc.border, color: sc.dot,
                      }}
                    >
                      {sc.label}
                    </span>
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2, lineHeight: 1.4 }}>
                    {step.summary}
                  </div>
                  <button
                    type="button"
                    data-testid={`evidence-disclose-${step.step}`}
                    // Flipped from the map itself, not from the derived `isOpen`
                    // above: the row's own state is the thing being toggled, and
                    // reading anything else back into the write is how the last
                    // model let a global flag swallow this click.
                    onClick={() => setOpen((prev) => ({ ...prev, [step.step]: prev[step.step] !== true }))}
                    style={{ ...btn, marginTop: 6, fontSize: 10 }}
                  >
                    {isOpen
                      ? 'Hide proof'
                      : step.proofs.length > 1
                        ? `How do we know? (${step.proofs.length} checks)`
                        : 'How do we know?'}
                  </button>

                  {isOpen && (
                    <ProofConsole proofs={step.proofs} testId={`evidence-console-${step.step}`} />
                  )}
                </div>
              </div>
            </div>
          )
        })}
      </div>

      {evidence && (
        <p data-testid="evidence-provenance" style={{ fontSize: 10, color: 'var(--muted)', marginTop: 10 }}>
          {summary.observed} observed · {summary.absent} not present · {summary.unavailable} unverified —
          collected {evidence.generated_at} by <code style={code}>{evidence.source}</code>
        </p>
      )}
    </div>
  )
}

const btn: React.CSSProperties = {
  fontSize: 11, padding: '3px 8px', borderRadius: 4, cursor: 'pointer',
  border: '1px solid var(--border, rgba(148,163,184,0.35))',
  background: 'transparent', color: 'inherit',
}

const code: React.CSSProperties = {
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  fontSize: 10, padding: '1px 4px', borderRadius: 3,
  background: 'rgba(148,163,184,0.15)',
}
