/**
 * Agent Auto-Claim API — the lifecycle handshake between a new agent pod
 * and the Signal Loom platform.
 *
 * When an agent starts, its OpenBao sidecar calls the claim endpoint with
 * its SPIFFE identity and declared capabilities. Signal Loom verifies the
 * SVID, allocates a token budget, binds the eBPF sentinel, and returns a
 * claim ID the agent uses for all subsequent API calls.
 *
 * This module defines the request/response types and the client functions
 * the dashboard uses to display and manage claims.
 */

// ─── Types ──────────────────────────────────────────────────────────────────

export interface AgentClaimRequest {
  /** Pod name in the cluster. */
  pod_name: string
  /** Namespace the pod runs in. */
  namespace: string
  /** SPIFFE ID from the agent's JWT-SVID. */
  spiffe_id: string
  /** Runtime harness — claude-code, daytona, openai-codex, etc. */
  harness: string
  /** LLM model backing the agent. */
  model: string
  /** Tools the agent declares it will use. */
  declared_tools: string[]
  /** Maximum token budget the agent requests (0 = platform default). */
  token_budget_limit: number
}

export interface AgentClaimResponse {
  /** Unique claim identifier — the agent's session key. */
  claim_id: string
  /** Claim status: granted, denied, pending-review. */
  status: 'granted' | 'denied' | 'pending-review'
  /** Whether the SPIFFE SVID was cryptographically verified. */
  spiffe_svid_verified: boolean
  /** Allocated token budget (may be less than requested). */
  allocated_token_budget: number
  /** WebSocket URL for the Signal session (real-time monitoring). */
  signal_session_url: string | null
  /** Whether the eBPF sentinel is bound to this agent's cgroup. */
  ebpf_sentinel_bound: boolean
}

export type ClaimStatus = AgentClaimResponse['status']

export interface ClaimRecord {
  claim_id: string
  pod_name: string
  namespace: string
  spiffe_id: string
  harness: string
  model: string
  status: ClaimStatus
  allocated_token_budget: number
  claimed_at: string
  released_at: string | null
}

// ─── API functions ──────────────────────────────────────────────────────────

const BASE = (import.meta.env.VITE_API_BASE_URL as string) ?? ''

/**
 * Submit a claim request for a new agent pod.
 *
 * Called by the OpenBao sidecar's process_supervisor hook, or manually
 * from the dashboard's agent management panel.
 */
export async function submitClaim(
  request: AgentClaimRequest,
  signal?: AbortSignal,
): Promise<AgentClaimResponse> {
  const res = await fetch(`${BASE}/api/v1/agents/claim`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(request),
    signal,
  })
  if (!res.ok) {
    const body = await res.text().catch(() => '')
    throw new Error(`Claim failed (${res.status}): ${body}`)
  }
  return res.json() as Promise<AgentClaimResponse>
}

/**
 * Release a claim — called when an agent is shutting down or being stunned.
 */
export async function releaseClaim(
  claimId: string,
  signal?: AbortSignal,
): Promise<void> {
  const res = await fetch(`${BASE}/api/v1/agents/claim/${encodeURIComponent(claimId)}`, {
    method: 'DELETE',
    signal,
  })
  if (!res.ok && res.status !== 404) {
    throw new Error(`Release failed (${res.status})`)
  }
}

/**
 * List all active claims — used by the dashboard's Agent Overview panel.
 */
export async function listClaims(
  signal?: AbortSignal,
): Promise<ClaimRecord[]> {
  const res = await fetch(`${BASE}/api/v1/agents/claims`, { signal })
  if (!res.ok) {
    console.warn(`[agentClaim] listClaims returned ${res.status}`)
    return []
  }
  const data = await res.json() as { claims?: ClaimRecord[] }
  return data.claims ?? []
}

/**
 * Get a single claim by ID.
 */
export async function getClaim(
  claimId: string,
  signal?: AbortSignal,
): Promise<ClaimRecord | null> {
  const res = await fetch(
    `${BASE}/api/v1/agents/claim/${encodeURIComponent(claimId)}`,
    { signal },
  )
  if (res.status === 404) return null
  if (!res.ok) {
    throw new Error(`getClaim failed (${res.status})`)
  }
  return res.json() as Promise<ClaimRecord>
}
