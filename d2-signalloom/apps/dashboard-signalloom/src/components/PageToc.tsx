/**
 * An on-this-page index, in the shape MkDocs Material established: a sticky
 * right-hand rail listing every section, with the one you are currently
 * reading marked, updating as you scroll.
 *
 * Why it exists. DesignSystemPage is fifteen sections and sixteen hundred
 * lines; DesignSystemHeadersPage is nine. Finding a component on either meant
 * scrolling and hoping. Both pages already carried the structure this needs —
 * a `Group` per section with a stable id — so the index is a reading of
 * something that was already true rather than a new thing to keep in sync.
 *
 * Four decisions worth knowing before editing.
 *
 * 1. THE ACTIVE SECTION IS THE TOPMOST ONE CROSSING A SCAN LINE, NOT THE
 *    TOPMOST ONE ON SCREEN. See TOC_SCAN_LINE below — this is the part
 *    scrollspies get wrong and the reason that constant is exported and
 *    asserted.
 *
 * 2. IT OWNS THE PAGE'S OUTER LAYOUT. The rail is a flex sibling of the
 *    content, not a `position: fixed` overlay, so "must not overlap the
 *    content" is true by construction rather than by arithmetic that goes
 *    stale the first time the sidebar changes width. `App.tsx` gives the page
 *    a 1172px column inside a 268px-sidebar shell; a fixed rail would have to
 *    know both numbers.
 *
 * 3. THE SCOPED STYLE BLOCK IS DELIBERATE, and follows the precedent
 *    DesignSystemHeadersPage set. `:hover`, `:focus-visible` and the media
 *    query cannot be expressed as an inline style object, and the alternative
 *    — editing the shared global.css that every page depends on — is a much
 *    larger blast radius for a feature used by two of them. Every colour is a
 *    `var(--token)`: styles/cssVarUsage.test.ts scans .tsx as well as .css.
 *
 * 4. IT IS PROVIDER-FREE. No router hooks, no context. Both pages that use it
 *    are rendered by a bare `render()` in their tests and must stay that way,
 *    so navigation is a real `<a href="#id">` and the address bar is updated
 *    through `history.replaceState` directly.
 *
 * Contrast, measured against `--bg` in all three themes (Dark / Light / Andy),
 * matching the standard the pages themselves record:
 *
 *   inactive entry   --muted on --bg    7.87 / 7.58 / 8.88   worst 7.58  AAA
 *   active entry     --text  on --bg   19.28 / 17.85 / 17.49 worst 17.49 AAA
 *   active marker    --cyan  on --bg    8.31 /  5.36 /  7.50 worst  5.36 AA-UI
 *   focus ring       --cyan  on --bg    8.31 /  5.36 /  7.50 worst  5.36 AA-UI
 *
 * The Andy column moved when that theme was rebuilt on the Signal Loom brand
 * ramp: the marker was 4.23 against the old red — 1.23 above the 3:1 non-text
 * floor — and is 7.50 against the brand cyan, so the tightest theme for this
 * component is now Light at 5.36 rather than Andy.
 *
 * `--dim` was the first choice for the rail's title and is not used: 4.24 at
 * worst, which fails AA for text. `--muted` carries it instead.
 */
import { useCallback, useEffect, useId, useMemo, useRef, useState, type MouseEvent, type ReactNode } from 'react'

export type TocEntry = {
  /** Must match the `id` attribute on the section it points at. */
  id: string
  /** The visible label. Should be the section's own heading text. */
  title: string
}

/**
 * The observation band, as an IntersectionObserver `rootMargin`.
 *
 * THE ACTIVE-SECTION RULE, which is the part people get wrong:
 *
 *   The active entry is the FIRST IN DOCUMENT ORDER among the sections
 *   currently intersecting this band. Sections are non-overlapping siblings,
 *   so first-in-document-order is exactly topmost-on-screen — and unlike
 *   comparing `boundingClientRect.top` values it needs no geometry, which
 *   matters because those rects are only fresh for the entries in the current
 *   callback batch.
 *
 * Why a band and not the whole viewport. "Topmost intersecting section" is the
 * textbook answer and it is wrong against the default root: a section holds
 * the highlight until its last pixel has scrolled off the top, so the reader
 * spends a whole screenful looking at section B's heading while the nav
 * insists they are in section A. Shrinking the root to a thin horizontal strip
 * fixes it — a section is "current" while it crosses the strip, which is the
 * band of the screen a reader's eye is actually in.
 *
 * `-12%` off the top and `-83%` off the bottom leaves rows 12%–17% of the
 * viewport: a strip about a line and a half tall. Narrow enough that usually
 * exactly one section crosses it, so the tie-break rarely runs at all; wide
 * enough that a fast scroll cannot jump clean over it between frames.
 *
 * Two consequences, both accepted rather than overlooked:
 *
 *   - When a section boundary lands inside the strip, two sections cross it
 *     and the OUTGOING one wins for the strip's worth of scroll. That is what
 *     "topmost" means here, and 5% of a viewport is not worth the machinery to
 *     avoid.
 *   - The last section or two on a page may never reach the strip, because the
 *     page runs out of scroll first. They stay reachable by clicking, and the
 *     entry above them stays marked. Fixing this properly needs the scroll
 *     position, and a scroll handler on a page this long is exactly what an
 *     IntersectionObserver is here to avoid.
 */
export const TOC_SCAN_LINE = '-12% 0px -83% 0px'

/**
 * Below this viewport width the rail is not rendered at all.
 *
 * THE NARROW-VIEWPORT DECISION: hide, rather than collapse or reflow.
 *
 * The budget is the argument. `App.tsx` puts the page inside a 268px sidebar
 * plus 64px of horizontal padding, so at a 1280px viewport the content column
 * is 948px and the rail takes 260 of it, leaving 688px — the narrowest the
 * page's widest specimen (the DataTable with seven columns) reads at. Below
 * that the rail is stealing width from the thing it exists to help you find.
 *
 * Collapsing it into a disclosure above the content was the alternative and
 * was rejected: a fourteen-entry list pushed above the page's opening
 * paragraph is a worse first screen than no index, and a `<details>` cannot be
 * opened by default at one width and closed at another without JavaScript
 * that would then disagree with the CSS. Moving it below the content makes it
 * an index you reach by doing the scrolling it was meant to save.
 *
 * So: hidden. Every section stays reachable by scrolling and by direct anchor
 * link, which is what a reader on a narrow screen would have had anyway. This
 * is a superadmin-only internal reference page inside a `height: 100vh;
 * overflow: hidden` desktop shell — it is not a mobile surface, and pretending
 * otherwise would cost content width on the widths that do matter.
 *
 * `display: none` also settles the no-overlap requirement at narrow widths in
 * the only way that cannot be got wrong.
 */
const RAIL_MIN_VIEWPORT = 1280

const RAIL_STYLES = `
.ds-toc-layout {
  display: flex;
  align-items: flex-start;
  gap: 28px;
}
.ds-toc-content {
  flex: 1 1 auto;
  /* Without this a wide child — the DataTable specimens — refuses to shrink
     below its content width and pushes the rail off the page. */
  min-width: 0;
}
.ds-toc-rail {
  flex: 0 0 232px;
  width: 232px;
  position: sticky;
  top: 20px;
  align-self: flex-start;
  /* main is the scroll container and is exactly 100vh, so the rail can never
     grow past one screen; it scrolls itself if the section list outgrows it. */
  max-height: calc(100vh - 48px);
  overflow-y: auto;
}
@media (max-width: ${RAIL_MIN_VIEWPORT - 1}px) {
  .ds-toc-rail { display: none; }
}
.ds-toc-title {
  margin: 0 0 8px;
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.07em;
  color: var(--muted);
}
.ds-toc-list {
  list-style: none;
  margin: 0;
  padding: 0;
  border-left: 1px solid var(--border-subtle);
}
.ds-toc-list li { margin: 0; }
.ds-toc-link {
  display: block;
  padding: 5px 0 5px 12px;
  /* Pulls the 2px active marker over the list's 1px track so the two read as
     one line rather than as a step. */
  margin-left: -1px;
  border-left: 2px solid transparent;
  font-size: 12.5px;
  line-height: 1.45;
  color: var(--muted);
  text-decoration: none;
}
.ds-toc-link:hover { color: var(--text); }
.ds-toc-link:focus-visible {
  /* global.css only paints a focus ring on button; an anchor gets the browser
     default, which is invisible on both dark themes. */
  outline: 2px solid var(--cyan);
  outline-offset: 2px;
  border-radius: 2px;
}
.ds-toc-link[aria-current='location'] {
  color: var(--text);
  font-weight: 600;
  border-left-color: var(--cyan);
}
`

/** Reads the fragment, tolerating the percent-encoding a copied URL can carry. */
function hashTarget(): string {
  const raw = window.location.hash.slice(1)
  if (!raw) return ''
  try {
    return decodeURIComponent(raw)
  } catch {
    return raw
  }
}

function scrollToSection(element: HTMLElement, animate: boolean): void {
  const reduced = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true
  // jsdom implements no layout and leaves scrollIntoView undefined, so the
  // optional call is load-bearing for every page test that mounts this.
  element.scrollIntoView?.({ behavior: animate && !reduced ? 'smooth' : 'auto', block: 'start' })
}

/**
 * Wraps a page's content and puts an index of its sections beside it.
 *
 * Every `entries[].id` must exist as an `id` attribute on an element inside
 * `children`; the pages guarantee this through their `Group` component, and
 * their own tests assert the two sets match.
 */
export default function PageTocLayout({
  entries,
  children,
}: {
  entries: readonly TocEntry[]
  children: ReactNode
}) {
  const titleId = useId()
  const contentRef = useRef<HTMLDivElement>(null)

  const ids = useMemo(() => entries.map((entry) => entry.id), [entries])

  // Seeded from the URL rather than corrected by an effect afterwards, so
  // landing on /design-system#data-table never flashes the first entry as
  // current before settling on the right one.
  const [activeId, setActiveId] = useState<string | null>(() => {
    const target = hashTarget()
    if (target && ids.includes(target)) return target
    return ids[0] ?? null
  })

  /** Scoped to our own subtree: an id elsewhere in the app is not our section. */
  const findSection = useCallback((id: string): HTMLElement | null => {
    const element = document.getElementById(id)
    return element && contentRef.current?.contains(element) ? element : null
  }, [])

  // ── Scrollspy ─────────────────────────────────────────────────────────────
  useEffect(() => {
    // Missing in jsdom and in any non-DOM renderer. Degrade to a plain index:
    // the links and anchors still work, only the highlight stops moving.
    if (typeof IntersectionObserver === 'undefined') return

    const targets = ids.map(findSection).filter((el): el is HTMLElement => el !== null)
    if (targets.length === 0) return

    // The browser reports CHANGES, not the current picture — a callback for a
    // section entering says nothing about the three still inside. Accumulating
    // here is what makes "first in document order among intersecting" a
    // question about the whole page rather than about the latest batch.
    const intersecting = new Set<string>()

    const observer = new IntersectionObserver(
      (records) => {
        for (const record of records) {
          if (record.isIntersecting) intersecting.add(record.target.id)
          else intersecting.delete(record.target.id)
        }
        const winner = ids.find((id) => intersecting.has(id))
        // No winner means the band is empty — mid-way through a section taller
        // than the strip's distance from the top. Holding the last answer beats
        // blanking the nav, which would flicker on every long section.
        if (winner) setActiveId(winner)
      },
      { rootMargin: TOC_SCAN_LINE, threshold: 0 },
    )

    for (const target of targets) observer.observe(target)
    return () => observer.disconnect()
  }, [ids, findSection])

  // ── Landing on an anchor ──────────────────────────────────────────────────
  useEffect(() => {
    const target = hashTarget()
    if (!target || !ids.includes(target)) return

    // One frame late, deliberately. The sections exist by the time an effect
    // runs but have no positions until the browser has laid them out, and
    // scrollIntoView against an unlaid-out tree lands at the top of the page.
    // One frame is enough for these pages, which render every section
    // synchronously; a page that streamed its sections in would need to
    // re-run this when they arrive.
    const frame = requestAnimationFrame(() => {
      const element = findSection(target)
      if (!element) return
      // No animation: smooth-scrolling a page the reader has not seen yet is
      // motion with nothing to orient against.
      scrollToSection(element, false)
      setActiveId(target)
    })
    return () => cancelAnimationFrame(frame)
  }, [ids, findSection])

  const handleClick = (event: MouseEvent<HTMLAnchorElement>, id: string) => {
    // Open-in-new-tab, middle-click and the rest belong to the browser.
    if (event.defaultPrevented) return
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return

    const element = findSection(id)
    // No target found: let the browser's own fragment handling have a go
    // rather than swallowing the click and doing nothing at all.
    if (!element) return

    event.preventDefault()
    scrollToSection(element, true)
    // Set now rather than waiting for the observer, which will not fire until
    // the smooth scroll has actually carried the section across the scan line.
    setActiveId(id)
    // replaceState, not pushState: these pages mount under a react-router
    // BrowserRouter, and pushing an entry the router never saw leaves the back
    // button walking a stack it cannot explain. The address bar still updates,
    // which is the part that makes the link copyable. The existing state object
    // is passed through because react-router keeps its own bookkeeping there.
    window.history.replaceState(window.history.state, '', `#${id}`)
  }

  return (
    <div className="ds-toc-layout">
      <style>{RAIL_STYLES}</style>
      <div className="ds-toc-content" ref={contentRef}>
        {children}
      </div>
      {entries.length > 0 && (
        <nav className="ds-toc-rail" aria-labelledby={titleId} data-testid="page-toc">
          {/* A div, not a heading: the page's own sections are the h2s, and
              slipping another one into that outline to label a nav would make
              the document structure worse to navigate, not better. The nav
              landmark is what a screen reader jumps to. */}
          <div className="ds-toc-title" id={titleId}>
            On this page
          </div>
          <ul className="ds-toc-list">
            {entries.map((entry) => (
              <li key={entry.id}>
                <a
                  className="ds-toc-link"
                  href={`#${entry.id}`}
                  data-testid={`page-toc-link-${entry.id}`}
                  // aria-current="location" rather than "true": this is a
                  // position within the page, which is the exact case the
                  // value exists for. Colour is not the only signal — weight
                  // and the marker bar change too.
                  aria-current={activeId === entry.id ? 'location' : undefined}
                  onClick={(event) => handleClick(event, entry.id)}
                >
                  {entry.title}
                </a>
              </li>
            ))}
          </ul>
        </nav>
      )}
    </div>
  )
}
