/**
 * The pixel-grid loader for long-running work.
 *
 * The component under test is a port of a Next.js + Tailwind snippet into this
 * app, which has neither. Two of these tests exist because the original was
 * wrong rather than merely incompatible:
 *
 *   * its header comment promised "reduced motion freezes the grid to its dim
 *     state; the timer still ticks" and the code implemented neither half;
 *   * it counted 100ms ticks and multiplied, so the figure drifted behind the
 *     wall clock by however much the event loop was busy — on a five-minute
 *     demo step, visibly.
 *
 * Both are pinned below. The name is `PixelLoader`, not `LoadingState`:
 * `LoadingState` is already taken by the four-phase idle/loading/success/error
 * status line used by twenty-odd pages, and this is a different thing.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import PixelLoader, { formatElapsed } from './PixelLoader'

/** Swap the global matchMedia stub for one that reports a given preference. */
function setReducedMotion(reduced: boolean) {
  const original = globalThis.matchMedia
  globalThis.matchMedia = ((query: string) => ({
    matches: reduced && query.includes('prefers-reduced-motion'),
    media: query,
    onchange: null,
    addListener: vi.fn(),
    removeListener: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    dispatchEvent: vi.fn(),
  })) as unknown as typeof globalThis.matchMedia
  return () => {
    globalThis.matchMedia = original
  }
}

function cells(): HTMLElement[] {
  return Array.from(screen.getByTestId('pixel-loader-grid').children) as HTMLElement[]
}

/** The Loom variant draws bars, not grid cells. Both live under the same node. */
function bars(): SVGLineElement[] {
  return Array.from(
    screen.getByTestId('pixel-loader-grid').querySelectorAll('line[data-bar]'),
  ) as SVGLineElement[]
}

describe('formatElapsed', () => {
  it('renders tenths under a minute', () => {
    expect(formatElapsed(0)).toBe('0.0s')
    expect(formatElapsed(12_340)).toBe('12.3s')
    expect(formatElapsed(59_900)).toBe('59.9s')
  })

  it('switches to minutes and seconds at sixty', () => {
    expect(formatElapsed(60_000)).toBe('1m 0.0s')
    expect(formatElapsed(65_000)).toBe('1m 5.0s')
    expect(formatElapsed(3_725_400)).toBe('62m 5.4s')
  })

  it('never renders a negative figure', () => {
    // A clock that steps backwards (NTP correction, a caller passing a future
    // stamp) must not produce "-3.0s" on stage.
    expect(formatElapsed(-3_000)).toBe('0.0s')
  })
})

describe('PixelLoader', () => {
  let restoreMedia: (() => void) | null = null

  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: false })
    vi.setSystemTime(new Date('2026-08-13T09:00:00Z'))
  })

  afterEach(() => {
    restoreMedia?.()
    restoreMedia = null
    vi.useRealTimers()
  })

  it('renders the supplied label', () => {
    render(<PixelLoader label="Running phase 3 · Compliance scan" />)
    expect(screen.getByTestId('pixel-loader-label')).toHaveTextContent(
      'Running phase 3 · Compliance scan',
    )
  })

  it('announces itself as a polite status region', () => {
    render(<PixelLoader label="Churning" />)
    const root = screen.getByTestId('pixel-loader')
    expect(root).toHaveAttribute('role', 'status')
    expect(root).toHaveAttribute('aria-live', 'polite')
    expect(screen.getByRole('status')).toBe(root)
  })

  it('hides the grid from assistive technology', () => {
    render(<PixelLoader label="Churning" />)
    expect(screen.getByTestId('pixel-loader-grid')).toHaveAttribute('aria-hidden', 'true')
  })

  it('keeps the ticking figure out of the live region', () => {
    // A polite live region that re-announces ten times a second is unusable.
    // The label is what gets announced; the timer is decoration for the eye.
    render(<PixelLoader label="Churning" />)
    expect(screen.getByTestId('pixel-loader-elapsed')).toHaveAttribute('aria-hidden', 'true')
  })

  // `variant="Drive"` is explicit here and everywhere else that counts cells.
  // Nine cells is a property of the grid variants, not of the component, and
  // the default is `Loom`, which draws bars. A test that says "Drive" when it
  // means Drive keeps working whatever the default is next.
  it('renders nine cells for the grid variants', () => {
    render(<PixelLoader label="Churning" variant="Drive" />)
    expect(cells()).toHaveLength(9)
  })

  it('counts up from mount in tenths', () => {
    render(<PixelLoader label="Churning" />)
    expect(screen.getByTestId('pixel-loader-elapsed')).toHaveTextContent('0.0s')

    act(() => {
      vi.advanceTimersByTime(1_500)
    })
    expect(screen.getByTestId('pixel-loader-elapsed')).toHaveTextContent('1.5s')

    act(() => {
      vi.advanceTimersByTime(63_500)
    })
    expect(screen.getByTestId('pixel-loader-elapsed')).toHaveTextContent('1m 5.0s')
  })

  it('reads elapsed from the wall clock, not from a tick count', () => {
    // The original incremented a counter per interval fire, so any fire the
    // event loop swallowed was a tenth of a second silently lost. Simulate
    // that by moving the clock further than the timers that fired.
    render(<PixelLoader label="Churning" />)
    act(() => {
      vi.advanceTimersByTime(200) // two fires
      vi.setSystemTime(Date.now() + 9_800) // …but ten seconds of wall clock
      vi.advanceTimersByTime(100) // one more fire, which re-reads the clock
    })
    expect(screen.getByTestId('pixel-loader-elapsed')).toHaveTextContent('10.1s')
  })

  it('counts from an explicit start stamp when one is given', () => {
    render(<PixelLoader label="Churning" startedAt={Date.now() - 4_200} />)
    expect(screen.getByTestId('pixel-loader-elapsed')).toHaveTextContent('4.2s')
  })

  // No caller in the app passes `variant`, so whatever this default is IS the
  // loader the product shows — LoadingState's twenty-odd pages, Instructor
  // Controls, and the in-button loaders all inherit it. It is the brand mark
  // deliberately, and it is pinned here so that flipping it back is a failing
  // test rather than a quiet change of appearance across the whole app.
  describe('the default variant', () => {
    it('is Loom — the brand mark, not the anonymous pixel grid', () => {
      render(<PixelLoader label="Churning" />)
      expect(bars()).toHaveLength(8)
      expect(screen.getByTestId('pixel-loader-grid').querySelectorAll('[data-shape]')).toHaveLength(0)
    })

    it('is Loom at sm too, where LoadingState renders it inline', () => {
      render(<PixelLoader label="Churning" size="sm" />)
      expect(bars()).toHaveLength(8)
      expect(screen.getByTestId('pixel-loader-grid').querySelectorAll('[data-shape]')).toHaveLength(0)
    })

    it('draws the mark at the right size without being asked, at both sizes', () => {
      const { container: md } = render(<PixelLoader label="Churning" testId="d-md" />)
      expect(md.querySelector('svg')?.getAttribute('width')).toBe('15')
      const { container: sm } = render(<PixelLoader label="Churning" size="sm" testId="d-sm" />)
      expect(sm.querySelector('svg')?.getAttribute('width')).toBe('14')
    })

    it('carries the brand gradient by default', () => {
      // The whole reason for the change: an unconfigured loader is on-brand.
      const { container } = render(<PixelLoader label="Churning" />)
      expect(
        Array.from(container.querySelectorAll('linearGradient stop')).map(s =>
          s.getAttribute('stop-color'),
        ),
      ).toEqual(['#7A42B1', '#518EAD', '#37BF9B'])
    })

    it('still announces, still labels, still counts', () => {
      // Everything the default already promised has to survive the new mark.
      render(<PixelLoader label="Loading agents…" />)
      const root = screen.getByTestId('pixel-loader')
      expect(root).toHaveAttribute('role', 'status')
      expect(root).toHaveAttribute('aria-live', 'polite')
      expect(screen.getByTestId('pixel-loader-label')).toHaveTextContent('Loading agents…')
      act(() => {
        vi.advanceTimersByTime(1_300)
      })
      expect(screen.getByTestId('pixel-loader-elapsed')).toHaveTextContent('1.3s')
    })

    it('is overridable — the other three are still one prop away', () => {
      render(<PixelLoader label="Churning" variant="Drive" />)
      expect(cells()).toHaveLength(9)
      expect(screen.getByTestId('pixel-loader').querySelectorAll('line[data-bar]')).toHaveLength(0)
    })
  })

  describe('variants', () => {
    it('Drive animates every cell as a square', () => {
      render(<PixelLoader label="Churning" variant="Drive" />)
      const all = cells()
      expect(all).toHaveLength(9)
      expect(all.every(c => c.dataset.animated === 'true')).toBe(true)
      expect(all.every(c => c.dataset.shape === 'square')).toBe(true)
    })

    it('Dots is the same wavefront with round cells', () => {
      render(<PixelLoader label="Churning" variant="Dots" />)
      const all = cells()
      expect(all.every(c => c.dataset.animated === 'true')).toBe(true)
      expect(all.every(c => c.dataset.shape === 'round')).toBe(true)
    })

    it('Orbit laps the perimeter and leaves the centre dark', () => {
      render(<PixelLoader label="Churning" variant="Orbit" />)
      const all = cells()
      expect(all.filter(c => c.dataset.animated === 'true')).toHaveLength(8)
      expect(all[4].dataset.animated).toBe('false')
    })

    it('falls back to Drive for an unknown variant', () => {
      render(<PixelLoader label="Churning" variant={'Nonsense' as 'Drive'} />)
      expect(cells().every(c => c.dataset.animated === 'true')).toBe(true)
    })
  })

  // The Loom variant is the only one that is not a 3x3 grid, so it gets its
  // own block. It draws the brand mark — a square rotated 45°, woven from four
  // warp bars and four weft bars — and weaves it in sequence. Everything the
  // other variants promise (size, reduced motion, announce, label, clock) has
  // to survive the different geometry; that is most of what is pinned here.
  describe('the Loom variant', () => {
    it('renders, and says it is moving on the same node the others use', () => {
      render(<PixelLoader label="Weaving" variant="Loom" />)
      const grid = screen.getByTestId('pixel-loader-grid')
      expect(grid).toHaveAttribute('data-motion', 'animated')
      expect(grid).toHaveAttribute('aria-hidden', 'true')
    })

    it('draws eight bars — four warp, four weft — and animates every one', () => {
      render(<PixelLoader label="Weaving" variant="Loom" />)
      const all = bars()
      expect(all).toHaveLength(8)
      expect(all.filter(b => b.dataset.bar === 'warp')).toHaveLength(4)
      expect(all.filter(b => b.dataset.bar === 'weft')).toHaveLength(4)
      expect(all.every(b => b.dataset.animated === 'true')).toBe(true)
      expect(all.every(b => (b.getAttribute('style') ?? '').includes('sl-loom-weave'))).toBe(true)
    })

    it('does not render the 3x3 grid as well', () => {
      // Belt and braces: the branch replaces the grid, it does not add to it.
      render(<PixelLoader label="Weaving" variant="Loom" />)
      expect(
        screen.getByTestId('pixel-loader-grid').querySelectorAll('[data-shape]'),
      ).toHaveLength(0)
    })

    it('staggers the bars into a travelling wavefront', () => {
      // Same technique as Drive: one duration, fixed per-element offsets. That
      // makes the whole composition periodic in the duration, so it loops
      // seamlessly however long it runs.
      render(<PixelLoader label="Weaving" variant="Loom" />)
      const delays = bars().map(b => {
        const m = (b.getAttribute('style') ?? '').match(/sl-loom-weave\s+(\d+)ms[^;]*?\s(\d+(?:\.\d+)?)ms/)
        return { dur: Number(m?.[1]), delay: Number(m?.[2]) }
      })
      expect(delays.every(d => Number.isFinite(d.delay))).toBe(true)
      // Every bar shares one duration, and no offset reaches it.
      const durations = new Set(delays.map(d => d.dur))
      expect(durations.size).toBe(1)
      expect(Math.max(...delays.map(d => d.delay))).toBeLessThan([...durations][0])
      // Warp leads, weft follows half a step behind, so the two directions
      // interleave rather than lighting in lockstep.
      const warp = delays.slice(0, 4).map(d => d.delay)
      const weft = delays.slice(4).map(d => d.delay)
      expect(warp).toEqual([...warp].sort((a, b) => a - b))
      expect(new Set(warp.concat(weft)).size).toBe(8)
    })

    it('interlaces: the interior bars break at the crossings they pass under', () => {
      // A gap is how a bar goes under another one without needing to know what
      // colour the page behind it is. The four outer bars are the diamond's
      // frame and stay solid; each of the four interior bars dips exactly once.
      render(<PixelLoader label="Weaving" variant="Loom" />)
      const dashed = bars().filter(b => b.getAttribute('stroke-dasharray'))
      expect(dashed).toHaveLength(4)
      expect(bars().filter(b => b.dataset.loomFrame === 'true')).toHaveLength(4)
      expect(dashed.every(b => b.dataset.loomFrame !== 'true')).toBe(true)
    })

    it('carries the brand gradient, purple through blue to teal', () => {
      const { container } = render(<PixelLoader label="Weaving" variant="Loom" />)
      const stops = Array.from(container.querySelectorAll('linearGradient stop'))
      expect(stops).toHaveLength(3)
      expect(stops.map(s => s.getAttribute('stop-color'))).toEqual([
        '#7A42B1',
        '#518EAD',
        '#37BF9B',
      ])
      const id = container.querySelector('linearGradient')?.getAttribute('id') ?? ''
      expect(id).not.toBe('')
      expect(bars().every(b => b.getAttribute('stroke') === `url(#${id})`)).toBe(true)
    })

    it('gives each instance its own gradient id', () => {
      // Two loaders on one page sharing an id means one of them silently wins.
      const { container } = render(
        <>
          <PixelLoader label="One" variant="Loom" testId="loom-a" />
          <PixelLoader label="Two" variant="Loom" testId="loom-b" />
        </>,
      )
      const ids = Array.from(container.querySelectorAll('linearGradient')).map(g => g.id)
      expect(ids).toHaveLength(2)
      expect(new Set(ids).size).toBe(2)
      // React's useId emits colons, which are not legal in a CSS identifier.
      expect(ids.every(id => !id.includes(':'))).toBe(true)
    })

    it('defines the keyframe it references', () => {
      const { container } = render(<PixelLoader label="Weaving" variant="Loom" />)
      expect(container.querySelector('style')?.textContent ?? '').toContain(
        '@keyframes sl-loom-weave',
      )
    })

    it('keeps the label and the ticking figure', () => {
      render(<PixelLoader label="Weaving cloth" variant="Loom" />)
      expect(screen.getByTestId('pixel-loader-label')).toHaveTextContent('Weaving cloth')
      act(() => {
        vi.advanceTimersByTime(2_100)
      })
      expect(screen.getByTestId('pixel-loader-elapsed')).toHaveTextContent('2.1s')
    })

    it('drops the live region when announce is false', () => {
      const { container } = render(
        <PixelLoader label="Weaving" variant="Loom" announce={false} />,
      )
      const root = screen.getByTestId('pixel-loader')
      expect(root).not.toHaveAttribute('role')
      expect(root).not.toHaveAttribute('aria-live')
      expect(container.querySelectorAll('[aria-live]')).toHaveLength(0)
    })

    it('lets the host keep its own testid for the label', () => {
      render(<PixelLoader label="Weaving" variant="Loom" labelTestId="loading-state-message" />)
      expect(screen.getByTestId('loading-state-message')).toHaveTextContent('Weaving')
    })

    describe('size', () => {
      // The mark is square. At md it takes the grid's own footprint, so a Loom
      // loader occupies exactly the line a Drive loader would — that is the
      // shipped Instructor Controls rendering and it must not move.
      it('renders at md the same width the 3x3 grid occupies', () => {
        const { container } = render(<PixelLoader label="Weaving" variant="Loom" />)
        expect(screen.getByTestId('pixel-loader')).toHaveAttribute('data-size', 'md')
        const svg = container.querySelector('svg')
        expect(svg?.getAttribute('width')).toBe('15') // 3 cells of 4px + 2 gutters of 1.5px
        expect(svg?.getAttribute('height')).toBe('15')
      })

      // At sm it does NOT match the grid's 11px footprint, and that is the
      // point. A diamond is inscribed in its box — it touches the four edge
      // midpoints and covers half the area — so at a matched footprint it is
      // always the smaller, denser drawing, with four bars across a 45° span
      // where the grid has three cells across a straight one. 11px of that is
      // a smudge. 14px is the largest it can be for free: the 12px label's
      // line box measures 14px, so the loader is 14px tall for any mark up to
      // 14 and only grows at 15.
      it('gets its own slightly larger footprint at sm, which costs no height', () => {
        const { container } = render(<PixelLoader label="Weaving" variant="Loom" size="sm" />)
        expect(screen.getByTestId('pixel-loader')).toHaveAttribute('data-size', 'sm')
        const svg = container.querySelector('svg')
        expect(svg?.getAttribute('width')).toBe('14')
        expect(svg?.getAttribute('height')).toBe('14')
        expect(screen.getByTestId('pixel-loader-label').style.fontSize).toBe('12px')
        expect(bars()).toHaveLength(8)
      })

      // 14 is a ceiling, not a preference: 15 is where the label's line box
      // stops absorbing the mark and the inline row starts getting taller.
      it('keeps the sm mark inside the 12px line box it has to sit in', () => {
        const { container } = render(<PixelLoader label="Weaving" variant="Loom" size="sm" />)
        const px = Number(container.querySelector('svg')?.getAttribute('width'))
        expect(px).toBeGreaterThan(11) // bigger than the grid, or it is a smudge
        expect(px).toBeLessThanOrEqual(14) // 15 would push the inline line taller
      })
    })

    // The interlace gaps are the first thing to die when the mark gets small.
    // A gap is 6 of 40 viewBox units, so at sm it is ~1.6 CSS px cut through a
    // bar ~1.1 CSS px wide: it does not read as "passes underneath", it chops
    // each interior bar into antialiased stubs and fogs the whole mark. Below
    // the threshold the mark reduces to the diamond outline plus the crossing
    // strokes — the same reduction the favicon work landed on.
    describe('interlacing below the legibility threshold', () => {
      it('keeps the full weave at md, where the gaps are big enough to read', () => {
        render(<PixelLoader label="Weaving" variant="Loom" />)
        expect(bars().filter(b => b.getAttribute('stroke-dasharray'))).toHaveLength(4)
      })

      it('drops the gaps at sm rather than drawing them sub-pixel', () => {
        render(<PixelLoader label="Weaving" variant="Loom" size="sm" />)
        expect(bars().filter(b => b.getAttribute('stroke-dasharray'))).toHaveLength(0)
      })

      it('drops nothing else — same eight bars, same gradient, same wavefront', () => {
        // Un-weaving must not become "a different mark at small size".
        const { container } = render(<PixelLoader label="Weaving" variant="Loom" size="sm" />)
        const all = bars()
        expect(all).toHaveLength(8)
        expect(all.filter(b => b.dataset.bar === 'warp')).toHaveLength(4)
        expect(all.filter(b => b.dataset.bar === 'weft')).toHaveLength(4)
        expect(all.every(b => b.dataset.animated === 'true')).toBe(true)
        expect(all.every(b => (b.getAttribute('style') ?? '').includes('sl-loom-weave'))).toBe(true)
        const id = container.querySelector('linearGradient')?.getAttribute('id') ?? ''
        expect(all.every(b => b.getAttribute('stroke') === `url(#${id})`)).toBe(true)
      })

      it('gives every bar a square cap once there are no gaps to protect', () => {
        // Butt caps exist so a 2-unit cap does not eat a third of a 6-unit
        // gap. With no gaps, butt caps would just leave the corners open.
        render(<PixelLoader label="Weaving" variant="Loom" size="sm" />)
        expect(bars().every(b => b.getAttribute('stroke-linecap') === 'square')).toBe(true)
      })

      it('says which treatment it used, so a host can assert it cheaply', () => {
        const { container: md } = render(<PixelLoader label="W" variant="Loom" testId="a" />)
        expect(md.querySelector('[data-loom-weave]')).toHaveAttribute('data-loom-weave', 'woven')
        const { container: sm } = render(
          <PixelLoader label="W" variant="Loom" size="sm" testId="b" />,
        )
        expect(sm.querySelector('[data-loom-weave]')).toHaveAttribute('data-loom-weave', 'plain')
      })
    })

    describe('prefers-reduced-motion: reduce', () => {
      beforeEach(() => {
        restoreMedia = setReducedMotion(true)
      })

      it('freezes the weave to a dim static state', () => {
        render(<PixelLoader label="Weaving" variant="Loom" />)
        const all = bars()
        expect(all).toHaveLength(8)
        expect(all.every(b => b.dataset.animated === 'false')).toBe(true)
        expect(all.every(b => (b.getAttribute('style') ?? '').includes('animation'))).toBe(false)
        expect(screen.getByTestId('pixel-loader-grid')).toHaveAttribute('data-motion', 'static')
      })

      it('keeps the mark visible rather than blanking it', () => {
        // Frozen is not gone. A dim mark still says "there is a loader here".
        render(<PixelLoader label="Weaving" variant="Loom" />)
        const opacities = bars().map(b => Number(b.style.opacity))
        expect(opacities.every(o => o > 0 && o < 1)).toBe(true)
        expect(new Set(opacities).size).toBe(1)
      })

      it('keeps the timer ticking while the weave is still', () => {
        render(<PixelLoader label="Weaving" variant="Loom" />)
        act(() => {
          vi.advanceTimersByTime(3_400)
        })
        expect(screen.getByTestId('pixel-loader-elapsed')).toHaveTextContent('3.4s')
        expect(bars().every(b => b.dataset.animated === 'false')).toBe(true)
      })

      it('freezes at sm as well', () => {
        render(<PixelLoader label="Weaving" variant="Loom" size="sm" />)
        expect(bars().every(b => b.dataset.animated === 'false')).toBe(true)
      })
    })
  })

  describe('prefers-reduced-motion: reduce', () => {
    beforeEach(() => {
      restoreMedia = setReducedMotion(true)
    })

    it('freezes the grid to its dim state', () => {
      render(<PixelLoader label="Churning" variant="Drive" />)
      const all = cells()
      expect(all).toHaveLength(9)
      expect(all.every(c => c.dataset.animated === 'false')).toBe(true)
      expect(all.every(c => (c.getAttribute('style') ?? '').includes('animation'))).toBe(false)
    })

    it('stops the label shimmering but still shows it', () => {
      render(<PixelLoader label="Churning" />)
      const label = screen.getByTestId('pixel-loader-label')
      expect(label).toHaveTextContent('Churning')
      expect(label.dataset.shimmer).toBe('false')
      expect(label.getAttribute('style') ?? '').not.toContain('animation')
    })

    it('keeps the timer ticking', () => {
      render(<PixelLoader label="Churning" />)
      act(() => {
        vi.advanceTimersByTime(2_300)
      })
      expect(screen.getByTestId('pixel-loader-elapsed')).toHaveTextContent('2.3s')
    })

    it('says so on the grid, so a host can assert it without reading nine cells', () => {
      render(<PixelLoader label="Churning" />)
      expect(screen.getByTestId('pixel-loader-grid')).toHaveAttribute('data-motion', 'static')
    })

    it('freezes at sm as well', () => {
      render(<PixelLoader label="Churning" variant="Drive" size="sm" />)
      expect(cells().every(c => c.dataset.animated === 'false')).toBe(true)
    })

    // The same guarantee, reached the way the app reaches it: no variant prop.
    it('freezes the default loader at both sizes, and keeps the clock running', () => {
      for (const size of ['md', 'sm'] as const) {
        const testId = `rm-${size}`
        render(<PixelLoader label="Churning" size={size} testId={testId} />)
        const grid = screen.getByTestId(`${testId}-grid`)
        expect(grid).toHaveAttribute('data-motion', 'static')
        expect(
          Array.from(grid.querySelectorAll('line[data-bar]')).every(
            b => (b as SVGLineElement).dataset.animated === 'false',
          ),
        ).toBe(true)
      }
      act(() => {
        vi.advanceTimersByTime(5_600)
      })
      expect(screen.getByTestId('rm-md-elapsed')).toHaveTextContent('5.6s')
      expect(screen.getByTestId('rm-sm-elapsed')).toHaveTextContent('5.6s')
    })
  })

  // LoadingState's inline variant is a 12px line of text beside a heading.
  // The panel-sized loader does not fit in one, and shrinking only the grid
  // leaves a 4px block against a 13px label looking like a mistake.
  describe('size', () => {
    it('defaults to md, and md is the rendering Instructor Controls already ships', () => {
      render(<PixelLoader label="Churning" variant="Drive" />)
      expect(screen.getByTestId('pixel-loader')).toHaveAttribute('data-size', 'md')
      expect(cells()[0].style.width).toBe('4px')
      expect(screen.getByTestId('pixel-loader-label').style.fontSize).toBe('13px')
      expect(screen.getByTestId('pixel-loader-elapsed').style.fontSize).toBe('12px')
    })

    it('scales the whole thing down at sm, not just the grid', () => {
      render(<PixelLoader label="Churning" variant="Drive" size="sm" />)
      expect(screen.getByTestId('pixel-loader')).toHaveAttribute('data-size', 'sm')
      expect(cells()[0].style.width).toBe('3px')
      expect(cells()[0].style.height).toBe('3px')
      expect(screen.getByTestId('pixel-loader-label').style.fontSize).toBe('12px')
      expect(screen.getByTestId('pixel-loader-elapsed').style.fontSize).toBe('11px')
    })

    it('is the same loader at sm — nine cells, same wavefront, same clock', () => {
      render(<PixelLoader label="Churning" variant="Drive" size="sm" />)
      const all = cells()
      expect(all).toHaveLength(9)
      expect(all.every(c => c.dataset.animated === 'true')).toBe(true)

      act(() => {
        vi.advanceTimersByTime(1_800)
      })
      expect(screen.getByTestId('pixel-loader-elapsed')).toHaveTextContent('1.8s')
    })
  })

  // A host that is already a live region has to be able to switch this one
  // off. Nesting two makes a screen reader read the same sentence twice.
  describe('embedding in a host that already announces', () => {
    it('owns a live region by default, because standalone nothing else will', () => {
      render(<PixelLoader label="Churning" />)
      const root = screen.getByTestId('pixel-loader')
      expect(root).toHaveAttribute('role', 'status')
      expect(root).toHaveAttribute('aria-live', 'polite')
    })

    it('drops both role and aria-live when announce is false', () => {
      const { container } = render(<PixelLoader label="Churning" announce={false} />)
      const root = screen.getByTestId('pixel-loader')
      expect(root).not.toHaveAttribute('role')
      expect(root).not.toHaveAttribute('aria-live')
      expect(container.querySelectorAll('[aria-live]')).toHaveLength(0)
      expect(screen.queryByRole('status')).not.toBeInTheDocument()
    })

    it('keeps the grid and the figure hidden either way', () => {
      render(<PixelLoader label="Churning" announce={false} />)
      expect(screen.getByTestId('pixel-loader-grid')).toHaveAttribute('aria-hidden', 'true')
      expect(screen.getByTestId('pixel-loader-elapsed')).toHaveAttribute('aria-hidden', 'true')
    })

    it('still shows the label when silent — the host announces it, the eye reads it', () => {
      render(<PixelLoader label="Loading agents…" announce={false} />)
      expect(screen.getByTestId('pixel-loader-label')).toHaveTextContent('Loading agents…')
    })

    it('lets the host keep its own testid for the label', () => {
      render(<PixelLoader label="Loading agents…" labelTestId="loading-state-message" />)
      expect(screen.getByTestId('loading-state-message')).toHaveTextContent('Loading agents…')
      expect(screen.queryByTestId('pixel-loader-label')).not.toBeInTheDocument()
    })

    it('is phrasing content, so it is legal inside a host <span>', () => {
      // LoadingState's inline variant is a <span>. A <div> in a <span> is
      // invalid nesting that browsers paper over inconsistently.
      render(<PixelLoader label="Churning" />)
      expect(screen.getByTestId('pixel-loader').tagName).toBe('SPAN')
    })
  })

  it('states on the grid whether it is moving', () => {
    render(<PixelLoader label="Churning" />)
    expect(screen.getByTestId('pixel-loader-grid')).toHaveAttribute('data-motion', 'animated')
  })

  it('defines the keyframes it references', () => {
    // The snippet referenced `pixel-on` and `shimmer-text` and defined
    // neither, so nothing moved. The keyframes ship inside the component.
    const { container } = render(<PixelLoader label="Churning" variant="Drive" />)
    const css = container.querySelector('style')?.textContent ?? ''
    expect(css).toContain('@keyframes sl-pixel-on')
    expect(css).toContain('@keyframes sl-shimmer-text')
    const animated = cells()[0].getAttribute('style') ?? ''
    expect(animated).toContain('sl-pixel-on')
  })
})
