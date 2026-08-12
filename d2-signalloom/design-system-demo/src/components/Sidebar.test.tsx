import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { PreferencesProvider, preferenceKeys } from '../state/preferences'
import { Sidebar } from './Sidebar'

function renderSidebar(route = '/') {
  return render(<MemoryRouter initialEntries={[route]} future={{ v7_startTransition: true, v7_relativeSplatPath: true }}><PreferencesProvider><Sidebar /></PreferencesProvider></MemoryRouter>)
}

describe('Sidebar', () => {
  beforeEach(() => window.localStorage.clear())
  afterEach(cleanup)

  it('renders grouped core navigation and marks the current destination', () => {
    renderSidebar('/agents')
    expect(screen.getByRole('heading', { name: 'Estate' })).toBeVisible()
    expect(screen.getByRole('heading', { name: 'Assurance' })).toBeVisible()
    expect(screen.getByRole('link', { name: /Agent health/ })).toHaveClass('nav-item--active')
    expect(screen.getByRole('link', { name: /Controls & evidence/ })).toBeVisible()
  })

  it('defaults superadmin off then reveals specialist destinations immediately', async () => {
    const user = userEvent.setup()
    renderSidebar()
    expect(screen.queryByRole('link', { name: /Permission findings/ })).not.toBeInTheDocument()
    await user.click(screen.getByTestId('superadmin-toggle'))
    expect(screen.getByRole('link', { name: /Permission findings/ })).toBeVisible()
    expect(screen.getByRole('link', { name: /Risky access paths/ })).toBeVisible()
    expect(window.localStorage.getItem(preferenceKeys.superadmin)).toBe('true')
  })

  it('restores superadmin visibility from the existing storage key', () => {
    window.localStorage.setItem(preferenceKeys.superadmin, 'true')
    renderSidebar()
    expect(screen.getByRole('link', { name: /Credential lifecycle/ })).toBeVisible()
  })

  it('opens mobile navigation as a labelled modal surface', async () => {
    const user = userEvent.setup()
    renderSidebar()
    await user.click(screen.getByRole('button', { name: 'Open navigation' }))
    expect(screen.getByRole('dialog', { name: 'Primary navigation' })).toHaveAttribute('aria-modal', 'true')
    expect(screen.getByRole('button', { name: 'Close navigation' })).toHaveFocus()
  })
})
