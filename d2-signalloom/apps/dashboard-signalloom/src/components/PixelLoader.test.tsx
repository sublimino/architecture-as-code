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

  it('renders nine cells', () => {
    render(<PixelLoader label="Churning" />)
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

  describe('prefers-reduced-motion: reduce', () => {
    beforeEach(() => {
      restoreMedia = setReducedMotion(true)
    })

    it('freezes the grid to its dim state', () => {
      render(<PixelLoader label="Churning" />)
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
  })

  it('defines the keyframes it references', () => {
    // The snippet referenced `pixel-on` and `shimmer-text` and defined
    // neither, so nothing moved. The keyframes ship inside the component.
    const { container } = render(<PixelLoader label="Churning" />)
    const css = container.querySelector('style')?.textContent ?? ''
    expect(css).toContain('@keyframes sl-pixel-on')
    expect(css).toContain('@keyframes sl-shimmer-text')
    const animated = cells()[0].getAttribute('style') ?? ''
    expect(animated).toContain('sl-pixel-on')
  })
})
