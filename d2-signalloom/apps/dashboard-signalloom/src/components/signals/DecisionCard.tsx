/**
 * A decision card, and the review control that is the whole point of the page.
 *
 * Three things about the review control are deliberate.
 *
 * The note is mandatory and has a floor. A verdict without a reason is not
 * evidence: six months later "false positive" with no note cannot be audited,
 * defended to a regulator, or used to fix the rule that produced it. Ten
 * characters is not a quality bar, it is a floor that stops a reflexive "ok".
 *
 * The badge appears optimistically and carries `data-pending` until the POST
 * lands. A reviewer working through a queue needs the row to settle instantly;
 * marking it pending rather than final means a 409 or a 403 can roll it back
 * without ever having lied about what is stored.
 *
 * A failed review is reported on the card and nowhere else. One decision whose
 * review would not store must not take down the other nineteen a reviewer
 * still has to judge, so the error lives next to the control that produced it.
 */
import { useState } from 'react'
import {
  REVIEW_NOTE_MIN_LENGTH,
  VERDICT_LABELS,
  type DecisionReview,
  type PolicyDecision,
  type PolicyFinding,
  type ReviewVerdict,
} from '../../api/policyApi'
import { LabelChips, layerColor, layerLabel, severityColor, timeShort } from './presentation'

const VERDICTS: ReviewVerdict[] = ['true_positive', 'false_positive', 'needs_info']

const VERDICT_COLORS: Record<ReviewVerdict, string> = {
  true_positive: 'var(--error)',
  false_positive: 'var(--teal)',
  needs_info: 'var(--amber)',
}

export interface DecisionCardProps {
  decision: PolicyDecision
  /** Findings already loaded for this window, used to expand the contributors. */
  findings: PolicyFinding[]
  /** Resolves with the stored review, or rejects with the API error. */
  onReview: (decisionId: string, body: { verdict: ReviewVerdict; note: string }) => Promise<DecisionReview>
}

export default function DecisionCard({ decision, findings, onReview }: DecisionCardProps) {
  const [verdict, setVerdict] = useState<ReviewVerdict | null>(null)
  const [note, setNote] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [optimistic, setOptimistic] = useState<{ verdict: ReviewVerdict; note: string } | null>(null)
  const [stored, setStored] = useState<DecisionReview | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [expanded, setExpanded] = useState(false)

  const settled = stored ?? decision.review
  const shown = settled ?? optimistic
  const pending = settled === null && optimistic !== null
  const noteOk = note.trim().length >= REVIEW_NOTE_MIN_LENGTH
  const canSubmit = verdict !== null && noteOk && !submitting

  const contributors = findings.filter((f) => decision.finding_ids.includes(f.id))

  async function submit() {
    if (verdict === null || !noteOk) return
    const body = { verdict, note: note.trim() }
    setSubmitting(true)
    setError(null)
    setOptimistic(body)
    try {
      const review = await onReview(decision.id, body)
      // The server's record is what is shown from here on, including the
      // reviewer identity and timestamp it assigned rather than ones we guessed.
      setStored(review)
      setOptimistic(null)
    } catch (err) {
      setOptimistic(null)
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div data-testid={`decision-card-${decision.id}`}>
      <div
        className="card"
        data-testid="decision-card"
        data-reviewed={settled !== null}
        style={{ padding: '16px 20px', display: 'flex', flexDirection: 'column', gap: 12 }}
      >
        {/* Header: what fired, and how the engine judged it */}
        <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
          <div style={{ minWidth: 0 }}>
            <div data-testid="decision-rule" style={{ fontSize: 15, fontWeight: 600, color: 'var(--text)' }}>
              {decision.rule_id}
            </div>
            <div style={{ fontSize: 11, color: 'var(--dim)', marginTop: 3 }}>
              {timeShort(decision.timestamp)} in window{' '}
              <span data-testid="decision-window">{decision.window_id}</span>
              {' '}under bundle {decision.bundle_id} {decision.bundle_version}
            </div>
          </div>
          <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', flexShrink: 0 }}>
            <span
              data-testid="decision-severity"
              className="tag"
              style={{ color: severityColor(decision.severity), background: 'var(--surface2)' }}
            >
              {decision.severity}
            </span>
            <span data-testid="decision-mode" className="tag" style={{ color: 'var(--muted)', background: 'var(--surface2)' }}>
              {decision.mode}
            </span>
            {shown && (
              <span
                data-testid="decision-verdict-badge"
                data-pending={pending}
                style={{
                  fontSize: 10,
                  fontWeight: 700,
                  textTransform: 'uppercase',
                  letterSpacing: '0.06em',
                  padding: '3px 9px',
                  borderRadius: 4,
                  color: VERDICT_COLORS[shown.verdict],
                  background: 'var(--surface2)',
                  border: `1px solid ${VERDICT_COLORS[shown.verdict]}`,
                  opacity: pending ? 0.65 : 1,
                }}
              >
                {VERDICT_LABELS[shown.verdict]}
                {pending ? ' (saving)' : ''}
              </span>
            )}
          </div>
        </div>

        {/* The facts a judgement rests on */}
        <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', fontSize: 12, color: 'var(--muted)' }}>
          <span>
            Actor{' '}
            <strong data-testid="decision-actor" style={{ color: 'var(--text)' }} title="Pseudonymous actor reference">
              {decision.actor}
            </strong>
          </span>
          <span>
            <strong data-testid="decision-count" style={{ color: 'var(--text)' }}>{decision.count}</strong>{' '}
            contributing {decision.count === 1 ? 'finding' : 'findings'}
          </span>
          <button
            type="button"
            data-testid="decision-findings-toggle"
            aria-expanded={expanded}
            onClick={() => setExpanded((v) => !v)}
            style={{
              fontSize: 12,
              fontWeight: 600,
              color: 'var(--cyan)',
              background: 'none',
              border: 'none',
              padding: 0,
              cursor: 'pointer',
            }}
          >
            {expanded ? 'Hide findings' : 'Show findings'}
          </button>
        </div>

        {expanded && (
          <div
            data-testid="decision-findings"
            style={{ display: 'flex', flexDirection: 'column', gap: 8, padding: '10px 12px', background: 'var(--surface2)', borderRadius: 6 }}
          >
            {contributors.length === 0 ? (
              <span style={{ fontSize: 12, color: 'var(--muted)' }}>
                The contributing findings have aged out of this window. Widen the window to see them.
              </span>
            ) : (
              contributors.map((f) => (
                <div key={f.id} style={{ display: 'flex', gap: 10, alignItems: 'baseline', flexWrap: 'wrap', fontSize: 12 }}>
                  <span style={{ color: 'var(--muted)', fontVariantNumeric: 'tabular-nums' }}>{timeShort(f.timestamp)}</span>
                  <span style={{ color: layerColor(f.layer), fontWeight: 600 }}>{layerLabel(f.layer)}</span>
                  <span style={{ color: 'var(--text)' }}>{f.rule_id}</span>
                  <a href={`#observation-${f.source_observation_id}`} style={{ color: 'var(--cyan)' }}>
                    {f.source_observation_id}
                  </a>
                  <LabelChips labels={f.labels} />
                </div>
              ))
            )}
          </div>
        )}

        {/* Review */}
        {settled ? (
          <div
            style={{ borderTop: '1px solid var(--border)', paddingTop: 10, display: 'flex', flexDirection: 'column', gap: 4 }}
          >
            <div style={{ fontSize: 12.5, color: 'var(--text)' }}>{settled.note}</div>
            <div style={{ fontSize: 11, color: 'var(--muted)' }}>
              Reviewed by{' '}
              <span data-testid="decision-reviewer">{settled.reviewer}</span>
              {' '}at {timeShort(settled.reviewed_at)}
            </div>
          </div>
        ) : (
          <div
            data-testid="decision-review-form"
            style={{ borderTop: '1px solid var(--border)', paddingTop: 10, display: 'flex', flexDirection: 'column', gap: 8 }}
          >
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {VERDICTS.map((v) => {
                const active = verdict === v
                return (
                  <button
                    key={v}
                    type="button"
                    data-testid={`verdict-btn-${v}`}
                    aria-pressed={active}
                    disabled={submitting}
                    onClick={() => setVerdict(v)}
                    style={{
                      padding: '6px 13px',
                      fontSize: 12,
                      fontWeight: 600,
                      borderRadius: 'var(--radius-sm, 6px)',
                      border: `1px solid ${active ? VERDICT_COLORS[v] : 'var(--border-subtle)'}`,
                      background: active ? 'var(--surface2)' : 'transparent',
                      color: active ? VERDICT_COLORS[v] : 'var(--muted)',
                      cursor: submitting ? 'wait' : 'pointer',
                    }}
                  >
                    {VERDICT_LABELS[v]}
                  </button>
                )
              })}
            </div>
            <label style={{ fontSize: 11, color: 'var(--muted)' }} htmlFor={`review-note-${decision.id}`}>
              Why. Minimum {REVIEW_NOTE_MIN_LENGTH} characters, stored as the evidence for this verdict.
            </label>
            <textarea
              id={`review-note-${decision.id}`}
              data-testid="review-note"
              value={note}
              disabled={submitting}
              onChange={(e) => setNote(e.target.value)}
              rows={2}
              style={{
                fontSize: 12.5,
                padding: '7px 9px',
                borderRadius: 'var(--radius-sm, 6px)',
                border: '1px solid var(--border)',
                background: 'var(--surface)',
                color: 'var(--text)',
                resize: 'vertical',
                fontFamily: 'inherit',
              }}
            />
            <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
              <button
                type="button"
                data-testid="review-submit"
                disabled={!canSubmit}
                onClick={() => void submit()}
                style={{
                  padding: '7px 16px',
                  fontSize: 12,
                  fontWeight: 600,
                  borderRadius: 'var(--radius-sm, 6px)',
                  border: 'none',
                  background: canSubmit ? 'var(--teal)' : 'var(--surface2)',
                  color: canSubmit ? 'var(--on-accent, #fff)' : 'var(--muted)',
                  cursor: canSubmit ? 'pointer' : 'not-allowed',
                }}
              >
                {submitting ? 'Recording...' : 'Record review'}
              </button>
              {!noteOk && note.length > 0 && (
                <span style={{ fontSize: 11, color: 'var(--muted)' }}>
                  {REVIEW_NOTE_MIN_LENGTH - note.trim().length} more characters needed.
                </span>
              )}
            </div>
            {error && (
              <div role="alert" data-testid="review-error" style={{ fontSize: 11.5, color: 'var(--error)' }}>
                {error}
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  )
}
