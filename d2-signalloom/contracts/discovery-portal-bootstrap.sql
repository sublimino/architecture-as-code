-- GENERATED FILE: do not edit.
-- Source: d2-signalloom/apps/fe-signalloom/src/db/migrations

-- BEGIN 001_discovery_tables.sql
-- Migration: 001_discovery_tables
--
-- Creates discovery_scan_sessions and discovered_agents tables.
-- Idempotent: CREATE TABLE IF NOT EXISTS + CREATE INDEX IF NOT EXISTS.

BEGIN;

CREATE TABLE IF NOT EXISTS public.discovery_scan_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR NOT NULL,
    email_domain VARCHAR NOT NULL,
    company_name VARCHAR NOT NULL,
    industry VARCHAR NOT NULL,
    platforms JSONB NOT NULL,
    status VARCHAR NOT NULL DEFAULT 'pending',
    agent_count INTEGER,
    governance_score INTEGER,
    ungoverned_count INTEGER,
    report_blob_url VARCHAR,
    hubspot_contact_id VARCHAR,
    error_message VARCHAR,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS public.discovered_agents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID REFERENCES discovery_scan_sessions(id) ON DELETE CASCADE,
    platform VARCHAR NOT NULL,
    external_id VARCHAR NOT NULL,
    name VARCHAR NOT NULL,
    model VARCHAR,
    tools_enabled JSONB,
    logging_enabled BOOLEAN DEFAULT FALSE,
    has_system_prompt BOOLEAN DEFAULT FALSE,
    creation_date TIMESTAMPTZ,
    governance_score INTEGER,
    compliance_gaps JSONB,
    risk_level VARCHAR,
    discovered_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_discovered_agents_session_id ON discovered_agents(session_id);
CREATE INDEX IF NOT EXISTS idx_discovery_scan_sessions_email_domain ON discovery_scan_sessions(email_domain);

COMMIT;
-- END 001_discovery_tables.sql

-- BEGIN 002_add_report_url_to_sessions.sql
-- 002_add_report_url_to_sessions.sql
ALTER TABLE IF EXISTS public.discovery_scan_sessions ADD COLUMN IF NOT EXISTS report_blob_url TEXT;
-- END 002_add_report_url_to_sessions.sql

-- BEGIN 003_platform_backends.sql
-- Migration: 003_platform_backends
-- Local-only platform connector records used by the deterministic demo adapters.

BEGIN;

CREATE TABLE IF NOT EXISTS public.platform_backends (
    identifier VARCHAR NOT NULL,
    tenant_id VARCHAR NOT NULL,
    display_name VARCHAR NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, identifier)
);

INSERT INTO public.platform_backends (identifier, tenant_id, display_name)
VALUES ('platform-demo', 'tenant-demo', 'Demo Platform')
ON CONFLICT (tenant_id, identifier) DO UPDATE
SET display_name = EXCLUDED.display_name;

COMMIT;
-- END 003_platform_backends.sql

-- BEGIN 004_agent_governance_schema.sql
-- Migration: 004_agent_governance_schema
-- Consolidated governance schema for the OSRAMP demo cluster.
-- Maps the original Signal Loom platform schema (migrations 001-044)
-- into standalone CREATE TABLE IF NOT EXISTS statements.
--
-- Demo simplifications vs. production:
--   - tenant_id is TEXT DEFAULT 'tenant-demo' (not UUID with RLS)
--   - No RLS policies (single-tenant demo)
--   - No GRANT/REVOKE (demo uses the connection user directly)
--   - set_updated_at() trigger function created here (prod has it in 001)
--
-- Idempotent: CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS,
--             CREATE OR REPLACE FUNCTION.
--
-- Tables created (13):
--   1.  agent_registry          — governed AI agents
--   2.  lifecycle_transitions   — agent state change audit trail
--   3.  agent_violations        — structured violation lifecycle
--   4.  governance_frameworks   — tenant-scoped framework catalog
--   5.  governance_controls     — controls within a framework
--   6.  agent_compliance_results — per-agent, per-control assessments
--   7.  audit_events            — typed governance event log
--   8.  tenant_settings         — org config, plan tier, consent
--   9.  tenant_api_keys         — hashed API keys with prefix hint
--  10.  nhi_scans               — NHI directory scan tracking
--  11.  nhi_discovered_accounts — service principals from AD/Entra
--  12.  consent_events          — immutable consent acceptance ledger
--  13.  support_requests        — help modal submissions

BEGIN;

-- ── Helper: updated_at trigger function ──────────────────────────────────────

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $body$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$body$;

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. agent_registry
-- ══════════════════════════════════════════════════════════════════════════════
-- Consolidated from platform migrations: 001 (base), 013 (governance cols),
-- 018 (lifecycle cols). Single CREATE TABLE with all columns.

CREATE TABLE IF NOT EXISTS public.agent_registry (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           TEXT        NOT NULL DEFAULT 'tenant-demo',
    name                TEXT        NOT NULL UNIQUE,
    display_name        TEXT        NOT NULL,
    description         TEXT,
    version             TEXT        NOT NULL DEFAULT '0.1.0',
    image_ref           TEXT,
    status              TEXT        NOT NULL DEFAULT 'inactive'
                                    CHECK (status IN (
                                        'active', 'inactive', 'deprecated',
                                        'suspended', 'quarantined', 'decommissioned', 'violation'
                                    )),
    capabilities        TEXT[]      NOT NULL DEFAULT '{}',
    config              JSONB       NOT NULL DEFAULT '{}',
    -- Identity and provenance (013)
    owner               TEXT,
    team                TEXT,
    origin              TEXT        CHECK (origin IS NULL
                                        OR origin IN ('Signal Loom Built', 'COTS', 'Custom')),
    foundry_built       BOOLEAN     NOT NULL DEFAULT false,
    -- Model columns (013)
    model_provider      TEXT,
    model_name          TEXT,
    model_approved      BOOLEAN,
    -- Governance columns (013)
    connectors          JSONB       NOT NULL DEFAULT '[]',
    policies_applied    JSONB       NOT NULL DEFAULT '[]',
    compliance_mappings JSONB       NOT NULL DEFAULT '{}',
    compliance_posture  INTEGER     CHECK (compliance_posture IS NULL
                                        OR compliance_posture BETWEEN 0 AND 100),
    violations          JSONB       NOT NULL DEFAULT '[]',
    last_heartbeat      TIMESTAMPTZ,
    -- Lifecycle columns (018)
    lifecycle_state     VARCHAR(20) NOT NULL DEFAULT 'enrolled'
                                    CHECK (lifecycle_state IN (
                                        'enrolled', 'active', 'suspended', 'revoked'
                                    )),
    last_transition_at  TIMESTAMPTZ,
    eu_ai_act_risk_class VARCHAR(20) CHECK (eu_ai_act_risk_class IS NULL
                                        OR eu_ai_act_risk_class IN (
                                            'high', 'limited', 'minimal', 'not_classified'
                                        )),
    -- Timestamps
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DO $body$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_agent_registry_updated_at') THEN
    CREATE TRIGGER trg_agent_registry_updated_at
      BEFORE UPDATE ON public.agent_registry
      FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
  END IF;
END $body$;

CREATE INDEX IF NOT EXISTS idx_agent_registry_tenant_id
    ON public.agent_registry (tenant_id);
CREATE INDEX IF NOT EXISTS idx_agent_registry_status
    ON public.agent_registry (tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_agent_registry_lifecycle
    ON public.agent_registry (tenant_id, lifecycle_state);

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. lifecycle_transitions
-- ══════════════════════════════════════════════════════════════════════════════
-- From platform migration 021.

CREATE TABLE IF NOT EXISTS public.lifecycle_transitions (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   TEXT        NOT NULL DEFAULT 'tenant-demo',
    agent_id    UUID        NOT NULL REFERENCES public.agent_registry(id),
    from_state  VARCHAR(20) NOT NULL,
    to_state    VARCHAR(20) NOT NULL,
    actor       VARCHAR(255) NOT NULL,
    reason      TEXT        NOT NULL,
    timestamp   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_lifecycle_agent
    ON public.lifecycle_transitions (tenant_id, agent_id, timestamp DESC);

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. agent_violations
-- ══════════════════════════════════════════════════════════════════════════════
-- From platform migration 019.

CREATE TABLE IF NOT EXISTS public.agent_violations (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           TEXT        NOT NULL DEFAULT 'tenant-demo',
    agent_id            UUID        REFERENCES public.agent_registry(id),
    violation_type      TEXT,
    severity            TEXT        CHECK (severity IS NULL
                                        OR severity IN ('critical', 'high', 'medium', 'low')),
    analysis            TEXT,
    recommended_action  TEXT,
    framework           TEXT,
    control             TEXT,
    status              VARCHAR(20) NOT NULL DEFAULT 'new'
                                    CHECK (status IN ('new', 'acknowledged', 'resolved')),
    acknowledged_by     VARCHAR(255),
    acknowledged_at     TIMESTAMPTZ,
    resolved_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DO $body$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_agent_violations_updated_at') THEN
    CREATE TRIGGER trg_agent_violations_updated_at
      BEFORE UPDATE ON public.agent_violations
      FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
  END IF;
END $body$;

CREATE INDEX IF NOT EXISTS idx_agent_violations_tenant
    ON public.agent_violations (tenant_id);
CREATE INDEX IF NOT EXISTS idx_agent_violations_agent
    ON public.agent_violations (tenant_id, agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_violations_status
    ON public.agent_violations (tenant_id, status);

-- ══════════════════════════════════════════════════════════════════════════════
-- 4. governance_frameworks
-- ══════════════════════════════════════════════════════════════════════════════
-- From platform migration 022.

CREATE TABLE IF NOT EXISTS public.governance_frameworks (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT        NOT NULL DEFAULT 'tenant-demo',
    name            VARCHAR(100) NOT NULL,
    version         VARCHAR(20),
    regulatory_body VARCHAR(100),
    compliance_deadline DATE,
    control_count   INTEGER     NOT NULL DEFAULT 0,
    activated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    activated_by    VARCHAR(255),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DO $body$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_governance_frameworks_updated_at') THEN
    CREATE TRIGGER trg_governance_frameworks_updated_at
      BEFORE UPDATE ON public.governance_frameworks
      FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
  END IF;
END $body$;

-- ══════════════════════════════════════════════════════════════════════════════
-- 5. governance_controls
-- ══════════════════════════════════════════════════════════════════════════════
-- From platform migration 022.

CREATE TABLE IF NOT EXISTS public.governance_controls (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT        NOT NULL DEFAULT 'tenant-demo',
    framework_id    UUID        NOT NULL REFERENCES public.governance_frameworks(id),
    name            VARCHAR(100) NOT NULL,
    description     TEXT,
    control_order   INTEGER     NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DO $body$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_governance_controls_updated_at') THEN
    CREATE TRIGGER trg_governance_controls_updated_at
      BEFORE UPDATE ON public.governance_controls
      FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
  END IF;
END $body$;

-- ══════════════════════════════════════════════════════════════════════════════
-- 6. agent_compliance_results
-- ══════════════════════════════════════════════════════════════════════════════
-- From platform migration 022.

CREATE TABLE IF NOT EXISTS public.agent_compliance_results (
    id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                   TEXT        NOT NULL DEFAULT 'tenant-demo',
    agent_id                    UUID        NOT NULL REFERENCES public.agent_registry(id),
    control_id                  UUID        NOT NULL REFERENCES public.governance_controls(id),
    status                      VARCHAR(30) NOT NULL
                                            CHECK (status IN ('pass', 'fail', 'pending',
                                                              'reassessment_requested')),
    assessed_at                 TIMESTAMPTZ,
    evidence_ref                VARCHAR(255),
    reassessment_requested_at   TIMESTAMPTZ,
    reassessment_requested_by   VARCHAR(255),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (agent_id, control_id)
);

DO $body$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_agent_compliance_results_updated_at') THEN
    CREATE TRIGGER trg_agent_compliance_results_updated_at
      BEFORE UPDATE ON public.agent_compliance_results
      FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
  END IF;
END $body$;

CREATE INDEX IF NOT EXISTS idx_compliance_results_agent
    ON public.agent_compliance_results (tenant_id, agent_id);

-- ══════════════════════════════════════════════════════════════════════════════
-- 7. audit_events
-- ══════════════════════════════════════════════════════════════════════════════
-- From platform migration 020.

CREATE TABLE IF NOT EXISTS public.audit_events (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   TEXT        NOT NULL DEFAULT 'tenant-demo',
    timestamp   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    event_type  VARCHAR(30) NOT NULL
                            CHECK (event_type IN (
                                'enrollment', 'state_transition', 'violation_detected',
                                'compliance_check', 'token_issued', 'token_refused',
                                'tenant_created', 'user_provisioned', 'directory_connected',
                                'discovery_enroll_requested'
                            )),
    agent_id    UUID        REFERENCES public.agent_registry(id),
    agent_name  VARCHAR(255),
    actor       VARCHAR(255) NOT NULL,
    detail      JSONB       NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_audit_events_tenant_timestamp
    ON public.audit_events (tenant_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_agent
    ON public.audit_events (tenant_id, agent_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_type
    ON public.audit_events (tenant_id, event_type, timestamp DESC);

-- ══════════════════════════════════════════════════════════════════════════════
-- 8. tenant_settings
-- ══════════════════════════════════════════════════════════════════════════════
-- Demo-only table consolidating tenant config that the platform spreads
-- across the tenants table + various ALTER TABLE additions (038, 039).

CREATE TABLE IF NOT EXISTS public.tenant_settings (
    id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                   TEXT        NOT NULL UNIQUE DEFAULT 'tenant-demo',
    org_name                    TEXT        NOT NULL DEFAULT 'Demo Organisation',
    plan_tier                   TEXT        NOT NULL DEFAULT 'enterprise'
                                            CHECK (plan_tier IN (
                                                'free', 'starter', 'professional', 'enterprise'
                                            )),
    status                      TEXT        NOT NULL DEFAULT 'active'
                                            CHECK (status IN (
                                                'provisioning', 'active', 'suspended',
                                                'deprovisioned', 'trial'
                                            )),
    selected_frameworks         JSONB       NOT NULL DEFAULT '["eu-ai-act"]',
    api_key_status              TEXT        NOT NULL DEFAULT 'active'
                                            CHECK (api_key_status IN (
                                                'active', 'revoked', 'not_generated'
                                            )),
    consent_accepted_at         TIMESTAMPTZ,
    consent_document_versions   JSONB,
    cookie_preferences          JSONB       DEFAULT '{"strictly_necessary": true, "analytics": false}',
    trial_expires_at            TIMESTAMPTZ,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DO $body$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_tenant_settings_updated_at') THEN
    CREATE TRIGGER trg_tenant_settings_updated_at
      BEFORE UPDATE ON public.tenant_settings
      FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
  END IF;
END $body$;

-- ══════════════════════════════════════════════════════════════════════════════
-- 9. tenant_api_keys
-- ══════════════════════════════════════════════════════════════════════════════
-- From platform migrations 036, 037.

CREATE TABLE IF NOT EXISTS public.tenant_api_keys (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           TEXT        NOT NULL DEFAULT 'tenant-demo',
    key_hash            TEXT        NOT NULL,
    prefix_hint         TEXT        NOT NULL,
    scope               TEXT        NOT NULL DEFAULT 'tenant_admin'
                                    CHECK (scope IN ('tenant_admin', 'read_only')),
    revealed_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revealed_by_email   TEXT        NOT NULL,
    revoked_at          TIMESTAMPTZ
);

-- One active key per tenant
CREATE UNIQUE INDEX IF NOT EXISTS uq_tenant_api_keys_active
    ON public.tenant_api_keys (tenant_id)
    WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_tenant_api_keys_hash
    ON public.tenant_api_keys (key_hash)
    WHERE revoked_at IS NULL;

-- ══════════════════════════════════════════════════════════════════════════════
-- 10. nhi_scans
-- ══════════════════════════════════════════════════════════════════════════════
-- From platform migration 023, 026.

CREATE TABLE IF NOT EXISTS public.nhi_scans (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               TEXT        NOT NULL DEFAULT 'tenant-demo',
    scan_source             VARCHAR(50) NOT NULL,
    started_at              TIMESTAMPTZ NOT NULL,
    completed_at            TIMESTAMPTZ,
    total_entries_scanned   INTEGER,
    service_accounts_found  INTEGER,
    total_at_risk           INTEGER,
    accounts_discovered     INTEGER,
    triggered_by            VARCHAR(255),
    status                  VARCHAR(20) NOT NULL
                                        CHECK (status IN ('running', 'completed', 'failed'))
);

-- ══════════════════════════════════════════════════════════════════════════════
-- 11. nhi_discovered_accounts
-- ══════════════════════════════════════════════════════════════════════════════
-- From platform migrations 023, 026, 042.

CREATE TABLE IF NOT EXISTS public.nhi_discovered_accounts (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               TEXT        NOT NULL DEFAULT 'tenant-demo',
    scan_id                 UUID        NOT NULL REFERENCES public.nhi_scans(id),
    account_name            VARCHAR(255) NOT NULL,
    directory_source        VARCHAR(50) NOT NULL,
    owner_email             VARCHAR(255),
    last_rotated            TIMESTAMPTZ,
    privilege_level         VARCHAR(30)
                                        CHECK (privilege_level IS NULL
                                            OR privilege_level IN (
                                                'standard', 'elevated',
                                                'domain_admin', 'enterprise_admin'
                                            )),
    findings                JSONB       NOT NULL DEFAULT '[]',
    status                  VARCHAR(20) NOT NULL DEFAULT 'discovered'
                                        CHECK (status IN (
                                            'discovered', 'under_review', 'enrolled',
                                            'dismissed', 'enrollment_requested'
                                        )),
    enrolled_agent_id       UUID        REFERENCES public.agent_registry(id),
    dismissed_at            TIMESTAMPTZ,
    dismissed_by            VARCHAR(255),
    dismiss_reason          TEXT,
    scan_count              INTEGER     NOT NULL DEFAULT 1,
    first_discovered_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at            TIMESTAMPTZ,
    changes_since_dismissal JSONB,
    previous_risk_flags     JSONB,
    -- Inventory columns (042)
    entra_object_id         VARCHAR(36),
    expires_at              TIMESTAMPTZ,
    rotation_status         VARCHAR(20)
                                        CHECK (rotation_status IS NULL
                                            OR rotation_status IN (
                                                'current', 'stale',
                                                'expiring_soon', 'expired'
                                            )),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DO $body$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_nhi_discovered_accounts_updated_at') THEN
    CREATE TRIGGER trg_nhi_discovered_accounts_updated_at
      BEFORE UPDATE ON public.nhi_discovered_accounts
      FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
  END IF;
END $body$;

CREATE INDEX IF NOT EXISTS idx_nhi_accounts_scan
    ON public.nhi_discovered_accounts (tenant_id, scan_id);
CREATE INDEX IF NOT EXISTS idx_nhi_accounts_status
    ON public.nhi_discovered_accounts (tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_nhi_accounts_match
    ON public.nhi_discovered_accounts (tenant_id, account_name, directory_source);
CREATE INDEX IF NOT EXISTS idx_nhi_accounts_expiry
    ON public.nhi_discovered_accounts (tenant_id, expires_at)
    WHERE expires_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_nhi_accounts_rotation_status
    ON public.nhi_discovered_accounts (tenant_id, rotation_status);

-- ══════════════════════════════════════════════════════════════════════════════
-- 12. consent_events
-- ══════════════════════════════════════════════════════════════════════════════
-- From platform migration 039.

CREATE TABLE IF NOT EXISTS public.consent_events (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               TEXT        NOT NULL DEFAULT 'tenant-demo',
    user_email              TEXT        NOT NULL,
    accepted_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    document_versions       JSONB       NOT NULL DEFAULT '{}'
                                        CHECK (jsonb_typeof(document_versions) = 'object'),
    cookie_preferences      JSONB       NOT NULL DEFAULT '{"strictly_necessary": true, "analytics": false}'
                                        CHECK (jsonb_typeof(cookie_preferences) = 'object'),
    b2b_warranty_accepted   BOOLEAN     NOT NULL DEFAULT TRUE,
    user_agent              TEXT,
    ip_address              INET
);

CREATE INDEX IF NOT EXISTS idx_consent_events_tenant_accepted
    ON public.consent_events (tenant_id, accepted_at DESC);

-- ══════════════════════════════════════════════════════════════════════════════
-- 13. support_requests
-- ══════════════════════════════════════════════════════════════════════════════
-- From platform migration 024.

CREATE TABLE IF NOT EXISTS public.support_requests (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT        NOT NULL DEFAULT 'tenant-demo',
    subject         VARCHAR(255) NOT NULL,
    urgency         VARCHAR(20) NOT NULL
                                CHECK (urgency IN ('low', 'normal', 'high', 'critical')),
    message         TEXT        NOT NULL,
    submitted_by    VARCHAR(255) NOT NULL,
    submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    clickup_task_id VARCHAR(50),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DO $body$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_support_requests_updated_at') THEN
    CREATE TRIGGER trg_support_requests_updated_at
      BEFORE UPDATE ON public.support_requests
      FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
  END IF;
END $body$;

COMMIT;
-- END 004_agent_governance_schema.sql

-- BEGIN 005_tenant_scan_preferences.sql
-- Migration: 005_tenant_scan_preferences
-- Adds the scan-preference columns the onboarding wizard's "Set your scan
-- preferences" step writes via PATCH /api/tenant/settings/preferences.
--
-- Defaults mirror the dashboard's DEFAULT_PREFERENCES
-- (dashboard-signalloom/src/pages/OnboardingWizard.tsx): 24-hour cadence,
-- no alert email, alert threshold of 1.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + guarded constraint creation.

BEGIN;

ALTER TABLE IF EXISTS public.tenant_settings
    ADD COLUMN IF NOT EXISTS preferred_scan_cadence_hours INTEGER NOT NULL DEFAULT 24;

ALTER TABLE IF EXISTS public.tenant_settings
    ADD COLUMN IF NOT EXISTS alert_email TEXT;

ALTER TABLE IF EXISTS public.tenant_settings
    ADD COLUMN IF NOT EXISTS alert_threshold INTEGER NOT NULL DEFAULT 1;

DO $body$ BEGIN
  IF to_regclass('public.tenant_settings') IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_settings_scan_cadence_positive'
  ) THEN
    ALTER TABLE public.tenant_settings
      ADD CONSTRAINT tenant_settings_scan_cadence_positive
      CHECK (preferred_scan_cadence_hours > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_settings_alert_threshold_positive'
  ) THEN
    ALTER TABLE public.tenant_settings
      ADD CONSTRAINT tenant_settings_alert_threshold_positive
      CHECK (alert_threshold > 0);
  END IF;
END $body$;

COMMIT;
-- END 005_tenant_scan_preferences.sql

-- BEGIN 006_onboarding.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 005 — onboarding state
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Backs GET/POST /api/onboarding/{status,skip,complete} and GET/PUT
-- /api/onboarding/state. Until this existed the dashboard ran its onboarding
-- client in MOCK_MODE, where "Skip for now" wrote a module-level variable that
-- died on reload — so the wizard could never be dismissed and every protected
-- route bounced back to /onboarding.
--
-- Shape: one row per tenant, holding a terminal status with its date plus the
-- wizard's resumable in-progress state.
--
-- Why a dedicated table rather than columns on tenant_settings (which already
-- carries consent_accepted_at, the closest precedent):
--
--   1. wizard_state churns on every step change. On tenant_settings each write
--      would fire trg_tenant_settings_updated_at and bump the updated_at of a
--      row that holds stable org configuration.
--   2. tenant_settings is 1:1 with tenant by UNIQUE constraint. If onboarding
--      later needs to be per-user, this table takes a user_email column and a
--      composite unique; tenant_settings could not without a redesign.
--   3. The onboarding state machine is legible in one place instead of being
--      inferred from three nullable columns on a grab-bag row.
--
-- History is NOT kept here. Completion and skip both append to audit_events, so
-- "skipped in March, completed in June" is answerable without this table
-- carrying an event log it would otherwise duplicate.
--
-- Multi-tenancy note: tenant_id is NOT NULL with NO DEFAULT, deliberately
-- diverging from the `DEFAULT 'tenant-demo'` used by the 004 tables. A default
-- means an INSERT that forgets the tenant silently lands in the demo tenant
-- instead of failing; on a shared-schema multi-tenant database that is a
-- cross-tenant write, not a convenience. The FK to tenant_settings gives this
-- table the referential integrity and tenant-deletion semantics the rest of the
-- schema currently lacks.

CREATE TABLE IF NOT EXISTS public.tenant_onboarding (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT        NOT NULL UNIQUE
                                REFERENCES public.tenant_settings(tenant_id)
                                ON DELETE CASCADE,
    status          TEXT        NOT NULL DEFAULT 'pending'
                                CHECK (status IN ('pending', 'completed', 'skipped')),
    completed_at    TIMESTAMPTZ,
    skipped_at      TIMESTAMPTZ,
    wizard_state    JSONB       NOT NULL DEFAULT '{}'::jsonb
                                CHECK (jsonb_typeof(wizard_state) = 'object'),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- A terminal status must carry its date, and a date must not appear without
    -- the status that explains it. Without these the table can express
    -- "completed, but we don't know when", which is exactly the ambiguity the
    -- status column was added to remove.
    CONSTRAINT tenant_onboarding_completed_has_date
        CHECK (status <> 'completed' OR completed_at IS NOT NULL),
    CONSTRAINT tenant_onboarding_skipped_has_date
        CHECK (status <> 'skipped'   OR skipped_at   IS NOT NULL),
    CONSTRAINT tenant_onboarding_pending_has_no_date
        CHECK (status <> 'pending'   OR (completed_at IS NULL AND skipped_at IS NULL))
);

CREATE INDEX IF NOT EXISTS idx_tenant_onboarding_status
    ON public.tenant_onboarding (status);

DO $body$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_tenant_onboarding_updated_at') THEN
    CREATE TRIGGER trg_tenant_onboarding_updated_at
      BEFORE UPDATE ON public.tenant_onboarding
      FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
  END IF;
END $body$;

-- ──────────────────────────────────────────────────────────────────────────────
-- audit_events: admit the two onboarding transitions
-- ──────────────────────────────────────────────────────────────────────────────
-- audit_events.event_type is a CHECK constraint, not an enum, so widening it
-- means dropping and recreating the constraint. Done as a guarded block so the
-- migration stays idempotent and so a database that already has the wider
-- constraint is left alone.

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
   WHERE nsp.nspname = 'public'
     AND rel.relname = 'audit_events'
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
             JOIN pg_class rel ON rel.oid = con.conrelid
            WHERE rel.relname = 'audit_events' AND con.conname = constraint_name
         )) NOT LIKE '%onboarding_completed%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%onboarding_completed%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'enrollment', 'state_transition', 'violation_detected',
        'compliance_check', 'token_issued', 'token_refused',
        'tenant_created', 'user_provisioned', 'directory_connected',
        'discovery_enroll_requested',
        'onboarding_completed', 'onboarding_skipped'
      ));
  END IF;
END $body$;
-- END 006_onboarding.sql

-- BEGIN 007_audit_event_types.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 007 — admit the event types the application actually writes
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Every call site of _audit_log() in api_compat.py writes a dotted event type
-- ('agent.created', 'tenant.frameworks_updated', ...). The CHECK constraint on
-- audit_events.event_type allowed only an undotted vocabulary
-- ('enrollment', 'state_transition', ...) that no call site uses. The two sets
-- were completely disjoint, so EVERY audit insert raised
--
--     CheckViolationError: new row for relation "audit_events"
--     violates check constraint "audit_events_event_type_check"
--
-- The mutation and its audit insert are separate autocommit statements, so the
-- business write landed and the request then returned 500. Symptoms included
-- PATCH /api/tenant/settings/preferences and PATCH /api/tenant/settings/frameworks
-- both failing while persisting their changes. audit_events held zero rows on a
-- cluster that had been running for days: the audit trail had never recorded a
-- single event.
--
-- 004 created the constraint and 006 widened it by two values, but both used the
-- undotted vocabulary, so neither closed the gap.
--
-- The dotted form is the application's convention — all thirteen call sites use
-- it — so the constraint moves to the code rather than the code to the
-- constraint. The undotted values are retained: they cost nothing, other
-- environments may hold rows that use them, and 006 is still expected to be
-- idempotent against a database that has already seen it.
--
-- tests/test_audit_event_types.py parses every event_type literal out of
-- api_compat.py and fails if one is absent here, so the two cannot drift again.
--
-- Same guarded-DO-block shape as 006: event_type is a CHECK constraint rather
-- than an enum, so widening means dropping and recreating, and the guard keys on
-- a value unique to this migration so re-running is a no-op.

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
   WHERE nsp.nspname = 'public'
     AND rel.relname = 'audit_events'
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  -- Already widened by this migration? Leave it alone.
  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
             JOIN pg_class rel ON rel.oid = con.conrelid
            WHERE rel.relname = 'audit_events' AND con.conname = constraint_name
         )) NOT LIKE '%tenant.preferences_updated%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%tenant.preferences_updated%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        -- Written by _audit_log() in api_compat.py. Keep in step with
        -- tests/test_audit_event_types.py, which derives its expectations from
        -- the source rather than from this list.
        'agent.created',
        'agent.credential_issued',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'nhi.dismissed',
        'nhi.enrolled',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'violation.acknowledged',
        -- Retained from 004 and 006. No call site emits these, but dropping
        -- them would break any environment holding rows that use them.
        'enrollment',
        'state_transition',
        'violation_detected',
        'compliance_check',
        'token_issued',
        'token_refused',
        'tenant_created',
        'user_provisioned',
        'directory_connected',
        'discovery_enroll_requested',
        'onboarding_completed',
        'onboarding_skipped'
      ));
  END IF;
END $body$;
-- END 007_audit_event_types.sql

-- BEGIN 008_platform_users.sql
-- Migration: 008_platform_users
-- Adds platform user management tables and links agent ownership.
--
-- Tables created (2):
--   1. platform_users  — tenant-scoped user directory
--   2. user_roles      — future RBAC expansion (roles × scopes)
--
-- Columns added (1):
--   agent_registry.owner_id — FK to platform_users for ownership reconciliation
--
-- Design notes:
--   - "platform_users" avoids collision with pg_catalog.pg_user
--   - role column uses a simple CHECK constraint (admin/editor/viewer)
--   - user_roles table is schema-only foundation for row-level access;
--     no RLS policies are created here (single-tenant demo)
--   - agent_registry.owner (TEXT) is preserved for display; owner_id is
--     the relational link for permission checks
--   - Library-agnostic: works with PostgreSQL RLS, CASL, Casbin, or Cerbos

BEGIN;

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. platform_users
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.platform_users (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT        NOT NULL DEFAULT 'tenant-demo',
    email           TEXT        NOT NULL,
    display_name    TEXT        NOT NULL,
    role            TEXT        NOT NULL DEFAULT 'viewer'
                                CHECK (role IN ('admin', 'editor', 'viewer')),
    status          TEXT        NOT NULL DEFAULT 'active'
                                CHECK (status IN ('active', 'invited', 'suspended', 'deactivated')),
    avatar_url      TEXT,
    department      TEXT,
    title           TEXT,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_platform_users_tenant_email UNIQUE (tenant_id, email)
);

CREATE INDEX IF NOT EXISTS idx_platform_users_tenant
    ON public.platform_users (tenant_id);

CREATE INDEX IF NOT EXISTS idx_platform_users_email
    ON public.platform_users (email);

DROP TRIGGER IF EXISTS set_platform_users_updated_at ON public.platform_users;
CREATE TRIGGER set_platform_users_updated_at
    BEFORE UPDATE ON public.platform_users
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. user_roles (RBAC foundation — not enforced in demo)
-- ══════════════════════════════════════════════════════════════════════════════
-- Designed for future row-level access control:
--   scope = 'tenant' → tenant-wide role
--   scope = 'team'   → team-scoped role (scope_id = team name)
--   scope = 'agent'  → per-agent permission (scope_id = agent UUID)
--
-- No RLS policies reference this table yet. When enforcement lands:
--   SET app.current_user_id = '<uuid>';
--   RLS policy: WHERE agent_registry.owner_id = current_setting('app.current_user_id')::uuid
--               OR EXISTS (SELECT 1 FROM user_roles WHERE ...)

CREATE TABLE IF NOT EXISTS public.user_roles (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES public.platform_users(id) ON DELETE CASCADE,
    tenant_id   TEXT        NOT NULL DEFAULT 'tenant-demo',
    role        TEXT        NOT NULL CHECK (role IN ('admin', 'editor', 'viewer')),
    scope       TEXT        NOT NULL DEFAULT 'tenant'
                            CHECK (scope IN ('tenant', 'team', 'agent')),
    scope_id    TEXT,
    granted_by  UUID        REFERENCES public.platform_users(id),
    granted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_user_roles_assignment UNIQUE (user_id, tenant_id, role, scope, scope_id)
);

CREATE INDEX IF NOT EXISTS idx_user_roles_user
    ON public.user_roles (user_id);

CREATE INDEX IF NOT EXISTS idx_user_roles_scope
    ON public.user_roles (tenant_id, scope, scope_id);

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. Add owner_id FK to agent_registry
-- ══════════════════════════════════════════════════════════════════════════════

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'agent_registry'
          AND column_name = 'owner_id'
    ) THEN
        ALTER TABLE public.agent_registry
            ADD COLUMN owner_id UUID REFERENCES public.platform_users(id);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_agent_registry_owner_id
    ON public.agent_registry (owner_id);

COMMIT;
-- END 008_platform_users.sql

-- BEGIN 009_agent_lifecycle_states.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 009 — admit the lifecycle states the application actually writes
-- ══════════════════════════════════════════════════════════════════════════════
--
-- agent_registry.lifecycle_state carried a CHECK constraint permitting only
--
--     enrolled | active | suspended | revoked
--
-- while api_compat.py writes 'registered' on every create (POST /api/agents
-- hardcodes it in the INSERT and _make_agent uses it for the fixture path), and
-- POST /api/agents/{id}/transition writes whatever to_state the caller sends.
-- So creating an agent against a real database raised
--
--     CheckViolationError: new row for relation "agent_registry"
--     violates check constraint "agent_registry_lifecycle_state_check"
--
-- and every lifecycle transition out of the four permitted states did the same.
-- Neither was visible until the tier-2 integration suite first ran: the tier-1
-- fixture store is a dict, and a dict enforces no constraints.
--
-- Same reasoning as 007, which widened audit_events.event_type: where the
-- schema's vocabulary and the application's have drifted, the application is
-- the product surface and the constraint moves to the code. The added values
-- are not invented — 'registered' is what the create path writes, and
-- 'decommissioned' is already in agent_registry.status's own CHECK, so the two
-- columns on the same table disagreed about whether the state exists.
--
-- The four original values are retained: deployed databases hold rows using
-- them, and data-mock.sql seeds 'enrolled' and 'active'.
--
-- NOTE: TransitionRequest.to_state is a bare `str` with no validation, so an
-- unrecognised state still reaches this constraint and surfaces as a 500 rather
-- than a 400. Widening the constraint does not fix that; constraining to_state
-- to this vocabulary in the request model is the fix, and is deliberately left
-- out of this change.
--
-- Guarded DO block in the shape 006 and 007 use: a CHECK constraint is not an
-- enum, so widening means drop-and-recreate, and the guard keys on a value
-- unique to this migration so re-running is a no-op.

BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
   WHERE nsp.nspname = 'public'
     AND rel.relname = 'agent_registry'
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%lifecycle_state%'
   LIMIT 1;

  -- Already widened by this migration? Leave it alone.
  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
             JOIN pg_class rel ON rel.oid = con.conrelid
            WHERE rel.relname = 'agent_registry' AND con.conname = constraint_name
         )) NOT LIKE '%registered%'
  THEN
    EXECUTE format('ALTER TABLE public.agent_registry DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'agent_registry'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%registered%'
  ) THEN
    ALTER TABLE public.agent_registry
      ADD CONSTRAINT agent_registry_lifecycle_state_check
      CHECK (lifecycle_state IN (
        -- Original vocabulary from 004.
        'enrolled',
        'active',
        'suspended',
        'revoked',
        -- Written by POST /api/agents and _make_agent().
        'registered',
        -- Already permitted by agent_registry.status; the end of the lifecycle.
        'decommissioned'
      ));
  END IF;
END $body$;

COMMIT;
-- END 009_agent_lifecycle_states.sql

-- BEGIN 010_agent_credentials.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 010 — persist agent credentials so revoke is real rather than theatrical
-- ══════════════════════════════════════════════════════════════════════════════
--
-- The dashboard already ships a Revoke Credential button, and the frontend now
-- calls POST /api/agents/{id}/credentials/revoke. The backend had no such
-- route, so the button 404'd outright. Worse, POST /api/agents/{id}/credentials
-- minted a demo token, wrote only an audit row, and persisted nothing about the
-- credential itself. Any later revoke count would therefore have been made up.
--
-- This migration fixes both halves of that defect:
--
--   1. add public.agent_credentials so issue can persist a revocable row and
--      revoke can count only what it actually changed, and
--   2. widen audit_events.event_type so the new
--      'agent.credential_revoked' audit row does not fail its CHECK and roll
--      the whole revoke back.
--
-- Only the token SHA-256 is stored. The dashboard never keeps a credential id
-- and the token is show-once, so revoke is intentionally all-or-nothing per
-- agent: revoke every active credential for that tenant+agent pair, without
-- retaining a plaintext secret the system never needs again.

BEGIN;

CREATE TABLE IF NOT EXISTS public.agent_credentials (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id TEXT NOT NULL,
  agent_id UUID NOT NULL REFERENCES public.agent_registry(id) ON DELETE CASCADE,
  token_sha256 TEXT NOT NULL,
  issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  revoked_by TEXT
);

CREATE INDEX IF NOT EXISTS idx_agent_credentials_active
  ON public.agent_credentials (tenant_id, agent_id)
  WHERE revoked_at IS NULL;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
   WHERE nsp.nspname = 'public'
     AND rel.relname = 'audit_events'
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  -- Already widened for revocation? Leave it alone.
  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
             JOIN pg_class rel ON rel.oid = con.conrelid
            WHERE rel.relname = 'audit_events' AND con.conname = constraint_name
         )) NOT LIKE '%agent.credential_revoked%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%agent.credential_revoked%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        -- Written by _audit_log() in api_compat.py. Keep in step with
        -- tests/test_audit_event_types.py, which derives its expectations from
        -- the source rather than from this list.
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'nhi.dismissed',
        'nhi.enrolled',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'violation.acknowledged',
        -- Retained legacy values from 004, 006, and 007.
        'enrollment',
        'state_transition',
        'violation_detected',
        'compliance_check',
        'token_issued',
        'token_refused',
        'tenant_created',
        'user_provisioned',
        'directory_connected',
        'discovery_enroll_requested',
        'onboarding_completed',
        'onboarding_skipped'
      ));
  END IF;
END $body$;

COMMIT;
-- END 010_agent_credentials.sql

-- BEGIN 011_agent_stunned_event_type.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 010 — admit 'agent.stunned'
-- ══════════════════════════════════════════════════════════════════════════════
--
-- POST /api/agents/{id}/stun records the operator isolating a non-compliant
-- agent. The SuperCred proxy performs the cluster-side action (relabel the pod,
-- revoke the OpenBao lease) and holds no database; without this endpoint the
-- most consequential action in the demo left no durable record at all — the
-- agent changed state and the Audit Trail showed nothing.
--
-- 007 moved the constraint to the code's dotted vocabulary and
-- tests/test_audit_event_types.py derives its expectations from the AST of
-- api_compat.py, so adding the call site without widening the constraint fails
-- that test rather than 500ing at runtime. This is that widening.
--
-- 'agent.stunned' is 13 characters; audit_events.event_type is VARCHAR(30).
--
-- Same guarded drop-and-recreate shape as 006, 007 and 009: event_type is a
-- CHECK constraint rather than an enum, so widening means recreating it, and
-- the guard keys on a value unique to this migration so re-running is a no-op.
--
-- CONSTRAINT_MIGRATION in tests/test_audit_event_types.py now points here.

BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
   WHERE nsp.nspname = 'public'
     AND rel.relname = 'audit_events'
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  -- Already widened by this migration? Leave it alone.
  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
             JOIN pg_class rel ON rel.oid = con.conrelid
            WHERE rel.relname = 'audit_events' AND con.conname = constraint_name
         )) NOT LIKE '%agent.stunned%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%agent.stunned%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        -- Written by _audit_log() in api_compat.py. Keep in step with
        -- tests/test_audit_event_types.py, which derives its expectations from
        -- the source rather than from this list.
        'agent.created',
        'agent.credential_issued',
        -- Merge union, added when this migration was renumbered 010 to 011.
        -- 010_agent_credentials.sql and this file were authored in parallel and
        -- BOTH drop-and-recreate audit_events_event_type_check, each enumerating
        -- a full vocabulary that omitted the other new type. Renumbering alone
        -- does not resolve that: whichever runs LAST wins outright, so ordering
        -- 010 then 011 without the next line would recreate the constraint
        -- lacking the credential-revoked type, and every revoke would raise
        -- CheckViolationError, rolling back the mutation it shares a
        -- transaction with and returning 500. The failure is invisible until
        -- someone presses the button: migration and API startup both succeed.
        -- The last migration to run must therefore carry the union of both.
        -- NB: no quote characters in this comment. test_audit_event_types.py
        -- parses quoted literals out of this file, so a quoted event name in
        -- prose is captured as if it were part of the vocabulary.
        'agent.credential_revoked',
        'agent.stunned',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'nhi.dismissed',
        'nhi.enrolled',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'violation.acknowledged',
        -- Retained from 004, 006 and 007. No call site emits these, but
        -- dropping them would break any environment holding rows that use them.
        'enrollment',
        'state_transition',
        'violation_detected',
        'compliance_check',
        'token_issued',
        'token_refused',
        'tenant_created',
        'user_provisioned',
        'directory_connected',
        'discovery_enroll_requested',
        'onboarding_completed',
        'onboarding_skipped'
      ));
  END IF;
END $body$;

COMMIT;
-- END 011_agent_stunned_event_type.sql

-- BEGIN 012_operational_event_types.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 012 — admit the operational event types
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Four actions that change state, or the cluster, and left no durable record:
--
--   demo.reset_requested       POST /api/demo/reset — the most destructive
--                              control in the product. It preempts and cancels
--                              whatever privileged phase is running, then runs
--                              the teardown. Its only history lived in a
--                              per-process dict that dies with the pod, while
--                              GET /api/demo/status describes that dict as the
--                              run history of a cluster-mutating control plane:
--                              which privileged phase was driven, by whom, when.
--                              That is a description of an audit trail kept in
--                              memory.
--
--   demo.phase_run             POST /api/demo/runs — a superadmin driving a
--                              privileged phase against the cluster. Recorded
--                              from what the runner observed (which step, which
--                              principal, exit status), never from what a
--                              browser asserted afterwards.
--
--   compliance.scan_completed  POST /api/compliance/policy/scan — refreshes
--                              agent_compliance_results. A compliance verdict
--                              changing with nothing recording that it did is
--                              the gap this product exists to close.
--
--   support.requested          POST /api/support — persists a request carrying
--                              the caller identity from their token. The row is
--                              evidence; that it was created was not.
--
-- Lengths against the VARCHAR(30) ceiling, longest first:
--   compliance.scan_completed  25
--   demo.reset_requested       20
--   support.requested          17
--   demo.phase_run             14
--
-- Same guarded drop-and-recreate shape as 006, 007, 009, 010 and 011:
-- event_type is a CHECK constraint rather than an enum, so widening means
-- recreating it, and the guard keys on a value unique to this migration so
-- re-running is a no-op.
--
-- This file enumerates EVERY permitted type, not just the new ones. 011 records
-- why in detail: whichever migration runs LAST wins outright, so a partial list
-- here would silently drop the eleven types 011 admitted and every one of those
-- writes would begin raising CheckViolationError — rolling back the mutation it
-- shares a transaction with and returning 500, invisibly, until someone presses
-- the button.
--
-- CONSTRAINT_MIGRATION in tests/test_audit_event_types.py now points here.
--
-- NB: no quote characters in these comments. test_audit_event_types.py parses
-- quoted literals out of this file, so a quoted event name in prose would be
-- captured as if it were part of the vocabulary.

BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
   WHERE nsp.nspname = 'public'
     AND rel.relname = 'audit_events'
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  -- Already widened by this migration? Leave it alone.
  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
             JOIN pg_class rel ON rel.oid = con.conrelid
            WHERE rel.relname = 'audit_events' AND con.conname = constraint_name
         )) NOT LIKE '%demo.reset_requested%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%demo.reset_requested%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        -- Written by _audit_log(). Keep in step with
        -- tests/test_audit_event_types.py, which derives its expectations from
        -- the source rather than from this list — and which now reads every
        -- module that calls _audit_log, not only api_compat.py.
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stunned',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'nhi.dismissed',
        'nhi.enrolled',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'violation.acknowledged',
        -- New in this migration.
        'compliance.scan_completed',
        'demo.phase_run',
        'demo.reset_requested',
        'support.requested',
        -- Live undotted vocabulary. 011 described the whole undotted block as
        -- emitted by no call site; that was true of the rest of it but not of
        -- these two, which onboarding.py has written since 006 and which have
        -- rows in the deployed database. The guard could not see them because
        -- it read only api_compat.py.
        'onboarding_completed',
        'onboarding_skipped',
        -- Retained from 004, 006 and 007. No call site emits these, but
        -- dropping them would break any environment holding rows that use them.
        'enrollment',
        'state_transition',
        'violation_detected',
        'compliance_check',
        'token_issued',
        'token_refused',
        'tenant_created',
        'user_provisioned',
        'directory_connected',
        'discovery_enroll_requested'
      ));
  END IF;
END $body$;

COMMIT;
-- END 012_operational_event_types.sql

-- BEGIN 020_user_preferences.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 020 — per-user preferences, and the first of them: display currency
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Every risk figure in the product is GBP at source and shown in the user's
-- chosen currency, defaulting to USD. That makes the preference part of what a
-- number on screen MEANS, so it has to be stored, not inferred.
--
-- ── Why a table, and not a column on platform_users ─────────────────────────
--
-- This is the FIRST per-user setting SignalLoom has ever had. platform_users
-- holds role, status, department and title — directory identity, nothing a user
-- chooses — and there is no existing preference storage to extend. So this
-- migration is not following a precedent, it is setting one, and it is written
-- for the settings that come after it rather than for this one alone.
--
-- A column on platform_users is cheaper today. It was the first design, and it
-- was reversed for three reasons:
--
--   1. The cheap-today argument was weaker than it looked. The case FOR a
--      column was that `NOT NULL DEFAULT 'USD'` makes the default a matter of
--      DDL, with no application fallback to forget. That turns out not to hold
--      here: a caller authenticated against this tenant may legitimately have
--      NO platform_users row at all — the directory is populated separately —
--      so the handler needs an application-level default for the missing-row
--      case regardless. Having paid that cost either way, the column buys much
--      less than it appeared to.
--
--   2. Cohesion. platform_users is the user DIRECTORY. Display preferences are
--      not directory data, and a column per preference grows a wide table that
--      mixes who someone is with how they like their screen. There are already
--      three browser-local per-user preferences in the dashboard (theme,
--      sidebar collapsed, load times) that will each want a home here, so
--      "the next one" is not hypothetical.
--
--   3. There is an exact structural precedent, and it is not platform_users.
--      tenant_settings (004) is a typed, scoped settings table for the TENANT.
--      This is its per-user twin: same shape, same idea, different scope.
--
-- Note what this is NOT: a generic key/value EAV table. Columns are typed and
-- constrained, so display_currency can carry a CHECK — which a TEXT `value`
-- column shared by every setting could never do. Each new preference is a
-- column here, which is a migration, which is the point: a preference worth
-- storing is worth declaring.
--
-- ── Keyed on the token identity, not on directory membership ────────────────
--
-- (tenant_id, user_email) rather than a foreign key to platform_users(id).
-- A user who can authenticate can hold a preference, whether or not anyone has
-- added them to the directory. An FK would make "your setting did not save
-- because you are absent from a table you have never heard of" a real
-- behaviour, and it is not a defensible one.
--
-- user_email holds Principal.actor — the email claim when Dex issues one, the
-- subject when it does not. Same convention as tenant_api_keys.revealed_by_email.
--
-- ── Scope ───────────────────────────────────────────────────────────────────
--
-- PER-USER, deliberately. Two people looking at the same fleet can want
-- different display currencies, and one of them changing it must not move the
-- other's board pack. The failure mode is not hypothetical: patch_cookie_
-- preferences currently stores a per-user cookie choice tenant-scoped, so one
-- user's preference silently overwrites everyone else's. That is what happens
-- when a user-scoped setting is bolted onto tenant-scoped storage, and this
-- table exists so the next one does not have to be.
--
-- 'USD' must agree with DEFAULT_DISPLAY_CURRENCY in api_compat.py,
-- DEFAULT_CURRENCY in dashboard-signalloom/src/money/currency.ts, and the demo
-- fixture in dashboard-signalloom/src/api/fakeData.ts. If one moves they all
-- move, or a user sees one currency while the audit trail records another.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS + guarded trigger creation, the same
-- shape as 008.

BEGIN;

CREATE TABLE IF NOT EXISTS public.user_preferences (
    id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         TEXT        NOT NULL DEFAULT 'tenant-demo',
    -- Principal.actor: the email claim, or the subject when the token carries
    -- no email. Named for the common case, like revealed_by_email.
    user_email        TEXT        NOT NULL,

    -- ISO 4217 alphabetic codes are exactly three uppercase letters. The
    -- constraint is on the SHAPE rather than an enumeration of codes: which
    -- currencies the UI offers is a frontend concern, and a migration to add
    -- CHF to a database list would be ceremony. What must never land is a
    -- lowercase code, an empty string, or a stray symbol — Intl does not
    -- reject unknown currency codes, it RENDERS them, so a bad value that
    -- reaches storage reaches the screen looking like real money.
    display_currency  VARCHAR(3)  NOT NULL DEFAULT 'USD'
                                  CHECK (display_currency ~ '^[A-Z]{3}$'),

    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_user_preferences_tenant_email UNIQUE (tenant_id, user_email)
);

CREATE INDEX IF NOT EXISTS idx_user_preferences_tenant
    ON public.user_preferences (tenant_id);

DROP TRIGGER IF EXISTS set_user_preferences_updated_at ON public.user_preferences;
CREATE TRIGGER set_user_preferences_updated_at
    BEFORE UPDATE ON public.user_preferences
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMIT;
-- END 020_user_preferences.sql

-- BEGIN 021_user_currency_event_type.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 021 — admit 'user.currency_updated'
-- ══════════════════════════════════════════════════════════════════════════════
--
-- PATCH /api/user/preferences records a user changing the currency every risk
-- figure on every screen is displayed in. A settings change a regulated
-- customer cannot see the history of is a gap, and this one changes what the
-- numbers in a board pack read as.
--
-- The detail carries {from, to, email} so the trail answers who changed it and
-- what it used to be, without a join against a table that only ever holds the
-- current value.
--
-- 'user.currency_updated' is 21 characters; audit_events.event_type is
-- VARCHAR(30).
--
-- ── The union, and why this file is dangerous ───────────────────────────────
--
-- event_type is a CHECK constraint rather than an enum, so widening it means
-- DROPPING AND RECREATING it with the ENTIRE vocabulary enumerated. The last
-- such migration to run wins outright: any type it omits is rejected from then
-- on, and because the audit insert shares a transaction with the mutation it
-- records, the rejection rolls back the business write and returns 500. Nothing
-- fails at migration time or at API startup — it fails the first time a user
-- presses the button.
--
-- 011 carries a long comment about exactly this: 010 and 011 were authored in
-- parallel, each enumerating a vocabulary that omitted the other's new type,
-- and renumbering alone did not fix it because ordering does not merge lists.
--
-- This file was written under the same conditions. Migrations 012-019 are
-- reserved for concurrent audit-coverage work that this author could not read.
-- If any of them adds an event type, IT MUST BE ADDED TO THE LIST BELOW — this
-- file runs last and its list is the one that survives. The reviewer merging
-- these branches owns that check; the test named below is what catches it.
--
-- Rather than leave that to the merge, the four types that work introduces were
-- obtained from the team lead and frozen: they are enumerated below under their
-- own heading even though nothing on this branch emits them. A superset costs
-- nothing and a subset is invisible until a user presses a button, so the
-- asymmetry decides it.
--
-- tests/test_audit_event_types.py derives its expectations from the AST of
-- api_compat.py and compares them against CONSTRAINT_MIGRATION, which this
-- change repoints at this file. A type emitted by a call site and missing here
-- fails that test rather than 500ing in production — which is the whole reason
-- the test parses the source instead of trusting a hand-maintained list.
--
-- NB: no quote characters in this prose. test_audit_event_types.py parses
-- quoted literals out of this file, so a quoted event name in a comment is
-- captured as if it were part of the vocabulary.
--
-- Same guarded drop-and-recreate shape as 006, 007, 009 and 011: the guard keys
-- on a value unique to this migration so re-running is a no-op.

BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
   WHERE nsp.nspname = 'public'
     AND rel.relname = 'audit_events'
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  -- Already widened by this migration? Leave it alone.
  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
             JOIN pg_class rel ON rel.oid = con.conrelid
            WHERE rel.relname = 'audit_events' AND con.conname = constraint_name
         )) NOT LIKE '%user.currency_updated%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%user.currency_updated%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        -- Written by _audit_log() and _record_memory_audit() in api_compat.py.
        -- Keep in step with tests/test_audit_event_types.py, which derives its
        -- expectations from the source rather than from this list.
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stunned',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        -- ── Carried from the concurrent audit-coverage work (012-019) ───────
        -- Not emitted by any call site on THIS branch. They are enumerated
        -- here because this migration runs last and its list is the one that
        -- survives: omitting a type the other branch emits would make every
        -- one of its writes raise CheckViolationError, rolling back the
        -- mutation it shares a transaction with. A superset is harmless; a
        -- subset is silent until someone presses the button.
        --
        -- Frozen by the team lead as of 2026-08-14. Any rename comes through
        -- them before it lands, so this list can be treated as stable.
        'compliance.scan_completed',
        'demo.phase_run',
        'demo.reset_requested',
        'support.requested',
        -- ───────────────────────────────────────────────────────────────────
        'consent.accepted',
        'cookie.preferences_updated',
        'nhi.dismissed',
        'nhi.enrolled',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        -- New in this migration. Per-user, deliberately not tenant-scoped: the
        -- tenant type above already exists and conflating the two would make a
        -- personal display choice look like a tenant-wide policy change.
        'user.currency_updated',
        'violation.acknowledged',
        -- Retained from 004, 006, 007 and 011. No call site emits these, but
        -- dropping them would break any environment holding rows that use them.
        'enrollment',
        'state_transition',
        'violation_detected',
        'compliance_check',
        'token_issued',
        'token_refused',
        'tenant_created',
        'user_provisioned',
        'directory_connected',
        'discovery_enroll_requested',
        'onboarding_completed',
        'onboarding_skipped'
      ));
  END IF;
END $body$;

COMMIT;
-- END 021_user_currency_event_type.sql

-- BEGIN 030_audit_events_append_only.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 030 — make public.audit_events append-only
-- ══════════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DEFENDS AGAINST
-- -------------------------
-- Not a malicious DBA. The realistic threat to an audit trail in this system is
-- the application rewriting its own history: a compromised API process, an
-- injection that reaches the writer, or a well-meaning future migration with a
-- stray UPDATE in it. All three arrive over the application's own database
-- connection, so a control that refuses UPDATE and DELETE on that connection
-- stops all three regardless of how the compromise happened.
--
-- audit_events is written by exactly one function, _audit_log() in
-- api_compat.py, which only ever INSERTs. Nothing in this repository has ever
-- had a legitimate reason to UPDATE or DELETE an audit row. The one legitimate
-- destructive caller is the demo reset (db/data-reset.sql); see ESCAPE HATCH.
--
--
-- WHY NOT A REVOKE
-- ----------------
-- The obvious control is:
--
--     REVOKE UPDATE, DELETE, TRUNCATE ON public.audit_events FROM <app role>;
--
-- Against this deployment that statement is decoration. Measured on the live
-- cluster (PostgreSQL 16.14, inf-signalloom/postgresql):
--
--     current_user  = signalloom      -- DATABASE_URL in base/secrets.yaml
--     tableowner    = signalloom      -- migrations run as the same role
--     rolsuper      = true            -- POSTGRES_USER in the bitnami entrypoint
--
-- The app connects as the table owner AND that role is a superuser. Two
-- separate reasons the grant system cannot help here, and the second is fatal:
--
--   1. Ownership. An owner may revoke privileges from itself — PostgreSQL does
--      allow that, contrary to folklore — but it may re-grant them at any time
--      with a single statement. A guard the guarded party can lift is a speed
--      bump, not a control.
--   2. Superuser. A superuser bypasses ALL privilege checks. The REVOKE is
--      recorded and then ignored. Observed directly, inside a transaction that
--      was rolled back afterwards:
--
--        REVOKE UPDATE, DELETE, TRUNCATE ON public.audit_events FROM signalloom;
--        -- relacl becomes  signalloom=arxt/signalloom
--        --   a=INSERT r=SELECT x=REFERENCES t=TRIGGER
--        --   no w (UPDATE), no d (DELETE), no D (TRUNCATE)
--        SELECT has_table_privilege('signalloom','public.audit_events','UPDATE');
--        -- t
--        UPDATE public.audit_events SET actor = 'TAMPERED';
--        -- UPDATE 12    <- every row rewritten, with the privilege revoked
--
-- So: a REVOKE-only migration would have passed review, applied cleanly, shown
-- a correct-looking ACL in \dp, and blocked nothing at all.
--
--
-- WHAT THIS DOES INSTEAD
-- ----------------------
-- A BEFORE UPDATE OR DELETE OR TRUNCATE trigger that unconditionally raises.
-- Triggers are not privilege checks, so superuser does not bypass them; the
-- same statements that succeeded above are refused with the trigger in place.
--
-- Three deliberate choices:
--
--   * FOR EACH STATEMENT, not FOR EACH ROW. It is the statement that is
--     illegitimate, not the row. Statement level costs nothing per row, and it
--     refuses `UPDATE ... WHERE false` too — a caller that believes it can
--     update audit rows should find out on the first attempt, not on the first
--     attempt that happens to match something. TRUNCATE triggers must be
--     statement level in any case, so this keeps it to one trigger.
--
--   * ENABLE ALWAYS, not the default ENABLE (ORIGIN). A session that sets
--     `session_replication_role = replica` skips ORIGIN triggers entirely;
--     measured on the live cluster, a DELETE under replica mode removed all 12
--     rows through an ORIGIN trigger and was refused by an ALWAYS one. Setting
--     that GUC needs superuser — which is exactly what the app role has, so the
--     distinction is not academic here.
--
--   * SQLSTATE 42501 (insufficient_privilege). asyncpg surfaces it as
--     InsufficientPrivilegeError and psql prints "permission denied"-class
--     wording, which is what a caller needs to read. The alternative codes
--     (0A000 feature_not_supported, 2F003 prohibited_sql_statement_attempted)
--     are more literally accurate about the mechanism and less comprehensible
--     about the meaning.
--
-- The REVOKE ... FROM PUBLIC below is not the control. It is one line of
-- housekeeping for the day someone adds a genuine read-only reporting role:
-- that role should not inherit write access from PUBLIC's defaults. It has no
-- effect on the app role today.
--
--
-- THIS DOES NOT BLOCK DDL — DELIBERATELY
-- --------------------------------------
-- Row and statement triggers fire on DML only. ALTER TABLE does not fire them,
-- and neither does the table rewrite that some ALTER TABLE forms perform. The
-- established way to widen audit_events.event_type in this repo is the guarded
-- drop-and-recreate of the CHECK constraint used by 006, 007, 009, 010 and 011,
-- and more of those are in flight right now. Verified against the live cluster
-- with this trigger installed:
--
--     ALTER TABLE public.audit_events DROP CONSTRAINT audit_events_event_type_check;
--     ALTER TABLE public.audit_events ADD  CONSTRAINT audit_events_event_type_check
--       CHECK (event_type IN (...));
--     -- ALTER TABLE / ALTER TABLE, no trigger involvement
--
-- Migrations that evolve this table therefore need to know nothing about this
-- one. The exception is a migration that needs to REWRITE existing audit rows
-- (a backfill, a column renormalisation): that is DML, it will be refused, and
-- refusing it is the point. Such a migration must lift the guard explicitly and
-- put it back, the same way db/data-reset.sql does.
--
--
-- ESCAPE HATCH, AND WHY THERE HAS TO BE ONE
-- -----------------------------------------
-- db/data-reset.sql TRUNCATEs every governance table to return the demo to a
-- live-empty state, and tests/test_contract_tier2.py runs it after every
-- mutating test. It reaches audit_events twice: directly in the 'audit' focus,
-- and — less obviously — via `TRUNCATE public.agent_registry CASCADE` in the
-- 'agents' focus, because audit_events.agent_id carries an FK to it. Both fire
-- this trigger. data-reset.sql is amended in the same commit to disable the
-- trigger for the duration of its transaction and re-enable it before COMMIT.
--
-- That hatch is available to anything holding the owner role, which is the app
-- role. It is not a privilege boundary and is not claimed as one. Its value is
-- that rewriting audit history now takes a deliberate, greppable, reviewable
-- DDL statement instead of happening by accident in a WHERE clause.
--
--
-- WHAT THIS DOES NOT PROTECT AGAINST
-- ----------------------------------
-- Read this as "the application can no longer rewrite the audit log", NOT as
-- "the audit log is now immutable". Overclaiming a control is worse than not
-- having one, because it stops people asking the next question.
--
--   * Superuser or table owner deliberately lifting the guard:
--     ALTER TABLE ... DISABLE TRIGGER, DROP TRIGGER, or replacing the trigger
--     function body. The app role can do all three. Two statements instead of
--     one is the whole of the delta.
--   * Anything below SQL: filesystem access to the data directory, a modified
--     Postgres binary, a snapshot of the PV.
--   * pg_dump / restore into a fresh database. The dump is data; the restored
--     copy is whatever the restorer chose to put in it.
--   * A compromise upstream of the INSERT. Nothing here judges whether an audit
--     row is truthful, only that it cannot later be changed. A caller that logs
--     a lie logs a permanent lie.
--   * Backdating. audit_events.timestamp defaults to NOW() and _audit_log()
--     never supplies it, so today's writer cannot backdate. A future writer, or
--     an injection that names the column, can. Forcing NEW.timestamp = now() in
--     a BEFORE INSERT trigger was considered and rejected: db/data-mock.sql
--     seeds deliberately backdated rows for the demo timeline and a forcing
--     trigger would flatten them. A separate server-set recorded_at column
--     would make the divergence detectable, but NOW() is not a constant default
--     so adding it rewrites the whole table under ACCESS EXCLUSIVE — too
--     expensive to bundle here. Ordering integrity belongs with the audit
--     hash-chain work, which is where a backdated insert becomes detectable
--     rather than merely discouraged.
--   * Deletion of the whole table or database. DROP TABLE is DDL.
--
-- Retention: nothing in this repository prunes audit_events today, so no
-- retention job is broken by this migration. Anything added later that expects
-- to age rows out MUST go through the same explicit disable/re-enable dance —
-- it will fail loudly rather than silently, which is the correct failure mode.
--
--
-- Idempotent by construction: CREATE OR REPLACE FUNCTION, DROP TRIGGER IF
-- EXISTS before CREATE TRIGGER, and a REVOKE that is a no-op when repeated. The
-- whole file is one transaction, so a fresh bootstrap and a re-run of the
-- runner against an already-guarded database both converge on the same state.

BEGIN;

CREATE OR REPLACE FUNCTION public.audit_events_reject_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
  RAISE EXCEPTION
    'audit_events is append-only: % is refused', TG_OP
    USING
      ERRCODE = '42501',
      DETAIL  = 'public.audit_events accepts INSERT only. Audit history is not '
                'rewritable over the application database connection.',
      HINT    = 'Record a compensating audit event instead. If this really is '
                'a sanctioned reset or backfill, lift the guard explicitly for '
                'the duration of the transaction: ALTER TABLE '
                'public.audit_events DISABLE TRIGGER audit_events_append_only; '
                '... ; ALTER TABLE public.audit_events ENABLE ALWAYS TRIGGER '
                'audit_events_append_only;';
END
$body$;

COMMENT ON FUNCTION public.audit_events_reject_mutation() IS
  'Refuses every UPDATE, DELETE and TRUNCATE against public.audit_events. '
  'Installed by migration 030. Stops the application rewriting its own audit '
  'history; does not constrain a superuser who deliberately disables it.';

-- DROP + CREATE rather than CREATE OR REPLACE TRIGGER: the latter is PG14+ and
-- this file also has to apply through the generated initdb bootstrap, whose
-- server version is not pinned here. DDL is transactional, so there is no
-- window in which the table is unguarded.
DROP TRIGGER IF EXISTS audit_events_append_only ON public.audit_events;

CREATE TRIGGER audit_events_append_only
  BEFORE UPDATE OR DELETE OR TRUNCATE ON public.audit_events
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.audit_events_reject_mutation();

-- ORIGIN triggers are skipped when session_replication_role = 'replica'.
-- ALWAYS triggers are not. The app role is a superuser and can set that GUC.
ALTER TABLE public.audit_events
  ENABLE ALWAYS TRIGGER audit_events_append_only;

COMMENT ON TRIGGER audit_events_append_only ON public.audit_events IS
  'Append-only guard (migration 030). INSERT and DDL are unaffected; '
  'UPDATE, DELETE and TRUNCATE raise 42501. db/data-reset.sql is the only '
  'sanctioned caller that disables it, and re-enables it in the same '
  'transaction.';

-- Housekeeping only, for a future non-superuser role. The app role owns the
-- table and is a superuser, so this changes nothing about its access today.
REVOKE UPDATE, DELETE, TRUNCATE ON public.audit_events FROM PUBLIC;

COMMIT;
-- END 030_audit_events_append_only.sql

-- BEGIN 031_signal_fusion_provisional_actors.sql
-- Migration: 031_signal_fusion_provisional_actors
-- Signal Fusion: provisional actors, evidence chains, and signal audit trail.
-- These tables are the PostgreSQL half of the Signal Fusion storage split.
-- Signal observations live in the columnar store (FrostDB); everything that
-- needs read-after-write, per-record erasure, or audit anchoring lives here.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS,
--             ON CONFLICT DO NOTHING, DROP TRIGGER IF EXISTS.

BEGIN;

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. provisional_actors — correlation-discovered agent candidates
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.provisional_actors (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT        NOT NULL DEFAULT 'tenant-demo',
    status          TEXT        NOT NULL DEFAULT 'provisional'
                                CHECK (status IN ('provisional', 'actionable', 'promoted', 'dismissed')),
    confidence      NUMERIC(5,4) NOT NULL DEFAULT 0.0
                                CHECK (confidence >= 0 AND confidence <= 1),
    correlation_keys JSONB      NOT NULL DEFAULT '[]'::jsonb,
    display_name    TEXT,
    promoted_at     TIMESTAMPTZ,
    agent_registry_id UUID      REFERENCES public.agent_registry(id),
    dismissed_at    TIMESTAMPTZ,
    dismissed_reason TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_provisional_actors_tenant
    ON public.provisional_actors (tenant_id);
CREATE INDEX IF NOT EXISTS idx_provisional_actors_status
    ON public.provisional_actors (status);
CREATE INDEX IF NOT EXISTS idx_provisional_actors_confidence
    ON public.provisional_actors (confidence DESC);

DROP TRIGGER IF EXISTS set_provisional_actors_updated_at ON public.provisional_actors;
CREATE TRIGGER set_provisional_actors_updated_at
    BEFORE UPDATE ON public.provisional_actors
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. actor_evidence — links between provisional actors and signal observations
-- ══════════════════════════════════════════════════════════════════════════════
-- Each row links one observation (stored in the columnar store) to a
-- provisional actor. The observation_id is an external reference to the
-- signal store, not a foreign key — the two stores are deliberately separate.

CREATE TABLE IF NOT EXISTS public.actor_evidence (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT        NOT NULL DEFAULT 'tenant-demo',
    actor_id        UUID        NOT NULL REFERENCES public.provisional_actors(id) ON DELETE CASCADE,
    observation_id  TEXT        NOT NULL,  -- reference to signal store, not FK
    layer           TEXT        NOT NULL
                                CHECK (layer IN (
                                    'network_egress', 'identity_authorization',
                                    'application_saas', 'endpoint_host', 'behavioural',
                                    'cloud_control_plane', 'protocol'
                                )),
    fidelity        TEXT        NOT NULL
                                CHECK (fidelity IN ('definitive', 'strong', 'suggestive', 'circumstantial')),
    contribution    TEXT        NOT NULL,  -- human-readable description
    observed_at     TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_actor_evidence_actor
    ON public.actor_evidence (actor_id);
CREATE INDEX IF NOT EXISTS idx_actor_evidence_layer
    ON public.actor_evidence (layer);
CREATE INDEX IF NOT EXISTS idx_actor_evidence_observation
    ON public.actor_evidence (observation_id);

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. signal_audit_trail — audit records for signal fusion operations
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.signal_audit_trail (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT        NOT NULL DEFAULT 'tenant-demo',
    event_type      TEXT        NOT NULL
                                CHECK (event_type IN (
                                    'observation_ingested', 'correlation_run',
                                    'actor_created', 'actor_updated',
                                    'actor_promoted', 'actor_dismissed',
                                    'collector_run', 'partition_dropped'
                                )),
    actor_id        UUID        REFERENCES public.provisional_actors(id),
    detail          JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_signal_audit_trail_tenant
    ON public.signal_audit_trail (tenant_id);
CREATE INDEX IF NOT EXISTS idx_signal_audit_trail_event_type
    ON public.signal_audit_trail (event_type);
CREATE INDEX IF NOT EXISTS idx_signal_audit_trail_actor
    ON public.signal_audit_trail (actor_id);
CREATE INDEX IF NOT EXISTS idx_signal_audit_trail_created
    ON public.signal_audit_trail (created_at DESC);

-- ══════════════════════════════════════════════════════════════════════════════
-- 4. Widen the audit_events CHECK constraint to admit signal fusion event types
-- ══════════════════════════════════════════════════════════════════════════════
-- Migration 007 owns the CHECK constraint on audit_events.event_type.
-- Rather than replacing that constraint (which would couple this migration to
-- the exact set of values 007 chose), signal fusion events flow through the
-- dedicated signal_audit_trail table above. The existing audit_events table
-- and its constraint are left untouched.

COMMIT;
-- END 031_signal_fusion_provisional_actors.sql

-- BEGIN 032_generated_demo_event_types.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 032 — admit the event types the multi-demo router GENERATES
-- ══════════════════════════════════════════════════════════════════════════════
--
-- WHAT BROKE
-- ----------
-- POST /api/demo/signalfusion/runs returned 500 on the Signal Fusion demo's
-- first phase, in front of an audience:
--
--   asyncpg.exceptions.CheckViolationError: new row for relation "audit_events"
--     violates check constraint "audit_events_event_type_check"
--   DETAIL: ... demo.signalfusion.phase_run ...
--
-- demo_runner.py has two paths into _record_privileged_invocation(). The
-- original SuperCred route passes a LITERAL:
--
--   _record_privileged_invocation(principal, "demo.phase_run", ...)
--
-- and the generic router factory _build_demo_router() INTERPOLATES:
--
--   _record_privileged_invocation(principal, f"demo.{config.demo_type}.phase_run", ...)
--   _record_privileged_invocation(principal, f"demo.{config.demo_type}.reset_requested", ...)
--
-- 'demo.phase_run' has been permitted since 012, which is why the SuperCred
-- demo kept working and why this looked like a Signal Fusion problem rather
-- than a refactor that shipped without its migration. The generalisation
-- changed the event type from a fixed string into a family of generated ones,
-- and the constraint's enumeration never followed.
--
--
-- THE SECOND DEFECT, WHICH THE CONSTRAINT ALONE DOES NOT FIX
-- -----------------------------------------------------------
-- audit_events.event_type has been VARCHAR(30) since 004. The generated names:
--
--   demo.supercred.phase_run             24
--   demo.signalfusion.phase_run          27   <- the reported 500
--   demo.supercred.reset_requested       30   <- exactly at the ceiling
--   demo.signalfusion.reset_requested    33   <- OVER IT
--
-- So widening only the CHECK constraint fixes the Run button and leaves the
-- Reset button failing — with StringDataRightTruncation instead of
-- CheckViolationError. Same 500, same endpoint, completely different error,
-- discovered only by whoever pressed Reset next. This migration therefore
-- widens the column as well, and tests/test_audit_event_types.py grew
-- test_every_emitted_event_type_fits_the_column so length is checked by
-- machine from here on.
--
-- 012 did that length check by hand, in a comment: "Lengths against the
-- VARCHAR(30) ceiling, longest first". That was correct when the vocabulary was
-- a hand-written list of short names. It stopped being checkable the moment the
-- emitter became an f-string, and a comment cannot notice that it has been
-- outgrown.
--
-- VARCHAR(30) -> TEXT rather than a bigger number. The CHECK constraint is an
-- exact allowlist, so it — not the column width — is what actually bounds this
-- value; a length cap on top of an allowlist constrains nothing the allowlist
-- does not already constrain, and contributes only a second, less legible way
-- for the same insert to fail. varchar -> text is binary-coercible, so this is
-- a catalogue change with no table rewrite and no scan.
--
--
-- WHY ENUMERATE RATHER THAN MATCH A PATTERN
-- ------------------------------------------
-- The obvious alternative is to stop enumerating and admit the family:
--
--   CHECK (event_type ~ '^demo\.[a-z_]+\.(phase_run|reset_requested)$' OR ...)
--
-- That never breaks again, and it was rejected. Three reasons, in order of
-- weight:
--
--   1. It converts the constraint from an allowlist into a shape check exactly
--      where the vocabulary is generated, which is exactly where a typo is most
--      likely and least visible. `demo.signalfsion.phase_run` satisfies that
--      regex. Under the enumeration it is a loud failure; under the pattern it
--      is a permanent, silent second vocabulary in the audit trail, and audit
--      rows are not editable (030) so it could not be cleaned up afterwards.
--   2. The constraint is READ as a source of truth, not merely enforced.
--      tests/test_audit_event_types.py parses this list, and
--      tests/test_dashboard_audit_vocabulary.py compares the dashboard's filter
--      options against it — a filter <select> cannot be built from a regex.
--      "What event types can this system record?" is a question a bank asks,
--      and `pg_get_constraintdef` currently answers it exactly. A pattern
--      answers a weaker question: "what shapes are not refused".
--   3. It contradicts this table's established posture. 030's whole argument is
--      that changing audit history should require "a deliberate, greppable,
--      reviewable DDL statement instead of happening by accident". Widening the
--      vocabulary is the same class of act, and deserves the same ceremony.
--
-- The cost of enumerating is one migration per new demo type. That cost is only
-- acceptable because it is now IMPOSSIBLE TO FORGET: test_audit_event_types.py
-- derives the demo types from the DemoConfig(demo_type=...) constructions,
-- expands the f-string templates over them, and fails if the result is not
-- permitted here. Registering a third demo turns that test red at commit time
-- rather than 500ing at runtime. Enumeration without that guard would just be
-- this bug on a timer, which is what it was.
--
-- The emitter deliberately keeps its f-string. Making it validate against a
-- shared constant was considered and rejected: it moves the failure from the
-- database to the application without removing it, and a runtime check that
-- fires in the same place at the same moment is not an improvement over a
-- constraint. The single source of truth is DemoConfig, and the test is what
-- binds it to this file.
--
--
-- SCOPE: all four combinations, not the one that broke. _build_demo_router() is
-- a factory over DEMO_CONFIGS, so the types it can generate are the full cross
-- product of the demo types with the two verbs. Only signalfusion is wired
-- through it today (supercred still uses the legacy literal route), but
-- `_build_demo_router(DEMO_CONFIGS["supercred"])` is a one-line change, and a
-- superset costs nothing while a subset is silent until someone presses the
-- button — 011 and 021 both record that lesson.
--
-- Same guarded drop-and-recreate shape as 006, 007, 009, 010, 011, 012 and 021:
-- event_type is a CHECK constraint rather than an enum, so widening means
-- recreating it, and the guard keys on a value unique to this migration so
-- re-running is a no-op.
--
-- This file enumerates EVERY permitted type, not just the new ones, for the
-- reason 011 records in detail: whichever migration runs LAST wins outright, so
-- a partial list here would silently drop everything 021 admitted.
--
-- 030 makes audit_events append-only via a BEFORE UPDATE/DELETE/TRUNCATE
-- trigger. Both statements below are DDL, which does not fire DML triggers —
-- 030's own comments verify precisely this drop-and-recreate against the live
-- cluster with the trigger installed. No rows are rewritten here, so the guard
-- neither needs nor gets an exemption.
--
-- CONSTRAINT_MIGRATION in tests/test_audit_event_types.py now points here.

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────────
-- 1. Widen the column so the longest generated name can be stored at all
-- ──────────────────────────────────────────────────────────────────────────────
-- Guarded so a re-run is a catalogue read rather than a needless ACCESS
-- EXCLUSIVE lock on a table the demo is actively writing to.

DO $body$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'audit_events'
       AND column_name  = 'event_type'
       AND character_maximum_length IS NOT NULL
  ) THEN
    ALTER TABLE public.audit_events
      ALTER COLUMN event_type TYPE TEXT;
  END IF;
END $body$;

COMMENT ON COLUMN public.audit_events.event_type IS
  'Audit vocabulary. Bounded by audit_events_event_type_check, not by a length '
  'limit: the CHECK is an exact allowlist, so a width cap would add only a '
  'second failure mode. Widened from VARCHAR(30) by migration 032, where '
  'demo.signalfusion.reset_requested (33 chars) did not fit.';

-- ──────────────────────────────────────────────────────────────────────────────
-- 2. Admit the generated demo event types
-- ──────────────────────────────────────────────────────────────────────────────

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
   WHERE nsp.nspname = 'public'
     AND rel.relname = 'audit_events'
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  -- Already widened by this migration? Leave it alone.
  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
             JOIN pg_class rel ON rel.oid = con.conrelid
            WHERE rel.relname = 'audit_events' AND con.conname = constraint_name
         )) NOT LIKE '%demo.signalfusion.phase_run%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%demo.signalfusion.phase_run%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        -- Written by _audit_log() and _record_memory_audit() in api_compat.py.
        -- Keep in step with tests/test_audit_event_types.py, which derives its
        -- expectations from the source rather than from this list.
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stunned',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        -- ── The legacy fixed-string demo route ─────────────────────────────
        -- demo_runner.start_demo_run()/reset(), the original SuperCred pair.
        -- Still emitted: those routes pass literals and are unchanged.
        'demo.phase_run',
        'demo.reset_requested',
        -- ── Generated by _build_demo_router() ──────────────────────────────
        -- f"demo.{config.demo_type}.{phase_run|reset_requested}" over every
        -- DemoConfig. NOT hand-maintained in any meaningful sense: adding a
        -- DemoConfig without extending this list fails
        -- test_every_emitted_event_type_is_permitted, which derives the demo
        -- types from the constructor calls and expands the templates itself.
        --
        -- The supercred pair is not reachable today — that demo still uses
        -- the legacy literal routes above — but the factory can produce it
        -- from one line of wiring, and a subset here is silent until someone
        -- presses the button.
        --
        -- NB: no apostrophes in these comments. _permitted_event_types() pairs
        -- single quotes to read this list, so one apostrophe in prose shifts
        -- every pair after it and silently truncates the parsed vocabulary.
        -- 011 carries the same warning; this migration re-learned it.
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        -- ───────────────────────────────────────────────────────────────────
        'support.requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'nhi.dismissed',
        'nhi.enrolled',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'user.currency_updated',
        'violation.acknowledged',
        -- Retained from 004, 006, 007 and 011. No call site emits these, but
        -- dropping them would break any environment holding rows that use them.
        'enrollment',
        'state_transition',
        'violation_detected',
        'compliance_check',
        'token_issued',
        'token_refused',
        'tenant_created',
        'user_provisioned',
        'directory_connected',
        'discovery_enroll_requested',
        'onboarding_completed',
        'onboarding_skipped'
      ));
  END IF;
END $body$;

COMMIT;
-- END 032_generated_demo_event_types.sql
