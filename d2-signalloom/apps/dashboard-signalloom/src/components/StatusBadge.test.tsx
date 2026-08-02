import { describe, it, expect } from 'vitest'
import { render } from '@testing-library/react'
import StatusBadge, { getStatusColor } from './StatusBadge'

describe('StatusBadge', () => {
  it('resolves lifecycle "active" to the teal token, not a hardcoded hex', () => {
    const { color, bg, border } = getStatusColor('active', 'lifecycle')
    expect(color).toBe('var(--teal)')
    expect(bg).toContain('var(--teal)')
    expect(border).toContain('var(--teal)')
  })

  it('resolves risk "high_risk" to the amber token', () => {
    const { color, bg } = getStatusColor('high_risk', 'risk')
    expect(color).toBe('var(--amber)')
    expect(bg).toContain('var(--amber)')
  })

  it('falls back to the neutral token for an unrecognized status', () => {
    const { color } = getStatusColor('totally_unknown')
    expect(color).toBe('var(--muted)')
  })

  it('renders the status text with underscores replaced by spaces', () => {
    const { getByText } = render(<StatusBadge status="high_risk" variant="risk" />)
    expect(getByText('high risk')).toBeTruthy()
  })
})
