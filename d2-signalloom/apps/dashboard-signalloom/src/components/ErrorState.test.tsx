import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import ErrorState, { isAuthError } from './ErrorState'

// A 401 is the one failure where Retry CANNOT work: the request was rejected
// before anything was attempted, so repeating it unchanged reproduces the same
// rejection. Offering Retry there teaches the operator the app is flaky when
// their session has simply expired.

describe('recognising an auth failure', () => {
  it('matches the message axios actually throws', () => {
    expect(isAuthError('Request failed with status code 401')).toBe(true)
  })

  it('matches the spellings this app renders itself', () => {
    expect(isAuthError('Evidence unavailable (HTTP 401)')).toBe(true)
    expect(isAuthError('401 Unauthorized')).toBe(true)
    expect(isAuthError('{"code":"authentication_required"}')).toBe(true)
  })

  it('does not treat other failures as auth failures', () => {
    expect(isAuthError('Request failed with status code 500')).toBe(false)
    expect(isAuthError('Request failed with status code 404')).toBe(false)
    expect(isAuthError('Network Error')).toBe(false)
  })

  it('does not fire on a number that merely contains 401', () => {
    // The reason the patterns are specific rather than a bare /401/.
    expect(isAuthError('401 roles scanned')).toBe(false)
    expect(isAuthError('Imported 4013 bindings')).toBe(false)
  })
})

describe('what the operator is offered', () => {
  it('offers Log in — not Retry — on a 401', async () => {
    const onRetry = vi.fn()
    const onLogin = vi.fn()
    render(<ErrorState message="Request failed with status code 401" onRetry={onRetry} onLogin={onLogin} />)

    expect(screen.getByTestId('error-login')).toHaveTextContent('Log in')
    expect(screen.queryByTestId('error-retry')).not.toBeInTheDocument()

    await userEvent.click(screen.getByTestId('error-login'))
    expect(onLogin).toHaveBeenCalledTimes(1)
    expect(onRetry).not.toHaveBeenCalled()
  })

  it('still offers Retry for a failure a retry could actually fix', async () => {
    const onRetry = vi.fn()
    render(<ErrorState message="Request failed with status code 500" onRetry={onRetry} />)

    expect(screen.getByTestId('error-retry')).toHaveTextContent('Retry')
    expect(screen.queryByTestId('error-login')).not.toBeInTheDocument()
    await userEvent.click(screen.getByTestId('error-retry'))
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it('offers Log in on a 401 even when the caller passed no onRetry', () => {
    render(<ErrorState message="Request failed with status code 401" />)
    expect(screen.getByTestId('error-login')).toBeInTheDocument()
  })

  it('stops saying "Failed to load" when nothing failed to load', () => {
    render(<ErrorState message="Request failed with status code 401" onLogin={vi.fn()} />)
    expect(screen.queryByText('Failed to load')).not.toBeInTheDocument()
    expect(screen.getByText(/session has expired/i)).toBeInTheDocument()
  })

  it('keeps the raw message reachable for an engineer', () => {
    render(<ErrorState message="Request failed with status code 401" onLogin={vi.fn()} />)
    expect(screen.getByTitle('Request failed with status code 401')).toBeInTheDocument()
  })

  it('renders without an auth provider, using its own redirect', async () => {
    // ErrorState is deliberately presentational — it must not require the auth
    // context, because it is rendered in isolation in several suites.
    const assign = vi.fn()
    const originalLocation = window.location
    const originalStorage = window.localStorage
    Object.defineProperty(window, 'location', {
      configurable: true,
      value: { ...originalLocation, assign },
    })

    // This suite's environment does not provide a working localStorage, so
    // stand one up rather than assert against a stub that silently no-ops.
    const store = new Map<string, string>([['oidc.user:https://x/dex:client', '{"access_token":"stale"}']])
    Object.defineProperty(window, 'localStorage', {
      configurable: true,
      value: {
        get length() { return store.size },
        key: (i: number) => [...store.keys()][i] ?? null,
        getItem: (k: string) => store.get(k) ?? null,
        setItem: (k: string, v: string) => { store.set(k, v) },
        removeItem: (k: string) => { store.delete(k) },
        clear: () => { store.clear() },
      },
    })

    render(<ErrorState message="Request failed with status code 401" />)
    await userEvent.click(screen.getByTestId('error-login'))

    // The stale user must go first, or AutoSignIn sees a session and never
    // redirects to Dex.
    expect(store.has('oidc.user:https://x/dex:client')).toBe(false)
    expect(assign).toHaveBeenCalledWith('/')

    Object.defineProperty(window, 'location', { configurable: true, value: originalLocation })
    Object.defineProperty(window, 'localStorage', { configurable: true, value: originalStorage })
  })
})
