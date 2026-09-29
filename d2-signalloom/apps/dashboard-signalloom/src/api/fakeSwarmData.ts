/**
 * Demo data fixtures for the swarm agent lifecycle.
 *
 * Used when `isDemoMode()` returns true so the dashboard renders a realistic
 * swarm without a live cluster. All 10 agents, their credential records,
 * and a representative audit trail covering the full lifecycle.
 */

import { spiffeId } from '../data/credentialInventory'
import type { CredentialRecord } from '../data/credentialInventory'
import type { AgentDiscoveryRecord } from '../data/agentDiscovery'
import type { SwarmAuditEvent } from './swarmAuditEvents'

// ─── Timestamp helpers ─────────────────────────────────────────────────────

const NOW = new Date()
function ago(minutes: number): string {
  return new Date(NOW.getTime() - minutes * 60_000).toISOString()
}

// ─── Swarm namespace ───────────────────────────────────────────────────────

const NS = 'fe-signalloom-agents'

// ─── 10 swarm agents ───────────────────────────────────────────────────────

export const FAKE_SWARM_AGENTS: AgentDiscoveryRecord[] = [
  {
    pod_name: 'prompt-commit-summarizer-7f8d4',
    namespace: NS,
    service_account: 'prompt-commit-summarizer',
    spiffe_id: spiffeId(NS, 'prompt-commit-summarizer'),
    tenant: 'acme-corp',
    project: 'osramp-core',
    role: 'summarizer',
    framework: 'kagent',
    harness: 'claude-code',
    model: 'gemini-2.5-flash',
    state: 'active',
    kernel_telemetry: {
      cgroup_frozen: false,
      cgroup_state: 'thawed',
      tc_drop_active: false,
      containment_latency_ms: null,
    },
    created_at: ago(120),
    provenance: 'demo',
  },
  {
    pod_name: 'triage-ci-worker-3a2b1',
    namespace: NS,
    service_account: 'triage-ci-worker',
    spiffe_id: spiffeId(NS, 'triage-ci-worker'),
    tenant: 'acme-corp',
    project: 'osramp-core',
    role: 'ci-worker',
    framework: 'custom',
    harness: 'openai-codex',
    model: 'gpt-4.1',
    state: 'active',
    kernel_telemetry: {
      cgroup_frozen: false,
      cgroup_state: 'thawed',
      tc_drop_active: false,
      containment_latency_ms: null,
    },
    created_at: ago(115),
    provenance: 'demo',
  },
  {
    pod_name: 'zulip-chat-agent-5e9c3',
    namespace: NS,
    service_account: 'zulip-chat-agent',
    spiffe_id: spiffeId(NS, 'zulip-chat-agent'),
    tenant: 'acme-corp',
    project: 'osramp-core',
    role: 'chat-agent',
    framework: 'claude-code',
    harness: 'claude-code',
    model: 'claude-sonnet-4',
    state: 'active',
    kernel_telemetry: {
      cgroup_frozen: false,
      cgroup_state: 'thawed',
      tc_drop_active: false,
      containment_latency_ms: null,
    },
    created_at: ago(110),
    provenance: 'demo',
  },
  {
    pod_name: 'cpai-engineer-8b1d6',
    namespace: NS,
    service_account: 'cpai-engineer',
    spiffe_id: spiffeId(NS, 'cpai-engineer'),
    tenant: 'acme-corp',
    project: 'osramp-core',
    role: 'engineer',
    framework: 'custom',
    harness: 'claude-code',
    model: 'claude-sonnet-4',
    state: 'claimed',
    kernel_telemetry: {
      cgroup_frozen: false,
      cgroup_state: 'thawed',
      tc_drop_active: false,
      containment_latency_ms: null,
    },
    created_at: ago(105),
    provenance: 'demo',
  },
  {
    pod_name: 'hosted-daytona-coder-2f4a9',
    namespace: NS,
    service_account: 'hosted-daytona-coder',
    spiffe_id: spiffeId(NS, 'hosted-daytona-coder'),
    tenant: 'acme-corp',
    project: 'osramp-core',
    role: 'coder',
    framework: 'custom',
    harness: 'daytona',
    model: null,
    state: 'active',
    kernel_telemetry: {
      cgroup_frozen: false,
      cgroup_state: 'thawed',
      tc_drop_active: false,
      containment_latency_ms: null,
    },
    created_at: ago(100),
    provenance: 'demo',
  },
  {
    pod_name: 'swarm-governor-9c4e2',
    namespace: NS,
    service_account: 'swarm-governor',
    spiffe_id: spiffeId(NS, 'swarm-governor'),
    tenant: 'acme-corp',
    project: 'osramp-core',
    role: 'governor',
    framework: 'claude-code',
    harness: 'claude-code',
    model: 'claude-sonnet-4',
    state: 'active',
    kernel_telemetry: {
      cgroup_frozen: false,
      cgroup_state: 'thawed',
      tc_drop_active: false,
      containment_latency_ms: null,
    },
    created_at: ago(130),
    provenance: 'demo',
  },
  {
    pod_name: 'prod-deploy-gate-4c7b2',
    namespace: NS,
    service_account: 'prod-deploy-gate',
    spiffe_id: spiffeId(NS, 'prod-deploy-gate'),
    tenant: 'acme-corp',
    project: 'osramp-core',
    role: 'deploy-gate',
    framework: 'custom',
    harness: null,
    model: null,
    state: 'active',
    kernel_telemetry: {
      cgroup_frozen: false,
      cgroup_state: 'thawed',
      tc_drop_active: false,
      containment_latency_ms: null,
    },
    created_at: ago(95),
    provenance: 'demo',
  },
  {
    pod_name: 'agent-cardvault-1d5f7',
    namespace: NS,
    service_account: 'agent-cardvault',
    spiffe_id: spiffeId(NS, 'agent-cardvault'),
    tenant: 'acme-corp',
    project: 'pci-compliance',
    role: 'cardvault',
    framework: 'kagent',
    harness: 'claude-code',
    model: 'claude-sonnet-4',
    state: 'claimed',
    kernel_telemetry: {
      cgroup_frozen: false,
      cgroup_state: 'thawed',
      tc_drop_active: false,
      containment_latency_ms: null,
    },
    created_at: ago(90),
    provenance: 'demo',
  },
  {
    pod_name: 'nono-containment-probe-6a3e1',
    namespace: NS,
    service_account: 'nono-containment-probe',
    spiffe_id: spiffeId(NS, 'nono-containment-probe'),
    tenant: 'platform',
    project: 'signalloom-infra',
    role: 'containment-probe',
    framework: 'custom',
    harness: null,
    model: null,
    state: 'active',
    kernel_telemetry: {
      cgroup_frozen: false,
      cgroup_state: 'thawed',
      tc_drop_active: false,
      containment_latency_ms: null,
    },
    created_at: ago(85),
    provenance: 'demo',
  },
  {
    pod_name: 'signalloom-stun-sentinel-node1',
    namespace: NS,
    service_account: 'signalloom-stun-sentinel',
    spiffe_id: spiffeId(NS, 'signalloom-stun-sentinel'),
    tenant: 'platform',
    project: 'signalloom-infra',
    role: 'sentinel',
    framework: 'custom',
    harness: null,
    model: null,
    state: 'active',
    kernel_telemetry: {
      cgroup_frozen: false,
      cgroup_state: 'thawed',
      tc_drop_active: false,
      containment_latency_ms: null,
    },
    created_at: ago(140),
    provenance: 'demo',
  },
]

// ─── Credential records for 6 credentialed agents ──────────────────────────

function makeCredential(
  sa: string,
  scope: string,
  minutesAgo: number,
): CredentialRecord {
  return {
    id: `${sa}-openbao-lease`,
    spiffeId: spiffeId(NS, sa),
    workload: sa,
    namespace: NS,
    kind: 'openbao-lease',
    issuer: 'openbao.inf-bao',
    scope,
    status: 'active',
    issuedAt: ago(minutesAgo),
    expiresAt: ago(minutesAgo - 5),
    revokedAt: null,
    ttlSeconds: 300,
    rotationCount: 11,
    provenance: 'demo',
  }
}

export const FAKE_SWARM_CREDENTIALS: CredentialRecord[] = [
  makeCredential('prompt-commit-summarizer', 'LLM API (Gemini 2.5 Flash)', 118),
  makeCredential('triage-ci-worker', 'GitHub API (read-only CI logs)', 113),
  makeCredential('zulip-chat-agent', 'Zulip API (stream messaging)', 108),
  makeCredential('cpai-engineer', 'Anthropic API (Claude Sonnet 4)', 103),
  makeCredential('swarm-governor', 'Anthropic API (Claude Sonnet 4)', 128),
  makeCredential('prod-deploy-gate', 'HMAC signing key', 93),
  makeCredential('agent-cardvault', 'OpenBao secret read/list', 88),
]

// ─── Audit trail ───────────────────────────────────────────────────────────

let eventSeq = 0
function ev(
  type: SwarmAuditEvent['type'],
  sa: string,
  minutesAgo: number,
  details: Record<string, string> = {},
): SwarmAuditEvent {
  return {
    id: `swarm-evt-${++eventSeq}`,
    type,
    agent_id: sa,
    spiffe_id: spiffeId(NS, sa),
    timestamp: ago(minutesAgo),
    details,
  }
}

/**
 * A realistic lifecycle sequence:
 * 1. Governor claims, fetches credential
 * 2. cpai-engineer claims, enters sandbox, fetches credential
 * 3. agent-cardvault claims, enters sandbox, fetches credential
 * 4. cpai-engineer credential rotated
 * 5. nono-containment-probe detects a violation on cpai-engineer
 * 6. Sentinel stuns cpai-engineer
 * 7. Sentinel releases cpai-engineer after human review
 * 8. cpai-engineer re-claims
 */
export const FAKE_SWARM_AUDIT_EVENTS: SwarmAuditEvent[] = [
  // Governor startup
  ev('swarm.agent.claimed', 'swarm-governor', 128, { harness: 'claude-code', model: 'claude-sonnet-4' }),
  ev('swarm.credential.fetched', 'swarm-governor', 127, { scope: 'Anthropic API (Claude Sonnet 4)' }),

  // cpai-engineer startup
  ev('swarm.agent.claimed', 'cpai-engineer', 105, { harness: 'claude-code', model: 'claude-sonnet-4' }),
  ev('swarm.nono.sandbox_entered', 'cpai-engineer', 104, { sandbox_id: 'nono-cgroup-cpai-001' }),
  ev('swarm.credential.fetched', 'cpai-engineer', 103, { scope: 'Anthropic API (Claude Sonnet 4)' }),

  // cardvault startup
  ev('swarm.agent.claimed', 'agent-cardvault', 90, { harness: 'claude-code', model: 'claude-sonnet-4' }),
  ev('swarm.nono.sandbox_entered', 'agent-cardvault', 89, { sandbox_id: 'nono-cgroup-cardvault-001' }),
  ev('swarm.credential.fetched', 'agent-cardvault', 88, { scope: 'OpenBao secret read/list' }),

  // Routine rotation
  ev('swarm.credential.rotated', 'cpai-engineer', 60, { rotation_count: '12', ttl_seconds: '300' }),
  ev('swarm.credential.rotated', 'swarm-governor', 55, { rotation_count: '15', ttl_seconds: '300' }),

  // Incident: nono detects a syscall violation
  ev('swarm.nono.violation_blocked', 'cpai-engineer', 30, {
    syscall: 'connect',
    target: '169.254.169.254:80',
    reason: 'IMDS access blocked by Nono policy',
  }),

  // Sentinel stuns the agent
  ev('swarm.sentinel.stun_triggered', 'cpai-engineer', 29, {
    reason: 'Repeated IMDS access attempts detected',
    frozen_cgroup: 'nono-cgroup-cpai-001',
  }),

  // Human review releases the agent
  ev('swarm.sentinel.stun_released', 'cpai-engineer', 10, {
    released_by: 'operator@controlplane.io',
    reason: 'False positive: legitimate metadata lookup',
  }),

  // Agent re-claims after release
  ev('swarm.agent.released', 'cpai-engineer', 9, { reason: 'post-stun cleanup' }),
  ev('swarm.agent.claimed', 'cpai-engineer', 8, { harness: 'claude-code', model: 'claude-sonnet-4' }),
  ev('swarm.credential.fetched', 'cpai-engineer', 7, { scope: 'Anthropic API (Claude Sonnet 4)' }),
]
