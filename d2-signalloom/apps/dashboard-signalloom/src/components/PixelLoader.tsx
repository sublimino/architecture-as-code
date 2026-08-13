import { useEffect, useId, useLayoutEffect, useRef, useState, type CSSProperties } from 'react'

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
// the host keeps its own testid convention.
//
// THE DEFAULT VARIANT IS `Loom` — the brand mark. That is a product decision,
// not an implementation detail: the loader is the thing users stare at while
// they wait, so it should be the Signal Loom diamond rather than an anonymous
// pixel grid. No caller in the app passes `variant`, so this default is what
// every loading surface renders — LoadingState's twenty-odd pages, Instructor
// Controls, and the in-button loaders. `Drive`, `Dots` and `Orbit` are
// unchanged and still available by asking for them. There is a test pinning
// the default so it cannot be flipped back by accident.
//
// Variants (design intent, preserved from the source):
//   Drive  square cells, chevron wavefront driving right. The 650ms cycle is
//          deliberately SHORTER than the sweep across the grid, so two fronts
//          are in flight at once — that overlap is the whole look.
//   Dots   the same wavefront with circular cells.
//   Orbit  a comet lapping the perimeter on 950ms; the centre cell stays dark.
//   Loom   the brand mark, woven. Not a 3x3 grid — see LOOM_BARS below.
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

export type PixelLoaderVariant = 'Drive' | 'Dots' | 'Orbit' | 'Loom'

/**
 * The three that are a 3x3 grid of cells. `Loom` is not, so it is not in
 * PATTERNS — see LOOM_BARS. Branching beats forcing a diamond of eight bars
 * into a shape that means "nine cells and a delay each".
 */
type GridVariant = Exclude<PixelLoaderVariant, 'Loom'>

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
  GridVariant,
  { delays: (number | null)[]; dur: number; round: boolean }
> = {
  Drive: { delays: CHEVRON, dur: 650, round: false },
  Dots: { delays: CHEVRON, dur: 650, round: true },
  Orbit: { delays: ORBIT, dur: 950, round: false },
}

// ─── Loom ────────────────────────────────────────────────────────────────────
//
// The brand mark is a diamond — a square rotated 45° — woven from interlaced
// bars, with a hollow square at each of the four corners and one at the
// centre. Full-size it is roughly two dozen bars crossing over and under each
// other. That does not survive being drawn at 15px, and it is not what this
// variant is for; the favicon work already found the same wall and reduced to
// "the diamond outline plus the crossing strokes".
//
// The reduction here is FOUR bars in each direction, evenly spaced. The outer
// bar of each direction is an edge of the diamond, so the four outermost bars
// ARE the frame — no separate outline element, the frame is just the weave's
// selvedge. The two interior bars per direction cross to make a 3x3 lattice,
// which leaves hollow cells at the four corners and at the centre: the same
// five holes the real mark has, and a pleasing echo of the 3x3 grid the other
// three variants draw.
//
// Interlacing is real, not implied. At crossing (i, j) the warp passes over
// iff i + j is even — a plain weave. A bar goes UNDER by having a gap in it at
// that crossing, expressed as a stroke-dasharray, so whatever is behind shows
// through. That matters more than it sounds: the alternative (drawing a
// background-coloured casing under the bar on top) needs to know the page
// colour, and this loader is embedded by LoadingState on surfaces of at least
// two different colours across three themes. A hole is a hole in every theme.
//
// With four bars a side, each interior bar has exactly one interior crossing
// where it dips, so each carries exactly one gap and two dash patterns cover
// all four. Eight bars, one hole each on the inner four.
//
// Colour is the brand gradient rather than --text, because the gradient is
// most of what makes the mark recognisable — a monochrome diamond is just a
// diamond. Values sampled off public/brand/signal-loom-logo.png.

/** Sampled from the shipped mark: left vertex, top vertex, right vertex. */
const LOOM_STOPS = ['#7A42B1', '#518EAD', '#37BF9B'] as const

/**
 * A 24-unit square inside a 40-unit box, rotated 45° about the centre. The
 * box has to hold the diagonal (24√2 ≈ 33.9) plus the square linecaps that
 * close the corners (2 units each way): the extreme corner sits 19.8 from the
 * centre, so 40 fits it with a fifth of a unit to spare.
 */
const LOOM_VIEW = 40
const LOOM_MIN = 8
const LOOM_MAX = 32
const LOOM_STROKE = 4
/** Four bars a side. The first and last are the diamond's frame. */
const LOOM_LINES = [8, 16, 24, 32]
/** Gap width at a crossing, and the two dash runs that place one. */
const LOOM_GAP = 6
/** Bar length 24: gap centred 8 along, and gap centred 16 along. */
const LOOM_DASH_NEAR = `5 ${LOOM_GAP} 13`
const LOOM_DASH_FAR = `13 ${LOOM_GAP} 5`

/**
 * Below this rendered size the weave is drawn WITHOUT its interlace gaps.
 *
 * The gaps are the first thing to die when the mark gets small, and they do
 * not die quietly. A gap is 6 of 40 viewBox units, so at a rendered 11px it is
 * 1.65 CSS px punched through a bar that is itself only 1.1 CSS px wide
 * (stroke 4 of 40). That does not read as "this bar passes underneath"; it
 * chops each interior bar into two ~1.4px stubs that antialias to grey fog and
 * take the diamond's silhouette down with them. Rasterised at 1x and magnified,
 * the woven mark at 11px is a coloured smudge while the same mark with solid
 * bars still reads as a lattice — measured, not assumed.
 *
 * So below the threshold the mark reduces to the diamond outline plus the
 * crossing strokes, which is exactly the reduction the favicon work landed on
 * when it hit this same wall. All eight bars stay, the gradient stays, the
 * wavefront stays; only the over/under goes, and only where it was never
 * legible in the first place.
 *
 * 15 is the `md` footprint, so `md` keeps the full weave and `sm` (14) does
 * not. It is a px threshold rather than a check on the size token so that an
 * arbitrary caller size still gets the right treatment.
 */
const LOOM_MIN_WOVEN_PX = 15

/** Per-bar offset. Weft trails warp by half a step so the two interleave. */
const LOOM_STEP = 90
/** Shorter than the 315ms it takes the front to cross, so two are in flight. */
const LOOM_DUR = 720
/** Frozen and un-lit opacity. Higher than the grid's: a mark, not a pixel. */
const LOOM_DIM = 0.28

interface LoomBar {
  dir: 'warp' | 'weft'
  x1: number
  y1: number
  x2: number
  y2: number
  delay: number
  /** Absent on the frame; the interior bars each dip once. */
  dash?: string
  frame: boolean
}

/**
 * Warp first, then weft, each in wavefront order. Index 1 is the bar at 16 and
 * index 2 the bar at 24, so the plain-weave parity (warp over iff i+j even)
 * puts the warp's dip at the FAR crossing for index 1 and the NEAR one for
 * index 2, and the weft's the other way round.
 */
const LOOM_BARS: LoomBar[] = [
  ...LOOM_LINES.map((x, i): LoomBar => ({
    dir: 'warp',
    x1: x,
    y1: LOOM_MIN,
    x2: x,
    y2: LOOM_MAX,
    delay: i * LOOM_STEP,
    dash: i === 1 ? LOOM_DASH_FAR : i === 2 ? LOOM_DASH_NEAR : undefined,
    frame: i === 0 || i === LOOM_LINES.length - 1,
  })),
  ...LOOM_LINES.map((y, j): LoomBar => ({
    dir: 'weft',
    x1: LOOM_MIN,
    y1: y,
    x2: LOOM_MAX,
    y2: y,
    delay: j * LOOM_STEP + LOOM_STEP / 2,
    dash: j === 1 ? LOOM_DASH_NEAR : j === 2 ? LOOM_DASH_FAR : undefined,
    frame: j === 0 || j === LOOM_LINES.length - 1,
  })),
]

/**
 * The mark. Rotation is a group transform rather than a CSS transform on the
 * <svg> so the gradient rotates with it — which is the whole trick for getting
 * the brand's left-to-right purple→blue→teal onto a shape whose left-to-right
 * axis is a diagonal in the coordinates the bars are written in. rotate(45)
 * maps the vector (1, −1) onto +x, so a userSpaceOnUse gradient run from the
 * bottom-left corner to the top-right one comes out horizontal on screen:
 * purple at the left vertex, teal at the right, blue over the top. Rotating
 * the <svg> instead would have carried the gradient round with it and put
 * purple at the bottom.
 */
function LoomMark({ px, frozen }: { px: number; frozen: boolean }) {
  // Two of these on one page must not share a gradient id — the second
  // definition would win for both. useId emits colons, which are legal in an
  // HTML id but not in a CSS identifier, so they come out.
  const gradientId = `sl-loom-${useId().replace(/:/g, '')}`
  const mid = LOOM_VIEW / 2
  // See LOOM_MIN_WOVEN_PX. Small enough, and the interlace gaps stop being
  // holes and start being fog, so they are not drawn at all.
  const woven = px >= LOOM_MIN_WOVEN_PX

  return (
    <svg
      width={px}
      height={px}
      viewBox={`0 0 ${LOOM_VIEW} ${LOOM_VIEW}`}
      fill="none"
      focusable="false"
      style={{ display: 'block', overflow: 'visible' }}
    >
      <defs>
        <linearGradient
          id={gradientId}
          gradientUnits="userSpaceOnUse"
          x1={LOOM_MIN}
          y1={LOOM_MAX}
          x2={LOOM_MAX}
          y2={LOOM_MIN}
        >
          {LOOM_STOPS.map((colour, i) => (
            <stop key={colour} offset={`${(i / (LOOM_STOPS.length - 1)) * 100}%`} stopColor={colour} />
          ))}
        </linearGradient>
      </defs>

      <g data-loom-weave={woven ? 'woven' : 'plain'} transform={`rotate(45 ${mid} ${mid})`}>
        {LOOM_BARS.map((bar, i) => {
          const dash = woven ? bar.dash : undefined
          return (
            <line
              key={i}
              data-bar={bar.dir}
              data-loom-frame={bar.frame ? 'true' : 'false'}
              data-animated={frozen ? 'false' : 'true'}
              x1={bar.x1}
              y1={bar.y1}
              x2={bar.x2}
              y2={bar.y2}
              stroke={`url(#${gradientId})`}
              strokeWidth={LOOM_STROKE}
              // Square caps close the diamond's corners; the dashed interior
              // bars need butt caps or each cap would eat 2 of the 6-unit gap.
              // Un-woven, every bar is a frame bar and wants the square cap.
              strokeLinecap={dash ? 'butt' : 'square'}
              strokeDasharray={dash}
              style={{
                opacity: LOOM_DIM,
                ...(frozen
                  ? null
                  : { animation: `sl-loom-weave ${LOOM_DUR}ms ease-in-out ${bar.delay}ms infinite` }),
              }}
            />
          )
        })}
      </g>
    </svg>
  )
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
 *
 * `markPx` is the Loom mark's footprint, and it is a separate number rather
 * than the grid's own `cell * 3 + cellGap * 2` because the two shapes do not
 * fill a box the same way. The grid fills it; the diamond is inscribed in it,
 * touching only the four edge midpoints, so it covers half the area and puts
 * four bars across a 45° span instead of three cells across a straight one. At
 * matched footprints the mark is systematically the smaller, denser drawing —
 * fine when Loom was opt-in, not fine now it is the default.
 *
 * At `md` it stays 15, exactly the grid's footprint: that is the shipped
 * Instructor Controls rendering and it must not move. At `sm` it is 14 rather
 * than 11, which is free — the 12px label's line box measures 14px, so the
 * loader's height is 14 for any mark up to 14 and only grows at 15. Three more
 * pixels of mark, no reflow. Nothing at `sm` sets a width (the fixed 78/124/144
 * widths in the panels are all `md`), so the extra 3px of width just moves the
 * label along.
 */
const SIZES: Record<
  PixelLoaderSize,
  { cell: number; cellGap: number; gap: number; labelPx: number; elapsedPx: number; markPx: number }
> = {
  md: { cell: 4, cellGap: 1.5, gap: 10, labelPx: 13, elapsedPx: 12, markPx: 15 },
  sm: { cell: 3, cellGap: 1, gap: 6, labelPx: 12, elapsedPx: 11, markPx: 14 },
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
@keyframes sl-loom-weave {
  0%, 100% { opacity: ${LOOM_DIM}; }
  22%      { opacity: 1; }
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

/**
 * Exported so a second component does not have to grow a fourth copy of this
 * (FleetTopology and FleetRiskGauge each carry an inline one already). The
 * live `change` subscription is the part worth sharing: a preference toggled
 * after mount has to stop the animation, and a one-shot read never does.
 */
export function usePrefersReducedMotion(): boolean {
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
  variant = 'Loom',
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

  const isLoom = variant === 'Loom'
  const { delays, dur, round } = PATTERNS[variant as GridVariant] ?? PATTERNS.Drive
  const { cell, cellGap, gap, labelPx, elapsedPx, markPx } = SIZES[size] ?? SIZES.md

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
        style={
          isLoom
            ? { display: 'inline-flex', flexShrink: 0, lineHeight: 0 }
            : {
                display: 'grid',
                gridTemplateColumns: `repeat(3, ${cell}px)`,
                gap: cellGap,
                flexShrink: 0,
              }
        }
      >
        {isLoom ? <LoomMark px={markPx} frozen={reducedMotion} /> : delays.map((d, i) => {
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
