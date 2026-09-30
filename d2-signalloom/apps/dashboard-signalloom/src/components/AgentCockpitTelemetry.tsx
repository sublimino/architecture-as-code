// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * AgentCockpitTelemetry - full-width live CPU / RSS visualiser (SLDC-P4-2).
 *
 * The containment proof an evaluator reads at a glance: under a cgroup freeze
 * the CPU reading is the literal `0.000 mCPU` and the sparkline collapses onto
 * the zero axis, while resident memory holds steady - frozen in place, not
 * killed. Termination looks different on purpose: RSS falls to zero.
 *
 * "STUNNED" is shown only on the producer's explicit freeze signal; a bare
 * zero is an honest "no CPU delta" (see api/agentTelemetry.ts for why).
 *
 * The container subscribes; the view is a memoised pure function of samples,
 * so the 2 s cadence re-renders this subtree and nothing above it.
 */
import { Component, memo, type ErrorInfo, type ReactNode } from 'react'
import {
  formatMiB,
  formatMillicores,
  runStateOf,
  utilisationBand,
  type AgentRunState,
  type TelemetrySample,
  type UtilisationBand,
} from '../api/agentTelemetry'
import { useAgentTelemetry, type TelemetryConnection, type TelemetryHookOptions } from '../hooks/useAgentTelemetry'

const W = 600
const H = 80
const PAD = 4
const Y_ZERO = H - PAD

const BAND_COLOUR: Record<UtilisationBand, string> = {
  normal: 'var(--teal)',
  elevated: 'var(--amber)',
  critical: 'var(--error)',
}

const BADGE_TEXT: Record<AgentRunState, string> = {
  frozen: 'STUNNED (CGROUP FROZEN)',
  active: 'ACTIVE',
  idle: 'IDLE · NO CPU DELTA',
  terminated: 'TERMINATED (RSS RELEASED)',
}

const CONNECTION_TEXT: Record<TelemetryConnection, string> = {
  connecting: 'CONNECTING',
  live: 'LIVE',
  reconnecting: 'RECONNECTING',
  polling: 'POLLING · STREAM DOWN',
  error: 'OFFLINE',
}

// Scoped keyframes. Inline so the component carries its own motion and the
// harness bundle needs no CSS loader; reduced-motion users get the end state.
//
// The flatline draws in with scaleX, NOT a stroke-dasharray sweep. Under
// vector-effect: non-scaling-stroke the dash lengths are screen pixels, so a
// dasharray sized to the viewBox width covered only the first 600 px of a
// wider sparkline and the gap hid the rest: a half-length flatline, seen in
// real Chrome and invisible to jsdom.
const COCKPIT_CSS = `
@keyframes sl-cockpit-pulse { 0%,100% { opacity: 1 } 50% { opacity: .35 } }
@keyframes sl-cockpit-flatline { from { transform: scaleX(0) } to { transform: scaleX(1) } }
.sl-cockpit-pulse { animation: sl-cockpit-pulse 1.6s ease-in-out infinite }
.sl-cockpit-flatline { transform-box: view-box; transform-origin: 0 0; animation: sl-cockpit-flatline .6s ease-out both }
.sl-cockpit-path { transition: stroke .3s ease }
@media (prefers-reduced-motion: reduce) {
  .sl-cockpit-pulse, .sl-cockpit-flatline { animation: none }
}
`

/** Right-aligned x positions over a fixed-width window, oldest leftmost. */
function xAt(i: number, n: number, windowSize: number): number {
  const step = W / Math.max(1, windowSize - 1)
  return W - (n - 1 - i) * step
}

export function sparklinePath(values: number[], windowSize: number, scaleMax: number): string {
  if (values.length === 0) return ''
  const span = H - 2 * PAD
  return values
    .map((v, i) => {
      const y = Y_ZERO - (Math.min(v, scaleMax) / scaleMax) * span
      return `${i === 0 ? 'M' : 'L'} ${xAt(i, values.length, windowSize).toFixed(1)} ${y.toFixed(1)}`
    })
    .join(' ')
}

/** The frozen trace: one segment, exactly on the zero axis, full width. */
export const FLATLINE_PATH = `M 0 ${Y_ZERO} L ${W} ${Y_ZERO}`

function Sparkline({ samples, windowSize, frozen }: { samples: TelemetrySample[]; windowSize: number; frozen: boolean }) {
  const cpu = samples.map((s) => s.cpuMillicores)
  const latest = cpu.length > 0 ? cpu[cpu.length - 1] : 0
  const band = utilisationBand(latest)
  const cpuScale = Math.max(100, ...cpu)
  const mem = samples.map((s) => s.memoryRssMiB).filter((m): m is number => m !== null)
  const memScale = Math.max(1, ...mem) * 1.25

  const label = frozen
    ? 'CPU flatlined at 0.000 millicores under cgroup freeze; memory held steady.'
    : `CPU and memory over the last ${samples.length} samples; latest ${formatMillicores(latest)}.`

  return (
    <svg
      data-testid="cockpit-sparkline"
      role="img"
      aria-label={label}
      viewBox={`0 0 ${W} ${H}`}
      preserveAspectRatio="none"
      style={{ width: '100%', height: 88, display: 'block', background: 'var(--surface2)', borderRadius: 6 }}
    >
      <line x1={0} x2={W} y1={Y_ZERO} y2={Y_ZERO} stroke="var(--border)" strokeWidth={1} />
      {mem.length > 0 && (
        <path
          data-testid="cockpit-memory-path"
          d={sparklinePath(mem, windowSize, memScale)}
          fill="none"
          stroke="var(--muted)"
          strokeWidth={1.5}
          strokeDasharray="4 3"
          vectorEffect="non-scaling-stroke"
        />
      )}
      {!frozen && cpu.length > 0 && (
        <path
          data-testid="cockpit-cpu-path"
          data-band={band}
          className="sl-cockpit-path"
          d={sparklinePath(cpu, windowSize, cpuScale)}
          fill="none"
          stroke={BAND_COLOUR[band]}
          strokeWidth={2}
          vectorEffect="non-scaling-stroke"
        />
      )}
      {frozen && (
        <path
          data-testid="cockpit-flatline"
          className="sl-cockpit-flatline"
          d={FLATLINE_PATH}
          fill="none"
          stroke="var(--error)"
          strokeWidth={2.5}
          vectorEffect="non-scaling-stroke"
        />
      )}
    </svg>
  )
}

export interface AgentCockpitTelemetryViewProps {
  podName: string
  samples: TelemetrySample[]
  connection: TelemetryConnection
  stale?: boolean
  windowSize?: number
}

function liveSentence(podName: string, state: AgentRunState | null, latest: TelemetrySample | null): string {
  if (!latest || !state) return `Awaiting telemetry for ${podName}.`
  switch (state) {
    case 'frozen':
      return `${podName} stunned: cgroup frozen, CPU ${formatMillicores(0, true)}, memory held at ${formatMiB(latest.memoryRssMiB)}.`
    case 'terminated':
      return `${podName} terminated: resident memory released.`
    case 'active':
      return `${podName} active.`
    case 'idle':
      return `${podName} idle: no CPU delta in the last sample.`
  }
}

export const AgentCockpitTelemetryView = memo(function AgentCockpitTelemetryView({
  podName,
  samples,
  connection,
  stale = false,
  windowSize = 15,
}: AgentCockpitTelemetryViewProps) {
  const latest = samples.length > 0 ? samples[samples.length - 1] : null
  const state = latest ? runStateOf(latest) : null
  const frozen = state === 'frozen'
  const cpuText = latest ? formatMillicores(latest.cpuMillicores, frozen) : 'awaiting'

  return (
    <section
      data-testid="agent-cockpit-telemetry"
      data-state={state ?? 'awaiting'}
      aria-label={`Live telemetry for ${podName}`}
      className="card"
      style={{ width: '100%', padding: 16, display: 'flex', flexDirection: 'column', gap: 12, boxSizing: 'border-box' }}
    >
      <style>{COCKPIT_CSS}</style>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
        <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis' }}>
          {podName}
        </div>
        {state && (
          <span
            data-testid="cockpit-state-badge"
            data-state={state}
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: 6,
              padding: '3px 10px',
              borderRadius: 999,
              fontSize: 11,
              fontWeight: 800,
              letterSpacing: '0.04em',
              ...(frozen
                ? { background: 'var(--error)', color: 'var(--on-accent)', border: '1px solid var(--error)' }
                : state === 'active'
                  ? { color: 'var(--teal)', border: '1px solid var(--teal)' }
                  : { color: 'var(--muted)', border: '1px solid var(--border)' }),
            }}
          >
            {state === 'active' && (
              <span
                aria-hidden="true"
                className="sl-cockpit-pulse"
                style={{ width: 8, height: 8, borderRadius: '50%', background: 'var(--teal)' }}
              />
            )}
            {BADGE_TEXT[state]}
          </span>
        )}
        {frozen && (
          <span
            data-testid="cockpit-containment-pill"
            style={{ fontSize: 11, fontWeight: 700, color: 'var(--error)', border: '1px solid var(--error)', borderRadius: 4, padding: '2px 8px' }}
          >
            CONTAINED: FROZEN
          </span>
        )}
        <span
          data-testid="cockpit-connection"
          data-connection={connection}
          style={{ marginLeft: 'auto', fontSize: 11, color: connection === 'live' ? 'var(--teal)' : 'var(--amber)' }}
        >
          {CONNECTION_TEXT[connection]}
        </span>
      </div>

      <div style={{ display: 'flex', alignItems: 'baseline', gap: 24, flexWrap: 'wrap' }}>
        <div>
          <div style={{ fontSize: 11, color: 'var(--muted)' }}>CPU</div>
          <div
            id="cockpit-cpu-metric"
            data-testid="cockpit-cpu-metric"
            style={{
              fontSize: 26,
              fontWeight: frozen ? 800 : 600,
              fontVariantNumeric: 'tabular-nums',
              color: frozen ? 'var(--error)' : 'var(--text)',
            }}
          >
            {cpuText}
          </div>
        </div>
        <div>
          <div style={{ fontSize: 11, color: 'var(--muted)' }}>Resident memory (RSS)</div>
          <div data-testid="cockpit-memory-metric" style={{ fontSize: 20, fontWeight: 600, fontVariantNumeric: 'tabular-nums' }}>
            {latest ? formatMiB(latest.memoryRssMiB) : 'awaiting'}
          </div>
        </div>
        {stale && latest && (
          <span data-testid="cockpit-stale" role="note" style={{ fontSize: 11, color: 'var(--amber)' }}>
            STALE READING · no sample recently; not current
          </span>
        )}
      </div>

      {samples.length > 0 ? (
        <Sparkline samples={samples} windowSize={windowSize} frozen={frozen} />
      ) : (
        <div data-testid="cockpit-awaiting" style={{ fontSize: 12, color: 'var(--muted)', padding: '12px 0' }}>
          {connection === 'error' ? 'Telemetry stream unavailable.' : 'Awaiting first telemetry sample…'}
        </div>
      )}

      <div
        data-testid="cockpit-live-region"
        role="status"
        aria-live={frozen ? 'assertive' : 'polite'}
        aria-atomic="true"
        style={{ position: 'absolute', width: 1, height: 1, overflow: 'hidden', clip: 'rect(0 0 0 0)', whiteSpace: 'nowrap' }}
      >
        {liveSentence(podName, state, latest)}
      </div>
    </section>
  )
})

interface BoundaryState {
  failed: boolean
}

/** Keeps a renderer fault in the visualiser from blanking the /agents page. */
export class TelemetryErrorBoundary extends Component<{ children: ReactNode; podName?: string }, BoundaryState> {
  state: BoundaryState = { failed: false }

  static getDerivedStateFromError(): BoundaryState {
    return { failed: true }
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    console.warn('AgentCockpitTelemetry failed to render', error, info.componentStack)
  }

  render(): ReactNode {
    if (this.state.failed) {
      return (
        <div data-testid="cockpit-telemetry-fallback" role="alert" className="card" style={{ padding: 16, fontSize: 13, color: 'var(--muted)' }}>
          Live telemetry{this.props.podName ? ` for ${this.props.podName}` : ''} is unavailable right now. The agent&apos;s
          containment state is unaffected; reload to retry the stream.
        </div>
      )
    }
    return this.props.children
  }
}

function LiveCockpit({ podName, options }: { podName: string; options?: TelemetryHookOptions }) {
  const { samples, connection, stale } = useAgentTelemetry(podName, options)
  return (
    <AgentCockpitTelemetryView
      podName={podName}
      samples={samples}
      connection={connection}
      stale={stale}
      windowSize={options?.windowSize ?? 15}
    />
  )
}

export default function AgentCockpitTelemetry({ podName, options }: { podName: string; options?: TelemetryHookOptions }) {
  return (
    <TelemetryErrorBoundary podName={podName}>
      <LiveCockpit podName={podName} options={options} />
    </TelemetryErrorBoundary>
  )
}
