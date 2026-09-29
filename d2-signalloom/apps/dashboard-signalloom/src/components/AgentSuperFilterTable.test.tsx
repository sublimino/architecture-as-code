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

  it('filters rows by multi-column criteria (status, framework, search query)', () => {
    interface ComplianceAgent {
      id: string
      name: string
      status: string
      framework: string
      namespace: string
    }

    const testData: ComplianceAgent[] = [
      { id: 'ca-1', name: 'Alpha Guard', status: 'Governed', framework: 'nist-800-53', namespace: 'prod' },
      { id: 'ca-2', name: 'Alpha Probe', status: 'Suspended', framework: 'nist-800-53', namespace: 'stage' },
      { id: 'ca-3', name: 'Alpha Watch', status: 'Governed', framework: 'eu-ai-act', namespace: 'prod' },
      { id: 'ca-4', name: 'Beta Guard', status: 'Governed', framework: 'nist-800-53', namespace: 'prod' },
    ]

    const testCols: Column<ComplianceAgent>[] = [
      { key: 'name', label: 'Name' },
      { key: 'status', label: 'Status' },
      { key: 'framework', label: 'Framework' },
    ]

    render(
      <AgentSuperFilterTable<ComplianceAgent>
        data={testData}
        columns={testCols}
        renderRow={(item) => (
          <tr key={item.id} data-testid={`test-row-${item.id}`}>
            <td>{item.name}</td>
            <td>{item.status}</td>
            <td>{item.framework}</td>
          </tr>
        )}
      />
    )

    // Initially 4 workloads shown
    expect(screen.getByTestId('test-row-ca-1')).toBeInTheDocument()
    expect(screen.getByTestId('test-row-ca-4')).toBeInTheDocument()

    // 1. Filter by framework select
    const fwSelect = screen.getByTestId('agent-super-filter-table-framework')
    fireEvent.change(fwSelect, { target: { value: 'nist-800-53' } })
    expect(screen.queryByTestId('test-row-ca-3')).not.toBeInTheDocument()

    // 2. Filter by state facet (Governed)
    const governedChip = screen.getByRole('button', { name: /^Governed/i })
    fireEvent.click(governedChip)
    expect(screen.queryByTestId('test-row-ca-2')).not.toBeInTheDocument()

    // 3. Search query "Alpha Guard"
    const searchInput = screen.getByPlaceholderText(/Search by name, ID/i)
    fireEvent.change(searchInput, { target: { value: 'Alpha Guard' } })

    // Only ca-1 should match all 3 criteria
    expect(screen.getByTestId('test-row-ca-1')).toBeInTheDocument()
    expect(screen.queryByTestId('test-row-ca-4')).not.toBeInTheDocument()
    expect(screen.getByText('1 of 4 workloads shown')).toBeInTheDocument()
  })

  it('renders EmptyState and resets when search yields no matches', () => {
    renderTable()
    const searchInput = screen.getByPlaceholderText(/Search by name, ID/i)
    fireEvent.change(searchInput, { target: { value: 'NonExistentAgentQuery123' } })

    expect(screen.getByText('No workloads match criteria')).toBeInTheDocument()
    expect(screen.getByTestId('agent-super-filter-table-empty-clear')).toBeInTheDocument()

    fireEvent.click(screen.getByTestId('agent-super-filter-table-empty-clear'))
    expect(screen.queryByText('No workloads match criteria')).not.toBeInTheDocument()
    expect(screen.getByTestId('row-agent-1')).toBeInTheDocument()
  })

  it('safely handles special regex characters in search query without crashing', () => {
    renderTable()
    const searchInput = screen.getByPlaceholderText(/Search by name, ID/i)

    const adversarialQueries = ['.*', '[a-z]+', '(', '(?=.*)', '^$', '\\d+', '+', '*', '?', '{1,3}', '[']
    for (const maliciousQuery of adversarialQueries) {
      expect(() => {
        fireEvent.change(searchInput, { target: { value: maliciousQuery } })
      }).not.toThrow()
    }
  })

  it('safely handles null and undefined data fields without crashing', () => {
    const dirtyData: any[] = [
      { id: 'dirty-1', name: null, status: null, namespace: null, owner: null },
      { id: null, name: undefined, status: undefined },
      {},
      null,
    ]

    expect(() => {
      render(
        <AgentSuperFilterTable<any>
          data={dirtyData}
          columns={[{ key: 'id', label: 'ID' }]}
          renderRow={(item, idx) => (
            <tr key={idx} data-testid={`dirty-row-${idx}`}>
              <td>{String(item?.id || '')}</td>
            </tr>
          )}
        />
      )
    }).not.toThrow()

    // Searching across dirty records should also not throw
    const searchInput = screen.getByPlaceholderText(/Search by name, ID/i)
    expect(() => {
      fireEvent.change(searchInput, { target: { value: 'test' } })
    }).not.toThrow()
  })
})
