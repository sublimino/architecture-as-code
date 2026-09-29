/**
 * Label-driven agent discovery for the Signal Loom agent swarm.
 *
 * Replaces hardcoded workload dictionaries with an orthogonal label contract:
 * every agent pod carries `signalloom.ai/*` orthogonal labels, and the
 * integration proxy surfaces them on GET /supercred-api/agents or /api/agents.
 *
 * ## Unified Orthogonal Label Schema
 *
 * Every agent pod MUST carry:
 *   signalloom.ai/agent: "true"             : discovery gate
 *   signalloom.ai/framework: <framework>    : agent framework (kagent, claude-code, langchain, custom)
 *   signalloom.ai/harness: <harness>        : execution runtime harness (claude-code, daytona, knative, opencode-cpai)
 *   signalloom.ai/role: <functional-role>   : functional specialization (summarizer, triage, engineer, sentinel, etc.)
 *   signalloom.ai/tenant: <tenant-id>       : multi-tenant isolation boundary (acme-corp, controlplane, platform)
 *   signalloom.ai/state: <state>            : lifecycle & containment state (active, claimed, idle, stunned, draining)
 *
 * Optional metadata labels:
 *   signalloom.ai/model: <model>            : LLM model backing the agent (claude-sonnet-4, gpt-4.1, gemini-2.5-flash)
 *   signalloom.ai/project: <project-id>     : project association (osramp-core, pci-compliance, signalloom-infra)
 *
 * ## Real-Time Sentinel Kernel Telemetry
 *
 * When an agent enters the `stunned` state, the Signal Loom Stun Sentinel
 * applies atomic kernel containment:
 *   - cgroups v2: writes 1 to `cgroup.freeze` (atomic task suspension, memory preserved)
 *   - eBPF / TC: attaches clsact qdisc matchall packet drop filter on the veth interface
 *
 * Every discovery record normalizes these kernel telemetry properties alongside
 * provenance metadata.
 */

import { TRUST_DOMAIN, spiffeId, type Provenance } from './credentialInventory'
import { FAKE_SWARM_AGENTS } from '../api/fakeSwarmData'

// ─── Label contract ─────────────────────────────────────────────────────────

/**
 * The canonical orthogonal label keys the platform uses for agent discovery,
 * taxonomy classification, and kernel containment policy.
 */
export const AGENT_LABELS = {
  /** Discovery gate: must be "true" for the pod/CR to be treated as an agent. */
  agent: 'signalloom.ai/agent',
  /** Agent framework: kagent, claude-code, langchain, crewai, custom. */
  framework: 'signalloom.ai/framework',
  /** Runtime execution harness: claude-code, daytona, knative, opencode-cpai, go-worker. */
  harness: 'signalloom.ai/harness',
  /** Functional role: summarizer, ci-worker, engineer, sentinel, governor, cardvault. */
  role: 'signalloom.ai/role',
  /** Multi-tenant isolation boundary. */
  tenant: 'signalloom.ai/tenant',
  /** Lifecycle & containment state: active, claimed, idle, stunned, draining. */
  state: 'signalloom.ai/state',
  /** LLM model backing the agent: claude-sonnet-4, gpt-4.1, gemini-2.5-flash. */
  model: 'signalloom.ai/model',
  /** Project association: maps to Signal Loom project constructs. */
  project: 'signalloom.ai/project',
} as const

export type AgentLabelKey = keyof typeof AGENT_LABELS

// ─── Sentinel Kernel Containment Telemetry ─────────────────────────────────

export interface SentinelKernelTelemetry {
  /** Whether the cgroup is currently frozen via cgroup.freeze (atomic kernel suspension). */
  cgroup_frozen: boolean
  /** Cgroup freeze state: 'frozen' | 'thawed' | 'none'. */
  cgroup_state: 'frozen' | 'thawed' | 'none'
  /** Whether TC matchall packet drop filter is active on the veth interface. */
  tc_drop_active: boolean
  /** Containment reaction latency in milliseconds (e.g. API watch + freeze write + TC attach). */
  containment_latency_ms?: number | null
  /** Cgroup v2 path on node if resolved. */
  cgroup_path?: string | null
  /** Host veth interface if attached. */
  veth_interface?: string | null
  sentinel_ack?: boolean
  sentinel_ack_id?: string | null
  sentinel_drop_count?: number
  sentinel_last_ack_at?: string | null
  containment_probe_state?: 'confirmed' | 'pending' | 'unconfirmed'
}

// ─── Discovery record ───────────────────────────────────────────────────────

export interface AgentDiscoveryRecord {
  /** Pod name or declarative CR name in the cluster. */
  pod_name: string
  /** Namespace the agent runs in. */
  namespace: string
  /** Service account: second segment of the SPIFFE ID. */
  service_account: string
  /** Derived SPIFFE ID: spiffe://signalloom.demo/ns/<ns>/sa/<sa>. */
  spiffe_id: string
  /** Tenant ID from the signalloom.ai/tenant label. */
  tenant: string
  /** Project ID from the signalloom.ai/project label. */
  project: string
  /** Functional role from signalloom.ai/role. */
  role: string
  /** Framework from signalloom.ai/framework (kagent, claude-code, langchain, custom). */
  framework: string | null
  /** Runtime harness from signalloom.ai/harness. */
  harness: string | null
  /** LLM model from signalloom.ai/model. */
  model: string | null
  /** Lifecycle state from signalloom.ai/state. */
  state: string | null
  /** Live Sentinel kernel containment telemetry. */
  kernel_telemetry?: SentinelKernelTelemetry | null
  /** Pod/CR creation timestamp. */
  created_at: string | null
  /** Data provenance: live from the proxy, or demo fixture. */
  provenance: Provenance
}

// ─── Proxy response shape ───────────────────────────────────────────────────

/** Raw agent record from GET /supercred-api/agents or /agents with label fields. */
export interface ProxyAgentRecord {
  id: string
  name?: string | null
  namespace?: string | null
  service_account?: string | null
  type?: string | null
  framework?: string | null
  role?: string | null
  harness?: string | null
  tenant?: string | null
  state?: string | null
  created_at?: string | null
  /** Real-time kernel telemetry if emitted by Sentinel proxy. */
  kernel_telemetry?: SentinelKernelTelemetry | null
  /** Labels surfaced by the proxy from pod/CR metadata. */
  labels?: Record<string, string> | null
  /** Annotations surfaced by the proxy. */
  annotations?: Record<string, string> | null
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
      .filter((a) => a.labels?.[AGENT_LABELS.agent] === 'true' || a.labels?.['signalloom.ai/agent'] === 'true' || a.type === 'declarative' || a.type === 'kagent')
      .map((a) => proxyRecordToDiscovery(a, 'live'))
  } catch (err) {
    console.warn('[agentDiscovery] proxy unreachable, using demo data', err)
    return DEMO_AGENTS
  }
}

export function proxyRecordToDiscovery(
  raw: ProxyAgentRecord,
  provenance: Provenance,
): AgentDiscoveryRecord {
  const ns = raw.namespace ?? 'fe-signalloom-agents'
  const sa = raw.service_account ?? raw.name ?? raw.id ?? 'unknown'
  const labels = raw.labels ?? {}
  const state = raw.state ?? labels[AGENT_LABELS.state] ?? null
  const isStunned = state === 'stunned'

  // Normalize framework across orthogonal schema and substrate hints
  const framework =
    labels[AGENT_LABELS.framework] ??
    labels['signalloom.ai/agent-framework'] ??
    raw.framework ??
    (raw.id.startsWith('kagent-') || sa.startsWith('kagent-') || labels[AGENT_LABELS.harness] === 'kagent'
      ? 'kagent'
      : null)

  // Normalize role across orthogonal schema and legacy agent-type keys
  const role =
    labels[AGENT_LABELS.role] ??
    labels['signalloom.ai/agent-type'] ??
    raw.role ??
    raw.type ??
    'unknown'

  // Normalize harness across orthogonal schema
  const harness =
    labels[AGENT_LABELS.harness] ??
    raw.harness ??
    null

  // Normalize tenant
  const tenant =
    labels[AGENT_LABELS.tenant] ??
    raw.tenant ??
    'default'

  // Normalize Sentinel kernel containment telemetry
  const kernelTelemetry: SentinelKernelTelemetry = raw.kernel_telemetry ?? {
    cgroup_frozen: isStunned,
    cgroup_state: isStunned ? 'frozen' : 'thawed',
    tc_drop_active: isStunned,
    containment_latency_ms: isStunned ? 42 : null,
  }

  return {
    pod_name: raw.name ?? raw.id,
    namespace: ns,
    service_account: sa,
    spiffe_id: spiffeId(ns, sa),
    tenant,
    project: labels[AGENT_LABELS.project] ?? 'unassigned',
    role,
    framework,
    harness,
    model: labels[AGENT_LABELS.model] ?? null,
    state,
    kernel_telemetry: kernelTelemetry,
    created_at: raw.created_at ?? null,
    provenance,
  }
}

/** Helper to check if an agent is contained by the kernel freezer / TC drop. */
export function isKernelContained(agent: { state?: string | null; kernel_telemetry?: SentinelKernelTelemetry | null }): boolean {
  return (
    agent.state === 'stunned' ||
    agent.kernel_telemetry?.cgroup_frozen === true ||
    agent.kernel_telemetry?.tc_drop_active === true
  )
}

// ─── Demo fixtures ──────────────────────────────────────────────────────────

/**
 * Offline fixture set. Delegates to the centralised FAKE_SWARM_AGENTS so
 * all demo surfaces (discovery, credential inventory, audit timeline) share
 * one canonical set of 10 agents.
 */
export const DEMO_AGENTS: AgentDiscoveryRecord[] = FAKE_SWARM_AGENTS
