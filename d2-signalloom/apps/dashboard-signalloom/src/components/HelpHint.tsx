import { useId, useLayoutEffect, useRef, useState } from 'react'

interface Props {
  label: string
  children: string
  testId?: string
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

/** A compact, keyboard-accessible explanation for nearby dashboard controls. */
export default function HelpHint({ label, children, testId }: Props) {
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
            width: 18, height: 18, borderRadius: '50%', padding: 0,
            border: '1px solid var(--cyan)', background: 'transparent', color: 'var(--cyan)',
            fontSize: 12, fontWeight: 700, lineHeight: 1, cursor: 'help',
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
          }}
        >
          {children}
        </span>
      )}
    </span>
  )
}
