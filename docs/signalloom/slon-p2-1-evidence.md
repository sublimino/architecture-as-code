# SLON-P2-1 Verification Evidence: Dual Demo Agent Deployment & Discovery

**Card ID:** `SLON-P2-1`  
**Title:** Deploy dual demo agents: agent-nono-evidenced and agent-standard-baseline with discovery labels  
**Phase:** Phase 2 (Dual Demo Agent Onboarding & Live Demo)  
**Agent:** `antigravity`  
**Worktree:** `/home/andy/src/.worktrees/c1ce1/osramp-demo`  
**Base Ref:** `refs/heads/integration/slon-v0.1.0`  
**Status:** `Completed` — 100% Verification Pass  

---

## 1. Executive Summary

Task `SLON-P2-1` authored and deployed two complementary demo agent workloads into the `fe-signalloom-agents` namespace on the Kind `osramp` single-node cluster:
1. `agent-nono-evidenced`: Demonstrates advanced AI agent governance with optional Linux Landlock sandboxing and hash-chained SPIFFE audit session logging.
2. `agent-standard-baseline`: Demonstrates standard containerized agent runtime operating without Nono sandboxing.

Both workloads:
- Registered unique cryptographic SPIFFE workload identities under trust domain `spiffe://signalloom.demo/` (`spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced` and `spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-standard-baseline`).
- Mounted the SPIFFE Workload API socket at `/run/spire/sockets/agent.sock` via hostPath volume.
- Declared discoverable metadata labels (`signalloom.io/agent: "demo"`, `signalloom.io/workload-profile: "nono-evidenced"` vs `"standard-baseline"`, `signalloom.ai/agent: "true"`, `signalloom.ai/framework: "custom"`, `signalloom.ai/state: "active"`).
- Executed SP-5 dynamic capability probe and graceful fallback without pod crashing or blocking scheduling.
- Emitted periodic structured JSON heartbeats to stdout.
- Are dynamically discovered by the Signal Loom inventory service (`fake-integration-proxy` and `fe-signalloom`).

---

## 2. Invariants & Architecture Compliance

1. **SP-5: Optional Nono Capability Detection & Fallback Invariant:**
   - `agent-nono-evidenced` runs a pre-execution capability probe. When `nono` is absent on the container substrate, it logs a structured warning (`nono_capability_available: false`) and executes unconfined without crashing or failing pod readiness.
2. **SPIFFE Workload Identity Invariant:**
   - Unique ServiceAccounts (`agent-nono-evidenced`, `agent-standard-baseline`) were created in `fe-signalloom-agents`.
   - SPIRE server entries were created with parent ID `spiffe://signalloom.demo/agent/kind` and selectors `k8s:ns:fe-signalloom-agents`, `k8s:sa:<name>`, and `k8s:pod-label:signalloom.ai/agent:true`.
3. **Admission Policy Compliance:**
   - Workloads adhere to `sl-agent-identity-state-protection` ValidatingAdmissionPolicy using allowed framework label `signalloom.ai/framework: custom`.
4. **NetworkPolicy Boundaries:**
   - Workloads match zero-trust NetworkPolicies in `fe-signalloom-agents` (`allow-signalloom-egress`, `allow-dns`, `allow-identity-plane-egress`).

---

## 3. Runtime Verification Evidence

### 3.1 Pod Scheduling & Status (`fe-signalloom-agents`)

```
NAME                                                READY   STATUS    RESTARTS   AGE    IP           NODE                   NOMINATED NODE   READINESS GATES
agent-nono-evidenced-fccfbb-xp8v7                   1/1     Running   0          30s    10.0.0.35    osramp-control-plane   <none>           <none>
agent-sir-lancelot                                  1/1     Running   0          2d     10.0.0.176   osramp-control-plane   <none>           <none>
agent-standard-baseline-6699c8bdb5-bxpwp            1/1     Running   0          29s    10.0.0.79    osramp-control-plane   <none>           <none>
```

### 3.2 SPIRE Registration Entries

```
Entry ID         : 283fd679-5443-4076-afe5-ec3c6530cafc
SPIFFE ID        : spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced
Parent ID        : spiffe://signalloom.demo/agent/kind
Revision         : 0
Selector         : k8s:ns:fe-signalloom-agents
Selector         : k8s:pod-label:signalloom.ai/agent:true
Selector         : k8s:sa:agent-nono-evidenced
DNS name         : agent-nono-evidenced.fe-signalloom-agents.svc.cluster.local

Entry ID         : 779e4bc7-c23e-47b4-aa40-765ef73f9cca
SPIFFE ID        : spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-standard-baseline
Parent ID        : spiffe://signalloom.demo/agent/kind
Revision         : 0
Selector         : k8s:ns:fe-signalloom-agents
Selector         : k8s:pod-label:signalloom.ai/agent:true
Selector         : k8s:sa:agent-standard-baseline
DNS name         : agent-standard-baseline.fe-signalloom-agents.svc.cluster.local
```

### 3.3 Container Startup & Heartbeat Logs

**`agent-nono-evidenced` Logs:**
```
[2026-09-10T09:54:24Z] ================================================================================
[2026-09-10T09:54:24Z] Starting Signal Loom Demo Agent: Demo Agent (Nono Evidenced) (agent-nono-evidenced)
[2026-09-10T09:54:24Z] Workload Profile: nono-evidenced
[2026-09-10T09:54:24Z] Expected SPIFFE ID: spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced
[2026-09-10T09:54:24Z] SPIFFE Workload API Socket: /run/spire/sockets/agent.sock
[2026-09-10T09:54:24Z] ================================================================================
[2026-09-10T09:54:24Z] [SPIFFE] Workload API socket verified available at /run/spire/sockets/agent.sock
[2026-09-10T09:54:24Z] [NONO-PROBE] {"timestamp":"2026-09-10T09:54:24Z","event":"nono_probe","status":"fallback","nono_capability_available":false,"warning":"Nono binary or Landlock LSM not available on container substrate; executing unconfined without crashing or blocking pod scheduling"}
{"timestamp":"2026-09-10T09:54:24Z","agent_id":"agent-nono-evidenced","name":"Demo Agent (Nono Evidenced)","profile":"nono-evidenced","spiffe_id":"spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced","status":"healthy","lifecycle_state":"active","heartbeat_seq":1,"nono_capability_available":false,"audit_session_id":"audit-sess-agent-nono-evidenced-1789034064"}
{"timestamp":"2026-09-10T09:54:34Z","agent_id":"agent-nono-evidenced","name":"Demo Agent (Nono Evidenced)","profile":"nono-evidenced","spiffe_id":"spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced","status":"healthy","lifecycle_state":"active","heartbeat_seq":2,"nono_capability_available":false,"audit_session_id":"audit-sess-agent-nono-evidenced-1789034064"}
```

**`agent-standard-baseline` Logs:**
```
[2026-09-10T09:54:25Z] ================================================================================
[2026-09-10T09:54:25Z] Starting Signal Loom Demo Agent: Demo Agent (Standard Baseline) (agent-standard-baseline)
[2026-09-10T09:54:25Z] Workload Profile: standard-baseline
[2026-09-10T09:54:25Z] Expected SPIFFE ID: spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-standard-baseline
[2026-09-10T09:54:25Z] SPIFFE Workload API Socket: /run/spire/sockets/agent.sock
[2026-09-10T09:54:25Z] ================================================================================
[2026-09-10T09:54:25Z] [SPIFFE] Workload API socket verified available at /run/spire/sockets/agent.sock
{"timestamp":"2026-09-10T09:54:25Z","agent_id":"agent-standard-baseline","name":"Demo Agent (Standard Baseline)","profile":"standard-baseline","spiffe_id":"spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-standard-baseline","status":"healthy","lifecycle_state":"active","heartbeat_seq":1}
{"timestamp":"2026-09-10T09:54:35Z","agent_id":"agent-standard-baseline","name":"Demo Agent (Standard Baseline)","profile":"standard-baseline","spiffe_id":"spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-standard-baseline","status":"healthy","lifecycle_state":"active","heartbeat_seq":2}
```

### 3.4 Inventory Discovery JSON

```json
[
  {
    "id": "agent-nono-evidenced-fccfbb-xp8v7",
    "name": "Demo Agent (Nono Evidenced)",
    "service_account": "agent-nono-evidenced",
    "state": "active",
    "type": "demo"
  },
  {
    "id": "agent-standard-baseline-6699c8bdb5-bxpwp",
    "name": "Demo Agent (Standard Baseline)",
    "service_account": "agent-standard-baseline",
    "state": "active",
    "type": "demo"
  }
]
```

---

## 4. Test Suite Execution Report

### BATS Integration Suite (`test/signalloom/dual-agents-deployed.bats`)

- **Command:** `bats test/signalloom/dual-agents-deployed.bats`
- **Output:**
```
dual-agents-deployed.bats
   1. Both demo agent deployments are rolled out and healthy in fe-sign...1/7 ✓ 1. Both demo agent deployments are rolled out and healthy in fe-signalloom-agents
   2. ServiceAccounts and unique SPIFFE workload identities exist for b...2/7 ✓ 2. ServiceAccounts and unique SPIFFE workload identities exist for both demo agents
   3. Both workloads declare discoverable metadata labels and annotations3/7 ✓ 3. Both workloads declare discoverable metadata labels and annotations
   4. SPIFFE Workload API socket is mounted at /run/spire/sockets in bo...4/7 ✓ 4. SPIFFE Workload API socket is mounted at /run/spire/sockets in both agent pods
   5. SP-5 dynamic Nono capability probe runs and emits structured fall...5/7 ✓ 5. SP-5 dynamic Nono capability probe runs and emits structured fallback/detection telemetry
   6. Both demo agent pods emit periodic structured heartbeat telemetry6/7 ✓ 6. Both demo agent pods emit periodic structured heartbeat telemetry
   7. Signal Loom agent inventory service dynamically discovers both de...7/7 ✓ 7. Signal Loom agent inventory service dynamically discovers both demo workloads

7 tests, 0 failures
```

---

## 5. Structured Verification Records

### Verification Record 4: Pod Readiness & Identity Proof
- **Timestamp:** `2026-09-10T09:54:25Z`
- **Command:** `kubectl -n fe-signalloom-agents rollout status deployment/agent-nono-evidenced && kubectl -n fe-signalloom-agents rollout status deployment/agent-standard-baseline`
- **Exit Status:** `0`
- **Result:** `PASS` — Both deployments rolled out 1/1 replicas.

### Verification Record 5: Discovery Inventory Match
- **Timestamp:** `2026-09-10T09:54:32Z`
- **Command:** `kubectl -n fe-signalloom exec deploy/dashboard-signalloom -- curl -sS http://fake-integration-proxy.inf-signalloom.svc.cluster.local:8080/agents`
- **Exit Status:** `0`
- **Result:** `PASS` — Both agents discovered with active state and correct serviceAccount mapping.

### Verification Record 6: Proposal Existence & Integrity Check
- **Timestamp:** `2026-09-10T09:55:00Z`
- **Command:** `test -f "/home/andy/Documents/Obsidian/v1/2. Areas/CEO/Innovation Proposals/Proposal — Signal Loom First User and Agent Onboarding (2026-Q3).md"`
- **Exit Status:** `0`
- **Result:** `PASS` — Proposal file verified on disk.
