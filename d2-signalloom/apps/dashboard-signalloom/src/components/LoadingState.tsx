import { useEffect, useRef, useState, type CSSProperties } from 'react'
import ErrorState, { isAuthError, redirectToLogin } from './ErrorState'
import PixelLoader from './PixelLoader'

// One status indicator for every surface in the dashboard that waits on an
// event. Four phases, and the fourth one is the point: `idle` means "never
// loaded", which is not the same thing as "loaded and found nothing". A
// dashboard that renders an empty table for both is a dashboard nobody can
// read — the operator cannot tell a healthy zero from a fetch that never ran.
//
// Colour note, because this is where the last bug in this area came from.
// `var(--error)` is NOT usable as body text: measured against the three
// themes it bottoms out at 3.03:1 (Dark, on --surface2), well under the 4.5:1
// AA threshold for text. So the failure *reason* is rendered in --text
// (13.98:1 worst case) and red is carried by the indicator dot and the left
// accent rule, which are graphical and only owe 3:1. Every colour below was
// measured across Dark, Light and Andy on --bg, --surface and --surface2.
// And never reach for `var(--card)`: it is declared by no theme and no :root
// block, so its fallback always wins and the result is invisible under Light.

export type LoadPhase = 'idle' | 'loading' | 'success' | 'error'

/**
 * Collapses the `loading` / `error` / `has-loaded-once` booleans that every
 * page in this codebase already keeps into a single phase. `loaded` has to be
 * passed explicitly — inferring it from "data is non-empty" is exactly how
 * "never loaded" and "loaded and empty" get conflated.
 */
export function loadPhase(input: {
  loading: boolean
  error?: string | null
  loaded?: boolean
}): LoadPhase {
  if (input.loading) return 'loading'
  if (input.error) return 'error'
  if (input.loaded) return 'success'
  return 'idle'
}

/** "just now" / "12s ago" / "2m ago" / "3h ago" / "2d ago". */
export function formatAgo(from: number, now: number = Date.now()): string {
  const secs = Math.max(0, Math.floor((now - from) / 1000))
  if (secs < 5) return 'just now'
  if (secs < 60) return `${secs}s ago`
  const mins = Math.floor(secs / 60)
  if (mins < 60) return `${mins}m ago`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `${hours}h ago`
  return `${Math.floor(hours / 24)}d ago`
}

/**
 * Re-renders often enough that the relative-time line stays honest without a
 * re-fetch: every second while the stamp is inside its first minute, every
 * fifteen after that. Returns the tick count so callers can use it as a
 * dependency — memoising the message without it silently freezes the line at
 * whatever it said on mount, which is worse than showing no time at all.
 */
function useElapsedTicker(stamp: number | null): number {
  const [tick, setTick] = useState(0)
  useEffect(() => {
    if (stamp === null) return
    const period = Date.now() - stamp < 60_000 ? 1_000 : 15_000
    const t = setInterval(() => setTick((n) => n + 1), period)
    return () => clearInterval(t)
    // `tick` is a dependency on purpose: each fire re-runs the effect, which
    // re-reads the elapsed time and so steps 1s cadence up to 15s once the
    // stamp passes a minute old.
  }, [stamp, tick])
  return tick
}

// The reduced-motion hook that used to live here is gone, not lost: the only
// thing that read it was the spinning `Indicator`, and the `loading` phase no
// longer draws one. PixelLoader owns motion now, including freezing its grid
// under `prefers-reduced-motion` while the elapsed figure keeps counting —
// which is strictly more than the dot did, since the dot just stopped.

function buildMessage(
  status: LoadPhase,
  ctx: { successAt: number | null; errorAt: number | null; label?: string; subject: string },
): string {
  const { successAt, errorAt, label, subject } = ctx
  switch (status) {
    case 'loading':
      return successAt !== null
        ? `Refreshing… · last refreshed ${formatAgo(successAt)}`
        : `Loading${subject}…`
    case 'success':
      return successAt !== null ? `Refreshed ${formatAgo(successAt)}` : 'Refreshed'
    case 'error':
      return errorAt !== null ? `Failed ${formatAgo(errorAt)}` : 'Failed'
    case 'idle':
    default:
      return label ? `No${subject} loaded yet` : 'Not loaded yet'
  }
}

export interface LoadingStateProps {
  status: LoadPhase
  /** The thing being loaded, lower case, e.g. "agents", "compliance data". */
  label?: string
  /** Failure reason. Shown verbatim — never replaced with a generic string. */
  error?: string | null
  /**
   * Explicit stamp for the current phase, in epoch ms. Omit it and the
   * component stamps the transition itself, which is what pages that flip
   * `loading` on every poll want. Pages that refresh without touching a
   * loading flag should pass their own stamp so the line keeps moving.
   */
  timestamp?: number | null
  /** `inline` = one-line strip beside a heading. `block` = centred panel. */
  variant?: 'inline' | 'block'
  onRetry?: () => void
  testId?: string
  style?: CSSProperties
}

export default function LoadingState({
  status,
  label,
  error,
  timestamp,
  variant = 'inline',
  onRetry,
  testId = 'loading-state',
  style,
}: LoadingStateProps) {
  // Stamped on the transition into a terminal phase, so a caller that owns no
  // timestamp of its own still gets a truthful "…12s ago".
  const [stamps, setStamps] = useState<{ success: number | null; error: number | null }>({
    success: null,
    error: null,
  })
  const seen = useRef<LoadPhase | null>(null)
  useEffect(() => {
    if (seen.current === status) return
    seen.current = status
    if (status === 'success') setStamps((s) => ({ ...s, success: Date.now() }))
    else if (status === 'error') setStamps((s) => ({ ...s, error: Date.now() }))
  }, [status])

  const successAt = status === 'success' && timestamp != null ? timestamp : stamps.success
  const errorAt = status === 'error' && timestamp != null ? timestamp : stamps.error
  const activeStamp = status === 'error' ? errorAt : successAt
  useElapsedTicker(activeStamp)

  const subject = label ? ` ${label}` : ''

  // Deliberately NOT memoised. formatAgo reads Date.now(), so the output is a
  // function of wall-clock time and not of the props alone — a useMemo keyed
  // on the props freezes the line at whatever it said on mount, which is the
  // exact bug the "counts up while the component just sits there" test in
  // LoadingState.test.tsx caught. Recomputing a switch on every tick is free.
  const message = buildMessage(status, { successAt, errorAt, label, subject })

  const isError = status === 'error'

  // role=alert is assertive by definition and must not also carry aria-live,
  // or some screen readers announce twice.
  const liveProps = isError
    ? ({ role: 'alert' as const })
    : ({ role: 'status' as const, 'aria-live': 'polite' as const })

  // The waiting pattern: a cycling grid, the message, and a live elapsed
  // figure. A dot that spins tells an operator the page is alive and nothing
  // else; forty seconds into a slow query the only question worth answering is
  // "how long has this been going", and this answers it.
  //
  // `announce={false}` because the element above is already the live region —
  // see PixelLoader's `announce` prop. It takes over `${testId}-message`, so
  // the message is still one element with one testid and callers see no change.
  //
  // No `startedAt`: this is mounted on entry to `loading` and unmounted on
  // exit, so mount time is exactly when the wait began, and a second load
  // starts a fresh figure without anyone having to stamp it.
  const waiting = (
    <PixelLoader
      size={variant === 'block' ? 'md' : 'sm'}
      announce={false}
      label={message}
      labelTestId={`${testId}-message`}
      testId={`${testId}-loader`}
    />
  )

  if (variant === 'block') {
    if (isError) {
      return (
        <div
          {...liveProps}
          data-testid={testId}
          data-status={status}
          style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', ...style }}
        >
          <ErrorState message={error || `Failed to load${subject}.`} onRetry={onRetry} />
          <p data-testid={`${testId}-timestamp`} style={{ color: 'var(--muted)', fontSize: 12, marginTop: -4 }}>
            {message}
          </p>
        </div>
      )
    }
    return (
      <div
        {...liveProps}
        data-testid={testId}
        data-status={status}
        style={{
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 12,
          padding: '48px 24px',
          ...style,
        }}
      >
        {status === 'loading' ? (
          waiting
        ) : (
          <>
            <Indicator status={status} size={22} />
            <p data-testid={`${testId}-message`} style={{ color: 'var(--muted)', fontSize: 13, margin: 0 }}>
              {message}
            </p>
          </>
        )}
      </div>
    )
  }

  return (
    <span
      {...liveProps}
      data-testid={testId}
      data-status={status}
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 8,
        fontSize: 12,
        color: 'var(--muted)',
        ...(isError
          ? { borderLeft: '2px solid var(--error)', paddingLeft: 8 }
          : null),
        ...style,
      }}
    >
      {status === 'loading' ? (
        waiting
      ) : (
        <>
          <Indicator status={status} size={12} />
          <span data-testid={`${testId}-message`}>{message}</span>
        </>
      )}
      {isError && error && (
        <>
          <span aria-hidden="true">—</span>
          {/* --text, not --error: see the colour note at the top of this file.
              The separator lives outside this span so the reason is the whole
              of its element's text and stays findable by exact string. */}
          <span data-testid={`${testId}-reason`} title={isAuthError(error) ? error : undefined} style={{ color: 'var(--text)' }}>
            {isAuthError(error) ? 'your session has expired' : error}
          </span>
        </>
      )}
      {/* A 401 cannot be retried — the request was refused, not lost. Offer the
          only action that can actually resolve it. */}
      {isError && error && isAuthError(error) && (
        <button
          type="button"
          data-testid={`${testId}-login`}
          onClick={redirectToLogin}
          style={{
            background: 'none', border: 'none', padding: 0, font: 'inherit',
            color: 'var(--text)', textDecoration: 'underline', cursor: 'pointer',
          }}
        >
          Log in
        </button>
      )}
      {isError && onRetry && !(error && isAuthError(error)) && (
        <button
          type="button"
          onClick={onRetry}
          style={{
            background: 'none',
            border: 'none',
            padding: 0,
            font: 'inherit',
            color: 'var(--text)',
            textDecoration: 'underline',
            cursor: 'pointer',
          }}
        >
          Retry
        </button>
      )}
    </span>
  )
}

/**
 * The settled-phase dot: idle, success, error. Purely decorative and
 * aria-hidden, because the sibling text is what carries the meaning.
 *
 * It draws no `loading` case any more and takes no reduced-motion argument.
 * Both are gone because the spinning ring they existed for is gone — a
 * `loading` phase renders PixelLoader instead, which handles its own motion.
 * Leaving the branch in place would have left a second, unreachable answer to
 * "what does loading look like" for the next person to find and believe.
 */
function Indicator({ status, size }: { status: LoadPhase; size: number }) {
  const base: CSSProperties = {
    width: size,
    height: size,
    borderRadius: '50%',
    flexShrink: 0,
    display: 'inline-block',
  }

  const fill =
    status === 'success' ? 'var(--teal)' : status === 'error' ? 'var(--error)' : 'var(--dim)'
  return (
    <span
      aria-hidden="true"
      data-testid="loading-indicator"
      data-motion="static"
      style={
        status === 'idle'
          ? { ...base, border: '2px solid var(--dim)', boxSizing: 'border-box' }
          : { ...base, background: fill }
      }
    />
  )
}
