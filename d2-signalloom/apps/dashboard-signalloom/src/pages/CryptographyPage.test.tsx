/**
 * Acceptance tests for the Cryptography page.
 *
 * The page calls api.health.crypto() which routes through fakeData in demo mode.
 * We mock demoMode to ensure fake data resolves, and mock auth for the token.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor, fireEvent, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'

// CryptographyPage calls useAuth0() to get a token for api.health.crypto().
const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

// Enable demo mode so api.health.crypto() resolves via fakeData fixtures.
vi.mock('../api/demoMode', () => ({
  isDemoMode: () => true,
}))

// api.health.crypto is spied — its default implementation is the real
// function (still routed through demoMode/fakeData, so existing demo-mode
// tests are unaffected), but individual tests can override a single call
// with mockResolvedValueOnce/mockRejectedValueOnce to simulate the live
// backend returning zero proofs or being unreachable.
vi.mock('../api/client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api/client')>()
  return {
    ...actual,
    api: {
      ...actual.api,
      health: { crypto: vi.fn(actual.api.health.crypto) },
    },
  }
})

import { api } from '../api/client'
import CryptographyPage from './CryptographyPage'

const cryptoSpy = vi.mocked(api.health.crypto)

function renderPage() {
  return render(
    <MemoryRouter>
      <CryptographyPage />
    </MemoryRouter>,
  )
}

/** Scopes queries to the <section> containing a given heading, since the
 *  Cipher Discovery and Algorithm Inventory tables share column names
 *  ('End of life') and, for P-256, share EOL badge text too. */
function sectionFor(headingName: string) {
  const heading = screen.getByRole('heading', { name: headingName })
  const section = heading.closest('section')
  if (!section) throw new Error(`no <section> ancestor for heading "${headingName}"`)
  return within(section)
}

describe('CryptographyPage', () => {
  it('renders the Cryptography heading', () => {
    renderPage()
    expect(screen.getByRole('heading', { level: 1, name: 'Cryptography' })).toBeInTheDocument()
  })

  it('renders all six dashboard sections', () => {
    renderPage()
    expect(screen.getByRole('heading', { name: 'Cluster Root of Trust' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'OpenBao Bootstrap' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'SPIFFE / SPIRE Bootstrap' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Cipher Discovery (PQC)' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Algorithm Inventory' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'OAuth2 / MCP Proxies' })).toBeInTheDocument()
  })

  it('renders concrete mock data — a SPIFFE SVID and the OpenBao seal status', () => {
    renderPage()
    expect(
      screen.getByText('spiffe://signalloom.svc.cluster.local/ns/fe-signalloom/sa/dashboard'),
    ).toBeInTheDocument()
    expect(screen.getByText('unsealed')).toBeInTheDocument()
  })

  it('renders a post-quantum key-exchange algorithm', () => {
    renderPage()
    expect(screen.getAllByText('X25519MLKEM768').length).toBeGreaterThan(0)
  })

  it('renders summary stat cards including PQC coverage', () => {
    renderPage()
    expect(screen.getByText('PQC coverage')).toBeInTheDocument()
    expect(screen.getByText('Workload identities')).toBeInTheDocument()
  })

  it('renders the Algorithm Inventory with PQC algorithms and sourced EOL dates', () => {
    renderPage()
    const table = sectionFor('Algorithm Inventory')
    // PQC algorithms — standardised, no EOL
    expect(table.getByText('ML-KEM (Kyber)')).toBeInTheDocument()
    expect(table.getByText('ML-DSA (Dilithium)')).toBeInTheDocument()
    expect(table.getByText('SLH-DSA (SPHINCS+)')).toBeInTheDocument()
    expect(table.getByText('FIPS 203')).toBeInTheDocument()
    expect(table.getByText('FIPS 204')).toBeInTheDocument()
    expect(table.getByText('FIPS 205')).toBeInTheDocument()
    // Classical/quantum-vulnerable algorithms carry a sourced EOL badge, not a bare literal.
    expect(table.getByText('RSA-2048')).toBeInTheDocument()
    expect(table.getByText('ECDH P-256')).toBeInTheDocument() // added so the Key exchange click-through has a real, correctly-typed target
    const eolBadges = table.getAllByText('EOL 2035')
    expect(eolBadges.length).toBe(5) // RSA-2048, ECDSA P-256, ECDSA P-384, X25519, ECDH P-256
    for (const badge of eolBadges) {
      expect(badge).toHaveAttribute('title', expect.stringContaining('NIST IR 8547'))
    }
    expect(table.getAllByText('Quantum-vulnerable — disallowed after 2035 (NIST IR 8547 IPD)').length).toBe(5)
    // Quantum-resistant symmetric — no EOL
    expect(table.getByText('AES-256')).toBeInTheDocument()
    expect(table.getAllByText('None').length).toBeGreaterThanOrEqual(4) // 3 PQC algorithms + AES-256
  })

  it('agrees between Cipher Discovery and Algorithm Inventory on the P-256 EOL date and citation', () => {
    renderPage()
    const cipherBadge = sectionFor('Cipher Discovery (PQC)').getAllByText('EOL 2035')[0]
    const inventoryBadge = sectionFor('Algorithm Inventory').getAllByText('EOL 2035').find(
      (el) => el.closest('tr')?.textContent?.includes('ECDH P-256'),
    )
    expect(inventoryBadge).toBeDefined()
    // Same underlying data-file entry backs both tables, so the citation must be identical, not just the date.
    expect(cipherBadge.getAttribute('title')).toBe(inventoryBadge!.getAttribute('title'))
  })

  it('loads workload-identity proofs from the API in demo mode', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByText('Dashboard workload exchanged SPIFFE identity for OpenBao access')).toBeInTheDocument()
    })
    expect(screen.getByText('Forged service-account replay was rejected')).toBeInTheDocument()
  })

  // Now rendered through the shared ErrorState, so the headline and the detail
  // are one message rather than two elements — matched on substring for that
  // reason, not because the wording got vaguer. The Retry is new: a failed
  // fetch used to be a dead end with nothing to press.
  it('shows an accurate "unreachable" message when the proof service call fails', async () => {
    cryptoSpy.mockRejectedValueOnce(new Error('network error'))
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('crypto-proofs-outcome')).toBeInTheDocument()
    })
    const outcome = screen.getByTestId('crypto-proofs-outcome')
    expect(outcome).toHaveTextContent('Workload-identity proof service unreachable')
    // The diagnostic chain survived the move into ErrorState.
    expect(outcome).toHaveTextContent('fake-integration-proxy')
    expect(outcome).toHaveTextContent('bao-spire-negative-proof')
    expect(screen.queryByText(/API in development/)).not.toBeInTheDocument()
  })

  it('offers a retry on an unreachable proof service, and re-asks when pressed', async () => {
    cryptoSpy.mockRejectedValueOnce(new Error('network error'))
    renderPage()
    const retry = await screen.findByTestId('error-retry')

    const callsBefore = cryptoSpy.mock.calls.length
    fireEvent.click(retry)
    await waitFor(() => expect(cryptoSpy.mock.calls.length).toBeGreaterThan(callsBefore))
    // The second call succeeds through the demo fixtures, so the panel recovers.
    await waitFor(() => {
      expect(screen.getByText('Dashboard workload exchanged SPIFFE identity for OpenBao access')).toBeInTheDocument()
    })
  })

  it('does not dress a healthy zero as a failure', async () => {
    cryptoSpy.mockResolvedValueOnce({ tenant_id: 'demo-tenant', proofs: [] })
    renderPage()
    await waitFor(() => {
      expect(screen.getByText('No workload-identity proofs reported')).toBeInTheDocument()
    })
    // EmptyState, not ErrorState: nothing failed, so there is nothing to retry
    // and no "Failed to load".
    expect(screen.queryByTestId('error-retry')).toBeNull()
    expect(screen.queryByText('Failed to load')).toBeNull()
  })

  it('shows an accurate "no proofs reported" message when the API succeeds with zero proofs', async () => {
    cryptoSpy.mockResolvedValueOnce({ tenant_id: 'demo-tenant', proofs: [] })
    renderPage()
    await waitFor(() => {
      expect(screen.getByText('No workload-identity proofs reported')).toBeInTheDocument()
    })
    expect(screen.queryByText(/API in development/)).not.toBeInTheDocument()
  })

  it('adds an End of Life column to the Cipher Discovery table, sourced per cipher', () => {
    renderPage()
    const table = sectionFor('Cipher Discovery (PQC)')
    // Anchored prefix rather than an exact name: the header now carries a
    // HelpHint, and an explicit aria-label on a descendant button joins the
    // header's own accessible name — it reads "End of life What End of life
    // means". The column is still called what it was called; the assertion was
    // over-specified about what else is allowed to be inside the cell.
    expect(table.getByRole('columnheader', { name: /^End of life/ })).toBeInTheDocument()
    // Classical key exchange (ECDHE P-256, used by postgres and redis) is flagged with a sourced EOL date.
    const eolBadges = table.getAllByText('EOL 2035')
    expect(eolBadges.length).toBe(2)
    for (const badge of eolBadges) {
      expect(badge).toHaveAttribute('title', expect.stringContaining('NIST IR 8547'))
    }
    // PQC-ready/hybrid ciphers have no EOL.
    expect(table.getAllByText('None').length).toBeGreaterThan(0)
  })

  // The local Pill this page used to carry built its fill with
  // `hex(colors.tealLoom, 0.12)`, and `colors.tealLoom` is the string
  // `var(--teal)` — so the background computed to `var(--teal)1f`, which is not
  // a colour and was dropped by the parser. Every badge on the page rendered
  // with no fill in all three themes, and the only visible symptom was slightly
  // thin-looking text, which is why it went unnoticed. StatusBadge's
  // color-mix-based tint is the fix.
  describe('badges get an actual fill', () => {
    it('tints a CA-status badge instead of emitting an unparseable colour', () => {
      renderPage()
      const badge = screen.getByText('renewing', { selector: '.tag' })

      expect(badge.style.background).toContain('color-mix')
      expect(badge.style.background).toContain('var(--cyan)')
      // The exact shape of the old defect: a token with an alpha suffix glued on.
      expect(badge.getAttribute('style')).not.toMatch(/var\(--[a-z-]+\)[0-9a-f]{2}/)
    })

    it('leaves no alpha-suffixed token anywhere on the page', () => {
      const { container } = renderPage()
      const broken = [...container.querySelectorAll<HTMLElement>('[style]')]
        .map((el) => el.getAttribute('style') ?? '')
        .filter((style) => /var\(--[a-z0-9-]+\)[0-9a-f]{2}\b/i.test(style))

      expect(broken).toEqual([])
    })

    it('renders the crypto statuses through StatusBadge with their own colours', () => {
      renderPage()
      const expected: Record<string, string> = {
        active: 'var(--teal)', renewing: 'var(--cyan)', expiring: 'var(--amber)',
        ready: 'var(--teal)', hybrid: 'var(--cyan)', classical: 'var(--amber)',
        degraded: 'var(--amber)',
      }
      for (const [status, color] of Object.entries(expected)) {
        const badges = screen.getAllByText(status, { selector: '.tag' })
        expect(badges.length, status).toBeGreaterThan(0)
        expect(badges[0].style.color, status).toBe(color)
      }
    })
  })

  // The page mounts, fires the proof request, and — in every synchronous test
  // above — is unmounted by Testing Library's auto-cleanup long before that
  // request settles. Nothing here used to stop it, so the fixture's 120ms timer
  // outlived the test file and React ran `dispatchSetState` against a torn-down
  // jsdom, failing the whole suite with all 1611 tests green. The guarantee
  // below is what closes that, and it is the same guarantee a user navigating
  // away from /cryptography mid-request depends on.
  describe('leaves nothing running behind it', () => {
    /** The signal handed to the most recent proof request. */
    function latestSignal(): AbortSignal | undefined {
      const calls = cryptoSpy.mock.calls
      return calls[calls.length - 1]?.[1]
    }

    it('aborts the in-flight proof request when the page unmounts', async () => {
      const { unmount } = renderPage()
      await waitFor(() => expect(cryptoSpy).toHaveBeenCalled())

      const signal = latestSignal()
      expect(signal).toBeInstanceOf(AbortSignal)
      expect(signal?.aborted).toBe(false)

      unmount()

      expect(signal?.aborted).toBe(true)
    })

    it('supersedes an outstanding attempt when Retry is pressed', async () => {
      cryptoSpy.mockRejectedValueOnce(new Error('network error'))
      renderPage()

      const retry = await screen.findByRole('button', { name: /retry/i })
      const firstSignal = latestSignal()

      fireEvent.click(retry)

      await waitFor(() => expect(cryptoSpy.mock.calls.length).toBeGreaterThan(1))
      expect(firstSignal?.aborted).toBe(true)
      expect(latestSignal()?.aborted).toBe(false)
    })
  })

  it('makes the Key exchange column click through to the matching Algorithm Inventory row', () => {
    renderPage()
    const links = screen.getAllByRole('button', { name: /View ECDHE P-256 in Algorithm Inventory/ })
    const targetRow = screen.getByText('ECDH P-256').closest('tr')
    expect(targetRow).not.toBeNull()
    expect(targetRow).toHaveAttribute('data-highlighted', 'false')

    fireEvent.click(links[0])

    expect(targetRow).toHaveAttribute('data-highlighted', 'true')
  })

  // ── Design-system migration ───────────────────────────────────────────────
  //
  // Every table on this page is now a DataTable with a `toolbar` and an
  // `emptyState`, which is the shape the Design System page calls "Realistic".
  // The suite below is table-driven on purpose: the point of the migration is
  // that all six behave IDENTICALLY, and six hand-written near-copies would let
  // one of them drift without failing anything. A table that forgets its
  // toolbar, its count, its empty state or its undo fails here by construction.

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
      heading: 'Cluster Root of Trust',
      prefix: 'root-of-trust',
      total: 4,
      search: { query: 'SPIRE Server', rows: 1, proof: 'SPIRE Server CA' },
      chip: { name: 'expiring', rows: 1 },
      hints: ['What Role means', 'What Status means'],
    },
    {
      heading: 'OpenBao Bootstrap',
      prefix: 'bao-engines',
      total: 5,
      search: { query: 'transit', rows: 1, proof: 'transit/envelope' },
      // Nothing is sealed, so this chip is the one that empties a table on a
      // page where every other filter has survivors — the empty-state path is
      // reachable by a real control, not only by a nonsense search.
      chip: { name: 'sealed', rows: 0 },
      hints: ['What Type means', 'What Active leases means'],
    },
    {
      heading: 'SPIFFE / SPIRE Bootstrap',
      prefix: 'spire-svids',
      total: 5,
      search: { query: 'legacy-batch', rows: 1, proof: 'legacy-batch-runner' },
      chip: { name: 'revoked', rows: 1 },
      hints: ['What SPIFFE ID means', 'What Selector means'],
    },
    {
      heading: 'Cipher Discovery (PQC)',
      prefix: 'cipher-discovery',
      total: 6,
      search: { query: 'postgres', rows: 1, proof: 'postgres (internal)' },
      chip: { name: 'classical', rows: 2 },
      hints: ['What Key exchange means', 'What PQC means', 'What End of life means'],
    },
    {
      heading: 'Algorithm Inventory',
      prefix: 'algo-inventory',
      total: 9,
      search: { query: 'Kyber', rows: 1, proof: 'ML-KEM (Kyber)' },
      chip: { name: 'quantum-vulnerable', rows: 5 },
      hints: ['What NIST Status means', 'What End of life means', 'What Quantum-safe means'],
    },
    {
      heading: 'OAuth2 / MCP Proxies',
      prefix: 'proxies',
      total: 4,
      search: { query: 'llm-gateway', rows: 1, proof: 'mcp-proxy/llm-gateway' },
      chip: { name: 'mcp-proxy', rows: 2 },
      hints: ['What Kind means', 'What Identity provider means', 'What Status means'],
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
      expect(sectionFor(spec.heading).getByText(spec.search.proof)).toBeInTheDocument()
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
  })

  it('filters each table independently — narrowing one leaves the others whole', () => {
    renderPage()
    fireEvent.change(screen.getByTestId('cipher-discovery-search'), { target: { value: 'postgres' } })

    expect(bodyRowCount('cipher-discovery')).toBe(1)
    expect(bodyRowCount('algo-inventory')).toBe(9)
    expect(bodyRowCount('root-of-trust')).toBe(4)
  })

  // The Recharts PieChart this section used to draw was a charting dependency
  // carrying a hand-rolled HTML overlay for its centre label and a hand-rolled
  // legend beneath it. DonutChart is the design system's answer for a single
  // proportion and needs neither.
  it('draws PQC coverage with the design system DonutChart, not a charting dependency', () => {
    const { container } = renderPage()
    const section = sectionFor('Cipher Discovery (PQC)')

    expect(section.getByText('67%')).toBeInTheDocument()
    expect(section.getByText('quantum-safe')).toBeInTheDocument()
    // Legend still names all three segments with their counts.
    expect(section.getByText(/PQC ready:/)).toHaveTextContent('PQC ready: 2')
    expect(section.getByText(/Hybrid:/)).toHaveTextContent('Hybrid: 2')
    expect(section.getByText(/Classical:/)).toHaveTextContent('Classical: 2')
    // Recharts renders into a .recharts-wrapper; nothing on the page should now.
    expect(container.querySelector('.recharts-wrapper')).toBeNull()
  })

  it('explains where the quantum-safe percentage comes from', () => {
    renderPage()
    const hint = sectionFor('Cipher Discovery (PQC)').getByRole('button', {
      name: 'What the quantum-safe percentage counts',
    })
    fireEvent.focus(hint)
    expect(screen.getByRole('tooltip')).toHaveTextContent(/hybrid/i)
  })
})
