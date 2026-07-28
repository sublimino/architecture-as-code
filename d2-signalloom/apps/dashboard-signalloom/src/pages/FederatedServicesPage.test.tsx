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
    expect(screen.getByText('payments-api')).toBeInTheDocument()
    expect(screen.getByText(/cofide-sdk-go\/cofide/)).toBeInTheDocument()
  })
})
