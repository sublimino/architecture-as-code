import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import FederatedServicesPage from './FederatedServicesPage'

function renderPage() {
  return render(
    <MemoryRouter>
      <FederatedServicesPage />
    </MemoryRouter>,
  )
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
})
