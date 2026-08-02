/**
 * Acceptance tests for the Cryptography page.
 *
 * The page calls api.health.crypto() which routes through fakeData in demo mode.
 * We mock demoMode to ensure fake data resolves, and mock auth for the token.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
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

  it('renders the Algorithm Inventory with PQC algorithms and EOL dates', () => {
    renderPage()
    // PQC algorithms — standardised, no EOL
    expect(screen.getByText('ML-KEM (Kyber)')).toBeInTheDocument()
    expect(screen.getByText('ML-DSA (Dilithium)')).toBeInTheDocument()
    expect(screen.getByText('SLH-DSA (SPHINCS+)')).toBeInTheDocument()
    expect(screen.getByText('FIPS 203')).toBeInTheDocument()
    expect(screen.getByText('FIPS 204')).toBeInTheDocument()
    expect(screen.getByText('FIPS 205')).toBeInTheDocument()
    // Classical algorithms with EOL
    expect(screen.getByText('RSA-2048')).toBeInTheDocument()
    expect(screen.getAllByText('2030').length).toBeGreaterThanOrEqual(3)
    // Quantum-resistant symmetric
    expect(screen.getByText('AES-256')).toBeInTheDocument()
  })

  it('loads workload-identity proofs from the API in demo mode', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByText('Dashboard workload exchanged SPIFFE identity for OpenBao access')).toBeInTheDocument()
    })
    expect(screen.getByText('Forged service-account replay was rejected')).toBeInTheDocument()
  })
})
