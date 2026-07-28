import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import CollusionAccessPage from './CollusionAccessPage'

function renderPage() {
  return render(
    <MemoryRouter>
      <CollusionAccessPage />
    </MemoryRouter>,
  )
}

describe('CollusionAccessPage', () => {
  it('renders the Collusion & Access heading', () => {
    renderPage()
    expect(screen.getByRole('heading', { level: 1, name: /Collusion & Access/ })).toBeInTheDocument()
  })

  it('renders the KubeSec-AFM analysis sections', () => {
    renderPage()
    expect(screen.getByRole('heading', { name: 'Analysis Phases' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Collusion Pairs' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Shared-Role Pivot Points' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Remediation Priorities' })).toBeInTheDocument()
  })

  it('uses the radial cluster graph as a background image', () => {
    renderPage()
    const bg = screen.getByTestId('ktp-graph-bg')
    expect(bg.getAttribute('data-bg')).toBe('/ktp-collusion-graph.png')
    expect(bg).toHaveAttribute('aria-hidden')
  })

  it('renders concrete mock data — a collusion pivot role', () => {
    renderPage()
    expect(screen.getAllByText('role:flux-reconciler').length).toBeGreaterThan(0)
    expect(screen.getByText('clusterrole:admin')).toBeInTheDocument()
  })
})
