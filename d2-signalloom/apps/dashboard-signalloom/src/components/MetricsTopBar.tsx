// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * MetricsTopBar - estate telemetry pill for the top navigation (SLDC-P4-2).
 *
 * Total / active / stunned agents and aggregate CPU across every monitored
 * namespace, from the estate stream. With no stream it says so and shows no
 * numbers: a zero here would read as "nothing is running", which is a claim.
 *
 * Layout: it must never push the nav links off-screen, so it shrinks first,
 * truncates, and drops its secondary labels below 1100 px.
 */
import { memo, useEffect, useRef, useState } from 'react'
import { formatMillicores } from '../api/agentTelemetry'
import { useEstateTelemetry, type EstateSummary, type TelemetryConnection, type TelemetryHookOptions } from '../hooks/useAgentTelemetry'

const BAR_CSS = `
.sl-metrics-bar { display: flex; align-items: center; gap: 10px; min-width: 0; flex: 0 1 auto; overflow: hidden; white-space: nowrap }
.sl-metrics-count { display: inline-block; padding: 0 3px; border-radius: 4px; font-variant-numeric: tabular-nums; transition: background-color .45s ease, color .45s ease }
.sl-metrics-count[data-flash="true"] { background-color: var(--surface2) }
@media (max-width: 1100px) { .sl-metrics-secondary { display: none } }
@media (prefers-reduced-motion: reduce) { .sl-metrics-count { transition: none } }
`

/** A number that briefly highlights when it changes; the transition is CSS. */
function Counter({ value, testId }: { value: string; testId: string }) {
  const [flash, setFlash] = useState(false)
  const first = useRef(true)
  useEffect(() => {
    if (first.current) {
      first.current = false
      return
    }
    setFlash(true)
    const t = setTimeout(() => setFlash(false), 450)
    return () => clearTimeout(t)
  }, [value])
  return (
    <span className="sl-metrics-count" data-testid={testId} data-flash={flash ? 'true' : 'false'}>
      {value}
    </span>
  )
}

export interface MetricsTopBarViewProps {
  summary: EstateSummary | null
  connection: TelemetryConnection
}

export const MetricsTopBarView = memo(function MetricsTopBarView({ summary, connection }: MetricsTopBarViewProps) {
  const reachable = connection === 'live' || connection === 'polling'
  return (
    <div
      className="sl-metrics-bar"
      data-testid="metrics-top-bar"
      data-connection={connection}
      role="group"
      aria-label="Agent estate telemetry"
      style={{ fontSize: 12, color: 'var(--muted)', padding: '4px 10px', border: '1px solid var(--border)', borderRadius: 999, marginRight: 12 }}
    >
      <style>{BAR_CSS}</style>
      {summary ? (
        <>
          <span title="Monitored agents">
            <span className="sl-metrics-secondary">Agents </span>
            <Counter testId="metrics-total" value={String(summary.total)} />
          </span>
          <span title="Active agents" style={{ color: 'var(--teal)' }}>
            <span className="sl-metrics-secondary">Active </span>
            <Counter testId="metrics-active" value={String(summary.active)} />
          </span>
          <span title="Stunned agents (cgroup frozen)" style={{ color: summary.stunned > 0 ? 'var(--error)' : 'var(--muted)', fontWeight: summary.stunned > 0 ? 700 : 400 }}>
            <span className="sl-metrics-secondary">Stunned </span>
            <Counter testId="metrics-stunned" value={String(summary.stunned)} />
          </span>
          <span title="Aggregate CPU across monitored namespaces" style={{ color: 'var(--text)' }}>
            <span className="sl-metrics-secondary">CPU </span>
            <Counter testId="metrics-cpu" value={formatMillicores(summary.totalCpuMillicores)} />
          </span>
          {!reachable && (
            <span data-testid="metrics-stale" style={{ color: 'var(--amber)' }}>· stale</span>
          )}
        </>
      ) : (
        <span data-testid="metrics-offline">
          {connection === 'connecting' || connection === 'reconnecting' ? 'Telemetry connecting…' : 'Telemetry offline'}
        </span>
      )}
      <span className="sr-only" role="status" aria-live="polite" style={{ position: 'absolute', width: 1, height: 1, overflow: 'hidden', clip: 'rect(0 0 0 0)' }}>
        {summary && summary.stunned > 0 ? `${summary.stunned} agent${summary.stunned === 1 ? '' : 's'} stunned` : ''}
      </span>
    </div>
  )
})

export default function MetricsTopBar({ options }: { options?: TelemetryHookOptions }) {
  const { summary, connection } = useEstateTelemetry(options)
  return <MetricsTopBarView summary={summary} connection={connection} />
}
