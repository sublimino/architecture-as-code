// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import {
  AgentSuperFilterTable,
  formatFullTimestamp,
  type AgentFilterFields,
} from './AgentSuperFilterTable'
import type { Column } from './DataTable'

interface MockWorkload {
  id: string
  name: string
  status: string
  source: string
  namespace: string
  owner: string
  last_assessed: string | null
}

const MOCK_DATA: MockWorkload[] = [
  {
    id: 'agent-1',
    name: 'Payment Agent',
    status: 'Governed',
    source: 'K8s Cluster',
    namespace: 'payments',
    owner: 'Alice',
    last_assessed: '2026-09-29T10:00:00Z',
  },
  {
    id: 'agent-2',
    name: 'Suspended Sentinel',
    status: 'Suspended',
    source: 'IDP Okta',
    namespace: 'security',
    owner: 'Bob',
    last_assessed: '2026-09-28T12:00:00Z',
  },
  {
    id: 'agent-3',
    name: 'Unowned Shadow Pod',
    status: 'Discovered',
    source: 'External Cloud Run',
    namespace: 'shadow',
    owner: '',
    last_assessed: null,
  },
  {
    id: 'agent-4',
    name: 'Revoked Legacy Bot',
    status: 'Revoked',
    source: 'External Service Lambda',
    namespace: 'legacy',
    owner: 'Charlie',
    last_assessed: '2026-09-20T08:30:00Z',
  },
]

const COLUMNS: Column<MockWorkload>[] = [
  { key: 'name', label: 'Name', sortable: true },
  { key: 'status', label: 'Lifecycle', sortable: true },
  { key: 'namespace', label: 'Namespace', sortable: true },
  { key: 'last_assessed', label: 'Last Assessed', sortable: true },
]

function renderTable(props: Partial<React.ComponentProps<typeof AgentSuperFilterTable<MockWorkload>>> = {}) {
  return render(
    <AgentSuperFilterTable<MockWorkload>
      data={MOCK_DATA}
      columns={COLUMNS}
      renderRow={(item) => (
        <tr key={item.id} data-testid={`row-${item.id}`}>
          <td>{item.name}</td>
          <td>{item.status}</td>
          <td>{item.namespace}</td>
          <td>{formatFullTimestamp(item.last_assessed)}</td>
        </tr>
      )}
      {...props}
    />
  )
}

describe('AgentSuperFilterTable', () => {
  it('renders all rows and columns initially', () => {
    renderTable()
    expect(screen.getByTestId('row-agent-1')).toBeInTheDocument()
    expect(screen.getByTestId('row-agent-2')).toBeInTheDocument()
    expect(screen.getByTestId('row-agent-3')).toBeInTheDocument()
    expect(screen.getByTestId('row-agent-4')).toBeInTheDocument()
    expect(screen.getByText('4 of 4 workloads shown')).toBeInTheDocument()
  })

  it('formats full timestamp with date, time, and seconds', () => {
    const formatted = formatFullTimestamp('2026-09-29T10:00:00Z')
    expect(formatted).toMatch(/29 Sept? 2026, 1[01]:00:00/)
    expect(formatFullTimestamp(null)).toBe('Never assessed')
  })

  it('filters rows by search input', () => {
    renderTable()
    const searchInput = screen.getByPlaceholderText(/Search by name, ID/i)
    fireEvent.change(searchInput, { target: { value: 'Payment' } })

    expect(screen.getByTestId('row-agent-1')).toBeInTheDocument()
    expect(screen.queryByTestId('row-agent-2')).not.toBeInTheDocument()
    expect(screen.getByText('1 of 4 workloads shown')).toBeInTheDocument()
  })

  it('filters rows by state facet', () => {
    renderTable()
    // Click Suspended facet chip
    const suspendedChip = screen.getByRole('button', { name: /^Suspended/i })
    fireEvent.click(suspendedChip)

    expect(screen.getByTestId('row-agent-2')).toBeInTheDocument()
    expect(screen.queryByTestId('row-agent-1')).not.toBeInTheDocument()
    expect(screen.getByText('1 of 4 workloads shown')).toBeInTheDocument()
  })

  it('filters rows when Attention Required toggle is clicked', () => {
    renderTable()
    const attentionBtn = screen.getByTestId('agent-super-filter-table-attention-btn')
    expect(attentionBtn).toHaveAttribute('aria-pressed', 'false')

    fireEvent.click(attentionBtn)
    expect(attentionBtn).toHaveAttribute('aria-pressed', 'true')

    // agent-2 (Suspended), agent-3 (Discovered/Unowned), agent-4 (Revoked) require attention
    expect(screen.getByTestId('row-agent-2')).toBeInTheDocument()
    expect(screen.getByTestId('row-agent-3')).toBeInTheDocument()
    expect(screen.getByTestId('row-agent-4')).toBeInTheDocument()
    expect(screen.queryByTestId('row-agent-1')).not.toBeInTheDocument()
  })

  it('filters rows by namespace select', () => {
    renderTable()
    const nsSelect = screen.getByTestId('agent-super-filter-table-namespace')
    fireEvent.change(nsSelect, { target: { value: 'payments' } })

    expect(screen.getByTestId('row-agent-1')).toBeInTheDocument()
    expect(screen.queryByTestId('row-agent-2')).not.toBeInTheDocument()
    expect(screen.getByText('1 of 4 workloads shown')).toBeInTheDocument()
  })

  it('resets all filters when Clear filters is clicked', () => {
    renderTable()
    const searchInput = screen.getByPlaceholderText(/Search by name, ID/i)
    fireEvent.change(searchInput, { target: { value: 'Payment' } })
    expect(screen.getByText('1 of 4 workloads shown')).toBeInTheDocument()

    const clearBtn = screen.getByRole('button', { name: /Clear filters/i })
    fireEvent.click(clearBtn)

    expect(screen.getByText('4 of 4 workloads shown')).toBeInTheDocument()
    expect(screen.getByTestId('row-agent-2')).toBeInTheDocument()
  })
})
