// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Mount point for the cluster-free cockpit telemetry harness (SLDC-P4-2).
 *
 * Renders the REAL MetricsTopBar and the REAL AgentCockpitTelemetry, with
 * their real hook, transport and SSE parser, against the scripted streams in
 * cockpit-telemetry-server.ts. Only auth/oidc is swapped (see auth-stub.tsx).
 * The nav strip mimics TopNav's flex layout so the medium-viewport overflow
 * check measures the bar in the space it actually gets.
 */
import { createRoot } from 'react-dom/client'
import MetricsTopBar from '../../../d2-signalloom/apps/dashboard-signalloom/src/components/MetricsTopBar'
import AgentCockpitTelemetry from '../../../d2-signalloom/apps/dashboard-signalloom/src/components/AgentCockpitTelemetry'

const root = document.getElementById('root')
if (!root) throw new Error('cockpit harness: #root is missing from index.html')

const pod = new URLSearchParams(window.location.search).get('pod') ?? 'kusari-agent-0'
const NAV = ['Agents', 'Compliance', 'Audit Trail', 'Settings']

createRoot(root).render(
  <>
    <nav
      data-testid="harness-nav"
      style={{ height: 60, display: 'flex', alignItems: 'center', padding: '0 32px', background: 'var(--surface)', borderBottom: '1px solid var(--border)' }}
    >
      <span style={{ fontWeight: 700, marginRight: 24, flexShrink: 0 }}>Signal Loom</span>
      <div style={{ display: 'flex', gap: 4, flex: 1 }}>
        {NAV.map((l) => (
          <a key={l} data-testid="harness-nav-link" href="#" style={{ padding: '6px 14px', fontSize: 13, whiteSpace: 'nowrap' }}>{l}</a>
        ))}
      </div>
      <MetricsTopBar />
      <div data-testid="harness-nav-right" style={{ display: 'flex', gap: 12, flexShrink: 0 }}>
        <button className="btn btn-secondary" style={{ fontSize: 12 }}>Help</button>
        <button className="btn" style={{ fontSize: 12 }}>Sign out</button>
      </div>
    </nav>
    <main style={{ padding: 24 }}>
      <AgentCockpitTelemetry podName={pod} />
    </main>
  </>,
)
