# Reference: Signal Loom Containment Contracts

## 1. GitOps Suspension Contract (SL-GSC-001)

When a rogue or compromised agent is stunned, the containment action takes place in the live Kubernetes cluster (eBPF network block, cgroup freezer, process freeze, revocation of SPIRE SVIDs).

### The Invariant
Because the Signal Loom platform is managed via GitOps (Flux Operator), any live cluster change is subject to periodic reconciliation. If the Git repository declares `replicas: 1` and normal labels, Flux will detect drift and attempt to restore the un-stunned workload.

Therefore:
- **Every containment controller MUST immediately apply**:
  ```yaml
  metadata:
    annotations:
      kustomize.toolkit.fluxcd.io/reconcile: disabled
  ```
- On recovery (`handleRecover`), the annotation is removed only AFTER credentials have been rotated and git state is updated.

---

## 2. Forensic Preservation Contract (H1)

Under standard Kubernetes operations, a frozen or stunned container fails its HTTP/TCP liveness probe within seconds. The kubelet then terminates the container (`SIGKILL`) and starts a fresh instance, destroying all volatile forensic artifacts (memory heap, open socket state, temporary files).

### The Invariant
- Stun mechanisms must intercept or suppress the liveness probe, or freeze the pod network namespace without causing the kubelet to restart the container.
- Container restart count MUST NOT increment while in stunned state.

---

## 3. Fleet Manager In-Memory DAG Invariant

Fleet Manager maintains an in-memory DAG (`s.dag`) representing inter-agent RPC dependencies.

### The Invariant
- `handleStun(agentID)` must call:
  ```go
  s.dag.SetAgentState(agentID, AgentStateStunned)
  for _, depID := range dependants {
      s.dag.SetAgentState(depID, AgentStateStunned)
  }
  ```
- Omitting this causes `GET /api/v1/fleet/topology` to report `state: active` despite active containment, breaking real-time audience visualization.
