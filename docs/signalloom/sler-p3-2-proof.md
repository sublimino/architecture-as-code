# SLER-P3-2 Proof & Verification: Admission Webhook Readmission Block & Deployment Surface

> **Phase 3 Implementation Deliverable — Signal Loom Enforcement & Response (SLER)**  
> **Card:** `SLER-P3-2` (Implement admission webhook block preventing pod readmission)  
> **Timestamp:** `2026-09-15 05:05:00+01:00`  

---

## 1. Executive Summary

`SLER-P3-2` delivers the dynamic admission webhook block and complete greenfield deployment surface for `node-capability-guard` in `d2-signalloom/apps/node-capability-guard/`, establishing fail-closed protection against contained agent pod reconstitution, restart, and rescheduling.

### Prior State
- `node-capability-guard` existed only as four bare Go files with **zero** `Dockerfile`, **zero** Kubernetes workload manifests (`Deployment`, `Service`, `RBAC`), and **zero** `ValidatingWebhookConfiguration`.
- `ValidatePod` evaluated only two static `nodeSelector` labels (`cgroup-v2=true`, `landlock=true`), with no SPIFFE predicate, no contained-identity denylist, and no ability to deny readmission of a contained agent.
- There was no mechanism preventing a contained agent pod from being rescheduled, restarted, or reconstituted after process termination or node migration.

### Delivered State
1. **Complete Greenfield Deployment Surface**:
   - `Dockerfile`: Multi-stage Go 1.24 alpine to distroless static Debian 12 non-root container (`EXPOSE 8443`, user `65532:65532`).
   - Base manifests in `base/`: `deployment.yaml`, `service.yaml`, `rbac.yaml`, `configmap.yaml`, `networkpolicy.yaml`, `validatingwebhookconfiguration.yaml`, and `kustomization.yaml`.
2. **Contained Identity Predicate & Store Architecture**:
   - Extended `PodSpec` with `ServiceAccountName` and derived SPIFFE ID (`spiffe://signalloom.demo/ns/<ns>/sa/<sa>`).
   - Implemented `ContainedIdentityStore` interface with thread-safe `MemoryIdentityStore`, mtime-cached `FileIdentityStore` (ConfigMap projected), and `FailingIdentityStore`.
   - Webhook checks both `CREATE` and `UPDATE` operations against the store and pod manifest state labels.
3. **Fail-Closed Security Architecture**:
   - `failurePolicy: Fail` in `ValidatingWebhookConfiguration` prevents bypass during webhook downtime.
   - Contained-identity store unreachability/corruption triggers fail-closed denial (`OutcomeDeniedStoreUnavailable`).
   - `timeoutSeconds: 5` prevents hung webhook processes from stalling cluster scheduling.
4. **Attestation & Observability**:
   - Fine-grained Prometheus metric counters extending `RejectionsTotal`/`AdmissionsTotal` with `RejectionsContainedIdentityTotal`, `RejectionsStoreUnavailableTotal`, and `RejectionsNodeCapabilityTotal`.
   - Structured JSON logging (`event: admission_decision` and `event: admission_block_attempt`) satisfying `SharedAttestationEventKeys` for Phase 5 attestation.
5. **Fleet-Manager Orchestration Integration**:
   - Implemented `AdmissionClient` and `K8sAdmissionClient` in `fleet-manager` syncing contained identities to the cluster-wide store upon containment cascade.

---

## 2. Architecture & Readmission Block Flow

```
   Kubernetes API Server (kube-apiserver)
        │
        ▼ (AdmissionReview: Pod CREATE / UPDATE)
   ┌───────────────────────────────────────────────────────────┐
   │ node-capability-guard Webhook (/validate)                 │
   │                                                           │
   │ 1. Non-Agent Check ───[ Non-Agent ]──────────────────────► ALLOW (200)
   │        │                                                  │
   │   [ Agent Pod ]                                           │
   │        ▼                                                  │
   │ 2. Manifest State Check (state=stunned / frozen) ────────► DENY (403)
   │        │                                                  │
   │   [ Manifest Active ]                                     │
   │        ▼                                                  │
   │ 3. Contained Identity Store Query                         │
   │    (Agent ID / Name / ServiceAccount / SPIFFE ID)         │
   │    ├── Store Error / Desync ─────────────────────────────► DENY (403 Fail-Closed)
   │    ├── Matched in Contained Store ───────────────────────► DENY (403 Readmission Block)
   │    └── Not Contained                                      │
   │        ▼                                                  │
   │ 4. Kernel Node Containment Check                          │
   │    (nodeSelector: cgroup-v2=true & landlock=true)         │
   │    ├── Missing Selectors ────────────────────────────────► DENY (403 Capability Missing)
   │    └── Selectors Present ────────────────────────────────► ALLOW (200 Compliant)
   └───────────────────────────────────────────────────────────┘
```

---

## 3. Contained Identity Store Design & Multi-Plane Coordination

### Store Implementation
The identity store is implemented as a thread-safe, in-memory cache synchronized with Kubernetes ConfigMap projections (`signalloom-contained-agents` in `fe-signalloom`):
- **Lookup Cost**: `< 1 µs` (in-memory hash index).
- **Reload Trigger**: File modification time (`mtime`) check on admission requests.
- **Fail-Closed Guarantee**: Any disk read failure, invalid JSON syntax, or unreadable volume projection immediately returns `ErrStoreUnavailable`, causing the webhook to deny admission by default.

### Multi-Plane Alignment
The definition of "contained" is strictly aligned across all three execution planes:

| Plane | Component | Mechanism | State Indicator |
| :--- | :--- | :--- | :--- |
| **Mesh Plane (P3-1)** | Cilium / conntrack | `CiliumNetworkPolicy` default-deny + in-flight TCP `FlushIP` | `signalloom.ai/state: stunned` |
| **Admission Plane (P3-2)** | `node-capability-guard` | Webhook blocks pod reconstitution/restart matching contained identities | Store entry in `signalloom-contained-agents` |
| **Freeze Plane (P4-1)** | `stun-sentinel` | cgroup v2 process freezer (`cgroup.freeze`) halting execution in-place | `signalloom.io/containment-mode: frozen` |

---

## 4. Fail-Closed Failure Mode Analysis

### 1. `failurePolicy: Fail` (ValidatingWebhookConfiguration)
- **Design Rationale**: Setting `failurePolicy: Ignore` creates a fatal readmission bypass. An attacker could intentionally overload or crash the webhook pod to allow contained agents to reschedule unhindered. `failurePolicy: Fail` ensures the cluster defaults to safety.
- **Availability Guard**: `timeoutSeconds: 5` ensures that if the webhook hangs, the API server rejects the admission attempt in 5 seconds rather than waiting the default 10–30s.

### 2. Contained-Identity Store Failure
- **Behavior**: If the store file or ConfigMap becomes unreadable, `ContainedIdentityStore.IsContained` returns `ErrStoreUnavailable`.
- **Verdict**: `ValidatePodWithContext` rejects the pod with `OutcomeDeniedStoreUnavailable` (`403 Forbidden`) and increments `RejectionsStoreUnavailableTotal`. A broken store is never treated as "no one is contained".

---

## 5. CA Bundle & TLS Certificate Rotation Plan

### Provisioning & Injection
`node-capability-guard` serves HTTPS on port 8443. The TLS certificate is managed via `cert-manager`:
1. `base/validatingwebhookconfiguration.yaml` is annotated with:
   ```yaml
   cert-manager.io/inject-ca-from: fe-signalloom/node-capability-guard-tls
   ```
2. `cert-manager-cainjector` automatically populates the `caBundle` field of the `ValidatingWebhookConfiguration` with the root CA of the serving certificate.

### Rotation Schedule & Verification
- **Validity**: 90 days.
- **Renewal Window**: 30 days before expiration (automatic via cert-manager).
- **Failure Defense**: Probes on `/healthz` verify certificate validity. If certificate rotation fails, cert-manager emits Kubernetes warning events consumed by the cluster monitoring stack.

---

## 6. Observability & Telemetry

### Metric Counters (`/metrics`)
The Prometheus endpoint exports both legacy counters and fine-grained outcome counters:

```prometheus
# HELP node_capability_rejections_total Total number of agent pods rejected due to missing node containment capabilities or containment policy
# TYPE node_capability_rejections_total counter
node_capability_rejections_total 1

# HELP node_capability_admissions_total Total number of agent pods admitted with valid containment capabilities
# TYPE node_capability_admissions_total counter
node_capability_admissions_total 1

# HELP node_capability_rejections_contained_identity_total Total number of pods rejected due to contained agent identity match
# TYPE node_capability_rejections_contained_identity_total counter
node_capability_rejections_contained_identity_total 1

# HELP node_capability_rejections_store_unavailable_total Total number of pods rejected due to contained identity store unavailability (fail-closed)
# TYPE node_capability_rejections_store_unavailable_total counter
node_capability_rejections_store_unavailable_total 0

# HELP node_capability_rejections_node_capability_total Total number of agent pods rejected due to missing kernel node containment selectors
# TYPE node_capability_rejections_node_capability_total counter
node_capability_rejections_node_capability_total 0

# HELP node_capability_admissions_allowed_total Total number of compliant non-contained agent pods admitted
# TYPE node_capability_admissions_allowed_total counter
node_capability_admissions_allowed_total 1
```

### Structured Audit Log Records
Every decision emits a single-line JSON log matching `SharedAttestationEventKeys`:

```json
{"timestamp":"2026-09-15T05:04:44Z","event":"admission_decision","uid":"uid-stress-46","operation":"CREATE","namespace":"fe-signalloom-agents","pod_name":"agent-046-pod-46","agent_id":"046","spiffe_id":"spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-046","allowed":false,"outcome":"denied_contained_identity","reason":"agent pod rejected: agent identity \"agent-046\" is currently contained/stunned (readmission blocked on CREATE)","latency_ms":2,"worst_case_residual_ms":0,"residual_provenance":"measured (synchronous admission webhook block)"}
```

---

## 7. Verification & Benchmark Evidence

### 1. Concurrent Admission Benchmark (`TestWebhookDecisionLatency_ConcurrentLoad`)
Executed 100 concurrent admission review requests across mixed contained and uncontained agent pods:
- **Total Requests**: 100 concurrent
- **Average Decision Latency**: **358.8 µs**
- **Maximum Decision Latency**: **2.28 ms** (Performance ceiling: < 50 ms, timeout: 5,000 ms)
- **Allowed Count**: 50
- **Denied Count**: 50

### 2. Unit & Integration Test Summary (`pkg/webhook/handler_test.go`)
- `TestNonAgentPodAllowed`: Passed (non-agent pods admitted unconditionally).
- `TestUnconfinedAgentPodRejected`: Passed (missing cgroup-v2/landlock node selectors rejected).
- `TestCompliantAgentPodAllowed`: Passed (compliant agent pods admitted).
- `TestContainedAgentPodRejected_StoreMatch`: Passed (agent-name, agent-ID, and derived SPIFFE ID rejected on CREATE and UPDATE).
- `TestContainedAgentPodRejected_ManifestStunnedLabel`: Passed (manifest with stunned labels rejected).
- `TestContainedAgentPod_StoreFailure_FailsClosed`: Passed (store errors result in 403 denial).
- `TestHTTPWebhookValidation`: Passed (end-to-end HTTP admission reviews).
- `TestHTTPWebhookValidation_MetricsExport`: Passed (all Prometheus counters verified).
- `TestHTTPWebhookValidation_StructuredLogging`: Passed (JSON fields match attestation schema).
- `TestWebhookDecisionLatency_ConcurrentLoad`: Passed (< 2.3ms latency).
- `TestFileIdentityStore_Lifecycle`: Passed (file write, persistence, reload, delete).
- `TestHealthz_Endpoint`: Passed.

### 3. Fleet-Manager Integration Test Summary (`apps/fleet-manager/admission_client_test.go`)
- `TestAdmissionClient_BlockAdmission_Success`: Passed (ConfigMap sync and enforcement confirmed).
- `TestAdmissionClient_UnblockAdmission_Success`: Passed (ConfigMap removal on unblock confirmed).
- `TestAdmissionClient_Idempotency`: Passed (retry safety verified).
- `TestAdmissionClient_StructuredLogging`: Passed (all `SharedAttestationEventKeys` verified).
- `TestAdmissionResponseToPlaneResult`: Passed (`PlaneAdmission` schema mapping verified).

---

## 8. Conclusion

`SLER-P3-2` completely closes the readmission bypass surface. An agent contained by Signal Loom cannot be scheduled, reconstituted, or restarted anywhere in the cluster, with all decisions enforced synchronously in `< 3 ms` and attested via structured audit logs.
