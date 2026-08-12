import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ThemeToggle } from '../components/ThemeToggle'
import { PreferencesProvider, preferenceKeys } from './preferences'

describe('design demo preferences', () => {
  beforeEach(() => window.localStorage.clear())
  afterEach(cleanup)

  it('defaults to dark and persists a light theme selection', async () => {
    const user = userEvent.setup()
    const { unmount } = render(<PreferencesProvider><ThemeToggle /></PreferencesProvider>)
    expect(document.documentElement).toHaveAttribute('data-theme', 'dark')
    await user.click(screen.getByTestId('theme-toggle'))
    expect(document.documentElement).toHaveAttribute('data-theme', 'light')
    expect(window.localStorage.getItem(preferenceKeys.theme)).toBe('light')
    unmount()
    render(<PreferencesProvider><ThemeToggle /></PreferencesProvider>)
    expect(document.documentElement).toHaveAttribute('data-theme', 'light')
  })

  it('exposes the next theme through an accessible label', async () => {
    const user = userEvent.setup()
    render(<PreferencesProvider><ThemeToggle /></PreferencesProvider>)
    const button = screen.getByRole('button', { name: 'Switch to light theme' })
    await user.click(button)
    expect(screen.getByRole('button', { name: 'Switch to dark theme' })).toHaveAttribute('aria-pressed', 'true')
  })
})
