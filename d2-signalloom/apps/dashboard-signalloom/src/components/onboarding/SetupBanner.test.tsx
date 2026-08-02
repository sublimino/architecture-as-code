import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import SetupBanner from './SetupBanner'

const navigateMock = vi.fn()
vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual('react-router-dom')
  return { ...actual, useNavigate: () => navigateMock }
})

describe('SetupBanner', () => {
  it('shows the connected/total provider count', () => {
    render(
      <MemoryRouter>
        <SetupBanner connectedCount={2} totalCount={5} />
      </MemoryRouter>,
    )
    expect(screen.getByText('2 of 5 providers connected')).toBeInTheDocument()
  })

  it('navigates to /onboarding when "Complete setup" is clicked', () => {
    render(
      <MemoryRouter>
        <SetupBanner connectedCount={0} totalCount={5} />
      </MemoryRouter>,
    )
    fireEvent.click(screen.getByRole('button', { name: 'Complete setup' }))
    expect(navigateMock).toHaveBeenCalledWith('/onboarding')
  })

  it('handles zero total providers without dividing by zero', () => {
    render(
      <MemoryRouter>
        <SetupBanner connectedCount={0} totalCount={0} />
      </MemoryRouter>,
    )
    expect(screen.getByText('0 of 0 providers connected')).toBeInTheDocument()
  })
})
