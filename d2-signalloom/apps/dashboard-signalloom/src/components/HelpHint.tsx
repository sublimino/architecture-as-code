import { useId, useLayoutEffect, useRef, useState, type CSSProperties } from 'react'

interface Props {
  label: string
  children: string
  testId?: string
  /**
   * CSS colour for the "?" affordance, so a hint can be tied visually to the
   * control it explains — the hint beside a red destructive button reads as
   * belonging to something else when it is cyan. Only the "?" is toned; a
   * coloured popup would read as an error rather than an explanation.
   * Proximity, not colour, is what actually establishes the association.
   */
  tone?: string
}

export interface Rect {
  top: number
  left: number
  width: number
  height: number
}

export interface Viewport {
  width: number
  height: number
}

export interface Placement {
  top: number
  left: number
  width: number
  /** Which side of the anchor the tooltip landed on. */
  vertical: 'below' | 'above'
  /** `start` left-aligns to the anchor, `end` right-aligns, `clamped` shifts to stay on screen. */
  horizontal: 'start' | 'end' | 'clamped'
}

/** Space between the anchor and the tooltip. */
export const HINT_GAP = 6
/** Minimum distance the tooltip keeps from every viewport edge. */
export const HINT_MARGIN = 8
/** Preferred tooltip width, narrowed only when the viewport cannot hold it. */
export const HINT_WIDTH = 260

/** Clamp that degrades to `min` when the range has collapsed or inverted. */
function clamp(value: number, min: number, max: number): number {
  return max < min ? min : Math.min(Math.max(value, min), max)
}

/**
 * Decide where a tooltip goes so it is always fully visible.
 *
 * Coordinates in and out are viewport-relative, matching `getBoundingClientRect`
 * and `position: fixed`. Pure and side-effect free so the geometry can be tested
 * without a browser — jsdom reports all-zero rects, so this is the only place the
 * edge cases can actually be exercised.
 */
export function placeTooltip(anchor: Rect, tip: Rect, viewport: Viewport): Placement {
  // Horizontal: prefer left-aligned, flip to right-aligned, shift as a last resort.
  const width = Math.max(0, Math.min(tip.width, viewport.width - HINT_MARGIN * 2))
  const rightLimit = viewport.width - HINT_MARGIN
  const startLeft = anchor.left
  const endLeft = anchor.left + anchor.width - width

  let horizontal: Placement['horizontal']
  let left: number
  if (startLeft >= HINT_MARGIN && startLeft + width <= rightLimit) {
    horizontal = 'start'
    left = startLeft
  } else if (endLeft >= HINT_MARGIN && endLeft + width <= rightLimit) {
    horizontal = 'end'
    left = endLeft
  } else {
    horizontal = 'clamped'
    left = clamp(startLeft, HINT_MARGIN, rightLimit - width)
  }

  // Vertical: prefer below, flip above, otherwise take the roomier side and clamp.
  const bottomLimit = viewport.height - HINT_MARGIN
  const belowTop = anchor.top + anchor.height + HINT_GAP
  const aboveTop = anchor.top - HINT_GAP - tip.height

  let vertical: Placement['vertical']
  let top: number
  if (belowTop + tip.height <= bottomLimit) {
    vertical = 'below'
    top = belowTop
  } else if (aboveTop >= HINT_MARGIN) {
    vertical = 'above'
    top = aboveTop
  } else {
    const roomAbove = anchor.top - HINT_GAP - HINT_MARGIN
    const roomBelow = bottomLimit - belowTop
    vertical = roomAbove > roomBelow ? 'above' : 'below'
    top = clamp(vertical === 'above' ? aboveTop : belowTop, HINT_MARGIN, bottomLimit - tip.height)
  }

  return { top, left, width, vertical, horizontal }
}

function samePlacement(a: Placement, b: Placement): boolean {
  return a.top === b.top && a.left === b.left && a.width === b.width
    && a.vertical === b.vertical && a.horizontal === b.horizontal
}

/**
 * Every inherited text property that can deform a hint, pinned to a known value.
 *
 * A hint has to look identical wherever it is dropped, and the container it is
 * dropped into gets a vote it never asked for: `text-transform`,
 * `letter-spacing`, `white-space`, `font-weight`, `font-style`, `word-spacing`
 * and `text-align` all inherit. A table header is the case that actually bit —
 * every `th` in this codebase carries
 * `{ textTransform: 'uppercase', letterSpacing: '0.05em', whiteSpace: 'nowrap',
 * fontWeight: 600 }` (DataTable, DashKit and the hand-rolled tables all agree
 * on it), and the tooltip is a DOM descendant of that `th`. `position: fixed`
 * moves where it paints, not where it inherits from, so a full sentence of
 * explanation rendered in BOLD LETTER-SPACED CAPITALS ON ONE UNWRAPPABLE LINE.
 *
 * Fixed here rather than at each call site on purpose. There are ~40 HelpHints
 * across the dashboard and any of them can be moved into a header later; a
 * component that only looks right in the places someone remembered to defend is
 * a component that is wrong by default.
 *
 * The font stack is spelled out for the same reason — a hint inside a `.mono`
 * or `<code>` cell would otherwise render its "?" in JetBrains Mono. It matches
 * `body` in global.css, which `.display`, `.number`, `.kicker` and `.label`
 * already restate for the same reason.
 */
const IMMUNE_TO_INHERITED_TYPOGRAPHY: CSSProperties = {
  fontFamily: "'Inter Tight', ui-sans-serif, system-ui, sans-serif",
  textTransform: 'none',
  letterSpacing: 'normal',
  wordSpacing: 'normal',
  fontStyle: 'normal',
  fontVariant: 'normal',
  textIndent: 0,
}

/** A compact, keyboard-accessible explanation for nearby dashboard controls. */
export default function HelpHint({ label, children, testId, tone = 'var(--cyan)' }: Props) {
  const [open, setOpen] = useState(false)
  const [placement, setPlacement] = useState<Placement | null>(null)
  const anchorRef = useRef<HTMLButtonElement>(null)
  const tipRef = useRef<HTMLSpanElement>(null)
  const id = useId()

  useLayoutEffect(() => {
    if (!open) {
      setPlacement(null)
      return
    }

    const measure = () => {
      const anchorEl = anchorRef.current
      const tipEl = tipRef.current
      if (!anchorEl || !tipEl) return

      const a = anchorEl.getBoundingClientRect()
      const t = tipEl.getBoundingClientRect()
      const next = placeTooltip(
        { top: a.top, left: a.left, width: a.width, height: a.height },
        // jsdom reports zero rects; fall back to the intended size so tests place sanely.
        { top: t.top, left: t.left, width: t.width || HINT_WIDTH, height: t.height },
        { width: window.innerWidth, height: window.innerHeight },
      )
      setPlacement((prev) => (prev && samePlacement(prev, next) ? prev : next))
    }

    measure()
    window.addEventListener('resize', measure)
    // Capture phase: the page scrolls inside <main>, not on window, and a fixed
    // tooltip has to follow its anchor.
    window.addEventListener('scroll', measure, true)
    return () => {
      window.removeEventListener('resize', measure)
      window.removeEventListener('scroll', measure, true)
    }
  }, [open])

  return (
    <span style={{ display: 'inline-flex', alignItems: 'center' }}>
      <span onMouseEnter={() => setOpen(true)} onMouseLeave={() => setOpen(false)}>
        <button
          ref={anchorRef}
          type="button"
          aria-label={label}
          aria-describedby={open ? id : undefined}
          data-testid={testId}
          onBlur={() => setOpen(false)}
          onFocus={() => setOpen(true)}
          style={{
            ...IMMUNE_TO_INHERITED_TYPOGRAPHY,
            width: 18, height: 18, borderRadius: '50%', padding: 0,
            // Longhands, not the `border` shorthand: a shorthand carrying a
            // custom property is unreadable to jsdom, so the tone would be
            // untestable outside a real browser.
            borderWidth: 1, borderStyle: 'solid', borderColor: tone,
            background: 'transparent', color: tone,
            fontSize: 12, fontWeight: 700, lineHeight: 1, cursor: 'help',
            // The 18px circle is the whole affordance, so the glyph has to be
            // centred in it. Inherited `letter-spacing: 0.05em` from a `th`
            // adds a right-side bearing after the "?" and shoves it visibly
            // off-centre; the reset above kills that, and these two make the
            // centring explicit rather than a default someone can inherit away.
            textAlign: 'center', whiteSpace: 'nowrap',
          }}
        >
          ?
        </button>
      </span>
      {open && (
        <span
          ref={tipRef}
          id={id}
          role="tooltip"
          data-placement={placement ? `${placement.vertical}-${placement.horizontal}` : undefined}
          style={{
            // Fixed, not absolute: <main> sets overflow:auto and the app shell sets
            // overflow:hidden, either of which clips an absolutely-positioned tooltip
            // no matter how good the arithmetic is.
            position: 'fixed', zIndex: 10,
            top: placement ? placement.top : 0,
            left: placement ? placement.left : 0,
            width: placement ? placement.width : HINT_WIDTH,
            // Hidden for the single pre-measurement render, which useLayoutEffect
            // resolves before the browser paints.
            visibility: placement ? 'visible' : 'hidden',
            // The tooltip can now sit above the anchor, over unrelated controls;
            // it must never swallow their clicks.
            pointerEvents: 'none',
            padding: '8px 10px', borderRadius: 4,
            background: 'var(--surface)', border: '1px solid var(--border)', color: 'var(--text)',
            boxShadow: '0 6px 18px rgba(0, 0, 0, 0.25)', fontSize: 12, lineHeight: 1.4,
            ...IMMUNE_TO_INHERITED_TYPOGRAPHY,
            // The three the popup needs beyond the shared reset. `whiteSpace`
            // is the load-bearing one: the tooltip is sized to `placement.width`
            // and a `nowrap` inherited from a `th` makes a sentence run straight
            // out of the box the placement arithmetic just measured.
            whiteSpace: 'normal', textAlign: 'left', fontWeight: 400,
          }}
        >
          {children}
        </span>
      )}
    </span>
  )
}
