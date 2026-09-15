// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import React from 'react'
import type { StoredRecord, Harness } from '../types/codingAgent'
import { colors } from '../styles/tokens'
import { hex } from './DashKit'

export interface CodingAgentCardProps {
  record: StoredRecord
  onSelect?: (record: StoredRecord) => void
  selected?: boolean
}

const HARNESS_ICONS: Record<Harness, string> = {
  claude: '🤖',
  antigravity: '✨',
  codex: '⚡',
  cpai: '🧠',
  opencode: '💻',
  hermes: '🏛️',
  aider: '🩹',
  unknown: '❓',
}

const HARNESS_COLORS: Record<Harness, string> = {
  claude: 'var(--amber)',
  antigravity: 'var(--cyan)',
  codex: 'var(--teal)',
  cpai: 'var(--violet)',
  opencode: '#3b82f6',
  hermes: '#a855f7',
  aider: '#10b981',
  unknown: 'var(--muted)',
}

const ROLE_COLORS: Record<string, string> = {
  implementation: 'var(--cyan)',
  research: 'var(--teal)',
  testing: 'var(--violet)',
  refactor: '#3b82f6',
  governor: '#a855f7',
  audit: 'var(--amber)',
  patch: '#10b981',
}

function formatBytes(bytes: number): string {
  if (!bytes || bytes === 0) return '0 B'
  const k = 1024
  const sizes = ['B', 'KB', 'MB', 'GB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return `${(bytes / Math.pow(k, i)).toFixed(i === 0 ? 0 : 1)} ${sizes[i]}`
}

function formatNumber(num: number): string {
  return (num || 0).toLocaleString()
}

function formatElapsed(seconds: number): string {
  if (!seconds || seconds <= 0) return '0s'
  const m = Math.floor(seconds / 60)
  const s = seconds % 60
  if (m === 0) return `${s}s`
  return `${m}m ${s.toString().padStart(2, '0')}s`
}

export function CodingAgentCard({ record, onSelect, selected = false }: CodingAgentCardProps) {
  const { event, observed_at, clock_skew_ms } = record
  const { harness, process, kanban, metrics, network, session_id, host_id } = event

  const harnessIcon = HARNESS_ICONS[harness] || '🤖'
  const harnessColor = HARNESS_COLORS[harness] || 'var(--cyan)'
  const roleColor = ROLE_COLORS[kanban?.role] || 'var(--muted)'

  // Extract non-zero tool counts for histogram
  const toolEntries = Object.entries(metrics.tool_counts || {})
    .filter(([, count]) => typeof count === 'number' && count > 0)
    .sort(([, a], [, b]) => (b as number) - (a as number))

  const totalToolCalls = toolEntries.reduce((acc, [, c]) => acc + (c as number), 0)

  return (
    <div
      data-testid={`coding-agent-card-${session_id.slice(0, 8)}`}
      data-harness={harness}
      className={`card ${selected ? 'card-selected' : ''}`}
      onClick={() => onSelect?.(record)}
      style={{
        padding: '18px 20px',
        borderRadius: 8,
        border: selected ? `1px solid ${harnessColor}` : '1px solid var(--border)',
        background: 'var(--surface)',
        display: 'flex',
        flexDirection: 'column',
        gap: 14,
        cursor: onSelect ? 'pointer' : 'default',
        transition: 'border-color 0.15s ease, box-shadow 0.15s ease',
      }}
    >
      {/* ─── Header: Harness, Process PID, Host, and Zero Payload Chip ───── */}
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <div
            style={{
              width: 34,
              height: 34,
              borderRadius: 6,
              background: hex(harnessColor, 0.15),
              border: `1px solid ${hex(harnessColor, 0.3)}`,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 18,
            }}
          >
            {harnessIcon}
          </div>
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <span style={{ fontSize: 14, fontWeight: 700, color: 'var(--text)', textTransform: 'capitalize' }}>
                {harness}
              </span>
              <span
                className="tag"
                style={{
                  fontSize: 11,
                  fontFamily: 'monospace',
                  background: 'var(--surface2)',
                  color: 'var(--text)',
                  border: '1px solid var(--border)',
                }}
              >
                comm: {process.comm} (PID: {process.pid})
              </span>
            </div>
            <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2, fontFamily: 'monospace' }}>
              {host_id || 'workstation'} • session {session_id.slice(0, 8)}…
            </div>
          </div>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
          {typeof clock_skew_ms === 'number' && (
            <span
              className="tag"
              title="Calculated server-side clock skew relative to workstation timestamp"
              style={{
                fontSize: 11,
                fontFamily: 'monospace',
                background: 'var(--surface2)',
                color: 'var(--muted)',
                border: '1px solid var(--border)',
              }}
            >
              skew: {clock_skew_ms >= 0 ? `+${clock_skew_ms}ms` : `${clock_skew_ms}ms`}
            </span>
          )}
          <span
            data-testid="zero-payload-chip"
            className="tag"
            style={{
              fontSize: 11,
              fontWeight: 600,
              background: hex(colors.tealLoom, 0.12),
              color: colors.tealLoom,
              border: `1px solid ${hex(colors.tealLoom, 0.3)}`,
              display: 'inline-flex',
              alignItems: 'center',
              gap: 4,
            }}
          >
            <span style={{ width: 6, height: 6, borderRadius: '50%', background: colors.tealLoom }} />
            Zero Customer Payload
          </span>
        </div>
      </div>

      {/* ─── Kanban Task Strip ────────────────────────────────────────────── */}
      <div
        style={{
          background: 'var(--surface2)',
          borderRadius: 6,
          padding: '8px 12px',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 8,
          fontSize: 12,
          flexWrap: 'wrap',
          border: '1px solid var(--border)',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ color: 'var(--muted)', fontWeight: 500 }}>Kanban Task:</span>
          <span style={{ fontWeight: 700, color: 'var(--text)', fontFamily: 'monospace' }}>
            {kanban.task_id}
          </span>
          {kanban.shortcode && (
            <span
              style={{
                fontSize: 10,
                padding: '1px 5px',
                borderRadius: 4,
                background: 'var(--surface)',
                color: 'var(--muted)',
                fontFamily: 'monospace',
                border: '1px solid var(--border)',
              }}
            >
              #{kanban.shortcode}
            </span>
          )}
          <span
            className="tag"
            style={{
              fontSize: 10,
              fontWeight: 600,
              textTransform: 'uppercase',
              background: hex(roleColor, 0.15),
              color: roleColor,
            }}
          >
            {kanban.role}
          </span>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 12, color: 'var(--muted)', fontSize: 11 }}>
          <span>Elapsed: <strong style={{ color: 'var(--text)' }}>{formatElapsed(kanban.elapsed_s)}</strong></span>
          <span>•</span>
          <span>Step: <strong style={{ color: 'var(--text)' }}>{metrics.step_count}</strong></span>
        </div>
      </div>

      {/* ─── Metrics Grid: Tokens, Steps, Process Resources ──────────────── */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(130px, 1fr))', gap: 10 }}>
        <div style={{ background: 'var(--surface2)', padding: '8px 10px', borderRadius: 6, border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>Token Throughput</div>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)', marginTop: 2 }}>
            {formatNumber(metrics.tokens_in + metrics.tokens_out)}
          </div>
          <div style={{ fontSize: 10, color: 'var(--muted)', marginTop: 1 }}>
            {formatNumber(metrics.tokens_in)} in • {formatNumber(metrics.tokens_out)} out
          </div>
        </div>

        <div style={{ background: 'var(--surface2)', padding: '8px 10px', borderRadius: 6, border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>Host Memory RSS</div>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)', marginTop: 2 }}>
            {formatBytes(process.rss_bytes)}
          </div>
          <div style={{ fontSize: 10, color: 'var(--muted)', marginTop: 1 }}>
            {formatNumber(process.cpu_ticks)} CPU ticks
          </div>
        </div>

        <div style={{ background: 'var(--surface2)', padding: '8px 10px', borderRadius: 6, border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>Inference Egress</div>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)', marginTop: 2, fontFamily: 'monospace', wordBreak: 'break-all' }}>
            {network.inference_endpoint || 'none'}
          </div>
          <div style={{ fontSize: 10, color: 'var(--muted)', marginTop: 1 }}>
            {formatBytes(network.egress_bytes)} egress
          </div>
        </div>
      </div>

      {/* ─── Tool Invocation Histogram ───────────────────────────────────── */}
      {toolEntries.length > 0 && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 11 }}>
            <span style={{ color: 'var(--muted)', fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
              Tool Invocation Histogram ({totalToolCalls} calls)
            </span>
          </div>

          {/* Mini stacked ratio bar */}
          <div style={{ display: 'flex', height: 6, borderRadius: 3, overflow: 'hidden', background: 'var(--surface2)' }}>
            {toolEntries.map(([tool, count], idx) => {
              const pct = totalToolCalls > 0 ? ((count as number) / totalToolCalls) * 100 : 0
              const barColors = ['var(--cyan)', 'var(--violet)', 'var(--teal)', 'var(--amber)', '#3b82f6', '#ec4899', '#8b5cf6']
              const color = barColors[idx % barColors.length]
              return (
                <div
                  key={tool}
                  style={{ width: `${pct}%`, background: color }}
                  title={`${tool}: ${count} (${pct.toFixed(0)}%)`}
                />
              )
            })}
          </div>

          {/* Tool count chips */}
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginTop: 2 }}>
            {toolEntries.map(([tool, count], idx) => {
              const barColors = ['var(--cyan)', 'var(--violet)', 'var(--teal)', 'var(--amber)', '#3b82f6', '#ec4899', '#8b5cf6']
              const color = barColors[idx % barColors.length]
              return (
                <span
                  key={tool}
                  style={{
                    fontSize: 11,
                    fontFamily: 'monospace',
                    padding: '2px 6px',
                    borderRadius: 4,
                    background: 'var(--surface2)',
                    color: 'var(--text)',
                    border: '1px solid var(--border)',
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: 4,
                  }}
                >
                  <span style={{ width: 6, height: 6, borderRadius: '50%', background: color }} />
                  <span>{tool}:</span>
                  <strong style={{ color }}>{count as number}</strong>
                </span>
              )
            })}
          </div>
        </div>
      )}

      {/* ─── Footer: Ingestion Timestamp ─────────────────────────────────── */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 11, color: 'var(--muted)', borderTop: '1px solid var(--border)', paddingTop: 8 }}>
        <span>Observed: {observed_at ? new Date(observed_at).toLocaleString('en-GB') : 'Just now'}</span>
        <span style={{ fontFamily: 'monospace', fontSize: 10 }}>schema v{event.schema_version}</span>
      </div>
    </div>
  )
}
