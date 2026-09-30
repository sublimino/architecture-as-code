// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * The /agents full-width cockpit slot (SLDC-P4-2).
 *
 * Kept out of AgentsPage.tsx on purpose: that page is shared with sibling
 * cards, so it carries one line that mounts this and nothing else. The pod
 * list comes from the estate stream, so the picker only offers pods the
 * telemetry pipeline actually monitors. `?pod=` preselects one.
 */
import { useMemo, useState } from 'react'
import AgentCockpitTelemetry from './AgentCockpitTelemetry'
import { useEstateTelemetry } from '../hooks/useAgentTelemetry'

function initialPod(): string | null {
  try {
    return new URLSearchParams(window.location.search).get('pod')
  } catch {
    return null
  }
}

export default function AgentCockpitSection() {
  const { pods } = useEstateTelemetry()
  const [chosen, setChosen] = useState<string | null>(initialPod)
  const podNames = useMemo(() => [...new Set(pods.map((p) => p.podName))].sort(), [pods])
  const podName = chosen ?? podNames[0] ?? null

  return (
    <div data-testid="agent-cockpit-section" style={{ marginBottom: 20, display: 'flex', flexDirection: 'column', gap: 8 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
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
