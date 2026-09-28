# EAPR Phase 2 Preflight Audit — EAP Anonymous Surface & Shared Patterns

**Date:** 2026-09-24  
**Integration Branch:** `refs/heads/integration/eapr-v0.1.0`  
**Base Ref SHA:** `0445bb53fc8e683585418b1571282d7505e69b5b`  
**Tag:** `integration/eapr-v0.1.0-p1`  
**Card:** `EAPR-P2-PRE`  

---

## 1. Executive Summary

This preflight audit enumerates the unauthenticated EAP attack surface on the merged integration branch `integration/eapr-v0.1.0` (post-P1-GOV merge of all five EAP integration tracks: `slea`, `slet`, `sled`, `sles`, `slte`).

The audit establishes the precise measurement for Phase 2 implementation cards:
1. **Measured Operation Count:** Exactly **35 operations** (34 HTTP operations + 1 WebSocket route) across the five EAP routers.
2. **Anonymous Attack Surface:** **31 operations** are unconditionally reachable without any `Authorization` header or credentials.
3. **Critical Header-Forging Vulnerability:** 2 OpenBao Transit operations (`POST .../transit/encrypt` and `POST .../transit/decrypt`) accept a client-forged `X-SPIFFE-ID` header without any bearer token or mTLS SVID verification, decrypting customer plaintext with HTTP 200.
4. **Signature-Gated Endpoints:** 2 webhook receiver endpoints (`POST /api/v1/webhooks/generic` and `POST /api/v1/webhooks/github`) enforce HMAC signature verification (returning 401 without signature); these are scheduled for removal in P3-4.
5. **Streaming Surface:** Live SSE stream `GET /api/v1/eap/scenarios/events/{customer_hash}/stream` and WebSocket stream `WS /api/v1/environments/{environment_id}/telemetry` are completely unauthenticated and stream customer event data to anonymous callers.

---

## 2. Positive Controls

To prove that the audit harness and test client accurately distinguish authenticated from unauthenticated endpoints, and that header checks operate correctly against this tree, two positive controls were verified:

1. **T1 Protected Route Positive Control:**
   Probing protected route `GET /api/agents/claim` without an `Authorization` header returns:
   ```
   HTTP/1.1 401 Unauthorized
   {"error": {"code": "authentication_required", "message": "Bearer authentication is required"}}
   ```
   This confirms that `TestClient` does not bypass authentication globally.

2. **T4 Header Search Positive Control:**
   - Probing HEAD (`844afa5a`) for `X-SPIFFE-ID` produces **0 matches**:
     ```bash
     $ git grep 'X-SPIFFE-ID' 844afa5a
     # exit code 1 (zero matches)
     ```
   - Probing `Authorization` on `api_compat.py` produces matches (positive proof that header grep inspects the file):
     ```bash
     $ grep -rn 'Authorization' api_compat.py | head -1
     4455:    forward ``Authorization``, unlike the ``/demo-api/`` block below it. Every
     ```
   - Probing merged tip (`0445bb53`) confirms `X-SPIFFE-ID` was introduced in `tenant_isolation.py:498` and `:517`.

---

## 3. T1 Table: EAP Operations & Anonymous Reachability

The table below catalogs all 35 operations mounted by the five EAP routers on `integration/eapr-v0.1.0`.

| # | Method | Path | Router Module | Handler | Anonymous Status | Reachability Classification |
|---|--------|------|---------------|---------|------------------|-----------------------------|
| 1 | `GET` | `/api/v1/eap/lifecycle/active` | `environment_lifecycle.py` | `api_list_active_lifecycle` | 200 OK | **ANONYMOUS REACHABLE** |
| 2 | `GET` | `/api/v1/eap/lifecycle/audit-events` | `environment_lifecycle.py` | `api_get_audit_events` | 200 OK | **ANONYMOUS REACHABLE** |
| 3 | `GET` | `/api/v1/eap/lifecycle/environments/{customer_hash}` | `environment_lifecycle.py` | `api_get_lifecycle` | 200 OK | **ANONYMOUS REACHABLE** |
| 4 | `POST` | `/api/v1/eap/lifecycle/environments/{customer_hash}/activity` | `environment_lifecycle.py` | `api_record_activity` | 200 OK | **ANONYMOUS REACHABLE** |
| 5 | `POST` | `/api/v1/eap/lifecycle/environments/{customer_hash}/heartbeat` | `environment_lifecycle.py` | `api_heartbeat` | 200 OK | **ANONYMOUS REACHABLE** |
| 6 | `GET` | `/api/v1/eap/lifecycle/metrics` | `environment_lifecycle.py` | `api_get_lifecycle_metrics` | 200 OK | **ANONYMOUS REACHABLE** |
| 7 | `POST` | `/api/v1/eap/lifecycle/reap-now` | `environment_lifecycle.py` | `api_trigger_reaping_pass` | 200 OK | **ANONYMOUS REACHABLE** |
| 8 | `GET` | `/api/v1/eap/lifecycle/reaper/dlq` | `environment_lifecycle.py` | `api_get_dlq` | 200 OK | **ANONYMOUS REACHABLE** |
| 9 | `POST` | `/api/v1/eap/lifecycle/reaper/dlq/clear` | `environment_lifecycle.py` | `api_clear_dlq` | 200 OK | **ANONYMOUS REACHABLE** |
| 10 | `POST` | `/api/v1/eap/lifecycle/reaper/pause` | `environment_lifecycle.py` | `api_pause_reaper` | 200 OK | **ANONYMOUS REACHABLE** |
| 11 | `POST` | `/api/v1/eap/lifecycle/reaper/resume` | `environment_lifecycle.py` | `api_resume_reaper` | 200 OK | **ANONYMOUS REACHABLE** |
| 12 | `GET` | `/api/v1/eap/lifecycle/reaper/status` | `environment_lifecycle.py` | `api_get_reaper_status` | 200 OK | **ANONYMOUS REACHABLE** |
| 13 | `POST` | `/api/v1/eap/lifecycle/register` | `environment_lifecycle.py` | `api_register_lifecycle` | 201 Created | **ANONYMOUS REACHABLE** |
| 14 | `GET` | `/api/v1/environments/` | `environment_routing.py` | `list_environments` | 200 OK | **ANONYMOUS REACHABLE** |
| 15 | `POST` | `/api/v1/environments/provision` | `environment_routing.py` | `provision_environment` | 201 Created | **ANONYMOUS REACHABLE** |
| 16 | `POST` | `/api/v1/environments/resolve-domain` | `environment_routing.py` | `resolve_domain` | 200 OK | **ANONYMOUS REACHABLE** |
| 17 | `GET` | `/api/v1/environments/{environment_id}` | `environment_routing.py` | `get_environment` | 200 OK | **ANONYMOUS REACHABLE** |
| 18 | `POST` | `/api/v1/environments/{environment_id}/extend` | `environment_routing.py` | `extend_environment_ttl` | 200 OK | **ANONYMOUS REACHABLE** |
| 19 | `GET` | `/api/v1/environments/{environment_id}/probe` | `environment_routing.py` | `probe_environment` | 200 OK / 410 Gone | **ANONYMOUS REACHABLE** |
| 20 | `POST` | `/api/v1/environments/{environment_id}/teardown` | `environment_routing.py` | `teardown_environment` | 200 OK | **ANONYMOUS REACHABLE** |
| 21 | `WS` | `/api/v1/environments/{environment_id}/telemetry` | `environment_routing.py` | `stream_environment_telemetry` | 200 Connected | **ANONYMOUS REACHABLE (WS)** |
| 22 | `GET` | `/api/v1/eap/scenarios/events/{customer_hash}` | `scenario_seeding.py` | `api_get_customer_events` | 200 OK | **ANONYMOUS REACHABLE** |
| 23 | `GET` | `/api/v1/eap/scenarios/events/{customer_hash}/stream` | `scenario_seeding.py` | `api_stream_customer_events` | 200 SSE | **ANONYMOUS REACHABLE (SSE)** |
| 24 | `POST` | `/api/v1/eap/scenarios/execute` | `scenario_seeding.py` | `api_execute_scenario` | 201 Created | **ANONYMOUS REACHABLE** |
| 25 | `GET` | `/api/v1/eap/scenarios/history` | `scenario_seeding.py` | `api_get_scenario_history` | 200 OK | **ANONYMOUS REACHABLE** |
| 26 | `POST` | `/api/v1/eap/tenants` | `tenant_isolation.py` | `api_provision_tenant` | 201 Created | **ANONYMOUS REACHABLE** |
| 27 | `GET` | `/api/v1/eap/tenants` | `tenant_isolation.py` | `api_list_tenants` | 200 OK | **ANONYMOUS REACHABLE** |
| 28 | `GET` | `/api/v1/eap/tenants/{customer_hash}` | `tenant_isolation.py` | `api_get_tenant` | 200 OK | **ANONYMOUS REACHABLE** |
| 29 | `DELETE` | `/api/v1/eap/tenants/{customer_hash}` | `tenant_isolation.py` | `api_teardown_tenant` | 200 OK | **ANONYMOUS REACHABLE** |
| 30 | `GET` | `/api/v1/eap/tenants/{customer_hash}/manifests` | `tenant_isolation.py` | `api_get_tenant_manifests` | 200 OK | **ANONYMOUS REACHABLE** |
| 31 | `GET` | `/api/v1/eap/tenants/{customer_hash}/spire-entry` | `tenant_isolation.py` | `api_get_tenant_spire_entry` | 200 OK | **ANONYMOUS REACHABLE** |
| 32 | `POST` | `/api/v1/eap/tenants/{customer_hash}/transit/encrypt` | `tenant_isolation.py` | `api_tenant_encrypt` | 403 / 200 with X-SPIFFE-ID | **FORGED-HEADER REACHABLE** |
| 33 | `POST` | `/api/v1/eap/tenants/{customer_hash}/transit/decrypt` | `tenant_isolation.py` | `api_tenant_decrypt` | 403 / 200 with X-SPIFFE-ID | **FORGED-HEADER REACHABLE** |
| 34 | `POST` | `/api/v1/webhooks/generic` | `webhook_triggers.py` | `generic_webhook_receiver` | 401 Unauthorized (HMAC) | HMAC-protected (delete P3-4) |
| 35 | `POST` | `/api/v1/webhooks/github` | `webhook_triggers.py` | `github_webhook_receiver` | 401 Unauthorized (HMAC) | HMAC-protected (delete P3-4) |

**Summary Reachability Counts:**
- Total EAP Operations: **35**
- Unconditionally Anonymous Reachable: **31**
- Forged `X-SPIFFE-ID` Reachable without Bearer: **2**
- HMAC Signature Protected: **2**

---

## 4. Reconciliation of Operation Counts

Why does earlier documentation cite 23 or 25 routes?
- **At HEAD (`844afa5a`):** 23 routes were mounted across four partial routers before transit encryption and telemetry were merged.
- **After SLET merge:** 2 transit routes (`encrypt` and `decrypt`) were added to `tenant_isolation.py` (bringing tenant routes from 6 to 8, total 25).
- **Across the full 5-router merged tip (`0445bb53`):**
  - `tenant_isolation.py`: 8 routes (6 standard + 2 transit)
  - `scenario_seeding.py`: 4 routes (3 standard + 1 SSE stream)
  - `environment_routing.py`: 8 routes (6 standard + 1 probe + 1 WebSocket telemetry)
  - `environment_lifecycle.py`: 13 routes (register, heartbeat, activity, get, active, reap-now, pause, resume, status, dlq, dlq/clear, audit-events, metrics)
  - `webhook_triggers.py`: 2 routes (github, generic)
  - **Sum:** `8 + 4 + 8 + 13 + 2 = 35 operations`.

---

## 5. T3 Exemption List Verbatim

### 5.1 The 16 EAP entries in `NOT_DATABASE_BACKED`
From `tests/test_tenant_isolation.py` (lines 720–736):
```python
    # SLEA on-demand EAP environment routing & mesh manager (in-memory / tailscale)
    ("GET", "/api/v1/environments/"),
    ("GET", "/api/v1/environments/{environment_id}"),
    ("POST", "/api/v1/environments/provision"),
    ("POST", "/api/v1/environments/resolve-domain"),
    ("POST", "/api/v1/environments/{environment_id}/extend"),
    ("POST", "/api/v1/environments/{environment_id}/teardown"),
    # SLTE webhook triggers (stateless signature verifier / event pipeline)
    ("POST", "/api/v1/webhooks/generic"),
    ("POST", "/api/v1/webhooks/github"),
    # SLET EAP tenant isolation & cryptographic identity engine (K8s/OpenBao/SPIRE)
    ("GET", "/api/v1/eap/tenants"),
    ("POST", "/api/v1/eap/tenants"),
    ("GET", "/api/v1/eap/tenants/{customer_hash}"),
    ("DELETE", "/api/v1/eap/tenants/{customer_hash}"),
    ("GET", "/api/v1/eap/tenants/{customer_hash}/manifests"),
    ("GET", "/api/v1/eap/tenants/{customer_hash}/spire-entry"),
    ("POST", "/api/v1/eap/tenants/{customer_hash}/transit/encrypt"),
    ("POST", "/api/v1/eap/tenants/{customer_hash}/transit/decrypt"),
```
*Note for P2-1:* These 16 exemptions existed so `test_the_route_sweep_covers_every_authenticated_api_route` would pass without the routes being tenant-bound. In P2-1, every database-backed or tenant-scoped route will be bound to `authenticated_tenant`, and invalid exemptions will be removed.

### 5.2 Mutating Routes and Audit Provenance
From `tests/test_audit_provenance.py` (lines 718–840):
- `NOT_AUDIT_WORTHY` contains 14 EAP handler entries (covering `environment_lifecycle`, `environment_routing`, `tenant_isolation`, `webhook_triggers`).
- `AUDIT_DECISION_OWED` contains `api_tenant_encrypt` and `api_tenant_decrypt`.
- `scenario_seeding.py:api_execute_scenario (POST /execute)` is absent from both dictionaries, causing `test_every_mutating_route_makes_an_audit_decision` to fail.
- In P2-2, all mutating EAP routes will either emit structured audit events or declare signed audit decisions in `NOT_AUDIT_WORTHY`.

---

## 6. Auth Pattern Reference

The standard authentication pattern to be applied across all EAP router mount points in `main.py` is copied from the precedent in `api_compat.py:7167`:

```python
# Mounting with router-level dependency:
app.include_router(
    router,
    dependencies=[Depends(api_compat.authenticated_principal)]
)
```

### Handler Tenant Derivation
In individual handlers requiring tenant binding, tenant identity MUST be derived exclusively via `authenticated_tenant` (defined in `api_compat.py:1522`):
```python
def authenticated_tenant(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> str:
    """The caller's tenant derived from claims['sub'] mapped via settings.api_subject_tenants."""
    return principal.tenant
```

`authenticated_principal` (defined in `api_compat.py:1492`):
- Reads the `Authorization` header.
- Enforces `Bearer <token>` format.
- Validates JWT signature, expiration, audience, and issuer against JWKS.
- Rejects restricted scopes (`audit-upload-only`, `external-host`).
- Resolves `claims["sub"]` via `settings.api_subject_tenants` (`:1512`).
- Raises `APIError(401, "authentication_required", ...)` or `APIError(401, "invalid_token", ...)`.

### Configuration Site
Tenant mappings are injected via environment variable `API_SUBJECT_TENANTS` in `d2-signalloom/apps/fe-signalloom/base/deployment.yaml:85`:
```yaml
- name: API_SUBJECT_TENANTS
  value: '{"CglkZW1vLXVzZXISBWxvY2Fs":"tenant-demo","demo-user":"tenant-demo","CgZ2aWV3ZXISBWxvY2Fs":"tenant-demo","viewer":"tenant-demo"}'
```

---

## 7. Phase 2 Ownership Matrix

| Area / Scope | Owned By | Deliverables |
|--------------|----------|--------------|
| **Authentication & Tenant Binding** | **EAPR-P2-1** | Add `dependencies=[Depends(authenticated_principal)]` to EAP `include_router` mounts in `main.py`; strip untrusted incoming `X-SPIFFE-ID` headers; bind tenant handlers to `authenticated_tenant`; remove obsolete `NOT_DATABASE_BACKED` exemptions; convert `test_eap_anonymous_surface.py` probe to strict default-deny assertion. |
| **Audit Provenance & Decision Accounting** | **EAPR-P2-2** | Author structured audit event emission for mutating EAP operations; reconcile `NOT_AUDIT_WORTHY` and `AUDIT_DECISION_OWED` in `test_audit_provenance.py` so `test_every_mutating_route_makes_an_audit_decision` turns green. |
| **Workflow & CI Automation** | **EAPR-P2-3** | Implement GitHub Actions workflow (`signalloom-eap-pr`); run `make test-eap-offline` under CI; resolve and flip strict-xfail probes. |
| **Phase 2 Governance Certification** | **EAPR-P2-GOV** | Multi-agent council audit; verify all 35 operations are authenticated, audited, and green under `make test-eap-offline`. |
