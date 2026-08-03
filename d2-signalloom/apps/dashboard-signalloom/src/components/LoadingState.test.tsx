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
    expect(screen.getByTestId('loading-indicator')).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByTestId('loading-state')).toHaveTextContent('Loading agents…')
  })
})

describe('prefers-reduced-motion', () => {
  it('spins when motion is allowed', () => {
    const restore = withReducedMotion(false)
    try {
      render(<LoadingState status="loading" />)
      const dot = screen.getByTestId('loading-indicator')
      expect(dot).toHaveAttribute('data-motion', 'spin')
      expect(dot).toHaveClass('loading-spinner')
    } finally {
      restore()
    }
  })

  it('falls back to a static indicator when the user asked for reduced motion', () => {
    const restore = withReducedMotion(true)
    try {
      render(<LoadingState status="loading" label="agents" />)
      const dot = screen.getByTestId('loading-indicator')
      expect(dot).toHaveAttribute('data-motion', 'static')
      expect(dot).not.toHaveClass('loading-spinner')
      // The meaning survives the missing animation.
      expect(screen.getByTestId('loading-state-message')).toHaveTextContent('Loading agents…')
    } finally {
      restore()
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
