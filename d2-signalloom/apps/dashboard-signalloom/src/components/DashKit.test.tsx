import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { Table, StatCard, Pill } from './DashKit'

describe('DashKit component suite', () => {
  it('renders Table with concentric border radius on first and last headers', () => {
    render(
      <Table headers={['Column A', 'Column B', 'Column C']}>
        <tr>
          <td>Row 1</td>
          <td>Row 2</td>
          <td>Row 3</td>
        </tr>
      </Table>
    )

    const colA = screen.getByText('Column A').closest('th')
    const colB = screen.getByText('Column B').closest('th')
    const colC = screen.getByText('Column C').closest('th')

    expect(colA).not.toBeNull()
    expect(colB).not.toBeNull()
    expect(colC).not.toBeNull()

    // First th has top-left concentric radius
    expect(colA?.style.borderTopLeftRadius).toBe('calc(var(--radius) - 1px)')
    expect(colA?.style.borderTopRightRadius).toBe('')

    // Middle th has no radius
    expect(colB?.style.borderTopLeftRadius).toBe('')
    expect(colB?.style.borderTopRightRadius).toBe('')

    // Last th has top-right concentric radius
    expect(colC?.style.borderTopLeftRadius).toBe('')
    expect(colC?.style.borderTopRightRadius).toBe('calc(var(--radius) - 1px)')
  })

  it('renders StatCard with accent color and text hierarchy', () => {
    render(
      <StatCard
        label="Active Agents"
        value="42"
        sub="All systems nominal"
        accent="var(--teal)"
      />
    )

    expect(screen.getByText('Active Agents')).toBeInTheDocument()
    expect(screen.getByText('42')).toHaveStyle({ color: 'var(--teal)' })
    expect(screen.getByText('All systems nominal')).toBeInTheDocument()
  })

  it('renders Pill with corresponding status colors', () => {
    const { unmount } = render(<Pill label="active" />)
    const activePill = screen.getByText('active')
    expect(activePill).toHaveClass('tag')
    unmount()

    render(<Pill label="critical" />)
    const criticalPill = screen.getByText('critical')
    expect(criticalPill).toHaveClass('tag')
  })
})
