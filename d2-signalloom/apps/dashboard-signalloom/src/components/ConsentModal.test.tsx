/**
 * ConsentModal smoke tests — Vitest + Testing Library
 *
 * Covers:
 *  1. Modal renders title, three doc tabs, cookie panel, warranty checkbox
 *  2. Accept button starts disabled
 *  3. Scrolling all three docs via postMessage doesn't enable button (checkbox needed)
 *  4. Warranty checkbox alone doesn't enable button (scrolling needed)
 *  5. All docs scrolled + checkbox checked → button enabled
 *  6. onAccept called with cookie preferences when Accept clicked
 *  7. Analytics checkbox state propagated to onAccept
 *  8. Escape key does not close modal
 *  9. Error shown when onAccept rejects
 * 10. Duplicate scroll postMessages are idempotent
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ConsentModal from './ConsentModal'
import type { CookiePreferences } from '../types/api'

const fireScrollMessage = (doc: 'terms' | 'privacy' | 'eula') => {
  act(() => {
    window.dispatchEvent(
      new MessageEvent('message', {
        data: { type: 'sl-legal-scrolled', doc },
        origin: '*',
      })
    )
  })
}

const scrollAll = () => {
  fireScrollMessage('terms')
  fireScrollMessage('privacy')
  fireScrollMessage('eula')
}

describe('ConsentModal', () => {
  let onAccept: ReturnType<typeof vi.fn>

  beforeEach(() => {
    onAccept = vi.fn().mockResolvedValue(undefined)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('renders the welcome title', () => {
    render(<ConsentModal onAccept={onAccept} />)
    expect(screen.getByText(/Welcome to Signal Loom/i)).toBeInTheDocument()
  })

  it('renders all three legal document tabs', () => {
    render(<ConsentModal onAccept={onAccept} />)
    expect(screen.getByText(/Terms of Service/i)).toBeInTheDocument()
    expect(screen.getByText(/Privacy Policy/i)).toBeInTheDocument()
    expect(screen.getByText(/EULA/i)).toBeInTheDocument()
  })

  it('renders cookie preferences panel with strictly necessary locked', () => {
    render(<ConsentModal onAccept={onAccept} />)
    expect(screen.getByText(/Cookie preferences/i)).toBeInTheDocument()
    expect(screen.getByText(/Strictly necessary/i)).toBeInTheDocument()

    const locked = screen.getByLabelText(/Strictly necessary cookies — always on/i)
    expect(locked).toBeChecked()
    expect(locked).toBeDisabled()
  })

  it('renders analytics checkbox unchecked by default (GDPR opt-in)', () => {
    render(<ConsentModal onAccept={onAccept} />)
    const analytics = screen.getByLabelText(/Allow non-essential analytics/i)
    expect(analytics).not.toBeChecked()
    expect(analytics).not.toBeDisabled()
  })

  it('renders authority warranty checkbox unchecked', () => {
    render(<ConsentModal onAccept={onAccept} />)
    // The warranty checkbox is the only non-disabled unchecked checkbox initially
    const warrantyBox = screen.getByRole('checkbox', { name: /authorized to bind my organization/i })
    expect(warrantyBox).not.toBeChecked()
  })

  it('Accept button is disabled on initial render', () => {
    render(<ConsentModal onAccept={onAccept} />)
    expect(screen.getByRole('button', { name: /accept/i })).toBeDisabled()
  })

  it('warranty checkbox alone does not enable Accept', async () => {
    const user = userEvent.setup()
    render(<ConsentModal onAccept={onAccept} />)
    await user.click(screen.getByRole('checkbox', { name: /authorized to bind/i }))
    expect(screen.getByRole('button', { name: /accept/i })).toBeDisabled()
  })

  it('scrolling all three docs alone does not enable Accept', () => {
    render(<ConsentModal onAccept={onAccept} />)
    scrollAll()
    expect(screen.getByRole('button', { name: /accept/i })).toBeDisabled()
  })

  it('enables Accept after all docs scrolled AND warranty checkbox checked', async () => {
    const user = userEvent.setup()
    render(<ConsentModal onAccept={onAccept} />)
    scrollAll()
    await user.click(screen.getByRole('checkbox', { name: /authorized to bind/i }))
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /accept/i })).not.toBeDisabled()
    )
  })

  it('calls onAccept with default (analytics=false) cookie prefs when accepted', async () => {
    const user = userEvent.setup()
    render(<ConsentModal onAccept={onAccept} />)
    scrollAll()
    await user.click(screen.getByRole('checkbox', { name: /authorized to bind/i }))
    await waitFor(() => expect(screen.getByRole('button', { name: /accept/i })).not.toBeDisabled())
    await user.click(screen.getByRole('button', { name: /accept/i }))

    expect(onAccept).toHaveBeenCalledOnce()
    const prefs: CookiePreferences = onAccept.mock.calls[0][0]
    expect(prefs.strictly_necessary).toBe(true)
    expect(prefs.analytics).toBe(false)
  })

  it('propagates analytics=true when user opts in', async () => {
    const user = userEvent.setup()
    render(<ConsentModal onAccept={onAccept} />)
    scrollAll()
    await user.click(screen.getByLabelText(/Allow non-essential analytics/i))
    await user.click(screen.getByRole('checkbox', { name: /authorized to bind/i }))
    await waitFor(() => expect(screen.getByRole('button', { name: /accept/i })).not.toBeDisabled())
    await user.click(screen.getByRole('button', { name: /accept/i }))

    const prefs: CookiePreferences = onAccept.mock.calls[0][0]
    expect(prefs.analytics).toBe(true)
  })

  it('shows saving state while onAccept is pending', async () => {
    let resolve: () => void
    const slowAccept = vi.fn(() => new Promise<void>(r => { resolve = r }))
    const user = userEvent.setup()
    render(<ConsentModal onAccept={slowAccept} />)
    scrollAll()
    await user.click(screen.getByRole('checkbox', { name: /authorized to bind/i }))
    await waitFor(() => expect(screen.getByRole('button', { name: /accept/i })).not.toBeDisabled())
    await user.click(screen.getByRole('button', { name: /accept/i }))

    expect(screen.getByRole('button', { name: /saving/i })).toBeInTheDocument()
    act(() => resolve())
  })

  it('Escape key does not close the modal', async () => {
    const user = userEvent.setup()
    render(<ConsentModal onAccept={onAccept} />)
    await user.keyboard('{Escape}')
    expect(screen.getByRole('dialog')).toBeInTheDocument()
  })

  it('shows error when onAccept rejects', async () => {
    const failingAccept = vi.fn().mockRejectedValue(new Error('network'))
    const user = userEvent.setup()
    render(<ConsentModal onAccept={failingAccept} />)
    scrollAll()
    await user.click(screen.getByRole('checkbox', { name: /authorized to bind/i }))
    await waitFor(() => expect(screen.getByRole('button', { name: /accept/i })).not.toBeDisabled())
    await user.click(screen.getByRole('button', { name: /accept/i }))
    await waitFor(() =>
      expect(screen.getByText(/failed to record acceptance/i)).toBeInTheDocument()
    )
  })

  it('duplicate scroll postMessages for same doc are idempotent', () => {
    render(<ConsentModal onAccept={onAccept} />)
    fireScrollMessage('terms')
    fireScrollMessage('terms')
    // Still need privacy + eula + checkbox — button still disabled
    expect(screen.getByRole('button', { name: /accept/i })).toBeDisabled()
  })
})
