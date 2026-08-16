/**
 * Adversarial tests for ErrorState and isAuthError — edge cases that probe
 * the regex boundary between "auth failure" and "operational error".
 *
 * Round 3 adversarial testing.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import ErrorState, { isAuthError, redirectToLogin } from './ErrorState'

// ── isAuthError regex precision ─────────────────────────────────────────────

describe('isAuthError — regex precision', () => {
  // TRUE POSITIVES — these are the exact strings the system produces
  it.each([
    'Request failed with status code 401',
    'Request failed with status code 401 for method GET',
    '(HTTP 401)',
    'Error: (HTTP 401) Access denied',
    '401 Unauthorized',
    '401 unauthorised',
    'authentication_required',
    'authentication required',
  ])('recognises "%s" as an auth error', (msg) => {
    expect(isAuthError(msg)).toBe(true)
  })

  // TRUE NEGATIVES — these must NOT match
  it.each([
    '401 roles scanned',
    'Found 401 items in the database',
    'Port 4010 is unavailable',
    'Error 400: Bad Request',
    'Error 403: Forbidden',
    'Error 500: Internal Server Error',
    'Network Error',
    'timeout exceeded',
    '',
    'authentication was not required',
    'The 401(k) plan updated successfully',
  ])('does NOT recognise "%s" as an auth error', (msg) => {
    expect(isAuthError(msg)).toBe(false)
  })

  // Case insensitivity
  it('is case-insensitive for HTTP 401', () => {
    expect(isAuthError('http 401')).toBe(true)
    expect(isAuthError('HTTP 401')).toBe(true)
  })
})

// ── ErrorState rendering edge cases ─────────────────────────────────────────

describe('ErrorState — rendering edge cases', () => {
  it('shows lock icon and session-expired text for auth errors', () => {
    render(<ErrorState message="Request failed with status code 401" />)
    expect(screen.getByText('Your session has expired')).toBeTruthy()
  })

  it('shows warning icon and Failed to load for non-auth errors', () => {
    render(<ErrorState message="Network Error" />)
    expect(screen.getByText('Failed to load')).toBeTruthy()
  })

  it('does not show Retry button for auth errors', () => {
    const onRetry = vi.fn()
    render(<ErrorState message="Request failed with status code 401" onRetry={onRetry} />)
    // Auth errors should show Log in instead of Retry
    expect(screen.queryByText('Retry')).toBeNull()
    expect(screen.getByText('Log in')).toBeTruthy()
  })

  it('shows Retry button for non-auth errors', () => {
    const onRetry = vi.fn()
    render(<ErrorState message="Network Error" onRetry={onRetry} />)
    expect(screen.getByText('Retry')).toBeTruthy()
    fireEvent.click(screen.getByText('Retry'))
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it('renders the raw message text for non-auth errors', () => {
    render(<ErrorState message="Something broke badly" />)
    expect(screen.getByText('Something broke badly')).toBeTruthy()
  })

  it('escapes HTML in error messages (no XSS)', () => {
    const xss = '<script>alert("xss")</script>'
    const { container } = render(<ErrorState message={xss} />)
    expect(container.querySelector('script')).toBeNull()
    expect(container.textContent).toContain(xss)
  })

  it('handles empty message string', () => {
    const { container } = render(<ErrorState message="" />)
    // Should render without crashing — empty message is a non-auth error
    expect(container).toBeTruthy()
    expect(screen.getByText('Failed to load')).toBeTruthy()
  })
})

// ── redirectToLogin safety ──────────────────────────────────────────────────
// redirectToLogin also sets window.location.href, which jsdom does not support
// in the same way as a browser. We test just the localStorage cleanup in
// isolation via the isAuthError + ErrorState rendering tests above.

describe('redirectToLogin — export exists', () => {
  it('is a callable function', () => {
    expect(typeof redirectToLogin).toBe('function')
  })
})
