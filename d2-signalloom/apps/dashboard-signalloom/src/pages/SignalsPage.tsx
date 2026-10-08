/**
 * SignalsPage: what is being ingested right now, and what the policy engine
 * decided about it, in a form a human can judge.
 *
 * Two tabs over one shared window. **Live** answers "is the telemetry
 * flowing, from where, and what did it say" (rate per layer, per-source table,
 * the observation feed, and the findings the window raised). **Decisions**
 * answers the question the page exists for: can a reviewer look at an
 * aggregated decision, see the findings under it, and record an objective
 * verdict with a reason that survives as evidence.
 *
 * Three design notes worth keeping.
 *
 * The window is shared, not per tab. A reviewer who widens to 90m on the Live
 * tab and then switches to Decisions is asking about the same 90 minutes; two
 * independent windows would silently compare different periods, which is the
 * one mistake this page must not help anyone make.
 *
 * There is exactly one stream, held in a ref and torn down by the same effect
 * that opened it. A second open stream would double every arrival in the feed
 * and read as a traffic spike that is not happening. The arrival handler also
 * checks a per-effect `cancelled` flag, because a disconnected stream's
 * callback closure still exists and a transport that delivers one last frame
 * after `abort()` would otherwise append to a paused feed.
 *
 * Pausing stops both the stream and the 10 second poll. "Pause" on a live
 * dashboard means "hold this picture still so I can read it", and a poll that
 * kept replacing the rows underneath would defeat the only reason to press it.
 */
import { useState, useEffect, useCallback, useRef, useMemo } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { isDemoMode } from '../api/demoMode'
import { weaveApi, type SignalObservation } from '../api/weaveApi'
import {
  policyApi,
  isPolicyConnectionError,
  reviewErrorMessage,
  type DecisionReview,
  type IngestRateBucket,
  type PolicyDecision,
  type PolicyFinding,
  type PolicyWindow,
  type RateBucket,
  type ReviewVerdict,
} from '../api/policyApi'
import { Section, StatCard } from '../components/DashKit'
import LoadingState, { loadPhase } from '../components/LoadingState'
import WindowSelector from '../components/signals/WindowSelector'
import IngestRateChart from '../components/signals/IngestRateChart'
import SourceTable from '../components/signals/SourceTable'
import ObservationFeed from '../components/signals/ObservationFeed'
import FindingsList from '../components/signals/FindingsList'
import DecisionCard from '../components/signals/DecisionCard'

/** How often the window is re-read while the page is live. */
const REFRESH_MS = 10_000

/** Most recent observations held in the feed. Beyond this the list is noise. */
const FEED_CAP = 60

type Tab = 'live' | 'decisions'

/**
 * Bucket width for the rate chart.
 *
 * A 1 minute bucket over 90 minutes is 90 bars in a 220px tall chart, which is
 * a smear; a 5 minute bucket over 5 minutes is one bar, which is not a chart.
 * The split is at 30m.
 */
export function bucketFor(window: PolicyWindow): RateBucket {
  return window === '5m' || window === '10m' ? '1m' : '5m'
}

export default function SignalsPage() {
  const { getAccessTokenSilently } = useAuth0()
  const demo = isDemoMode()
  const [searchParams, setSearchParams] = useSearchParams()

  const initialWindow = (searchParams.get('window') as PolicyWindow) || '10m'
  const initialTab = (searchParams.get('tab') as Tab) || 'live'
  const initialLayer = searchParams.get('layer') || null
  const initialFidelity = searchParams.get('fidelity') || null
  const initialQ = searchParams.get('q') || ''
  const initialExcludeSentinel = searchParams.get('excludeSentinel') === 'true'

  const [window, setWindow] = useState<PolicyWindow>(initialWindow)
  const [tab, setTab] = useState<Tab>(initialTab)
  const [selectedLayer, setSelectedLayer] = useState<string | null>(initialLayer)
  const [selectedFidelity, setSelectedFidelity] = useState<string | null>(initialFidelity)
  const [searchQuery, setSearchQuery] = useState<string>(initialQ)
  const [excludeSentinel, setExcludeSentinel] = useState<boolean>(initialExcludeSentinel)
  const [paused, setPaused] = useState(false)
  const [unreviewedOnly, setUnreviewedOnly] = useState(false)

  const [observations, setObservations] = useState<SignalObservation[]>([])
  const [findings, setFindings] = useState<PolicyFinding[]>([])
  const [decisions, setDecisions] = useState<PolicyDecision[]>([])
  const [rates, setRates] = useState<IngestRateBucket[]>([])

  const [loading, setLoading] = useState(true)
  const [loaded, setLoaded] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [liveCount, setLiveCount] = useState(0)

  const streamRef = useRef<{ disconnect: () => void } | null>(null)

  // Sync state to URL search parameters
  useEffect(() => {
    const params = new URLSearchParams(searchParams)
    if (window && window !== '10m') params.set('window', window)
    else params.delete('window')

    if (tab && tab !== 'live') params.set('tab', tab)
    else params.delete('tab')

    if (selectedLayer && selectedLayer !== 'all') params.set('layer', selectedLayer)
    else params.delete('layer')

    if (selectedFidelity && selectedFidelity !== 'all') params.set('fidelity', selectedFidelity)
    else params.delete('fidelity')

    if (searchQuery.trim()) params.set('q', searchQuery.trim())
    else params.delete('q')

    if (excludeSentinel) params.set('excludeSentinel', 'true')
    else params.delete('excludeSentinel')

    if (params.toString() !== searchParams.toString()) {
      setSearchParams(params, { replace: true })
    }
  }, [window, tab, selectedLayer, selectedFidelity, searchQuery, excludeSentinel, searchParams, setSearchParams])

  const fetchAll = useCallback(
    async (opts: { initial: boolean }) => {
      try {
        if (opts.initial) setLoading(true)
        const token = await getAccessTokenSilently()
        const [obs, fnd, dec, rts] = await Promise.all([
          weaveApi.getObservations(token, {
            limit: FEED_CAP,
            layer: selectedLayer && selectedLayer !== 'all' ? selectedLayer : undefined,
          }),
          policyApi.getFindings(token, { window }),
          policyApi.getDecisions(token, { window }),
          policyApi.getRates(token, { window, bucket: bucketFor(window) }),
        ])
        setObservations(obs.slice(0, FEED_CAP))
        setFindings(fnd)
        setDecisions(dec)
        setRates(rts)
        setError(null)
        setLoaded(true)
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Failed to load signal data.')
      } finally {
        if (opts.initial) setLoading(false)
      }
    },
    [getAccessTokenSilently, window, selectedLayer],
  )

  // Initial load, and a reload whenever the window or selected layer changes.
  useEffect(() => {
    void fetchAll({ initial: true })
  }, [fetchAll])

  // The poll. Deliberately not a refresh on `paused` going false as well: the
  // stream effect reopens and the next tick is at most 10s away, and firing an
  // extra fetch on resume made the resume button feel like a reload button.
  useEffect(() => {
    if (paused) return
    const t = setInterval(() => void fetchAll({ initial: false }), REFRESH_MS)
    return () => clearInterval(t)
  }, [fetchAll, paused])

  // The one stream.
  useEffect(() => {
    if (paused || demo) return
    let cancelled = false
    let handle: { disconnect: () => void } | null = null

    void (async () => {
      const token = await getAccessTokenSilently()
      if (cancelled) return
      handle = weaveApi.createObservationsStream(
        token,
        {
          limit: FEED_CAP,
          layers: selectedLayer && selectedLayer !== 'all' ? selectedLayer : undefined,
        },
        (obs) => {
          if (cancelled) return
          setObservations((prev) => {
            if (prev.some((o) => o.id === obs.id)) return prev
            return [obs, ...prev].slice(0, FEED_CAP)
          })
          setLiveCount((n) => n + 1)
        },
        () => {
          // A dropped stream is not a page failure: the 10s poll still carries
          // the window, so the feed degrades from realtime to near-realtime
          // rather than going blank. Surfaced in the stream status line only.
          if (!cancelled) setLiveCount((n) => n)
        },
      )
      streamRef.current = handle
    })()

    return () => {
      cancelled = true
      handle?.disconnect()
      if (streamRef.current === handle) streamRef.current = null
    }
  }, [getAccessTokenSilently, paused, demo, window, selectedLayer])

  const handleReview = useCallback(
    async (decisionId: string, body: { verdict: ReviewVerdict; note: string }): Promise<DecisionReview> => {
      const token = await getAccessTokenSilently()
      try {
        const review = await policyApi.reviewDecision(token, decisionId, body)
        // Fold the stored review into the page's own copy so the badge
        // survives the card unmounting (a window change, or the filter).
        setDecisions((prev) => prev.map((d) => (d.id === decisionId ? { ...d, review } : d)))
        return review
      } catch (err) {
        // Mapped here rather than in the card so every caller of the review
        // route reports a 409 and a 403 in the same words.
        throw new Error(reviewErrorMessage(err))
      }
    },
    [getAccessTokenSilently],
  )

  const visibleDecisions = useMemo(
    () => (unreviewedOnly ? decisions.filter((d) => d.review === null) : decisions),
    [decisions, unreviewedOnly],
  )

  const unreviewedTotal = useMemo(() => decisions.filter((d) => d.review === null).length, [decisions])
  const totalIngest = useMemo(() => rates.reduce((n, r) => n + r.count, 0), [rates])

  if (loading && !loaded) {
    return (
      <LoadingState
        status={loadPhase({ loading, error, loaded })}
        label="signal and decision data"
        testId="signals-load-state"
      />
    )
  }

  if (error && !loaded) {
    if (!demo && isPolicyConnectionError(error)) {
      return (
        <div data-testid="signals-unreachable" style={{ padding: 32 }}>
          <h2 style={{ fontSize: 18, fontWeight: 700, color: 'var(--error)', marginBottom: 8 }}>
            Policy engine unreachable
          </h2>
          <p style={{ fontSize: 13, color: 'var(--text)', lineHeight: 1.6, maxWidth: 560, marginBottom: 16 }}>
            The policy engine behind the gateway is not responding, so neither the
            findings nor the decisions for this window can be read. Start it with{' '}
            <code style={{ fontSize: 12, padding: '2px 6px', background: 'var(--surface2)', borderRadius: 4 }}>
              make policy-engine-up
            </code>{' '}
            or switch to demo mode using the toggle in the sidebar.
          </p>
          <p style={{ fontSize: 12, color: 'var(--muted)' }}>{error}</p>
        </div>
      )
    }
    return (
      <LoadingState
        variant="block"
        status="error"
        label="signal and decision data"
        error={error}
        testId="signals-load-state"
        onRetry={() => void fetchAll({ initial: true })}
      />
    )
  }

  const nothingAtAll =
    observations.length === 0 && findings.length === 0 && decisions.length === 0 && rates.length === 0

  return (
    <div data-testid="signals-page">
      {/* Header */}
      <div style={{ marginBottom: 20 }}>
        <h1 className="display" style={{ fontSize: 22, fontWeight: 700, color: 'var(--text)', marginBottom: 4 }}>
          Signals
        </h1>
        <p style={{ fontSize: 13, color: 'var(--muted)', maxWidth: 680 }}>
          What is being ingested, and what the policy engine decided about it. Every
          decision here can be reviewed by a human, and the verdict and its reason
          are stored as evidence against the decision.
        </p>
      </div>

      {/* Controls: window, stream, errors from a background poll */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 12,
          flexWrap: 'wrap',
          marginBottom: 18,
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
          <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>
            Window
          </span>
          <WindowSelector value={window} onChange={setWindow} />
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
          <span
            data-testid="stream-status"
            style={{ display: 'flex', alignItems: 'center', gap: 7, fontSize: 12, fontWeight: 600, color: 'var(--text)' }}
          >
            <span
              aria-hidden="true"
              style={{
                width: 8,
                height: 8,
                borderRadius: '50%',
                background: demo ? 'var(--violet)' : paused ? 'var(--amber)' : 'var(--teal)',
              }}
            />
            {demo ? 'Fixtures' : paused ? 'Paused' : 'Live'}
            {!demo && !paused && liveCount > 0 && (
              <span style={{ fontWeight: 400, color: 'var(--muted)' }}>
                {liveCount} streamed
              </span>
            )}
          </span>
          <button
            type="button"
            data-testid="stream-toggle"
            aria-pressed={paused}
            onClick={() => setPaused((p) => !p)}
            style={{
              padding: '6px 14px',
              fontSize: 12,
              fontWeight: 600,
              borderRadius: 'var(--radius-sm, 6px)',
              border: '1px solid var(--border-subtle)',
              background: 'var(--surface2)',
              color: 'var(--text)',
              cursor: 'pointer',
            }}
          >
            {paused ? 'Resume' : 'Pause'}
          </button>
        </div>
      </div>

      {demo && (
        <div
          data-testid="signals-demo-notice"
          style={{
            marginBottom: 18,
            padding: '9px 14px',
            borderRadius: 6,
            background: 'var(--surface2)',
            border: '1px solid var(--border)',
            fontSize: 12,
            color: 'var(--muted)',
          }}
        >
          Demo mode: these signals, findings and decisions are fixtures, and a review
          recorded here is kept in the browser only. Switch demo mode off to read the
          live policy engine.
        </div>
      )}

      {/* A failed background poll, once the page has data on screen. The rows
          below are the last good read, and saying so is more useful than
          replacing them with an error panel. */}
      {error && loaded && (
        <div
          role="alert"
          data-testid="signals-stale-warning"
          style={{
            marginBottom: 18,
            padding: '9px 14px',
            borderRadius: 6,
            background: 'var(--amber-bg)',
            border: '1px solid var(--amber)',
            fontSize: 12,
            color: 'var(--text)',
          }}
        >
          Showing the last successful read. The most recent refresh failed: {error}
        </div>
      )}

      {/* Stat cards */}
      <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 22 }}>
        <StatCard label="Ingested" value={String(totalIngest)} sub={`In the last ${window}`} accent="var(--cyan)" />
        <StatCard label="Findings" value={String(findings.length)} sub="Rules that fired" accent="var(--amber)" />
        <StatCard label="Decisions" value={String(decisions.length)} sub={`${unreviewedTotal} awaiting review`} accent="var(--teal)" />
        <StatCard label="Reviewed" value={String(decisions.length - unreviewedTotal)} sub="Verdict on record" accent="var(--violet)" />
      </div>

      {/* Tabs */}
      <div role="tablist" aria-label="Signals view" style={{ display: 'flex', gap: 4, borderBottom: '1px solid var(--border)', marginBottom: 20 }}>
        {([
          ['live', 'Live'],
          ['decisions', `Decisions${unreviewedTotal > 0 ? ` (${unreviewedTotal})` : ''}`],
        ] as Array<[Tab, string]>).map(([key, label]) => {
          const active = tab === key
          return (
            <button
              key={key}
              type="button"
              role="tab"
              id={`signals-tab-${key}`}
              data-testid={`signals-tab-${key}`}
              aria-selected={active}
              aria-controls={`signals-panel-${key}`}
              onClick={() => setTab(key)}
              style={{
                padding: '8px 16px',
                fontSize: 13,
                fontWeight: 600,
                border: 'none',
                borderBottom: `2px solid ${active ? 'var(--teal)' : 'transparent'}`,
                background: 'none',
                color: active ? 'var(--text)' : 'var(--muted)',
                cursor: 'pointer',
              }}
            >
              {label}
            </button>
          )
        })}
      </div>

      {nothingAtAll && (
        <div className="card" data-testid="signals-empty" style={{ padding: '32px 24px', textAlign: 'center', marginBottom: 22 }}>
          <p style={{ fontSize: 14, color: 'var(--muted)', margin: 0 }}>
            Nothing has been ingested in the last {window}. Widen the window, or check
            that a collector is reporting.
          </p>
        </div>
      )}

      {tab === 'live' ? (
        <div role="tabpanel" id="signals-panel-live" aria-labelledby="signals-tab-live">
          <Section title="Ingest rate by layer" hint={`Per ${bucketFor(window)} bucket, stacked`}>
            <div className="card" style={{ padding: '16px 18px' }}>
              <IngestRateChart
                rates={rates}
                selectedLayer={selectedLayer}
                onSelectLayer={(l) => setSelectedLayer(l)}
              />
            </div>
          </Section>

          <Section title="Sources" hint="Who is reporting, and when they last did">
            <SourceTable rates={rates} />
          </Section>

          <Section title="Live signal feed" hint="Newest first. Projected descriptions, never payloads">
            <ObservationFeed
              observations={observations}
              selectedLayer={selectedLayer}
              onSelectLayer={(l) => setSelectedLayer(l)}
              selectedFidelity={selectedFidelity}
              onSelectFidelity={(f) => setSelectedFidelity(f)}
              searchQuery={searchQuery}
              onSearchChange={(q) => setSearchQuery(q)}
              excludeSentinel={excludeSentinel}
              onToggleSentinel={() => setExcludeSentinel((v) => !v)}
              onClearFilters={() => {
                setSelectedLayer(null)
                setSelectedFidelity(null)
                setSearchQuery('')
                setExcludeSentinel(false)
              }}
            />
          </Section>

          <Section title="Findings in this window" hint="Rules that fired, and the signal behind each">
            <FindingsList findings={findings} />
          </Section>
        </div>
      ) : (
        <div role="tabpanel" id="signals-panel-decisions" aria-labelledby="signals-tab-decisions">
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
            <button
              type="button"
              data-testid="unreviewed-only-toggle"
              aria-pressed={unreviewedOnly}
              onClick={() => setUnreviewedOnly((v) => !v)}
              style={{
                padding: '6px 13px',
                fontSize: 12,
                fontWeight: 600,
                borderRadius: 'var(--radius-sm, 6px)',
                border: `1px solid ${unreviewedOnly ? 'var(--teal)' : 'var(--border-subtle)'}`,
                background: unreviewedOnly ? 'var(--surface2)' : 'transparent',
                color: unreviewedOnly ? 'var(--text)' : 'var(--muted)',
                cursor: 'pointer',
              }}
            >
              Unreviewed only
            </button>
            <span style={{ fontSize: 12, color: 'var(--muted)' }}>
              {visibleDecisions.length} of {decisions.length} shown
            </span>
          </div>

          {visibleDecisions.length === 0 ? (
            <div className="card" data-testid="decisions-empty" style={{ padding: '32px 24px', textAlign: 'center' }}>
              <p style={{ fontSize: 14, color: 'var(--muted)', margin: 0 }}>
                {decisions.length === 0
                  ? `The policy engine reached no decision in the last ${window}.`
                  : 'Every decision in this window has a verdict on record.'}
              </p>
            </div>
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              {visibleDecisions.map((d) => (
                <DecisionCard key={d.id} decision={d} findings={findings} onReview={handleReview} />
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  )
}
