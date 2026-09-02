// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import React from 'react'
import { render, screen, fireEvent } from '@testing-library/react'
import { describe, it, expect, vi } from 'vitest'
import { IdentityAuditPanel, IdentityAuditEvent } from './IdentityAuditPanel'

const MOCK_EVENTS: IdentityAuditEvent[] = [
  {
    id: 'test-1',
    timestamp: '2026-09-02T08:00:00Z',
    operation: 'read',
    path: 'secret/data/cardvault/keys',
    spiffeId: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa',
    agentRole: 'cardvault',
    accessor: 'hmac-111',
    isOutOfRole: false,
  },
  {
    id: 'test-2',
    timestamp: '2026-09-02T08:05:00Z',
    operation: 'read',
    path: 'secret/data/admin/master',
    spiffeId: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa',
    agentRole: 'cardvault',
    accessor: 'hmac-111',
    isOutOfRole: true,
  },
  {
    id: 'test-3',
    timestamp: '2026-09-02T08:10:00Z',
    operation: 'svid_issuance',
    path: 'spire/workload',
    spiffeId: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa',
    agentRole: 'cardvault',
    accessor: 'hmac-svid-222',
    isOutOfRole: false,
  },
]

describe('IdentityAuditPanel', () => {
  it('renders title and active leases count', () => {
    render(<IdentityAuditPanel events={MOCK_EVENTS} activeLeasesCount={5} />)
    expect(screen.getByTestId('identity-audit-panel')).toBeInTheDocument()
    expect(screen.getByTestId('active-leases-count')).toHaveTextContent('Active Leases: 5')
  })

  it('renders all audit rows by default', () => {
    render(<IdentityAuditPanel events={MOCK_EVENTS} />)
    expect(screen.getByTestId('audit-row-test-1')).toBeInTheDocument()
    expect(screen.getByTestId('audit-row-test-2')).toBeInTheDocument()
    expect(screen.getByTestId('audit-row-test-3')).toBeInTheDocument()
  })

  it('filters by out-of-role anomalies', () => {
    const onFilter = vi.fn()
    render(<IdentityAuditPanel events={MOCK_EVENTS} onFilterChange={onFilter} />)

    fireEvent.click(screen.getByTestId('filter-out_of_role'))
    expect(onFilter).toHaveBeenCalledWith('out_of_role')

    expect(screen.queryByTestId('audit-row-test-1')).not.toBeInTheDocument()
    expect(screen.getByTestId('audit-row-test-2')).toBeInTheDocument()
    expect(screen.getByTestId('status-out-of-role-test-2')).toBeInTheDocument()
    expect(screen.queryByTestId('audit-row-test-3')).not.toBeInTheDocument()
  })

  it('filters by OpenBao audit signals only', () => {
    render(<IdentityAuditPanel events={MOCK_EVENTS} />)

    fireEvent.click(screen.getByTestId('filter-vault'))
    expect(screen.getByTestId('audit-row-test-1')).toBeInTheDocument()
    expect(screen.getByTestId('audit-row-test-2')).toBeInTheDocument()
    expect(screen.queryByTestId('audit-row-test-3')).not.toBeInTheDocument()
  })

  it('filters by SPIRE SVID signals only', () => {
    render(<IdentityAuditPanel events={MOCK_EVENTS} />)

    fireEvent.click(screen.getByTestId('filter-spire'))
    expect(screen.queryByTestId('audit-row-test-1')).not.toBeInTheDocument()
    expect(screen.queryByTestId('audit-row-test-2')).not.toBeInTheDocument()
    expect(screen.getByTestId('audit-row-test-3')).toBeInTheDocument()
  })
})
