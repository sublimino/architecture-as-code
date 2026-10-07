// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * The Agent Containment Cockpit (SLDC-P4-2).
 *
 * Visualises live cAdvisor CPU and resident memory (RSS) telemetry.
 * When mounted with an `agent`, it resolves the corresponding pod name
 * (from agent runtime metadata, estate telemetry, or name/id fallback)
 * and preselects it, while keeping all available monitored pods accessible
 * in the selector dropdown.
 */
import { useEffect, useMemo, useRef, useState, type CSSProperties } from 'react'
import AgentCockpitTelemetry from './AgentCockpitTelemetry'
import { useEstateTelemetry } from '../hooks/useAgentTelemetry'
import type { AgentResponse } from '../types/api'
import type { TelemetrySample } from '../api/agentTelemetry'

function initialPod(): string | null {
  try {
    return new URLSearchParams(window.location.search).get('pod')
  } catch {
    return null
  }
}

export function resolveAgentPod(
  agent: AgentResponse | null | undefined,
  pods: TelemetrySample[] = []
): string | null {
  if (!agent) return null
  const explicit = agent.runtime?.pod_name || (agent as any).pod_name
  if (explicit) return explicit

  const id = agent.id?.includes(':') ? agent.id.split(':').pop()! : agent.id
  const name = agent.name

  // 1. Exact match against monitored pods in telemetry
  const exact = pods.find((p) => p.podName === id || p.podName === name || p.podName === agent.id)
  if (exact) return exact.podName

  // 2. Prefix match against monitored pods (e.g. agent-cardvault-1d5f7 for agent-cardvault)
  if (id) {
    const prefix = pods.find((p) => p.podName.startsWith(`${id}-`) || p.podName.includes(id))
    if (prefix) return prefix.podName
  }
  if (name) {
    const namePrefix = pods.find((p) => p.podName.startsWith(`${name}-`) || p.podName.includes(name))
    if (namePrefix) return namePrefix.podName
  }

  // 3. Fallback to clean id or name
  return id || name || null
}

export interface AgentCockpitSectionProps {
  agent?: AgentResponse | null
  targetPod?: string | null
  className?: string
  style?: CSSProperties
}

export default function AgentCockpitSection({
  agent,
  targetPod,
  className,
  style,
}: AgentCockpitSectionProps = {}) {
  const { pods } = useEstateTelemetry()
  const [chosen, setChosen] = useState<string | null>(initialPod)

  const agentKey = agent?.id ?? targetPod ?? null
  const prevAgentKeyRef = useRef(agentKey)
  useEffect(() => {
    if (prevAgentKeyRef.current !== agentKey) {
      prevAgentKeyRef.current = agentKey
      setChosen(null)
    }
  }, [agentKey])

  const defaultPod = useMemo(() => {
    if (targetPod) return targetPod
    return resolveAgentPod(agent, pods)
  }, [targetPod, agent, pods])

  const podNames = useMemo(() => {
    const set = new Set(pods.map((p) => p.podName))
    if (defaultPod) set.add(defaultPod)
    return [...set].sort()
  }, [pods, defaultPod])

  const podName = chosen ?? defaultPod ?? podNames[0] ?? null

  return (
    <div
      data-testid="agent-cockpit-section"
      className={className}
      style={{ marginBottom: 20, display: 'flex', flexDirection: 'column', gap: 8, ...style }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, justifyContent: 'space-between', flexWrap: 'wrap' }}>
        <h2 style={{ fontSize: 14, fontWeight: 700, margin: 0 }}>Live containment cockpit</h2>
        {podNames.length > 0 && (
          <select
            aria-label="Agent pod for live telemetry"
            data-testid="cockpit-pod-select"
            className="input"
            value={podName ?? ''}
            onChange={(e) => setChosen(e.target.value)}
            style={{ fontSize: 12, padding: '2px 6px' }}
          >
            {podName && !podNames.includes(podName) && <option value={podName}>{podName}</option>}
            {podNames.map((p) => (
              <option key={p} value={p}>{p}</option>
            ))}
          </select>
        )}
      </div>
      {podName ? (
        <AgentCockpitTelemetry podName={podName} />
      ) : (
        <div data-testid="cockpit-no-pods" style={{ fontSize: 12, color: 'var(--muted)' }}>
          No monitored agent pods reported by the telemetry pipeline yet.
        </div>
      )}
    </div>
  )
}
