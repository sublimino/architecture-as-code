// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import { describe, it, expect, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { createPortal } from 'react-dom'
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
    expect(screen.getByTestId('drawer-workload-header-namespace')).toHaveTextContent('ns:identity-entra')
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

  it('handles Escape only from the iframe owner window', () => {
    const handleClose = vi.fn()
    const frame = document.createElement('iframe')
    document.body.appendChild(frame)
    const mount = frame.contentDocument!.createElement('div')
    frame.contentDocument!.body.appendChild(mount)
    const { unmount } = render(createPortal(
      <MemoryRouter>
        <DiscoveredWorkloadDrawer
          isOpen={true}
          workload={mockWorkload}
          onClose={handleClose}
          onEnroll={vi.fn()}
          onDismiss={vi.fn()}
        />
      </MemoryRouter>,
      mount,
    ))

    fireEvent.keyDown(window, { key: 'Escape' })
    expect(handleClose).not.toHaveBeenCalled()
    fireEvent.keyDown(frame.contentWindow!, { key: 'Escape' })
    expect(handleClose).toHaveBeenCalledOnce()

    unmount()
    frame.remove()
  })

  describe('Claude User & Remote Agent Card', () => {
    const mockClaudeWorkload: DiscoveryWorkload = {
      id: 'claude:agent_01FoEhnKF9QsC5DGmuELhm7G',
      name: 'claude-swe-worker',
      source: 'external_services',
      source_label: 'Anthropic Claude',
      namespace: 'external-claude',
      status: 'discovered',
      owner: 'dev@signalloom.local',
      spiffe_id: null,
      model: 'claude-3-7-sonnet',
      last_seen_at: '2026-10-16T12:00:00Z',
      recommendations: {
        config: 'pass',
        content: 'pass',
        supply_chain: 'pass',
        eu_ai_act: 'pass',
      },
      metadata: {
        provider_id: 'claude',
        raw_hash: '9a8f7e6d5c4b3a210fedcba987654321',
        system_prompt: 'You are an autonomous Claude coding agent with secure bash execution.',
        user_metadata: {
          owner: 'dev@signalloom.local',
          org_id: 'org_test_9e10-42e5-b2ac-e8f37a186b88',
          workspace_id: 'wrkspc_test_bUVWA2wWnyvm',
          key_type: 'service_account',
        },
        environment_config: {
          env_name: 'cloud-dev',
          env_id: 'env_01CyCigBbDRSLTzSCyyHQ7eT',
          network_egress: 'Unrestricted (0.0.0.0/0)',
          package_registries: 'PyPI, npm, apt allowed',
        },
        metrics: {
          input_tokens: '12.4k',
          output_tokens: '1.8k',
          cost: 0.11,
          limit: 5.0,
        },
      },
    }

    it('renders Claude user card with identity, deduplicated versioning, prompt audit, and metrics', () => {
      render(
        <MemoryRouter>
          <DiscoveredWorkloadDrawer
            isOpen={true}
            workload={mockClaudeWorkload}
            onClose={vi.fn()}
            onEnroll={vi.fn()}
            onDismiss={vi.fn()}
          />
        </MemoryRouter>,
      )

      // Prominent Claude User & Remote Agent Card
      const card = screen.getByTestId('drawer-claude-user-card')
      expect(card).toBeInTheDocument()
      expect(screen.getByText('Claude User & Managed Agent Card')).toBeInTheDocument()

      // Identity & Organization Grid
      expect(screen.getByTestId('drawer-claude-user-owner')).toHaveTextContent('dev@signalloom.local')
      expect(screen.getByTestId('drawer-claude-org-id')).toHaveTextContent('org_test_9e10-42e5-b2ac-e8f37a186b88')
      expect(screen.getByTestId('drawer-claude-workspace-id')).toHaveTextContent('wrkspc_test_bUVWA2wWnyvm')
      expect(screen.getByTestId('drawer-claude-exec-identity')).toHaveTextContent('service_account')

      // Content-Addressed Versioning & Deduplication Banner
      expect(screen.getByTestId('drawer-claude-snapshot-hash')).toHaveTextContent('SHA-256: 9a8f7e6d5c4b...')
      expect(screen.getByTestId('drawer-claude-dedup-badge')).toHaveTextContent('✓ Storage Deduplicated · Versioned Snapshot')

      // Environment & Network Containment Section
      expect(screen.getByTestId('drawer-claude-environment')).toHaveTextContent('cloud-dev (env_01CyCigBbDRSLTzSCyyHQ7eT)')
      expect(screen.getByTestId('drawer-claude-network-egress')).toHaveTextContent('Unrestricted (0.0.0.0/0)')
      expect(screen.getByTestId('drawer-claude-package-registries')).toHaveTextContent('PyPI, npm, apt allowed')

      // System Prompt Audit Preview
      const details = screen.getByTestId('drawer-claude-system-prompt')
      expect(details).toBeInTheDocument()
      expect(details).toHaveTextContent('System Prompt Audit')
      expect(details).toHaveTextContent('You are an autonomous Claude coding agent with secure bash execution.')

      // Usage & Cost Metrics
      expect(screen.getByTestId('drawer-claude-tokens-metric')).toHaveTextContent('12.4k input / 1.8k output')
      expect(screen.getByTestId('drawer-claude-cost-metric')).toHaveTextContent('$0.11 / $5.00 limit')
    })

    it('shows "Not reported" rather than inventing values when user_metadata or raw_hash are omitted on a Claude workload', () => {
      const minimalClaude: DiscoveryWorkload = {
        ...mockClaudeWorkload,
        owner: null,
        metadata: {
          provider_id: 'claude',
        },
      }
      render(
        <MemoryRouter>
          <DiscoveredWorkloadDrawer
            isOpen={true}
            workload={minimalClaude}
            onClose={vi.fn()}
            onEnroll={vi.fn()}
            onDismiss={vi.fn()}
          />
        </MemoryRouter>,
      )

      expect(screen.getByTestId('drawer-claude-user-card')).toBeInTheDocument()
      expect(screen.getByTestId('drawer-claude-user-owner')).toHaveTextContent('Not reported')
      expect(screen.getByTestId('drawer-claude-org-id')).toHaveTextContent('Not reported')
      expect(screen.getByTestId('drawer-claude-workspace-id')).toHaveTextContent('Not reported')
      expect(screen.getByTestId('drawer-claude-exec-identity')).toHaveTextContent('Not reported')
      expect(screen.getByTestId('drawer-claude-environment')).toHaveTextContent('Not reported')
      expect(screen.getByTestId('drawer-claude-network-egress')).toHaveTextContent('Not reported')
      expect(screen.getByTestId('drawer-claude-package-registries')).toHaveTextContent('Not reported')
      expect(screen.getByTestId('drawer-claude-tokens-metric')).toHaveTextContent('Not reported')
      expect(screen.getByTestId('drawer-claude-cost-metric')).toHaveTextContent('Not reported')
      expect(screen.getByTestId('drawer-claude-snapshot-hash')).toHaveTextContent('SHA-256: Not reported')
      expect(screen.getByTestId('drawer-claude-dedup-badge')).toHaveTextContent('✓ Storage Deduplicated · Versioned Snapshot')

      // None of the previously-hardcoded fabrications may ever render again.
      expect(screen.queryByText(/Andrew Martin \(User\)/)).not.toBeInTheDocument()
      expect(screen.queryByText(/1f9b3065-9e10-42e5-b2ac-e8f37a186b88/)).not.toBeInTheDocument()
      expect(screen.queryByText(/wrkspc_01PFJfZsJrq5bUVWA2wWnyvm/)).not.toBeInTheDocument()
    })

    it('does NOT render Claude card for non-Claude workloads', () => {
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

      expect(screen.queryByTestId('drawer-claude-user-card')).not.toBeInTheDocument()
      expect(screen.queryByTestId('drawer-claude-system-prompt')).not.toBeInTheDocument()
    })
  })
})
