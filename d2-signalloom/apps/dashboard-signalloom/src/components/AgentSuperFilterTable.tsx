// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import React, { useState, useMemo, useCallback } from 'react'
import DataTable, { type Column } from './DataTable'
import {
  DataTableToolbar,
  ToolbarSearch,
  ToolbarFacet,
  ToolbarSelect,
  ToolbarClear,
  ToolbarCount,
  type ToolbarOption,
} from './DataTableToolbar'
import EmptyState from './EmptyState'
import { colors } from '../styles/tokens'

export interface AgentFilterFields {
  id?: string
  name?: string
  state?: string
  source?: string
  namespace?: string
  owner?: string
  lastAssessed?: string | number | null
  requiresAttention?: boolean
}

export interface AgentSuperFilterTableProps<T> {
  data: T[]
  columns: Column<T>[]
  renderRow: (item: T, index: number) => React.ReactNode
  extractFields?: (item: T) => AgentFilterFields
  pageSize?: number
  testId?: string
  initialStateFilter?: string
  initialSourceFilter?: string
  initialNamespaceFilter?: string
  initialAttentionFilter?: boolean
}

/**
 * Formats a date value into a full human-readable timestamp with date and time.
 */
export function formatFullTimestamp(val: string | number | null | undefined): string {
  if (!val) return 'Never assessed'
  const date = typeof val === 'number' ? new Date(val) : new Date(String(val))
  if (isNaN(date.getTime())) return String(val)
  return date.toLocaleString('en-GB', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  })
}

function defaultExtractFields<T>(item: T): AgentFilterFields {
  const rec = item as Record<string, unknown>
  const name = typeof rec.name === 'string' ? rec.name : typeof rec.agent_name === 'string' ? rec.agent_name : ''
  const id = typeof rec.id === 'string' ? rec.id : typeof rec.agent_id === 'string' ? rec.agent_id : ''
  const state = typeof rec.lifecycle_state === 'string'
    ? rec.lifecycle_state
    : typeof rec.status === 'string'
      ? rec.status
      : typeof rec.state === 'string'
        ? rec.state
        : ''
  const source = typeof rec.source === 'string'
    ? rec.source
    : typeof rec.connector === 'string'
      ? rec.connector
      : typeof rec.provider === 'string'
        ? rec.provider
        : ''
  const namespace = typeof rec.namespace === 'string'
    ? rec.namespace
    : typeof (rec.runtime as Record<string, unknown> | undefined)?.namespace === 'string'
      ? String((rec.runtime as Record<string, unknown>).namespace)
      : ''
  const owner = typeof rec.owner === 'string'
    ? rec.owner
    : typeof (rec.responsibility as Record<string, unknown> | undefined)?.owner_name === 'string'
      ? String((rec.responsibility as Record<string, unknown>).owner_name)
      : ''

  const lastAssessed = rec.last_assessed ?? rec.lastAssessed ?? rec.last_observed_at ?? (rec.timestamps as Record<string, unknown> | undefined)?.last_observed_at ?? null

  const sLower = state.toLowerCase()
  const requiresAttention = Boolean(
    rec.requires_attention ||
    rec.requiresAttention ||
    sLower === 'suspended' ||
    sLower === 'stunned' ||
    sLower === 'revoked' ||
    sLower === 'discovered' ||
    sLower === 'in_review' ||
    (!owner && sLower !== 'ignored' && sLower !== 'revoked')
  )

  return {
    id,
    name,
    state,
    source,
    namespace,
    owner,
    lastAssessed: lastAssessed as string | number | null,
    requiresAttention,
  }
}

export function AgentSuperFilterTable<T>({
  data,
  columns,
  renderRow,
  extractFields = defaultExtractFields,
  pageSize = 50,
  testId = 'agent-super-filter-table',
  initialStateFilter = 'all',
  initialSourceFilter = 'all',
  initialNamespaceFilter = 'all',
  initialAttentionFilter = false,
}: AgentSuperFilterTableProps<T>) {
  const [searchQuery, setSearchQuery] = useState('')
  const [stateFilter, setStateFilter] = useState(initialStateFilter)
  const [sourceFilter, setSourceFilter] = useState(initialSourceFilter)
  const [namespaceFilter, setNamespaceFilter] = useState(initialNamespaceFilter)
  const [attentionOnly, setAttentionOnly] = useState(initialAttentionFilter)

  // Extract fields once per dataset
  const enrichedData = useMemo(() => {
    return data.map((item) => ({
      item,
      fields: extractFields(item),
    }))
  }, [data, extractFields])

  // Count items requiring attention
  const attentionCount = useMemo(() => {
    return enrichedData.filter((e) => e.fields.requiresAttention).length
  }, [enrichedData])

  // Available unique namespaces
  const namespaceOptions: ToolbarOption[] = useMemo(() => {
    const set = new Set<string>()
    enrichedData.forEach((e) => {
      if (e.fields.namespace && e.fields.namespace.trim()) {
        set.add(e.fields.namespace.trim())
      }
    })
    const list = Array.from(set).sort()
    return [
      { value: 'all', label: 'All namespaces' },
      ...list.map((ns) => ({ value: ns, label: ns })),
    ]
  }, [enrichedData])

  // Standard lifecycle state options
  const stateOptions: ToolbarOption[] = useMemo(() => {
    const counts: Record<string, number> = {
      all: enrichedData.length,
      governed: 0,
      suspended: 0,
      revoked: 0,
      discovered: 0,
    }

    enrichedData.forEach((e) => {
      const s = (e.fields.state || '').toLowerCase()
      if (s === 'governed' || s === 'active' || s === 'enrolled' || s === 'registered') {
        counts.governed += 1
      } else if (s === 'suspended' || s === 'stunned') {
        counts.suspended += 1
      } else if (s === 'revoked' || s === 'decommissioned') {
        counts.revoked += 1
      } else if (s === 'discovered' || s === 'in_review') {
        counts.discovered += 1
      }
    })

    const opts: ToolbarOption[] = [
      { value: 'all', label: 'All states', count: counts.all },
      { value: 'governed', label: 'Governed', count: counts.governed },
      { value: 'suspended', label: 'Suspended', count: counts.suspended },
      { value: 'revoked', label: 'Revoked', count: counts.revoked },
    ]

    if (counts.discovered > 0) {
      opts.push({ value: 'discovered', label: 'Discovered', count: counts.discovered })
    }

    return opts
  }, [enrichedData])

  // Connector source options
  const sourceOptions: ToolbarOption[] = useMemo(() => {
    const counts: Record<string, number> = {
      all: enrichedData.length,
      idp: 0,
      k8s: 0,
      external: 0,
      service: 0,
    }

    enrichedData.forEach((e) => {
      const src = (e.fields.source || '').toLowerCase()
      if (src.includes('idp') || src.includes('entra') || src.includes('okta') || src.includes('dex')) {
        counts.idp += 1
      } else if (src.includes('k8s') || src.includes('kubernetes') || src.includes('cluster')) {
        counts.k8s += 1
      } else if (src.includes('external') || src.includes('cloud') || src.includes('aws') || src.includes('gcp') || src.includes('azure')) {
        counts.external += 1
      } else if (src.includes('service') || src.includes('n8n') || src.includes('lambda')) {
        counts.service += 1
      }
    })

    const opts: ToolbarOption[] = [
      { value: 'all', label: 'All sources', count: counts.all },
    ]
    if (counts.idp > 0) opts.push({ value: 'idp', label: 'IDP', count: counts.idp })
    if (counts.k8s > 0) opts.push({ value: 'k8s', label: 'K8s Cluster', count: counts.k8s })
    if (counts.external > 0) opts.push({ value: 'external', label: 'External Cluster', count: counts.external })
    if (counts.service > 0) opts.push({ value: 'service', label: 'External Service', count: counts.service })

    return opts
  }, [enrichedData])

  // Filter application
  const filteredData = useMemo(() => {
    return enrichedData
      .filter((e) => {
        const { fields } = e

        // Attention filter
        if (attentionOnly && !fields.requiresAttention) {
          return false
        }

        // State filter
        if (stateFilter !== 'all') {
          const s = (fields.state || '').toLowerCase()
          if (stateFilter === 'governed') {
            if (s !== 'governed' && s !== 'active' && s !== 'enrolled' && s !== 'registered') return false
          } else if (stateFilter === 'suspended') {
            if (s !== 'suspended' && s !== 'stunned') return false
          } else if (stateFilter === 'revoked') {
            if (s !== 'revoked' && s !== 'decommissioned') return false
          } else if (stateFilter === 'discovered') {
            if (s !== 'discovered' && s !== 'in_review') return false
          } else if (s !== stateFilter) {
            return false
          }
        }

        // Source filter
        if (sourceFilter !== 'all') {
          const src = (fields.source || '').toLowerCase()
          if (sourceFilter === 'idp') {
            if (!src.includes('idp') && !src.includes('entra') && !src.includes('okta') && !src.includes('dex')) return false
          } else if (sourceFilter === 'k8s') {
            if (!src.includes('k8s') && !src.includes('kubernetes') && !src.includes('cluster')) return false
          } else if (sourceFilter === 'external') {
            if (!src.includes('external') && !src.includes('cloud') && !src.includes('aws') && !src.includes('gcp') && !src.includes('azure')) return false
          } else if (sourceFilter === 'service') {
            if (!src.includes('service') && !src.includes('n8n') && !src.includes('lambda')) return false
          }
        }

        // Namespace filter
        if (namespaceFilter !== 'all') {
          if (fields.namespace !== namespaceFilter) {
            return false
          }
        }

        // Search query
        if (searchQuery.trim()) {
          const q = searchQuery.toLowerCase().trim()
          const matchName = fields.name?.toLowerCase().includes(q)
          const matchId = fields.id?.toLowerCase().includes(q)
          const matchNamespace = fields.namespace?.toLowerCase().includes(q)
          const matchOwner = fields.owner?.toLowerCase().includes(q)
          const matchSource = fields.source?.toLowerCase().includes(q)
          if (!matchName && !matchId && !matchNamespace && !matchOwner && !matchSource) {
            return false
          }
        }

        return true
      })
      .map((e) => e.item)
  }, [enrichedData, attentionOnly, stateFilter, sourceFilter, namespaceFilter, searchQuery])

  const isFiltered = Boolean(
    searchQuery.trim() ||
    stateFilter !== 'all' ||
    sourceFilter !== 'all' ||
    namespaceFilter !== 'all' ||
    attentionOnly
  )

  const handleClearFilters = useCallback(() => {
    setSearchQuery('')
    setStateFilter('all')
    setSourceFilter('all')
    setNamespaceFilter('all')
    setAttentionOnly(false)
  }, [])

  return (
    <div data-testid={testId} style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      {/* Standardized Design System Toolbar */}
      <DataTableToolbar label="Agent Super Filter Toolbar">
        <ToolbarSearch
          label="Search workloads"
          placeholder="Search by name, ID, namespace, owner..."
          value={searchQuery}
          onChange={setSearchQuery}
          testId={`${testId}-search`}
        />

        <ToolbarFacet
          label="Filter by state"
          value={stateFilter}
          options={stateOptions}
          onChange={setStateFilter}
          testIdPrefix={`${testId}-state`}
        />

        {sourceOptions.length > 1 && (
          <ToolbarFacet
            label="Filter by source"
            value={sourceFilter}
            options={sourceOptions}
            onChange={setSourceFilter}
            testIdPrefix={`${testId}-source`}
          />
        )}

        {namespaceOptions.length > 1 && (
          <ToolbarSelect
            label="Namespace"
            subject="workloads"
            value={namespaceFilter}
            options={namespaceOptions}
            onChange={setNamespaceFilter}
            testId={`${testId}-namespace`}
          />
        )}

        {/* Attention Required Filter Button */}
        <button
          type="button"
          onClick={() => setAttentionOnly((prev) => !prev)}
          data-testid={`${testId}-attention-btn`}
          aria-pressed={attentionOnly}
          style={{
            display: 'inline-flex',
            alignItems: 'center',
            gap: 6,
            padding: '5px 10px',
            borderRadius: 4,
            fontSize: 12,
            fontWeight: attentionOnly ? 600 : 500,
            cursor: 'pointer',
            fontFamily: 'inherit',
            background: attentionOnly
              ? 'rgba(239, 68, 68, 0.18)'
              : 'var(--surface2)',
            color: attentionOnly ? colors.red : 'var(--text)',
            border: `1px solid ${attentionOnly ? colors.red : 'var(--border)'}`,
          }}
        >
          <span
            style={{
              background: colors.red,
              color: 'var(--on-accent)',
              borderRadius: 99,
              fontSize: 10,
              fontWeight: 700,
              padding: '0px 5px',
              minWidth: 16,
              textAlign: 'center',
            }}
          >
            {attentionCount}
          </span>
          Attention Required
        </button>

        <ToolbarClear
          active={isFiltered}
          onClear={handleClearFilters}
          testId={`${testId}-clear`}
        />

        <ToolbarCount
          shown={filteredData.length}
          total={data.length}
          noun="workloads"
          testId={`${testId}-count`}
        />
      </DataTableToolbar>

      {/* Table Content or Empty State */}
      {filteredData.length === 0 ? (
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center' }}>
          <EmptyState
            kicker="No workloads match criteria"
            body="No agent or workload matches the active filter selection. Try clearing the search or resetting facets."
          />
          <button
            type="button"
            className="btn btn-secondary btn-sm"
            onClick={handleClearFilters}
            data-testid={`${testId}-empty-clear`}
            style={{ marginTop: -32, marginBottom: 24 }}
          >
            Reset filters
          </button>
        </div>
      ) : (
        <DataTable<T>
          columns={columns}
          data={filteredData}
          pageSize={pageSize}
          renderRow={renderRow}
        />
      )}
    </div>
  )
}

export default AgentSuperFilterTable
