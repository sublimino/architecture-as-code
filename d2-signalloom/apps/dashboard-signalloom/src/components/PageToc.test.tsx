import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import PageTocLayout, { TOC_SCAN_LINE, type TocEntry } from './PageToc'
import {
  installMockIntersectionObserver,
  type MockIntersectionObserver,
  type MockObserverHandle,
  type ObserverRecord,
} from '../test-utils/mockIntersectionObserver'

// Scrollspy under jsdom, which has neither a viewport nor an
// IntersectionObserver. Everything geometric is therefore arranged rather than
// simulated: `observer.fire()` states which sections are intersecting and the
// assertions are about what the component concludes from that, which is the
// only part of a scrollspy that is actually logic.
//
// The one thing these tests will not do is pass while the observer is dead.
// `handle.latest()` throws when the component constructed no observer, so the
// failure mode where a jsdom stub is missing and every assertion quietly
// measures the initial render is a loud red, not a green.

const ENTRIES: readonly TocEntry[] = [
  { id: 'alpha', title: 'Alpha' },
  { id: 'bravo', title: 'Bravo' },
  { id: 'charlie', title: 'Charlie' },
]

function Harness({ entries = ENTRIES }: { entries?: readonly TocEntry[] }) {
  return (
    <PageTocLayout entries={entries}>
      <h1>Reference page</h1>
      {entries.map((entry) => (
        <section key={entry.id} id={entry.id} data-testid={`section-${entry.id}`}>
          <h2>{entry.title}</h2>
        </section>
      ))}
    </PageTocLayout>
  )
}

function nav() {
  return screen.getByRole('navigation', { name: /on this page/i })
}

function linkFor(id: string) {
  return screen.getByTestId(`page-toc-link-${id}`)
}

function sectionFor(id: string) {
  return screen.getByTestId(`section-${id}`)
}

/**
 * Deliver intersection changes and let React settle before asserting.
 *
 * The act() wrapper is not decoration. A real observer callback lands inside
 * React's own event plumbing and is flushed for you; the mock's does not, so
 * without this the state update is queued, the DOM still shows the previous
 * active entry, and four tests fail against a component that is correct. The
 * only visible symptom is an "update was not wrapped in act(...)" warning in
 * the noise above the failures.
 */
function fire(observer: MockIntersectionObserver, records: ObserverRecord[]) {
  act(() => observer.fire(records))
}

/** The id currently carrying aria-current, or null. Exactly one, or it fails. */
function currentId(): string | null {
  const marked = within(nav())
    .getAllByRole('link')
    .filter((link) => link.getAttribute('aria-current') !== null)
  expect(marked.length).toBeLessThanOrEqual(1)
  return marked[0]?.getAttribute('href')?.replace('#', '') ?? null
}

let handle: MockObserverHandle
let scrollIntoView: ReturnType<typeof vi.fn>
let originalScrollIntoView: unknown

beforeEach(() => {
  handle = installMockIntersectionObserver()
  scrollIntoView = vi.fn()
  originalScrollIntoView = Reflect.get(Element.prototype, 'scrollIntoView')
  Reflect.set(Element.prototype, 'scrollIntoView', scrollIntoView)
  window.history.replaceState(window.history.state, '', window.location.pathname)
})

afterEach(() => {
  handle.restore()
  if (originalScrollIntoView === undefined) Reflect.deleteProperty(Element.prototype, 'scrollIntoView')
  else Reflect.set(Element.prototype, 'scrollIntoView', originalScrollIntoView)
  vi.restoreAllMocks()
})

describe('PageTocLayout', () => {
  // ── Structure and naming ──────────────────────────────────────────────────

  it('names the nav with the text it renders, not with a separate aria-label', () => {
    render(<Harness />)
    const region = nav()
    // WCAG 2.5.3 Label in Name, the invariant sidebarLabelInName.test.tsx
    // guards for the rail: the name a speech-input user says must be the name
    // on the screen. Satisfied here by construction — aria-labelledby points
    // at the visible title, so the two cannot drift apart.
    expect(region).toHaveAccessibleName('On this page')
    expect(within(region).getByText('On this page')).toBeInTheDocument()
    expect(region).not.toHaveAttribute('aria-label')
  })

  it('renders one real link per entry, in document order, pointing at real anchors', () => {
    render(<Harness />)
    const links = within(nav()).getAllByRole('link')
    expect(links.map((l) => l.textContent)).toEqual(['Alpha', 'Bravo', 'Charlie'])
    expect(links.map((l) => l.getAttribute('href'))).toEqual(['#alpha', '#bravo', '#charlie'])
    // An href is worth nothing without a target carrying that id.
    for (const entry of ENTRIES) {
      expect(document.getElementById(entry.id)).toBe(sectionFor(entry.id))
    }
  })

  it('leaves the entries reachable by keyboard in order', async () => {
    const user = userEvent.setup()
    render(<Harness />)
    // Anchors with href are natively focusable; this asserts nothing has been
    // done to them (tabindex=-1, a div-with-onclick) that would take that away.
    await user.tab()
    expect(document.activeElement).toBe(linkFor('alpha'))
    await user.tab()
    expect(document.activeElement).toBe(linkFor('bravo'))
  })

  // ── The observer is real ──────────────────────────────────────────────────

  it('observes every section, through a scan line rather than the whole viewport', () => {
    render(<Harness />)
    const observer = handle.only()
    expect(observer.targets).toEqual([sectionFor('alpha'), sectionFor('bravo'), sectionFor('charlie')])
    expect(observer.rootMargin).toBe(TOC_SCAN_LINE)
    // Both insets negative is what makes it a band near the top rather than
    // the full viewport. With the full viewport, "topmost intersecting" holds
    // a section active until it has left the screen entirely — the lag this
    // margin exists to remove. See PageToc.tsx for the full argument.
    const insets = TOC_SCAN_LINE.split(/\s+/)
    expect(insets[0].startsWith('-')).toBe(true)
    expect(insets[2].startsWith('-')).toBe(true)
  })

  it('disconnects the observer when it unmounts', () => {
    const { unmount } = render(<Harness />)
    const observer = handle.only()
    expect(observer.disconnectCount).toBe(0)
    unmount()
    expect(observer.disconnectCount).toBe(1)
  })

  // ── The active-section rule ───────────────────────────────────────────────

  it('marks the first entry before anything has intersected', () => {
    render(<Harness />)
    expect(currentId()).toBe('alpha')
    expect(linkFor('alpha')).toHaveAttribute('aria-current', 'location')
  })

  it('moves aria-current when a different section crosses the scan line', () => {
    render(<Harness />)
    const observer = handle.latest()

    fire(observer, [
      { target: sectionFor('alpha'), isIntersecting: false },
      { target: sectionFor('charlie'), isIntersecting: true },
    ])

    expect(currentId()).toBe('charlie')
    expect(linkFor('charlie')).toHaveAttribute('aria-current', 'location')
    expect(linkFor('alpha')).not.toHaveAttribute('aria-current')
  })

  it('gives the section nearest the top of the page the win when two intersect', () => {
    render(<Harness />)
    const observer = handle.latest()

    // A section boundary landing inside the scan line: the outgoing section's
    // tail and the incoming one's head both cross it. Document order decides,
    // and document order IS top-to-bottom for non-overlapping siblings.
    fire(observer, [
      { target: sectionFor('alpha'), isIntersecting: false },
      { target: sectionFor('bravo'), isIntersecting: true },
      { target: sectionFor('charlie'), isIntersecting: true },
    ])

    expect(currentId()).toBe('bravo')
  })

  it('accumulates state across callbacks rather than reading only the latest batch', () => {
    render(<Harness />)
    const observer = handle.latest()

    // The browser reports CHANGES, not the whole picture. A component that
    // treats each batch as the complete set of intersecting sections gets the
    // right answer for a single-section scroll and the wrong one here: bravo
    // is still intersecting, it just did not change in the second batch.
    fire(observer, [
      { target: sectionFor('bravo'), isIntersecting: true },
      { target: sectionFor('charlie'), isIntersecting: true },
    ])
    expect(currentId()).toBe('bravo')

    fire(observer, [{ target: sectionFor('bravo'), isIntersecting: false }])
    expect(currentId()).toBe('charlie')
  })

  it('holds the last active entry when nothing crosses the line', () => {
    render(<Harness />)
    const observer = handle.latest()

    fire(observer, [{ target: sectionFor('charlie'), isIntersecting: true }])
    expect(currentId()).toBe('charlie')

    // A section taller than the gap between page top and scan line leaves the
    // band empty for a stretch. Blanking the nav there would flicker; the last
    // thing the reader passed is still the best answer available.
    fire(observer, [{ target: sectionFor('charlie'), isIntersecting: false }])
    expect(currentId()).toBe('charlie')
  })

  // ── Anchors ───────────────────────────────────────────────────────────────

  it('scrolls to the clicked section and puts it in the address bar', async () => {
    const user = userEvent.setup()
    render(<Harness />)

    await user.click(linkFor('charlie'))

    expect(scrollIntoView).toHaveBeenCalledTimes(1)
    expect(scrollIntoView.mock.instances[0]).toBe(sectionFor('charlie'))
    expect(scrollIntoView).toHaveBeenCalledWith({ behavior: 'smooth', block: 'start' })
    expect(window.location.hash).toBe('#charlie')
    // Immediate, not waiting for the observer to catch up mid-animation.
    expect(currentId()).toBe('charlie')
  })

  it('jumps without animation when the reader asked for reduced motion', async () => {
    const user = userEvent.setup()
    const original = globalThis.matchMedia
    globalThis.matchMedia = ((query: string) => ({
      matches: query.includes('prefers-reduced-motion'),
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(),
    })) as unknown as typeof globalThis.matchMedia

    try {
      render(<Harness />)
      await user.click(linkFor('bravo'))
      expect(scrollIntoView).toHaveBeenCalledWith({ behavior: 'auto', block: 'start' })
    } finally {
      globalThis.matchMedia = original
    }
  })

  it('leaves modified clicks to the browser', async () => {
    const user = userEvent.setup()
    render(<Harness />)

    await user.keyboard('{Meta>}')
    await user.click(linkFor('bravo'))
    await user.keyboard('{/Meta}')

    // Open-in-new-tab must stay open-in-new-tab. Hijacking it would also have
    // scrolled the page the reader was trying to leave behind.
    expect(scrollIntoView).not.toHaveBeenCalled()
  })

  it('scrolls to the section named in the URL when the page is loaded at that anchor', async () => {
    window.history.replaceState(window.history.state, '', '#charlie')
    render(<Harness />)

    // Marked from the very first render — no flash of "Alpha is current"
    // before an effect corrects it.
    expect(currentId()).toBe('charlie')

    // And scrolled once layout exists, which is a frame later than mount:
    // the sections do not have positions at the moment the effect runs.
    await waitFor(() => expect(scrollIntoView).toHaveBeenCalledTimes(1))
    expect(scrollIntoView.mock.instances[0]).toBe(sectionFor('charlie'))
    // A landing scroll is a jump even without reduced motion — animating from
    // the top of a page the reader never saw is motion for its own sake.
    expect(scrollIntoView).toHaveBeenCalledWith({ behavior: 'auto', block: 'start' })
  })

  it('ignores a URL fragment that names no section on this page', async () => {
    window.history.replaceState(window.history.state, '', '#not-a-section')
    render(<Harness />)

    expect(currentId()).toBe('alpha')
    await new Promise((resolve) => requestAnimationFrame(resolve))
    expect(scrollIntoView).not.toHaveBeenCalled()
  })

  // ── Degradation ───────────────────────────────────────────────────────────

  it('still renders a usable index where IntersectionObserver does not exist', () => {
    handle.restore()
    const key = 'IntersectionObserver'
    const original = Reflect.get(globalThis, key)
    Reflect.deleteProperty(globalThis, key)
    try {
      // Links and anchors are the part that must survive; only the highlight
      // is the observer's job. Throwing here would take the whole page down.
      expect(() => render(<Harness />)).not.toThrow()
      expect(within(nav()).getAllByRole('link')).toHaveLength(3)
    } finally {
      Reflect.set(globalThis, key, original)
    }
  })

  it('renders no rail at all when it is given no entries', () => {
    render(<Harness entries={[]} />)
    expect(screen.queryByRole('navigation', { name: /on this page/i })).not.toBeInTheDocument()
  })
})
