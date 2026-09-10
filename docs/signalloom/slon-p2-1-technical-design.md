# SLON-P2-1 Technical Design: Dual Demo Agent Onboarding & Workload Profiles

## 1. Context & Objectives

Signal Loom requires a demonstrable proof of heterogeneous AI agent governance across both cutting-edge sandboxed workloads (with Linux Landlock kernel confinement and detached cryptographic SPIFFE signatures) and baseline standard containerized workloads.

Task `SLON-P2-1` provides the foundation for this dual-agent demonstration by deploying two live agent workloads in `fe-signalloom-agents`:
- `agent-nono-evidenced`: Profile `nono-evidenced`, instrumented for optional Nono Landlock sandboxing and hash-chained audit logging.
- `agent-standard-baseline`: Profile `standard-baseline`, demonstrating standard containerized runtime behavior.

---

## 2. Architecture Overview

```
+-------------------------------------------------------------------------+
| Namespace: fe-signalloom-agents                                         |
|                                                                         |
|  +-------------------------------+   +-------------------------------+  |
|  | Pod: agent-nono-evidenced     |   | Pod: agent-standard-baseline  |  |
|  | - SA: agent-nono-evidenced    |   | - SA: agent-standard-baseline |  |
|  | - Profile: nono-evidenced     |   | - Profile: standard-baseline  |  |
|  | - SP-5 Dynamic Nono Probe     |   | - Baseline Container Runtime  |  |
|  | - SPIFFE Workload API Mount   |   | - SPIFFE Workload API Mount   |  |
|  | - Structured Heartbeat Loop   |   | - Structured Heartbeat Loop   |  |
|  +---------------+---------------+   +---------------+---------------+  |
|                  |                                   |                  |
|                  |                                   |                  |
+------------------|-----------------------------------|------------------+
                   |                                   |
                   v                                   v
+-------------------------------------------------------------------------+
| Namespace: inf-bao                                                      |
|  SPIRE Server (Trust Domain: spiffe://signalloom.demo/)                 |
|  - SVID: spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono |
|  - SVID: spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-base |
+-------------------------------------------------------------------------+
                   |
                   v
+-------------------------------------------------------------------------+
| Namespace: inf-signalloom                                               |
|  fake-integration-proxy & Discovery Inventory                           |
|  - Queries labelSelector: signalloom.ai/agent=true                      |
|  - Exposes GET /agents -> fe-signalloom backend -> dashboard            |
+-------------------------------------------------------------------------+
```

---

## 3. Workload Identity & SPIRE SVIDs

Each workload operates under an isolated ServiceAccount registered in the SPIRE Server:

| Workload | ServiceAccount | SPIFFE SVID | Parent ID |
| :--- | :--- | :--- | :--- |
| `agent-nono-evidenced` | `agent-nono-evidenced` | `spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced` | `spiffe://signalloom.demo/agent/kind` |
| `agent-standard-baseline` | `agent-standard-baseline` | `spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-standard-baseline` | `spiffe://signalloom.demo/agent/kind` |

Workloads reach the SPIRE agent Workload API via a read-only hostPath mount of `/run/spire/sockets` to `/run/spire/sockets/agent.sock`.

---

## 4. Discovery Labeling & Inventory Integration

Workloads declare standardized Kubernetes labels enabling dynamic discovery by the Signal Loom inventory service:

| Label Key | Value (`agent-nono-evidenced`) | Value (`agent-standard-baseline`) | Purpose |
| :--- | :--- | :--- | :--- |
| `signalloom.ai/agent` | `"true"` | `"true"` | Required by SPIRE selector and `fake-integration-proxy` discovery selector |
| `signalloom.io/agent` | `"demo"` | `"demo"` | Identifies workload as part of the demo suite |
| `signalloom.io/workload-profile` | `"nono-evidenced"` | `"standard-baseline"` | Distinguishes sandboxed vs standard baseline profile |
| `signalloom.ai/agent-name` | `"agent-nono-evidenced"` | `"agent-standard-baseline"` | Workload canonical identifier |
| `signalloom.ai/framework` | `"custom"` | `"custom"` | Validated by `sl-agent-identity-state-protection` admission policy |
| `signalloom.ai/state` | `"active"` | `"active"` | Initial lifecycle state |

---

## 5. SP-5 Dynamic Capability Detection & Graceful Fallback

In accordance with Shared Pattern **SP-5**:
- Workloads instrumented for Nono must run a pre-execution probe (`command -v nono`).
- If Nono is present, the agent executes sandboxed under `nono run` with hash-chained audit logging and detached SPIFFE signing.
- If Nono is absent, the agent logs a structured JSON warning (`nono_capability_available: false`) and continues unconfined execution without crashing, exiting with non-zero error, or blocking pod scheduling.
