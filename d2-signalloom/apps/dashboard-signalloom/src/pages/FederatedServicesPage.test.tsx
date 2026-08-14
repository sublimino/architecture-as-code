import { describe, it, expect } from 'vitest'
import { render, screen, within } from '@testing-library/react'
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
 * The rows of one table, by its DataTable test-id prefix.
 *
 * Scoped to the table rather than the page: six tables now render on this page
 * and `getAllByRole('row')` would happily count another one's. The prefix is
 * the only thing that distinguishes them, which is why every DataTable here has
 * one.
 */
function bodyRows(prefix: string): HTMLElement[] {
  const toolbar = screen.getByTestId(`${prefix}-toolbar`)
  // The toolbar and the table are siblings inside DataTable's wrapper.
  const table = toolbar.parentElement?.querySelector('table')
  if (!table) return []
  return Array.from(table.querySelectorAll('tbody tr'))
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

    // Selected by ACCESSIBLE NAME rather than test-id. The three hints on this
    // page used to be hand-placed in DashKit headers with test-ids this file
    // chose; they are now `help` strings on DataTable columns, and DataTable
    // derives both the name (`What <label> means`) and the test-id from the
    // column. The name is the better hook of the two anyway: it is the thing a
    // speech-input user says out loud, so asserting on it also asserts that the
    // hint is reachable by someone who is not using a mouse.
    it('explains the jargon that gates federation, from inside a table header', async () => {
      const user = userEvent.setup()
      renderPage()

      await user.hover(screen.getByRole('button', { name: 'What Attestation policy means' }))
      expect(await screen.findByRole('tooltip')).toHaveTextContent(/Federating two zones does not admit everything/i)
    })

    it('distinguishes an X.509 SVID from a replayable JWT one', async () => {
      const user = userEvent.setup()
      renderPage()

      await user.hover(screen.getByRole('button', { name: 'What SVID type means' }))
      expect(await screen.findByRole('tooltip')).toHaveTextContent(/replayable if it leaks/i)
    })

    it('keeps the trust-direction hint that predates the DataTable migration', async () => {
      const user = userEvent.setup()
      renderPage()

      await user.hover(screen.getByRole('button', { name: 'What Mode means' }))
      expect(await screen.findByRole('tooltip')).toHaveTextContent(/one-way means only the named direction does/i)
    })
  })

  /**
   * Every hint on the page, by the accessible name DataTable derives from the
   * column label, and the phrase that makes it worth having.
   *
   * Table-driven rather than ten `it` blocks because the assertion is identical
   * ten times over and the interesting content is the list — which is also the
   * convention this page is meant to set. A column gets a hint when its label
   * is a term of art a competent reader would guess WRONG about. Federation
   * Events is absent from this list on purpose: "Timestamp", "Zone", "Event"
   * and "Detail" mean what they say, and a convention that fires everywhere is
   * decoration rather than judgement.
   */
  describe('tooltips, each reachable by its accessible name', () => {
    const HINTS: [name: string, phrase: RegExp][] = [
      ['What Trust domain means', /share no certificate authority/i],
      ['What SPIRE servers means', /identity is not partitioned by server/i],
      ['What Mode means', /Bidirectional means each zone accepts/i],
      ['What Attestation policy means', /this is the filter/i],
      ['What Status means', /reads as working and is not/i],
      ['What Local endpoint means', /not the remote service/i],
      ['What Transport means', /Who holds the socket/i],
      ['What Selector means', /forgeable by anything that controls it/i],
      ['What SPIFFE ID means', /a different identity, not the same one renamed/i],
      ['What SVID type means', /replayable if it leaks/i],
    ]

    it.each(HINTS)('%s', async (name, phrase) => {
      const user = userEvent.setup()
      renderPage()

      const hint = screen.getByRole('button', { name })
      await user.hover(hint)
      expect(await screen.findByRole('tooltip')).toHaveTextContent(phrase)
    })

    it('leaves the self-evident columns alone', () => {
      renderPage()
      for (const label of ['Zone', 'Namespace', 'Timestamp', 'Event', 'Detail', 'Clusters']) {
        expect(screen.queryByRole('button', { name: `What ${label} means` })).toBeNull()
      }
    })
  })

  /**
   * Filters. Every table on the page has one, and they all work the same way:
   * a search box, a chip strip on one axis, a Clear filters button and a count,
   * in that order, in DataTable's `toolbar` slot.
   */
  describe('filters', () => {
    it('gives every table a toolbar', () => {
      renderPage()
      for (const prefix of ['fed-zones', 'fed-federations', 'fed-services', 'fed-policies', 'fed-spiffe', 'fed-events']) {
        expect(screen.getByTestId(`${prefix}-toolbar`)).toBeInTheDocument()
      }
    })

    it('narrows trust zones by search over name and trust domain', async () => {
      const user = userEvent.setup()
      renderPage()
      expect(bodyRows('fed-zones')).toHaveLength(3)

      await user.type(screen.getByTestId('fed-zones-search'), 'acme.partner')
      expect(bodyRows('fed-zones')).toHaveLength(1)
      expect(screen.getByTestId('fed-zones-count')).toHaveTextContent('1 of 3 shown')
    })

    it('narrows federations by status chip', async () => {
      const user = userEvent.setup()
      renderPage()
      expect(bodyRows('fed-federations')).toHaveLength(3)

      await user.click(screen.getByTestId('fed-federations-filter-connecting'))
      const rows = bodyRows('fed-federations')
      expect(rows).toHaveLength(1)
      expect(rows[0]).toHaveTextContent('pending bundle exchange')
    })

    it('narrows federated services by home zone', async () => {
      const user = userEvent.setup()
      renderPage()
      expect(bodyRows('fed-services')).toHaveLength(4)

      await user.click(screen.getByTestId('fed-services-filter-signalloom-eu'))
      expect(bodyRows('fed-services')).toHaveLength(2)
      expect(screen.getByTestId('fed-services-count')).toHaveTextContent('2 of 4 shown')
    })

    // The one row-to-many-chips case on the page: `zones: 'eu, acme'` puts one
    // policy under both chips, so the chip counts deliberately sum to more than
    // the row count.
    it('files a policy under every zone it binds', async () => {
      const user = userEvent.setup()
      renderPage()

      await user.click(screen.getByTestId('fed-policies-filter-acme'))
      const rows = bodyRows('fed-policies')
      expect(rows).toHaveLength(1)
      expect(rows[0]).toHaveTextContent('ap-partner-read')

      await user.click(screen.getByTestId('fed-policies-filter-eu'))
      expect(bodyRows('fed-policies')).toHaveLength(3)
    })

    it('narrows SPIFFE identities by workload, and by search over the URI', async () => {
      const user = userEvent.setup()
      renderPage()
      expect(bodyRows('fed-spiffe')).toHaveLength(5)

      await user.click(screen.getByTestId('fed-spiffe-filter-service'))
      expect(bodyRows('fed-spiffe')).toHaveLength(3)

      await user.type(screen.getByTestId('fed-spiffe-search'), 'acme.partner.example')
      expect(bodyRows('fed-spiffe')).toHaveLength(1)
    })

    it('narrows federation events by zone', async () => {
      const user = userEvent.setup()
      renderPage()
      expect(bodyRows('fed-events')).toHaveLength(5)

      await user.click(screen.getByTestId('fed-events-filter-signalloom-eu'))
      expect(bodyRows('fed-events')).toHaveLength(3)
    })

    it('counts each chip against the whole table, not against the current filter', async () => {
      const user = userEvent.setup()
      renderPage()

      const before = screen.getByTestId('fed-services-filter-signalloom-us').textContent
      await user.click(screen.getByTestId('fed-services-filter-signalloom-eu'))
      // A chip whose count reported the filtered set would now read 0 and stop
      // being a way back to the rows it hides.
      expect(screen.getByTestId('fed-services-filter-signalloom-us')).toHaveTextContent(before ?? '')
    })
  })

  /**
   * The reason `toolbar` and `emptyState` are DataTable props rather than
   * something a page stacks by hand: a hand-rolled
   * `rows.length ? <Table/> : <EmptyState/>` takes the control that emptied the
   * table down with it, and the only way out is a reload.
   */
  describe('the empty state, and getting out of it', () => {
    it('replaces the table when nothing matches', async () => {
      const user = userEvent.setup()
      renderPage()

      await user.type(screen.getByTestId('fed-zones-search'), 'no-such-zone')
      const empty = screen.getByTestId('fed-zones-empty')
      expect(empty).toHaveTextContent(/Nothing matches those filters/i)
      expect(bodyRows('fed-zones')).toHaveLength(0)
    })

    it('keeps the toolbar alive on the empty branch so the filter can be undone', async () => {
      const user = userEvent.setup()
      renderPage()

      await user.type(screen.getByTestId('fed-events-search'), 'no-such-event')
      expect(screen.getByTestId('fed-events-empty')).toBeInTheDocument()

      // The controls that caused it are still on screen — this is the whole
      // guarantee the two props buy.
      const toolbar = screen.getByTestId('fed-events-toolbar')
      expect(within(toolbar).getByTestId('fed-events-search')).toBeInTheDocument()
      expect(within(toolbar).getByRole('button', { name: 'Clear filters' })).toBeEnabled()

      await user.click(within(toolbar).getByRole('button', { name: 'Clear filters' }))
      expect(screen.queryByTestId('fed-events-empty')).toBeNull()
      expect(bodyRows('fed-events')).toHaveLength(5)
    })

    it('clears a chip and a search together', async () => {
      const user = userEvent.setup()
      renderPage()

      await user.click(screen.getByTestId('fed-spiffe-filter-agent'))
      await user.type(screen.getByTestId('fed-spiffe-search'), 'zzz')
      expect(screen.getByTestId('fed-spiffe-empty')).toBeInTheDocument()

      await user.click(screen.getByTestId('fed-spiffe-clear'))
      expect(bodyRows('fed-spiffe')).toHaveLength(5)
      expect(screen.getByTestId('fed-spiffe-search')).toHaveValue('')
      expect(screen.getByTestId('fed-spiffe-filter-all')).toHaveAttribute('aria-pressed', 'true')
    })

    // Disabled rather than unmounted. A control that appears only once it is
    // needed shifts everything beside it at the moment the reader is aiming,
    // which is the same defect class as DataTable's footer hiding the select
    // that opened it.
    it('keeps Clear filters on screen but inert when there is nothing to clear', () => {
      renderPage()
      expect(screen.getByTestId('fed-zones-clear')).toBeDisabled()
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

    it('labels each search box with the table it searches', () => {
      renderPage()
      expect(screen.getByTestId('fed-policies-search')).toHaveAccessibleName('Search attestation policies')
    })

    it('groups each chip strip under the axis it filters', () => {
      renderPage()
      expect(screen.getByRole('group', { name: 'Filter federated services by home zone' })).toBeInTheDocument()
      expect(screen.getByRole('group', { name: 'Filter SPIFFE identities by workload' })).toBeInTheDocument()
    })
  })

  /**
   * DataTable's other half. Sorting is why the component exists; on a five-row
   * fixture it is not what a reader reaches for, but it is what the page grows
   * into and it costs one assertion to know it is wired up.
   */
  describe('sorting', () => {
    it('sorts SPIFFE identities by SVID type, bringing the replayable JWT to the top', async () => {
      const user = userEvent.setup()
      renderPage()

      await user.click(screen.getByRole('columnheader', { name: /SVID type/ }))
      expect(bodyRows('fed-spiffe')[0]).toHaveTextContent('JWT')
    })

    it('leaves the prose column unsortable', async () => {
      const user = userEvent.setup()
      renderPage()

      const detail = screen.getByRole('columnheader', { name: 'Detail' })
      await user.click(detail)
      expect(detail).not.toHaveAttribute('aria-sort')
      // Still in the fixture's own order, newest first.
      expect(bodyRows('fed-events')[0]).toHaveTextContent('Bundle refreshed')
    })
  })
})
