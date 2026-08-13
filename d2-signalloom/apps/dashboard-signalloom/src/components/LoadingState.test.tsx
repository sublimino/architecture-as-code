import { describe, it, expect, vi, afterEach } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import LoadingState, { formatAgo, loadPhase } from './LoadingState'

// Swaps the global matchMedia stub (test-setup.ts pins matches:false) for one
// that answers true to the reduced-motion query only.
function withReducedMotion(reduced: boolean) {
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

/**
 * The moving parts of the embedded PixelLoader, whichever variant it draws.
 *
 * This used to read the grid's nine children directly. PixelLoader's default
 * is now `Loom`, the brand mark, which draws eight woven bars instead of a 3x3
 * grid — so a helper that counts cells was really asserting "the default is
 * Drive", which is PixelLoader's business and not LoadingState's. Every
 * element that takes part in the animation carries `data-animated` in either
 * shape, so querying that keeps these tests about what they were always about:
 * that the waiting pattern is drawn, that it moves, and that it stops moving
 * when the user asks it to. Which variant is the default is pinned in
 * PixelLoader.test.tsx, in one place.
 */
function loaderMarks(testId = 'loading-state'): (HTMLElement | SVGElement)[] {
  return Array.from(
    screen.getByTestId(`${testId}-loader-grid`).querySelectorAll('[data-animated]'),
  ) as (HTMLElement | SVGElement)[]
}

afterEach(() => {
  vi.useRealTimers()
})

describe('loadPhase — never-loaded is not the same as loaded-and-empty', () => {
  it('reports idle when nothing has been fetched yet', () => {
    expect(loadPhase({ loading: false, error: null, loaded: false })).toBe('idle')
  })

  it('reports success once a fetch has completed, even with no rows', () => {
    expect(loadPhase({ loading: false, error: null, loaded: true })).toBe('success')
  })

  it('reports loading while a fetch is in flight, error state notwithstanding', () => {
    expect(loadPhase({ loading: true, error: 'stale failure', loaded: true })).toBe('loading')
  })

  it('reports error when the last settled fetch failed', () => {
    expect(loadPhase({ loading: false, error: 'boom', loaded: true })).toBe('error')
  })
})

describe('formatAgo', () => {
  const now = 1_000_000_000_000

  it.each([
    [0, 'just now'],
    [4_000, 'just now'],
    [12_000, '12s ago'],
    [59_000, '59s ago'],
    [60_000, '1m ago'],
    [2 * 60_000, '2m ago'],
    [60 * 60_000, '1h ago'],
    [25 * 60 * 60_000, '1d ago'],
  ])('renders %ims of elapsed time as "%s"', (elapsed, expected) => {
    expect(formatAgo(now - elapsed, now)).toBe(expected)
  })

  it('never renders a negative age from a clock that skewed forward', () => {
    expect(formatAgo(now + 5_000, now)).toBe('just now')
  })
})

describe('the four states each say something distinct', () => {
  it('idle says nothing has loaded yet, and names the subject', () => {
    render(<LoadingState status="idle" label="agents" />)
    expect(screen.getByTestId('loading-state')).toHaveAttribute('data-status', 'idle')
    expect(screen.getByTestId('loading-state-message')).toHaveTextContent('No agents loaded yet')
  })

  it('loading says it is loading', () => {
    render(<LoadingState status="loading" label="agents" />)
    expect(screen.getByTestId('loading-state-message')).toHaveTextContent('Loading agents…')
  })

  it('success says when it last refreshed', () => {
    render(<LoadingState status="success" label="agents" />)
    expect(screen.getByTestId('loading-state-message')).toHaveTextContent('Refreshed just now')
  })

  it('error says when it failed', () => {
    render(<LoadingState status="error" label="agents" error="HTTP 503" />)
    expect(screen.getByTestId('loading-state-message')).toHaveTextContent('Failed just now')
  })

  it('a refresh over existing data keeps the previous success time visible', () => {
    const twoMinutesAgo = Date.now() - 120_000
    render(<LoadingState status="loading" label="agents" timestamp={twoMinutesAgo} />)
    // No prior success recorded in this mount, so it is a first load.
    expect(screen.getByTestId('loading-state-message')).toHaveTextContent('Loading agents…')

    const { rerender } = render(<LoadingState status="success" label="agents" testId="second" />)
    rerender(<LoadingState status="loading" label="agents" testId="second" />)
    expect(screen.getByTestId('second-message')).toHaveTextContent(/Refreshing… · last refreshed/)
  })
})

describe('the failure reason is surfaced, never a generic string', () => {
  it('shows the real reason inline', () => {
    render(<LoadingState status="error" label="agents" error="connect ECONNREFUSED 10.0.0.4:8200" />)
    expect(screen.getByTestId('loading-state-reason')).toHaveTextContent(
      'connect ECONNREFUSED 10.0.0.4:8200',
    )
  })

  it('shows the real reason in block variant', () => {
    render(
      <LoadingState variant="block" status="error" label="agents" error="policy engine unreachable" />,
    )
    expect(screen.getByText('policy engine unreachable')).toBeInTheDocument()
  })

  it('falls back to a subject-specific line only when there is genuinely no reason', () => {
    render(<LoadingState variant="block" status="error" label="agents" />)
    expect(screen.getByText('Failed to load agents.')).toBeInTheDocument()
  })

  it('offers retry and calls back', async () => {
    const onRetry = vi.fn()
    render(<LoadingState status="error" error="boom" onRetry={onRetry} />)
    await userEvent.click(screen.getByRole('button', { name: 'Retry' }))
    expect(onRetry).toHaveBeenCalledTimes(1)
  })
})

describe('the relative-time line moves without a re-fetch', () => {
  it('counts up while the component just sits there', () => {
    vi.useFakeTimers()
    try {
      render(<LoadingState status="success" label="agents" />)
      expect(screen.getByTestId('loading-state-message')).toHaveTextContent('Refreshed just now')

      act(() => {
        vi.advanceTimersByTime(12_000)
      })
      expect(screen.getByTestId('loading-state-message')).toHaveTextContent('Refreshed 12s ago')

      act(() => {
        vi.advanceTimersByTime(108_000)
      })
      expect(screen.getByTestId('loading-state-message')).toHaveTextContent('Refreshed 2m ago')
    } finally {
      vi.useRealTimers()
    }
  })

  it('clears its interval on unmount', () => {
    vi.useFakeTimers()
    try {
      const clear = vi.spyOn(globalThis, 'clearInterval')
      const { unmount } = render(<LoadingState status="success" />)
      unmount()
      expect(clear).toHaveBeenCalled()
      clear.mockRestore()
    } finally {
      vi.useRealTimers()
    }
  })

  it('registers no ticker at all while idle — nothing to count from', () => {
    vi.useFakeTimers()
    try {
      const set = vi.spyOn(globalThis, 'setInterval')
      render(<LoadingState status="idle" />)
      expect(set).not.toHaveBeenCalled()
      set.mockRestore()
    } finally {
      vi.useRealTimers()
    }
  })
})

describe('accessibility — this is demoed to regulated-industry customers', () => {
  it('announces loading politely via role=status', () => {
    render(<LoadingState status="loading" label="agents" />)
    const el = screen.getByTestId('loading-state')
    expect(el).toHaveAttribute('role', 'status')
    expect(el).toHaveAttribute('aria-live', 'polite')
  })

  it('announces success politely via role=status', () => {
    render(<LoadingState status="success" label="agents" />)
    const el = screen.getByTestId('loading-state')
    expect(el).toHaveAttribute('role', 'status')
    expect(el).toHaveAttribute('aria-live', 'polite')
  })

  it('announces failure assertively via role=alert, and does not double up with aria-live', () => {
    render(<LoadingState status="error" error="boom" />)
    const el = screen.getByTestId('loading-state')
    expect(el).toHaveAttribute('role', 'alert')
    expect(el).not.toHaveAttribute('aria-live')
  })

  it('keeps role=alert in the block variant too', () => {
    render(<LoadingState variant="block" status="error" error="boom" />)
    expect(screen.getByTestId('loading-state')).toHaveAttribute('role', 'alert')
  })

  it('hides the indicator from assistive tech — the text carries the meaning', () => {
    render(<LoadingState status="loading" label="agents" />)
    // The loading visual is now PixelLoader's grid rather than a bare dot.
    // Same contract: decorative, hidden, and the sentence still stands alone.
    expect(screen.getByTestId('loading-state-loader-grid')).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByTestId('loading-state')).toHaveTextContent('Loading agents…')
  })

  it('hides the settled-phase dot from assistive tech too', () => {
    render(<LoadingState status="success" label="agents" />)
    expect(screen.getByTestId('loading-indicator')).toHaveAttribute('aria-hidden', 'true')
  })
})

describe('prefers-reduced-motion', () => {
  // The assertions moved from the spinning dot to the pixel grid because the
  // dot is gone, not because the rule relaxed. The rule is the same one:
  // motion when it is welcome, none when it is not, meaning either way.
  it('animates the grid when motion is allowed', () => {
    const restore = withReducedMotion(false)
    try {
      render(<LoadingState status="loading" />)
      const grid = screen.getByTestId('loading-state-loader-grid')
      expect(grid).toHaveAttribute('data-motion', 'animated')
      expect(loaderMarks().length).toBeGreaterThan(0)
      expect(loaderMarks().every(c => c.dataset.animated === 'true')).toBe(true)
    } finally {
      restore()
    }
  })

  it('freezes the grid when the user asked for reduced motion', () => {
    const restore = withReducedMotion(true)
    try {
      render(<LoadingState status="loading" label="agents" />)
      const grid = screen.getByTestId('loading-state-loader-grid')
      expect(grid).toHaveAttribute('data-motion', 'static')
      expect(loaderMarks().length).toBeGreaterThan(0)
      expect(loaderMarks().every(c => c.dataset.animated === 'false')).toBe(true)
      expect(
        loaderMarks().every(c => (c.getAttribute('style') ?? '').includes('animation')),
      ).toBe(false)
      // The meaning survives the missing animation.
      expect(screen.getByTestId('loading-state-message')).toHaveTextContent('Loading agents…')
    } finally {
      restore()
    }
  })

  it('keeps the elapsed figure ticking even with motion switched off', () => {
    // Reduced motion is a request to stop things moving, not a request to be
    // told less. A frozen grid with a dead timer is a hung page.
    vi.useFakeTimers()
    const restore = withReducedMotion(true)
    try {
      render(<LoadingState status="loading" label="agents" />)
      const elapsed = screen.getByTestId('loading-state-loader-elapsed')
      expect(elapsed).toHaveTextContent('0.0s')
      act(() => {
        vi.advanceTimersByTime(3_100)
      })
      expect(elapsed).toHaveTextContent('3.1s')
    } finally {
      restore()
      vi.useRealTimers()
    }
  })

  it('the non-loading states are static regardless', () => {
    const restore = withReducedMotion(false)
    try {
      render(<LoadingState status="success" />)
      expect(screen.getByTestId('loading-indicator')).toHaveAttribute('data-motion', 'static')
    } finally {
      restore()
    }
  })
})

describe('theming — no dead tokens, no bare hex', () => {
  // styles/cssVarUsage.test.ts enforces this across all of src; asserting it
  // here as well keeps the intent local to the component that got it wrong
  // last time (DemoToggle's `var(--card, #1a1a1a)`).
  it('references no undeclared custom property and no literal hex', async () => {
    const { readFileSync } = await import('node:fs')
    const { join } = await import('node:path')
    const source = readFileSync(join(__dirname, 'LoadingState.tsx'), 'utf8')
    const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '')
    expect(code).not.toMatch(/var\(\s*--card\b/)
    expect(code).not.toMatch(/(?:color|background|border(?:Color|Left)?)\s*:\s*['"]#[0-9a-fA-F]{3,8}/)
  })
})

// The inline variant renders its own Retry rather than going through
// ErrorState, so the 401 rule has to be applied in both places or the fix
// covers only half the app. /network-tests was still offering Retry on a 401
// after ErrorState alone was fixed.
describe('an expired session in the inline variant', () => {
  it('offers Log in instead of Retry on a 401', () => {
    const onRetry = vi.fn()
    render(
      <LoadingState
        status="error"
        error="Request failed with status code 401"
        onRetry={onRetry}
        testId="inline"
      />,
    )
    expect(screen.getByTestId('inline-login')).toHaveTextContent('Log in')
    expect(screen.queryByRole('button', { name: /^retry$/i })).not.toBeInTheDocument()
  })

  it('replaces the axios text but keeps it reachable', () => {
    render(<LoadingState status="error" error="Request failed with status code 401" testId="inline" />)
    expect(screen.getByTestId('inline-reason')).toHaveTextContent('your session has expired')
    expect(screen.getByTitle('Request failed with status code 401')).toBeInTheDocument()
  })

  it('still offers Retry for a failure retrying could fix', () => {
    const onRetry = vi.fn()
    render(<LoadingState status="error" error="Request failed with status code 503" onRetry={onRetry} testId="inline" />)
    expect(screen.getByRole('button', { name: /^retry$/i })).toBeInTheDocument()
    expect(screen.queryByTestId('inline-login')).not.toBeInTheDocument()
  })
})

// A spinner is a promise that something is happening. It is not evidence.
// Forty seconds into a slow query the operator's question is not "is it
// alive" but "how long has this been going, and is that normal" — and the
// spinner answers neither. The instructor panel already solved this with a
// pixel grid and a running clock; this is that pattern reaching the twenty-odd
// pages that render LoadingState.
describe('the waiting pattern is the loading state', () => {
  it('draws the waiting pattern, not a dot, while loading inline', () => {
    render(<LoadingState status="loading" label="agents" />)
    expect(screen.getByTestId('loading-state-loader')).toBeInTheDocument()
    expect(loaderMarks().length).toBeGreaterThan(0)
    expect(screen.queryByTestId('loading-indicator')).not.toBeInTheDocument()
  })

  it('draws it in the block variant too', () => {
    render(<LoadingState variant="block" status="loading" label="agents" />)
    expect(screen.getByTestId('loading-state-loader')).toBeInTheDocument()
    expect(loaderMarks().length).toBeGreaterThan(0)
    expect(screen.getByTestId('loading-state-message')).toHaveTextContent('Loading agents…')
  })

  it('shows how long the wait has been going, in tenths', () => {
    vi.useFakeTimers()
    try {
      render(<LoadingState status="loading" label="agents" />)
      const elapsed = screen.getByTestId('loading-state-loader-elapsed')
      expect(elapsed).toHaveTextContent('0.0s')

      act(() => {
        vi.advanceTimersByTime(2_400)
      })
      expect(elapsed).toHaveTextContent('2.4s')

      // Past a minute the figure has to stay readable, not become "84.0s".
      act(() => {
        vi.advanceTimersByTime(62_600)
      })
      expect(elapsed).toHaveTextContent('1m 5.0s')
    } finally {
      vi.useRealTimers()
    }
  })

  it('reads the wall clock, so a starved event loop does not lose seconds', () => {
    vi.useFakeTimers()
    try {
      render(<LoadingState status="loading" label="agents" />)
      act(() => {
        vi.advanceTimersByTime(100)
        vi.setSystemTime(Date.now() + 7_900) // the tab was backgrounded
        vi.advanceTimersByTime(100)
      })
      expect(screen.getByTestId('loading-state-loader-elapsed')).toHaveTextContent('8.1s')
    } finally {
      vi.useRealTimers()
    }
  })

  it('starts a fresh figure for a second load rather than resuming the first', () => {
    vi.useFakeTimers()
    try {
      const { rerender } = render(<LoadingState status="loading" label="agents" />)
      act(() => {
        vi.advanceTimersByTime(5_000)
      })
      expect(screen.getByTestId('loading-state-loader-elapsed')).toHaveTextContent('5.0s')

      rerender(<LoadingState status="success" label="agents" />)
      act(() => {
        vi.advanceTimersByTime(30_000)
      })
      rerender(<LoadingState status="loading" label="agents" />)
      expect(screen.getByTestId('loading-state-loader-elapsed')).toHaveTextContent('0.0s')
    } finally {
      vi.useRealTimers()
    }
  })

  it('uses the compact size inline and the full size in a block panel', () => {
    // A 4px grid on a 13px label is right in a panel and too heavy sitting in
    // a 12px line beside a heading.
    const { unmount } = render(<LoadingState status="loading" label="agents" />)
    expect(screen.getByTestId('loading-state-loader')).toHaveAttribute('data-size', 'sm')
    unmount()

    render(<LoadingState variant="block" status="loading" label="agents" />)
    expect(screen.getByTestId('loading-state-loader')).toHaveAttribute('data-size', 'md')
  })

  it('keeps the message under its documented testid — callers see no change', () => {
    render(<LoadingState status="loading" label="compliance data" testId="compliance" />)
    expect(screen.getByTestId('compliance-message')).toHaveTextContent('Loading compliance data…')
  })

  it('leaves the settled phases showing a plain dot', () => {
    for (const status of ['idle', 'success'] as const) {
      const { unmount } = render(<LoadingState status={status} label="agents" />)
      expect(screen.queryByTestId('loading-state-loader-grid')).not.toBeInTheDocument()
      expect(screen.getByTestId('loading-indicator')).toBeInTheDocument()
      unmount()
    }
  })

  it('leaves the error path alone entirely', () => {
    render(<LoadingState status="error" label="agents" error="HTTP 503" onRetry={vi.fn()} />)
    expect(screen.queryByTestId('loading-state-loader-grid')).not.toBeInTheDocument()
    expect(screen.getByTestId('loading-state-reason')).toHaveTextContent('HTTP 503')
    expect(screen.getByRole('button', { name: /^retry$/i })).toBeInTheDocument()
  })
})

// PixelLoader announces itself when it stands alone, because standalone it is
// the only thing that can. LoadingState has been a live region for twenty-odd
// pages and stays the one that speaks; the loader is told to keep quiet. Two
// nested regions is not more accessible — it is the same sentence read twice.
describe('exactly one live region, never two', () => {
  it('nests no second region inside the inline loading tree', () => {
    const { container } = render(<LoadingState status="loading" label="agents" />)
    expect(container.querySelectorAll('[aria-live]')).toHaveLength(1)
    expect(screen.getAllByRole('status')).toHaveLength(1)
    expect(screen.getByRole('status')).toBe(screen.getByTestId('loading-state'))
  })

  it('nests no second region inside the block loading tree', () => {
    const { container } = render(<LoadingState variant="block" status="loading" label="agents" />)
    expect(container.querySelectorAll('[aria-live]')).toHaveLength(1)
    expect(screen.getAllByRole('status')).toHaveLength(1)
  })

  it('leaves role=alert unaccompanied on the error path', () => {
    const { container } = render(<LoadingState status="error" error="boom" />)
    expect(container.querySelectorAll('[aria-live]')).toHaveLength(0)
    expect(screen.getAllByRole('alert')).toHaveLength(1)
    expect(screen.queryAllByRole('status')).toHaveLength(0)
  })

  it('keeps the ticking figure out of the region that does announce', () => {
    // aria-live + a number changing ten times a second is a screen reader
    // reading digits until the user leaves the page.
    render(<LoadingState status="loading" label="agents" />)
    expect(screen.getByTestId('loading-state-loader-elapsed')).toHaveAttribute(
      'aria-hidden',
      'true',
    )
  })
})
