# SLON-P1 — Technical Design & Runtime Architecture Specification

**Mission:** Signal Loom First User and Agent Onboarding (`SLON`)  
**Phase:** Phase 1 — First User Onboarding & Information Architecture  
**Status:** Certified Final  
**Integration Branch:** `refs/heads/integration/slon-v0.1.0`  

---

## 1. Architectural Architecture & Design Decisions

### 1.1. Zero-Mock Server-Side Persistence Invariant (SP-1)
Prior to Phase 1, portions of the onboarding status and wizard scratch state relied on client-side memory or fallback defaults when API communication degraded. Under Phase 1:
- `onboardingClient.ts` interfaces directly with FastAPI endpoints on `fe-signalloom`.
- All tenant state (`current_step`, `tenant_name`, `workspace_id`, `admin_email`, `environment`, `idp_type`, `idp_issuer_url`, `idp_client_id`, `idp_scopes`, `containment_profile`, `consent_given`) is stored in PostgreSQL table `tenant_onboarding_state` with unique `tenant_id` foreign keys and transactional JSONB payloads.
- State transitions (`pending` -> `in_progress` -> `completed` / `skipped`) are stored in `tenant_onboarding_status` with immutable audit timestamps (`completed_at`, `skipped_at`).
- Repeat calls to `/complete` or `/skip` are idempotent and preserve the original transition timestamp.

### 1.2. Information Architecture & Navigation Hierarchy (SP-2)
The left-hand sidebar navigation was reorganized from an ad-hoc listing into a strict 3-tier domain hierarchy:
1. **View (Telemetry & Observation):**
   - Overview (`/overview`)
   - Agents (`/agents`)
   - Topology (`/topology` / `/agent-trust-topology`)
   - Activity (`/activity` / `/supercred`)
   - FAIR Risk (`/fair-risk` / `/risk-exposure`)
2. **Control (Governance & Policy Enforcement):**
   - Policies (`/policies` / `/compliance-policy`)
   - Containment (`/containment` / `/collusion-access`)
   - Approvals (`/approvals` / `/who-authorized`)
   - Audit Trail (`/audit` / `/audit-trail`)
3. **Design (Configuration & Infrastructure Management):**
   - Workspaces (`/workspaces` / `/federated-services`)
   - Connectors (`/connectors` / `/dex-connectors`)
   - Fleet Config (`/fleet-config` / `/fleet-demo`)
   - Settings (`/settings`)
4. **Persistent Anchors:**
   - Onboarding Wizard (`/onboarding`)
   - Help & Support (`/help` / `/connector-help`)

### 1.3. First User Onboarding Wizard State Machine (SLON-P1-3)
The wizard provides an accessible, step-by-step experience:
- **Step 1 (Tenant & Workspace Identity):** Captures organization name, workspace slug, operator admin email, and governance tier. Validates required fields with accessible error banners (`ValidationErrorBanner`).
- **Step 2 (Identity Provider Linkage):** Supports Dex OIDC (in-cluster default), Okta, Entra ID, Google Cloud Identity, and AWS IAM Identity Center. Includes interactive connection test probe.
- **Step 3 (Containment Policy & Security Consent):** Enforces Zero-Trust policy consent checkboxes, Landlock sandbox profile selection, and configuration review summary.
- **Completion Celebration:** Summary review card confirming successful onboarding and routing operator to the overview dashboard.

---

## 2. API Interface Contract Specification

| Method | Path | Request Body | Response Body | Description |
| :--- | :--- | :--- | :--- | :--- |
| `GET` | `/api/onboarding/status` | `None` | `{"status": "pending"\|"in_progress"\|"completed"\|"skipped", "completed_at": ISO8601\|null, "skipped_at": ISO8601\|null}` | Authoritative status lookup |
| `GET` | `/api/onboarding/state` | `None` | `{"current_step": int, "state": dict}` | Retrieves saved wizard scratch state |
| `PUT` | `/api/onboarding/state` | `{"current_step": int, "state": dict}` | `{"status": "saved", "current_step": int}` | Saves wizard form state |
| `POST` | `/api/onboarding/complete` | `{"state": dict}` (optional) | `{"status": "completed", "completed_at": ISO8601}` | Marks onboarding as complete |
| `POST` | `/api/onboarding/skip` | `None` | `{"status": "skipped", "skipped_at": ISO8601}` | Skips onboarding wizard |

---

## 3. Database Schema & Migration Specification

### 3.1. `tenant_onboarding_status` Table
```sql
CREATE TABLE IF NOT EXISTS tenant_onboarding_status (
    tenant_id VARCHAR(64) PRIMARY KEY,
    status VARCHAR(32) NOT NULL DEFAULT 'pending',
    completed_at TIMESTAMPTZ,
    skipped_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### 3.2. `tenant_onboarding_state` Table
```sql
CREATE TABLE IF NOT EXISTS tenant_onboarding_state (
    tenant_id VARCHAR(64) PRIMARY KEY REFERENCES tenant_onboarding_status(tenant_id) ON DELETE CASCADE,
    current_step INTEGER NOT NULL DEFAULT 1,
    state_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

---

## 4. Verification & Quality Matrix

| Test Domain | Target Suite | Scope | Pass Rate |
| :--- | :--- | :--- | :--- |
| Frontend Components | Vitest (`bun test`) | 158 test files, 3,110 tests | 100% (3,110/3,110) |
| Backend Handlers | Pytest (`uv run pytest`) | 1,146 tests | 100% (1,146/1,146) |
| Onboarding Persistence | Pytest `test_onboarding.py` | 19 tests | 100% (19/19) |
| Sidebar Navigation | Vitest `Sidebar.test.tsx` | 84 tests | 100% (84/84) |
| Acceptance Specs | BATS `acceptance-spec-coverage.bats` | 7 guard tests | 100% (7/7) |
| Production Bundle | Vite (`bun run build`) | TypeScript & asset emission | Clean (4.77s) |
