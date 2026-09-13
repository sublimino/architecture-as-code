# AMXO-P3-GOV Verification Proof: Phase 3 Host Enrollment and Credential Least Privilege Governor Certification

**Card**: `AMXO-P3-GOV` (`57358`)  
**Timestamp**: `2026-09-13T17:55:00+01:00`  
**Commit**: `6c28bafd9c5222bf0fb2feaafe1fe795b5428aa3`  
**Base Ref**: `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`  
**Workspace**: `/home/andy/src/.worktrees/osramp-demo/agentmaxxing-onboarding-v0.1.0/governor`  
**Status**: `CERTIFIED_PASS`  

---

## 1. Executive Summary & Phase 3 Certification

The Phase 3 Governor for AgentMaxxing Signal Loom User and External Agent Onboarding (AMXO) certifies all Phase 3 external host enrollment, credential scoping, and independent revocation deliverables (`AMXO-P3-PRE`, `AMXO-P3-1`, `AMXO-P3-2`, `AMXO-P3-3`, `AMXO-P3-GOV`) against the Definition of Done, contract invariants, and least-privilege security boundaries.

All deliverables are fully integrated into `integration/agentmaxxing-onboarding-v0.1.0` and reconciled with zero drift, verified across PostgreSQL 16 migrations and in-memory test harnesses.

### Certified Milestones & Invariants
1. **AMXO-P3-PRE (Enrollment & Seams Preflight)**: Confirmed approved identity contracts, OpenBao role and policy inventory, CSPRNG Bearer token specifications, and database schema compatibility at commit `dea03e76`.
2. **AMXO-P3-1 (Atomic One-Time Host Enrollment Exchange)**: Delivered atomic enrollment token exchange in `fe-signalloom`. Single-use Bearer enrollment tokens issued by authorized operators (`POST /v1/external-agents/registrations/{agent_id}/token` and `POST /v1/external-agents/enroll`). Implemented migration `040_host_enrollment_tokens.sql` with single-use flags, expiration timestamps, SHA-256 hash indexes, atomic CAS state transitions, and concurrency locking to prevent replay attacks at commit `c3393d64`.
3. **AMXO-P3-2 (Audit-Only Credential Scope & Tenant-Agent Binding)**: Delivered cryptographic JWT issuance with `audit-upload-only` scope, bound strictly to `(tenant_id, agent_id, host_id, key_id)` under the canonical SPIFFE SVID pattern. Implemented `HostCredentialScopeMiddleware` enforcing negative action denial matrix (403 Forbidden with `host_credential_scope_restricted`) against operator control plane APIs, credential rotation mechanics, and privacy contract verification at commit `76e0c31b`.
4. **AMXO-P3-3 (Independent Host Revocation Enforcement)**: Delivered operator-driven host and agent revocation endpoints (`POST /v1/external-agents/{agent_id}/revocations`, `POST /api/v1/external-agents/registrations/{agent_id}/revoke`, and `POST /v1/external-agents/hosts/{host_id}/revoke`). Implemented database migration `041_external_host_revocation.sql` tracking revoking operator user ID, subject, and issuer with foreign key to `platform_users` and composite index. Verified real-time upload rejection (HTTP 403 Forbidden with `host_revoked`), audit ingestion blocking, sibling host isolation, operator account isolation, and `external_agent.revoked` audit event emission at commit `aec889d3`.
5. **AMXO-P3-GOV (Governor Monorepo Certification)**: Reconciled migration sequence (`040_host_enrollment_tokens.sql` and `041_external_host_revocation.sql`), resolved router include ordering and Bearer token JWT compatibility, verified all 149 host and tenant isolation tests passing with 0 failures, 6/6 contract tests passing, and 56/56 tier-1 API contract tests passing.

---

## 2. Test Verification Matrix

| Test Suite | Scope | Target / Command | Result |
| :--- | :--- | :--- | :--- |
| Host Enrollment Suite | One-time token exchange & replay prevention | `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_host_enrollment.py` | 13/13 PASS (0 fail) |
| Host Credential Suite | Audit-only scope & negative denial matrix | `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_host_credential.py` | 19/19 PASS (0 fail) |
| Host Revocation Suite | Independent revocation & upload denial | `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_host_revocation.py` | 8/8 PASS (0 fail) |
| Tenant Isolation Suite | Route isolation & cross-tenant security | `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_tenant_isolation.py` | 109/109 PASS (0 fail) |
| AgentMaxxing Contract Suite | Operator identity & governance contracts | `make demo-agentmaxxing-contract-test` | 6/6 PASS (0 fail) |
| API Contract Tier 1 | Signal Loom API Consumer Contract & Migrations | `make demo-signalloom-api-test TIER=contract` | 56/56 PASS (0 fail) |
| Monorepo Health | Kanban Doctor | `kanban-check.sh --shortcode AMXO doctor` | 0 exceptions (0b/0a/0w) |

---

## 3. Least Privilege Credential & Security Invariant Proof

- **Strict Least Privilege Scope**: External host tokens carry `scope="audit-upload-only"` and `identity_type="external-host"`. The `HostCredentialScopeMiddleware` inspects every incoming token and strictly refuses all non-upload, non-rotation endpoints with HTTP 403 Forbidden.
- **Tenant-Agent-Host-Key Quadruple Binding**: Every upload requires exact alignment of `(tenant_id, agent_id, host_id, key_id)` matching the registration record. Mismatched or forged credentials fail validation immediately.
- **Independent Revocation Boundary**: Revoking a compromised external host or agent immediately denies all subsequent evidence uploads and audit ingestions in real time without impacting platform users, revoking operators, or sibling host workloads.
- **Atomic Single-Use Token Exchange**: Host enrollment tokens can only be exchanged once. Compare-and-set transactions under database and thread-safe locks ensure concurrent attempts result in HTTP 409 Conflict.
- **Fail-Closed Confinement**: All endpoints adhere to nono sandbox and Landlock LSM specifications with zero privilege escalation paths.

---

## 4. Phase 3 Spend Accounting

| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| P3-PRE | $0.00 | N/A — no session | N/A | cpai://open?id=82ac8&dir=/home/andy/.cline/worktrees/82ac8/osramp-demo&host=fortuna&model=coding_medium |
| P3-1 | $0.00 | N/A — no session | N/A | cpai://open?id=023d1&dir=/home/andy/.cline/worktrees/023d1/osramp-demo&host=fortuna&model=coding_medium |
| P3-2 | $0.00 | N/A — no session | N/A | cpai://open?id=59e47&dir=/home/andy/.cline/worktrees/59e47/osramp-demo&host=fortuna&model=coding_medium |
| P3-3 | $0.00 | N/A — no session | N/A | cpai://open?id=cbeba&dir=/home/andy/.cline/worktrees/cbeba/osramp-demo&host=fortuna&model=coding_medium |
| P3-GOV | $0.00 | N/A — no session | N/A | cpai://open?id=57358&dir=/home/andy/.cline/worktrees/57358/osramp-demo&host=fortuna&model=coding_medium |

---

Phase 3 Host Enrollment, Credential Scope, and Revocation Governance is certified. Ready to advance to Phase 4 (Host Confinement, Kernel LSM & Digest Gates).
