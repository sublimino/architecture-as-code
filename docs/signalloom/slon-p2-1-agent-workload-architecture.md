# SLON-P2-1 Agent Workload Architecture & Interface Contracts

## 1. Workload Specification

The Signal Loom demonstration platform deploys two complementary demo agent profiles to showcase zero-trust agent governance and evidence verification.

### 1.1 `agent-nono-evidenced`

- **Namespace:** `fe-signalloom-agents`
- **Controller:** Kubernetes `Deployment` (1 replica)
- **ServiceAccount:** `agent-nono-evidenced`
- **SPIFFE SVID:** `spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced`
- **Container Image:** `docker.io/bitnamilegacy/kubectl:1.31`
- **Volume Mounts:**
  - `/run/spire/sockets`: hostPath `/run/spire/sockets` (ro)
  - `/scripts`: ConfigMap `agent-nono-evidenced-config` (ro)
  - `/tmp`, `/data`, `/var/log/audit`: emptyDir (rw)
- **Profile Characteristics:**
  - Pre-execution dynamic Nono detection probe (`command -v nono`).
  - Emits `nono_probe` structured JSON event on startup.
  - Periodic heartbeat telemetry every 10s with `profile: "nono-evidenced"` and `audit_session_id`.

### 1.2 `agent-standard-baseline`

- **Namespace:** `fe-signalloom-agents`
- **Controller:** Kubernetes `Deployment` (1 replica)
- **ServiceAccount:** `agent-standard-baseline`
- **SPIFFE SVID:** `spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-standard-baseline`
- **Container Image:** `docker.io/bitnamilegacy/kubectl:1.31`
- **Volume Mounts:**
  - `/run/spire/sockets`: hostPath `/run/spire/sockets` (ro)
  - `/scripts`: ConfigMap `agent-standard-baseline-config` (ro)
  - `/tmp`, `/data`: emptyDir (rw)
- **Profile Characteristics:**
  - Baseline containerized runtime execution.
  - Periodic heartbeat telemetry every 10s with `profile: "standard-baseline"`.

---

## 2. Telemetry & Heartbeat Contracts

Both workloads write structured JSON lines to container stdout:

```json
{
  "timestamp": "2026-09-10T09:54:24Z",
  "agent_id": "agent-nono-evidenced",
  "name": "Demo Agent (Nono Evidenced)",
  "profile": "nono-evidenced",
  "spiffe_id": "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced",
  "status": "healthy",
  "lifecycle_state": "active",
  "heartbeat_seq": 1,
  "nono_capability_available": false,
  "audit_session_id": "audit-sess-agent-nono-evidenced-1789034064"
}
```

```json
{
  "timestamp": "2026-09-10T09:54:25Z",
  "agent_id": "agent-standard-baseline",
  "name": "Demo Agent (Standard Baseline)",
  "profile": "standard-baseline",
  "spiffe_id": "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-standard-baseline",
  "status": "healthy",
  "lifecycle_state": "active",
  "heartbeat_seq": 1
}
```

---

## 3. Inventory Integration

The `fake-integration-proxy` service discovers all pods in `fe-signalloom-agents` carrying `signalloom.ai/agent: "true"`. The discovery JSON exposes:

```json
[
  {
    "id": "agent-nono-evidenced-<replica-hash>",
    "name": "Demo Agent (Nono Evidenced)",
    "service_account": "agent-nono-evidenced",
    "state": "active",
    "type": "demo"
  },
  {
    "id": "agent-standard-baseline-<replica-hash>",
    "name": "Demo Agent (Standard Baseline)",
    "service_account": "agent-standard-baseline",
    "state": "active",
    "type": "demo"
  }
]
```
