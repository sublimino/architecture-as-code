import { describe, expect, it } from 'vitest'
import { fireEvent, render, screen, within } from '@testing-library/react'
import DesignSystemHeadersPage from './DesignSystemHeadersPage'
import { ALERTS, SEVERITY_LABELS, highestSeverity, toHref } from '../components/headers/alerts'

// Like DesignSystemPage, the page under test is deliberately provider-free: no
// router, no auth context, no API client. The bare `render()` calls below are
// the assertion, not a shortcut — a gallery of proposals that needs a live
// cluster to render is a gallery nobody opens, and the deep links are plain
// <a href> for exactly this reason.
//
// Sections are queried by testid rather than by their heading text throughout,
// following DesignSystemPage.test.tsx: the whole value of this page is in its
// prose, that prose will be rewritten, and a suite that breaks on a copy edit
// gets its assertions weakened rather than its wording improved.

/** The five candidates, in the order the page presents them. */
const VARIANTS = [
  { id: 'command', frame: 'dsh-variant-command' },
  { id: 'context', frame: 'dsh-variant-context' },
  { id: 'operations', frame: 'dsh-variant-operations' },
  { id: 'quiet', frame: 'dsh-variant-quiet' },
  { id: 'situation', frame: 'dsh-variant-situation' },
] as const

/** Every section on the page, variants and framing alike. */
const SECTIONS = [
  'deep-linking',
  'command',
  'context',
  'operations',
  'quiet',
  'situation',
  'comparison',
  'recommendation',
  'rules',
] as const

const TOP_ALERT = highestSeverity(ALERTS)!

// ── The label-in-name sweep ──────────────────────────────────────────────────
//
// The generalised form of the bug components/sidebarLabelInName.test.tsx was
// written for: an explicit aria-label REPLACES an element's content as its
// accessible name, so a control reading "Help & Support" and named "Open help
// and support" is a control a speech-input user cannot say and a screen reader
// describes with words that are on no part of the screen.
//
// Asserted word by word rather than as a substring, because the DOM
// concatenates across element boundaries — a button rendering a "6" pill next
// to the word "unread" has textContent "6unread", which contains no substring
// of any sane label. Every visible word must appear in the name; the order and
// the punctuation between them are the designer's business.
//
// aria-hidden subtrees are excluded, and that exclusion is doing real work: a
// ⌘K hint chip beside the word "Search" is an affordance hint, not part of the
// control's label, and it is marked aria-hidden precisely to say so.

/** Visible words, with element boundaries treated as spaces and aria-hidden pruned. */
function visibleWords(el: Element): string[] {
  const clone = el.cloneNode(true) as HTMLElement
  clone.querySelectorAll('[aria-hidden="true"]').forEach((node) => node.remove())
  const text = Array.from(clone.querySelectorAll('*'))
    .concat(clone)
    .map((node) =>
      Array.from(node.childNodes)
        .filter((child) => child.nodeType === 3)
        .map((child) => child.textContent ?? '')
        .join(' '),
    )
    .join(' ')
  return text
    .split(/\s+/)
    .map((word) => word.trim())
    .filter((word) => /[a-z0-9]/i.test(word))
}

function labelledControls(container: HTMLElement): HTMLElement[] {
  return Array.from(container.querySelectorAll<HTMLElement>('button[aria-label], a[aria-label]'))
}

describe('DesignSystemHeadersPage — the five candidates', () => {
  it('renders all five variants and their sections', () => {
    render(<DesignSystemHeadersPage />)

    for (const { id, frame } of VARIANTS) {
      expect(screen.getByTestId(`ds-section-${id}`)).toBeInTheDocument()
      expect(screen.getByTestId(frame)).toBeInTheDocument()
    }
  })

  it('gives every section a heading and a when-to-use line', () => {
    render(<DesignSystemHeadersPage />)

    for (const id of SECTIONS) {
      const section = screen.getByTestId(`ds-section-${id}`)
      const heading = within(section).getByTestId(`ds-heading-${id}`)
      // H2 by testid rather than by role, for the reason DesignSystemPage's
      // Group carries one: a specimen can bring its own heading along.
      expect(heading.tagName).toBe('H2')
      expect(heading.textContent?.trim().length ?? 0).toBeGreaterThan(0)
      expect(within(section).getByTestId(`ds-when-${id}`).textContent?.trim().length ?? 0).toBeGreaterThan(20)
    }
  })

  it('states when NOT to reach for each of the five, not only when to', () => {
    // The half of a design-system entry that is usually missing, and the half
    // that saves the argument in six months. Asserted per variant so a new
    // candidate cannot be added with only its sales pitch.
    render(<DesignSystemHeadersPage />)

    for (const { id } of VARIANTS) {
      const notWhen = screen.getByTestId(`ds-notwhen-${id}`)
      expect(notWhen.textContent).toMatch(/do not use it when/i)
      expect(notWhen.textContent!.length).toBeGreaterThan(60)
    }
  })

  it('compares all five on the same axes', () => {
    render(<DesignSystemHeadersPage />)
    for (const { id } of VARIANTS) {
      expect(screen.getByTestId(`ds-comparison-row-${id}`)).toBeInTheDocument()
    }
  })

  it('makes a recommendation rather than offering five neutral options', () => {
    render(<DesignSystemHeadersPage />)
    expect(screen.getByTestId('ds-recommendation').textContent!.length).toBeGreaterThan(200)
  })
})

describe('DesignSystemHeadersPage — deep linking', () => {
  it('points the deep link at the exact row, not at the page', () => {
    // The assertion this page exists for. Three separate claims, because three
    // separate mistakes are possible and only the first one is ever noticed:
    // the wrong resource, the missing filter state, and the missing row anchor.
    render(<DesignSystemHeadersPage />)

    const href = screen.getByTestId('ds-deep-link-good').getAttribute('href')!

    expect(href).toBe('/compliance/eu-ai-act?control=ART-14-3&state=failing#row-sbom-collector')
    // The resource, not its list route.
    expect(href.startsWith('/compliance/eu-ai-act')).toBe(true)
    expect(href).not.toBe('/compliance')
    // The filter state, without which the row is on page four of an unfiltered list.
    expect(href).toContain('control=ART-14-3')
    expect(href).toContain('state=failing')
    // The row itself, so the page can scroll to it and so the URL survives being
    // pasted into a ticket.
    expect(href.endsWith('#row-sbom-collector')).toBe(true)
  })

  it('keeps the shallow anti-pattern beside it, and keeps it shallow', () => {
    // If this ever grows a query or an anchor it has stopped being the
    // counter-example and the comparison silently means nothing.
    render(<DesignSystemHeadersPage />)

    const href = screen.getByTestId('ds-deep-link-bad').getAttribute('href')!
    expect(href).toBe('/compliance')
    expect(href).not.toContain('?')
    expect(href).not.toContain('#')
  })

  it('carries the whole target in every alert link in every variant', () => {
    render(<DesignSystemHeadersPage />)

    // The command palette and the operations drawer both list all six.
    fireEvent.focus(screen.getByTestId('dsh-command-input'))
    fireEvent.click(screen.getByTestId('dsh-operations-bell'))

    for (const alert of ALERTS) {
      const expected = toHref(alert.target)
      expect(screen.getByTestId(`dsh-command-alert-${alert.id}`)).toHaveAttribute('href', expected)
      expect(screen.getByTestId(`dsh-alert-link-${alert.id}`)).toHaveAttribute('href', expected)
      // Every alert names a specific resource: a target with no query and no
      // anchor is only acceptable when the path itself already identifies one.
      const identifiesARow =
        Boolean(alert.target.anchor) || alert.target.path.split('/').filter(Boolean).length >= 3
      expect(identifiesARow).toBe(true)
    }
  })

  it('prints the resolved href beside each alert, so a claim to deep-link is checkable', () => {
    render(<DesignSystemHeadersPage />)
    fireEvent.click(screen.getByTestId('dsh-operations-bell'))

    for (const alert of ALERTS) {
      expect(screen.getByTestId(`dsh-alert-href-${alert.id}`)).toHaveTextContent(toHref(alert.target))
    }
  })
})

describe('DesignSystemHeadersPage — 1 · Command bar', () => {
  it('opens the palette on focus and closes it on Escape', () => {
    render(<DesignSystemHeadersPage />)

    expect(screen.queryByTestId('dsh-command-palette')).toBeNull()

    const input = screen.getByTestId('dsh-command-input')
    fireEvent.focus(input)
    expect(screen.getByTestId('dsh-command-palette')).toBeInTheDocument()

    fireEvent.keyDown(input, { key: 'Escape' })
    expect(screen.queryByTestId('dsh-command-palette')).toBeNull()
  })

  it('moves focus from the input into the results with ArrowDown', () => {
    // The keyboard path is the whole proposition of a command bar; if it only
    // works with a pointer it is a search box with extra chrome.
    render(<DesignSystemHeadersPage />)

    const input = screen.getByTestId('dsh-command-input')
    fireEvent.focus(input)
    fireEvent.keyDown(input, { key: 'ArrowDown' })

    expect(document.activeElement).toBe(screen.getByTestId(`dsh-command-alert-${TOP_ALERT.id}`))
  })

  it('filters commands and alerts against the same query', () => {
    render(<DesignSystemHeadersPage />)

    const input = screen.getByTestId('dsh-command-input')
    fireEvent.focus(input)
    fireEvent.change(input, { target: { value: 'sbom' } })

    expect(screen.getByTestId(`dsh-command-alert-${TOP_ALERT.id}`)).toBeInTheDocument()
    expect(screen.queryByTestId('dsh-command-alert-alert-new-account')).toBeNull()
    expect(screen.queryByTestId('dsh-command-item-cmd-agents')).toBeNull()
  })

  it('surfaces the unread count outside the palette', () => {
    // Deliberate: the whole risk of a search-first header is that an unattended
    // alert sits behind an interaction. The count does not.
    render(<DesignSystemHeadersPage />)

    expect(screen.getByTestId('dsh-command-unread-count')).toHaveTextContent(String(ALERTS.length))

    fireEvent.click(screen.getByTestId('dsh-command-unread'))
    expect(screen.getByTestId('dsh-command-palette')).toBeInTheDocument()
  })
})

describe('DesignSystemHeadersPage — 2 · Context bar', () => {
  it('marks the last breadcrumb as the current page and links the rest', () => {
    render(<DesignSystemHeadersPage />)

    expect(screen.getByTestId('dsh-crumb-0')).toHaveAttribute('href', '/compliance')
    expect(screen.getByTestId('dsh-crumb-1')).toHaveAttribute('href', '/compliance/eu-ai-act')

    const current = screen.getByTestId('dsh-crumb-2')
    expect(current).toHaveAttribute('aria-current', 'page')
    expect(current.tagName).not.toBe('A')
  })

  it('expands and collapses the alerts scoped to the entity on screen', () => {
    render(<DesignSystemHeadersPage />)

    const toggle = screen.getByTestId('dsh-context-scoped-toggle')
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByTestId('dsh-context-scoped-panel')).toBeNull()

    fireEvent.click(toggle)
    expect(toggle).toHaveAttribute('aria-expanded', 'true')

    const panel = screen.getByTestId('dsh-context-scoped-panel')
    // Scoped means scoped: only the alerts about this framework, and nothing else.
    const scoped = ALERTS.filter((a) => a.target.path.startsWith('/compliance/eu-ai-act'))
    expect(scoped.length).toBeGreaterThan(0)
    for (const alert of scoped) {
      expect(within(panel).getByTestId(`dsh-context-alert-${alert.id}`)).toBeInTheDocument()
    }
    for (const alert of ALERTS.filter((a) => !scoped.includes(a))) {
      expect(within(panel).queryByTestId(`dsh-context-alert-${alert.id}`)).toBeNull()
    }

    fireEvent.click(toggle)
    expect(screen.queryByTestId('dsh-context-scoped-panel')).toBeNull()
  })

  it('always offers a way to the alerts it is hiding', () => {
    // Scoping is this variant's best idea and its sharpest edge. The count of
    // everything else is the mitigation, so it is asserted rather than trusted.
    render(<DesignSystemHeadersPage />)

    const scoped = ALERTS.filter((a) => a.target.path.startsWith('/compliance/eu-ai-act')).length
    expect(screen.getByTestId('dsh-context-elsewhere')).toHaveTextContent(String(ALERTS.length - scoped))
  })
})

describe('DesignSystemHeadersPage — 3 · Operations console', () => {
  it('names what the operator is pointed at, in the chrome', () => {
    // The single reason this variant exists. If the strip ever stops saying
    // which cluster, the variant has become variant 4 with more padding.
    render(<DesignSystemHeadersPage />)

    const strip = screen.getByTestId('dsh-operations-env-strip')
    expect(within(strip).getByTestId('dsh-operations-tenant')).toHaveTextContent('Acme Insurance')
    expect(within(strip).getByTestId('dsh-operations-cluster')).toHaveTextContent('prod-eu-west-1')
    expect(within(strip).getByTestId('dsh-operations-data-mode')).toHaveTextContent('Demo data')
    expect(within(strip).getByTestId('dsh-operations-superadmin')).toHaveTextContent('Active')
  })

  it('opens the drawer on click and closes it on Escape, returning focus to the bell', () => {
    render(<DesignSystemHeadersPage />)

    const bell = screen.getByTestId('dsh-operations-bell')
    expect(bell).toHaveAttribute('aria-expanded', 'false')

    fireEvent.click(bell)
    expect(screen.getByTestId('dsh-operations-drawer')).toBeInTheDocument()
    expect(bell).toHaveAttribute('aria-expanded', 'true')
    // Focus moves into the panel, or a keyboard user is left behind the drawer.
    expect(document.activeElement).toBe(screen.getByTestId('dsh-operations-drawer-close'))

    fireEvent.keyDown(document, { key: 'Escape' })
    expect(screen.queryByTestId('dsh-operations-drawer')).toBeNull()
    expect(document.activeElement).toBe(bell)
  })

  it('closes on the drawer close button too', () => {
    render(<DesignSystemHeadersPage />)

    fireEvent.click(screen.getByTestId('dsh-operations-bell'))
    fireEvent.click(screen.getByTestId('dsh-operations-drawer-close'))
    expect(screen.queryByTestId('dsh-operations-drawer')).toBeNull()
  })

  it('dismisses in place and drops the count', () => {
    render(<DesignSystemHeadersPage />)

    fireEvent.click(screen.getByTestId('dsh-operations-bell'))
    expect(screen.getByTestId('dsh-operations-unread-count')).toHaveTextContent(String(ALERTS.length))

    fireEvent.click(screen.getByTestId(`dsh-alert-dismiss-${TOP_ALERT.id}`))

    expect(screen.queryByTestId(`dsh-operations-alert-${TOP_ALERT.id}`)).toBeNull()
    expect(screen.getByTestId('dsh-operations-unread-count')).toHaveTextContent(String(ALERTS.length - 1))
  })

  it('says where dismissed alerts went, rather than showing an empty box', () => {
    render(<DesignSystemHeadersPage />)

    fireEvent.click(screen.getByTestId('dsh-operations-bell'))
    fireEvent.click(screen.getByTestId('dsh-operations-dismiss-all'))

    expect(screen.getByTestId('dsh-operations-empty')).toHaveTextContent(/audit trail/i)
    expect(screen.queryByTestId('dsh-operations-unread-count')).toBeNull()
    expect(screen.getByTestId('dsh-operations-bell')).toHaveAccessibleName(/none unread/i)
  })
})

describe('DesignSystemHeadersPage — 4 · Quiet header', () => {
  it('shows the single worst alert, as a link to its exact row', () => {
    render(<DesignSystemHeadersPage />)

    const link = screen.getByTestId('dsh-quiet-alert')
    expect(link).toHaveAttribute('href', toHref(TOP_ALERT.target))
    expect(link).toHaveTextContent(TOP_ALERT.title)
  })

  it('collapses to nothing when there is nothing to say, and comes back', () => {
    // The state this variant is really being judged on, and the state most
    // headers never draw.
    render(<DesignSystemHeadersPage />)

    fireEvent.click(screen.getByTestId('ds-quiet-toggle'))
    expect(screen.queryByTestId('dsh-quiet-alert')).toBeNull()
    expect(screen.getByTestId('dsh-quiet-clear')).toHaveTextContent('All clear')

    fireEvent.click(screen.getByTestId('ds-quiet-toggle'))
    expect(screen.getByTestId('dsh-quiet-alert')).toBeInTheDocument()
  })
})

describe('DesignSystemHeadersPage — 5 · Situation header', () => {
  it('rests quietly, promotes on an incident, and demotes on acknowledge', () => {
    render(<DesignSystemHeadersPage />)

    expect(screen.getByTestId('dsh-situation-rest')).toBeInTheDocument()
    expect(screen.queryByTestId('dsh-situation-banner')).toBeNull()

    fireEvent.click(screen.getByTestId('dsh-situation-simulate'))

    const banner = screen.getByTestId('dsh-situation-banner')
    expect(banner).toHaveAttribute('role', 'alert')
    expect(banner).toHaveTextContent(TOP_ALERT.title)
    expect(banner).toHaveTextContent(SEVERITY_LABELS[TOP_ALERT.severity])
    expect(screen.queryByTestId('dsh-situation-rest')).toBeNull()

    fireEvent.click(screen.getByTestId('dsh-situation-acknowledge'))
    expect(screen.queryByTestId('dsh-situation-banner')).toBeNull()
    expect(screen.getByTestId('dsh-situation-rest')).toBeInTheDocument()
  })

  it('makes the deep link the banner’s primary offer', () => {
    render(<DesignSystemHeadersPage />)
    fireEvent.click(screen.getByTestId('dsh-situation-simulate'))

    const link = screen.getByTestId('dsh-situation-deep-link')
    expect(link).toHaveAttribute('href', toHref(TOP_ALERT.target))
    expect(link).toHaveTextContent(TOP_ALERT.resource)
  })

  it('mounts no live region until someone asks for one', () => {
    // Five headers announcing themselves on mount is the failure mode
    // DesignSystemPage's live-region roster exists to prevent, reached from the
    // other direction. This page's only region is the promoted banner.
    const { container } = render(<DesignSystemHeadersPage />)

    expect(container.querySelectorAll('[role="alert"], [role="status"], [aria-live]')).toHaveLength(0)

    fireEvent.click(screen.getByTestId('dsh-situation-simulate'))
    expect(container.querySelectorAll('[role="alert"], [role="status"], [aria-live]')).toHaveLength(1)

    fireEvent.click(screen.getByTestId('dsh-situation-acknowledge'))
    expect(container.querySelectorAll('[role="alert"], [role="status"], [aria-live]')).toHaveLength(0)
  })
})

describe('DesignSystemHeadersPage — accessible names', () => {
  it('never names a control with words that are not on it', () => {
    // Every panel opened first, so the sweep covers the controls that only
    // exist while something is open — which is where this class of bug hides.
    const { container } = render(<DesignSystemHeadersPage />)
    fireEvent.focus(screen.getByTestId('dsh-command-input'))
    fireEvent.click(screen.getByTestId('dsh-operations-bell'))
    fireEvent.click(screen.getByTestId('dsh-context-scoped-toggle'))
    fireEvent.click(screen.getByTestId('dsh-situation-simulate'))

    const controls = labelledControls(container)
    expect(controls.length).toBeGreaterThan(10)

    const offenders: string[] = []
    for (const control of controls) {
      const label = (control.getAttribute('aria-label') ?? '').toLowerCase()
      for (const word of visibleWords(control)) {
        if (!label.includes(word.toLowerCase())) {
          offenders.push(`${control.dataset.testid ?? control.tagName}: visible "${word}" is not in aria-label "${label}"`)
        }
      }
    }

    expect(offenders).toEqual([])
  })

  it('gives every icon-only control a name a person would say', () => {
    const { container } = render(<DesignSystemHeadersPage />)
    fireEvent.click(screen.getByTestId('dsh-operations-bell'))

    const iconOnly = labelledControls(container).filter((c) => visibleWords(c).length === 0)
    expect(iconOnly.length).toBeGreaterThan(0)

    for (const control of iconOnly) {
      const label = control.getAttribute('aria-label')!
      // Two or more real words. A name like "Alerts" or "×" is not something a
      // speech-input user can distinguish from the six other controls near it.
      expect(label.split(/\s+/).filter((w) => /[a-z]/i.test(w)).length).toBeGreaterThanOrEqual(2)
    }
  })

  it('puts the unread count in the bell’s name, not only in its badge', () => {
    // The badge is aria-hidden, because it is a red pill that a screen reader
    // would otherwise read as a bare number with no noun attached. That makes
    // the name the only carrier of the count, so it is asserted here.
    render(<DesignSystemHeadersPage />)

    const bell = screen.getByTestId('dsh-operations-bell')
    expect(bell).toHaveAccessibleName(new RegExp(`${ALERTS.length} unread`, 'i'))
    expect(bell).toHaveAccessibleName(/critical/i)
    expect(screen.getByTestId('dsh-operations-unread-count')).toHaveAttribute('aria-hidden', 'true')
  })

  it('opens nothing on hover — every panel needs a click or a key', () => {
    render(<DesignSystemHeadersPage />)

    fireEvent.mouseOver(screen.getByTestId('dsh-operations-bell'))
    fireEvent.mouseEnter(screen.getByTestId('dsh-operations-bell'))
    expect(screen.queryByTestId('dsh-operations-drawer')).toBeNull()

    fireEvent.mouseEnter(screen.getByTestId('dsh-context-scoped-toggle'))
    expect(screen.queryByTestId('dsh-context-scoped-panel')).toBeNull()
  })
})

describe('DesignSystemHeadersPage — theme safety', () => {
  it('paints every specimen from tokens, never from a literal colour', () => {
    // styles/cssVarUsage.test.ts is the build-level guard and it scans source
    // text. This one watches the rendered output, which is what the reader
    // actually gets: a bare hex here would be correct in exactly one of Dark,
    // Light and Andy and wrong in the other two.
    const { container } = render(<DesignSystemHeadersPage />)
    fireEvent.click(screen.getByTestId('dsh-operations-bell'))
    fireEvent.click(screen.getByTestId('dsh-situation-simulate'))

    const offenders: string[] = []
    for (const el of Array.from(container.querySelectorAll<HTMLElement>('[style]'))) {
      const style = el.getAttribute('style') ?? ''
      for (const property of ['color', 'background', 'background-color', 'border-color']) {
        const match = style.match(new RegExp(`(?:^|;)\\s*${property}\\s*:\\s*([^;]+)`))
        if (match && /#[0-9a-f]{3,8}\b/i.test(match[1])) {
          offenders.push(`${el.dataset.testid ?? el.tagName}: ${property}: ${match[1].trim()}`)
        }
      }
    }

    expect(offenders).toEqual([])
  })
})
