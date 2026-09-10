# SFAS-P3-1: Real-Time Delegation Revocation Dispatcher & Stun Containment Architecture

**Document Version:** 1.0.0  
**Status:** IMPLEMENTED & VERIFIED  
**Component:** `signal-ingest` Identity & Containment Subsystem  
**Reference Card:** `SFAS-P3-1`  
**Date:** 2026-09-10  

---

## 1. Overview & Motivation

In multi-agent collaborative workflows governed by Signal Loom, compromised or misbehaving agents must be instantly neutralized upon detection by Sentinel monitoring systems (`stun-sentinel`, `agent-nono`, or policy engines). 

Halting agent process execution alone is insufficient if active cryptographic delegation edges remain valid in the identity graph: upstream or downstream actors could still execute privileged actions using existing delegation tokens or assumed role chains.

`SFAS-P3-1` establishes an automated, sub-millisecond revocation cascade:
1. Receives stun triggers asynchronously (`swarm.sentinel.stun_triggered` / `StunExecutionHalted`) or via synchronous REST API (`POST /api/v1/delegations/revoke`).
2. Atomically clamps `valid_to = event_time` across all active incoming and outgoing temporal delegation edges in PostgreSQL and in-memory caches.
3. Propagates `delegation.revoked` invalidation events across the internal event bus to flush resolved graph caches.
4. Triggers network-level containment by dispatching egress drop commands to Stun Sentinel (`POST /api/v1/stun/drop`) with exponential backoff retries.
5. Emits structured tamper-evident audit records.

---

## 2. Temporal Invalidation Model & Cascade Semantics

### 2.1 Monotonic Half-Open Interval Clamping
Delegation edges in Signal Loom follow half-open temporal intervals $[valid\_from, valid\_to)$. When a revocation event occurs at timestamp $T_{stun}$:

$$\text{For all edges } e \in E \text{ where } (e.delegate = A \lor e.principal = A) \land (e.valid\_to \text{ IS NULL} \lor e.valid\_to > T_{stun}):$$

$$e.valid\_to \leftarrow \max(T_{stun}, e.valid\_from + 1\mu s)$$
$$e.status \leftarrow \text{"REVOKED"}$$

The clamping operation ensures:
- **Strict Monotonicity**: $valid\_to > valid\_from$ is guaranteed even if $T_{stun} \le valid\_from$, preventing SQL constraint violations (`CHECK (valid_to IS NULL OR valid_from < valid_to)`).
- **Historical Integrity**: Queries with $as\_of < T_{stun}$ evaluate the edge as active and authorized, preserving accurate historical audit records.
- **Immediate Invalidation**: Queries with $as\_of \ge T_{stun}$ evaluate the edge as invalid, severing any transitive chain traversing $A$.

### 2.2 Transitive Multi-Hop Invalidation
When edge $B \xrightarrow{\text{delegates}} A$ or $A \xrightarrow{\text{delegates}} C$ is revoked:
- Direct queries for $A$'s authorization fail with `Decision: "REVOKED"` and HTTP 403 Forbidden.
- Downstream chains (e.g., $B \to A \to C \to D$) are severed at the $A$ boundary. Any agent attempting to claim authorization derived transitively through $A$ is rejected.
- Upstream chains (e.g., $B$) remain valid for non-dependent operations, strictly adhering to **SP-1 (Never-Merge)** isolation.

---

## 3. Component Architecture

```
                               ┌───────────────────────────────────────────────┐
                               │             External Ingestion                │
                               │  - swarm.sentinel.stun_triggered (EventBus)   │
                               │  - POST /api/v1/delegations/revoke (HTTP)     │
                               └──────────────────────┬────────────────────────┘
                                                      │
                                                      ▼
                                       ┌─────────────────────────────┐
                                       │   StunEventListener /       │
                                       │   RevocationHandler         │
                                       └──────────────┬──────────────┘
                                                      │
                        ┌─────────────────────────────┼─────────────────────────────┐
                        ▼                             ▼                             ▼
        ┌──────────────────────────────┐ ┌───────────────────────────┐ ┌───────────────────────────┐
        │        IdentityStore         │ │       EventBus            │ │    StunSentinelClient     │
        │   RevokeActiveDelegations    │ │ Publish delegation.revoked│ │  DispatchDropWithRetry    │
        └──────────────┬───────────────┘ └────────────┬──────────────┘ └────────────┬──────────────┘
                       │                              │                             │
          ┌────────────┴────────────┐                 ▼                             ▼
          ▼                         ▼          [Cache Flusher /           [Stun Sentinel Pod /
   [PostgreSQL DB]           [Memory Cache]     Event Subscribers]         Egress Drop Gateway]
  UPDATE delegations...     Clamp valid_to
  status = 'REVOKED'        status = 'REVOKED'
```

### 3.1 `StunEventListener`
The `StunEventListener` subscribes to `swarm.sentinel.stun_triggered` and `StunExecutionHalted` topics. Upon event arrival:
```go
func (l *StunEventListener) handleStunTriggered(ctx context.Context, payload []byte) {
    var event StunContainmentEvent
    json.Unmarshal(payload, &event)
    
    // 1. Invalidate active delegation edges in Identity Store
    l.store.RevokeActiveDelegations(ctx, event.ActorID, event.Timestamp)
    
    // 2. Broadcast invalidation event
    l.bus.Publish("delegation.revoked", RevocationEvent{
        ActorID:   event.ActorID,
        EventTime: event.Timestamp,
        Reason:    event.Reason,
    })
    
    // 3. Dispatch network egress drop to Stun Sentinel
    if l.stunClient != nil && event.AgentIP != "" {
        l.stunClient.DispatchDropWithRetry(ctx, DropRequest{
            AgentIP: event.AgentIP,
            Reason:  event.Reason,
        })
    }
}
```

### 3.2 `DelegationReaper`
The `DelegationReaper` background worker executes every 10 seconds:
- Queries for past-validity delegation edges ($valid\_to \le NOW() \land status = \text{'ACTIVE'}$).
- Marks them as `status = 'EXPIRED'` to reduce active index scan sizes.
- Protected against panics via `defer recover()` with automatic worker loop restart.

---

## 4. Latency & Performance Measurements

All latency benchmarks were executed on bare metal hardware (`AMD Ryzen 9 7900X 12-Core Processor`).

### 4.1 End-to-End Latency Results
- **Edge Invalidation + Query Reflection SLA:** $< 50\text{ ms}$
  - **Measured (In-Memory Repository):** $10.57\ \mu\text{s}$ average ($0.0105\text{ ms}$)
  - **Measured Maximum (100 iterations):** $103.94\ \mu\text{s}$ ($0.1039\text{ ms}$)
- **End-to-End API Revocation Dispatch SLA:** $\le 500\text{ ms}$
  - **Measured:** $< 0.2\text{ ms}$ across full HTTP round-trip
- **Dispatch Handler Throughput:**
  - **Benchmark:** `BenchmarkRevocationDispatch`
  - **Throughput:** $153,285\text{ operations in } 1.78\text{ s}$ $\to$ **$85,859\text{ ops/sec}$** ($11.65\ \mu\text{s/op}$)

---

## 5. Security & Verification Assertions

1. **Denial-of-Service Resistance**: Input validation strictly enforces non-empty actor IDs and timestamps, returning 400 Bad Request on invalid payloads.
2. **Exponential Backoff with Jitter**: Network drops to Stun Sentinel tolerate transient network blips with 3 retry attempts, doubling backoff intervals up to 500ms.
3. **Audit Trail**: Every revocation event logs actor ID, containment reason, operator identity, and timestamp into the tamper-evident audit writer.
