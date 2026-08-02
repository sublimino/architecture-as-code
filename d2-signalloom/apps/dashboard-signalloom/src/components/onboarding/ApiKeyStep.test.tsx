import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import ApiKeyStep from './ApiKeyStep'

describe('ApiKeyStep', () => {
  it('does not reveal until the user confirms — reveal requires two clicks', () => {
    const onReveal = vi.fn()
    render(
      <ApiKeyStep
        revealed={null}
        revealing={false}
        onReveal={onReveal}
        onContinue={vi.fn()}
        onBack={vi.fn()}
      />,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Reveal my API key' }))
    expect(onReveal).not.toHaveBeenCalled()
    expect(screen.getByText(/only time you'll be able to see this key/i)).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Yes, reveal it' }))
    expect(onReveal).toHaveBeenCalledOnce()
  })

  it('"Never mind" backs out of the confirm step without revealing', () => {
    const onReveal = vi.fn()
    render(
      <ApiKeyStep
        revealed={null}
        revealing={false}
        onReveal={onReveal}
        onContinue={vi.fn()}
        onBack={vi.fn()}
      />,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Reveal my API key' }))
    fireEvent.click(screen.getByRole('button', { name: 'Never mind' }))

    expect(onReveal).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: 'Reveal my API key' })).toBeInTheDocument()
  })

  it('opting out via "I\'ll do this later" calls onContinue without revealing', () => {
    const onReveal = vi.fn()
    const onContinue = vi.fn()
    render(
      <ApiKeyStep
        revealed={null}
        revealing={false}
        onReveal={onReveal}
        onContinue={onContinue}
        onBack={vi.fn()}
      />,
    )

    fireEvent.click(screen.getByRole('button', { name: "I'll do this later" }))
    expect(onReveal).not.toHaveBeenCalled()
    expect(onContinue).toHaveBeenCalledOnce()
    expect(screen.getByText(/reveal it later from Settings/i)).toBeInTheDocument()
  })

  it('shows the key once revealed, with a Continue button', () => {
    const onContinue = vi.fn()
    render(
      <ApiKeyStep
        revealed={{ key: 'sl_live_abc123', prefix_hint: 'sl_live_' }}
        revealing={false}
        onReveal={vi.fn()}
        onContinue={onContinue}
        onBack={vi.fn()}
      />,
    )

    expect(screen.getByText('sl_live_abc123')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Continue' }))
    expect(onContinue).toHaveBeenCalledOnce()
  })

  it('shows an error message from a failed reveal attempt', () => {
    render(
      <ApiKeyStep
        revealed={null}
        revealing={false}
        error="This key was already revealed once — you can rotate it anytime from Settings → API Access."
        onReveal={vi.fn()}
        onContinue={vi.fn()}
        onBack={vi.fn()}
      />,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Reveal my API key' }))
    expect(screen.getByText(/already revealed once/i)).toBeInTheDocument()
  })
})
