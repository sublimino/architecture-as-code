import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import HelpHint from './HelpHint'

describe('HelpHint', () => {
  it('shows its explanation on hover and keyboard focus', async () => {
    const user = userEvent.setup()
    render(<HelpHint label="Explain current data">Refreshes current data.</HelpHint>)

    const control = screen.getByRole('button', { name: 'Explain current data' })
    await user.hover(control)
    expect(screen.getByRole('tooltip')).toHaveTextContent('Refreshes current data.')

    await user.unhover(control)
    await user.tab()
    expect(screen.getByRole('tooltip')).toHaveTextContent('Refreshes current data.')
  })
})
