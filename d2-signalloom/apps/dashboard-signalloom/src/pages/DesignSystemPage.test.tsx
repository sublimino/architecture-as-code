import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, screen, within } from '@testing-library/react'
import DesignSystemPage from './DesignSystemPage'

// The page under test is deliberately provider-free: it imports presentational
// components only, so it must render with no router, no auth context and no API
// client. That is not a nicety — a gallery that needs a live cluster to render
// is a gallery nobody opens. The bare `render()` calls below are the assertion.

// Order matters and is asserted: Loom is the default, so it is met first. The
// page's job is to answer "what do I get if I pass nothing?" without the reader
// having to go and read PixelLoader's signature.
const LOADER_VARIANTS = ['Loom', 'Drive', 'Dots', 'Orbit'] as const
const LOADER_SIZES = ['sm', 'md'] as const

/** Every loader specimen caption on the page, in render order. */
const LOADER_CAPTION_IDS = [
  'ds-loader-caption-Loom',
  'ds-loader-caption-Drive',
  'ds-loader-caption-Dots',
  'ds-loader-caption-Orbit',
  'ds-loader-caption-default',
] as const

/**
 * The load-times specimens, in render order.
 *
 * `long` appears twice on purpose and the pair is the section's whole claim:
 * one wait that started at mount and is still inside the threshold, one handed
 * an older stamp and already past it. A single `long` specimen would be
 * indistinguishable from `all` to anyone who arrived a few seconds late, which
 * is the failure mode a gallery exists to prevent.
 */
const LOADER_TIME_KEYS = ['all', 'long-new', 'long-aged', 'none'] as const

/** Which of the four is showing an elapsed figure at first paint, and why. */
const LOADER_TIME_EXPECTATIONS: readonly [key: string, showsFigure: boolean][] = [
  ['all', true],
  ['long-new', false],
  ['long-aged', true],
  ['none', false],
]


// ── Query helpers for the complex DataTable specimen ─────────────────────────
//
// Re-queried from `screen` on every call rather than captured once: these run
// across re-renders driven by fireEvent, and a stale handle to a row that React
// has since replaced is the classic way to assert against the previous page.

const complexTable = () => screen.getByTestId('ds-datatable-complex-example')

/** A column header by its label. Headers carry a sort arrow, so exact text match will not do. */
function complexHeader(label: string): HTMLElement {
  const match = within(complexTable())
    .getAllByRole('columnheader')
    .find((th) => (th.textContent ?? '').trim().startsWith(label))
  if (!match) throw new Error(`No column header starting with "${label}"`)
  return match
}

/** The Agent cell of every row currently on screen, in display order. */
function complexAgents(): string[] {
  return within(complexTable())
    .queryAllByTestId('ds-datatable-complex-row')
    .map((row) => row.querySelector('td')?.textContent?.trim() ?? '')
}

const complexPage = () => screen.getByTestId('ds-datatable-complex-page-indicator')

// ── Query helpers for the super DataTable specimen ───────────────────────────
//
// Same re-query-every-call discipline as the complex helpers above, for the same
// reason. Scoped to the super example's own wrapper so a testid that also exists
// on the two specimens above it can never satisfy an assertion meant for this one.

const superTable = () => screen.getByTestId('ds-datatable-super-example')

function superHeader(label: string): HTMLElement {
  const match = within(superTable())
    .getAllByRole('columnheader')
    .find((th) => (th.textContent ?? '').trim().startsWith(label))
  if (!match) throw new Error(`No column header starting with "${label}"`)
  return match
}

/** The Service cell of every row currently on screen, in display order. */
function superServices(): string[] {
  return within(superTable())
    .queryAllByTestId('ds-datatable-super-row')
    .map((row) => row.querySelector('td')?.textContent?.trim() ?? '')
}

const superCount = () => screen.getByTestId('ds-datatable-super-count')
const superSearchBox = () => screen.getByTestId('ds-datatable-super-search')
const superOwnerSelect = () => screen.getByTestId('ds-datatable-super-owner')

/**
 * The live-region roster for the whole page, asserted by name rather than as a
 * ceiling.
 *
 * Every `role="status"` / `role="alert"` is something a screen reader reads out
 * when its content changes, and a component gallery is the one page in the app
 * that mounts a dozen waiting-indicators at once. Left to their defaults that is
 * a wall of simultaneous "Churning" announcements at anyone who opens it.
 *
 * Three separate facts hold the roster down to this, and each is worth failing on:
 *   - the nine gallery PixelLoaders pass `announce={false}`, so they own no
 *     region at all — that is asserted per-loader in its own test below;
 *   - exactly six LoadingState specimens are rendered, because LoadingState has
 *     no `announce` opt-out and every instance is a region by construction;
 *   - CredentialStateNotice's revoked branch is a region too, which is easy to
 *     miss because nothing in its call site says so. Naming it here is the point:
 *     it was found by this assertion failing, not by reading the component.
 *
 * Listed as name/role pairs rather than counted, so a failure says which region
 * appeared or vanished instead of just that a number moved.
 *
 * The roster was seven after the ButtonWait section and the second DataTable
 * specimen, and that was not luck. ButtonWait must not own a region — the button
 * already carries the accessible name and the disabled state — and DataTable
 * never had one. If the real ButtonWait lands with a region inside it, this list
 * is where that shows up, which is the reason it is asserted by name.
 *
 * The eighth entry is the streaming demo, and it is the one deliberate addition.
 * The tempting reading of an auto-appending console is that it needs a region
 * around the log body; that is precisely backwards, because every chunk is a
 * change and the region would read the whole run out loud line by line. So the
 * body owns nothing, and a single polite region carries the phase sentence and
 * only that. It belongs to the LIVE specimen alone: the stalled specimen below
 * it renders the same component with `announce` left at its default of false,
 * because a frozen specimen has nothing to announce, and its absence from this
 * list is the assertion that the default really is off. If a future caller adds
 * streaming to a page without thinking about it, the default keeps them at zero
 * regions and this list stays at eight.
 */
const EXPECTED_LIVE_REGIONS: readonly [testId: string, role: string][] = [
  ['credential-state-revoked', 'status'],
  ['ds-loadingstate-block-error', 'alert'],
  ['ds-loadingstate-block-loading', 'status'],
  ['ds-loadingstate-inline-error', 'alert'],
  ['ds-loadingstate-inline-idle', 'status'],
  ['ds-loadingstate-inline-loading', 'status'],
  ['ds-loadingstate-inline-success', 'status'],
  ['ds-stream-live-stream-announce', 'status'],
]

describe('DesignSystemPage', () => {
  it('renders with no router, auth or API providers', () => {
    expect(() => render(<DesignSystemPage />)).not.toThrow()
    expect(screen.getByRole('heading', { level: 1, name: /Design System/i })).toBeInTheDocument()
  })

  // ── Loaders ───────────────────────────────────────────────────────────────

  it('shows every PixelLoader variant by name, including Loom', () => {
    render(<DesignSystemPage />)
    for (const variant of LOADER_VARIANTS) {
      expect(screen.getByTestId(`ds-loader-caption-${variant}`)).toHaveTextContent(variant)
    }
  })

  it('shows every variant at both sizes', () => {
    render(<DesignSystemPage />)
    for (const variant of LOADER_VARIANTS) {
      for (const size of LOADER_SIZES) {
        expect(screen.getByTestId(`ds-loader-${variant}-${size}`)).toHaveAttribute('data-size', size)
      }
    }
  })

  it('presents Loom first and marks it as the default', () => {
    render(<DesignSystemPage />)
    const section = screen.getByTestId('ds-section-pixel-loader')

    // Order is the weakest half of the claim, so it is only half the test.
    const captions = within(section).getAllByTestId(/^ds-loader-caption-/)
    expect(captions.map((el) => el.getAttribute('data-testid'))).toEqual([...LOADER_CAPTION_IDS])

    // The badge is the other half: exactly one specimen claims to be the
    // default, and it is Loom's.
    const badges = within(section).getAllByTestId('ds-loader-default-badge')
    expect(badges).toHaveLength(1)
    expect(within(screen.getByTestId('ds-loader-caption-Loom')).getByTestId('ds-loader-default-badge')).toBe(badges[0])
  })

  it('says in prose which variant you get when you pass none', () => {
    render(<DesignSystemPage />)
    // Ordering and a badge tell a reader who is scanning. The sentence is for
    // the reader who arrived with the actual question.
    expect(screen.getByTestId('ds-when-pixel-loader')).toHaveTextContent(
      /no variant prop and you get Loom, the default/i,
    )
  })

  it('demonstrates the default with a specimen that passes no variant', () => {
    render(<DesignSystemPage />)
    // Stated, then shown. This specimen renders whatever PixelLoader's default
    // actually is, so the page cannot drift out of step with the component the
    // way the sentence above it can.
    const defaulted = screen.getByTestId('ds-loader-default')
    expect(defaulted).toBeInTheDocument()
    expect(defaulted).toHaveAttribute('data-size', 'md')
  })

  it('gives the gallery loaders no live region of their own', () => {
    render(<DesignSystemPage />)
    // Thirteen since the load-times specimens landed, and the count is stated
    // rather than derived so that adding a loader to this page is a decision
    // about live regions rather than an accident. The page-wide roster below
    // is unchanged by those four, which is the assertion that they really did
    // all pass `announce={false}`.
    const loaderIds = [
      ...LOADER_VARIANTS.flatMap((variant) => LOADER_SIZES.map((size) => `ds-loader-${variant}-${size}`)),
      'ds-loader-default',
      ...LOADER_TIME_KEYS.map((key) => `ds-loader-times-${key}`),
    ]
    expect(loaderIds).toHaveLength(13)
    for (const id of loaderIds) {
      const loader = screen.getByTestId(id)
      expect(loader).not.toHaveAttribute('role')
      expect(loader).not.toHaveAttribute('aria-live')
    }
  })

  // ── Load times ────────────────────────────────────────────────────────────
  //
  // The setting is a presence and an absence, so the section has to show it
  // rather than describe it. What is asserted here is mostly the absence side,
  // because that is the half a future edit can delete without noticing.

  describe('the load-times specimens', () => {
    it('shows all three modes side by side, long twice', () => {
      render(<DesignSystemPage />)
      const section = screen.getByTestId('ds-section-pixel-loader')
      const captions = within(section).getAllByTestId(/^ds-loader-times-caption-/)
      expect(captions.map((el) => el.getAttribute('data-testid'))).toEqual(
        LOADER_TIME_KEYS.map((key) => `ds-loader-times-caption-${key}`),
      )
    })

    it('renders each specimen in the mode it claims', () => {
      render(<DesignSystemPage />)
      for (const key of LOADER_TIME_KEYS) {
        const expected = key.startsWith('long') ? 'long' : key
        expect(screen.getByTestId(`ds-loader-times-${key}`)).toHaveAttribute(
          'data-load-times',
          expected,
        )
      }
    })

    it('shows the figure on exactly the two specimens that should have one', () => {
      // This is the demonstration. If all four looked the same the section
      // would be four copies of one screenshot with different captions.
      render(<DesignSystemPage />)
      for (const [key, showsFigure] of LOADER_TIME_EXPECTATIONS) {
        const figure = screen.queryByTestId(`ds-loader-times-${key}-elapsed`)
        if (showsFigure) expect(figure).toBeInTheDocument()
        else expect(figure).not.toBeInTheDocument()
      }
    })

    it('KEEPS THE LABEL on all four, including none', () => {
      // The rule that outranks the setting, demonstrated rather than asserted
      // in prose alone: "none" is a loader without a figure, not a loader
      // without wording.
      render(<DesignSystemPage />)
      for (const key of LOADER_TIME_KEYS) {
        expect(screen.getByTestId(`ds-loader-times-${key}-label`)).toHaveTextContent('Deploying')
      }
    })

    it('keeps the mark on the none specimen, so there is still a loader to see', () => {
      render(<DesignSystemPage />)
      expect(screen.getByTestId('ds-loader-times-none-grid')).toBeInTheDocument()
    })

    it('states the threshold and the label rule in the section prose', () => {
      render(<DesignSystemPage />)
      const blurb = screen.getByTestId('ds-loader-times-blurb')
      expect(blurb).toHaveTextContent(/2\.0 seconds/)
      expect(blurb).toHaveTextContent(/shown in every mode/i)
      expect(blurb).toHaveTextContent(/Only the figure is conditional/i)
      // And where to change it, since a setting nobody can find is decoration.
      expect(blurb).toHaveTextContent(/Settings under Display/i)
    })
  })

  // ── ButtonWait ────────────────────────────────────────────────────────────

  it('shows ButtonWait idle and waiting, side by side and the same size', () => {
    render(<DesignSystemPage />)
    const idle = screen.getByTestId('ds-buttonwait-idle')
    const waiting = screen.getByTestId('ds-buttonwait-loading')

    expect(idle).toBeEnabled()
    expect(waiting).toBeDisabled()
    expect(within(waiting).getByTestId('ds-buttonwait-indicator')).toBeInTheDocument()
    expect(within(idle).queryByTestId('ds-buttonwait-indicator')).not.toBeInTheDocument()

    // The whole point of a wait indicator sized for a control: the control does
    // not resize when the work starts, so the toolbar around it does not reflow
    // and the button does not move out from under the pointer.
    expect(idle).toHaveStyle({ minWidth: '190px' })
    expect(waiting).toHaveStyle({ minWidth: '190px' })
    expect(idle).toHaveTextContent('Rotate credential')
    expect(waiting).toHaveTextContent('Rotate credential')
  })

  it('says when ButtonWait is the right choice rather than PixelLoader or LoadingState', () => {
    render(<DesignSystemPage />)
    // The three-way distinction IS the section — a pair of screenshots with no
    // rule for choosing between them is decoration.
    const section = screen.getByTestId('ds-section-button-wait')
    expect(section).toHaveTextContent(/ButtonWait/)
    expect(section).toHaveTextContent(/PixelLoader/)
    expect(section).toHaveTextContent(/LoadingState/)
    expect(section).toHaveTextContent(/no live region/i)
  })


  it('holds the whole page to its declared live-region roster', () => {
    render(<DesignSystemPage />)
    const actual = [...document.querySelectorAll('[role="status"], [role="alert"]')]
      .map((el) => [el.getAttribute('data-testid') ?? '(no testid)', el.getAttribute('role') ?? ''])
      .sort((a, b) => a[0].localeCompare(b[0]))

    expect(actual).toEqual(EXPECTED_LIVE_REGIONS.map(([id, role]) => [id, role]))
  })

  // ── LoadingState ──────────────────────────────────────────────────────────

  it('shows LoadingState in each phase across both variants', () => {
    render(<DesignSystemPage />)
    expect(screen.getByTestId('ds-loadingstate-inline-idle')).toHaveAttribute('data-status', 'idle')
    expect(screen.getByTestId('ds-loadingstate-inline-loading')).toHaveAttribute('data-status', 'loading')
    expect(screen.getByTestId('ds-loadingstate-inline-success')).toHaveAttribute('data-status', 'success')
    expect(screen.getByTestId('ds-loadingstate-inline-error')).toHaveAttribute('data-status', 'error')
    expect(screen.getByTestId('ds-loadingstate-block-loading')).toHaveAttribute('data-status', 'loading')
    expect(screen.getByTestId('ds-loadingstate-block-error')).toHaveAttribute('data-status', 'error')
  })

  // ── ErrorState ────────────────────────────────────────────────────────────

  it('shows both ErrorState branches — retryable and 401', () => {
    render(<DesignSystemPage />)
    const retryable = screen.getByTestId('ds-errorstate-retry')
    expect(within(retryable).getByTestId('error-retry')).toHaveTextContent('Retry')
    expect(within(retryable).getByText('Failed to load')).toBeInTheDocument()

    const authFailure = screen.getByTestId('ds-errorstate-auth')
    expect(within(authFailure).getByTestId('error-login')).toHaveTextContent('Log in')
    expect(within(authFailure).getByText('Your session has expired')).toBeInTheDocument()
    // isAuthError is what drives the branch, so the 401 specimen must carry a
    // message that actually trips it — otherwise this renders the Retry state
    // and silently documents the wrong thing.
    expect(within(authFailure).queryByTestId('error-retry')).not.toBeInTheDocument()
  })

  // ── Component sections ────────────────────────────────────────────────────

  const SECTIONS = [
    'tokens',
    'pixel-loader',
    'button-wait',
    'loading-state',
    'error-state',
    'empty-state',
    'status-badge',
    'help-hint',
    'data-table',
    'donut-chart',
    'proof-console',
    'streaming-proof',
    'credential-state-notice',
    'dash-kit',
    'not-shown',
  ] as const

  it('renders every documented section with a heading and a when-to-use note', () => {
    render(<DesignSystemPage />)
    for (const id of SECTIONS) {
      const section = screen.getByTestId(`ds-section-${id}`)
      // By testid, not by role: a specimen can bring its own h2 (DashKit's
      // Section does), so `getByRole('heading')` inside a group is ambiguous.
      const heading = within(section).getByTestId(`ds-heading-${id}`)
      expect(heading.tagName).toBe('H2')
      expect(heading.textContent?.trim()).not.toBe('')
      expect(within(section).getByTestId(`ds-when-${id}`).textContent?.trim()).not.toBe('')
    }
  })

  it('renders a swatch for every theme-switched colour token', () => {
    render(<DesignSystemPage />)
    const swatches = within(screen.getByTestId('ds-section-tokens')).getAllByTestId(/^ds-token-/)
    // themes.ts CSS_VAR_NAMES is the declared set; the page must not hand-pick.
    expect(swatches.length).toBeGreaterThanOrEqual(16)
    expect(screen.getByTestId('ds-token---cyan')).toBeInTheDocument()
  })

  it('renders live specimens, not just headings', () => {
    render(<DesignSystemPage />)
    expect(screen.getByText('enterprise_admin'.replace(/_/g, ' '))).toBeInTheDocument()
    expect(screen.getByTestId('ds-datatable-pagination')).toBeInTheDocument()
    expect(screen.getByTestId('ds-proof-console')).toBeInTheDocument()
    expect(screen.getByTestId('credential-state-revoked')).toBeInTheDocument()
    expect(screen.getByText(/No agents match this filter/i)).toBeInTheDocument()
  })

  // ── DataTable: the pair ───────────────────────────────────────────────────
  //
  // Two specimens, and the contrast is the content: four columns and a page
  // control against seven columns, sorting, a small page size and page-owned
  // search. Both are asserted, because a page that quietly loses the simple one
  // has lost the comparison that made either of them worth reading.

  it('renders all three DataTable examples — minimum viable, realistic and super', () => {
    render(<DesignSystemPage />)
    const section = screen.getByTestId('ds-section-data-table')
    const simple = within(section).getByTestId('ds-datatable-simple-example')
    const complex = within(section).getByTestId('ds-datatable-complex-example')
    const superEx = within(section).getByTestId('ds-datatable-super-example')

    expect(within(simple).getAllByRole('columnheader')).toHaveLength(4)
    expect(within(complex).getAllByRole('columnheader')).toHaveLength(7)
    expect(within(superEx).getAllByRole('columnheader')).toHaveLength(6)
    expect(within(simple).getByTestId('ds-datatable-pagination')).toBeInTheDocument()
    expect(within(complex).getByTestId('ds-datatable-complex-pagination')).toBeInTheDocument()
    expect(within(superEx).getByTestId('ds-datatable-super-pagination')).toBeInTheDocument()
  })

  it('reads as a progression — three headings, each stating when to reach for it', () => {
    render(<DesignSystemPage />)
    const section = screen.getByTestId('ds-section-data-table')
    // By testid, so a copy edit to any of the three titles does not break this.
    // The ORDER is the assertion: a reader scanning down has to meet the minimum
    // before the realistic and the realistic before the super, or the section
    // stops being a progression and becomes three unrelated tables.
    const headings = within(section)
      .getAllByTestId(/^ds-example-heading-datatable-/)
      .map((h) => h.getAttribute('data-testid'))
    expect(headings).toEqual([
      'ds-example-heading-datatable-simple',
      'ds-example-heading-datatable-complex',
      'ds-example-heading-datatable-super',
    ])
  })

  it('puts StatusBadge in the complex example’s cells', () => {
    render(<DesignSystemPage />)
    const firstRow = within(complexTable()).getAllByTestId('ds-datatable-complex-row')[0]
    // Lifecycle state and a pass/fail on the posture number — two badges, two
    // different variants, which is the reason a cell renderer exists at all.
    expect(firstRow.querySelectorAll('.tag')).toHaveLength(2)
    expect(firstRow).toHaveTextContent('active')
    expect(firstRow).toHaveTextContent('71%')
    expect(firstRow).toHaveTextContent('pass')
  })

  it('paginates the complex example — five rows a page, three pages', () => {
    render(<DesignSystemPage />)
    expect(complexAgents()).toHaveLength(5)
    expect(complexPage()).toHaveTextContent('Page 1 of 3')
    expect(screen.getByTestId('ds-datatable-complex-prev')).toBeDisabled()

    fireEvent.click(screen.getByTestId('ds-datatable-complex-next'))
    expect(complexPage()).toHaveTextContent('Page 2 of 3')
    expect(complexAgents()).toHaveLength(5)

    fireEvent.click(screen.getByTestId('ds-datatable-complex-next'))
    expect(complexPage()).toHaveTextContent('Page 3 of 3')
    // 14 rows, so the last page is a short one — the arithmetic is the part
    // worth checking, not that a button exists.
    expect(complexAgents()).toHaveLength(4)
    expect(screen.getByTestId('ds-datatable-complex-next')).toBeDisabled()
  })

  it('sorts the complex example by a clicked header, both directions', () => {
    render(<DesignSystemPage />)
    // Unsorted is declaration order, which is deliberately neither alphabetical
    // nor numeric — otherwise a broken sort would still look right.
    expect(complexAgents()[0]).toBe('policy-evaluator')

    fireEvent.click(complexHeader('Agent'))
    expect(complexAgents()[0]).toBe('attestation-signer')
    expect(complexHeader('Agent')).toHaveAttribute('aria-sort', 'ascending')

    fireEvent.click(complexHeader('Agent'))
    expect(complexAgents()[0]).toBe('trace-sampler')
    expect(complexHeader('Agent')).toHaveAttribute('aria-sort', 'descending')

    // A numeric column, because string and number take different branches in
    // DataTable's comparator and only one of them is exercised above.
    fireEvent.click(complexHeader('Open findings'))
    fireEvent.click(complexHeader('Open findings'))
    expect(complexHeader('Open findings')).toHaveAttribute('aria-sort', 'descending')
    expect(complexAgents()[0]).toBe('sbom-collector')
    // Switching columns drops the previous sort rather than stacking on it.
    expect(complexHeader('Agent')).not.toHaveAttribute('aria-sort')
  })

  it('filters the complex example from the search box the page owns', () => {
    render(<DesignSystemPage />)
    fireEvent.change(screen.getByTestId('ds-datatable-complex-search'), { target: { value: 'identity' } })

    expect(screen.getByTestId('ds-datatable-complex-count')).toHaveTextContent('3 of 14 shown')
    expect([...complexAgents()].sort()).toEqual(['cert-renewer', 'credential-rotator', 'secret-syncer'])
    // Three rows fit one page, so the pager removes itself — hidePaginationWhenSinglePage.
    expect(screen.queryByTestId('ds-datatable-complex-pagination')).not.toBeInTheDocument()
  })

  it('returns to page 1 when a lifecycle filter shrinks the data underneath', () => {
    render(<DesignSystemPage />)
    fireEvent.click(screen.getByTestId('ds-datatable-complex-next'))
    expect(complexPage()).toHaveTextContent('Page 2 of 3')

    fireEvent.click(screen.getByTestId('ds-datatable-complex-filter-active'))
    // Nine active rows over two pages, and crucially back on the first of them.
    // Staying on page 2 here is the bug this behaviour exists to prevent: a
    // filter that lands you on an empty table.
    expect(complexPage()).toHaveTextContent('Page 1 of 2')
    expect(complexAgents()).toHaveLength(5)
    expect(screen.getByTestId('ds-datatable-complex-filter-active')).toHaveAttribute('aria-pressed', 'true')
  })

  it('shows an empty state rather than an empty table when nothing matches', () => {
    render(<DesignSystemPage />)
    fireEvent.change(screen.getByTestId('ds-datatable-complex-search'), { target: { value: 'no-such-agent' } })

    expect(screen.getByTestId('ds-datatable-complex-count')).toHaveTextContent('0 of 14 shown')
    expect(within(complexTable()).getByText(/Nothing matches that search/i)).toBeInTheDocument()
    expect(within(complexTable()).queryAllByTestId('ds-datatable-complex-row')).toHaveLength(0)
  })

  // ── DataTable: the toolbar slot and the empty branch ──────────────────────
  //
  // The claim these two make is the reason the advanced form is one component
  // with optional props rather than a second component. Everything else about
  // the pair is asserted above and did not change.

  it('renders the complex example’s filter controls inside DataTable’s toolbar slot', () => {
    render(<DesignSystemPage />)
    const toolbar = within(complexTable()).getByTestId('ds-datatable-complex-toolbar')
    // Not a cosmetic detail: the search box being INSIDE the component is what
    // makes the next assertion structurally true rather than a thing the page
    // has to remember.
    expect(within(toolbar).getByTestId('ds-datatable-complex-search')).toBeInTheDocument()
    expect(within(toolbar).getByTestId('ds-datatable-complex-filter-active')).toBeInTheDocument()
    expect(within(toolbar).getByTestId('ds-datatable-complex-count')).toBeInTheDocument()
  })

  it('keeps the filter controls on screen when a filter matches nothing', () => {
    render(<DesignSystemPage />)
    const search = screen.getByTestId('ds-datatable-complex-search')
    fireEvent.change(search, { target: { value: 'no-such-agent' } })

    // The bug this prop exists to make impossible: a hand-rolled
    // `rows.length ? table : empty` ternary takes the search box down with the
    // table, and the user has no way to undo the filter that emptied it.
    expect(screen.getByTestId('ds-datatable-complex-toolbar')).toBeInTheDocument()
    expect(screen.getByTestId('ds-datatable-complex-empty')).toBeInTheDocument()
    expect(search).toBeInTheDocument()

    // And it is genuinely usable, not merely present.
    fireEvent.change(search, { target: { value: '' } })
    expect(screen.queryByTestId('ds-datatable-complex-empty')).not.toBeInTheDocument()
    expect(complexAgents()).toHaveLength(5)
  })

  // ── DataTable: the super specimen ─────────────────────────────────────────
  //
  // What this one has to prove that the realistic specimen above does not is
  // COMPOSITION: two independent facets narrowing the same array, a count that
  // stays a count of the whole table while they do, and two ways back out of the
  // state where they compose to nothing. Everything asserted below is a claim the
  // section's prose makes; a specimen whose prose outruns its behaviour is worse
  // than no specimen, because the reader copies it.

  it('paginates the super specimen — seven rows a page, three pages, short last one', () => {
    render(<DesignSystemPage />)
    expect(superServices()).toHaveLength(7)
    expect(screen.getByTestId('ds-datatable-super-page-indicator')).toHaveTextContent('Page 1 of 3')

    fireEvent.click(screen.getByTestId('ds-datatable-super-next'))
    expect(superServices()).toHaveLength(7)
    fireEvent.click(screen.getByTestId('ds-datatable-super-next'))
    // 18 over 7 leaves 4 — the arithmetic, not the existence of a button.
    expect(superServices()).toHaveLength(4)
    expect(screen.getByTestId('ds-datatable-super-next')).toBeDisabled()
  })

  it('sorts the super specimen by a clicked header, both directions and both types', () => {
    render(<DesignSystemPage />)
    expect(superServices()[0]).toBe('policy-evaluator')

    fireEvent.click(superHeader('Service'))
    expect(superServices()[0]).toBe('attestation-signer')
    expect(superHeader('Service')).toHaveAttribute('aria-sort', 'ascending')

    fireEvent.click(superHeader('Service'))
    expect(superServices()[0]).toBe('trace-sampler')
    expect(superHeader('Service')).toHaveAttribute('aria-sort', 'descending')

    // Numeric column: a different branch of DataTable's comparator.
    fireEvent.click(superHeader('Open findings'))
    fireEvent.click(superHeader('Open findings'))
    expect(superServices()[0]).toBe('sbom-collector')
    expect(superHeader('Service')).not.toHaveAttribute('aria-sort')
  })

  it('narrows the super specimen from the search box', () => {
    render(<DesignSystemPage />)
    expect(superCount()).toHaveTextContent('18 of 18 shown')

    fireEvent.change(superSearchBox(), { target: { value: 'spire' } })
    expect(superCount()).toHaveTextContent('2 of 18 shown')
    expect([...superServices()].sort()).toEqual(['cert-renewer', 'credential-rotator'])
  })

  it('narrows the super specimen from a source chip, and says which is pressed', () => {
    render(<DesignSystemPage />)
    fireEvent.click(screen.getByTestId('ds-datatable-super-filter-demo'))

    expect(superCount()).toHaveTextContent('4 of 18 shown')
    expect(screen.getByTestId('ds-datatable-super-filter-demo')).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByTestId('ds-datatable-super-filter-all')).toHaveAttribute('aria-pressed', 'false')
  })

  it('narrows the super specimen from the owner select', () => {
    render(<DesignSystemPage />)
    fireEvent.change(superOwnerSelect(), { target: { value: 'identity' } })

    expect(superCount()).toHaveTextContent('4 of 18 shown')
    expect([...superServices()].sort()).toEqual([
      'bao-unsealer', 'cert-renewer', 'credential-rotator', 'secret-syncer',
    ])
  })

  it('composes the two facets with AND, and keeps counting the whole table while it does', () => {
    render(<DesignSystemPage />)
    fireEvent.click(screen.getByTestId('ds-datatable-super-filter-config'))
    expect(superCount()).toHaveTextContent('6 of 18 shown')

    fireEvent.change(superOwnerSelect(), { target: { value: 'identity' } })
    // Six are config and four are identity; exactly one is both. An OR would
    // report nine here, which is the bug this assertion exists for.
    expect(superCount()).toHaveTextContent('1 of 18 shown')
    expect(superServices()).toEqual(['credential-rotator'])

    // And the facet counts did NOT move with the result. A chip reporting the
    // filtered set reads 0 for every option not selected and stops being a way
    // back to the rows it is hiding.
    expect(screen.getByTestId('ds-datatable-super-filter-live')).toHaveTextContent('8')
    expect(screen.getByTestId('ds-datatable-super-filter-demo')).toHaveTextContent('4')
  })

  it('shows Clear filters only while something is narrowing the super specimen', () => {
    render(<DesignSystemPage />)
    // Conditioned on the OTHER controls, never on its own value and never on the
    // row count — so using it cannot put the user in a state it has left.
    expect(screen.queryByTestId('ds-datatable-super-clear')).not.toBeInTheDocument()

    fireEvent.change(superSearchBox(), { target: { value: 'mesh' } })
    expect(superCount()).toHaveTextContent('4 of 18 shown')
    fireEvent.click(screen.getByTestId('ds-datatable-super-clear'))

    expect(superCount()).toHaveTextContent('18 of 18 shown')
    expect(superSearchBox()).toHaveValue('')
    expect(screen.queryByTestId('ds-datatable-super-clear')).not.toBeInTheDocument()
  })

  it('resets every control at once, not just the one last touched', () => {
    render(<DesignSystemPage />)
    fireEvent.change(superSearchBox(), { target: { value: 'mesh' } })
    fireEvent.click(screen.getByTestId('ds-datatable-super-filter-live'))
    fireEvent.change(superOwnerSelect(), { target: { value: 'network' } })

    fireEvent.click(screen.getByTestId('ds-datatable-super-clear'))
    expect(superSearchBox()).toHaveValue('')
    expect(superOwnerSelect()).toHaveValue('all')
    expect(screen.getByTestId('ds-datatable-super-filter-all')).toHaveAttribute('aria-pressed', 'true')
    expect(superCount()).toHaveTextContent('18 of 18 shown')
  })

  it('reaches the empty state by composing two facets that are each non-empty', () => {
    render(<DesignSystemPage />)
    // Four rows are `demo` and six are `platform-eng`; none is both. Neither
    // facet is empty on its own, which is the case a single-facet specimen
    // cannot pose and the reason this one carries two.
    fireEvent.click(screen.getByTestId('ds-datatable-super-filter-demo'))
    fireEvent.change(superOwnerSelect(), { target: { value: 'platform-eng' } })

    expect(superCount()).toHaveTextContent('0 of 18 shown')
    expect(within(superTable()).getByTestId('ds-datatable-super-filtered-empty')).toBeInTheDocument()
    expect(superServices()).toHaveLength(0)
    // Nothing over the empty panel: no pager, no rows-per-page control.
    expect(within(superTable()).queryByTestId('ds-datatable-super-footer')).not.toBeInTheDocument()
  })

  it('keeps the whole strip alive on the empty branch, and clears from inside the panel', () => {
    render(<DesignSystemPage />)
    fireEvent.change(superSearchBox(), { target: { value: 'no-such-service' } })

    // Every control survives, because DataTable renders the toolbar outside the
    // empty ternary. The in-panel button is not redundancy: it is the way back
    // from where the mistake is visible.
    const toolbar = within(superTable()).getByTestId('ds-datatable-super-toolbar')
    expect(within(toolbar).getByTestId('ds-datatable-super-search')).toBeInTheDocument()
    expect(within(toolbar).getByTestId('ds-datatable-super-filter-live')).toBeInTheDocument()
    expect(within(toolbar).getByTestId('ds-datatable-super-owner')).toBeInTheDocument()
    expect(within(toolbar).getByTestId('ds-datatable-super-clear')).toBeInTheDocument()

    fireEvent.click(screen.getByTestId('ds-datatable-super-empty-clear'))
    expect(screen.queryByTestId('ds-datatable-super-filtered-empty')).not.toBeInTheDocument()
    expect(superServices()).toHaveLength(7)
    expect(superCount()).toHaveTextContent('18 of 18 shown')
  })

  it('returns to page 1 when a super facet shrinks the data underneath', () => {
    render(<DesignSystemPage />)
    fireEvent.click(screen.getByTestId('ds-datatable-super-next'))
    expect(screen.getByTestId('ds-datatable-super-page-indicator')).toHaveTextContent('Page 2 of 3')

    fireEvent.click(screen.getByTestId('ds-datatable-super-filter-live'))
    // Eight live rows over two pages, and on the first of them. Staying on page
    // 2 is the bug DataTable's usePrevious guard exists to prevent.
    expect(screen.getByTestId('ds-datatable-super-page-indicator')).toHaveTextContent('Page 1 of 2')
    expect(superServices()).toHaveLength(7)
  })

  it('names the super strip and its facet group, and keeps every label inside its accessible name', () => {
    render(<DesignSystemPage />)
    const toolbar = within(superTable()).getByTestId('ds-datatable-super-toolbar')

    // The strip is a named group, and the chip vocabulary is a named group
    // WITHIN it — otherwise a screen reader announces two facets as one list.
    expect(within(toolbar).getByRole('group', { name: /filter the super datatable example/i })).toBeInTheDocument()
    expect(within(toolbar).getByRole('group', { name: /filter by source/i })).toBeInTheDocument()

    // WCAG 2.5.3: an explicit aria-label REPLACES the wrapping label's text, so
    // it must contain the visible word or a speech-input user saying "Owner"
    // reaches nothing.
    const owner = superOwnerSelect()
    expect(owner.getAttribute('aria-label')?.toLowerCase()).toContain('owner')
    expect(within(toolbar).getByLabelText(/by owner/i)).toBe(owner)
  })

  it('badges the super specimen’s Source cell with a variant that actually has a map', () => {
    render(<DesignSystemPage />)
    const firstRow = within(superTable()).getAllByTestId('ds-datatable-super-row')[0]
    // One badge, and it renders the provenance word rather than falling through
    // StatusBadge's maps to a neutral grey that carries no distinction at all.
    expect(firstRow.querySelectorAll('.tag')).toHaveLength(1)
    expect(firstRow).toHaveTextContent('live')
  })

  // ── ProofConsole streaming demo ───────────────────────────────────────────
  //
  // Fake timers throughout, and started before render so the fixture poller's
  // interval is captured rather than half of it running for real. The point of
  // the section is that output ARRIVES over time, so a test that only checks
  // the finished state would pass against a component that dumped the whole
  // fixture on mount — which is the exact thing the section must not do, since
  // it would show a cadence no real implementation has.

  /**
   * The streamed output only.
   *
   * Not the panel: the panel also holds the command (which contains the string
   * "step 6", so an assertion against it silently passes before a single byte
   * has arrived) and the status row (whose PixelLoader rewrites an elapsed
   * figure ten times a second, so nothing about the panel's text is stable).
   */
  const liveDetail = () => screen.getByTestId('ds-stream-live-detail')
  /** Advance by whole poll intervals, inside act so React flushes each one. */
  const polls = (n: number) => act(() => { vi.advanceTimersByTime(350 * n) })

  describe('streaming demo', () => {
    beforeEach(() => { vi.useFakeTimers() })
    afterEach(() => { vi.useRealTimers() })

    it('says on screen that it is simulated and that no backend endpoint exists', () => {
      render(<DesignSystemPage />)
      const disclaimer = screen.getByTestId('ds-stream-disclaimer')
      // Three separate claims, because a reader deciding whether to build this
      // needs all three: that it is fake, that the capability is absent, and
      // what the real path would actually be.
      expect(disclaimer).toHaveTextContent(/simulated/i)
      expect(disclaimer).toHaveTextContent(/no streaming endpoint in this backend/i)
      expect(disclaimer).toHaveTextContent(/offset polling/i)
      expect(disclaimer).toHaveTextContent(/fetchDemoRunLog\(runId, offset\)/)
    })

    it('fills the console chunk by chunk rather than all at once', () => {
      render(<DesignSystemPage />)
      // Nothing has been polled yet, so the body is empty. Critically it does
      // NOT say "(no output)" — that is a verdict, and no verdict is available
      // while a stream is still open.
      expect(liveDetail().textContent).toBe('')
      expect(screen.getByTestId('ds-stream-live-panel')).not.toHaveTextContent('(no output)')

      polls(1)
      const afterOne = liveDetail().textContent ?? ''
      expect(afterOne).toContain('[evidence] step 6')
      expect(afterOne).not.toContain('blast radius contained')

      polls(2)
      const afterThree = liveDetail().textContent ?? ''
      // Strictly longer, and the earlier text is still a prefix of it: chunks
      // append at their offset, they do not replace or reorder what landed.
      expect(afterThree.length).toBeGreaterThan(afterOne.length)
      expect(afterThree.startsWith(afterOne)).toBe(true)
      expect(afterThree).not.toContain('blast radius contained')
    })

    it('shows the house wait treatment while the stream is open, and only then', () => {
      render(<DesignSystemPage />)
      polls(1)
      expect(screen.getByTestId('ds-stream-live-stream')).toHaveAttribute('data-stream', 'streaming')
      expect(screen.getByTestId('ds-stream-live-stream-wait')).toBeInTheDocument()
      // The wait inside the control the user pressed is ButtonWait's job, and
      // the control is disabled so a second run cannot be started mid-run.
      expect(screen.getByTestId('ds-stream-replay')).toBeDisabled()
      expect(screen.getByTestId('ds-stream-replay-wait')).toBeInTheDocument()

      polls(40)
      expect(screen.queryByTestId('ds-stream-live-stream-wait')).not.toBeInTheDocument()
      expect(screen.queryByTestId('ds-stream-replay-wait')).not.toBeInTheDocument()
    })

    it('reaches a completed state holding the whole fixture', () => {
      render(<DesignSystemPage />)
      polls(40)

      expect(screen.getByTestId('ds-stream-live-stream')).toHaveAttribute('data-stream', 'complete')
      expect(screen.getByTestId('ds-stream-live-stream')).toHaveTextContent('Complete')
      expect(screen.getByTestId('ds-stream-phase')).toHaveTextContent('complete')
      // Both ends of the fixture, so "complete" means the whole thing arrived
      // rather than the poller having given up somewhere in the middle.
      expect(liveDetail()).toHaveTextContent('[evidence] step 6')
      expect(liveDetail()).toHaveTextContent('3 of 3 platform responses verified')
    })

    it('stops polling once the stream is complete', () => {
      render(<DesignSystemPage />)
      polls(40)
      const settled = liveDetail().textContent

      // A poller that keeps firing past eof re-appends the tail forever, which
      // looks fine on a short fixture and is a leak on a long one.
      polls(40)
      expect(liveDetail().textContent).toBe(settled)
    })

    it('replays from an empty console instead of appending to the finished one', () => {
      render(<DesignSystemPage />)
      polls(40)
      const finished = liveDetail().textContent ?? ''

      fireEvent.click(screen.getByTestId('ds-stream-replay'))
      expect(screen.getByTestId('ds-stream-live-stream')).toHaveAttribute('data-stream', 'streaming')
      expect(liveDetail().textContent).toBe('')

      polls(40)
      // Same output, not twice the output.
      expect(liveDetail().textContent).toBe(finished)
    })

    it('renders the stalled state with a reason, not just a stream that stopped moving', () => {
      render(<DesignSystemPage />)
      const stalled = screen.getByTestId('ds-stream-stalled-stream')
      expect(stalled).toHaveAttribute('data-stream', 'stalled')
      // The word, not the colour. A red dot is invisible to a good fraction of
      // any room and to every printout.
      expect(stalled).toHaveTextContent('Stopped')
      expect(screen.getByTestId('ds-stream-stalled-stream-note')).toHaveTextContent(/No output for 45s/)
      // Partial output is still shown: it is real, it is just not all of it.
      expect(screen.getByTestId('ds-stream-stalled-detail')).toHaveTextContent('[evidence] step 6')
      expect(screen.getByTestId('ds-stream-stalled-detail')).not.toHaveTextContent('3 of 3 platform responses')
    })

    it('never puts the appending log body inside a live region', () => {
      render(<DesignSystemPage />)
      polls(3)
      // The whole a11y argument in one assertion: the thing that changes on
      // every chunk must not be announced, or a screen reader reads the run
      // out loud line by line over whatever the user was doing.
      const body = liveDetail()
      expect(body.textContent).not.toBe('')
      expect(body).not.toHaveAttribute('role')
      expect(body).not.toHaveAttribute('aria-live')
      expect(body.closest('[aria-live]')).toBeNull()
      expect(screen.getByTestId('ds-stream-live-panel').querySelector('[aria-live]')).toBeNull()
      expect(screen.getByTestId('ds-stream-live-stream')).not.toHaveAttribute('aria-live')
    })

    it('announces the phase from a region that existed before the phase changed', () => {
      render(<DesignSystemPage />)
      // Present at the first render, not created on completion: a live region
      // born at the same instant as its content is announced unreliably or not
      // at all. This is the assertion that keeps it mounted.
      const region = screen.getByTestId('ds-stream-live-stream-announce')
      expect(region).toHaveAttribute('role', 'status')
      expect(region).toHaveAttribute('aria-live', 'polite')
      expect(region).toHaveTextContent(/output is still arriving/i)

      polls(40)
      expect(screen.getByTestId('ds-stream-live-stream-announce')).toBe(region)
      expect(region).toHaveTextContent(/proof complete/i)
    })

    it('leaves the stalled specimen with no region of its own', () => {
      render(<DesignSystemPage />)
      // `announce` defaults to false, and this is what that default buys: a
      // caller who adds streaming without thinking about accessibility adds no
      // regions at all rather than adding a bad one.
      expect(screen.queryByTestId('ds-stream-stalled-stream-announce')).not.toBeInTheDocument()
    })
  })

  // ── Coverage ledger ───────────────────────────────────────────────────────

  it('lists the components it could not show, each with a reason', () => {
    render(<DesignSystemPage />)
    const ledger = screen.getByTestId('ds-section-not-shown')
    const rows = within(ledger).getAllByTestId(/^ds-skipped-/)
    expect(rows.length).toBeGreaterThanOrEqual(8)
    for (const row of rows) {
      // A name with no reason beside it is the failure mode this page exists to
      // avoid — an omission that looks like an oversight.
      expect(row.textContent?.trim().length ?? 0).toBeGreaterThan(20)
    }
    expect(within(ledger).getByTestId('ds-skipped-Sidebar')).toBeInTheDocument()
  })
})
