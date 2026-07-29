/**
 * Acceptance tests for the Cryptography page.
 *
 * The page is self-contained (in-module mock data, no API/auth), so these tests
 * render it directly and assert the enriched dashboard surfaces every trust domain.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'

// CryptographyPage now calls useAuth0() for the live crypto-proof section.
const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

import CryptographyPage from './CryptographyPage'

function renderPage() {
  return render(
    <MemoryRouter>
      <CryptographyPage />
    </MemoryRouter>,
  )
}

describe('CryptographyPage', () => {
  it('renders the Cryptography heading', () => {
    renderPage()
    expect(screen.getByRole('heading', { level: 1, name: 'Cryptography' })).toBeInTheDocument()
  })

  it('renders all five trust-domain sections', () => {
    renderPage()
    expect(screen.getByRole('heading', { name: 'Cluster Root of Trust' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'OpenBao Bootstrap' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'SPIFFE / SPIRE Bootstrap' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Cipher Discovery (PQC)' })).toBeInTheDocument()
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
})
