// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import React, { useState, useEffect, useCallback, useMemo } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import type { StoredRecord, Harness, AggregateResult } from '../types/codingAgent'
import { CodingAgentCard } from './CodingAgentCard'
import { StatCard } from './DashKit'
import EmptyState from './EmptyState'
import LoadingState from './LoadingState'
import { colors } from '../styles/tokens'
import { LIVE_POLL_MS } from '../api/pollInterval'

const POLL_INTERVAL = LIVE_POLL_MS

export interface CodingAgentsTabProps {
  initialHarness?: string
  initialTaskId?: string
  onSelectAgent?: (record: StoredRecord) => void
}

export function CodingAgentsTab({ initialHarness, initialTaskId, onSelectAgent }: CodingAgentsTabProps) {
  const { getAccessTokenSilently } = useAuth0()
  const [records, setRecords] = useState<StoredRecord[]>([])
  const [aggregate, setAggregate] = useState<AggregateResult | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [selectedHarness, setSelectedHarness] = useState<string>(initialHarness || 'all')
  const [selectedRole, setSelectedRole] = useState<string>('all')
  const [searchQuery, setSearchQuery] = useState<string>(initialTaskId || '')
  const [selectedRecordId, setSelectedRecordId] = useState<string | null>(null)

  const fetchTelemetry = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const [listRes, aggRes] = await Promise.allSettled([
        api.codingAgents.list(token),
        api.codingAgents.aggregate(token),
      ])

      if (listRes.status === 'fulfilled') {
        setRecords(listRes.value || [])
        setError(null)
      } else {
        // Fallback or error handling
        setError(listRes.reason instanceof Error ? listRes.reason.message : 'Failed to fetch telemetry')
      }

      if (aggRes.status === 'fulfilled') {
        setAggregate(aggRes.value)
      }
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Telemetry request failed')
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    void fetchTelemetry()
    const timer = setInterval(() => {
      void fetchTelemetry()
    }, POLL_INTERVAL)
    return () => clearInterval(timer)
  }, [fetchTelemetry])

  // Filtered records based on controls
  const filteredRecords = useMemo(() => {
    return records.filter((rec) => {
      const event = rec.event
      if (selectedHarness !== 'all' && event.harness !== selectedHarness) {
        return false
      }
      if (selectedRole !== 'all' && event.kanban?.role !== selectedRole) {
        return false
      }
      if (searchQuery.trim()) {
        const q = searchQuery.toLowerCase().trim()
        const matchTask = event.kanban?.task_id?.toLowerCase().includes(q)
        const matchShortcode = event.kanban?.shortcode?.toLowerCase().includes(q)
        const matchSession = event.session_id?.toLowerCase().includes(q)
        const matchComm = event.process?.comm?.toLowerCase().includes(q)
        const matchHost = event.host_id?.toLowerCase().includes(q)
        const matchEndpoint = event.network?.inference_endpoint?.toLowerCase().includes(q)
        if (!matchTask && !matchShortcode && !matchSession && !matchComm && !matchHost && !matchEndpoint) {
          return false
        }
      }
      return true
    })
  }, [records, selectedHarness, selectedRole, searchQuery])

  // Compute live rollups
  const stats = useMemo(() => {
    const totalSessions = records.length
    const totalTokens = records.reduce((acc, r) => acc + (r.event.metrics.tokens_in + r.event.metrics.tokens_out), 0)
    const totalSteps = records.reduce((acc, r) => acc + r.event.metrics.step_count, 0)
    const distinctHosts = new Set(records.map((r) => r.event.host_id).filter(Boolean)).size || 1

    return {
      totalSessions,
      totalTokens,
      totalSteps,
      distinctHosts,
    }
  }, [records])

  const harnesses: Harness[] = ['claude', 'antigravity', 'codex', 'cpai', 'opencode', 'hermes', 'aider']
  const roles = ['implementation', 'research', 'testing', 'refactor', 'governor', 'audit', 'patch']

  return (
    <div data-testid="coding-agents-tab" style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      {/* ─── Governance / Lawful Basis Info Strip ────────────────────────── */}
      <div
        style={{
          background: 'var(--surface2)',
          border: '1px solid var(--border)',
          borderRadius: 8,
          padding: '12px 16px',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 16,
          flexWrap: 'wrap',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <span style={{ fontSize: 20 }}>🛡️</span>
          <div>
            <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)' }}>
              Autonomous Coding Agent Telemetry (SLCD Host Detective)
            </div>
            <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
              Passive process, token, tool histogram, and network egress telemetry ingested via SPIFFE JWT-SVID authenticated pipeline. Zero customer code or prompt payload invariant enforced.
            </div>
          </div>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span
            className="tag"
            style={{
              fontSize: 11,
              background: 'rgba(20, 184, 166, 0.12)',
              color: colors.tealLoom,
              border: '1px solid rgba(20, 184, 166, 0.3)',
              fontWeight: 600,
            }}
          >
            k-Anonymity (k ≥ 5) Guaranteed
          </span>
          <button
            type="button"
            className="btn btn-secondary btn-sm"
            onClick={() => void fetchTelemetry()}
            style={{ fontSize: 11, padding: '4px 10px' }}
          >
            ↻ Refresh
          </button>
        </div>
      </div>

      {/* ─── Stat Cards ──────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap' }}>
        <StatCard
          label="Active Sessions"
          value={stats.totalSessions.toString()}
          sub={`${stats.distinctHosts} distinct workstations`}
          accent="var(--cyan)"
        />
        <StatCard
          label="Total Token Throughput"
          value={stats.totalTokens.toLocaleString()}
          sub={`${(stats.totalTokens / 1000).toFixed(1)}k tokens processed`}
          accent="var(--teal)"
        />
        <StatCard
          label="Cumulative Steps"
          value={stats.totalSteps.toLocaleString()}
          sub="Autonomous iteration turns"
          accent="var(--violet)"
        />
        {/*
          SLCD-P5-GOV: when the aggregate is absent the cohort figure is
          WITHHELD, never substituted.

          `aggregate` is null precisely when signal-ingest REFUSED to compute
          it: HTTP 422, cohort below the k=5 anonymity floor (see
          codingagent/store.go:268). fetchTelemetry() uses Promise.allSettled,
          so that refusal lands here silently as a null with no error set.

          This card previously fell back to `${stats.totalSessions} sessions`,
          a client-side count of the rows already in hand. That re-disclosed
          the exact quantity the server had just withheld to prevent
          re-identification, under a heading asserting k-anonymity (i.e. the
          UI answered the question the privacy control exists to refuse).
          Proven live in CodingAgentsTab.e2e.test.tsx, which rendered
          "2 sessions" against a 422.
        */}
        <StatCard
          label="Anonymity Cohort"
          value={aggregate ? `${aggregate.group_size} entities` : 'Withheld'}
          sub={
            aggregate
              ? aggregate.avg_clock_skew_ms
                ? `avg skew ${aggregate.avg_clock_skew_ms.toFixed(1)}ms`
                : 'clock skew bounded'
              : 'below k=5 anonymity floor'
          }
          accent="var(--amber)"
        />
      </div>

      {/* ─── Filter & Search Toolbar ─────────────────────────────────────── */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 12,
          flexWrap: 'wrap',
          background: 'var(--surface)',
          padding: '12px 14px',
          borderRadius: 8,
          border: '1px solid var(--border)',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
          {/* Search box */}
          <div style={{ position: 'relative', width: 220 }}>
            <input
              type="text"
              placeholder="Search task, session, PID…"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              className="input"
              style={{
                width: '100%',
                fontSize: 12,
                padding: '6px 10px',
                borderRadius: 6,
                background: 'var(--surface2)',
                border: '1px solid var(--border)',
                color: 'var(--text)',
              }}
            />
          </div>

          {/* Harness filter */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
            <span style={{ fontSize: 11, color: 'var(--muted)', fontWeight: 600, textTransform: 'uppercase' }}>Harness:</span>
            <select
              value={selectedHarness}
              onChange={(e) => setSelectedHarness(e.target.value)}
              style={{
                fontSize: 12,
                padding: '5px 8px',
                borderRadius: 6,
                background: 'var(--surface2)',
                border: '1px solid var(--border)',
                color: 'var(--text)',
              }}
            >
              <option value="all">All Harnesses ({records.length})</option>
              {harnesses.map((h) => {
                const count = records.filter((r) => r.event.harness === h).length
                return (
                  <option key={h} value={h}>
                    {h} ({count})
                  </option>
                )
              })}
            </select>
          </div>

          {/* Role filter */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
            <span style={{ fontSize: 11, color: 'var(--muted)', fontWeight: 600, textTransform: 'uppercase' }}>Role:</span>
            <select
              value={selectedRole}
              onChange={(e) => setSelectedRole(e.target.value)}
              style={{
                fontSize: 12,
                padding: '5px 8px',
                borderRadius: 6,
                background: 'var(--surface2)',
                border: '1px solid var(--border)',
                color: 'var(--text)',
              }}
            >
              <option value="all">All Roles</option>
              {roles.map((r) => (
                <option key={r} value={r}>
                  {r}
                </option>
              ))}
            </select>
          </div>
        </div>

        <div style={{ fontSize: 12, color: 'var(--muted)' }}>
          Showing <strong>{filteredRecords.length}</strong> of <strong>{records.length}</strong> detected agents
        </div>
      </div>

      {/* ─── Content Body: Cards or Empty / Loading State ────────────────── */}
      {loading && records.length === 0 ? (
        <LoadingState status="loading" label="coding agent telemetry" testId="coding-agents-load-state" />
      ) : error && records.length === 0 ? (
        <LoadingState status="error" error={error} label="coding agent telemetry" onRetry={fetchTelemetry} testId="coding-agents-load-state" />
      ) : filteredRecords.length === 0 ? (
        <EmptyState
          kicker="No coding agents found"
          body={
            searchQuery || selectedHarness !== 'all' || selectedRole !== 'all'
              ? 'No detected coding agents match the active filter criteria. Try clearing the search or changing the harness filter.'
              : 'No external workstation coding agents are currently reporting telemetry. Ensure agentmaxxing-host-sensor is running on your development host.'
          }
        />
      ) : (

        <div
          data-testid="coding-agents-grid"
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(420px, 1fr))',
            gap: 16,
          }}
        >
          {filteredRecords.map((rec) => {
            const sid = rec.event.session_id
            return (
              <CodingAgentCard
                key={sid}
                record={rec}
                selected={selectedRecordId === sid}
                onSelect={(selected) => {
                  setSelectedRecordId(selected.event.session_id)
                  onSelectAgent?.(selected)
                }}
              />
            )
          })}
        </div>
      )}
    </div>
  )
}
