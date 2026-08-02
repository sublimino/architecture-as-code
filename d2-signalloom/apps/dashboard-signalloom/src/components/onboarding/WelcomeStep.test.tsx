import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import WelcomeStep from './WelcomeStep'

describe('WelcomeStep', () => {
  it('shows the welcome heading and a tour of the main pages', () => {
    render(<WelcomeStep onContinue={vi.fn()} onOpenHelp={vi.fn()} />)
    expect(screen.getByRole('heading', { name: 'Welcome to Signal Loom' })).toBeInTheDocument()
    for (const page of ['Discovery', 'Agents', 'Compliance', 'Audit Trail', 'Settings']) {
      expect(screen.getByText(page)).toBeInTheDocument()
    }
  })

  it('calls onOpenHelp when the Help & FAQ link is clicked', () => {
    const onOpenHelp = vi.fn()
    render(<WelcomeStep onContinue={vi.fn()} onOpenHelp={onOpenHelp} />)
    fireEvent.click(screen.getByRole('button', { name: 'Open Help & FAQ' }))
    expect(onOpenHelp).toHaveBeenCalledOnce()
  })

  it('calls onContinue when "Get started" is clicked', () => {
    const onContinue = vi.fn()
    render(<WelcomeStep onContinue={onContinue} onOpenHelp={vi.fn()} />)
    fireEvent.click(screen.getByRole('button', { name: 'Get started' }))
    expect(onContinue).toHaveBeenCalledOnce()
  })
})
