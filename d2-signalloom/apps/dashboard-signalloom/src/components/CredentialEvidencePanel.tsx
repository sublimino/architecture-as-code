import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  EVIDENCE_ENDPOINT,
  evidenceSummary,
  parseEvidence,
  type CredentialEvidence,
  type EvidenceState,
  type EvidenceStep,
} from '../api/credentialEvidence'

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

function headline(steps: EvidenceStep[]): string {
  const { observed, unavailable, total } = evidenceSummary(steps)
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
   * `/api/demo/supercred/evidence` sits behind `authenticated_tenant` exactly
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
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [open, setOpen] = useState<Record<number, boolean>>({})
  const [showAllCommands, setShowAllCommands] = useState(false)

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
        // Surface the status rather than falling back to a blank lifecycle: an
        // empty card reads exactly like "nothing is deployed", which is the
        // confusion this component exists to end.
        setError(
          response.status === 401
            ? 'Evidence unavailable (HTTP 401) — the platform did not accept this session'
            : `Evidence unavailable (HTTP ${response.status})`,
        )
        setEvidence(null)
        return
      }
      setEvidence(parseEvidence(await response.json()))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Evidence request failed')
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

  return (
    <div data-testid="credential-evidence-panel">
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, marginBottom: 8 }}>
        <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Credential Lifecycle</h2>
        <div style={{ display: 'flex', gap: 8 }}>
          <button
            type="button"
            data-testid="evidence-toggle-commands"
            onClick={() => setShowAllCommands((v) => !v)}
            style={btn}
          >
            {showAllCommands ? 'Hide commands' : 'Show commands'}
          </button>
          <button type="button" data-testid="evidence-refresh" onClick={() => void load()} disabled={loading} style={btn}>
            {loading ? 'Checking…' : 'Re-check'}
          </button>
        </div>
      </div>

      {/* The executive line: one sentence, no jargon, no counts of things that
          were not checked hidden inside a "completed". */}
      <p data-testid="evidence-headline" style={{ fontSize: 12, color: 'var(--muted)', margin: '0 0 4px', lineHeight: 1.5 }}>
        {headline(steps)}
      </p>
      <p style={{ fontSize: 11, color: 'var(--muted)', margin: '0 0 12px', lineHeight: 1.5 }}>
        Every row below was decided by running a command against the cluster just now — not by
        what the operator clicked. Open a row, or run{' '}
        <code style={code}>make demo-signalloom-supercred-evidence</code> for the same result in a terminal.
      </p>

      {error && (
        <div role="alert" data-testid="evidence-error" style={{
          padding: '10px 14px', borderRadius: 6, marginBottom: 12,
          background: 'rgba(245,158,11,0.10)', border: '1px solid rgba(245,158,11,0.35)',
          fontSize: 12, lineHeight: 1.5,
        }}>
          <strong>{error}.</strong> No lifecycle state is shown, because none was observed. This is
          not the same as the chain being absent.
        </div>
      )}

      <div data-testid="evidence-steps" style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {steps.map((step) => {
          const sc = STATE_STYLE[step.state]
          const isOpen = showAllCommands || open[step.step] === true
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
                    onClick={() => setOpen((prev) => ({ ...prev, [step.step]: !isOpen }))}
                    style={{ ...btn, marginTop: 6, fontSize: 10 }}
                  >
                    {isOpen ? 'Hide proof' : 'How do we know?'}
                  </button>

                  {isOpen && (
                    <div data-testid={`evidence-console-${step.step}`} style={consoleBox}>
                      <div style={{ color: 'var(--cyan)' }}>$ {step.command}</div>
                      <pre style={{ margin: '6px 0 0', whiteSpace: 'pre-wrap', wordBreak: 'break-word', color: 'var(--text)' }}>
                        {step.detail || '(no output)'}
                      </pre>
                    </div>
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

const consoleBox: React.CSSProperties = {
  marginTop: 8, padding: '8px 10px', borderRadius: 4,
  // --surface2 with --text is the pairing the theme guarantees contrast for;
  // a hardcoded slate console rendered 1.03:1 against the light theme's text
  // when this repo last hardcoded a panel colour.
  background: 'var(--surface2)', border: '1px solid var(--border)',
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  fontSize: 10, lineHeight: 1.5, overflowX: 'auto',
}
