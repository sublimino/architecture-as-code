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
