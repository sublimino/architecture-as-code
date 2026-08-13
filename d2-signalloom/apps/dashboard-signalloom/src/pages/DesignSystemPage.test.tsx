import { describe, expect, it } from 'vitest'
import { fireEvent, render, screen, within } from '@testing-library/react'
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
 * Tripwire for the ButtonWait stand-in.
 *
 * DesignSystemPage renders a local `ButtonWait` because the shared component
 * lands in a parallel branch and importing something that does not exist would
 * take the whole gallery down, not just one section. The stand-in is a debt with
 * an owner, not a decision — so this asserts the debt is still outstanding, and
 * fails the moment it is not.
 *
 * A glob rather than a filesystem read: it is resolved by Vite at transform
 * time against the same module graph the page imports through, so it cannot
 * disagree with what an import would have found. `{}` means the file is absent.
 */
const BUTTON_WAIT_MODULE = import.meta.glob('../components/ButtonWait.tsx')

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
 * The roster is still seven after the ButtonWait section and the second
 * DataTable specimen, and that is not luck. ButtonWait must not own a region —
 * the button already carries the accessible name and the disabled state — and
 * DataTable never had one. If the real ButtonWait lands with a region inside it,
 * this list is where that shows up, which is the reason it is asserted by name.
 */
const EXPECTED_LIVE_REGIONS: readonly [testId: string, role: string][] = [
  ['credential-state-revoked', 'status'],
  ['ds-loadingstate-block-error', 'alert'],
  ['ds-loadingstate-block-loading', 'status'],
  ['ds-loadingstate-inline-error', 'alert'],
  ['ds-loadingstate-inline-idle', 'status'],
  ['ds-loadingstate-inline-loading', 'status'],
  ['ds-loadingstate-inline-success', 'status'],
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
    const loaderIds = [
      ...LOADER_VARIANTS.flatMap((variant) => LOADER_SIZES.map((size) => `ds-loader-${variant}-${size}`)),
      'ds-loader-default',
    ]
    expect(loaderIds).toHaveLength(9)
    for (const id of loaderIds) {
      const loader = screen.getByTestId(id)
      expect(loader).not.toHaveAttribute('role')
      expect(loader).not.toHaveAttribute('aria-live')
    }
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

  it('still needs its ButtonWait stand-in — fails the moment the real one lands', () => {
    expect(
      Object.keys(BUTTON_WAIT_MODULE),
      'src/components/ButtonWait.tsx now exists. In DesignSystemPage.tsx: uncomment the ' +
        "`import ButtonWait from '../components/ButtonWait'` line and delete the stand-in " +
        'function beneath it. The specimens do not change — the stand-in is named ButtonWait ' +
        'so the call sites are already written against the real contract. Then delete this test.',
    ).toEqual([])
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

  it('renders both DataTable examples — minimum viable and realistic', () => {
    render(<DesignSystemPage />)
    const section = screen.getByTestId('ds-section-data-table')
    const simple = within(section).getByTestId('ds-datatable-simple-example')
    const complex = within(section).getByTestId('ds-datatable-complex-example')

    expect(within(simple).getAllByRole('columnheader')).toHaveLength(4)
    expect(within(complex).getAllByRole('columnheader')).toHaveLength(7)
    expect(within(simple).getByTestId('ds-datatable-pagination')).toBeInTheDocument()
    expect(within(complex).getByTestId('ds-datatable-complex-pagination')).toBeInTheDocument()
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
