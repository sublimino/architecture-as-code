import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import LoginPage from './LoginPage'

const mockLoginWithRedirect = vi.fn()
const mockNavigate = vi.fn()
let mockIsAuthenticated = false
let mockIsLoading = false

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual('react-router-dom')
  return {
    ...actual,
    useNavigate: () => mockNavigate,
  }
})

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    isAuthenticated: mockIsAuthenticated,
    isLoading: mockIsLoading,
    loginWithRedirect: mockLoginWithRedirect,
  }),
  LOGGED_OUT_KEY: 'signalloom:logged-out',
}))

describe('LoginPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockIsAuthenticated = false
    mockIsLoading = false
  })

  it('renders logged out state and Sign in with Dex button', () => {
    render(
      <MemoryRouter>
        <LoginPage />
      </MemoryRouter>,
    )

    expect(screen.getByText('Signal Loom')).toBeInTheDocument()
    expect(screen.getByText('You are currently signed out.')).toBeInTheDocument()
    const btn = screen.getByTestId('login-dex-btn')
    expect(btn).toBeInTheDocument()
    expect(btn).toHaveTextContent('Sign in with Dex')
  })

  it('clears logged-out key and calls loginWithRedirect on button click', () => {
    sessionStorage.setItem('signalloom:logged-out', 'true')
    render(
      <MemoryRouter>
        <LoginPage />
      </MemoryRouter>,
    )

    const btn = screen.getByTestId('login-dex-btn')
    fireEvent.click(btn)

    expect(sessionStorage.getItem('signalloom:logged-out')).toBeNull()
    expect(mockLoginWithRedirect).toHaveBeenCalled()
  })

  it('redirects to /agents when already authenticated', () => {
    mockIsAuthenticated = true
    render(
      <MemoryRouter>
        <LoginPage />
      </MemoryRouter>,
    )

    expect(mockNavigate).toHaveBeenCalledWith('/agents', { replace: true })
  })

  it('shows loading indicator when isLoading is true', () => {
    mockIsLoading = true
    render(
      <MemoryRouter>
        <LoginPage />
      </MemoryRouter>,
    )

    expect(screen.getByTestId('login-loading')).toBeInTheDocument()
  })
})
