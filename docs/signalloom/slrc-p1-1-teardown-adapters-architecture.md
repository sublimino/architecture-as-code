# Environment Teardown Adapters Architecture & Exception Contract

> **Card:** SLRC-P1-1 · **Component:** `d2-signalloom/apps/fe-signalloom`
> **Status:** Implemented and verified with comprehensive regression test suite
> **Contract:** [`environment_teardown_contract.py`](../../d2-signalloom/apps/fe-signalloom/src/environment_teardown_contract.py)
> **Implementation:** [`environment_teardown_adapters.py`](../../d2-signalloom/apps/fe-signalloom/src/environment_teardown_adapters.py)

## Overview

The Signal Loom Environment Teardown subsystem orchestrates deterministic deallocation and cryptographic sanitization of ephemeral customer environments (EAP). It guarantees fail-closed isolation across four sequential stages:

1. **Route (`ROUTE`)**: Removal and verification of Gateway API `HTTPRoute` resources.
2. **Mesh (`MESH`)**: Revocation and eviction of Tailscale node keys with ownership attribution.
3. **Key and SPIRE (`KEY_SPIRE`)**: Transit key shredding in OpenBao and workload registration deletion in SPIRE.
4. **Namespace and Storage (`NAMESPACE_STORAGE`)**: Deletion of the Kubernetes tenant namespace and absence proof of PersistentVolumes.

## Exception Hierarchy

The exception hierarchy in `environment_teardown_contract.py` defines explicit failure classes to prevent silent swallowing or misclassification of security errors:

```
TeardownError (Exception)
├── TeardownAuthorizationError   (HTTP 403 / permission denial)
├── TeardownSecurityError        (HTTP 500, redirect rejection, payload limits)
├── AttributionError             (Unowned, non-fixture, or foreign nodes)
└── DeadlineExceeded             (Stage timeout exhaustion)
```

| Exception | Trigger Condition | Fail-Closed Policy |
| :--- | :--- | :--- |
| `TeardownAuthorizationError` | HTTP 403 Forbidden or RBAC lookup failure | Halts stage progression; never reported as absent or successful |
| `TeardownSecurityError` | Server 500 error, 3xx redirect attempt, response body overflow | Halts stage progression; aborts pipeline |
| `AttributionError` | Node hostname collision without authoritative ownership record | Prevents deletion of unowned or workstation devices |
| `DeadlineExceeded` | Total elapsed execution time exceeds monotonic stage deadline | Terminates child process group via `SIGKILL` |

## Security Bloc and Defect Mitigations

### 1. Fail-Closed Kubernetes Namespace Verification (C1)
`KubernetesNamespaceStorageClient.namespace_exists` executes `kubectl get namespace <ns> --ignore-not-found -o name`:
- Standard absence: Clean return code `0` with empty stdout confirms absence (`False`).
- Existing namespace: Return code `0` with stdout `namespace/<ns>` confirms presence (`True`).
- Non-zero returncode: If stderr indicates forbidden or 403, raises `TeardownAuthorizationError("namespace_lookup_failed: ...")`. Any other non-zero exit raises `RuntimeError("namespace_lookup_failed: ...")`.

### 2. Tailscale & SPIRE Schema Validation (C2, C3)
Loose dictionary lookups (`.get("devices", [])` / `.get("entries", [])`) are replaced by fail-closed schema checks:
- Tailscale API response must be a JSON object containing a `"devices"` list; missing or malformed collections raise `RuntimeError("invalid_tailscale_inventory")`.
- SPIRE CLI response must contain an `"entries"` list; missing or malformed output raises `RuntimeError("invalid_spire_inventory")`.

### 3. Tailscale Ownership Attribution (C4)
`MeshAdapter` requires an explicit `ownership` inventory mapping `customer_hash` to expected device IDs and tags:
- Missing inventory: Aborts with `ownership_inventory_missing` (`StageResult.success = False`).
- Unowned node collision: If a node matches the prefix `sl-eap-<hash>` but its device ID is not in `device_ids` or its tags mismatch, aborts with `mesh_ownership_collision` and performs zero deletions.

### 4. Strict SPIFFE Trust Domain and Path Parsing (H1)
`KeySpireAdapter._tenant_entries` parses both string (`spiffe://trust_domain/path`) and dictionary representations:
- Validates exact trust domain `signalloom.demo`.
- Validates exact path prefix `/ns/eap-<customer_hash>/`.
- Rejects cross-trust-domain collisions and substring path collisions.

### 5. OpenBao Status Code and Encryption Integrity (H2)
`OpenBaoHTTPClient` enforces HTTPS for remote connections and verifies each stage of key shredding:
- Post-shred confirmation: A `GET` to `/v1/transit/keys/eap-<hash>` must return `404 Not Found` to confirm deletion.
- Authorization and Server Errors: Status `403` raises `TeardownAuthorizationError`, status `>= 500` raises `TeardownSecurityError`.
- Idempotent Retries: HTTP `404` during initial config or deletion requests is treated as already deleted, permitting safe checkpoint retries.

### 6. Bounded HTTP Transport (H3)
`BoundedHTTPTransport` guarantees deterministic bounded I/O:
- Enforces total deadline across the entire request/response lifecycle.
- Reads response bodies in bounded chunks against `max_body_bytes`.
- Rejects 3xx redirects immediately with `TeardownSecurityError("http_redirect_rejected")` to prevent secret header forwarding.

### 7. Provider Exception Sanitization (H4)
`ConfiguredTeardownExecutor` catches internal provider exceptions and returns `detail="provider_failed"`, preventing raw tokens or header values from leaking into persistent audit logs.

### 8. Storage Absence Non-Erasure Proof (M1)
`KubernetesNamespaceStorageClient.storage_absence_proof` inspects cluster PV claims and returns `verified=False` with `blocker="durable_storage_erasure_unproved"`, preventing passive observation from falsely certifying physical data destruction.

### 9. Synchronous Read-Only `verify()` Contract (M2)
`StageExecutor` defines synchronous `verify(self, stage, request) -> StageResult`:
- All adapters implement non-mutating `verify()` methods that inspect resource absence without issuing delete commands.
- `FailClosedExecutor.verify()` returns `StageResult(stage, False, reason, {"configured": False})`.
