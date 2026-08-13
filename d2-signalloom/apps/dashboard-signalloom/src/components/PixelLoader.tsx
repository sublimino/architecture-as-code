import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from 'react'

// ─────────────────────────────────────────────────────────────────────────────
// PIXEL LOADER — for work that takes long enough that a spinner stops helping.
//
// A demo step against a live cluster runs for minutes. A spinner says "still
// going" and nothing else; after ninety seconds the instructor cannot tell a
// slow step from a hung one. This says the same thing three ways: a grid that
// is visibly cycling, a label naming what is running, and an elapsed figure
// that keeps counting.
//
// It is no longer only the instructor panel's loader. LoadingState renders it
// for every `loading` phase across the app, so this component now has to
// survive being embedded: `size="sm"` to fit a 12px line, `announce={false}`
// to keep quiet when the host is already a live region, and `labelTestId` so
// the host keeps its own testid convention. Defaults are unchanged, and that
// is deliberate — Instructor Controls passes none of them and must not move.
//
// Variants (design intent, preserved from the source):
//   Drive  square cells, chevron wavefront driving right. The 650ms cycle is
//          deliberately SHORTER than the sweep across the grid, so two fronts
//          are in flight at once — that overlap is the whole look.
//   Dots   the same wavefront with circular cells.
//   Orbit  a comet lapping the perimeter on 950ms; the centre cell stays dark.
//
// PORTING NOTE. The source was a Next.js + Tailwind component and none of it
// ran here. `"use client"` is a Next directive with no meaning under Vite.
// This app has no Tailwind — no config, no PostCSS step, no dependency — so
// every utility class (`grid-cols-[repeat(3,4px)]`, `size-[4px]`, `bg-ink`,
// `tabular-nums`, …) was inert text on an attribute. And `--ink` / `--ink-3`
// are Beautiful-UI tokens that no theme here declares; referencing them would
// have reproduced the `var(--card, #1a1a1a)` bug that DemoToggle shipped with,
// where an undeclared token silently falls back and renders invisible under
// one theme. Everything is therefore inline styles over this app's real
// tokens: --ink → --text, --ink-3 → --muted. src/styles/cssVarUsage.test.ts
// enforces that; do not reach for a token that is not in CSS_VAR_NAMES.
//
// Two things the source promised and did not do, fixed here:
//   1. Its header claimed reduced motion "freezes the grid to its dim state;
//      the timer still ticks". It implemented neither half.
//   2. It counted 100ms interval fires and multiplied. Intervals are a floor,
//      not a guarantee, so the figure fell behind the wall clock by however
//      much the main thread was busy. Elapsed is read from Date.now() against
//      a start stamp instead.
// ─────────────────────────────────────────────────────────────────────────────

export type PixelLoaderVariant = 'Drive' | 'Dots' | 'Orbit'

/** Chevron wavefront: distance from the left-middle cell, 90ms per column. */
const CHEVRON: (number | null)[] = Array.from({ length: 9 }, (_, i) => {
  const r = Math.floor(i / 3)
  const c = i % 3
  return (c + Math.abs(r - 1)) * 90
})

/** Clockwise from the top-left; index 4 (the centre) is absent on purpose. */
const ORBIT_ORDER = [0, 1, 2, 5, 8, 7, 6, 3]
const ORBIT: (number | null)[] = Array.from({ length: 9 }, (_, i) => {
  const k = ORBIT_ORDER.indexOf(i)
  return k === -1 ? null : k * 110
})

const PATTERNS: Record<
  PixelLoaderVariant,
  { delays: (number | null)[]; dur: number; round: boolean }
> = {
  Drive: { delays: CHEVRON, dur: 650, round: false },
  Dots: { delays: CHEVRON, dur: 650, round: true },
  Orbit: { delays: ORBIT, dur: 950, round: false },
}

export type PixelLoaderSize = 'sm' | 'md'

/**
 * Two sizes, because the pattern now has two homes.
 *
 * `md` is the original and the default: a loader that owns its own line,
 * used by Instructor Controls while a demo phase runs. Every number here is
 * the shipped one and must not drift — that panel is what gets demoed.
 *
 * `sm` is for sitting inside a line of 12px text, which is what LoadingState's
 * inline variant is. It scales as a unit rather than just shrinking the grid:
 * a 3px cell on a 1px gutter is 11px of grid, which fits a 12px line without
 * pushing it taller, and the label and figure come down with it so the three
 * parts stay in proportion.
 */
const SIZES: Record<
  PixelLoaderSize,
  { cell: number; cellGap: number; gap: number; labelPx: number; elapsedPx: number }
> = {
  md: { cell: 4, cellGap: 1.5, gap: 10, labelPx: 13, elapsedPx: 12 },
  sm: { cell: 3, cellGap: 1, gap: 6, labelPx: 12, elapsedPx: 11 },
}

const DIM_OPACITY = 0.15
/** Cells the pattern never lights (Orbit's centre) sit below the dim floor. */
const DARK_OPACITY = 0.07

// The keyframes live with the component rather than in global.css. Two
// reasons: the component stays portable — dropping the file into a page
// cannot leave it silently motionless because someone forgot the CSS — and
// global.css is a shared file that concurrent work is editing, so an edit
// there is a merge conflict waiting to happen for no gain. Names are
// `sl-` prefixed because the unprefixed `pixel-on` / `shimmer-text` from the
// source are generic enough to collide with anything.
//
// React renders one <style> per mounted instance. The rules are byte-identical
// and CSS deduplicates them by definition, so N instances cost N small text
// nodes and change nothing about the cascade.
const KEYFRAMES = `
@keyframes sl-pixel-on {
  0%, 100% { opacity: ${DIM_OPACITY}; }
  22%      { opacity: 1; }
}
@keyframes sl-shimmer-text {
  from { background-position: 200% 0; }
  to   { background-position: -200% 0; }
}
`

const REDUCED_MOTION_QUERY = '(prefers-reduced-motion: reduce)'

function readsReducedMotion(): boolean {
  try {
    return window.matchMedia(REDUCED_MOTION_QUERY).matches
  } catch {
    // No matchMedia (older jsdom, exotic embed) — assume motion is fine.
    return false
  }
}

function usePrefersReducedMotion(): boolean {
  const [reduced, setReduced] = useState(readsReducedMotion)
  useEffect(() => {
    let mq: MediaQueryList
    try {
      mq = window.matchMedia(REDUCED_MOTION_QUERY)
    } catch {
      return
    }
    const onChange = (e: MediaQueryListEvent) => setReduced(e.matches)
    mq.addEventListener?.('change', onChange)
    return () => mq.removeEventListener?.('change', onChange)
  }, [])
  return reduced
}

/** `0.0s` … `59.9s`, then `1m 5.0s`. Never negative. */
export function formatElapsed(ms: number): string {
  const total = Math.max(0, ms) / 1000
  if (total < 60) return `${total.toFixed(1)}s`
  return `${Math.floor(total / 60)}m ${(total % 60).toFixed(1)}s`
}

/** How often the figure is re-read. Tenths are shown, so tenths are polled. */
const TICK_MS = 100

/**
 * Writes the elapsed figure straight into a node, ten times a second.
 *
 * Two decisions here, both load-bearing.
 *
 * It re-reads Date.now() rather than incrementing a counter. An interval is a
 * floor, not a schedule: a starved main thread or a backgrounded tab fires it
 * fewer times than the wall clock advances, and a counter loses exactly those
 * tenths while looking completely plausible. The source snippet counted.
 *
 * It mutates textContent instead of holding React state. A 10Hz setState
 * re-renders this subtree ten times a second for a string nobody diffs, and —
 * because these intervals fire outside `act()` — it buries every consuming
 * test suite in act warnings; wiring it into SuperCredInstructorPanel took
 * that suite from 16 warnings to 30 before this. The node is rendered with no
 * React children, so React has nothing to clobber and this owns its text
 * outright. useLayoutEffect, so the first figure is there before first paint
 * rather than a frame of blank.
 */
function useElapsedText(startedAt: number, ref: { current: HTMLElement | null }): void {
  useLayoutEffect(() => {
    const write = () => {
      if (ref.current) ref.current.textContent = formatElapsed(Date.now() - startedAt)
    }
    write()
    const t = setInterval(write, TICK_MS)
    return () => clearInterval(t)
  }, [startedAt, ref])
}

export interface PixelLoaderProps {
  /** What is running. Announced; keep it specific — "Deploy", not "Loading". */
  label?: string
  variant?: PixelLoaderVariant
  /** `md` owns its own line; `sm` sits inside one. See SIZES. */
  size?: PixelLoaderSize
  /** Epoch ms the work began. Defaults to mount, which is usually the same. */
  startedAt?: number
  /**
   * Whether to own a live region. Default true: standalone, this element is
   * the only thing announcing, so it has to.
   *
   * Pass false when the host is ALREADY a live region — LoadingState is, and
   * has been for twenty-odd pages. Two nested regions is not "more
   * accessible"; a screen reader hits both and reads the same sentence twice.
   * The host's region wins rather than this one, because the host's survives
   * the phase change into success or failure and this one is unmounted by it,
   * and a live region that is created at the same instant as its content is
   * announced unreliably or not at all.
   */
  announce?: boolean
  testId?: string
  /**
   * Override for the label's test id. A host that embeds this loader in place
   * of its own text keeps its own `data-testid` convention that way — pages
   * query LoadingState's message as `${testId}-message` and should not have to
   * learn that a loader moved in underneath it.
   */
  labelTestId?: string
  style?: CSSProperties
}

export default function PixelLoader({
  label = 'Churning',
  variant = 'Drive',
  size = 'md',
  startedAt,
  announce = true,
  testId = 'pixel-loader',
  labelTestId,
  style,
}: PixelLoaderProps) {
  const reducedMotion = usePrefersReducedMotion()

  // Mount time is the fallback start. Held in a ref so a re-render (every
  // tick) cannot restart the clock at zero.
  const mountedAt = useRef(Date.now())
  const origin = startedAt ?? mountedAt.current
  const elapsedRef = useRef<HTMLSpanElement | null>(null)
  useElapsedText(origin, elapsedRef)

  const { delays, dur, round } = PATTERNS[variant] ?? PATTERNS.Drive
  const { cell, cellGap, gap, labelPx, elapsedPx } = SIZES[size] ?? SIZES.md

  // See the `announce` prop. Empty when the host already owns a live region.
  const liveProps = announce
    ? ({ role: 'status' as const, 'aria-live': 'polite' as const })
    : {}

  // A span, not a div, so this is legal phrasing content and can be dropped
  // inside a <span> host (LoadingState's inline variant is one) without
  // producing invalid nesting. display:inline-flex was already set, so the box
  // model — and therefore the shipped Instructor Controls rendering — is
  // unchanged by the tag.
  return (
    <span
      {...liveProps}
      data-testid={testId}
      data-size={size}
      style={{ display: 'inline-flex', width: 'fit-content', alignItems: 'center', gap, ...style }}
    >
      <style>{KEYFRAMES}</style>

      <span
        aria-hidden="true"
        data-testid={`${testId}-grid`}
        data-motion={reducedMotion ? 'static' : 'animated'}
        style={{
          display: 'grid',
          gridTemplateColumns: `repeat(3, ${cell}px)`,
          gap: cellGap,
          flexShrink: 0,
        }}
      >
        {delays.map((d, i) => {
          const animated = d !== null && !reducedMotion
          return (
            <span
              key={i}
              data-animated={animated ? 'true' : 'false'}
              data-shape={round ? 'round' : 'square'}
              style={{
                width: cell,
                height: cell,
                background: 'var(--text)',
                borderRadius: round ? '50%' : 1,
                opacity: d === null ? DARK_OPACITY : DIM_OPACITY,
                ...(animated
                  ? { animation: `sl-pixel-on ${dur}ms ease-in-out ${d}ms infinite` }
                  : null),
              }}
            />
          )
        })}
      </span>

      {/* Under reduced motion this is plain --text rather than a frozen
          gradient: a background-clip:text fill that is not moving is just a
          harder way to draw solid text, and one more thing to get wrong. */}
      <span
        data-testid={labelTestId ?? `${testId}-label`}
        data-shimmer={reducedMotion ? 'false' : 'true'}
        style={
          reducedMotion
            ? { fontSize: labelPx, fontWeight: 500, color: 'var(--text)' }
            : {
                fontSize: labelPx,
                fontWeight: 500,
                color: 'transparent',
                backgroundImage:
                  'linear-gradient(90deg, var(--muted) 35%, var(--text) 50%, var(--muted) 65%)',
                backgroundSize: '200% 100%',
                WebkitBackgroundClip: 'text',
                backgroundClip: 'text',
                animation: 'sl-shimmer-text 1.4s linear infinite',
              }
        }
      >
        {label}
      </span>

      {/* aria-hidden, and that is the accessibility decision, not an oversight.
          This element's text changes ten times a second; inside a polite live
          region that is a screen reader reading digits forever. The label
          carries the announcement. */}
      <span
        ref={elapsedRef}
        aria-hidden="true"
        data-testid={`${testId}-elapsed`}
        style={{
          fontFamily: 'monospace',
          fontSize: elapsedPx,
          color: 'var(--muted)',
          fontVariantNumeric: 'tabular-nums',
        }}
      />
    </span>
  )
}
