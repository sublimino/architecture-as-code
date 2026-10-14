import { useId, useState, type CSSProperties } from 'react'
import { Link } from 'react-router-dom'
import type { deriveAgentReview } from '../data/agentReview'
import './AgentReviewQueue.css'

interface Props {
  review: ReturnType<typeof deriveAgentReview>
  loaded: boolean
  loading: boolean
  error: string | null
  sourceHealth?: 'healthy' | 'degraded' | 'unavailable' | null
  lastRefresh?: string | null
  onRetry: () => void
}

// Flex children and .btn otherwise retain intrinsic/no-wrap widths on narrow
// layouts. Allow actual reflow, including unbroken names, rather than clipping.
const wrapStyle: CSSProperties = { minWidth: 0, maxWidth: '100%', whiteSpace: 'normal', overflowWrap: 'anywhere' }

/** Read-only triage: no acknowledgement state or lifecycle operations. */
export default function AgentReviewQueue({ review, loaded, loading, error, sourceHealth, lastRefresh, onRetry }: Props) {
  const [expanded, setExpanded] = useState(false)
  const headingId = useId()
  const listId = useId()
  const helpId = useId()
  const visible = expanded ? review.issues : review.issues.slice(0, 5)
  const incomplete = !!error || sourceHealth === 'unavailable' || sourceHealth === 'degraded'
  return (
    <section className="card agent-review-queue" aria-labelledby={headingId} aria-describedby={helpId} aria-busy={!loaded && loading} style={{ ...wrapStyle, marginBottom: 20, padding: 14, color: 'var(--text)' }}>
      <div className="agent-review-queue__header" style={{ ...wrapStyle, display: 'flex', flexWrap: 'wrap', alignItems: 'baseline', gap: 8 }}>
        <h2 id={headingId} style={{ ...wrapStyle, fontSize: 16, margin: 0 }}>Review queue</h2>
        {loaded && <span style={{ ...wrapStyle, fontSize: 12, color: 'var(--muted)' }}>{error ? 'Last known: ' : incomplete ? 'Observed: ' : ''}{review.issues.length} {review.issues.length === 1 ? 'issue' : 'issues'} · {review.affectedAgentCount} affected {review.affectedAgentCount === 1 ? 'agent' : 'agents'}</span>}
        {loaded && lastRefresh && Number.isFinite(Date.parse(lastRefresh)) && <span className="agent-review-queue__refresh" style={{ fontSize: 11, color: 'var(--muted)' }}>Last successful API refresh: <time dateTime={lastRefresh}>{new Date(lastRefresh).toLocaleString()}</time></span>}
      </div>
      <p id={helpId} className="agent-review-queue__help">Prioritised evidence for investigation. Reviewing opens the agent dossier; it does not change agent state.</p>
      {!loaded && !error && <p role="status">Loading review evidence…</p>}
      {error && <div role="alert" style={{ ...wrapStyle, display: 'flex', flexWrap: 'wrap', gap: 10, borderLeft: '3px solid var(--error)', paddingLeft: 10, fontSize: 13 }}>
        <span style={{ ...wrapStyle, flex: '1 1 200px' }}>{loaded ? `Refresh failed; showing stale review evidence: ${error}` : `Review queue unavailable: ${error}`}</span>
        <button type="button" className="btn btn-secondary" onClick={onRetry} disabled={loading} style={{ ...wrapStyle, minHeight: 44 }}>Retry</button>
      </div>}
      {loaded && !error && incomplete && <p role="status" style={{ fontSize: 13 }}>Evidence sources {sourceHealth}; review coverage is incomplete.</p>}
      {loaded && review.issues.length === 0 && !incomplete && <div style={{ padding: '12px 0' }}>
        <strong>No agents need review</strong>
        <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 0 }}>No review issues in the available evidence. Agent inventory remains below.</p>
      </div>}
      {loaded && visible.length > 0 && <>
        <div className="agent-review-queue__columns" aria-hidden="true"><span>Severity / issue</span><span>Agent</span><span>Owner / team</span><span>Evidence</span><span>Review</span></div>
        <ol id={listId} className="agent-review-queue__list">
        {visible.map(issue => <li key={issue.id} className="agent-review-queue__row" style={{ borderLeft: `3px solid var(--${issue.severity === 'critical' ? 'error' : 'amber'})` }}>
          <span className="agent-review-queue__cell" title={`${issue.severity === 'critical' ? 'Critical' : 'Warning'} · ${issue.reason}`} style={{ color: 'var(--muted)' }}>{issue.severity === 'critical' ? 'Critical' : 'Warning'} · {issue.reason}</span>
          <strong className="agent-review-queue__cell" title={issue.agentName}>{issue.agentName}</strong>
          <span className="agent-review-queue__cell" title={issue.responsibility} style={{ color: 'var(--muted)' }}>{issue.responsibility}</span>
          <div className="agent-review-queue__evidence">
            <span className="agent-review-queue__cell" title={issue.description}>{issue.description}</span>
            {issue.evidenceAt && <span className="agent-review-queue__help">Kernel evidence observed: <time dateTime={issue.evidenceAt}>{new Date(issue.evidenceAt).toLocaleString()}</time></span>}
          </div>
          <Link className="btn btn-secondary agent-review-queue__action" to={`/agents/${encodeURIComponent(issue.agentId)}?tab=${issue.detailTab}`} aria-label={`Review agent ${issue.agentName}: ${issue.reason}`} title="Open agent dossier (read-only review)" style={{ ...wrapStyle, fontSize: 12, textDecoration: 'none', color: 'var(--text)' }}>Review agent →</Link>
        </li>)}
      </ol></>}
      {loaded && review.issues.length > 5 && <button type="button" className="btn btn-secondary agent-review-queue__action" aria-expanded={expanded} aria-controls={listId} onClick={() => setExpanded(value => !value)} style={{ ...wrapStyle, marginTop: 8, fontSize: 12 }}>{expanded ? 'Show fewer' : `View all ${review.issues.length} issues`}</button>}
    </section>
  )
}
