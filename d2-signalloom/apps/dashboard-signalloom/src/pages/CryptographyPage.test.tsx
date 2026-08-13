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
    expect(table.getByRole('columnheader', { name: 'End of life' })).toBeInTheDocument()
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

  it('makes the Key exchange column click through to the matching Algorithm Inventory row', () => {
    renderPage()
    const links = screen.getAllByRole('button', { name: /View ECDHE P-256 in Algorithm Inventory/ })
    const targetRow = screen.getByText('ECDH P-256').closest('tr')
    expect(targetRow).not.toBeNull()
    expect(targetRow).toHaveAttribute('data-highlighted', 'false')

    fireEvent.click(links[0])

    expect(targetRow).toHaveAttribute('data-highlighted', 'true')
  })
})
