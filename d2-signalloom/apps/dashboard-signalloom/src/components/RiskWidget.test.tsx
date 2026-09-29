import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, it, expect, vi } from 'vitest'
import RiskWidget, { formatFrequency, formatTriple, SourceBadge } from './RiskWidget'
import type { FairTriple } from '../types/fair'

describe('RiskWidget Component', () => {
  const sampleTriple: FairTriple = { min: 0.01, mode: 0.05, max: 0.2 }

  it('renders all quantitative risk metrics with live source badge', () => {
    render(
      <RiskWidget
        testId="drawer-section-risk"
        title="Quantitative Risk (OpenFAIR)"
        lef={sampleTriple}
        lossMagnitude={{ amount: 563520, currency: 'GBP' }}
        pml={{ amount: 51342162, currency: 'GBP' }}
        ale={{ amount: 21681338, currency: 'GBP' }}
        tvar={{ amount: 60172685, currency: 'GBP' }}
        source="riskctl"
        loading={false}
        error={null}
      />
    )

    expect(screen.getByTestId('drawer-section-risk')).toBeInTheDocument()
    expect(screen.getByText('Quantitative Risk (OpenFAIR)')).toBeInTheDocument()

    // Provenance badge
    const badge = screen.getByTestId('drawer-section-risk-source')
    expect(badge).toHaveTextContent('LIVE riskctl')

    // Metrics
    expect(screen.getByTestId('drawer-section-risk-lef')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-section-risk-lm')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-section-risk-pml')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-section-risk-ale')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-section-risk-tvar')).toBeInTheDocument()
  })

  it('renders demo source badge when source is fixture', () => {
    render(
      <RiskWidget
        testId="drawer-section-risk"
        title="Quantitative Risk (OpenFAIR)"
        lef={sampleTriple}
        lossMagnitude={{ amount: 10000, currency: 'GBP' }}
        pml={{ amount: 50000, currency: 'GBP' }}
        ale={{ amount: 12000, currency: 'GBP' }}
        source="fixture"
        loading={false}
        error={null}
      />
    )

    const badge = screen.getByTestId('drawer-section-risk-source')
    expect(badge).toHaveTextContent('DEMO fixture')
  })

  it('renders loading state with placeholder indicators', () => {
    render(
      <RiskWidget
        testId="drawer-section-risk"
        title="Quantitative Risk (OpenFAIR)"
        lef={null}
        lossMagnitude={null}
        pml={null}
        ale={null}
        source="riskctl"
        loading={true}
        error={null}
      />
    )

    const widget = screen.getByTestId('drawer-section-risk')
    expect(widget).toHaveAttribute('data-loading', 'true')
    expect(screen.getByTestId('drawer-section-risk-ale-value')).toHaveTextContent('…')
  })

  it('renders error state and handles onRetry callback', async () => {
    const onRetry = vi.fn()
    render(
      <RiskWidget
        testId="drawer-section-risk"
        title="Quantitative Risk (OpenFAIR)"
        lef={null}
        lossMagnitude={null}
        pml={null}
        ale={null}
        source="riskctl"
        loading={false}
        error="policy-engine returned unparseable JSON (status 404)"
        onRetry={onRetry}
      />
    )

    expect(screen.getByTestId('drawer-section-risk-error')).toBeInTheDocument()
    expect(screen.getByText(/policy-engine returned unparseable JSON/i)).toBeInTheDocument()

    const retryBtn = screen.getByRole('button', { name: /retry/i })
    await userEvent.click(retryBtn)
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it('formats frequency numbers and triples accurately without em-dashes', () => {
    expect(formatFrequency(0)).toBe('0')
    expect(formatFrequency(15.2)).toBe('15')
    expect(formatFrequency(3.45)).toBe('3.5')
    expect(formatFrequency(0.052)).toBe('0.052')

    const tripleStr = formatTriple({ min: 0.01, mode: 0.05, max: 0.2 })
    expect(tripleStr).toContain('0.01 to 0.2 /yr (mode 0.05)')
    expect(tripleStr).not.toContain('—')
    expect(tripleStr).not.toContain('–')
  })

  it('renders SourceBadge accessibility labels correctly', () => {
    const { rerender } = render(<SourceBadge source="riskctl" testId="source-badge" />)
    expect(screen.getByTestId('source-badge')).toHaveAttribute(
      'aria-label',
      'Data source: live riskctl computation'
    )

    rerender(<SourceBadge source="fixture" testId="source-badge" />)
    expect(screen.getByTestId('source-badge')).toHaveAttribute(
      'aria-label',
      'Data source: offline demo fixture, not a live computation'
    )
  })
})
