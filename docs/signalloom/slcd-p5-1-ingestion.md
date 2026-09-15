# SLCD-P5-1 — Coding Agent Telemetry Ingestion Pipeline

**Status:** Complete · **Role:** Implementation · **Date:** 2026-09-15 · **Author:** SLCD-P5-1

---

## Executive Summary

This document describes the architectural implementation and security guarantees delivered under **SLCD-P5-1 (Wire Coding Agent Telemetry Dispatcher into Signal Loom Ingestion Pipeline)**. 

SLCD-P5-1 bridges the workstation detective sensor (`agentmaxxing-host-sensor`) to the Signal Loom ingestion plane (`signal-ingest`), resolves the routing gap flagged in SLCD-P1-3 and SLCD-P5-PRE, enforces strict multi-tenant isolation via cryptographic token claims, guarantees zero customer payload capture, and establishes mathematical resistance against two critical distributed telemetry failure modes:
1. **Small-group re-identification** via a strict $k$-anonymity floor ($k \ge 5$).
2. **Clock-skew-induced misordering** via per-workstation skew estimation and skew-bounded causal uncertainty windows.

---

## 1. Architectural Routing Decision

### 1.1 Evaluated Options & The Routing Gap
As analyzed in `docs/signalloom/slcd-p5-pre-routing-topology.md`, incoming requests to `/api/v1/telemetry/coding-agents` routed from Envoy Ingress Gateway or `dashboard-signalloom`'s `location /api/` terminate at `fe-signalloom-api:8000` (FastAPI BFF), while `signal-ingest` listens on `signal-ingest:8082` with a restrictive NetworkPolicy allowing ingress **only** from pods labeled `app.kubernetes.io/name: fe-signalloom`.

Three architectural options were evaluated:
- **Option 1 (FastAPI BFF Proxy in `fe-signalloom`)**: Recommended & Implemented. FastAPI mounts `/api/v1/telemetry/coding-agents` and proxies requests internally to `http://signal-ingest:8082`. Preserves existing NetworkPolicy, centralizes authentication & rate limiting, requires no Envoy Gateway or nginx modifications, and maintains single API gateway semantics.
- **Option 2 (Dedicated nginx `location` block in `dashboard-signalloom`)**: Rejected. Violates NetworkPolicy (`allow-signal-ingest-ingress` denies ingress from `dashboard-signalloom`), creates split routing between web clients and external API consumers, and introduces maintenance overhead in nginx reverse proxy configurations.
- **Option 3 (Envoy Gateway dedicated `HTTPRoute`)**: Rejected. Bypasses BFF middleware and requires re-architecting Ingress Gateway routing tables and TLS termination topology.

### 1.2 Implemented Topology
```
[ Detective Sensor / Client ]
            │
            ▼ (HTTPS / TLS)
[ Envoy Ingress Gateway / dashboard-signalloom nginx ]
            │ (PathPrefix: /api/)
            ▼
[ fe-signalloom-api (FastAPI BFF :8000) ]
  (src/coding_agent_telemetry.py)
            │ (Internal HTTP within fe-signalloom namespace)
            ▼
[ signal-ingest (:8082) ]
  (api/auth.go -> ProtectedRouter -> tenant_bridge.go -> api/telemetry_handler.go)
            │
            ▼
[ In-Memory / Distributed TelemetryStore ]
  (codingagent/store.go)
```

---

## 2. Tenant Isolation & Cryptographic Trust Boundaries

### 2.1 The Hostile Header Threat Model
In multi-tenant environments, malicious or misconfigured clients may attempt to inject arbitrary tenant identifiers via HTTP headers such as `X-Tenant-ID` or `X-SignalLoom-Tenant`.

### 2.2 Enforced Tenant Extraction Flow
1. **SPIFFE JWT / Bearer Token Verification**: Requests entering `signal-ingest` must pass through `NewProtectedRouter` (`api/auth.go`).
2. **Context Binding**: The authenticator validates the token signature, extracts the verified tenant claim, and injects it into `req.Context()` via `tenant_bridge.go` (`TenantContextKey`).
3. **Strict Ignore of Unauthenticated Headers**: `api/telemetry_handler.go` resolves tenant identity exclusively from `TenantFromContext(r.Context())`. Any `X-Tenant-ID` or `X-SignalLoom-Tenant` header present on the wire is completely ignored.
4. **Hostile Test Verification**: Verified by `TestCodingAgentTelemetry_HostileTenantHeaderIgnored` in `api/telemetry_handler_test.go`, which asserts that an attacker supplying `X-Tenant-ID: tenant-attacker` with a valid `tenant-victim` token is isolated strictly within `tenant-victim` storage.

---

## 3. Wire Contract & Closed-World Validation

### 3.1 Closed-World Decoding
Ingestion strictly adheres to the frozen wire contract specification defined in SLCD-P1-3 (`docs/signalloom/slcd-p1-3-wire-contract.md`).
- `json.NewDecoder(r.Body).DisallowUnknownFields()` is enforced on every payload.
- Unknown fields, malformed metadata, or payload schemas outside `codingagent.v1` are rejected immediately with `400 Bad Request` or `422 Unprocessable Entity`.
- No customer payloads, file contents, code strings, or secret values are present in the schema or accepted on the wire.

---

## 4. Monotonic Deduplication Strategy

### 4.1 Vulnerability of Wall-Clock Timestamps
In distributed systems, client wall-clock timestamps are susceptible to NTP shifts, local clock tampering, and network retry jitter. Relying on wall-clock timestamps for deduplication leads to duplicate event acceptance or false deduplication collisions.

### 4.2 Monotonic Anchor Implementation
Events are deduplicated within a tenant using a 4-tuple composite key derived from deterministic monotonic anchors:
$$\text{DeduplicationKey} = \langle \text{session\_id}, \text{task\_id}, \text{elapsed\_s}, \text{step\_count} \rangle$$

- If `task_id`, `elapsed_s`, or `step_count` are omitted, fallback anchors (such as event ID or normalized timestamp) are used deterministically.
- Duplicate submissions return `HTTP 200 OK` with `{"status":"duplicate","deduplicated":true}`, ensuring client retries are idempotent and store state remains clean.

---

## 5. Clock-Skew Estimation & Causal Ordering

### 5.1 Per-Workstation Skew Estimation
When telemetry arrives at `signal-ingest`, the ingestion pipeline computes the workstation clock-skew without mutating the client's original timestamp:
$$\text{EstimatedSkew} = \text{ObservedAt} - \text{ClientTimestamp}$$

Both $\text{Timestamp}$ and $\text{EstimatedSkew}$ are immutably stored in the telemetry record.

### 5.2 Skew-Bounded Causal Ordering
When querying causal orderings across distinct workstations $W_1$ and $W_2$ with event timestamps $t_1, t_2$ and skews $\Delta_1, \Delta_2$:
$$\Delta_{\text{max}} = \max(|\Delta_1|, |\Delta_2|)$$

If $|t_1 - t_2| \le \Delta_{\text{max}}$:
- Causal order cannot be asserted with certainty due to clock skew overlap.
- The pipeline sets `Uncertain: true` and annotates `UncertaintyReason: "clock skew overlap: |t1-t2| <= max(|skew1|, |skew2|)"`.
- Consumers (such as correlation analyzers and topology visualizers) can branch safely on deterministic causal bounds.

---

## 6. Small-Group Re-Identification Floor ($k \ge 5$)

### 6.1 Privacy Threat Model
Querying telemetry aggregates (such as tool execution frequency, token throughput, or error rates) over small groups of workstations allows adversaries to isolate and deanonymize individual developer workstations or project teams.

### 6.2 $k$-Anonymity Enforcement
All aggregate queries (`GET /api/v1/telemetry/coding-agents/aggregate` and `POST /api/v1/telemetry/coding-agents/aggregate`) enforce a hard anonymity floor:
$$k_{\text{floor}} = 5$$

- If the distinct number of workstations matching the query filter is less than $k_{\text{floor}}$, the pipeline aborts processing.
- The handler returns **`HTTP 422 Unprocessable Entity`** with error code `ErrGroupSizeBelowAnonymityFloor` and message:
  `"aggregate cohort size (N) is below the anonymity floor of 5 workstations; query refused to prevent re-identification"`.
- Verified by unit and integration tests in `codingagent/telemetry_pipeline_test.go` and `api/telemetry_handler_test.go`.

---

## 7. Detective Sensor Lawful-Basis Gate

### 7.1 Dispatcher Implementation
In `d2-signalloom/apps/agentmaxxing-host-sensor/dispatcher.py`, the `CodingAgentTelemetryDispatcher` executes a mandatory consent and policy preflight check prior to payload serialization and network dispatch:

```python
lawful_basis.assert_workstation_collection_permitted("dispatcher.dispatch")
```

If collection has been revoked or workstation consent policy is inactive, dispatch fails closed immediately with `PermissionError` before any network packet is emitted.

---

## 8. Verification & Test Evidence

| Test Suite | Scope / Verification Focus | Result |
|---|---|---|
| `api/telemetry_handler_test.go` | Hostile tenant header isolation, JWT authentication, closed-world rejection, monotonic deduplication, $k$-anonymity floor ($k < 5$), clock-skew uncertainty causal ordering | **PASS** (6/6) |
| `codingagent/telemetry_pipeline_test.go` | Store deduplication, clock skew computation, $k$-anonymity enforcement, causal ordering logic | **PASS** (4/4) |
| `codingagent/wire_contract_test.go` | Closed-world wire contract decoding, routing gap closure assertion | **PASS** (7/7) |
| `fe-signalloom/src/tests/test_coding_agent_telemetry.py` | FastAPI BFF proxy routing, query proxying, error propagation | **PASS** (2/2) |
| `agentmaxxing-host-sensor/test_dispatcher.py` | Lawful basis gating, dispatch serialization, failure handling | **PASS** (4/4) |
| `d2-signalloom/test/dashboard-route-collisions.bats` | Reverse proxy routing collision resistance | **PASS** |

---

## 9. Conclusion & Delivery

SLCD-P5-1 is fully implemented, verified, and ready for integration into `integration/slcd-v0.1.0`. All routing gaps are resolved via Option 1 (FastAPI BFF proxy), multi-tenant isolation is cryptographically enforced, and privacy/distributed consistency guards ($k \ge 5$, skew-bounded causal ordering) are fully active.
