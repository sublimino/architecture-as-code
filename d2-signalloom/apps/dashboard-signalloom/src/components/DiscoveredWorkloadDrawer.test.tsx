// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import DiscoveredWorkloadDrawer from './DiscoveredWorkloadDrawer'
import type { DiscoveryWorkload, AgentResponse } from '../types/api'

const mockWorkload: DiscoveryWorkload = {
  id: 'tenant-demo:nhi-1',
  name: 'svc-billing-sync',
  source: 'idp',
  source_label: 'Entra ID',
  namespace: 'identity-entra',
  status: 'discovered',
  owner: 'ops@signalloom.local',
  spiffe_id: 'spiffe://signalloom.svc.cluster.local/ns/identity-entra/sa/svc-billing-sync',
  model: 'gpt-4o',
  last_seen_at: '2026-07-27T10:00:00Z',
  recommendations: {
    config: 'warning',
    content: 'not_applicable',
    supply_chain: 'recommended',
    eu_ai_act: 'pass',
  },
  metadata: {
    privilege_level: 'high',
    findings: ['stale_credential', 'over_privileged'],
    scan_count: 3,
  },
}

const mockMatchedAgent: AgentResponse = {
  id: 'tenant-demo:agent-billing',
  name: 'billing-agent',
  type: 'Signal Loom Built',
  owner: 'demo-user',
  tenant_id: 'tenant-demo',
  lifecycle_state: 'active',
  created_at: '2026-07-20T10:00:00Z',
  last_transition_at: '2026-07-20T10:00:00Z',
  last_transition_by: 'demo-user',
  eu_ai_act_risk_class: 'minimal',
  compliance_summary: {
    total_controls: 12,
    passing: 12,
    failing: 0,
    pending: 0,
    posture_score: 1.0,
  },
}

describe('DiscoveredWorkloadDrawer', () => {
  it('renders nothing when isOpen is false', () => {
    const { container } = render(
      <MemoryRouter>
        <DiscoveredWorkloadDrawer
          isOpen={false}
          workload={mockWorkload}
          onClose={vi.fn()}
          onEnroll={vi.fn()}
          onDismiss={vi.fn()}
        />
      </MemoryRouter>,
    )
    expect(container).toBeEmptyDOMElement()
  })

  it('renders workload metadata, provenance, and 4-pillar recommendations', () => {
    render(
      <MemoryRouter>
        <DiscoveredWorkloadDrawer
          isOpen={true}
          workload={mockWorkload}
          onClose={vi.fn()}
          onEnroll={vi.fn()}
          onDismiss={vi.fn()}
        />
      </MemoryRouter>,
    )

    expect(screen.getByTestId('drawer-workload-name')).toHaveTextContent('svc-billing-sync')
    expect(screen.getByTestId('drawer-workload-source')).toHaveTextContent('Entra ID')
    expect(screen.getByTestId('drawer-workload-status')).toHaveTextContent('discovered')
    expect(screen.getByTestId('drawer-workload-id')).toHaveTextContent('tenant-demo:nhi-1')
    expect(screen.getByTestId('drawer-workload-namespace')).toHaveTextContent('identity-entra')
    expect(screen.getByTestId('drawer-workload-owner')).toHaveTextContent('ops@signalloom.local')
    expect(screen.getByTestId('drawer-workload-model')).toHaveTextContent('gpt-4o')
    expect(screen.getByTestId('drawer-workload-spiffe-id')).toHaveTextContent('spiffe://signalloom.svc.cluster.local/ns/identity-entra/sa/svc-billing-sync')
    expect(screen.getByTestId('drawer-privilege-level')).toHaveTextContent('high')

    // 4 pillars
    expect(screen.getByTestId('drawer-rec-config')).toHaveTextContent(/CFG.*Action Required/i)
    expect(screen.getByTestId('drawer-rec-content')).toHaveTextContent(/CNT.*N\/A/i)
    expect(screen.getByTestId('drawer-rec-supply_chain')).toHaveTextContent(/SC.*Review/i)
    expect(screen.getByTestId('drawer-rec-eu_ai_act')).toHaveTextContent(/EU.*Pass/i)

    // Security findings
    expect(screen.getByText(/stale_credential/)).toBeInTheDocument()
    expect(screen.getByText(/over_privileged/)).toBeInTheDocument()
  })

  it('renders matched agent dossier link when matchedAgent is provided', () => {
    render(
      <MemoryRouter>
        <DiscoveredWorkloadDrawer
          isOpen={true}
          workload={mockWorkload}
          matchedAgent={mockMatchedAgent}
          onClose={vi.fn()}
          onEnroll={vi.fn()}
          onDismiss={vi.fn()}
        />
      </MemoryRouter>,
    )

    expect(screen.getByTestId('drawer-matched-agent-card')).toBeInTheDocument()
    expect(screen.getByText('billing-agent')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-matched-agent-link')).toBeInTheDocument()
  })

  it('handles user actions: enroll, dismiss, claim, and close', async () => {
    const handleClose = vi.fn()
    const handleEnroll = vi.fn()
    const handleDismiss = vi.fn()
    const handleClaim = vi.fn()

    render(
      <MemoryRouter>
        <DiscoveredWorkloadDrawer
          isOpen={true}
          workload={mockWorkload}
          onClose={handleClose}
          onEnroll={handleEnroll}
          onDismiss={handleDismiss}
          onClaim={handleClaim}
        />
      </MemoryRouter>,
    )

    // Click Enroll
    await userEvent.click(screen.getByTestId('drawer-enroll-btn'))
    expect(handleEnroll).toHaveBeenCalledWith('tenant-demo:nhi-1')

    // Click Dismiss
    await userEvent.click(screen.getByTestId('drawer-dismiss-btn'))
    expect(handleDismiss).toHaveBeenCalledWith('tenant-demo:nhi-1')

    // Click Claim
    await userEvent.click(screen.getByTestId('drawer-claim-btn'))
    expect(handleClaim).toHaveBeenCalledWith(mockWorkload)

    // Click Close
    await userEvent.click(screen.getByTestId('drawer-close-btn'))
    expect(handleClose).toHaveBeenCalled()
  })

  it('closes on Escape key press', async () => {
    const handleClose = vi.fn()
    render(
      <MemoryRouter>
        <DiscoveredWorkloadDrawer
          isOpen={true}
          workload={mockWorkload}
          onClose={handleClose}
          onEnroll={vi.fn()}
          onDismiss={vi.fn()}
        />
      </MemoryRouter>,
    )

    await userEvent.keyboard('{Escape}')
    expect(handleClose).toHaveBeenCalled()
  })
})
