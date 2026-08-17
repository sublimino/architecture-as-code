import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { act, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import DesignSystemPage, { DESIGN_SYSTEM_SECTIONS } from './DesignSystemPage'
import DesignSystemHeadersPage, { DESIGN_SYSTEM_HEADER_SECTIONS } from './DesignSystemHeadersPage'
import type { TocEntry } from '../components/PageToc'
import { installMockIntersectionObserver, type MockObserverHandle } from '../test-utils/mockIntersectionObserver'

// The on-this-page index, asserted against the two pages that carry it.
//
// PageToc.test.tsx covers the scrollspy's logic against a three-section
// harness. This file covers the thing that harness cannot: that the index each
// real page declares still describes the page. The index is a hand-maintained
// array — chosen over deriving it from the DOM so the rail is correct on the
// first paint with no measuring pass — and the whole cost of that choice is
// the risk that someone adds a Group and not an entry. These tests are what
// makes that cost bounded: divergence in either direction is a red build.
//
// Both pages are asserted by the same parameterised block, deliberately. They
// are the two long reference pages in this app and they already share a Group
// implementation by copy; letting their indexes diverge in behaviour would be
// a bug in its own right, so there is one set of rules and both pages meet it.

const PAGES = [
  {
    name: 'DesignSystemPage',
    entries: DESIGN_SYSTEM_SECTIONS,
    render: () => render(<DesignSystemPage />),
  },
  {
    name: 'DesignSystemHeadersPage',
    entries: DESIGN_SYSTEM_HEADER_SECTIONS,
    render: () => render(<DesignSystemHeadersPage />),
  },
] as const

/** Collapses the whitespace a JSX heading spreads across source lines. */
function flat(text: string | null | undefined): string {
  return (text ?? '').replace(/\s+/g, ' ').trim()
}

function renderedSectionIds(container: HTMLElement): string[] {
  return Array.from(container.querySelectorAll<HTMLElement>('[data-testid^="ds-section-"]')).map((section) =>
    section.getAttribute('data-testid')!.replace('ds-section-', ''),
  )
}

function toc() {
  return screen.getByRole('navigation', { name: /on this page/i })
}

let handle: MockObserverHandle
let originalScrollIntoView: unknown

beforeEach(() => {
  handle = installMockIntersectionObserver()
  originalScrollIntoView = Reflect.get(Element.prototype, 'scrollIntoView')
  Reflect.set(Element.prototype, 'scrollIntoView', vi.fn())
  window.history.replaceState(window.history.state, '', window.location.pathname)
})

afterEach(() => {
  handle.restore()
  if (originalScrollIntoView === undefined) Reflect.deleteProperty(Element.prototype, 'scrollIntoView')
  else Reflect.set(Element.prototype, 'scrollIntoView', originalScrollIntoView)
  vi.restoreAllMocks()
})

describe.each(PAGES)('$name — on-this-page index', ({ entries, render: renderPage }) => {
  it('indexes exactly the sections the page renders, in the order it renders them', () => {
    const { container } = renderPage()
    // Both directions in one assertion: a Group with no entry and an entry
    // with no Group both fail here, and so does reordering one without the
    // other, which would leave a scrollspy that jumps backwards as you scroll.
    expect(entries.map((entry: TocEntry) => entry.id)).toEqual(renderedSectionIds(container))
  })

  it('gives every section a real id attribute, not only a testid', () => {
    renderPage()
    for (const entry of entries) {
      const section = screen.getByTestId(`ds-section-${entry.id}`)
      // The testid is what the suites query; the id is what a published URL
      // and the observer need. Before this feature the sections had only the
      // former, so there was nothing for /design-system#data-table to find.
      expect(section.getAttribute('id')).toBe(entry.id)
      expect(document.getElementById(entry.id)).toBe(section)
    }
  })

  it('never labels an entry with something its heading does not say', () => {
    renderPage()
    for (const entry of entries) {
      const heading = screen.getByTestId(`ds-heading-${entry.id}`)
      // Shorter than the heading is allowed — DesignSystemHeadersPage's
      // headings are sentences and a rail full of sentences is not an index.
      // Different from the heading is not: an entry that says one thing and
      // lands on another is worse than no entry, because it is trusted.
      expect(flat(heading.textContent).toLowerCase()).toContain(flat(entry.title).toLowerCase())
    }
  })

  it('points every link at an anchor that exists on this page', () => {
    const { container } = renderPage()
    const links = within(toc()).getAllByRole('link')
    expect(links).toHaveLength(entries.length)
    for (const link of links) {
      const id = link.getAttribute('href')!.replace('#', '')
      const target = container.querySelector(`[data-testid="ds-section-${id}"]`)
      expect(target).not.toBeNull()
      expect(target!.getAttribute('id')).toBe(id)
    }
  })

  it('carries an accessible name made of the text it shows', () => {
    renderPage()
    expect(toc()).toHaveAccessibleName('On this page')
    expect(within(toc()).getByText('On this page')).toBeInTheDocument()
  })

  it('actually observes every section on the real page', () => {
    renderPage()
    // The assertion that stops this whole file being theatre. jsdom ships no
    // IntersectionObserver, so without the mock installed above the component
    // takes its degradation path and every test here still passes against a
    // dead scrollspy. `only()` throws if no observer was ever constructed.
    const observer = handle.only()
    expect(observer.targets).toHaveLength(entries.length)
    expect(observer.targets.map((target) => target.id)).toEqual(entries.map((entry: TocEntry) => entry.id))
  })

  it('moves aria-current as sections cross the scan line', () => {
    renderPage()
    const observer = handle.only()
    const first = entries[0]
    const last = entries[entries.length - 1]

    expect(screen.getByTestId(`page-toc-link-${first.id}`)).toHaveAttribute('aria-current', 'location')

    act(() =>
      observer.fire([
        { target: screen.getByTestId(`ds-section-${first.id}`), isIntersecting: false },
        { target: screen.getByTestId(`ds-section-${last.id}`), isIntersecting: true },
      ]),
    )

    expect(screen.getByTestId(`page-toc-link-${last.id}`)).toHaveAttribute('aria-current', 'location')
    expect(screen.getByTestId(`page-toc-link-${first.id}`)).not.toHaveAttribute('aria-current')
  })

  it('scrolls to the section a clicked entry names', async () => {
    const user = userEvent.setup()
    renderPage()
    const target = entries[entries.length - 1]

    await user.click(screen.getByTestId(`page-toc-link-${target.id}`))

    const scrollIntoView = Reflect.get(Element.prototype, 'scrollIntoView') as ReturnType<typeof vi.fn>
    expect(scrollIntoView).toHaveBeenCalledTimes(1)
    expect(scrollIntoView.mock.instances[0]).toBe(screen.getByTestId(`ds-section-${target.id}`))
    expect(window.location.hash).toBe(`#${target.id}`)
  })
})

describe('the two pages agree on how the index behaves', () => {
  it('uses one component, so neither page can drift from the other', () => {
    // Not a tautology dressed as a test: the Group component on these two
    // pages is duplicated by hand, and the temptation to duplicate the rail
    // the same way is exactly what this asserts against. Same testid, same
    // accessible name, same aria-current mechanism, from one implementation.
    const first = render(<DesignSystemPage />)
    const dsNav = screen.getByTestId('page-toc')
    const dsShape = {
      name: dsNav.getAttribute('aria-labelledby') !== null,
      className: dsNav.className,
      tag: dsNav.tagName,
    }
    first.unmount()

    render(<DesignSystemHeadersPage />)
    const headersNav = screen.getByTestId('page-toc')
    expect({
      name: headersNav.getAttribute('aria-labelledby') !== null,
      className: headersNav.className,
      tag: headersNav.tagName,
    }).toEqual(dsShape)
  })
})
