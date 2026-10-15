import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import FindingsList from './FindingsList'
import type { PolicyFinding } from '../../api/policyApi'

const FINDING: PolicyFinding = {
  id: 'finding-1',
  timestamp: '2026-10-13T20:04:12Z',
  tenant_id: 'tenant-a',
  actor: 'agent-ci-runner',
  layer: 'identity_authorization',
  source_observation_id: 'observation-1',
  rule_id: 'unexpected-role-binding',
  bundle_id: 'signal-loom-defaults',
  bundle_version: '1.4.2',
  severity: 'high',
  mode: 'enforce',
  labels: { namespace: 'ci' },
}

describe('FindingsList', () => {
  // jev browser loop, /design-system: LAYOUT_OVERFLOW 66px on findings-list.
  // In a narrow card the eight-column table is wider than its container and
  // `overflow: hidden` clipped the trailing "Source signal" column — the link
  // back to the observation that raised the finding. jsdom does no layout, so
  // the contract pinned is the container's horizontal overflow mode.
  it('scrolls a too-wide findings table horizontally instead of clipping its last column', () => {
    render(<FindingsList findings={[FINDING]} />)
    const card = screen.getByTestId('findings-list')
    expect(card.style.overflowX).toBe('auto')
    expect(card.style.overflow).not.toBe('hidden')
    expect(screen.getByTestId('finding-observation-link')).toHaveAttribute('href', '#observation-observation-1')
  })
})
