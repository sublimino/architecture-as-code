# SLER-P1-2: Per-Plane Containment Dispatch Schema and Event Models

## 1. Executive Summary & Objective

This document defines the canonical wire schemas, event models, and envelope types for the Signal Loom Enforcement and Response (SLER) architecture.

Prior to SLER-P1-2, the fleet containment subsystem (`d2-signalloom/apps/fleet-manager/cascade.go`) used minimal types (`StateChangeEvent` and `CascadeResult`) that lacked outcome status, error reporting, and per-plane attribution. When underlying operations failed (e.g. unreadable pod state, credential revocation failure, or pod label write failure), the orchestrator logged a warning and proceeded, fabricating an unconditional success response (`HTTP 200` with `StateStunned`).

SLER-P1-2 provides the foundational data structures and wire contracts required by all downstream implementation cards (P1-1, P1-3, P1-4, P1-5, P2-1, P2-2, P3-1, P3-2, P4-1, P4-2, P4-3, P5-1, P5-2, P6-1) so that partial and failed containments are accurately represented across all five enforcement planes:
1. **Mesh Network Isolation** (`mesh`)
2. **OpenBao Credential Revocation** (`bao`)
3. **SPIRE Identity Eviction** (`spire`)
4. **Admission Control Block** (`admission`)
5. **Runtime Process Freeze** (`freeze`)

---

## 2. Architectural Principles & Schema Versioning

### 2.1 Explicit Schema Versioning
All wire models carry a `schema_version` field to enable schema freezing in P1-3 without breaking changes.
- **Active Schema Version:** `sler.signalloom.io/v1alpha1`
- **Go Constant:** `CurrentSchemaVersion = "sler.signalloom.io/v1alpha1"`

### 2.2 Tri-State Enforcement Outcome (`PlaneOutcome`)
Containment outcomes are modeled as a typed string enum rather than booleans or integers, ensuring that logs and wire payloads are self-describing without external code lookups:
- `contained`: The plane successfully and completely enforced containment.
- `partial`: The plane partially enforced containment (e.g. some leases revoked, or non-fatal degraded state).
- `unavailable`: The plane failed completely or the enforcement API was unreachable.

### 2.3 Idempotency Invariant
Every plane dispatch request and response carries an `idempotency_key` (UUID v4 or deterministic hash). Retried containment actions on any plane must be idempotent and safe under network timeouts.

---

## 3. Component & Consumer Card Mapping

| Schema Component / Field | Type | Description | Primary Consumer Cards |
| :--- | :--- | :--- | :--- |
| `PlaneOutcome` | Enum (`string`) | Tri-state outcome (`contained`, `partial`, `unavailable`) | All cards (P1-1 through P6-GOV) |
| `EnforcementPlane` | Enum (`string`) | Plane identifier (`mesh`, `bao`, `spire`, `admission`, `freeze`) | All cards |
| `PlaneResult` | Struct / JSON | Per-plane containment result carrying outcome, error, latency, and details | P1-1, P1-5, P2-1, P2-2, P3-1, P3-2, P4-1 |
| `StateChangeEvent.Success` | `bool` | Explicit flag indicating whether state transition succeeded | P1-5, P6-1, P6-3 |
| `StateChangeEvent.Error` | `string` | Diagnostic error string on state transition failure | P1-5, P6-1 |
| `CascadeResult.Planes` | `[]PlaneResult` | Array of per-plane results aggregated during cascade | P1-5, P5-1, P5-2 |
| `CascadeResult.OverallOutcome` | `PlaneOutcome` | Aggregated outcome of the cascade operation | P1-5, P6-3 |
| `ContainmentDecision` | Struct / JSON | Top-level fan-out and aggregation envelope | P1-1, P1-3, P5-1, P6-1 |
| `MeshIsolationRequest/Response` | Wire Model | Request/response for Cilium/Istio network policy isolation | P3-1, P3-GOV, P6-1 |
| `BaoRevokeRequest/Response` | Wire Model | Request/response for OpenBao token/lease revocation | P2-1, P2-GOV, P6-1 |
| `SpireEvictionRequest/Response` | Wire Model | Request/response for SPIRE server entry eviction & SVID denial | P2-2, P2-GOV, P6-1 |
| `AdmissionBlockRequest/Response` | Wire Model | Request/response for node-capability-guard admission block | P3-2, P3-GOV, P6-1 |
| `FreezeRequest/Response` | Wire Model | Request/response for stun-sentinel cgroup v2 / SIGSTOP freeze | P4-1, P4-2, P4-GOV, P6-1 |
| `ResumeToken` & `ResumeRequest/Response` | Wire Model | Governance-signed token and unfreeze/credential renewal request | P1-3, P4-3, P4-GOV |
| `AttestedRecordDigest` | `string` | Cryptographic digest binding containment to Witness attestation | P5-1, P5-GOV |
| `LatencyMs` | `int64` | Measured execution latency per plane | P5-2, P6-2 |

---

## 4. Core Data Structures & Wire Models

### 4.1 Enums & Types

```go
type PlaneOutcome string

const (
    OutcomeContained   PlaneOutcome = "contained"
    OutcomePartial     PlaneOutcome = "partial"
    OutcomeUnavailable PlaneOutcome = "unavailable"
)

type EnforcementPlane string

const (
    PlaneMesh      EnforcementPlane = "mesh"
    PlaneBao       EnforcementPlane = "bao"
    PlaneSpire     EnforcementPlane = "spire"
    PlaneAdmission EnforcementPlane = "admission"
    PlaneFreeze    EnforcementPlane = "freeze"
)
```

### 4.2 Per-Plane Result (`PlaneResult`)
```go
type PlaneResult struct {
    Plane     EnforcementPlane `json:"plane"`
    Outcome   PlaneOutcome     `json:"outcome"`
    Error     string           `json:"error,omitempty"`
    Timestamp string           `json:"timestamp"`
    LatencyMs int64            `json:"latency_ms,omitempty"`
    Details   map[string]any   `json:"details,omitempty"`
}
```

### 4.3 Extended StateChangeEvent & CascadeResult
```go
type StateChangeEvent struct {
    AgentID   string `json:"agent_id"`
    FromState string `json:"from_state"`
    ToState   string `json:"to_state"`
    Timestamp string `json:"timestamp"`
    Success   bool   `json:"success"`
    Error     string `json:"error,omitempty"`
}

type CascadeResult struct {
    SchemaVersion  string             `json:"schema_version,omitempty"`
    TargetAgent    string             `json:"target_agent"`
    AffectedAgents []string           `json:"affected_agents"`
    Events         []StateChangeEvent `json:"events"`
    Planes         []PlaneResult      `json:"planes,omitempty"`
    DurationMs     int64              `json:"duration_ms"`
    RecoveryOrder  []string           `json:"recovery_order,omitempty"`
    OverallOutcome PlaneOutcome       `json:"overall_outcome,omitempty"`
}
```

### 4.4 ContainmentDecision Envelope
```go
type TargetRef struct {
    AgentID   string `json:"agent_id"`
    Namespace string `json:"namespace"`
    PodName   string `json:"pod_name,omitempty"`
    SPIFFEID  string `json:"spiffe_id,omitempty"`
    NodeName  string `json:"node_name,omitempty"`
}

type ContainmentReason struct {
    Code                  string `json:"code"`
    Description           string `json:"description"`
    TriggeredBy           string `json:"triggered_by"`
    DelegationEdgeRevoked bool   `json:"delegation_edge_revoked"`
    AttestationDigest     string `json:"attestation_digest,omitempty"`
}

type ContainmentDecision struct {
    DecisionID           string             `json:"decision_id"`
    SchemaVersion        string             `json:"schema_version"`
    IdempotencyKey       string             `json:"idempotency_key"`
    Target               TargetRef          `json:"target"`
    Reason               ContainmentReason  `json:"reason"`
    RequestedPlanes      []EnforcementPlane `json:"requested_planes"`
    PlaneResults         []PlaneResult      `json:"plane_results"`
    OverallOutcome       PlaneOutcome       `json:"overall_outcome"`
    DurationMs           int64              `json:"duration_ms"`
    Timestamp            string             `json:"timestamp"`
    AttestedRecordDigest string             `json:"attested_record_digest,omitempty"`
}
```

---

## 5. Wire Schemas for Plane Dispatch

### 5.1 Mesh Isolation Wire Schema
- **Request (`MeshIsolationRequest`)**:
```json
{
  "schema_version": "sler.signalloom.io/v1alpha1",
  "idempotency_key": "idem-mesh-001",
  "agent_id": "agent-cardvault",
  "namespace": "fe-signalloom-agents",
  "pod_name": "agent-cardvault-7d8b89c4-x9q2p",
  "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault",
  "target_ips": ["10.244.0.15"],
  "reason": "Unauthorized delegation traversal detected by Signal Fusion",
  "timestamp": "2026-09-15T01:00:00Z",
  "metadata": {
    "policy_template": "deny-all-ingress-egress"
  }
}
```
- **Response (`MeshIsolationResponse`)**:
```json
{
  "schema_version": "sler.signalloom.io/v1alpha1",
  "idempotency_key": "idem-mesh-001",
  "agent_id": "agent-cardvault",
  "plane": "mesh",
  "outcome": "contained",
  "policy_applied": true,
  "connections_cut": 4,
  "latency_ms": 15,
  "timestamp": "2026-09-15T01:00:00Z"
}
```

### 5.2 OpenBao Revocation Wire Schema
- **Request (`BaoRevokeRequest`)**:
```json
{
  "schema_version": "sler.signalloom.io/v1alpha1",
  "idempotency_key": "idem-bao-001",
  "agent_id": "agent-cardvault",
  "namespace": "fe-signalloom-agents",
  "lease_ids": ["database/creds/readonly/sler-1234"],
  "token_accessor": "accessor-abcdef123456",
  "revoke_all_tokens": true,
  "reason": "Active containment cascade",
  "timestamp": "2026-09-15T01:00:00Z"
}
```
- **Response (`BaoRevokeResponse`)**:
```json
{
  "schema_version": "sler.signalloom.io/v1alpha1",
  "idempotency_key": "idem-bao-001",
  "agent_id": "agent-cardvault",
  "plane": "bao",
  "outcome": "contained",
  "revoked_leases": 1,
  "tokens_invalidated": 3,
  "latency_ms": 42,
  "timestamp": "2026-09-15T01:00:00Z"
}
```

### 5.3 SPIRE Eviction Wire Schema
- **Request (`SpireEvictionRequest`)**:
```json
{
  "schema_version": "sler.signalloom.io/v1alpha1",
  "idempotency_key": "idem-spire-001",
  "agent_id": "agent-cardvault",
  "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault",
  "entry_ids": ["entry-001", "entry-002"],
  "reason": "Attested containment order",
  "timestamp": "2026-09-15T01:00:00Z"
}
```
- **Response (`SpireEvictionResponse`)**:
```json
{
  "schema_version": "sler.signalloom.io/v1alpha1",
  "idempotency_key": "idem-spire-001",
  "agent_id": "agent-cardvault",
  "plane": "spire",
  "outcome": "contained",
  "entries_evicted": 2,
  "svids_invalidated": 2,
  "latency_ms": 18,
  "timestamp": "2026-09-15T01:00:00Z"
}
```

### 5.4 Admission Block Wire Schema
- **Request (`AdmissionBlockRequest`)**:
```json
{
  "schema_version": "sler.signalloom.io/v1alpha1",
  "idempotency_key": "idem-adm-001",
  "agent_id": "agent-cardvault",
  "namespace": "fe-signalloom-agents",
  "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault",
  "match_labels": {
    "app.kubernetes.io/name": "agent-cardvault"
  },
  "ttl_seconds": 3600,
  "reason": "Quarantine active: prevent pod reschedule/restart",
  "timestamp": "2026-09-15T01:00:00Z"
}
```
- **Response (`AdmissionBlockResponse`)**:
```json
{
  "schema_version": "sler.signalloom.io/v1alpha1",
  "idempotency_key": "idem-adm-001",
  "agent_id": "agent-cardvault",
  "plane": "admission",
  "outcome": "contained",
  "rule_id": "ncg-rule-9988",
  "block_enforced": true,
  "latency_ms": 9,
  "timestamp": "2026-09-15T01:00:00Z"
}
```

### 5.5 Freeze Engine Wire Schema
- **Request (`FreezeRequest`)**:
```json
{
  "schema_version": "sler.signalloom.io/v1alpha1",
  "idempotency_key": "idem-frz-001",
  "agent_id": "agent-cardvault",
  "namespace": "fe-signalloom-agents",
  "pod_name": "agent-cardvault-7d8b89c4-x9q2p",
  "container_id": "containerd://1234567890abcdef",
  "cgroup_path": "/sys/fs/cgroup/kubepods.slice/agent-cardvault",
  "freeze_method": "cgroup.freeze",
  "reason": "In-place memory preservation for forensics",
  "timestamp": "2026-09-15T01:00:00Z"
}
```
- **Response (`FreezeResponse`)**:
```json
{
  "schema_version": "sler.signalloom.io/v1alpha1",
  "idempotency_key": "idem-frz-001",
  "agent_id": "agent-cardvault",
  "plane": "freeze",
  "outcome": "contained",
  "processes_frozen": 4,
  "cgroup_state": "FROZEN",
  "memory_preserved": true,
  "latency_ms": 5,
  "timestamp": "2026-09-15T01:00:00Z"
}
```

### 5.6 Governance Resume Wire Schema
- **Request (`ResumeRequest`)**:
```json
{
  "schema_version": "sler.signalloom.io/v1alpha1",
  "idempotency_key": "idem-res-001",
  "agent_id": "agent-cardvault",
  "namespace": "fe-signalloom-agents",
  "token": {
    "token_id": "tok-res-7788",
    "agent_id": "agent-cardvault",
    "operator_id": "secops-lead@company.internal",
    "governance_approval_ref": "gov-rec-20260915-01",
    "issued_at": "2026-09-15T01:05:00Z",
    "expires_at": "2026-09-15T01:15:00Z",
    "signature": "sig-ecdsa-p256-verified"
  },
  "timestamp": "2026-09-15T01:06:00Z"
}
```
- **Response (`ResumeResponse`)**:
```json
{
  "schema_version": "sler.signalloom.io/v1alpha1",
  "idempotency_key": "idem-res-001",
  "agent_id": "agent-cardvault",
  "success": true,
  "processes_resumed": 4,
  "credentials_rotated": true,
  "latency_ms": 35,
  "timestamp": "2026-09-15T01:06:01Z"
}
```

---

## 6. Worked Example: Partial Containment Payload

Below is the complete worked example JSON payload demonstrating a **partial containment** scenario.
In this scenario:
- **Mesh** was `contained` (connections severed).
- **OpenBao** was `unavailable` (API endpoint unreachable / connection refused).
- **SPIRE** was `partial` (entry deleted, cache invalidation partial ack).
- **Admission** was `contained` (webhook block applied).
- **Freeze** was `contained` (processes frozen via cgroup v2).
- **Overall Outcome** evaluated to `partial`.

```json
{
  "decision_id": "dec-20260915-01-partial-containment",
  "schema_version": "sler.signalloom.io/v1alpha1",
  "idempotency_key": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
  "target": {
    "agent_id": "agent-cardvault",
    "namespace": "fe-signalloom-agents",
    "pod_name": "agent-cardvault-7d8b89c4-x9q2p",
    "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault",
    "node_name": "kind-worker"
  },
  "reason": {
    "code": "UNAUTHORIZED_DELEGATION_TRAVERSAL",
    "description": "Agent attempted delegation edge traversal without signed provenance chain",
    "triggered_by": "signal-fusion-governor",
    "delegation_edge_revoked": true,
    "attestation_digest": "sha256:4b227777d4dd1fc61c6f884f48641d02b4d121d3fd328cb08b5531fcacdabf8a"
  },
  "requested_planes": [
    "mesh",
    "bao",
    "spire",
    "admission",
    "freeze"
  ],
  "plane_results": [
    {
      "plane": "mesh",
      "outcome": "contained",
      "latency_ms": 8,
      "timestamp": "2026-09-15T01:00:00Z",
      "details": {
        "connections_cut": 4,
        "policy": "deny-all-ingress-egress"
      }
    },
    {
      "plane": "bao",
      "outcome": "unavailable",
      "error": "dial tcp 10.96.120.44:8200: connect: connection refused",
      "latency_ms": 1500,
      "timestamp": "2026-09-15T01:00:01Z"
    },
    {
      "plane": "spire",
      "outcome": "partial",
      "error": "spire-server entry deleted, but SVID cache invalidation returned partial ack",
      "latency_ms": 45,
      "timestamp": "2026-09-15T01:00:01Z"
    },
    {
      "plane": "admission",
      "outcome": "contained",
      "latency_ms": 12,
      "timestamp": "2026-09-15T01:00:01Z",
      "details": {
        "webhook_rule_id": "ncg-block-agent-cardvault"
      }
    },
    {
      "plane": "freeze",
      "outcome": "contained",
      "latency_ms": 4,
      "timestamp": "2026-09-15T01:00:01Z",
      "details": {
        "cgroup_path": "/sys/fs/cgroup/kubepods.slice/agent-cardvault",
        "processes_frozen": 3
      }
    }
  ],
  "overall_outcome": "partial",
  "duration_ms": 1569,
  "timestamp": "2026-09-15T01:00:01Z",
  "attested_record_digest": "sha256:7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069"
}
```

---

## 7. Review Against `cascade.go`'s Three Swallow Points

The initial `cascade.go` implementation contained three distinct error swallow points that masked containment failures as successful events:

### Swallow Point 1: `cascade.go:90-91` (`GetPodState` error)
- **Previous Behavior**: If `o.client.GetPodState` returned an error, the orchestrator emitted `slog.Warn` and unconditionally set `currentState = StateRunning`, proceeding with the cascade.
- **Remediation with P1-2 Schema**:
  - `StateChangeEvent.Success` is set to `false`.
  - `StateChangeEvent.Error` records `err.Error()` (e.g. `"pod not found in namespace fe-signalloom-agents"`).
  - P1-5 writes a `PlaneResult` with `Plane: PlaneAdmission` / `Outcome: OutcomeUnavailable` if pod inspection fails catastrophically.

### Swallow Point 2: `cascade.go:96` (`RevokeCredentials` error)
- **Previous Behavior**: If `o.client.RevokeCredentials` returned an error, `slog.Warn` was emitted and the function proceeded directly to pod labeling, never recording that credentials remained valid.
- **Remediation with P1-2 Schema**:
  - P1-5 writes a `PlaneResult` for `Plane: PlaneBao` (and `Plane: PlaneSpire`) with `Outcome: OutcomeUnavailable` (or `OutcomePartial`), capturing `Error: err.Error()`.
  - `CascadeResult.Planes` records this failure, downgrading `CascadeResult.OverallOutcome` from `contained` to `partial` or `unavailable`.

### Swallow Point 3: `cascade.go:101` (`SetPodState` error)
- **Previous Behavior**: If `o.client.SetPodState` failed, `slog.Warn` was emitted, but `result.Events` immediately appended a `StateChangeEvent` reporting `ToState: StateStunned`, and the HTTP API answered `200 OK`.
- **Remediation with P1-2 Schema**:
  - `StateChangeEvent.Success` is explicitly set to `false`.
  - `StateChangeEvent.Error` records `err.Error()` (e.g. `"admission webhook denied update"` or `"etcd lease timeout"`).
  - `CascadeResult.OverallOutcome` reflects that the agent pod state was not updated.

---

## 8. Verification & Test Evidence

The schema and its wire contracts are validated in `d2-signalloom/apps/fleet-manager/schema_test.go`:
- `TestSchemaVersionConstants`: Asserts `CurrentSchemaVersion` matches `sler.signalloom.io/v1alpha1`.
- `TestPlaneOutcome_StringConstantsAndValidation`: Asserts `contained`, `partial`, `unavailable` validation and rejection of bare integers or unknown strings.
- `TestEnforcementPlane_StringConstantsAndValidation`: Validates all 5 planes (`mesh`, `bao`, `spire`, `admission`, `freeze`).
- `TestPartialContainment_SurvivesJSONRoundTripWithoutCoercion`: Asserts that a mixed multi-plane failure round-trips without coercion into a single boolean.
- `TestAggregateOutcome`: Verifies all permutations of aggregation logic.
- `TestStateChangeEvent_SuccessAndErrorRoundTrip`: Verifies error retention in state transition events.
- `TestCascadeResult_PlanesAndOverallOutcome`: Verifies cascade payload structure.
- `TestPlaneWireModels_RoundTrip`: Exercises JSON serialization and deserialization for all 5 plane request/response models and governance resume tokens.
