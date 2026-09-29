import { describe, it, expect } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import { PlaneOutcomeTable, PlaneStrip, StunOverallHeadline, summariseDetails } from './StunPlanes'
import type { PlaneResult } from '../types/api'

const T = '2026-09-29T10:00:00Z'

// One plane per outcome class the contract names, plus an outcome the contract
// does not name, because the server is allowed to grow the vocabulary and the
// table must not paint an unknown word green.
const PLANES: PlaneResult[] = [
  { plane: 'freeze', outcome: 'contained', timestamp: T, latency_ms: 42, details: { cgroup: 'frozen' } },
  { plane: 'spire', outcome: 'partial', timestamp: T, latency_ms: 310, error: '1 of 2 SVIDs still within TTL' },
  { plane: 'bao', outcome: 'failed', timestamp: T, error: 'lease revoke returned 503' },
  { plane: 'gitops', outcome: 'not_found', timestamp: T },
  { plane: 'mesh', outcome: 'quarantined-ish', timestamp: T },
]

function row(plane: string) {
  return screen.getByTestId(`stun-plane-row-${plane}`)
}

function outcomeCell(plane: string) {
  return within(row(plane)).getByTestId(`stun-plane-outcome-${plane}`)
}

describe('PlaneOutcomeTable', () => {
  it('renders one row per plane, naming the plane and its outcome', () => {
    render(<PlaneOutcomeTable planes={PLANES} />)
    const body = screen.getByTestId('stun-plane-table').querySelector('tbody') as HTMLElement
    expect(body.querySelectorAll('tr')).toHaveLength(PLANES.length)
    expect(row('freeze')).toHaveTextContent('freeze')
    expect(outcomeCell('freeze')).toHaveTextContent('contained')
    expect(outcomeCell('spire')).toHaveTextContent('partial')
    expect(outcomeCell('bao')).toHaveTextContent('failed')
    expect(outcomeCell('gitops')).toHaveTextContent('not_found')
  })

  it('colour-codes contained green, partial amber, failed and not_found red', () => {
    render(<PlaneOutcomeTable planes={PLANES} />)
    expect(outcomeCell('freeze')).toHaveClass('stun-outcome--contained')
    expect(outcomeCell('freeze')).toHaveStyle({ color: 'var(--teal)' })
    expect(outcomeCell('spire')).toHaveClass('stun-outcome--partial')
    expect(outcomeCell('spire')).toHaveStyle({ color: 'var(--amber)' })
    expect(outcomeCell('bao')).toHaveClass('stun-outcome--failed')
    expect(outcomeCell('bao')).toHaveStyle({ color: 'var(--error)' })
    expect(outcomeCell('gitops')).toHaveClass('stun-outcome--failed')
    expect(outcomeCell('gitops')).toHaveStyle({ color: 'var(--error)' })
  })

  it('never paints an outcome it does not recognise as contained', () => {
    render(<PlaneOutcomeTable planes={PLANES} />)
    expect(outcomeCell('mesh')).toHaveTextContent('quarantined-ish')
    expect(outcomeCell('mesh')).toHaveClass('stun-outcome--unknown')
    expect(outcomeCell('mesh')).not.toHaveClass('stun-outcome--contained')
  })

  it('shows latency, error text and a one-line details summary', () => {
    render(<PlaneOutcomeTable planes={PLANES} />)
    expect(within(row('freeze')).getByTestId('stun-plane-latency-freeze')).toHaveTextContent('42 ms')
    expect(within(row('bao')).getByTestId('stun-plane-latency-bao')).toHaveTextContent('-')
    expect(within(row('bao')).getByTestId('stun-plane-error-bao')).toHaveTextContent('lease revoke returned 503')
    expect(within(row('freeze')).getByTestId('stun-plane-details-freeze')).toHaveTextContent('cgroup=frozen')
  })
})

describe('summariseDetails', () => {
  it('flattens to one line and caps the length', () => {
    expect(summariseDetails({ a: 1, b: 'x', c: { d: true } })).toBe('a=1, b=x, c={"d":true}')
    expect(summariseDetails(undefined)).toBe('')
    const long = summariseDetails({ k: 'y'.repeat(500) })
    expect(long.length).toBeLessThanOrEqual(120)
    expect(long).not.toContain('\n')
  })
})

describe('StunOverallHeadline', () => {
  it('reads partial as incomplete containment, never as success', () => {
    render(<StunOverallHeadline outcome="partial" />)
    const headline = screen.getByTestId('stun-overall-outcome')
    expect(headline).toHaveTextContent(/partial/i)
    expect(headline).toHaveClass('stun-outcome--partial')
    expect(headline).not.toHaveClass('stun-outcome--contained')
    expect(headline).not.toHaveTextContent(/stunned|contained|revoked|success/i)
  })

  it('reads contained as contained', () => {
    render(<StunOverallHeadline outcome="contained" />)
    expect(screen.getByTestId('stun-overall-outcome')).toHaveClass('stun-outcome--contained')
    expect(screen.getByTestId('stun-overall-outcome')).toHaveTextContent(/contained/i)
  })

  it('reads failed and simulated as what they are', () => {
    const { unmount } = render(<StunOverallHeadline outcome="failed" />)
    expect(screen.getByTestId('stun-overall-outcome')).toHaveClass('stun-outcome--failed')
    unmount()
    render(<StunOverallHeadline outcome="simulated" />)
    expect(screen.getByTestId('stun-overall-outcome')).toHaveClass('stun-outcome--simulated')
    expect(screen.getByTestId('stun-overall-outcome')).toHaveTextContent(/simulated/i)
  })
})

describe('PlaneStrip', () => {
  it('lists every plane compactly with the same outcome classes', () => {
    render(<PlaneStrip planes={PLANES} testId="strip" />)
    const strip = screen.getByTestId('strip')
    expect(within(strip).getByTestId('strip-freeze')).toHaveTextContent('freeze: contained')
    expect(within(strip).getByTestId('strip-freeze')).toHaveClass('stun-outcome--contained')
    expect(within(strip).getByTestId('strip-spire')).toHaveClass('stun-outcome--partial')
    expect(within(strip).getByTestId('strip-gitops')).toHaveClass('stun-outcome--failed')
  })
})
