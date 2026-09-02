// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import React, { useState } from 'react'

export interface IdentityAuditEvent {
  id: string
  timestamp: string
  operation: string
  path: string
  spiffeId: string
  agentRole: string
  accessor: string
  leaseId?: string
  leaseDuration?: string
  isOutOfRole?: boolean
  error?: string
}

export interface IdentityAuditPanelProps {
  events?: IdentityAuditEvent[]
  activeLeasesCount?: number
  onFilterChange?: (filter: string) => void
}

const DEFAULT_EVENTS: IdentityAuditEvent[] = [
  {
    id: 'bao-audit-1',
    timestamp: '2026-09-02T08:15:22Z',
    operation: 'read',
    path: 'secret/data/cardvault/master-keys',
    spiffeId: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa',
    agentRole: 'cardvault',
    accessor: 'hmac-98a72b1c4e5d6f0a',
    leaseId: 'secret/data/cardvault/master-keys/lease-88',
    leaseDuration: '3600s',
    isOutOfRole: false,
  },
  {
    id: 'bao-audit-2',
    timestamp: '2026-09-02T08:20:10Z',
    operation: 'read',
    path: 'secret/data/pki/ca-root-key',
    spiffeId: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa',
    agentRole: 'cardvault',
    accessor: 'hmac-98a72b1c4e5d6f0a',
    isOutOfRole: true,
    error: 'permission denied: policy out_of_role',
  },
  {
    id: 'spire-svid-1',
    timestamp: '2026-09-02T08:10:00Z',
    operation: 'svid_issuance',
    path: 'spire/agent/workload',
    spiffeId: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa',
    agentRole: 'cardvault',
    accessor: 'hmac-spire-jwt-101',
    leaseDuration: '300s',
    isOutOfRole: false,
  },
]

export const IdentityAuditPanel: React.FC<IdentityAuditPanelProps> = ({
  events = DEFAULT_EVENTS,
  activeLeasesCount = 4,
  onFilterChange,
}) => {
  const [activeFilter, setActiveFilter] = useState<string>('all')

  const handleFilter = (filter: string) => {
    setActiveFilter(filter)
    if (onFilterChange) {
      onFilterChange(filter)
    }
  }

  const filteredEvents = events.filter((ev) => {
    if (activeFilter === 'out_of_role') return ev.isOutOfRole
    if (activeFilter === 'vault') return ev.operation !== 'svid_issuance'
    if (activeFilter === 'spire') return ev.operation === 'svid_issuance'
    return true
  })

  return (
    <div
      data-testid="identity-audit-panel"
      style={{
        marginTop: 20,
        marginBottom: 24,
        padding: '16px 20px',
        background: 'var(--surface)',
        borderRadius: 8,
        border: '1px solid var(--border)',
      }}
    >
      <div
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          flexWrap: 'wrap',
          gap: 12,
          marginBottom: 16,
          borderBottom: '1px solid var(--border-subtle)',
          paddingBottom: 12,
        }}
      >
        <div>
          <h3 style={{ margin: 0, fontSize: 15, fontWeight: 600, color: 'var(--text)' }}>
            🔑 OpenBao & SPIRE Cryptographic Identity Stream
          </h3>
          <p style={{ margin: '4px 0 0', fontSize: 12, color: 'var(--muted)' }}>
            Real-time audit device streaming, SVID lease tracking & out-of-role vault access correlation
          </p>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <span
            data-testid="active-leases-count"
            style={{
              fontSize: 12,
              padding: '3px 10px',
              borderRadius: 12,
              background: 'var(--surface2)',
              border: '1px solid var(--border)',
              color: 'var(--teal)',
              fontWeight: 600,
            }}
          >
            Active Leases: {activeLeasesCount}
          </span>
          <div style={{ display: 'flex', gap: 6 }}>
            {['all', 'vault', 'spire', 'out_of_role'].map((filter) => (
              <button
                key={filter}
                data-testid={`filter-${filter}`}
                onClick={() => handleFilter(filter)}
                style={{
                  padding: '4px 10px',
                  fontSize: 11,
                  fontWeight: 500,
                  borderRadius: 4,
                  cursor: 'pointer',
                  background: activeFilter === filter ? 'var(--teal)' : 'var(--surface2)',
                  color: activeFilter === filter ? 'var(--on-accent, #fff)' : 'var(--text)',
                  border: '1px solid var(--border)',
                }}
              >
                {filter === 'all' && 'All Signals'}
                {filter === 'vault' && 'OpenBao Audit'}
                {filter === 'spire' && 'SPIRE SVID'}
                {filter === 'out_of_role' && '⚠️ Out-of-Role'}
              </button>
            ))}
          </div>
        </div>
      </div>

      <div style={{ overflowX: 'auto' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
          <thead>
            <tr style={{ color: 'var(--muted)', textAlign: 'left', borderBottom: '1px solid var(--border-subtle)' }}>
              <th style={{ padding: '8px 10px' }}>Timestamp</th>
              <th style={{ padding: '8px 10px' }}>Operation</th>
              <th style={{ padding: '8px 10px' }}>Secret Path / Resource</th>
              <th style={{ padding: '8px 10px' }}>SPIFFE ID / Role</th>
              <th style={{ padding: '8px 10px' }}>Accessor (HMAC)</th>
              <th style={{ padding: '8px 10px' }}>Status</th>
            </tr>
          </thead>
          <tbody>
            {filteredEvents.map((ev) => (
              <tr
                key={ev.id}
                data-testid={`audit-row-${ev.id}`}
                style={{
                  borderBottom: '1px solid var(--border-subtle)',
                  background: ev.isOutOfRole ? 'rgba(239, 68, 68, 0.08)' : 'transparent',
                }}
              >
                <td style={{ padding: '8px 10px', whiteSpace: 'nowrap', color: 'var(--dim)' }}>
                  {new Date(ev.timestamp).toLocaleTimeString()}
                </td>
                <td style={{ padding: '8px 10px' }}>
                  <span
                    style={{
                      fontSize: 11,
                      padding: '2px 6px',
                      borderRadius: 4,
                      background: 'var(--surface2)',
                      color: ev.operation === 'svid_issuance' ? 'var(--violet)' : 'var(--cyan)',
                      fontWeight: 600,
                    }}
                  >
                    {ev.operation.toUpperCase()}
                  </span>
                </td>
                <td style={{ padding: '8px 10px', fontFamily: 'monospace', color: 'var(--text)' }}>
                  {ev.path}
                </td>
                <td style={{ padding: '8px 10px' }}>
                  <div style={{ color: 'var(--text)', fontWeight: 500 }}>{ev.agentRole}</div>
                  <div style={{ fontSize: 10, color: 'var(--muted)', fontFamily: 'monospace' }}>{ev.spiffeId}</div>
                </td>
                <td style={{ padding: '8px 10px', fontFamily: 'monospace', fontSize: 11, color: 'var(--dim)' }}>
                  {ev.accessor}
                </td>
                <td style={{ padding: '8px 10px' }}>
                  {ev.isOutOfRole ? (
                    <span
                      data-testid={`status-out-of-role-${ev.id}`}
                      style={{
                        fontSize: 11,
                        padding: '2px 6px',
                        borderRadius: 4,
                        background: 'var(--error)',
                        color: 'var(--on-accent, #fff)',
                        fontWeight: 600,
                      }}
                    >
                      OUT-OF-ROLE
                    </span>
                  ) : (
                    <span
                      style={{
                        fontSize: 11,
                        padding: '2px 6px',
                        borderRadius: 4,
                        background: 'rgba(16, 185, 129, 0.15)',
                        color: 'var(--teal)',
                        fontWeight: 600,
                      }}
                    >
                      AUTHORIZED
                    </span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
