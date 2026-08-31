# Unified Metrics Design — OSRAMP/SignalLoom

> Proposed by sensai based on operational experience as overnight STUN supervisor.
> ISA: `~/.claude/PAI/MEMORY/WORK/20260831-osramp-unified-metrics/ISA.md`

## Thesis

Every metric exposed to the dashboard UI is also available as structured JSON from the same API endpoint. The human reads a card; the AI reads the JSON. Neither gets a privileged view.

## The Eight Layers

Ordered by how often I (sensai) query each one during an autonomous supervisor run.

### 1. Flux GitOps Health — `GET /api/v1/metrics/flux`

**Why this is #1:** I spent more time on Flux Kustomization status than all other metrics combined during the STUN overnight. The `infra-controllers → infra-configs → agent-swarm` dependency chain was invisible until I traced it manually across 6 kubectl calls.

**What I need:**

```jsonc
{
  "version": "1.0.0",
  "timestamp": "2026-08-31T09:00:00Z",
  "source": "live",
  "layerHealth": "degraded",
  "data": {
    "kustomizations": [
      {
        "name": "infra-configs",
        "namespace": "inf-bao",
        "ready": false,
        "statusMessage": "health check failed after 5m0s: timeout waiting for: [DaemonSet/inf-bao/spire-agent status: 'InProgress']",
        "lastAppliedRevision": "latest@sha256:886d656...",
        "lastAttemptedRevision": "latest@sha256:886d656...",
        "dependsOn": ["infra-controllers"],
        "reconciledAt": "2026-08-31T00:15:00Z",
        "healthChecks": [
          { "kind": "DaemonSet", "namespace": "inf-bao", "name": "spire-agent", "status": "InProgress" }
        ]
      }
    ],
    "dependencyGraph": {
      "infra-controllers": [],
      "infra-configs": ["infra-controllers"],
      "agent-swarm": ["signalloom-infra", "infra-configs"]
    },
    "suspendedCount": 0,
    "failedCount": 1
  }
}
```

**Dashboard rendering:** DAG visualisation with red/green/amber nodes. Clicking a node opens a drawer with the status message and health check details. This single panel would have saved me 3+ hours last night.

### 2. Kubernetes Workload Health — `GET /api/v1/metrics/workloads`

**Why this is #2:** Pod restart counts and CrashLoopBackOff detection are my second most-used signals. The SPIRE agent's 1528 restarts over 6d19h was the tell for the trust chain failure — a "top restarters" card would have surfaced it immediately.

**What I need:**

```jsonc
{
  "layerHealth": "degraded",
  "data": {
    "namespaces": {
      "inf-bao": { "total": 5, "running": 4, "pending": 0, "failed": 0, "crashLoopBackOff": 1 }
    },
    "topRestarters": [
      { "name": "spire-agent-74bkt", "namespace": "inf-bao", "restartCount": 1528, "lastTerminationReason": "Error" }
    ],
    "crashLoopBackOff": [
      { "name": "spire-agent-74bkt", "namespace": "inf-bao", "reason": "CreateContainerConfigError" }
    ]
  }
}
```

**Sub-endpoint: Jobs** — `GET /api/v1/metrics/workloads/jobs`

Stale completed/failed Jobs were a major overnight blocker. I need:
- `staleJobs`: completed/failed Jobs older than 1 hour
- `neverSucceeded`: Jobs with age >1h and zero completions (the `openbao-agent-generic-role-setup` pattern)

### 3. Process Liveness (CPU Delta) — integrated into workloads

**Why:** This is my primary liveness signal. `awk '{print $14+$15}' /proc/PID/stat; sleep 9; repeat` — if the delta is zero, the process is stalled regardless of what its pod status says.

```jsonc
{
  "containers": [
    {
      "name": "cpai-engineer",
      "cpuRateMillicores": 450,
      "memoryRssMb": 128,
      "memoryLimitMb": 512,
      "cpuThrottlingPct": 2.1,
      "liveness": "alive"  // "alive" if CPU delta >0 over 30s, "stalled" if =0
    }
  ]
}
```

### 4. Trust Chain Health — `GET /api/v1/metrics/trust`

**Why:** The SPIRE ↔ OpenBao circular dependency was invisible until I traced it manually. A "bootstrap completeness" indicator would immediately show which step in the chain is broken.

```jsonc
{
  "layerHealth": "critical",
  "data": {
    "bootstrapCompleteness": {
      "openbaoUnsealed": true,
      "jwtAuthEnabled": false,  // <-- this was the root cause last night
      "spireServerRunning": true,
      "spireAgentAttested": false,
      "genericRoleConfigured": false
    },
    "spireServer": { "phase": "Running", "restartCount": 0, "registrationEntryCount": 0 },
    "spireAgent": { "phase": "CreateContainerConfigError", "restartCount": 0, "available": 0, "desired": 1 },
    "openbao": { "phase": "Running", "sealStatus": "unsealed", "authMethods": ["token"], "policyCount": 1 }
  }
}
```

**Dashboard rendering:** Vertical pipeline: OpenBao → JWT Auth → SPIRE Server → SPIRE Agent → Agent SVIDs. Each step green/red with the specific blocker.

### 5. Git-to-Cluster Drift — `GET /api/v1/metrics/drift`

**Why:** I repeatedly compared `kubectl get kustomization` SHAs against git commit SHAs. This should be a table, not a manual comparison.

```jsonc
{
  "data": {
    "kustomizations": [
      {
        "name": "infra-controllers",
        "namespace": "inf-bao",
        "committedSha": "794f19d5...",
        "deployedSha": "794f19d5...",
        "match": true,
        "driftAge": "0s"
      }
    ],
    "pendingChanges": [],
    "suspendedResources": []
  }
}
```

### 6. Agent Swarm Status — `GET /api/v1/metrics/agents`

**Why:** The kanban supervisor needs to know which agents are running, stalled, or dead. Currently I check `/proc/PID/stat` per agent — a structured view across the whole swarm would replace 18 individual probes.

```jsonc
{
  "data": {
    "agentCount": { "total": 18, "running": 15, "failed": 1, "stalled": 2 },
    "agents": [
      {
        "name": "cpai-engineer",
        "type": "kagent",
        "namespace": "agent-swarm",
        "phase": "Running",
        "restartCount": 0,
        "svidStatus": "missing",  // no SPIRE agent = no SVID
        "lastActivity": "2026-08-31T08:45:00Z",
        "compliancePosture": { "verdict": "non-compliant", "controlPassRate": 0.72, "residualAle": 14200 }
      }
    ],
    "stalledAgents": [
      { "name": "kagent-chaos-prober", "stalledSince": "2026-08-31T07:30:00Z", "reason": "no CPU delta for 90 minutes" }
    ]
  }
}
```

### 7. Network Policy Enforcement — `GET /api/v1/metrics/network`

**Why:** P3-2's entire task was deploying deny policies via Flux. I need to see if policies are actually delivered and enforced, not just committed.

```jsonc
{
  "data": {
    "policies": [
      { "name": "stun-admin-deny", "namespace": "stun-quarantine", "ingressRules": 1, "egressRules": 1, "age": "2h" }
    ],
    "namespacesWithoutDefaultDeny": ["stun-pre-probe"],
    "policyVerdicts": { "allowed": 1420, "denied": 3, "interval": "5m" }
  }
}
```

### 8. Cluster Events & Anomalies — `GET /api/v1/metrics/events`

**Why:** Warning events are the first sign something's wrong. I currently don't check them because each `kubectl get events` call is expensive in context tokens. A pre-filtered anomaly array would be cheap.

```jsonc
{
  "data": {
    "eventRate": { "perMinute": 2.3, "baseline": 1.1, "spikeDetected": true },
    "anomalies": [
      { "reason": "BackOff", "involvedObject": "pod/spire-agent-74bkt", "count": 47, "message": "Back-off restarting failed container" }
    ]
  }
}
```

## The Supervisor Summary — `GET /api/v1/metrics/supervisor-summary`

This is the endpoint purpose-built for AI consumption. One JSON object, one round trip, <200ms.

```jsonc
{
  "timestamp": "2026-08-31T09:00:00Z",
  "layers": {
    "flux": { "health": "degraded", "topBlocker": "inf-bao/infra-configs: health check timeout on spire-agent DaemonSet" },
    "workloads": { "health": "degraded", "topBlocker": "spire-agent-74bkt: CreateContainerConfigError, 0/1 ready" },
    "trust": { "health": "critical", "topBlocker": "JWT auth engine not enabled in OpenBao" },
    "agents": { "health": "degraded", "topBlocker": "2 agents stalled (no CPU delta >90min)" },
    "risk": { "health": "healthy", "topBlocker": null },
    "network": { "health": "healthy", "topBlocker": null },
    "drift": { "health": "healthy", "topBlocker": null },
    "events": { "health": "degraded", "topBlocker": "spike: 2.3/min vs 1.1/min baseline" }
  },
  "actionableBlockers": [
    {
      "layer": "trust",
      "severity": "critical",
      "description": "JWT auth engine not enabled in OpenBao — blocks SPIRE agent attestation → agent SVIDs → agent compliance",
      "suggestedAction": "kubectl exec deployment/openbao -n inf-bao -- bao auth enable jwt"
    },
    {
      "layer": "workloads",
      "severity": "high",
      "description": "spire-agent DaemonSet 0/1 ready — CreateContainerConfigError",
      "suggestedAction": "kubectl describe pod -n inf-bao -l app.kubernetes.io/name=spire-agent"
    }
  ],
  "sinceLastPoll": {
    "changedLayers": ["flux"],
    "newBlockers": 0,
    "resolvedBlockers": 1
  }
}
```

**What this replaces for my supervisor tick:** Currently ~8 kubectl calls (3K tokens, 60-90s). With this endpoint: 1 curl call (~200 tokens, <200ms). Over an 8-hour overnight run: **~430K tokens saved**.

## Unified Response Envelope

Every endpoint shares:

```typescript
interface MetricsResponse<T> {
  version: string           // "1.0.0"
  timestamp: string         // ISO 8601
  source: "live" | "demo"   // demo mode toggle
  layerHealth: "healthy" | "degraded" | "critical" | "unknown"
  data: T
}
```

Query parameters:
- `?format=summary` — top-level counts only, no object lists
- `?namespace=X` — namespace filter
- `?since=ISO` — delta since timestamp (supervisor-summary only)

## Dashboard Page Mapping

| Metric Layer | New or Enhanced | Page |
|-------------|----------------|------|
| Flux GitOps | **New** | Operations page — DAG panel |
| Workloads | **New** | Operations page — workload cards |
| Trust Chain | **New** | Operations page — pipeline panel |
| Agent Swarm | Enhanced | AgentsPage + AgentDetailPage |
| Risk Posture | Enhanced | RiskExposurePage |
| Network Policy | Enhanced | NetworkTestsPage |
| Drift | **New** | Operations page — drift table |
| Events | **New** | Operations page — anomaly timeline |

The new "Operations" page sits in the sidebar and assembles all 8 layer health cards. Each card is expandable or links to the dedicated page.

## Demo Mode Fixtures

Each layer gets a fixture file under `src/api/fixtures/` returning realistic data matching the kind-osramp topology (11 Kustomizations, 18 agents, inf-bao namespace). Every fixture includes at least one degraded example for visual testing.

## Implementation Order (suggested)

1. **F1: Metrics API Server** — Go HTTP handlers with client-go informers (foundation)
2. **F11: Supervisor Summary** — the compressed endpoint (highest agent value, lowest code)
3. **F12: Demo Mode Fixtures** — enables dashboard development without a live cluster
4. **F2: Flux DAG Panel** — the single highest-value visualisation
5. **F3-F9: Remaining panels** — parallelisable across developers
6. **F10: Operations Page** — assembles panels
7. **F13: OpenAPI & TypeScript Codegen** — polish
