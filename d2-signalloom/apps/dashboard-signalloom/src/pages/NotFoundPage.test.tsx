import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import NotFoundPage from './NotFoundPage'

describe('NotFoundPage', () => {
  it('renders 404 status code, heading and explanatory message', () => {
    render(
      <MemoryRouter>
        <NotFoundPage />
      </MemoryRouter>,
    )

    expect(screen.getByTestId('not-found')).toBeInTheDocument()
    expect(screen.getByText('404')).toBeInTheDocument()
    expect(screen.getByRole('heading', { level: 1, name: 'Page Not Found' })).toBeInTheDocument()
    expect(
      screen.getByText(/The page you requested does not exist, has been moved, or is disabled for your tenant/i),
    ).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Back to Agents' })).toHaveAttribute('href', '/agents')
  })

  it('renders safely outside of React Router context (using SafeLink fallback)', () => {
    // Provider-free render — proves it does not throw useHref or useLocation errors
    render(<NotFoundPage />)

    expect(screen.getByTestId('not-found')).toBeInTheDocument()
    expect(screen.getByText('404')).toBeInTheDocument()
    expect(screen.getByRole('heading', { level: 1, name: 'Page Not Found' })).toBeInTheDocument()
    const link = screen.getByRole('link', { name: 'Back to Agents' })
    expect(link).toHaveAttribute('href', '/agents')
    expect(link.tagName).toBe('A')
  })
})
