/**
 * Tests for SignalBadge — compact pill showing signal observation count
 * coloured by fidelity tier.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import SignalBadge from './SignalBadge'

describe('SignalBadge', () => {
  it('renders the observation count', () => {
    render(
      <SignalBadge
        observationCount={8}
        highestFidelity="definitive"
        layerCount={5}
        testId="badge"
      />,
    )
    expect(screen.getByTestId('badge')).toHaveTextContent('8 signals')
  })

  it('renders singular form for count of 1', () => {
    render(
      <SignalBadge
        observationCount={1}
        highestFidelity="strong"
        layerCount={1}
        testId="badge"
      />,
    )
    expect(screen.getByTestId('badge')).toHaveTextContent('1 signal')
  })

  it('shows tooltip with fidelity and layer count', () => {
    render(
      <SignalBadge
        observationCount={8}
        highestFidelity="definitive"
        layerCount={5}
        testId="badge"
      />,
    )
    const badge = screen.getByTestId('badge')
    expect(badge).toHaveAttribute(
      'title',
      '8 signal observations from 5 layers — highest fidelity: Definitive',
    )
  })

  it('includes actor status in tooltip when provided', () => {
    render(
      <SignalBadge
        observationCount={3}
        highestFidelity="strong"
        layerCount={2}
        actorStatus="actionable"
        testId="badge"
      />,
    )
    const badge = screen.getByTestId('badge')
    expect(badge.getAttribute('title')).toContain('Actor status: Actionable')
  })

  it('renders with suggestive fidelity', () => {
    render(
      <SignalBadge
        observationCount={2}
        highestFidelity="suggestive"
        layerCount={1}
        testId="badge"
      />,
    )
    expect(screen.getByTestId('badge').getAttribute('title')).toContain('Suggestive')
  })

  it('renders with circumstantial fidelity', () => {
    render(
      <SignalBadge
        observationCount={1}
        highestFidelity="circumstantial"
        testId="badge"
      />,
    )
    expect(screen.getByTestId('badge').getAttribute('title')).toContain('Circumstantial')
  })

  it('calls onClick when clicked', async () => {
    const onClick = vi.fn()
    render(
      <SignalBadge
        observationCount={5}
        highestFidelity="strong"
        onClick={onClick}
        testId="badge"
      />,
    )
    await userEvent.click(screen.getByTestId('badge'))
    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it('has role=button and tabIndex when onClick is provided', () => {
    render(
      <SignalBadge
        observationCount={5}
        highestFidelity="strong"
        onClick={() => {}}
        testId="badge"
      />,
    )
    const badge = screen.getByTestId('badge')
    expect(badge).toHaveAttribute('role', 'button')
    expect(badge).toHaveAttribute('tabIndex', '0')
  })

  it('does not have role=button when onClick is absent', () => {
    render(
      <SignalBadge
        observationCount={5}
        highestFidelity="strong"
        testId="badge"
      />,
    )
    const badge = screen.getByTestId('badge')
    expect(badge).not.toHaveAttribute('role')
  })
})
