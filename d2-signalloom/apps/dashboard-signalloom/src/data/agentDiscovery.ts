/**
 * Label-driven agent discovery for the Signal Loom agent swarm.
 *
 * Replaces hardcoded workload dictionaries with a label contract: every
 * agent pod carries `signalloom.ai/*` labels, and the fake-integration-proxy
 * surfaces them verbatim on GET /supercred-api/agents. This module defines
 * the label schema, the discovery record type, and the fetch function.
 *
 * ## Label contract
 *
 * Every agent pod MUST carry:
 *   signalloom.ai/agent: "true"          — discovery gate
 *   signalloom.ai/tenant: <tenant-id>    — multi-tenant scoping
 *   signalloom.ai/project: <project-id>  — project association
 *   signalloom.ai/role: <functional-role> — what the agent does
 *
 * Optional but expected:
 *   signalloom.ai/harness: <harness>     — runtime harness (e.g. claude-code, daytona)
 *   signalloom.ai/model: <model>         — LLM model backing the agent
 *   signalloom.ai/state: <state>         — lifecycle state (active, stunned, claimed)
 *
 * ## Provenance
 *
 * Same contract as credentialInventory.ts: every record carries `provenance`
 * so the dashboard never presents modelled data as measured.
 */

import { TRUST_DOMAIN, spiffeId, type Provenance } from './credentialInventory'

// ─── Label contract ─────────────────────────────────────────────────────────

/**
 * The canonical label keys the platform uses for agent discovery and policy.
 * These are the keys — values are workload-specific.
 */
export const AGENT_LABELS = {
  /** Discovery gate — must be "true" for the pod to be treated as an agent. */
  agent: 'signalloom.ai/agent',
  /** Multi-tenant isolation key. */
  tenant: 'signalloom.ai/tenant',
  /** Project association — maps to Signal Loom project constructs. */
  project: 'signalloom.ai/project',
  /** Functional role — summarizer, ci-worker, engineer, etc. */
  role: 'signalloom.ai/role',
  /** Runtime harness — claude-code, daytona, openai-codex, etc. */
  harness: 'signalloom.ai/harness',
  /** LLM model backing the agent — claude-sonnet-4, gpt-4.1, etc. */
  model: 'signalloom.ai/model',
  /** Lifecycle state — active, stunned, claimed, draining. */
  state: 'signalloom.ai/state',
} as const

export type AgentLabelKey = keyof typeof AGENT_LABELS

// ─── Discovery record ───────────────────────────────────────────────────────

export interface AgentDiscoveryRecord {
  /** Pod name in the cluster. */
  pod_name: string
  /** Namespace the pod runs in. */
  namespace: string
  /** Service account — second segment of the SPIFFE ID. */
  service_account: string
  /** Derived SPIFFE ID: spiffe://signalloom.demo/ns/<ns>/sa/<sa>. */
  spiffe_id: string
  /** Tenant ID from the signalloom.ai/tenant label. */
  tenant: string
  /** Project ID from the signalloom.ai/project label. */
  project: string
  /** Functional role from signalloom.ai/role. */
  role: string
  /** Runtime harness from signalloom.ai/harness. */
  harness: string | null
  /** LLM model from signalloom.ai/model. */
  model: string | null
  /** Lifecycle state from signalloom.ai/state. */
  state: string | null
  /** Pod creation timestamp. */
  created_at: string | null
  /** Data provenance — live from the proxy, or demo fixture. */
  provenance: Provenance
}

// ─── Proxy response shape ───────────────────────────────────────────────────

/** Raw agent record from GET /supercred-api/agents with label fields. */
interface ProxyAgentRecord {
  id: string
  name?: string | null
  namespace?: string | null
  service_account?: string | null
  state?: string | null
  created_at?: string | null
  /** Labels surfaced by the proxy from pod metadata. */
  labels?: Record<string, string> | null
}

// ─── Discovery function ─────────────────────────────────────────────────────

/**
 * Fetch agent pods from the integration proxy and return typed discovery
 * records. Falls back to demo fixtures when the proxy is unreachable.
 *
 * @param baseUrl - API base URL (defaults to window origin)
 * @param signal  - AbortSignal for cancellation
 */
export async function discoverAgents(
  baseUrl?: string,
  signal?: AbortSignal,
): Promise<AgentDiscoveryRecord[]> {
  const base = baseUrl ?? ''
  try {
    const res = await fetch(`${base}/supercred-api/agents`, { signal })
    if (!res.ok) {
      console.warn(`[agentDiscovery] proxy returned ${res.status}, falling back to demo data`)
      return DEMO_AGENTS
    }
    const data = await res.json() as { agents?: ProxyAgentRecord[] }
    const agents = data.agents ?? []
    return agents
      .filter((a) => a.labels?.[AGENT_LABELS.agent] === 'true')
      .map((a) => proxyRecordToDiscovery(a, 'live'))
  } catch (err) {
    console.warn('[agentDiscovery] proxy unreachable, using demo data', err)
    return DEMO_AGENTS
  }
}

function proxyRecordToDiscovery(
  raw: ProxyAgentRecord,
  provenance: Provenance,
): AgentDiscoveryRecord {
  const ns = raw.namespace ?? 'fe-signalloom-agents'
  const sa = raw.service_account ?? raw.name ?? 'unknown'
  const labels = raw.labels ?? {}
  return {
    pod_name: raw.name ?? raw.id,
    namespace: ns,
    service_account: sa,
    spiffe_id: spiffeId(ns, sa),
    tenant: labels[AGENT_LABELS.tenant] ?? 'default',
    project: labels[AGENT_LABELS.project] ?? 'unassigned',
    role: labels[AGENT_LABELS.role] ?? 'unknown',
    harness: labels[AGENT_LABELS.harness] ?? null,
    model: labels[AGENT_LABELS.model] ?? null,
    state: raw.state ?? labels[AGENT_LABELS.state] ?? null,
    created_at: raw.created_at ?? null,
    provenance,
  }
}

// ─── Demo fixtures ──────────────────────────────────────────────────────────

/**
 * Offline fixture set. Uses real trust domain and realistic label values
 * so the demo teaches the right mental model.
 */
export const DEMO_AGENTS: AgentDiscoveryRecord[] = [
  {
    pod_name: 'prompt-commit-summarizer-7f8d4',
    namespace: 'fe-signalloom-agents',
    service_account: 'prompt-commit-summarizer',
    spiffe_id: spiffeId('fe-signalloom-agents', 'prompt-commit-summarizer'),
    tenant: 'acme-corp',
    project: 'osramp-core',
    role: 'summarizer',
    harness: 'claude-code',
    model: 'claude-sonnet-4',
    state: 'active',
    created_at: new Date().toISOString(),
    provenance: 'demo',
  },
  {
    pod_name: 'triage-ci-worker-3a2b1',
    namespace: 'fe-signalloom-agents',
    service_account: 'triage-ci-worker',
    spiffe_id: spiffeId('fe-signalloom-agents', 'triage-ci-worker'),
    tenant: 'acme-corp',
    project: 'osramp-core',
    role: 'ci-worker',
    harness: 'openai-codex',
    model: 'gpt-4.1',
    state: 'active',
    created_at: new Date().toISOString(),
    provenance: 'demo',
  },
  {
    pod_name: 'swarm-governor-9c4e2',
    namespace: 'fe-signalloom-agents',
    service_account: 'swarm-governor',
    spiffe_id: spiffeId('fe-signalloom-agents', 'swarm-governor'),
    tenant: 'acme-corp',
    project: 'osramp-core',
    role: 'governor',
    harness: 'claude-code',
    model: 'claude-opus-4',
    state: 'active',
    created_at: new Date().toISOString(),
    provenance: 'demo',
  },
  {
    pod_name: 'agent-cardvault-1d5f7',
    namespace: 'fe-signalloom-agents',
    service_account: 'agent-cardvault',
    spiffe_id: spiffeId('fe-signalloom-agents', 'agent-cardvault'),
    tenant: 'acme-corp',
    project: 'pci-compliance',
    role: 'cardvault',
    harness: 'claude-code',
    model: 'claude-sonnet-4',
    state: 'claimed',
    created_at: new Date().toISOString(),
    provenance: 'demo',
  },
  {
    pod_name: 'signalloom-stun-sentinel-node1',
    namespace: 'fe-signalloom-agents',
    service_account: 'signalloom-stun-sentinel',
    spiffe_id: spiffeId('fe-signalloom-agents', 'signalloom-stun-sentinel'),
    tenant: 'platform',
    project: 'signalloom-infra',
    role: 'sentinel',
    harness: null,
    model: null,
    state: 'active',
    created_at: new Date().toISOString(),
    provenance: 'demo',
  },
]
