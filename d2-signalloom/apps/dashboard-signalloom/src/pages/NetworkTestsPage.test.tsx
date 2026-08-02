import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    isAuthenticated: true,
    getAccessTokenSilently: () => Promise.resolve('fake-token'),
    user: { name: 'Test', email: 'test@example.com' },
  }),
}))

import NetworkTestsPage from './NetworkTestsPage'

function renderPage() {
  return render(
    <MemoryRouter>
      <NetworkTestsPage />
    </MemoryRouter>,
  )
}

describe('NetworkTestsPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('renders the page heading', () => {
    renderPage()
    expect(screen.getByText('Network Tests')).toBeTruthy()
  })

  it('renders the NetSerts section', () => {
    renderPage()
    expect(screen.getByText('NetSerts — Network Policy Assertions')).toBeTruthy()
  })

  it('renders allowed and denied test entries', () => {
    renderPage()
    // Allowed paths
    expect(screen.getByText('dashboard-to-api-allowed')).toBeTruthy()
    expect(screen.getByText('dashboard-to-dex-allowed')).toBeTruthy()
    expect(screen.getByText('api-to-postgresql-allowed')).toBeTruthy()
    // Denied paths
    expect(screen.getByText('agents-to-api-denied')).toBeTruthy()
    expect(screen.getByText('agents-to-dashboard-denied')).toBeTruthy()
  })

  it('renders the CI Pipeline Results section', () => {
    renderPage()
    expect(screen.getByText('CI Pipeline Results')).toBeTruthy()
  })

  it('renders CI summary stats', () => {
    renderPage()
    // Summary cards
    expect(screen.getByText('176')).toBeTruthy() // pass count
    expect(screen.getByText('14')).toBeTruthy()  // fail count
  })

  it('renders agent test results section', () => {
    renderPage()
    expect(screen.getByText('Agent Test Infrastructure')).toBeTruthy()
  })

  it('renders the fe-signalloom-agents namespace reference', () => {
    renderPage()
    expect(screen.getAllByText('fe-signalloom-agents').length).toBeGreaterThan(0)
  })
})
