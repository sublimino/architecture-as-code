/**
 * Live OpenFAIR risk client.
 *
 * ─── Why this goes through req() ───────────────────────────────────────────
 *
 * `req()` in client.ts is the ONE place the app decides between fixtures and
 * the network. A client that called axios directly would be live even with the
 * DemoToggle showing `● DEMO DATA`, which is precisely the asymmetry that makes
 * `connectorsClient.ts` (always mock) and `onboardingClient.ts` (always live)
 * so misleading to debug. Routing through req() also inherits, for free, the
 * in-flight GET coalescing and the per-caller cancellation the risk hooks rely
 * on when the operator flips the toggle mid-request.
 *
 * ─── The path, and why it is configurable ──────────────────────────────────
 *
 * req() prefixes `/api` to any path that does not already start with it, so
 * `/v1/risk/agents/x` reaches `/api/v1/risk/agents/x` — the endpoint named in
 * the Phase 2 work decomposition.
 *
 * The prefix is an env var because the service half (CRKC-P2-1) is being built
 * in a parallel worktree and the gateway rewrite in front of it is CRKC-P2-3's.
 * Neither is merged at the time this file is written. A hardcoded path would
 * make a deployment-shaped disagreement into a code change; an env var makes it
 * a values change. See docs/signalloom/dashboard-live-data-integration.md.
 */

import { req } from './client'
import { isDemoMode } from './demoMode'
import {
  normalizeAgentRisk,
  normalizeFleetRisk,
  type AgentRisk,
  type FleetRisk,
} from '../types/fair'

/**
 * Base path for the FAIR risk surface, WITHOUT the `/api` prefix req() adds.
 *
 * Default `/v1/risk` → `/api/v1/risk/...`.
 */
export const FAIR_API_PREFIX =
  ((import.meta.env.VITE_FAIR_API_PREFIX as string) ?? '/v1/risk').replace(/\/+$/, '')

export const fairApi = {
  /**
   * Live risk for one agent.
   *
   * The id is percent-encoded because agent ids in this estate are
   * tenant-qualified (`tenant-demo:agent-triage`) and a bare colon in a path
   * segment is legal-but-ambiguous to some proxies.
   */
  getAgentRisk: async (
    token: string,
    agentId: string,
    signal?: AbortSignal,
  ): Promise<AgentRisk> => {
    const raw = await req<unknown>(
      `${FAIR_API_PREFIX}/agents/${encodeURIComponent(agentId)}`,
      token,
      { signal },
    )
    return normalizeAgentRisk(raw, agentId)
  },

  /** Fleet-level rollup across every agent the caller can see. */
  getFleetRisk: async (token: string, signal?: AbortSignal): Promise<FleetRisk> => {
    const raw = await req<unknown>(`${FAIR_API_PREFIX}/fleet`, token, { signal })
    return normalizeFleetRisk(raw)
  },

  /**
   * Which data plane a risk figure is about to come from.
   *
   * Exposed so a component can label provenance BEFORE the request settles,
   * rather than rendering an unlabelled figure for the duration of the fetch.
   */
  currentSource: (): 'fixture' | 'riskctl' => (isDemoMode() ? 'fixture' : 'riskctl'),
}
