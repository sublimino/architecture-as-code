/**
 * Design System — Headers. Five candidate top bars, side by side, so the
 * choice can be made by looking rather than by describing.
 *
 * Why it exists. components/TopNav.tsx is the header this app has, and it was
 * never chosen — it accreted. It carries a second copy of four nav links the
 * sidebar already owns, a Help button, an avatar and a Sign out, and it says
 * nothing about which cluster or which tenant the reader is pointed at. That
 * is defensible for an internal tool and it is not defensible in front of a
 * bank, where the header is the first thing anyone reads and the last thing
 * anyone trusts. Rather than argue about it in prose, this page renders five
 * genuinely different answers and lets them be compared.
 *
 * WHAT THIS PAGE DOES NOT DO. It does not touch TopNav. Nothing here is
 * mounted by the app shell, nothing here changes any existing behaviour, and
 * adopting one of the five is a separate, deliberate act. This is a proposal
 * surface.
 *
 * Three things worth knowing before you edit it.
 *
 * 1. IT IS PROVIDER-FREE, like DesignSystemPage. No router, no auth context,
 *    no API client — every specimen is driven by fixtures in
 *    components/headers/alerts.ts, and DesignSystemHeadersPage.test.tsx
 *    renders it with a bare `render()` to keep it that way. The deep links are
 *    plain `<a href>` for exactly this reason: `toHref()` produces the same
 *    string a `<Link to={…}>` would consume, so the payload under test is the
 *    real one while the page stays mountable anywhere.
 *
 * 2. IT MOUNTS ONE LIVE REGION, AND ONLY AFTER A CLICK. The Situation header's
 *    promoted banner is `role="alert"`; it is absent until someone presses
 *    "Simulate a critical incident". Five headers each announcing themselves
 *    on mount would be the failure mode DesignSystemPage's live-region roster
 *    exists to prevent, arrived at from the other direction.
 *
 * 3. THE SCOPED STYLE BLOCK IS DELIBERATE. Hover and :focus-visible cannot be
 *    expressed in an inline style object, and global.css only paints a focus
 *    ring on `button` — an anchor gets the browser default, which is invisible
 *    on the dark themes. Nine other agents are in src/components/ and
 *    styles/global.css right now, so rather than edit a shared stylesheet this
 *    page carries its own `dsh-` prefixed rules. Every colour in it is a
 *    var(--token): styles/cssVarUsage.test.ts scans .tsx as well as .css.
 */
import { useState, type CSSProperties, type ReactNode } from 'react'
import {
  ALERTS,
  SHALLOW_TARGET,
  alertLinkName,
  highestSeverity,
  toHref,
  type HeaderAlert,
} from '../components/headers/alerts'
import {
  CommandBarHeader,
  ContextBarHeader,
  OperationsHeader,
  QuietHeader,
  SituationHeader,
} from '../components/headers/variants'
import PageTocLayout, { type TocEntry } from '../components/PageToc'

/**
 * The on-this-page index, in document order.
 *
 * The labels are SHORTER than the headings they point at, which the headings
 * on this page earn by being sentences — "3 · Operations console — the header
 * is an instrument panel" is a good heading and a bad nav entry, and a
 * 232px rail full of four-line links is not an index. What the labels may not
 * do is say something different: DesignSystemHeadersPage.test.tsx asserts each
 * one appears verbatim inside the heading it links to, so a shortened label
 * stays a truthful one and renaming a section without renaming its entry is a
 * red build.
 */
export const DESIGN_SYSTEM_HEADER_SECTIONS: readonly TocEntry[] = [
  { id: 'deep-linking', title: 'The deep-link contract' },
  { id: 'command', title: '1 · Command bar' },
  { id: 'context', title: '2 · Context bar' },
  { id: 'operations', title: '3 · Operations console' },
  { id: 'quiet', title: '4 · Quiet header' },
  { id: 'situation', title: '5 · Situation header' },
  { id: 'comparison', title: 'The five, on the axes a choice turns on' },
  { id: 'recommendation', title: 'The recommendation' },
  { id: 'rules', title: 'What all five obey' },
]

// ── Layout helpers ───────────────────────────────────────────────────────────
//
// Deliberately the same shapes DesignSystemPage uses — `Group` with its
// section/heading/when-to-use testids, and an `ExampleHeading` at h3 so a
// group never carries two h2s. Duplicated rather than imported: that page's
// helpers are private to it, and a design-system page that reaches into
// another page's internals to render itself is making a worse argument than
// the one it is trying to make.

/**
 * A section. The `when` line is the part that earns the page.
 *
 * Every group here states when to reach for the thing AND when not to. A
 * gallery that only shows is a catalogue; the reader still has to decide, and
 * deciding is the expensive part.
 */
function Group({
  id,
  title,
  when,
  children,
}: {
  id: string
  title: string
  when: ReactNode
  children: ReactNode
}) {
  return (
    // Same as DesignSystemPage's Group: `id` is the anchor PageToc links to and
    // observes, `data-testid` is what the suites query, and neither can stand
    // in for the other.
    <section id={id} data-testid={`ds-section-${id}`} style={{ marginBottom: 38, scrollMarginTop: 20 }}>
      <h2 data-testid={`ds-heading-${id}`} style={{ fontSize: 16, fontWeight: 700, color: 'var(--text)', margin: '0 0 3px' }}>
        {title}
      </h2>
      <p
        data-testid={`ds-when-${id}`}
        style={{ fontSize: 12.5, color: 'var(--muted)', margin: '0 0 14px', maxWidth: 820, lineHeight: 1.55 }}
      >
        {when}
      </p>
      {children}
    </section>
  )
}

function ExampleHeading({ id, title, blurb }: { id: string; title: string; blurb: string }) {
  return (
    <>
      <h3 data-testid={`ds-example-heading-${id}`} style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)', margin: '18px 0 3px' }}>
        {title}
      </h3>
      <p style={{ fontSize: 12, color: 'var(--muted)', margin: '0 0 10px', maxWidth: 820, lineHeight: 1.5 }}>{blurb}</p>
    </>
  )
}

/** A boxed aside for the cost of the thing above it. Same shape as DesignSystemPage's Caveat. */
function Caveat({ children }: { children: ReactNode }) {
  return (
    <p
      style={{
        borderLeft: '2px solid var(--amber)',
        paddingLeft: 10,
        margin: '12px 0 0',
        fontSize: 12,
        color: 'var(--muted)',
        lineHeight: 1.5,
        maxWidth: 820,
      }}
    >
      {children}
    </p>
  )
}

/** "Do not reach for this when …" — always rendered, never optional. */
function NotWhen({ id, children }: { id: string; children: ReactNode }) {
  return (
    <p
      data-testid={`ds-notwhen-${id}`}
      style={{
        borderLeft: '2px solid var(--error)',
        paddingLeft: 10,
        margin: '10px 0 0',
        fontSize: 12,
        color: 'var(--muted)',
        lineHeight: 1.5,
        maxWidth: 820,
      }}
    >
      <strong style={{ color: 'var(--text)', fontWeight: 600 }}>Do not use it when </strong>
      {children}
    </p>
  )
}

const cardStyle: CSSProperties = {
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius)',
  background: 'var(--surface)',
  padding: 14,
}

/**
 * Hover and focus, which inline styles cannot express.
 *
 * `.dsh-link:focus-visible` is the one that matters: global.css paints a ring
 * on `button:focus-visible` and on nothing else, so every anchor on this page —
 * and the deep links are all anchors — would otherwise be keyboard-reachable
 * and invisibly so.
 */
const SCOPED_STYLE = `
.dsh-link:hover { text-decoration: underline; }
.dsh-link:focus-visible,
.dsh-result:focus-visible,
.dsh-icon-button:focus-visible {
  outline: 2px solid var(--cyan);
  outline-offset: 2px;
  border-radius: var(--radius-sm);
}
.dsh-icon-button:hover { background: var(--surface2); color: var(--text); }
.dsh-result:hover { background: var(--surface2); }
.dsh-search:focus-within { border-color: var(--cyan); box-shadow: 0 0 0 2px var(--cyan-focus); }
`

// ── Comparison ───────────────────────────────────────────────────────────────

/**
 * The five, reduced to the axes a choice actually turns on.
 *
 * Resting height is first because it is the only cost that is paid on every
 * page view by every reader, and it is the one nobody puts in a slide.
 */
const COMPARISON: {
  id: string
  name: string
  height: string
  notifications: string
  orientation: string
  search: string
  environment: string
}[] = [
  {
    id: 'command',
    name: 'Command bar',
    height: '52px',
    notifications: 'A count, then inside the palette',
    orientation: 'None — the sidebar carries it',
    search: 'The entire header',
    environment: 'Not shown',
  },
  {
    id: 'context',
    name: 'Context bar',
    height: '72px',
    notifications: 'Scoped to the entity on screen',
    orientation: 'Breadcrumb + entity state',
    search: 'Not shown',
    environment: 'Not shown',
  },
  {
    id: 'operations',
    name: 'Operations console',
    height: '84px',
    notifications: 'Drawer, grouped, dismissable',
    orientation: 'Product / page name only',
    search: 'A control that opens one',
    environment: 'Tenant, cluster, region, data mode, superadmin',
  },
  {
    id: 'quiet',
    name: 'Quiet header',
    height: '44px',
    notifications: 'The single worst one, as a link',
    orientation: 'Page name only',
    search: 'Not shown',
    environment: 'Not shown',
  },
  {
    id: 'situation',
    name: 'Situation header',
    height: '38px at rest, 62px promoted',
    notifications: 'Nothing, until something is wrong',
    orientation: 'Page name only',
    search: 'Not shown',
    environment: 'Not shown',
  },
]

const thStyle: CSSProperties = {
  textAlign: 'left',
  fontSize: 10.5,
  fontWeight: 600,
  textTransform: 'uppercase',
  letterSpacing: '0.06em',
  color: 'var(--dim)',
  padding: '8px 10px',
  borderBottom: '1px solid var(--border-subtle)',
  whiteSpace: 'nowrap',
}

const tdStyle: CSSProperties = {
  fontSize: 11.5,
  color: 'var(--muted)',
  padding: '9px 10px',
  borderBottom: '1px solid var(--border)',
  verticalAlign: 'top',
}

// ── Page ─────────────────────────────────────────────────────────────────────

export default function DesignSystemHeadersPage() {
  // The Quiet header's empty state, which is the state it is actually being
  // judged on. Local to the page rather than to the variant so the control
  // that drives it can sit outside the frame, where a real header would never
  // put it.
  const [quietAlerts, setQuietAlerts] = useState<HeaderAlert[]>(ALERTS)

  const deepAlert = highestSeverity(ALERTS) as HeaderAlert
  const deepHref = toHref(deepAlert.target)
  const shallowHref = toHref(SHALLOW_TARGET)

  return (
    <PageTocLayout entries={DESIGN_SYSTEM_HEADER_SECTIONS}>
      <style>{SCOPED_STYLE}</style>

      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>Design System — Headers</h1>
      <p style={{ color: 'var(--muted)', fontSize: 13, marginTop: 0, marginBottom: 10, maxWidth: 860, lineHeight: 1.6 }}>
        Five candidate top bars for this product, each a different argument about what a header is for. They are
        working specimens, not pictures: hover them, tab into them, open and close them. All five are driven by the
        same six alerts, because the only useful question is how the same world looks through each.
      </p>
      <p style={{ color: 'var(--muted)', fontSize: 12.5, marginTop: 0, marginBottom: 26, maxWidth: 860, lineHeight: 1.6 }}>
        Nothing here is wired into the app. <code style={{ color: 'var(--text)' }}>components/TopNav.tsx</code> is
        untouched and stays the header this dashboard renders until one of these is chosen on purpose. Start with the
        deep-link contract below — it is the vocabulary the five variants are compared in.
      </p>

      {/* ── The deep-link contract ─────────────────────────────────────────── */}
      <Group
        id="deep-linking"
        title="The deep-link contract"
        when="Reach for this every time an alert names a specific thing — which is nearly always. An alert is a promise that something is wrong somewhere; a deep link is the difference between keeping that promise and handing the reader a search problem with a red dot on it. The three parts below each do a job the other two cannot, and the middle one is the one products drop."
      >
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 14 }}>
          <div style={{ ...cardStyle, flex: '1 1 340px' }}>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--cyan)', marginBottom: 10 }}>
              Deep — the row
            </div>
            <a
              className="dsh-link"
              href={deepHref}
              aria-label={alertLinkName(deepAlert)}
              data-testid="ds-deep-link-good"
              style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--text)', textDecoration: 'none' }}
            >
              {deepAlert.title}
            </a>
            <code data-testid="ds-deep-link-good-href" style={{ display: 'block', marginTop: 8, fontSize: 11, lineHeight: 1.5, color: 'var(--muted)', wordBreak: 'break-all' }}>
              {deepHref}
            </code>
            <dl style={{ margin: '12px 0 0', display: 'grid', gridTemplateColumns: 'auto 1fr', gap: '6px 12px', fontSize: 11.5 }}>
              <dt style={{ color: 'var(--cyan)', fontWeight: 600 }}>path</dt>
              <dd style={{ margin: 0, color: 'var(--muted)' }}>Which resource. The framework id is already substituted — never the bare list route.</dd>
              <dt style={{ color: 'var(--cyan)', fontWeight: 600 }}>query</dt>
              <dd style={{ margin: 0, color: 'var(--muted)' }}>
                What must be true for the row to be rendered at all. Drop this and the link still “works”: you land on an
                unfiltered list sorted by name, the row is on page four, and the reader is searching again.
              </dd>
              <dt style={{ color: 'var(--cyan)', fontWeight: 600 }}>anchor</dt>
              <dd style={{ margin: 0, color: 'var(--muted)' }}>
                Which row, so the page can scroll to it and highlight it — and so the URL still means something after it
                has been pasted into a ticket somebody opens next Tuesday.
              </dd>
            </dl>
          </div>

          <div style={{ ...cardStyle, flex: '1 1 340px', borderColor: 'color-mix(in srgb, var(--error) 40%, transparent)' }}>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--error)', marginBottom: 10 }}>
              Shallow — the anti-pattern
            </div>
            <a
              className="dsh-link"
              href={shallowHref}
              data-testid="ds-deep-link-bad"
              style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--text)', textDecoration: 'none' }}
            >
              3 controls are failing
            </a>
            <code data-testid="ds-deep-link-bad-href" style={{ display: 'block', marginTop: 8, fontSize: 11, lineHeight: 1.5, color: 'var(--muted)' }}>
              {shallowHref}
            </code>
            <p style={{ fontSize: 11.5, color: 'var(--muted)', lineHeight: 1.55, margin: '12px 0 0' }}>
              This is the link every product ships first. It is not broken, which is why it survives review — it
              navigates, the destination exists, the badge clears. It has simply moved the work from the system to the
              reader, and it does so once per alert, forever. The two cards are one line of markup apart.
            </p>
          </div>
        </div>

        <Caveat>
          Both links here are plain <code>&lt;a href&gt;</code> rather than router <code>&lt;Link&gt;</code>, so this
          page stays renderable with no providers. <code>toHref()</code> produces the string either consumes, which is
          why the test asserts on the string rather than on a navigation.
        </Caveat>
      </Group>

      {/* ── 1. Command bar ─────────────────────────────────────────────────── */}
      <Group
        id="command"
        title="1 · Command bar — the header is a way in"
        when="Choose this when your operators are experts who arrive knowing the noun they want — an agent name, a control id, a policy — and when the left rail already carries navigation, so a second navigation across the top is duplication rather than redundancy. It is the only one of the five that scales to a hundred destinations without growing, because it does not list them."
      >
        <CommandBarHeader />
        <NotWhen id="command">
          your users browse rather than seek, when the population is occasional or non-technical, or when someone must
          be able to see the state of the estate without performing an interaction first. A palette hides everything
          behind a keystroke; that is its efficiency and its blind spot. Note that the unread count still sits outside
          it here — a version of this that folded the count away too would fail in an operations centre by lunchtime.
        </NotWhen>
        <Caveat>
          Keyboard: tab to the input, type to filter, <kbd>↓</kbd> to move into the results, <kbd>Esc</kbd> to close.
          Results are real links and buttons rather than <code>aria-activedescendant</code> bookkeeping, so a screen
          reader meets each one as the link it is. There is no global hotkey binding on this page on purpose — five
          specimens cannot each own <kbd>/</kbd>, and it must not race KeyboardShortcutsOverlay’s window handler.
        </Caveat>
      </Group>

      {/* ── 2. Context bar ─────────────────────────────────────────────────── */}
      <Group
        id="context"
        title="2 · Context bar — the header is a place"
        when="Choose this when the recurring question is “where am I and what is this”. This app has /compliance/:frameworkId and /discovery/accounts/:accountId — three levels deep with nothing in the chrome saying so and the browser back button as the only trail. It is also the only variant whose alerts are scoped to the thing on screen, which is what makes them worth reading rather than worth dismissing."
      >
        <ContextBarHeader />
        <NotWhen id="context">
          your pages are flat — a breadcrumb of length one is noise with a chevron — or when alerts routinely originate
          somewhere other than the entity in view. Scoping is the strongest idea here and the most dangerous: it makes
          what you see relevant and it makes what you cannot see invisible, which is why the count of everything else is
          still printed beside it as a way out.
        </NotWhen>
      </Group>

      {/* ── 3. Operations console ──────────────────────────────────────────── */}
      <Group
        id="operations"
        title="3 · Operations console — the header is an instrument panel"
        when="Choose this when acting on the wrong environment is the expensive mistake, and when alert volume is past what a badge can summarise. In a regulated estate the costly error is not misreading a figure, it is suspending the right agent in the wrong cluster — and no amount of care in the page below repairs a shell that never says which cluster it is. Demo data belongs in that strip for the same reason: this product is demonstrated far more often than it is operated, and a fictional figure should say so in the chrome rather than in the presenter’s narration."
      >
        <OperationsHeader />
        <NotWhen id="operations">
          there is only one environment, in which case the strip is a constant that stops being read in a fortnight, or
          when vertical space is scarce — this is the tallest of the five at 84px before any work starts, and on a 13&quot;
          laptop that is a visible fraction of the screen paid on every page view.
        </NotWhen>
        <Caveat>
          The drawer is a drawer rather than an <code>/alerts</code> page because triage is a sequence — read, judge,
          dismiss, next. Sending someone to another route to dismiss one thing and come back is four navigations for one
          decision. Dismiss an item and the count drops; dismiss them all and the drawer states where they went.
        </Caveat>
      </Group>

      {/* ── 4. Quiet header ────────────────────────────────────────────────── */}
      <Group
        id="quiet"
        title="4 · Quiet header — the header is a label"
        when="Choose this when the page is the product and the chrome is overhead: demos, projected screens, an audience six metres from the display. Forty-four pixels, one alert, no drawer, nothing that opens. Being able to show only one alert is a constraint that forces the right one to be chosen, which is a better discipline than it sounds — and it is the cheapest of the five to build and the hardest to get wrong."
      >
        <QuietHeader alerts={quietAlerts} />
        <div style={{ marginTop: 10, display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
          <button
            type="button"
            className="btn btn-secondary"
            onClick={() => setQuietAlerts((prev) => (prev.length > 0 ? [] : ALERTS))}
            data-testid="ds-quiet-toggle"
            style={{ fontSize: 11.5, padding: '4px 10px' }}
          >
            {quietAlerts.length > 0 ? 'Clear all alerts' : 'Restore the alerts'}
          </button>
          <span style={{ fontSize: 11, color: 'var(--muted)' }}>
            The empty state is what this variant is really being judged on — it is where a demo audience spends most of
            its time, and it is the state most headers never draw.
          </span>
        </div>
        <NotWhen id="quiet">
          operators must triage several alerts without leaving the page, or when environment ambiguity exists — this
          header will not tell anyone which cluster they are in, and it has nowhere to put it.
        </NotWhen>
      </Group>

      {/* ── 5. Situation header ────────────────────────────────────────────── */}
      <Group
        id="situation"
        title="5 · Situation header — the header is an exception channel"
        when="Choose this when the normal state is “nothing to do” and the abnormal state must be impossible to miss. At rest it is thinner than any of the other four; when something breaks the same strip promotes into a banner that states what happened, which resource, since when, and offers exactly two things — go to it, or acknowledge it. A permanent instrument panel is read attentively for about a week; chrome that appears only when it has something to say is still being read in year two."
      >
        <SituationHeader />
        <NotWhen id="situation">
          something is always wrong in your estate. A banner that is always on is a permanent instrument panel with
          worse layout stability, and it teaches the same learned blindness it was built to avoid. Also avoid it where
          layout must not shift — the promotion moves the page down, and there is no honest way to make an
          impossible-to-miss banner that occupies no space.
        </NotWhen>
        <Caveat>
          The promoted banner carries <code>role=&quot;alert&quot;</code> and is the only live region this page mounts.
          It does not exist until someone presses the control, so a reader who simply opens this page meets silence —
          the correct behaviour for a gallery, and not by coincidence for the real thing. Focus follows the escalation
          to Acknowledge and returns to the trigger when the banner is dismissed.
        </Caveat>
      </Group>

      {/* ── Comparison ─────────────────────────────────────────────────────── */}
      <Group
        id="comparison"
        title="The five, on the axes a choice turns on"
        when="Read the height column first. It is the only cost paid by every reader on every page view, it is the one nobody puts in a slide, and it is very nearly the whole argument between variant 3 and variant 4."
      >
        <div style={{ ...cardStyle, padding: 0, overflowX: 'auto' }}>
          <table data-testid="ds-comparison-table" style={{ width: '100%', borderCollapse: 'collapse', minWidth: 720 }}>
            <thead>
              <tr>
                <th scope="col" style={thStyle}>Variant</th>
                <th scope="col" style={thStyle}>Resting height</th>
                <th scope="col" style={thStyle}>Notifications</th>
                <th scope="col" style={thStyle}>Orientation</th>
                <th scope="col" style={thStyle}>Search</th>
                <th scope="col" style={thStyle}>Environment</th>
              </tr>
            </thead>
            <tbody>
              {COMPARISON.map((row) => (
                <tr key={row.id} data-testid={`ds-comparison-row-${row.id}`}>
                  <th scope="row" style={{ ...tdStyle, color: 'var(--text)', fontWeight: 600, textAlign: 'left', whiteSpace: 'nowrap' }}>
                    {row.name}
                  </th>
                  <td style={tdStyle}>{row.height}</td>
                  <td style={tdStyle}>{row.notifications}</td>
                  <td style={tdStyle}>{row.orientation}</td>
                  <td style={tdStyle}>{row.search}</td>
                  <td style={tdStyle}>{row.environment}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Group>

      {/* ── Recommendation ─────────────────────────────────────────────────── */}
      <Group
        id="recommendation"
        title="The recommendation"
        when="Five neutral options is a decision deferred, not a decision supported. This section says which one and why, so that disagreeing with it is cheaper than choosing from scratch."
      >
        <div data-testid="ds-recommendation" style={{ ...cardStyle, borderColor: 'color-mix(in srgb, var(--cyan) 45%, transparent)', maxWidth: 820 }}>
          <p style={{ margin: '0 0 10px', fontSize: 13, color: 'var(--text)', lineHeight: 1.6 }}>
            <strong>Take variant 3, the Operations console, and put variant 5’s promotion behaviour into it.</strong>
          </p>
          <p style={{ margin: '0 0 10px', fontSize: 12.5, color: 'var(--muted)', lineHeight: 1.6 }}>
            The environment strip is the one thing on this page that a bank’s operator will notice is missing from every
            competitor’s screenshot. It answers “which tenant, which cluster, is this real data” without being asked, and
            in a regulated estate that is not chrome — it is the control that stops the wrong action being taken
            confidently. The drawer is the only notification pattern here that survives past three alerts, and it
            dismisses in place, which is what triage actually is.
          </p>
          <p style={{ margin: '0 0 10px', fontSize: 12.5, color: 'var(--muted)', lineHeight: 1.6 }}>
            Its real cost is height, and variant 5 is the fix: keep the 84px console, and let the top strip take over the
            full width as a severity banner when a critical alert lands, demoting on acknowledge. That buys the instrument
            panel and the exception channel for one row of chrome instead of two, and it means the loudest thing on the
            screen is the thing that is actually wrong rather than the thing that is permanently displayed.
          </p>
          <p style={{ margin: 0, fontSize: 12.5, color: 'var(--muted)', lineHeight: 1.6 }}>
            Variant 4 is the fallback and it is not a consolation prize — if the header is going to be looked at from the
            back of a room more often than it is worked in, ship the Quiet header and put the environment into the page.
            Variant 1 is right for a later product with more surface than a sidebar can list; today it solves a problem
            this app does not have yet. Variant 2 is not a header at all — it is a page-level component that several
            pages should adopt on their own, and building it into the shell would force a breadcrumb onto the flat
            top-level pages where it is noise.
          </p>
        </div>
      </Group>

      {/* ── Rules every candidate obeys ────────────────────────────────────── */}
      <Group
        id="rules"
        title="What all five obey"
        when="These are not per-variant choices, they are the floor. A candidate that broke one of them would not be a different design, it would be a worse one, so they are stated once here rather than five times above."
      >
        <ul data-testid="ds-rules-list" style={{ margin: 0, paddingLeft: 18, maxWidth: 820, fontSize: 12.5, color: 'var(--muted)', lineHeight: 1.7 }}>
          <li>
            <strong style={{ color: 'var(--text)' }}>An accessible name contains the visible label.</strong> WCAG 2.5.3,
            and in this codebase a CI stage — an <code>aria-label</code> of “Open help and support” on a button reading
            “Help &amp; Support” made the control unsayable. Every icon-only control here takes a name a person would
            plausibly speak, and every control showing a number puts that number in its name: the bell is “Notifications,
            6 unread, 2 critical”.
          </li>
          <li>
            <strong style={{ color: 'var(--text)' }}>Colour is never the only carrier.</strong> Every severity dot has
            the severity word beside it or in the name of the control it sits in. The dots clear the 3:1 non-text floor
            in all three themes; they are never asked to carry text.
          </li>
          <li>
            <strong style={{ color: 'var(--text)' }}>The unread count is not white on red.</strong>{' '}
            <code>--on-accent</code> against <code>--error</code> measures 3.62:1 under the Andy theme and the numeral is
            normal-size text, so it wants 4.5:1 — a red pill with an unreadable number on it is a decoration that looks
            like information. The urgency is carried by a red-tinted surface and a red hairline; the numeral is{' '}
            <code>--text</code>, above 10:1 in every theme.
          </li>
          <li>
            <strong style={{ color: 'var(--text)' }}>Nothing opens on hover alone.</strong> Every panel opens on click or
            on Enter, closes on Escape and on a click outside, and puts focus back where it found it.
          </li>
          <li>
            <strong style={{ color: 'var(--text)' }}>Tokens only.</strong> No bare hex anywhere in these files —
            styles/cssVarUsage.test.ts fails the build for it, and a literal colour is correct in exactly one of Dark,
            Light and Andy. Switch the theme with the toggle and every specimen above should still read.
          </li>
        </ul>
      </Group>
    </PageTocLayout>
  )
}
