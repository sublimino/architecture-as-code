// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Mount point for the cluster-free coding-agent topology harness.
 *
 * Renders the REAL CodingAgentsTab — the same module AgentsPage.tsx:1623 ships
 * — against the scripted telemetry store in coding-agents-server.ts. This file
 * is a `createRoot` call. It reimplements nothing and it styles nothing.
 *
 * No theme code here, for the reason harness/entry.tsx records: index.html
 * links the app's real `styles/global.css`, which carries the `:root` palette,
 * the font stack, the base font-size and line-height, and the `.card`, `.tag`,
 * `.kicker`, `.btn` and `.input` classes CodingAgentsTab and CodingAgentCard
 * use BY NAME. Copying a subset of those onto documentElement would produce a
 * page with the app's colours and the browser's typography, which is not the
 * app — and would be a second source of truth for the one thing themes.test.ts
 * exists to keep single.
 *
 * The tenant banner is the only thing added, and it is added deliberately: a
 * cross-tenant isolation failure that shows the WRONG tenant's cards is
 * indistinguishable from a harness that was pointed at the wrong tenant, unless
 * the identity actually in play is visible in the DOM. The spec asserts it.
 */
import { createRoot } from 'react-dom/client'
import { CodingAgentsTab } from '../../../d2-signalloom/apps/dashboard-signalloom/src/components/CodingAgentsTab'
import { HARNESS_TENANT } from './coding-agents-auth-stub'

const root = document.getElementById('root')
if (!root) throw new Error('coding-agents harness: #root is missing from index.html')

function HarnessApp() {
  return (
    <div style={{ padding: 24, display: 'flex', flexDirection: 'column', gap: 16 }}>
      <div
        data-testid="harness-tenant"
        data-tenant={HARNESS_TENANT}
        style={{ fontSize: 12, fontFamily: 'monospace', color: 'var(--muted)' }}
      >
        harness tenant: {HARNESS_TENANT}
      </div>
      <CodingAgentsTab />
    </div>
  )
}

createRoot(root).render(<HarnessApp />)
