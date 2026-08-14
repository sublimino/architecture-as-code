import { describe, it, expect } from 'vitest'
import { render, screen, within, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import FederatedServicesPage from './FederatedServicesPage'

function renderPage() {
  return render(
    <MemoryRouter>
      <FederatedServicesPage />
    </MemoryRouter>,
  )
}

/**
 * Assertions scoped to one `<Section>`, so six tables cannot answer for each
 * other.
 *
 * `level: 2` is load-bearing, not tidiness. One section on this page is called
 * "Federated Services" and so is the page — an unqualified name matches the h1
 * as well and throws "found multiple elements". Section headings are h2 and the
 * page title is the only h1, so the level disambiguates without hard-coding
 * which of the six is the awkward one.
 */
function sectionFor(headingName: string) {
  const heading = screen.getByRole('heading', { level: 2, name: headingName })
  const section = heading.closest('section')
  if (!section) throw new Error(`no <section> ancestor for heading "${headingName}"`)
  return within(section)
}

describe('FederatedServicesPage', () => {
  it('renders the Federated Services heading', () => {
    renderPage()
    expect(screen.getByRole('heading', { level: 1, name: 'Federated Services' })).toBeInTheDocument()
  })

  it('renders the Cofide-inspired sections', () => {
    renderPage()
    expect(screen.getByRole('heading', { name: 'Trust Zones' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Federations' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { level: 2, name: 'Federated Services' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Attestation Policies' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Cofide Go SDK' })).toBeInTheDocument()
  })

  it('renders concrete mock data — a federated service and the Go SDK import', () => {
    renderPage()
    expect(screen.getAllByText('payments-api').length).toBeGreaterThanOrEqual(1)
    expect(screen.getByText(/cofide-sdk-go\/cofide/)).toBeInTheDocument()
  })

  it('renders the SPIFFE Identities section with real trust domain URIs', () => {
    renderPage()
    expect(screen.getByRole('heading', { name: 'SPIFFE Identities' })).toBeInTheDocument()
    expect(screen.getByText(/spiffe:\/\/signalloom\.demo\/ns\/fe-signalloom\/sa\/fe-signalloom/)).toBeInTheDocument()
    expect(screen.getByText(/spiffe:\/\/acme\.partner\.example\/ns\/kyc\/sa\/kyc-lookup/)).toBeInTheDocument()
  })

  it('renders the Federation Events section with activity log', () => {
    renderPage()
    expect(screen.getByRole('heading', { name: 'Federation Events' })).toBeInTheDocument()
    expect(screen.getByText(/Bundle refreshed/)).toBeInTheDocument()
    expect(screen.getByText(/Awaiting signalloom-us bundle acceptance/)).toBeInTheDocument()
  })

  // This page makes the strongest claims of the three superadmin surfaces and
  // has no data path whatsoever. Read next to Credential Inventory's live view
  // it is indistinguishable from one, so the disclosure is what keeps a fixture
  // from being taken for a measurement.
  describe('says out loud that none of it was measured', () => {
    it('leads with a provenance banner rather than presenting fixtures as fact', () => {
      renderPage()
      const banner = screen.getByTestId('federated-source')
      expect(banner).toHaveTextContent(/illustrative/i)
      expect(banner).toHaveTextContent(/no trust zone, federation or SVID below was observed/i)
    })

    it('keeps the proof closed until asked, then names the file the data comes from', async () => {
      const user = userEvent.setup()
      renderPage()
      expect(screen.queryByTestId('federated-proof-console')).toBeNull()

      await user.click(screen.getByTestId('federated-disclose-proof'))
      const panel = screen.getByTestId('federated-proof-console-panel')
      expect(panel).toHaveTextContent('FederatedServicesPage.tsx')
      expect(panel).toHaveTextContent('issues no fetch')
    })

    it('names the commands that would make it real, marked as never run', async () => {
      const user = userEvent.setup()
      renderPage()
      await user.click(screen.getByTestId('federated-disclose-proof'))
      await user.click(screen.getByTestId('federated-proof-console-tab-1'))

      const panel = screen.getByTestId('federated-proof-console-panel')
      expect(panel).toHaveTextContent('spire-server bundle list')
      expect(panel).toHaveTextContent('NOT RUN')
    })
  })

  describe('shared components', () => {
    it('renders statuses through StatusBadge with a fill that actually parses', () => {
      renderPage()
      // DashKit's Pill built its background as `hex(colors.tealLoom, 0.12)`,
      // and that token is the string `var(--teal)` — so every pill on this page
      // was emitting `var(--teal)1f` and rendering with no fill at all.
      const badge = screen.getAllByText('federated', { selector: '.tag' })[0]
      expect(badge.style.background).toContain('color-mix')
      expect(badge.style.color).toBe('var(--teal)')

      const connecting = screen.getAllByText('connecting', { selector: '.tag' })[0]
      expect(connecting.style.color).toBe('var(--cyan)')
    })
  })

  // ── Design-system migration ─────────────────────────────────────────────────
  //
  // Every table on this page is now a DataTable with a `toolbar` and an
  // `emptyState`, the shape the Design System page calls "Realistic". The suite
  // below is table-driven for the same reason CryptographyPage's is: the point
  // of the migration is that all six behave IDENTICALLY, and six hand-written
  // near-copies would let one of them drift without failing anything. A table
  // that forgets its toolbar, its count, its empty state or its undo fails here
  // by construction.

  interface TableSpec {
    heading: string
    prefix: string
    total: number
    /** A search that matches exactly one row, and the text proving which. */
    search: { query: string; rows: number; proof: string }
    /** A filter chip that narrows, and how many rows survive it. */
    chip: { name: string; rows: number }
    /** Accessible names of every HelpHint this table's headers carry. */
    hints: string[]
  }

  const TABLES: TableSpec[] = [
    {
      heading: 'Trust Zones',
      prefix: 'fed-zones',
      total: 3,
      search: { query: 'acme.partner', rows: 1, proof: 'partner-acme' },
      // No zone is connecting today, so this is the chip that reaches the empty
      // state through a real control rather than through a nonsense search —
      // which is why the vocabulary is declared rather than derived from rows.
      chip: { name: 'connecting', rows: 0 },
      hints: ['What Trust domain means', 'What SPIRE servers means'],
    },
    {
      heading: 'Federations',
      prefix: 'fed-federations',
      total: 3,
      search: { query: 'one-way', rows: 1, proof: 'one-way (eu → acme)' },
      chip: { name: 'connecting', rows: 1 },
      hints: ['What Mode means', 'What Attestation policy means', 'What Status means'],
    },
    {
      heading: 'Federated Services',
      prefix: 'fed-services',
      total: 4,
      search: { query: 'settle.local', rows: 1, proof: 'settlement-feed' },
      chip: { name: 'signalloom-eu', rows: 2 },
      hints: ['What Local endpoint means', 'What Transport means'],
    },
    {
      heading: 'Attestation Policies',
      prefix: 'fed-policies',
      total: 3,
      search: { query: 'tpm:ek', rows: 1, proof: 'ap-node-tpm' },
      // The one many-valued axis: `ap-partner-read` binds eu AND acme, so it is
      // the single row this chip keeps while `eu` keeps all three.
      chip: { name: 'acme', rows: 1 },
      hints: ['What Selector means'],
    },
    {
      heading: 'SPIFFE Identities',
      prefix: 'fed-spiffe',
      total: 5,
      search: { query: 'cardvault', rows: 1, proof: 'cardvault-agent' },
      chip: { name: 'service', rows: 3 },
      hints: ['What SPIFFE ID means', 'What SVID type means'],
    },
    {
      heading: 'Federation Events',
      prefix: 'fed-events',
      total: 5,
      search: { query: 'Attestation passed', rows: 1, proof: 'Attestation passed' },
      chip: { name: 'partner-acme', rows: 1 },
      // Empty on purpose. "Timestamp", "Zone", "Event" and "Detail" mean what
      // they say, and a "?" that restates its header is what stops the other ten
      // being read. A convention with no floor is decoration.
      hints: [],
    },
  ]

  /** Body rows currently rendered by a table, excluding its header row. */
  function bodyRowCount(prefix: string): number {
    // The toolbar and the table are siblings under DataTable's root, so the
    // toolbar's own test id is the stable way to reach the table it belongs to
    // — and it keeps working on the empty branch, where there is no table.
    const toolbar = screen.queryByTestId(`${prefix}-toolbar`)
    const table = toolbar?.parentElement?.querySelector('table')
    return table ? table.querySelectorAll('tbody tr').length : 0
  }

  describe.each(TABLES)('$heading table', (spec) => {
    it('carries a toolbar, which no table on this page had before', () => {
      renderPage()
      expect(screen.getByTestId(`${spec.prefix}-toolbar`)).toBeInTheDocument()
      expect(screen.getByTestId(`${spec.prefix}-count`)).toHaveTextContent(
        `${spec.total} of ${spec.total} shown`,
      )
      expect(bodyRowCount(spec.prefix)).toBe(spec.total)
    })

    it('narrows the rows when the search box is typed into', () => {
      renderPage()
      fireEvent.change(screen.getByTestId(`${spec.prefix}-search`), {
        target: { value: spec.search.query },
      })

      expect(bodyRowCount(spec.prefix)).toBe(spec.search.rows)
      expect(screen.getByTestId(`${spec.prefix}-count`)).toHaveTextContent(
        `${spec.search.rows} of ${spec.total} shown`,
      )
      expect(sectionFor(spec.heading).getAllByText(spec.search.proof).length).toBeGreaterThan(0)
    })

    it('narrows the rows when a filter chip is pressed', () => {
      renderPage()
      const chip = screen.getByTestId(`${spec.prefix}-filter-${spec.chip.name}`)
      expect(chip).toHaveAttribute('aria-pressed', 'false')

      fireEvent.click(chip)

      expect(chip).toHaveAttribute('aria-pressed', 'true')
      expect(bodyRowCount(spec.prefix)).toBe(spec.chip.rows)
      expect(screen.getByTestId(`${spec.prefix}-count`)).toHaveTextContent(
        `${spec.chip.rows} of ${spec.total} shown`,
      )
    })

    // The bug DataTable's two props exist to prevent: a hand-rolled
    // `rows.length ? <Table/> : <EmptyState/>` takes the filter control down
    // with the table, so the filter that emptied it cannot be undone without a
    // reload. Asserting the toolbar is STILL THERE is the whole point.
    it('shows an empty state that the filter can be cleared from', () => {
      renderPage()
      const search = screen.getByTestId(`${spec.prefix}-search`)
      fireEvent.change(search, { target: { value: 'no-such-thing-anywhere' } })

      expect(screen.getByTestId(`${spec.prefix}-empty`)).toBeInTheDocument()
      expect(bodyRowCount(spec.prefix)).toBe(0)
      // The undo affordance survived the table it emptied.
      expect(screen.getByTestId(`${spec.prefix}-toolbar`)).toBeInTheDocument()
      expect(screen.getByTestId(`${spec.prefix}-search`)).toBeInTheDocument()
      expect(screen.getByTestId(`${spec.prefix}-filter-all`)).toBeInTheDocument()

      fireEvent.change(screen.getByTestId(`${spec.prefix}-search`), { target: { value: '' } })

      expect(screen.queryByTestId(`${spec.prefix}-empty`)).toBeNull()
      expect(bodyRowCount(spec.prefix)).toBe(spec.total)
    })

    it('resets to every row when the "all" chip is pressed', () => {
      renderPage()
      fireEvent.click(screen.getByTestId(`${spec.prefix}-filter-${spec.chip.name}`))
      fireEvent.click(screen.getByTestId(`${spec.prefix}-filter-all`))

      expect(bodyRowCount(spec.prefix)).toBe(spec.total)
    })

    it('counts each chip against the whole table, not against the current filter', () => {
      renderPage()
      // The chips only. The count span is their sibling inside the same strip
      // and is SUPPOSED to move, so sweeping up the whole toolbar would assert
      // the opposite of what this test is about.
      const chipText = () =>
        within(screen.getByTestId(`${spec.prefix}-toolbar`))
          .getAllByRole('button')
          .map((b) => b.textContent)
          .join('|')
      const before = chipText()

      fireEvent.click(screen.getByTestId(`${spec.prefix}-filter-${spec.chip.name}`))

      // A chip reporting the filtered set would read 0 for every option not
      // selected and stop being a way back to the rows it hides.
      expect(chipText()).toBe(before)
    })

    it('explains its jargon columns behind a HelpHint reachable by accessible name', () => {
      renderPage()
      const table = sectionFor(spec.heading)
      for (const hint of spec.hints) {
        const trigger = table.getByRole('button', { name: hint })
        expect(trigger).toBeInTheDocument()

        // Reachable by keyboard, not hover only — the tooltip has to appear for
        // someone who never touches a pointer.
        fireEvent.focus(trigger)
        const tip = table.getByRole('tooltip')
        expect(tip.textContent?.length ?? 0).toBeGreaterThan(20)
        expect(trigger).toHaveAttribute('aria-describedby', tip.id)

        fireEvent.blur(trigger)
        expect(table.queryByRole('tooltip')).toBeNull()
      }
    })

    it('puts no "?" on a header that already says it', () => {
      renderPage()
      const table = sectionFor(spec.heading)
      expect(table.queryAllByRole('button', { name: /^What .+ means$/ })).toHaveLength(
        spec.hints.length,
      )
    })
  })

  it('filters each table independently — narrowing one leaves the others whole', () => {
    renderPage()
    fireEvent.change(screen.getByTestId('fed-spiffe-search'), { target: { value: 'cardvault' } })

    expect(bodyRowCount('fed-spiffe')).toBe(1)
    expect(bodyRowCount('fed-events')).toBe(5)
    expect(bodyRowCount('fed-zones')).toBe(3)
  })

  // The three hints that predate the migration, asserted by CONTENT rather than
  // by name, so a reworded column cannot quietly drop the explanation. Their
  // test-ids are DataTable's now, and the accessible name is the better hook
  // anyway: it is the phrase a speech-input user has to say.
  describe('the jargon that gates federation, carried over verbatim', () => {
    it.each([
      ['What Mode means', /one-way means only the named direction does/i],
      ['What Attestation policy means', /Federating two zones does not admit everything/i],
      ['What SVID type means', /replayable if it leaks/i],
    ])('%s', (name, phrase) => {
      renderPage()
      fireEvent.focus(screen.getByRole('button', { name }))
      expect(screen.getByRole('tooltip')).toHaveTextContent(phrase)
    })
  })

  /**
   * Label-in-name (WCAG 2.5.3) for the controls this page authors. A speech
   * user says what they can see; an aria-label that replaces the visible text
   * with different words leaves them with nothing to say.
   */
  describe('accessible names contain the visible label', () => {
    it('gives the chips their own visible text as their name', () => {
      renderPage()
      const chip = screen.getByTestId('fed-federations-filter-federated')
      expect(chip).toHaveAccessibleName(expect.stringContaining('federated'))
      expect(chip.textContent).toContain('federated')
    })

    it('labels each search box with the table it searches, not just "Search"', () => {
      renderPage()
      expect(screen.getByTestId('fed-policies-search')).toHaveAccessibleName('Search attestation policies')
      expect(screen.getByTestId('fed-spiffe-search')).toHaveAccessibleName('Search SPIFFE identities')
    })
  })

  /**
   * DataTable's other half. Sorting is why the component exists; on a five-row
   * fixture it is not what a reader reaches for, but it is what the page grows
   * into and it costs one assertion to know it is wired up.
   */
  describe('sorting', () => {
    it('sorts SPIFFE identities by SVID type, bringing the replayable JWT to the top', () => {
      renderPage()
      const table = sectionFor('SPIFFE Identities')
      fireEvent.click(table.getByRole('columnheader', { name: /SVID type/ }))

      expect(table.getAllByRole('row')[1]).toHaveTextContent('JWT')
    })

    it('leaves the prose column unsortable', () => {
      renderPage()
      const table = sectionFor('Federation Events')
      const detail = table.getByRole('columnheader', { name: 'Detail' })
      fireEvent.click(detail)

      expect(detail).not.toHaveAttribute('aria-sort')
      // Still in the fixture's own order, newest first.
      expect(table.getAllByRole('row')[1]).toHaveTextContent('Bundle refreshed')
    })
  })
})
