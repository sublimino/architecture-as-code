import { act, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import HelpHint, { HINT_GAP, HINT_MARGIN, placeTooltip, type Rect } from './HelpHint'

const ANCHOR: Rect = { top: 300, left: 400, width: 18, height: 18 }
const TIP: Rect = { top: 0, left: 0, width: 260, height: 64 }
const VIEWPORT = { width: 1280, height: 800 }

/** Every edge of the placed tooltip, for "is it on screen" assertions. */
function edges(place: { top: number; left: number; width: number }, height: number) {
  return { top: place.top, bottom: place.top + height, left: place.left, right: place.left + place.width }
}

describe('placeTooltip', () => {
  it('sits below and left-aligned when there is room for both', () => {
    const place = placeTooltip(ANCHOR, TIP, VIEWPORT)

    expect(place.vertical).toBe('below')
    expect(place.horizontal).toBe('start')
    expect(place.top).toBe(ANCHOR.top + ANCHOR.height + HINT_GAP)
    expect(place.left).toBe(ANCHOR.left)
    expect(place.width).toBe(TIP.width)
  })

  it('flips to right-aligned when left-aligning would overflow the right edge', () => {
    // Anchor at the right-hand end of a card header — the real failing case.
    const anchor = { ...ANCHOR, left: VIEWPORT.width - 40 }

    const place = placeTooltip(anchor, TIP, VIEWPORT)

    expect(place.horizontal).toBe('end')
    // Right edge of tooltip aligns with right edge of the anchor.
    expect(place.left + place.width).toBe(anchor.left + anchor.width)
    expect(edges(place, TIP.height).right).toBeLessThanOrEqual(VIEWPORT.width - HINT_MARGIN)
    expect(place.vertical).toBe('below')
  })

  it('shifts back on-screen when the anchor hugs the left edge', () => {
    const anchor = { ...ANCHOR, left: 2 }

    const place = placeTooltip(anchor, TIP, VIEWPORT)

    expect(place.horizontal).toBe('clamped')
    expect(place.left).toBeGreaterThanOrEqual(HINT_MARGIN)
  })

  it('flips above when there is not enough room below', () => {
    const anchor = { ...ANCHOR, top: VIEWPORT.height - 40 }

    const place = placeTooltip(anchor, TIP, VIEWPORT)

    expect(place.vertical).toBe('above')
    expect(place.top).toBe(anchor.top - HINT_GAP - TIP.height)
    expect(edges(place, TIP.height).bottom).toBeLessThanOrEqual(anchor.top)
    expect(place.top).toBeGreaterThanOrEqual(HINT_MARGIN)
  })

  it('stays below when flipping above would overflow the top edge', () => {
    // Tall tip, anchor near the top: above does not fit, below is the lesser evil.
    const anchor = { ...ANCHOR, top: 10 }
    const tip = { ...TIP, height: 200 }

    const place = placeTooltip(anchor, tip, { width: 1280, height: 260 })

    expect(place.top).toBeGreaterThanOrEqual(HINT_MARGIN)
    expect(edges(place, tip.height).bottom).toBeLessThanOrEqual(260 - HINT_MARGIN)
  })

  it('flips on both axes at the bottom-right corner', () => {
    const anchor = { top: VIEWPORT.height - 40, left: VIEWPORT.width - 40, width: 18, height: 18 }

    const place = placeTooltip(anchor, TIP, VIEWPORT)

    expect(place.vertical).toBe('above')
    expect(place.horizontal).toBe('end')
    const box = edges(place, TIP.height)
    expect(box.right).toBeLessThanOrEqual(VIEWPORT.width - HINT_MARGIN)
    expect(box.bottom).toBeLessThanOrEqual(VIEWPORT.height - HINT_MARGIN)
  })

  it('narrows the tooltip when the viewport is narrower than its natural width', () => {
    const viewport = { width: 200, height: 800 }

    const place = placeTooltip({ ...ANCHOR, left: 150 }, TIP, viewport)

    expect(place.width).toBe(viewport.width - HINT_MARGIN * 2)
    expect(place.left).toBe(HINT_MARGIN)
    expect(place.left + place.width).toBeLessThanOrEqual(viewport.width - HINT_MARGIN)
  })

  it('clamps rather than going negative when the tip is taller than the viewport', () => {
    const tip = { ...TIP, height: 900 }

    const place = placeTooltip(ANCHOR, tip, VIEWPORT)

    expect(place.top).toBe(HINT_MARGIN)
    expect(place.left).toBeGreaterThanOrEqual(0)
  })

  it('never overflows any edge, wherever the anchor sits', () => {
    const overflows: string[] = []

    for (let top = 0; top <= VIEWPORT.height; top += 40) {
      for (let left = 0; left <= VIEWPORT.width; left += 40) {
        const place = placeTooltip({ top, left, width: 18, height: 18 }, TIP, VIEWPORT)
        const box = edges(place, TIP.height)
        if (box.left < 0 || box.top < 0 || box.right > VIEWPORT.width || box.bottom > VIEWPORT.height) {
          overflows.push(`anchor(${top},${left}) -> ${JSON.stringify(box)}`)
        }
      }
    }

    expect(overflows).toEqual([])
  })

  it('does not cover the anchor it explains', () => {
    for (const top of [0, 100, 400, 760, 799]) {
      const anchor = { ...ANCHOR, top }
      const place = placeTooltip(anchor, TIP, VIEWPORT)
      const box = edges(place, TIP.height)
      const clear = box.top >= anchor.top + anchor.height || box.bottom <= anchor.top
      expect(clear, `tooltip overlaps anchor at top=${top}`).toBe(true)
    }
  })
})

/** jsdom reports all-zero rects, so edge cases only exist if we fake the geometry. */
function stubGeometry(anchor: Rect, tip: Rect, viewport = VIEWPORT) {
  window.innerWidth = viewport.width
  window.innerHeight = viewport.height
  return vi.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(function (this: Element) {
    const r = this.getAttribute('role') === 'tooltip' ? tip : anchor
    return {
      top: r.top, left: r.left, width: r.width, height: r.height,
      right: r.left + r.width, bottom: r.top + r.height, x: r.left, y: r.top,
      toJSON: () => ({}),
    } as DOMRect
  })
}

const JSDOM_WIDTH = window.innerWidth
const JSDOM_HEIGHT = window.innerHeight

describe('HelpHint', () => {
  afterEach(() => {
    vi.restoreAllMocks()
    // Plain assignments, so restoreAllMocks does not undo them; leaking a 500px
    // viewport into the next test would silently change its geometry.
    window.innerWidth = JSDOM_WIDTH
    window.innerHeight = JSDOM_HEIGHT
  })

  it('shows its explanation on hover and keyboard focus', async () => {
    const user = userEvent.setup()
    render(<HelpHint label="Explain current data">Refreshes current data.</HelpHint>)

    const control = screen.getByRole('button', { name: 'Explain current data' })
    await user.hover(control)
    expect(screen.getByRole('tooltip')).toHaveTextContent('Refreshes current data.')

    await user.unhover(control)
    await user.tab()
    expect(screen.getByRole('tooltip')).toHaveTextContent('Refreshes current data.')
  })

  it('hides again on blur and on mouse leave', async () => {
    const user = userEvent.setup()
    render(<HelpHint label="Explain current data">Refreshes current data.</HelpHint>)

    const control = screen.getByRole('button', { name: 'Explain current data' })
    await user.hover(control)
    expect(screen.getByRole('tooltip')).toBeInTheDocument()
    await user.unhover(control)
    expect(screen.queryByRole('tooltip')).not.toBeInTheDocument()

    await user.tab()
    expect(screen.getByRole('tooltip')).toBeInTheDocument()
    await user.tab()
    expect(screen.queryByRole('tooltip')).not.toBeInTheDocument()
  })

  it('wires aria-describedby to the tooltip only while it is open', async () => {
    const user = userEvent.setup()
    render(<HelpHint label="Explain current data" testId="hint-under-test">Refreshes current data.</HelpHint>)

    const control = screen.getByTestId('hint-under-test')
    expect(control).not.toHaveAttribute('aria-describedby')

    await user.hover(control)
    const tip = screen.getByRole('tooltip')
    expect(control.getAttribute('aria-describedby')).toBe(tip.id)
    expect(tip.id).toBeTruthy()
  })

  it('keeps a right-edge tooltip on screen instead of clipping it', async () => {
    stubGeometry({ top: 300, left: VIEWPORT.width - 40, width: 18, height: 18 }, TIP)
    const user = userEvent.setup()
    render(<HelpHint label="Explain current data">Refreshes current data.</HelpHint>)

    await user.hover(screen.getByRole('button', { name: 'Explain current data' }))

    const tip = screen.getByRole('tooltip')
    expect(tip).toHaveStyle({ position: 'fixed' })
    const left = Number.parseFloat(tip.style.left)
    const width = Number.parseFloat(tip.style.width)
    expect(left + width).toBeLessThanOrEqual(VIEWPORT.width - HINT_MARGIN)
  })

  it('repositions when the viewport is resized while open', async () => {
    stubGeometry({ top: 300, left: 400, width: 18, height: 18 }, TIP)
    const user = userEvent.setup()
    render(<HelpHint label="Explain current data">Refreshes current data.</HelpHint>)

    await user.hover(screen.getByRole('button', { name: 'Explain current data' }))
    expect(Number.parseFloat(screen.getByRole('tooltip').style.left)).toBe(400)

    // Native listener, so React needs an explicit act() to flush the re-render.
    window.innerWidth = 500
    act(() => window.dispatchEvent(new Event('resize')))

    const left = Number.parseFloat(screen.getByRole('tooltip').style.left)
    const width = Number.parseFloat(screen.getByRole('tooltip').style.width)
    expect(left + width).toBeLessThanOrEqual(500 - HINT_MARGIN)
  })

  it('draws the "?" in the cyan token unless told otherwise', () => {
    render(<HelpHint label="Explain current data" testId="hint-under-test">Refreshes current data.</HelpHint>)

    const control = screen.getByTestId('hint-under-test')
    expect(control.style.color).toBe('var(--cyan)')
    expect(control.style.borderColor).toBe('var(--cyan)')
  })

  it('takes the colour of the control it explains', () => {
    render(
      <HelpHint label="What Reset demo does" testId="hint-under-test" tone="var(--error)">
        Tears the demo down.
      </HelpHint>,
    )

    const control = screen.getByTestId('hint-under-test')
    expect(control.style.color).toBe('var(--error)')
    expect(control.style.borderColor).toBe('var(--error)')
  })

  it('tones only the "?" affordance, never the tooltip body', async () => {
    const user = userEvent.setup()
    render(
      <HelpHint label="What Reset demo does" testId="hint-under-test" tone="var(--error)">
        Tears the demo down.
      </HelpHint>,
    )

    await user.hover(screen.getByTestId('hint-under-test'))

    // A red popup would read as an error message rather than an explanation.
    const tip = screen.getByRole('tooltip')
    expect(tip.style.color).toBe('var(--text)')
    expect(tip.style.background).toBe('var(--surface)')
    expect(tip.getAttribute('style')).not.toContain('var(--error)')
  })

  // The deformation this guards against: every `th` in the codebase carries
  // `{ textTransform: 'uppercase', letterSpacing: '0.05em', whiteSpace:
  // 'nowrap', fontWeight: 600 }`, and all four of those properties inherit. The
  // hint is a DOM descendant of the header even though the tooltip paints
  // `position: fixed`, so before the reset a header hint rendered its sentence
  // in bold letter-spaced capitals on one unwrappable line, and the "?" itself
  // sat off-centre in its circle from the trailing 0.05em.
  //
  // Asserted on the declared inline styles rather than getComputedStyle:
  // measured, jsdom does not propagate inherited properties at all — a button
  // inside an uppercase `th` reports `textTransform: "none"` and the tooltip
  // reports `""` whether or not the fix is present, so a computed-style
  // assertion here would pass against the broken component too.
  describe('is immune to the typography of whatever contains it', () => {
    const HEADER_TYPOGRAPHY = {
      textTransform: 'uppercase',
      letterSpacing: '0.05em',
      whiteSpace: 'nowrap',
      fontWeight: 600,
      fontStyle: 'italic',
      fontSize: 11,
    } as const

    /** The same hint, standalone and inside a real uppercase table header. */
    async function renderBothContexts() {
      const user = userEvent.setup()
      const { unmount } = render(
        <HelpHint label="What Selectors means" testId="loose">
          What SPIRE checks about a running pod before it will hand that pod an identity.
        </HelpHint>,
      )
      const loose = screen.getByTestId('loose')
      await user.hover(loose)
      const looseTip = screen.getByRole('tooltip')
      const looseStyles = { button: loose.getAttribute('style'), tip: looseTip.getAttribute('style') }
      unmount()

      render(
        <table>
          <thead>
            <tr>
              <th style={HEADER_TYPOGRAPHY}>
                Selectors
                <HelpHint label="What Selectors means" testId="in-header">
                  What SPIRE checks about a running pod before it will hand that pod an identity.
                </HelpHint>
              </th>
            </tr>
          </thead>
        </table>,
      )
      const inHeader = screen.getByTestId('in-header')
      await user.hover(inHeader)
      const headerTip = screen.getByRole('tooltip')

      return {
        loose: looseStyles,
        header: { button: inHeader.getAttribute('style'), tip: headerTip.getAttribute('style') },
        headerButton: inHeader,
        headerTip,
      }
    }

    it('renders identically inside an uppercase table header and outside one', async () => {
      const { loose, header } = await renderBothContexts()

      // Byte-identical, because the component defends itself — no caller has
      // to. This one is the guard against the other available fix: patching
      // the ~40 call sites that sit in headers. It would go green there too,
      // and then the next hint moved into a `th` would be broken again.
      expect(header.button).toBe(loose.button)
      expect(header.tip).toBe(loose.tip)
    })

    it('pins the "?" against an inherited uppercase and letter-spacing', async () => {
      const { headerButton } = await renderBothContexts()

      expect(headerButton.style.textTransform).toBe('none')
      expect(headerButton.style.letterSpacing).toBe('normal')
      // Its own size and weight, not the header's 11px/600.
      expect(headerButton.style.fontSize).toBe('12px')
      expect(headerButton.style.fontWeight).toBe('700')
      expect(headerButton.style.fontStyle).toBe('normal')
      expect(headerButton.textContent).toBe('?')
    })

    it('keeps the explanation lower case, unbolded and wrappable inside a header', async () => {
      const { headerTip } = await renderBothContexts()

      expect(headerTip.style.textTransform).toBe('none')
      expect(headerTip.style.letterSpacing).toBe('normal')
      expect(headerTip.style.fontWeight).toBe('400')
      expect(headerTip.style.fontStyle).toBe('normal')
      // The one that actually breaks the placement arithmetic: a `nowrap`
      // inherited from the header runs the sentence out of the measured box.
      expect(headerTip.style.whiteSpace).toBe('normal')
      expect(headerTip.textContent).toContain('What SPIRE checks')
    })

    it('names its own font so a mono cell cannot recast the "?"', async () => {
      const user = userEvent.setup()
      render(
        <code className="mono">
          <HelpHint label="What this means" testId="in-mono">Explained here.</HelpHint>
        </code>,
      )

      const control = screen.getByTestId('in-mono')
      expect(control.style.fontFamily).toContain('Inter Tight')
      await user.hover(control)
      expect(screen.getByRole('tooltip').style.fontFamily).toContain('Inter Tight')
    })
  })

  it('removes its resize and scroll listeners when it closes', async () => {
    const remove = vi.spyOn(window, 'removeEventListener')
    const user = userEvent.setup()
    render(<HelpHint label="Explain current data">Refreshes current data.</HelpHint>)

    const control = screen.getByRole('button', { name: 'Explain current data' })
    await user.hover(control)
    await user.unhover(control)

    const removed = remove.mock.calls.map((c) => c[0])
    expect(removed).toContain('resize')
    expect(removed).toContain('scroll')
  })
})
