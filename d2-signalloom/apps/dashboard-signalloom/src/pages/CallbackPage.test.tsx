import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { installMemoryStorage } from '../test-utils/memoryStorage'
import CallbackPage from './CallbackPage'

const mockNavigate = vi.fn()
const mockSigninRedirect = vi.fn().mockResolvedValue(undefined)
let mockAuthState = {
  isAuthenticated: false,
  isLoading: false,
  error: null as Error | null,
  signinRedirect: mockSigninRedirect,
}

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual('react-router-dom')
  return {
    ...actual,
    useNavigate: () => mockNavigate,
  }
})

vi.mock('react-oidc-context', () => ({
  useAuth: () => mockAuthState,
}))

describe('CallbackPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    installMemoryStorage()
    mockAuthState = {
      isAuthenticated: false,
      isLoading: false,
      error: null,
      signinRedirect: mockSigninRedirect,
    }
  })

  it('renders loading state while sign in is resolving', () => {
    render(
      <MemoryRouter>
        <CallbackPage />
      </MemoryRouter>,
    )

    expect(screen.getByTestId('callback-loading')).toBeInTheDocument()
  })

  it('navigates to returnTo URL on successful authentication and clears storage', () => {
    localStorage.setItem('signalloom-return-to', '/topology')
    sessionStorage.setItem('signalloom:logged-out', 'true')
    mockAuthState.isAuthenticated = true

    render(
      <MemoryRouter>
        <CallbackPage />
      </MemoryRouter>,
    )

    expect(mockNavigate).toHaveBeenCalledWith('/topology', { replace: true })
    expect(localStorage.getItem('signalloom-return-to')).toBeNull()
    expect(sessionStorage.getItem('signalloom:logged-out')).toBeNull()
  })

  it('defaults to /agents if no returnTo was stored', () => {
    mockAuthState.isAuthenticated = true

    render(
      <MemoryRouter>
        <CallbackPage />
      </MemoryRouter>,
    )

    expect(mockNavigate).toHaveBeenCalledWith('/agents', { replace: true })
  })

  it('renders friendly error card and retry actions when error occurs', () => {
    mockAuthState.error = new Error('Invalid state parameter in response')

    render(
      <MemoryRouter>
        <CallbackPage />
      </MemoryRouter>,
    )

    expect(screen.getByText('Authentication Error')).toBeInTheDocument()
    expect(screen.getByText('Invalid state parameter in response')).toBeInTheDocument()
    const retryBtn = screen.getByTestId('callback-retry-btn')
    expect(retryBtn).toBeInTheDocument()

    fireEvent.click(retryBtn)
    expect(mockSigninRedirect).toHaveBeenCalledWith({ extraQueryParams: { prompt: 'login' } })
  })
})
