import { describe, it, expect } from 'vitest'
import { render, screen, fireEvent, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { CompactInventorySpecimen } from './CompactInventorySpecimen'
import { COMPONENT_COVERAGE } from './componentCoverage'

describe('compact inventory specimen', () => {
  it('uses the live row components for normal, unknown, unconfirmed and critical evidence', () => {
    render(<MemoryRouter><CompactInventorySpecimen /></MemoryRouter>)
    const region = screen.getByRole('region', { name: 'Compact operational inventory specimen' })
    expect(region.querySelectorAll('thead th')).toHaveLength(8)
    expect(region.querySelectorAll('tbody')).toHaveLength(4)
    expect(within(region).getByTestId('kernel-telemetry-unconfirmed-specimen-unconfirmed')).toBeVisible()
    expect(within(region).getByTestId('kernel-state-badge-specimen-critical')).toHaveTextContent('Frozen · no stun')
    fireEvent.focus(within(region).getByRole('button', { name: /Agent details for Long/ }))
    expect(screen.getByRole('tooltip')).toHaveTextContent('Long operational agent name')
    expect(screen.getByRole('tooltip')).toHaveTextContent('tenant-gallery')
  })

  it('records fixture representation for the shared components, rather than inventing a copied table', () => {
    for (const name of ['CompactOperationalTable', 'CompactDisclosure', 'CompactEmail', 'CompactObservedTime']) {
      expect(COMPONENT_COVERAGE.find(entry => entry.symbol === name)?.kind).toBe('specimen')
    }
  })
})
