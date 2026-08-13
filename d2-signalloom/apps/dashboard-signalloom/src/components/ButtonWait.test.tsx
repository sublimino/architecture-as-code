/**
 * The in-button wait.
 *
 * These tests pin the four things that make a loader INSIDE a button different
 * from a loader on its own line, because all four had already been got
 * differently right (and differently wrong) in the two places this pattern was
 * invented before it was named:
 *
 *   1. no visible word — the button's own text already said it;
 *   2. the button does not resize while the figure counts;
 *   3. the control keeps an accessible name once its text is gone;
 *   4. no live region inside an interactive control.
 *
 * (2) is the one jsdom cannot check honestly: there is no layout engine, so
 * `offsetWidth` is 0 before and after and an assertion on it would pass for a
 * component that reserved nothing at all. The mechanism is asserted instead —
 * a fixed pixel width on the loader and tabular figures under it — and the
 * elapsed text is read on both sides of the tick so the test cannot pass by
 * the clock having simply not moved.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, act, within } from '@testing-library/react'
import ButtonWait from './ButtonWait'

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

/** The real shape: a busy button whose text has been replaced by the wait. */
function renderInButton(node: React.ReactNode) {
  return render(
    <button type="button" disabled>
      {node}
    </button>,
  )
}

describe('ButtonWait', () => {
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

  it('renders as phrasing content, so a button may legally contain it', () => {
    renderInButton(<ButtonWait testId="wait" label="Deploying" />)
    // A div here would be invalid inside a <button> and the browser's parser
    // would be entitled to do something surprising with it.
    expect(screen.getByTestId('wait').tagName).toBe('SPAN')
  })

  it('gives the button an accessible name once its text is gone', () => {
    renderInButton(<ButtonWait testId="wait" label="Deploying" />)
    expect(screen.getByRole('button')).toHaveAccessibleName('Deploying')
  })

  it('still names the button when the caller supplies nothing', () => {
    // A generic name is a floor, not a target — call sites should say what is
    // running. But an unnamed button is a WCAG 4.1.2 failure, and this
    // component is the thing that removed the text that used to name it.
    renderInButton(<ButtonWait testId="wait" />)
    expect(screen.getByRole('button')).toHaveAccessibleName(/\S/)
  })

  it('does not defeat an aria-label the call site already sets', () => {
    render(
      <button type="button" aria-label="Stunning agent" disabled>
        <ButtonWait testId="wait" label="Stunning" />
      </button>,
    )
    expect(screen.getByRole('button')).toHaveAccessibleName('Stunning agent')
  })

  it('shows no word — the grid and the figure, nothing else', () => {
    renderInButton(<ButtonWait testId="wait" label="Deploying" />)
    // The loader's own label slot is empty; the name lives in the hidden span.
    expect(screen.getByTestId('wait-label')).toBeEmptyDOMElement()
    const hidden = screen.getByText('Deploying')
    expect(hidden.style.width).toBe('1px')
    expect(hidden.style.overflow).toBe('hidden')
  })

  it('creates no live region inside the control', () => {
    // PixelLoader is role=status by default. A live region nested inside an
    // interactive control is wrong twice over: the reader announces on focus
    // AND on mutation, and the figure mutates ten times a second.
    renderInButton(<ButtonWait testId="wait" label="Deploying" />)
    const button = screen.getByRole('button')
    expect(screen.queryByRole('status')).toBeNull()
    expect(button.querySelector('[role="status"]')).toBeNull()
    expect(button.querySelector('[aria-live]')).toBeNull()
  })

  it('hides the moving parts from assistive technology', () => {
    renderInButton(<ButtonWait testId="wait" label="Deploying" />)
    expect(screen.getByTestId('wait').closest('[aria-hidden="true"]')).not.toBeNull()
  })

  it('reserves its width, so the button cannot move while the figure counts', () => {
    renderInButton(<ButtonWait testId="wait" label="Deploying" />)
    const loader = screen.getByTestId('wait')
    const elapsed = within(loader).getByTestId('wait-elapsed')

    const widthAtFirstFrame = loader.style.width
    const textAtFirstFrame = elapsed.textContent
    expect(widthAtFirstFrame).toMatch(/^\d+px$/)

    // Past 10.0s and past 1m 0.0s: the two points where the figure gains a
    // character. A shrink-to-fit button jumps at both.
    act(() => { vi.advanceTimersByTime(65_000) })

    expect(elapsed.textContent).not.toBe(textAtFirstFrame)
    expect(elapsed).toHaveTextContent('1m 5.0s')
    expect(loader.style.width).toBe(widthAtFirstFrame)
  })

  it('draws the figure in tabular figures, so digits do not jitter either', () => {
    renderInButton(<ButtonWait testId="wait" label="Deploying" />)
    const elapsed = screen.getByTestId('wait-elapsed')
    expect(elapsed.style.fontVariantNumeric).toBe('tabular-nums')
  })

  it('counts the wait up from mount', () => {
    renderInButton(<ButtonWait testId="wait" label="Deploying" />)
    expect(screen.getByTestId('wait-elapsed')).toHaveTextContent('0.0s')
    act(() => { vi.advanceTimersByTime(3_400) })
    expect(screen.getByTestId('wait-elapsed')).toHaveTextContent('3.4s')
  })

  describe('prefers-reduced-motion: reduce', () => {
    beforeEach(() => {
      restoreMedia = setReducedMotion(true)
    })

    it('freezes the grid and keeps the clock running', () => {
      renderInButton(<ButtonWait testId="wait" label="Deploying" />)
      const grid = screen.getByTestId('wait-grid')
      expect(grid).toHaveAttribute('data-motion', 'static')
      expect(
        Array.from(grid.querySelectorAll('[data-animated]')).every(
          n => n.getAttribute('data-animated') === 'false',
        ),
      ).toBe(true)

      act(() => { vi.advanceTimersByTime(2_000) })
      expect(screen.getByTestId('wait-elapsed')).toHaveTextContent('2.0s')
    })

    it('still reserves the same width', () => {
      renderInButton(<ButtonWait testId="wait" label="Deploying" />)
      expect(screen.getByTestId('wait').style.width).toMatch(/^\d+px$/)
    })
  })
})
