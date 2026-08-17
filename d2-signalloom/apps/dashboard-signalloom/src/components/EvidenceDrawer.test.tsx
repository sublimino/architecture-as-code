/**
 * Tests for EvidenceDrawer component.
 */
import { describe, expect, it, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import EvidenceDrawer from './EvidenceDrawer'
import { fakeWeaveData } from '../api/fakeWeaveData'

const actor = fakeWeaveData.actors[0] // Shadow LLM Proxy — actionable, 8 evidence items

describe('EvidenceDrawer', () => {
  it('renders nothing when actor is null', () => {
    const { container } = render(<EvidenceDrawer actor={null} onClose={vi.fn()} />)
    expect(container.innerHTML).toBe('')
  })

  it('renders the actor display name', () => {
    render(<EvidenceDrawer actor={actor} onClose={vi.fn()} />)
    expect(screen.getByText('Shadow LLM Proxy')).toBeInTheDocument()
  })

  it('renders all evidence items', () => {
    render(<EvidenceDrawer actor={actor} onClose={vi.fn()} />)
    const items = screen.getAllByTestId('evidence-item')
    expect(items.length).toBe(actor.evidence_chain.length)
  })

  it('displays the confidence percentage', () => {
    render(<EvidenceDrawer actor={actor} onClose={vi.fn()} />)
    const pct = Math.round(actor.confidence * 100)
    expect(screen.getByText(`${pct}%`)).toBeInTheDocument()
  })

  it('orders evidence by timestamp', () => {
    render(<EvidenceDrawer actor={actor} onClose={vi.fn()} />)
    const items = screen.getAllByTestId('evidence-item')
    const timestamps = items.map((el) => {
      // Each item shows the time — extract text content from the contribution lines
      return el.textContent ?? ''
    })
    // The first item's contribution should be from the earliest observation
    expect(timestamps[0]).toContain('Unregistered service account')
  })

  it('calls onClose when close button is clicked', async () => {
    const onClose = vi.fn()
    render(<EvidenceDrawer actor={actor} onClose={onClose} />)
    await userEvent.click(screen.getByTestId('evidence-drawer-close'))
    expect(onClose).toHaveBeenCalledOnce()
  })

  it('shows the layer count in the subtitle', () => {
    render(<EvidenceDrawer actor={actor} onClose={vi.fn()} />)
    const layers = new Set(actor.evidence_chain.map((e) => e.layer))
    expect(screen.getByText(new RegExp(`${layers.size} layers`))).toBeInTheDocument()
  })

  it('shows definitive signal count in confidence section', () => {
    render(<EvidenceDrawer actor={actor} onClose={vi.fn()} />)
    const definitiveCount = actor.evidence_chain.filter((e) => e.fidelity === 'definitive').length
    if (definitiveCount > 0) {
      expect(screen.getByText(new RegExp(`${definitiveCount} definitive`))).toBeInTheDocument()
    }
  })
})
