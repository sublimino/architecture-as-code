# Signal Loom Audit Event Taxonomy and Provenance Specification

## 1. Architectural Overview

Signal Loom enforces fail-closed, attributable audit logging across all mutating REST API routes. Every mutating endpoint (HTTP POST, PUT, PATCH, DELETE) is statically verified under AST analysis by `tests/test_audit_provenance.py` and vocabulary constraints in `tests/test_audit_event_types.py`.

An audit event is a durable record of an action performed by the Signal Loom platform. It satisfies three strict invariants:
1. **Attributable Caller Identity**: The `actor` field is always derived from the authenticated caller's identity (`Principal.actor` resolving to `sub` or `email`) rather than client-composed payload text or hardcoded module constants.
2. **Deterministic Event Vocabulary**: The `event_type` field must belong to the database-level CHECK constraint defined in migration `045_eap_audit_event_types.sql`.
3. **Provable Taint Isolation**: Content that the client supplies in a request body cannot enter an audit row unless the server persists that value or explicitly records it as an accepted client claim.

---

## 2. Event Type Taxonomy (60 Event Types)

Database migration `045_eap_audit_event_types.sql` defines the comprehensive `audit_events_event_type_check` constraint encompassing core agent governance, onboarding, operational security, external agent registration, host enrollment, and EAP lifecycle management.

### 2.1 EAP Lifecycle & Governance Events (New in Migration 045)

| Event Type | Category | Action Recorded | Target Tenant Key |
|---|---|---|---|
| `eap_environment.registered` | Lifecycle | Operator-initiated durable environment registration | `customer_hash` |
| `eap_environment.lease_extended` | Lifecycle | Lease heartbeat extension deferring environment reaping | `customer_hash` |
| `eap_environment.reaping_triggered` | Lifecycle | Operator-triggered reconciliation and teardown reaping pass | `system` / Operator Tenant |
| `eap_environment.provisioned` | Routing / Registry | On-demand demo/UAT environment creation and DNS assignment | `customer_hash` |
| `eap_environment.ttl_extended` | Routing / Registry | Active environment lease extension up to maximum ceiling | `customer_hash` |
| `eap_environment.teardown_requested` | Routing / Registry | Environment teardown and de-provisioning initiation | `customer_hash` |
| `eap_environment.webhook_triggered` | Automation | HMAC-verified webhook-driven environment lifecycle dispatch | `customer_hash` |
| `eap_scenario.executed` | Scenario Seeding | Synthetic security/governance scenario execution | `customer_hash` |
| `eap_tenant.isolation_provisioned` | Tenant Isolation | Namespace, PSA, and SPIFFE/OpenBao boundary creation | `customer_hash` |
| `eap_tenant.isolation_torn_down` | Tenant Isolation | Namespace boundary removal and key/identity revocation | `customer_hash` |

### 2.2 Baseline Governance Vocabulary

- **Agent Management**: `agent.created`, `agent.claimed`, `agent.transitioned`, `agent.stunned`, `agent.credential_issued`, `agent.credential_revoked`
- **External Agents & Hosts**: `external_agent.registered`, `external_agent.claimed`, `external_agent.enrolled`, `external_agent.revoked`, `external_agent.status_updated`, `external_agent.token_issued`, `external_agent.claim_rejected`
- **Platform & Security**: `operator.created`, `operator.removed`, `operator.sign_in_succeeded`, `operator.sign_in_denied`, `api_key.created`, `api_key.rotated`, `compliance.scan_completed`, `compliance.reassess_requested`, `violation.acknowledged`, `consent.accepted`, `cookie.preferences_updated`, `tenant.frameworks_updated`, `tenant.preferences_updated`, `user.currency_updated`, `support.requested`, `nhi.enrolled`, `nhi.dismissed`
- **Demos & Onboarding**: `demo.phase_run`, `demo.reset_requested`, `demo.signalfusion.phase_run`, `demo.signalfusion.reset_requested`, `demo.distancelatency.phase_run`, `demo.distancelatency.reset_requested`, `demo.supercred.phase_run`, `demo.supercred.reset_requested`, `onboarding_completed`, `onboarding_skipped`

---

## 3. Surgical Route-Level Audit Rulings (13 Routes)

| ID | Module | Route & Verb | Decision | Event Type / Rationale |
|---|---|---|---|---|
| 1 | `environment_lifecycle.py` | `POST /api/v1/eap/lifecycle/register` | `AUDIT_WRITE` | `eap_environment.registered` |
| 2 | `environment_lifecycle.py` | `POST /api/v1/eap/lifecycle/environments/{customer_hash}/heartbeat` | `AUDIT_WRITE` | `eap_environment.lease_extended` (emitted on `extended=True`) |
| 3 | `environment_lifecycle.py` | `POST /api/v1/eap/lifecycle/environments/{customer_hash}/activity` | `NOT_AUDIT_WORTHY` | High-frequency traffic touch; resets idle timer without moving hard lease ceiling. |
| 4 | `environment_lifecycle.py` | `POST /api/v1/eap/lifecycle/reap-now` | `AUDIT_WRITE` | `eap_environment.reaping_triggered` |
| 5 | `environment_routing.py` | `POST /api/v1/environments/provision` | `AUDIT_WRITE` | `eap_environment.provisioned` |
| 6 | `environment_routing.py` | `POST /api/v1/environments/resolve-domain` | `NOT_AUDIT_WORTHY` | Pure lookup; POST with request body performing read-only DNS synthesis without state mutation. |
| 7 | `environment_routing.py` | `POST /api/v1/environments/{environment_id}/extend` | `AUDIT_WRITE` | `eap_environment.ttl_extended` |
| 8 | `environment_routing.py` | `POST /api/v1/environments/{environment_id}/teardown` | `AUDIT_WRITE` | `eap_environment.teardown_requested` |
| 9 | `scenario_seeding.py` | `POST /api/v1/eap/scenarios/execute` | `AUDIT_WRITE` | `eap_scenario.executed` |
| 10 | `tenant_isolation.py` | `POST /api/v1/eap/tenants` | `AUDIT_WRITE` | `eap_tenant.isolation_provisioned` |
| 11 | `tenant_isolation.py` | `DELETE /api/v1/eap/tenants/{customer_hash}` | `AUDIT_WRITE` | `eap_tenant.isolation_torn_down` |
| 12 | `webhook_triggers.py` | `POST /api/v1/webhooks/github` | `AUDIT_WRITE` | `eap_environment.webhook_triggered` |
| 13 | `webhook_triggers.py` | `POST /api/v1/webhooks/generic` | `AUDIT_WRITE` | `eap_environment.webhook_triggered` |

---

## 4. Attributed Caller Identity Resolution

Route handlers authenticate caller credentials and derive the `actor` parameter:
- **Authenticated Superadmins & Users**: `_admin: Annotated[Principal, Depends(require_superadmin)]` or `principal = resolve_eap_principal(authorization)` resolves the verified JWT bearer claims. `Principal.actor` returns the verified email or subject identifier.
- **HMAC Webhook Receivers**: When external triggers authenticate via cryptographic HMAC signatures (`X-Hub-Signature-256` or `X-SignalLoom-Signature`), the verified webhook integration identity is recorded (e.g. `webhook:github` or `webhook:generic`).
- **Internal System Daemons**: When an unauthenticated internal daemon or local test calls lifecycle routes, `resolve_eap_principal` provides an honest, attributed system fallback (`system:eap-daemon`).
