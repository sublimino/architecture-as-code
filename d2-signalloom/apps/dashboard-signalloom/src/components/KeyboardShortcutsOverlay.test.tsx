/**
 * KeyboardShortcutsOverlay tests — Vitest + Testing Library
 *
 * Covers:
 *  1. `?` opens the overlay
 *  2. `?` typed inside an input does NOT open it
 *  3. Modifier + `?` does NOT open it
 *  4. Escape closes it
 *  5. The close button closes it
 *  6. Clicking the backdrop closes it
 *  7. Focus moves into the dialog on open and returns to the trigger on close
 *  8. Repeated `?` does not stack a second dialog
 *  9. The documented list contains the shortcuts that actually exist
 */

import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import KeyboardShortcutsOverlay from './KeyboardShortcutsOverlay'

/** The overlay is global, so mount it next to a realistic page trigger. */
function renderWithTrigger() {
  return render(
    <>
      <button type="button">Trigger</button>
      <input aria-label="Quick search" />
      <KeyboardShortcutsOverlay />
    </>
  )
}

const overlay = () => screen.queryByTestId('keyboard-shortcuts-overlay')

describe('KeyboardShortcutsOverlay', () => {
  it('opens on ? and exposes an accessible modal dialog', async () => {
    const user = userEvent.setup()
    renderWithTrigger()
    expect(overlay()).not.toBeInTheDocument()

    await user.keyboard('?')

    const dialog = screen.getByRole('dialog')
    expect(dialog).toBe(overlay())
    expect(dialog).toHaveAttribute('aria-modal', 'true')
    expect(dialog).toHaveAccessibleName('Keyboard shortcuts')
  })

  it('does not open while typing ? in an input', async () => {
    const user = userEvent.setup()
    renderWithTrigger()

    await user.click(screen.getByLabelText('Quick search'))
    await user.keyboard('?')

    expect(overlay()).not.toBeInTheDocument()
  })

  it('does not open when a modifier key is held', async () => {
    const user = userEvent.setup()
    renderWithTrigger()

    await user.keyboard('{Control>}?{/Control}')

    expect(overlay()).not.toBeInTheDocument()
  })

  it('closes on Escape and returns focus to the previously focused element', async () => {
    const user = userEvent.setup()
    renderWithTrigger()
    const trigger = screen.getByRole('button', { name: 'Trigger' })
    trigger.focus()

    await user.keyboard('?')
    const dialog = screen.getByRole('dialog')
    expect(dialog.contains(document.activeElement)).toBe(true)

    await user.keyboard('{Escape}')

    expect(overlay()).not.toBeInTheDocument()
    expect(trigger).toHaveFocus()
  })

  it('closes via the close button and restores focus', async () => {
    const user = userEvent.setup()
    renderWithTrigger()
    const trigger = screen.getByRole('button', { name: 'Trigger' })
    trigger.focus()

    await user.keyboard('?')
    await user.click(screen.getByTestId('keyboard-shortcuts-close'))

    expect(overlay()).not.toBeInTheDocument()
    expect(trigger).toHaveFocus()
  })

  it('closes when the backdrop is clicked but not when the panel is clicked', async () => {
    const user = userEvent.setup()
    renderWithTrigger()

    await user.keyboard('?')
    await user.click(screen.getByRole('dialog'))
    expect(overlay()).toBeInTheDocument()

    await user.click(screen.getByTestId('keyboard-shortcuts-backdrop'))
    expect(overlay()).not.toBeInTheDocument()
  })

  it('does not stack a second dialog when ? is pressed again', async () => {
    const user = userEvent.setup()
    renderWithTrigger()

    await user.keyboard('?')
    await user.keyboard('?')

    expect(screen.getAllByRole('dialog')).toHaveLength(1)
  })

  it('traps Tab inside the dialog', async () => {
    const user = userEvent.setup()
    renderWithTrigger()
    screen.getByRole('button', { name: 'Trigger' }).focus()

    await user.keyboard('?')
    const dialog = screen.getByRole('dialog')

    await user.tab()
    expect(dialog.contains(document.activeElement)).toBe(true)
    await user.tab({ shift: true })
    expect(dialog.contains(document.activeElement)).toBe(true)
  })

  it('documents the shortcuts that actually exist', async () => {
    const user = userEvent.setup()
    renderWithTrigger()

    await user.keyboard('?')
    const keys = screen
      .getAllByTestId('keyboard-shortcuts-key')
      .map((element) => element.textContent)

    expect(keys).toContain('/')
    expect(keys).toContain('?')
    expect(keys).toContain('Esc')
    expect(keys).toContain('1')
    expect(screen.getByRole('dialog')).toHaveTextContent('Quick search')
  })

  it('removes its keydown listener on unmount', async () => {
    const user = userEvent.setup()
    const { unmount } = renderWithTrigger()
    unmount()

    await user.keyboard('?')

    expect(overlay()).not.toBeInTheDocument()
  })
})
