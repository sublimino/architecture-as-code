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
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
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

-- BEGIN 033_quarantine_synthetic_audit_events.sql
-- Migration: 033_quarantine_synthetic_audit_events
-- Quarantines historical synthetic audit events created by legacy GET /api/audit side effects.
-- Under RFC 9110 and Signal Loom governance invariants, GET operations must be strictly read-only.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS,
--             guarded migration execution.

BEGIN;

CREATE TABLE IF NOT EXISTS public.quarantined_synthetic_audit_events (
    id              UUID        PRIMARY KEY,
    tenant_id       TEXT        NOT NULL,
    event_type      TEXT        NOT NULL,
    agent_id        UUID,
    agent_name      TEXT,
    actor           TEXT        NOT NULL,
    detail          JSONB       NOT NULL DEFAULT '{}'::jsonb,
    timestamp       TIMESTAMPTZ NOT NULL,
    quarantined_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    quarantine_reason TEXT      NOT NULL DEFAULT 'legacy_synthetic_audit_generation'
);

CREATE INDEX IF NOT EXISTS idx_quarantined_audit_tenant
    ON public.quarantined_synthetic_audit_events (tenant_id);
CREATE INDEX IF NOT EXISTS idx_quarantined_audit_event_type
    ON public.quarantined_synthetic_audit_events (event_type);
CREATE INDEX IF NOT EXISTS idx_quarantined_audit_timestamp
    ON public.quarantined_synthetic_audit_events (timestamp DESC);

DO $body$
BEGIN
    -- Only run quarantine copy/delete if audit_events exists
    IF EXISTS (
        SELECT 1 FROM information_schema.tables 
        WHERE table_schema = 'public' AND table_name = 'audit_events'
    ) THEN
        -- Lift append-only trigger temporarily for sanctioned quarantine
        IF EXISTS (
            SELECT 1 FROM pg_trigger WHERE tgname = 'audit_events_append_only'
        ) THEN
            ALTER TABLE public.audit_events DISABLE TRIGGER audit_events_append_only;
        END IF;

        -- Move synthetic audit events to quarantine table
        INSERT INTO public.quarantined_synthetic_audit_events (
            id, tenant_id, event_type, agent_id, agent_name, actor, detail, timestamp, quarantine_reason
        )
        SELECT 
            id, tenant_id, event_type, agent_id, agent_name, actor, detail, timestamp,
            'legacy_synthetic_audit_generation'
        FROM public.audit_events
        WHERE (
            actor IN ('system/discovery', 'spire/workload-attestor', 'governance/engine')
            AND (detail->>'source' = 'declarative-cr' OR detail ? 'agent_ref')
        )
        ON CONFLICT (id) DO NOTHING;

        -- Remove synthetic rows from active audit table
        DELETE FROM public.audit_events
        WHERE (
            actor IN ('system/discovery', 'spire/workload-attestor', 'governance/engine')
            AND (detail->>'source' = 'declarative-cr' OR detail ? 'agent_ref')
        );

        -- Restore append-only trigger
        IF EXISTS (
            SELECT 1 FROM pg_trigger WHERE tgname = 'audit_events_append_only'
        ) THEN
            ALTER TABLE public.audit_events ENABLE ALWAYS TRIGGER audit_events_append_only;
        END IF;
    END IF;
END $body$;

COMMIT;
-- END 033_quarantine_synthetic_audit_events.sql

-- BEGIN 034_agent_origin_verification.sql
-- Migration: 034_agent_origin_verification.sql
-- Establishes authenticated origin verification tracking for agent workloads.
-- Supports Live Authenticated Origin Verification (SFAGENTS-P3-4) under RFC 9110.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS.

BEGIN;

CREATE TABLE IF NOT EXISTS public.agent_origin_verifications (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           TEXT        NOT NULL,
    agent_id            UUID        REFERENCES public.agent_registry(id) ON DELETE CASCADE,
    origin_type         TEXT        NOT NULL DEFAULT 'unknown',
    auth_method         TEXT        NOT NULL DEFAULT 'none',
    issuer              TEXT,
    subject             TEXT,
    status              TEXT        NOT NULL DEFAULT 'unverified'
                                    CHECK (status IN ('verified', 'unverified', 'failed', 'unsupported')),
    verified            BOOLEAN     NOT NULL DEFAULT false,
    proxy_path          TEXT,
    metadata            JSONB       NOT NULL DEFAULT '{}'::jsonb,
    verified_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_agent_origin_verifications_tenant
    ON public.agent_origin_verifications (tenant_id);
CREATE INDEX IF NOT EXISTS idx_agent_origin_verifications_agent_id
    ON public.agent_origin_verifications (agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_origin_verifications_status
    ON public.agent_origin_verifications (status);

COMMIT;
-- END 034_agent_origin_verification.sql

-- BEGIN 035_agent_claim_contract.sql
-- Migration: tenant-scoped registry identity and approved claim audit vocabulary.
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
     AND con.contype = 'u'
     AND pg_get_constraintdef(con.oid) = 'UNIQUE (name)'
   LIMIT 1;

  IF constraint_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.agent_registry DROP CONSTRAINT %I', constraint_name);
  END IF;
END $body$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_registry_tenant_name
  ON public.agent_registry (tenant_id, name);

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
         )) NOT LIKE '%agent.claimed%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%agent.claimed%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stunned',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'support.requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'nhi.dismissed',
        'nhi.enrolled',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'user.currency_updated',
        'violation.acknowledged',
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
-- END 035_agent_claim_contract.sql

-- BEGIN 036_agent_claim_persistence.sql
-- Durable, tenant-scoped agent claim lifecycle and concurrency constraints.
BEGIN;

CREATE TABLE IF NOT EXISTS public.agent_claims (
    claim_id                   TEXT        PRIMARY KEY,
    tenant_id                  TEXT        NOT NULL,
    agent_id                   UUID        NOT NULL REFERENCES public.agent_registry(id) ON DELETE CASCADE,
    pod_name                   TEXT        NOT NULL,
    namespace                  TEXT        NOT NULL,
    spiffe_id                  TEXT        NOT NULL,
    harness                    TEXT        NOT NULL,
    model                      TEXT        NOT NULL,
    status                     TEXT        NOT NULL CHECK (status IN ('granted', 'denied', 'pending-review')),
    allocated_token_budget     INTEGER     NOT NULL CHECK (allocated_token_budget > 0),
    authoritative_pod_uid      TEXT,
    claimed_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    released_at                TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_agent_claims_tenant
    ON public.agent_claims (tenant_id, claimed_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_claims_active_tenant_agent
    ON public.agent_claims (tenant_id, agent_id)
    WHERE status = 'granted' AND released_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_claims_active_authoritative_pod_uid
    ON public.agent_claims (authoritative_pod_uid)
    WHERE authoritative_pod_uid IS NOT NULL
      AND status = 'granted'
      AND released_at IS NULL;

COMMIT;
-- END 036_agent_claim_persistence.sql

-- BEGIN 037_signed_audit_sessions.sql
-- Migration: 037_signed_audit_sessions.sql
-- Ingest and storage for signed audit sessions (SLON-P2-2) conforming to SP-5.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS.

BEGIN;

CREATE TABLE IF NOT EXISTS public.signed_audit_sessions (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id          TEXT        NOT NULL UNIQUE,
    tenant_id           TEXT        NOT NULL,
    agent_id            TEXT        NOT NULL,
    spiffe_id           TEXT        NOT NULL,
    started_at          TIMESTAMPTZ NOT NULL,
    ended_at            TIMESTAMPTZ,
    events_count        INTEGER     NOT NULL DEFAULT 0,
    root_hash           TEXT        NOT NULL,
    signature           TEXT        NOT NULL,
    algorithm           TEXT        NOT NULL DEFAULT 'ECDSA_SHA256',
    public_key          TEXT,
    verified            BOOLEAN     NOT NULL DEFAULT true,
    hash_chain_valid    BOOLEAN     NOT NULL DEFAULT true,
    signature_valid     BOOLEAN     NOT NULL DEFAULT true,
    events              JSONB       NOT NULL DEFAULT '[]'::jsonb,
    metadata            JSONB       NOT NULL DEFAULT '{}'::jsonb,
    ingested_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_signed_audit_sessions_tenant
    ON public.signed_audit_sessions (tenant_id);
CREATE INDEX IF NOT EXISTS idx_signed_audit_sessions_agent
    ON public.signed_audit_sessions (agent_id);
CREATE INDEX IF NOT EXISTS idx_signed_audit_sessions_session_id
    ON public.signed_audit_sessions (session_id);

COMMIT;
-- END 037_signed_audit_sessions.sql

-- BEGIN 038_operator_identities.sql
-- 038 — attributable AgentMaxxing operator identities
--
-- Migration 008 remains the platform-user directory baseline. This forward-only
-- extension binds a directory row to one immutable OIDC issuer/subject pair,
-- preserves removed identities, and gives audit rows stable identity snapshots.
-- Existing users are deliberately not guessed or backfilled.

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS uq_platform_users_id_tenant
    ON public.platform_users (id, tenant_id);

CREATE TABLE IF NOT EXISTS public.operator_identities (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    platform_user_id    UUID        NOT NULL,
    tenant_id           TEXT        NOT NULL,
    issuer              TEXT        NOT NULL CHECK (btrim(issuer) <> ''),
    subject             TEXT        NOT NULL CHECK (btrim(subject) <> ''),
    identity_kind       TEXT        NOT NULL DEFAULT 'individual'
                                    CHECK (identity_kind = 'individual'),
    status              TEXT        NOT NULL DEFAULT 'active'
                                    CHECK (status IN ('active', 'removed')),
    removed_at          TIMESTAMPTZ,
    removed_by_user_id  UUID,
    removal_reason      TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_operator_identity_user UNIQUE (platform_user_id),
    CONSTRAINT uq_operator_identity_subject UNIQUE (issuer, subject),
    CONSTRAINT fk_operator_identity_user_tenant
        FOREIGN KEY (platform_user_id, tenant_id)
        REFERENCES public.platform_users (id, tenant_id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_operator_identity_remover_tenant
        FOREIGN KEY (removed_by_user_id, tenant_id)
        REFERENCES public.platform_users (id, tenant_id)
        ON DELETE RESTRICT,
    CONSTRAINT operator_identities_removal_check CHECK (
        (
            status = 'active'
            AND removed_at IS NULL
            AND removed_by_user_id IS NULL
            AND removal_reason IS NULL
        )
        OR
        (
            status = 'removed'
            AND removed_at IS NOT NULL
            AND removed_by_user_id IS NOT NULL
            AND removal_reason IS NOT NULL
            AND btrim(removal_reason) <> ''
        )
    )
);

CREATE INDEX IF NOT EXISTS idx_operator_identities_tenant_status
    ON public.operator_identities (tenant_id, status);

DROP TRIGGER IF EXISTS set_operator_identities_updated_at
    ON public.operator_identities;
CREATE TRIGGER set_operator_identities_updated_at
    BEFORE UPDATE ON public.operator_identities
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.audit_events
    ADD COLUMN IF NOT EXISTS actor_user_id UUID,
    ADD COLUMN IF NOT EXISTS actor_issuer TEXT,
    ADD COLUMN IF NOT EXISTS actor_subject TEXT;

DO $body$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.audit_events'::regclass
       AND conname = 'audit_events_actor_user_tenant_fkey'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_actor_user_tenant_fkey
      FOREIGN KEY (actor_user_id, tenant_id)
      REFERENCES public.platform_users (id, tenant_id) ON DELETE RESTRICT;
  END IF;
END $body$;

CREATE INDEX IF NOT EXISTS idx_audit_events_actor_user
    ON public.audit_events (tenant_id, actor_user_id, timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_audit_events_actor_identity
    ON public.audit_events (tenant_id, actor_issuer, actor_subject, timestamp DESC)
    WHERE actor_issuer IS NOT NULL AND actor_subject IS NOT NULL;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
         )) NOT LIKE '%operator.created%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%operator.created%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stunned',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'support.requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'nhi.dismissed',
        'nhi.enrolled',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'user.currency_updated',
        'violation.acknowledged',
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
-- END 038_operator_identities.sql

-- BEGIN 039_external_agent_registrations.sql
-- 039 — tenant-bound external Linux agent registrations and claim controls
--
-- Adds durable registration metadata for external Linux agents (host OS,
-- runtime profile, enrollment status, allocated budget, registration provenance).
-- Ensures global agent_id uniqueness to reject cross-tenant and duplicate claims,
-- with foreign keys to tenant-scoped platform users and comprehensive audit types.

BEGIN;

CREATE TABLE IF NOT EXISTS public.external_agent_registrations (
    id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id                    TEXT        NOT NULL CHECK (btrim(agent_id) <> ''),
    tenant_id                   TEXT        NOT NULL CHECK (btrim(tenant_id) <> ''),
    host_id                     TEXT        NOT NULL CHECK (btrim(host_id) <> ''),
    host_os                     TEXT        NOT NULL DEFAULT 'linux'
                                            CHECK (host_os IN ('linux', 'ubuntu-24.04', 'debian-12', 'rhel-9', 'fedora-40', 'arch')),
    runtime_profile             TEXT        NOT NULL DEFAULT 'nono-0.73.0-standard'
                                            CHECK (btrim(runtime_profile) <> ''),
    enrollment_status           TEXT        NOT NULL DEFAULT 'pending'
                                            CHECK (enrollment_status IN ('pending', 'enrolled', 'revoked', 'failed')),
    registered_by_user_id       UUID,
    registered_by_subject       TEXT        NOT NULL CHECK (btrim(registered_by_subject) <> ''),
    registered_by_issuer        TEXT        NOT NULL CHECK (btrim(registered_by_issuer) <> ''),
    allocated_token_budget      INTEGER     NOT NULL DEFAULT 100000 CHECK (allocated_token_budget > 0),
    spiffe_id_pattern           TEXT,
    enrollment_token_hash       TEXT,
    enrollment_token_expires_at TIMESTAMPTZ,
    enrolled_at                 TIMESTAMPTZ,
    revoked_at                  TIMESTAMPTZ,
    revocation_reason           TEXT,
    metadata                    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_external_agent_registrations_agent_id UNIQUE (agent_id),
    CONSTRAINT fk_external_agent_registered_by_user
        FOREIGN KEY (registered_by_user_id, tenant_id)
        REFERENCES public.platform_users (id, tenant_id)
        ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_external_agent_registrations_tenant_status
    ON public.external_agent_registrations (tenant_id, enrollment_status);

CREATE INDEX IF NOT EXISTS idx_external_agent_registrations_tenant_created
    ON public.external_agent_registrations (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_external_agent_registrations_host
    ON public.external_agent_registrations (tenant_id, host_id);

DROP TRIGGER IF EXISTS set_external_agent_registrations_updated_at
    ON public.external_agent_registrations;
CREATE TRIGGER set_external_agent_registrations_updated_at
    BEFORE UPDATE ON public.external_agent_registrations
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Extend audit event types for external agent lifecycle
DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
         )) NOT LIKE '%external_agent.registered%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%external_agent.registered%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stunned',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'external_agent.registered',
        'external_agent.claim_rejected',
        'external_agent.status_updated',
        'external_agent.revoked',
        'external_agent.claimed',
        'support.requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'nhi.dismissed',
        'nhi.enrolled',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'user.currency_updated',
        'violation.acknowledged',
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
-- END 039_external_agent_registrations.sql

-- BEGIN 040_host_enrollment_tokens.sql
-- 040 — host enrollment tokens with single-use consumption flags and timestamps
--
-- Implements AMXO-P3-1:
-- 1. Dedicated host enrollment tokens with single-use consumption flags and timestamps.
-- 2. Extended external agent registration credentials state (enrolled key ID, public key, nonce).
-- 3. Atomic token lookup indexes and audit event types.

BEGIN;

CREATE TABLE IF NOT EXISTS public.host_enrollment_tokens (
    id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                   TEXT        NOT NULL CHECK (btrim(tenant_id) <> ''),
    agent_id                    TEXT        NOT NULL CHECK (btrim(agent_id) <> ''),
    host_id                     TEXT        NOT NULL CHECK (btrim(host_id) <> ''),
    token_hash                  TEXT        NOT NULL CHECK (btrim(token_hash) <> ''),
    created_by_subject          TEXT        NOT NULL CHECK (btrim(created_by_subject) <> ''),
    created_by_issuer           TEXT        NOT NULL CHECK (btrim(created_by_issuer) <> ''),
    expires_at                  TIMESTAMPTZ NOT NULL,
    consumed_at                 TIMESTAMPTZ,
    consumed_by_host_id         TEXT,
    consumed_by_key_id          TEXT,
    consumed_by_public_key      TEXT,
    consumed_by_client_nonce    TEXT,
    status                      TEXT        NOT NULL DEFAULT 'pending'
                                            CHECK (status IN ('pending', 'consumed', 'expired', 'revoked')),
    metadata                    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_host_enrollment_tokens_hash UNIQUE (token_hash),
    CONSTRAINT fk_host_enrollment_token_agent
        FOREIGN KEY (agent_id)
        REFERENCES public.external_agent_registrations (agent_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_host_enrollment_tokens_tenant_status
    ON public.host_enrollment_tokens (tenant_id, status);

CREATE INDEX IF NOT EXISTS idx_host_enrollment_tokens_agent
    ON public.host_enrollment_tokens (tenant_id, agent_id);

CREATE INDEX IF NOT EXISTS idx_host_enrollment_tokens_hash
    ON public.host_enrollment_tokens (token_hash);

-- Extend external_agent_registrations table with enrolled credential columns
ALTER TABLE public.external_agent_registrations
    ADD COLUMN IF NOT EXISTS enrolled_key_id TEXT,
    ADD COLUMN IF NOT EXISTS enrolled_public_key TEXT,
    ADD COLUMN IF NOT EXISTS enrolled_client_nonce TEXT,
    ADD COLUMN IF NOT EXISTS enrolled_credential_reference TEXT,
    ADD COLUMN IF NOT EXISTS enrolled_credential_expires_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS token_consumed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_external_agent_registrations_token_hash
    ON public.external_agent_registrations (enrollment_token_hash)
    WHERE enrollment_token_hash IS NOT NULL;

DROP TRIGGER IF EXISTS set_host_enrollment_tokens_updated_at
    ON public.host_enrollment_tokens;
CREATE TRIGGER set_host_enrollment_tokens_updated_at
    BEFORE UPDATE ON public.host_enrollment_tokens
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Extend audit event types for host enrollment
DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
          )) NOT LIKE '%external_agent.token_issued%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%external_agent.token_issued%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stunned',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'external_agent.registered',
        'external_agent.claim_rejected',
        'external_agent.status_updated',
        'external_agent.revoked',
        'external_agent.claimed',
        'external_agent.token_issued',
        'external_agent.enrolled',
        'support.requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'nhi.dismissed',
        'nhi.enrolled',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'user.currency_updated',
        'violation.acknowledged',
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
-- END 040_host_enrollment_tokens.sql

-- BEGIN 041_external_host_revocation.sql
-- 041 — external host revocation tracking and attribution
--
-- Adds attributable revoking operator columns and indexes to
-- public.external_agent_registrations for independent host revocation enforcement.
-- Ensures that host revocation captures exact operator identity, timestamp,
-- and reason without impacting platform user accounts or sibling agent workloads.

BEGIN;

ALTER TABLE public.external_agent_registrations
    ADD COLUMN IF NOT EXISTS revoked_by_user_id UUID,
    ADD COLUMN IF NOT EXISTS revoked_by_subject TEXT,
    ADD COLUMN IF NOT EXISTS revoked_by_issuer TEXT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'fk_external_agent_revoked_by_user'
          AND conrelid = 'public.external_agent_registrations'::regclass
    ) THEN
        ALTER TABLE public.external_agent_registrations
            ADD CONSTRAINT fk_external_agent_revoked_by_user
            FOREIGN KEY (revoked_by_user_id, tenant_id)
            REFERENCES public.platform_users (id, tenant_id)
            ON DELETE RESTRICT;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_external_agent_registrations_revocation
    ON public.external_agent_registrations (tenant_id, enrollment_status, revoked_at);

CREATE INDEX IF NOT EXISTS idx_external_agent_registrations_revoked_by
    ON public.external_agent_registrations (tenant_id, revoked_by_subject)
    WHERE enrollment_status = 'revoked';

COMMIT;
-- END 041_external_host_revocation.sql

-- BEGIN 042_external_agent_evidence.sql
-- Migration: 042_external_agent_evidence.sql
-- Storage and tenant-scoped projections for external agent evidence (AMXO-P5-3).
--
-- Idempotent: CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS.

BEGIN;

CREATE TABLE IF NOT EXISTS public.external_agent_evidence (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           TEXT        NOT NULL,
    agent_id            TEXT        NOT NULL,
    session_id          TEXT        NOT NULL,
    evidence_type       TEXT        NOT NULL,
    source              TEXT        NOT NULL DEFAULT 'agentmaxxing-host-sensor',
    observed_at         TIMESTAMPTZ NOT NULL,
    attributable_actor  TEXT        NOT NULL,
    spiffe_id           TEXT        NOT NULL,
    landlock_abi        INTEGER     NOT NULL DEFAULT 0,
    git_oid             TEXT,
    attributes          JSONB       NOT NULL DEFAULT '{}'::jsonb,
    hash_chain_digest   TEXT        NOT NULL,
    verified            BOOLEAN     NOT NULL DEFAULT true,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_external_agent_evidence_tenant_agent
    ON public.external_agent_evidence (tenant_id, agent_id, observed_at DESC);

CREATE INDEX IF NOT EXISTS idx_external_agent_evidence_session
    ON public.external_agent_evidence (tenant_id, session_id);

CREATE INDEX IF NOT EXISTS idx_external_agent_evidence_type
    ON public.external_agent_evidence (tenant_id, evidence_type);

COMMIT;
-- END 042_external_agent_evidence.sql

-- BEGIN 043_eap_environment_lifecycle.sql
-- Durable EAP environment lifecycle, teardown checkpoints, worker leases, and outbox.
BEGIN;

CREATE TABLE IF NOT EXISTS public.eap_environment_lifecycle (
    customer_hash                 TEXT        PRIMARY KEY
        CHECK (customer_hash ~ '^[0-9a-f]{8}$'),
    company_name                  TEXT        NOT NULL,
    state                         TEXT        NOT NULL
        CHECK (state IN ('provisioning', 'warming', 'active', 'draining', 'teardown_failed', 'terminated')),
    created_at                    TIMESTAMPTZ NOT NULL,
    last_heartbeat_at             TIMESTAMPTZ NOT NULL,
    last_activity_at              TIMESTAMPTZ NOT NULL,
    expires_at                    TIMESTAMPTZ NOT NULL,
    max_lifetime_expires_at       TIMESTAMPTZ NOT NULL,
    grace_period_expires_at       TIMESTAMPTZ,
    reap_reason                   TEXT,
    teardown_id                   TEXT,
    teardown_stages_completed     TEXT[]      NOT NULL DEFAULT '{}',
    retry_count                   INTEGER     NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    next_retry_at                 TIMESTAMPTZ,
    last_error                    TEXT,
    claim_owner                   TEXT,
    claim_expires_at              TIMESTAMPTZ,
    version                       BIGINT      NOT NULL DEFAULT 1 CHECK (version > 0),
    updated_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK ((claim_owner IS NULL) = (claim_expires_at IS NULL))
);

CREATE INDEX IF NOT EXISTS idx_eap_lifecycle_reaper_due
    ON public.eap_environment_lifecycle (state, next_retry_at, grace_period_expires_at)
    WHERE state IN ('draining', 'teardown_failed');

CREATE TABLE IF NOT EXISTS public.eap_lifecycle_outbox (
    event_id       UUID        PRIMARY KEY,
    customer_hash  TEXT        NOT NULL REFERENCES public.eap_environment_lifecycle(customer_hash),
    event_type     TEXT        NOT NULL,
    occurred_at    TIMESTAMPTZ NOT NULL,
    payload        JSONB       NOT NULL,
    published_at   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_eap_lifecycle_outbox_unpublished
    ON public.eap_lifecycle_outbox (occurred_at)
    WHERE published_at IS NULL;

COMMIT;
-- END 043_eap_environment_lifecycle.sql

-- BEGIN 044_eap_lifecycle_fencing.sql
-- Migration 044: Add claim fencing token to EAP environment lifecycle and index outbox by customer_hash
BEGIN;

ALTER TABLE public.eap_environment_lifecycle
    ADD COLUMN IF NOT EXISTS claim_fencing_token BIGINT NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_eap_lifecycle_outbox_customer_hash
    ON public.eap_lifecycle_outbox (customer_hash);

COMMIT;
-- END 044_eap_lifecycle_fencing.sql

-- BEGIN 045_eap_audit_event_types.sql
-- 045 — EAP on-demand environment lifecycle and isolation audit event types
--
-- Extends the permitted audit_events vocabulary with 10 EAP lifecycle, routing,
-- tenant isolation, scenario seeding, and webhook trigger event types.
-- Replaces audit_events_event_type_check with the combined vocabulary.

BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
          )) NOT LIKE '%eap_environment.registered%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%eap_environment.registered%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stunned',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 045_eap_audit_event_types.sql

-- BEGIN 046_agent_stun_failed_event_type.sql
-- 046 — admit 'agent.stun_failed'
--
-- POST /api/agents/{id}/stun used to record every attempt as 'agent.stunned',
-- including 404s and 502s where nothing was isolated, so a filter for stuns
-- returned failures as if they were containments. Failed attempts are now
-- 'agent.stun_failed' (17 characters; event_type is VARCHAR(30)).
-- Replaces audit_events_event_type_check with 045's vocabulary plus this type.

BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
          )) NOT LIKE '%agent.stun_failed%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%agent.stun_failed%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stunned',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 046_agent_stun_failed_event_type.sql

-- BEGIN 047_agent_stun_simulated_event_type.sql
-- 047 — admit 'agent.stun_simulated'
--
-- With FLEET_MANAGER_URL empty no fleet-manager is asked, so nothing is
-- isolated and lifecycle state must not move. Such attempts are recorded as
-- 'agent.stun_simulated' (20 characters; event_type is VARCHAR(30)), apart
-- from real stuns and real failures. Replaces audit_events_event_type_check
-- with 046's vocabulary plus this type.

BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
          )) NOT LIKE '%agent.stun_simulated%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%agent.stun_simulated%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stun_simulated',
        'agent.stunned',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 047_agent_stun_simulated_event_type.sql

-- BEGIN 048_upstream_request_event_types.sql
-- 048 — admit the three upstream-request audit types
--
-- Policy bundle registration and rollback happen in the policy-engine, and a
-- cluster scan is queued in KubeSec-AFM, so fe-signalloom records the request
-- before forwarding it: 'policy.bundle_submitted', 'policy.rollback_requested'
-- and 'rbac.scan_requested'. (event_type has been TEXT since 032; the
-- VARCHAR(30) mentioned in 046 and 047 predates that.) Replaces
-- audit_events_event_type_check with 047's vocabulary plus these types.

BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
          )) NOT LIKE '%rbac.scan_requested%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%rbac.scan_requested%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stun_simulated',
        'agent.stunned',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'policy.bundle_submitted',
        'policy.rollback_requested',
        'rbac.scan_requested',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 048_upstream_request_event_types.sql

-- BEGIN 049_agent_transition_failed_event_type.sql
-- 049 — admit 'agent.transition_failed'
--
-- A lifecycle transition requested for an agent that does not exist used to be
-- audited as 'agent.transitioned' "registered -> X" and answered 200, so the
-- trail recorded moves that never happened. The attempt is still recorded, as
-- 'agent.transition_failed' with detail.outcome 'not_found', and answers 404.
-- Kept apart from 'agent.transitioned' for the reason 046 split out
-- 'agent.stun_failed': a filter for transitions must not return refusals.
-- Replaces audit_events_event_type_check with 048's vocabulary plus this type.

BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
          )) NOT LIKE '%agent.transition_failed%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%agent.transition_failed%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stun_simulated',
        'agent.stunned',
        'agent.transition_failed',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'policy.bundle_submitted',
        'policy.rollback_requested',
        'rbac.scan_requested',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 049_agent_transition_failed_event_type.sql

-- BEGIN 050_afm_cluster_import_event_type.sql
-- 050 — admit 'afm.cluster_import_requested'
--
-- AFM cluster models are imported through fe-signalloom's authenticated gateway,
-- so fe-signalloom records the outbound mutation request before forwarding it:
-- 'afm.cluster_import_requested'. (event_type has been TEXT since 032; the
-- VARCHAR(30) mentioned in 046 and 047 predates that.) Replaces
-- audit_events_event_type_check with 049's vocabulary plus this type.

BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
          )) NOT LIKE '%afm.cluster_import_requested%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%afm.cluster_import_requested%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'afm.cluster_import_requested',
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stun_simulated',
        'agent.stunned',
        'agent.transition_failed',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'policy.bundle_submitted',
        'policy.rollback_requested',
        'rbac.scan_requested',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 050_afm_cluster_import_event_type.sql

-- BEGIN 051_batch_chain_event_type.sql
-- 051 — admit 'batch_chain' in signal_audit_trail
--
-- Signal-ingest verifies D10 batch chain headers and records anomalies, replays,
-- and unchained batches in signal_audit_trail under event_type 'batch_chain'.
-- Replaces the signal_audit_trail event_type check constraint with 031's vocabulary
-- plus 'batch_chain'.

BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.signal_audit_trail'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.signal_audit_trail'::regclass
              AND con.conname = constraint_name
         )) NOT LIKE '%batch_chain%'
  THEN
    EXECUTE format('ALTER TABLE public.signal_audit_trail DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.signal_audit_trail'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%batch_chain%'
  ) THEN
    ALTER TABLE public.signal_audit_trail
      ADD CONSTRAINT signal_audit_trail_event_type_check
      CHECK (event_type IN (
        'actor_created',
        'actor_dismissed',
        'actor_promoted',
        'actor_updated',
        'batch_chain',
        'collector_run',
        'correlation_run',
        'observation_ingested',
        'partition_dropped'
      ));
  END IF;
END $body$;

COMMIT;
-- END 051_batch_chain_event_type.sql

-- BEGIN 052_fleet_operator_event_types.sql
-- 052 — admit 'fleet.recover_requested' and 'fleet.resume_requested'
--
-- recover and resume belong to fleet-manager's 'operator' break-glass caller key
-- alone, so the dashboard could not call them and the Fleet page's Recover
-- button answered 403 for everyone. fe-signalloom now proxies both behind
-- require_superadmin and presents the operator key server-side
-- (src/fleet_operator.py), recording the outbound request before forwarding it:
-- 'fleet.recover_requested' and 'fleet.resume_requested'. The events name a
-- request, not an outcome; the outcome belongs to fleet-manager. Replaces
-- audit_events_event_type_check with 050's vocabulary plus these two.

BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
          )) NOT LIKE '%fleet.recover_requested%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%fleet.recover_requested%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'afm.cluster_import_requested',
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stun_simulated',
        'agent.stunned',
        'agent.transition_failed',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'fleet.recover_requested',
        'fleet.resume_requested',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'policy.bundle_submitted',
        'policy.rollback_requested',
        'rbac.scan_requested',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 052_fleet_operator_event_types.sql

-- BEGIN 053_invites_and_subject_tenants.sql
-- 053 — self-service invites and a server-side subject-to-tenant binding
--
-- Until now the only way a Dex subject reached a tenant was the
-- API_SUBJECT_TENANTS environment variable of the fe-signalloom Deployment: a
-- new pilot user was a Dex config edit plus a subject-map edit plus a rollout.
-- These two tables give the portal a data path for the second edit.
--
-- invites: one row per invitation a superadmin issued. Only the sha256 of the
-- one-time token is stored; the token itself is shown once in the response to
-- POST /api/v1/invites and never again. A row is spent when redeemed_at is set
-- and dead when expires_at has passed.
--
-- subject_tenants: the binding authenticated_principal consults BEFORE the
-- environment map. The column is named `tenant`, not `tenant_id`, on purpose:
-- tests/test_tenant_isolation.py derives its tenant-owned table set from
-- `tenant_id` columns and requires every statement against such a table to be
-- bound to the caller's tenant. Neither table is reachable by tenant: a subject
-- lookup is keyed by subject, an invite by its token hash, and the superadmin
-- who lists or creates invites is acting across tenants by design. Access is
-- gated by require_superadmin (create, list) and by the verified token subject
-- (redeem), never by a tenant predicate.

BEGIN;

CREATE TABLE IF NOT EXISTS public.invites (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash      TEXT        NOT NULL UNIQUE CHECK (btrim(token_hash) <> ''),
    email           TEXT        NOT NULL CHECK (btrim(email) <> ''),
    tenant          TEXT        NOT NULL CHECK (btrim(tenant) <> ''),
    created_by      TEXT        NOT NULL CHECK (btrim(created_by) <> ''),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL,
    redeemed_by     TEXT,
    redeemed_at     TIMESTAMPTZ,
    CONSTRAINT invites_redeemed_together CHECK (
        (redeemed_by IS NULL AND redeemed_at IS NULL)
        OR (redeemed_by IS NOT NULL AND redeemed_at IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS invites_tenant_created_at_idx
    ON public.invites (tenant, created_at DESC);

CREATE TABLE IF NOT EXISTS public.subject_tenants (
    subject         TEXT        PRIMARY KEY CHECK (btrim(subject) <> ''),
    tenant          TEXT        NOT NULL CHECK (btrim(tenant) <> ''),
    bound_via       TEXT        NOT NULL CHECK (bound_via IN ('invite', 'operator')),
    bound_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMIT;
-- END 053_invites_and_subject_tenants.sql

-- BEGIN 054_invite_event_types.sql
-- 054 — admit 'invite.created' and 'invite.redeemed'
--
-- Migration 053 added self-service invites. A superadmin issuing an invite and
-- a subject redeeming one are both authorisation changes, so each is audited:
-- 'invite.created' is filed under the invite's tenant by the issuing
-- superadmin, 'invite.redeemed' under the tenant the subject is now bound to.
-- Replaces audit_events_event_type_check with 052's vocabulary plus these two,
-- on 052's pattern: drop the constraint only if it lacks the new type, recreate
-- it only if absent.
BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
          )) NOT LIKE '%fleet.recover_requested%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%fleet.recover_requested%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'afm.cluster_import_requested',
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stun_simulated',
        'agent.stunned',
        'agent.transition_failed',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'fleet.recover_requested',
        'fleet.resume_requested',
        'invite.created',
        'invite.redeemed',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'policy.bundle_submitted',
        'policy.rollback_requested',
        'rbac.scan_requested',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 054_invite_event_types.sql

-- BEGIN 055_actor_promote_event_type.sql
-- 055 — admit 'actor.promote_requested'
--
-- The Weave page's Promote button now reaches signal-ingest's
-- POST /api/v1/actors/{id}/promote through fe-signalloom's existing proxy
-- (src/signal_fusion.py promote_actor), now superadmin-gated, with the gateway
-- key presented server-side. The request is
-- recorded before it is forwarded, under the caller's own tenant, on the
-- pattern of 'fleet.recover_requested': the event names a request, not an
-- outcome; the outcome ('actor_promoted') belongs to signal-ingest's own
-- audit trail. Replaces audit_events_event_type_check with 054's vocabulary
-- plus this type, on 052's pattern.
BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
          )) NOT LIKE '%fleet.recover_requested%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%fleet.recover_requested%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'afm.cluster_import_requested',
        'actor.promote_requested',
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stun_simulated',
        'agent.stunned',
        'agent.transition_failed',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'fleet.recover_requested',
        'fleet.resume_requested',
        'invite.created',
        'invite.redeemed',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'policy.bundle_submitted',
        'policy.rollback_requested',
        'rbac.scan_requested',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 055_actor_promote_event_type.sql

-- BEGIN 056_cross_tenant_read_event_type.sql
-- 056 — admit 'audit.cross_tenant_read'
--
-- A superadmin keeps its cross-tenant view for the pilot (Andy, 2026-10-06),
-- but every read whose response discloses another tenant's data now writes
-- one audit event naming it (cross_tenant_audit.audit_cross_tenant_read,
-- called from the signal_fusion/signal_policy/invites/cadvisor_poller
-- read routes that can act for every tenant). Replaces
-- audit_events_event_type_check with 055's vocabulary plus this type, on
-- 055's own pattern.
BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
          )) NOT LIKE '%audit.cross_tenant_read%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%audit.cross_tenant_read%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'afm.cluster_import_requested',
        'actor.promote_requested',
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stun_simulated',
        'agent.stunned',
        'agent.transition_failed',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'audit.cross_tenant_read',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'fleet.recover_requested',
        'fleet.resume_requested',
        'invite.created',
        'invite.redeemed',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'policy.bundle_submitted',
        'policy.rollback_requested',
        'rbac.scan_requested',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 056_cross_tenant_read_event_type.sql

-- BEGIN 057_tenant_feature_flags.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 057 — tenant-scoped feature flags for granular surface scoping and gating
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Provides tenant-scoped feature flags with JSONB configuration payloads.
-- Guarantees strict multi-tenant isolation, default evaluation fallbacks,
-- and sub-millisecond lookups via composite primary key (tenant_id, flag_key).

BEGIN;

CREATE TABLE IF NOT EXISTS public.tenant_feature_flags (
    tenant_id   VARCHAR(128) NOT NULL,
    flag_key    VARCHAR(128) NOT NULL,
    enabled     BOOLEAN      NOT NULL DEFAULT FALSE,
    config_json JSONB        NOT NULL DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, flag_key)
);

CREATE INDEX IF NOT EXISTS idx_tenant_feature_flags_tenant
    ON public.tenant_feature_flags (tenant_id, flag_key);

COMMIT;
-- END 057_tenant_feature_flags.sql

-- BEGIN 058_platform_users_superadmin.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 058 — platform_users superadmin flag and partial index
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Adds is_superadmin boolean column to public.platform_users defaulting to FALSE.
-- Adds partial index on platform_users(email) WHERE is_superadmin = TRUE for fast
-- privileged account lookup without scanning ordinary user records.

BEGIN;

ALTER TABLE public.platform_users
    ADD COLUMN IF NOT EXISTS is_superadmin BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_platform_users_superadmin
    ON public.platform_users (email)
    WHERE is_superadmin = TRUE;

COMMIT;
-- END 058_platform_users_superadmin.sql

-- BEGIN 059_user_admin_audit_event_types.sql
-- 059 — admit user admin lifecycle audit event types
--
-- Adds audit event types for platform user administration CRUD endpoints:
-- 'user.invited', 'user.updated', 'user.role_updated', 'user.status_updated', 'user.deleted'.
-- Replaces audit_events_event_type_check with 056's vocabulary plus these types.
BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
         )) NOT LIKE '%user.invited%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%user.invited%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'afm.cluster_import_requested',
        'actor.promote_requested',
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stun_simulated',
        'agent.stunned',
        'agent.transition_failed',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'audit.cross_tenant_read',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'fleet.recover_requested',
        'fleet.resume_requested',
        'invite.created',
        'invite.redeemed',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'policy.bundle_submitted',
        'policy.rollback_requested',
        'rbac.scan_requested',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user.deleted',
        'user.invited',
        'user.role_updated',
        'user.status_updated',
        'user.updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 059_user_admin_audit_event_types.sql

-- BEGIN 060_seed_design_partner_presets.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 060: seed design partner presets (Kusari and tenant-demo) and initial superadmin
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Seeds default feature flags for design partner tenant 'kusari':
--   - Enabled: core_governance, audit, compliance
--   - Disabled: demos_fleet, supercred, rbac_analysis, collusion_access
--
-- Seeds default feature flags for demonstration tenant 'tenant-demo':
--   - Enabled: core_governance, audit, compliance, demos_fleet, supercred, rbac_analysis, collusion_access
--
-- Seeds initial platform superadmin accounts:
--   - demo-user@signalloom.local (tenant: tenant-demo, is_superadmin: true)
--   - admin@kusari.demo (tenant: kusari, is_superadmin: true)
--
-- All inserts use ON CONFLICT clauses to ensure strict forward-only idempotency.

BEGIN;

-- 1. Seed Kusari and Tenant-Demo Feature Flags
INSERT INTO public.tenant_feature_flags (
    tenant_id,
    flag_key,
    enabled,
    config_json,
    created_at,
    updated_at
) VALUES
    ('kusari', 'core_governance', TRUE,  '{"description": "Core governance policies, agent registry, and guardrails"}'::jsonb, NOW(), NOW()),
    ('kusari', 'audit',           TRUE,  '{"description": "Authoritative immutable audit log and provenance stream"}'::jsonb, NOW(), NOW()),
    ('kusari', 'compliance',      TRUE,  '{"description": "Compliance posture dashboards and regulatory framework evaluation"}'::jsonb, NOW(), NOW()),
    ('kusari', 'demos_fleet',     FALSE, '{"description": "Demo fleet simulation scenarios and testing controls"}'::jsonb, NOW(), NOW()),
    ('kusari', 'supercred',       FALSE, '{"description": "SuperCred privilege escalation demonstration surfaces"}'::jsonb, NOW(), NOW()),
    ('kusari', 'rbac_analysis',   FALSE, '{"description": "Experimental AFM formal RBAC graph visualization"}'::jsonb, NOW(), NOW()),
    ('kusari', 'collusion_access',FALSE, '{"description": "Experimental multi-agent collusion detection matrix"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'core_governance', TRUE,  '{"description": "Core governance policies, agent registry, and guardrails"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'audit',           TRUE,  '{"description": "Authoritative immutable audit log and provenance stream"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'compliance',      TRUE,  '{"description": "Compliance posture dashboards and regulatory framework evaluation"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'demos_fleet',     TRUE,  '{"description": "Demo fleet simulation scenarios and testing controls"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'supercred',       TRUE,  '{"description": "SuperCred privilege escalation demonstration surfaces"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'rbac_analysis',   TRUE,  '{"description": "Experimental AFM formal RBAC graph visualization"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'collusion_access',TRUE,  '{"description": "Experimental multi-agent collusion detection matrix"}'::jsonb, NOW(), NOW())
ON CONFLICT (tenant_id, flag_key) DO UPDATE SET
    enabled = EXCLUDED.enabled,
    config_json = EXCLUDED.config_json,
    updated_at = NOW();

-- 2. Seed Initial Platform Superadmin Users
-- Uses stable UUIDs for deterministic bootstrap reconciliation.
INSERT INTO public.platform_users (
    id,
    tenant_id,
    email,
    display_name,
    role,
    status,
    department,
    title,
    is_superadmin,
    created_at,
    updated_at
) VALUES
    (
        'a0000000-0000-0000-0000-000000000000',
        'tenant-demo',
        'demo-user@signalloom.local',
        'Platform Superadmin',
        'admin',
        'active',
        'Platform Engineering',
        'Superadmin Operator',
        TRUE,
        NOW(),
        NOW()
    ),
    (
        'a0000000-0000-0000-0000-000000000001',
        'kusari',
        'admin@kusari.demo',
        'Kusari Admin',
        'admin',
        'active',
        'Security Operations',
        'Design Partner Lead',
        TRUE,
        NOW(),
        NOW()
    )
ON CONFLICT (tenant_id, email) DO UPDATE SET
    role = EXCLUDED.role,
    status = EXCLUDED.status,
    is_superadmin = EXCLUDED.is_superadmin,
    updated_at = NOW();

-- Ensure any preexisting record for seeded superadmins is also elevated
UPDATE public.platform_users
SET is_superadmin = TRUE,
    role = 'admin',
    status = 'active',
    updated_at = NOW()
WHERE email IN ('demo-user@signalloom.local', 'admin@kusari.demo');

COMMIT;
-- END 060_seed_design_partner_presets.sql

-- BEGIN 061_policy_check_mapping.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 061 — stable mapping from governance controls to policy-engine checks
-- ══════════════════════════════════════════════════════════════════════════════
--
-- The policy scan reconciles each engine verdict onto agent_compliance_results.
-- Before this migration it matched the engine's check id / control name against
-- governance_controls.name / id, which never matched a seeded row and, when it
-- did, stamped one verdict on every agent's row.
--
--   governance_controls.policy_framework_id  policy-engine pack id
--                                            (e.g. 'cis-kubernetes', 'finos-aigf')
--   governance_controls.policy_check_id      check id inside that pack
--                                            (e.g. 'no-privileged-containers')
--       Both NULL for controls no engine check evaluates.  Unique per tenant,
--       so a verdict maps to at most one control.
--
--   agent_registry.workload_spec             the agent's Kubernetes workload
--                                            (Pod, or a controller with a pod
--                                            template); the scan's CEL `object`.
--                                            NULL when none is recorded: the scan
--                                            then sends no object, it never
--                                            invents one.
--
--   agent_compliance_results.status          gains 'error': the check could not
--                                            evaluate.  Never a pass, never a fail.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS, and the
-- status CHECK is dropped and re-added under its original name.

BEGIN;

ALTER TABLE public.governance_controls
    ADD COLUMN IF NOT EXISTS policy_framework_id TEXT,
    ADD COLUMN IF NOT EXISTS policy_check_id     TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS uq_governance_controls_policy_check
    ON public.governance_controls (tenant_id, policy_framework_id, policy_check_id)
    WHERE policy_framework_id IS NOT NULL AND policy_check_id IS NOT NULL;

ALTER TABLE public.agent_registry
    ADD COLUMN IF NOT EXISTS workload_spec JSONB;

ALTER TABLE public.agent_compliance_results
    DROP CONSTRAINT IF EXISTS agent_compliance_results_status_check;
ALTER TABLE public.agent_compliance_results
    ADD CONSTRAINT agent_compliance_results_status_check
    CHECK (status IN ('pass', 'fail', 'error', 'pending', 'reassessment_requested'));

COMMIT;
-- END 061_policy_check_mapping.sql

-- BEGIN 062_tenant_risk_profile.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 062 — the risk profile a tenant DECLARES about itself at onboarding
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Backs PATCH /api/tenant/settings/risk-profile and the identity step of the
-- onboarding wizard, which until now collected an organisation profile
-- (organizationName, workspaceId, adminEmail, environment, description) and
-- threw every field away — it never reached wizard_state, let alone a column.
--
-- ── What these five columns are, and why they are these five ────────────────
--
-- They are the subset of `OrgRiskPosture` (tools/riskctl/internal/model/
-- model.go) that an institution can honestly state about ITSELF on day one:
--
--   risk/org/acme.yaml field          column here
--   ────────────────────────────────  ──────────────────────────
--   metadata.sector                   sector
--   metadata.jurisdiction             jurisdiction
--   currency                          reporting_currency
--   appetite.tolerance                risk_appetite_tolerance
--   risk_load                         risk_load
--
-- Deliberately NOT here: the per-scenario `magnitude` triples. Those are the
-- institution's half of the pricing split (acme.yaml:3-6 — the policy pack owns
-- loss event FREQUENCY, the institution owns loss MAGNITUDE), and every one of
-- them carries MANDATORY `provenance` prose because an unsourced number is not
-- reviewable. A wizard cannot elicit a calibrated triple with a defensible
-- anchor class from someone clicking through onboarding, and a fabricated
-- triple is strictly worse than no triple: it would price agent risk in pounds
-- that nobody can argue with because nobody wrote down where they came from.
-- Magnitudes stay in reviewed, version-controlled YAML.
--
-- ── Typed columns on tenant_settings, not EAV and not wizard_state ──────────
--
-- Three doctrines in this schema already decided the shape:
--
--   * 020_user_preferences.sql:40-44 — "a preference worth storing is worth
--     declaring". Not a key/value EAV table: typed columns can carry a CHECK,
--     a shared TEXT `value` column never can.
--   * 006_onboarding.sql:14-24 — org configuration does NOT belong on
--     tenant_onboarding. wizard_state churns on every step change; this is
--     stable org configuration and belongs on the stable row.
--   * 005_tenant_scan_preferences.sql — the exact precedent for adding a
--     declared field to tenant_settings via an onboarding step.
--
-- ── EVERY COLUMN IS NULLABLE, WITH NO DEFAULT. That is load-bearing ─────────
--
-- A tenant that declines to declare must stay valid, and must stay
-- INDISTINGUISHABLE FROM ONE THAT HAS NOT BEEN ASKED. There is deliberately no
-- `DEFAULT 0.10` for risk_load and no `DEFAULT 'GBP'` for reporting_currency,
-- even though those are the values the engine uses today, because a default
-- here would be a posture the tenant never stated — and the moment it is a
-- column with a value, something downstream will price with it. NULL means
-- "undeclared", the engine falls back to its own documented constant, and no
-- existing figure moves unless a tenant opts in.
--
-- The jurisdiction semantics follow from the same reasoning and are NOT
-- invented here: `Scenario.AppliesTo` (model.go:153-163) excludes a scoped
-- scenario when the institution states no jurisdiction, rather than assuming
-- it applies. Silence must never read as a match. So NULL here scopes NOTHING,
-- which is why '*' is spellable — declaring global operation is an affirmative
-- act and is not the same as saying nothing.
--
-- ── Why the currency CHECK is a shape check, and what it is NOT ─────────────
--
-- `^[A-Z]{3}$` is a FLOOR, not the real validation. The binding constraint is
-- the FX rate table (risk/fx/rates.yaml): a currency with no rate renders every
-- figure as Unavailable. The closed set lives in the handler as
-- SUPPORTED_DISPLAY_CURRENCIES, which tests/test_user_currency_renderable.py
-- holds equal to SUPPORTED_CURRENCIES in currency.ts. Both layers exist on
-- purpose:
--
--   * the handler's closed set stops a renderable-but-unpriceable code (XXX is
--     a real ISO assignment meaning "no currency"; XAU is gold);
--   * this CHECK binds EVERY writer, including a migration, a fixture or a
--     psql session that never passes through the handler.
--
-- The failure this prevents is not a 500. Intl.NumberFormat RENDERS an
-- unrecognised code instead of throwing, so an unvalidated code arrives on
-- screen looking like real money (020_user_preferences.sql makes the same
-- point about display_currency).
--
-- ── Why `< 'Infinity'` and not just `>= 0` ──────────────────────────────────
--
-- PostgreSQL sorts NaN ABOVE every other value, so `'NaN'::float8 >= 0` is TRUE
-- and `'NaN'::numeric > 0` is TRUE. A naive non-negativity check therefore
-- admits NaN, which then propagates through `tvar * (1 + risk_load)` and yields
-- a carried figure that passes every structural check and is not a number
-- anyone can use — the same trap LoadOrgRiskPosture guards with
-- math.IsNaN/IsInf at the YAML boundary. `< 'Infinity'` is what rejects it,
-- because NaN compares as greater than Infinity, and it excludes +Inf in the
-- same breath. Verified against postgres:16 rather than reasoned about.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + guarded constraint creation, the same
-- shape as 005.

BEGIN;

ALTER TABLE IF EXISTS public.tenant_settings
    ADD COLUMN IF NOT EXISTS sector                  TEXT,
    ADD COLUMN IF NOT EXISTS jurisdiction            TEXT,
    ADD COLUMN IF NOT EXISTS reporting_currency      TEXT,
    ADD COLUMN IF NOT EXISTS risk_appetite_tolerance NUMERIC(20, 2),
    ADD COLUMN IF NOT EXISTS risk_load               DOUBLE PRECISION;

DO $body$ BEGIN
  IF to_regclass('public.tenant_settings') IS NULL THEN
    RETURN;
  END IF;

  -- An ISO-4217-shaped code, or nothing. See the header for why this is a floor
  -- and not the whole validation.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_settings_reporting_currency_shape'
  ) THEN
    ALTER TABLE public.tenant_settings
      ADD CONSTRAINT tenant_settings_reporting_currency_shape
      CHECK (reporting_currency IS NULL OR reporting_currency ~ '^[A-Z]{3}$');
  END IF;

  -- Finite and non-negative. Zero is a coherent posture: carry the tail with no
  -- load on top.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_settings_risk_load_finite_non_negative'
  ) THEN
    ALTER TABLE public.tenant_settings
      ADD CONSTRAINT tenant_settings_risk_load_finite_non_negative
      CHECK (
        risk_load IS NULL
        OR (risk_load >= 0 AND risk_load < 'Infinity'::double precision)
      );
  END IF;

  -- Strictly positive when stated: without a tolerance band a number cannot
  -- become a verdict (model.go, appetite.tolerance).
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_settings_risk_appetite_tolerance_positive'
  ) THEN
    ALTER TABLE public.tenant_settings
      ADD CONSTRAINT tenant_settings_risk_appetite_tolerance_positive
      CHECK (
        risk_appetite_tolerance IS NULL
        OR (risk_appetite_tolerance > 0 AND risk_appetite_tolerance < 'Infinity'::numeric)
      );
  END IF;

  -- A blank string must not be storable as though it were a declaration. A
  -- whitespace-only jurisdiction trims to empty, which AppliesTo treats as "no
  -- jurisdiction stated" — so it would behave as NULL while reading as declared.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_settings_sector_non_blank'
  ) THEN
    ALTER TABLE public.tenant_settings
      ADD CONSTRAINT tenant_settings_sector_non_blank
      CHECK (sector IS NULL OR btrim(sector) <> '');
  END IF;

  -- Canonical form, so 'uk' and 'UK' cannot both exist. AppliesTo compares
  -- case-insensitively and trimmed, so storing both buys nothing and makes two
  -- rows that differ only by case — a data trap, not a feature (model.go:147).
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_settings_jurisdiction_canonical'
  ) THEN
    ALTER TABLE public.tenant_settings
      ADD CONSTRAINT tenant_settings_jurisdiction_canonical
      CHECK (
        jurisdiction IS NULL
        OR (btrim(jurisdiction) <> '' AND jurisdiction = upper(btrim(jurisdiction)))
      );
  END IF;
END $body$;

COMMIT;
-- END 062_tenant_risk_profile.sql

-- BEGIN 063_tenant_risk_profile_audit_event_type.sql
-- 063 — admit the 'tenant.risk_profile_updated' audit event type
--
-- PATCH /api/tenant/settings/risk-profile audits its write, because the
-- declared profile changes what the tenant's risk is priced against and a
-- later "why did our figures move" has to be answerable from the trail.
--
-- WHY THIS MIGRATION IS NOT OPTIONAL, stated plainly because the failure is
-- nastier than a rejected insert: audit_events carries a CHECK on event_type,
-- so an unlisted type raises CheckViolationError at runtime.  The handler
-- performs its UPDATE and its _audit_log INSERT inside one transaction, but
-- the shape of the failure is still bad — the write is attempted, the audit
-- insert raises, and the endpoint returns 500 to a caller who cannot tell
-- whether the declaration landed.  tests/test_audit_event_types.py asserts
-- every type _audit_log can emit is permitted by this constraint, which is how
-- this was caught before it ran anywhere.
--
-- Replaces audit_events_event_type_check with 059's vocabulary plus this type.
-- Same guarded shape as 059: the new type is its own sentinel, so re-running is
-- a no-op and a database already carrying it is left alone.
BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
         )) NOT LIKE '%tenant.risk_profile_updated%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%tenant.risk_profile_updated%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'afm.cluster_import_requested',
        'actor.promote_requested',
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stun_simulated',
        'agent.stunned',
        'agent.transition_failed',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'audit.cross_tenant_read',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'fleet.recover_requested',
        'fleet.resume_requested',
        'invite.created',
        'invite.redeemed',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'policy.bundle_submitted',
        'policy.rollback_requested',
        'rbac.scan_requested',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant.risk_profile_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user.deleted',
        'user.invited',
        'user.role_updated',
        'user.status_updated',
        'user.updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 063_tenant_risk_profile_audit_event_type.sql

-- BEGIN 064_backfill_claimed_agent_ownership.sql
-- Migration 064: Backfill claimed agent ownership from explicit assignment evidence.
-- Audit actors are operators, not necessarily owners. Unknown owners stay unattributed.

BEGIN;

-- A valid existing owner_id is authoritative. Keep its display text consistent.
UPDATE public.agent_registry ar
SET owner = pu.email
FROM public.platform_users pu
WHERE ar.owner_id = pu.id
  AND pu.tenant_id = ar.tenant_id
  AND NULLIF(BTRIM(ar.tenant_id), '') IS NOT NULL
  AND ar.owner IS DISTINCT FROM pu.email;

WITH ownership_evidence AS (
    SELECT DISTINCT ON (ac.agent_id, ac.tenant_id)
           ac.agent_id,
           ac.tenant_id,
           COALESCE(
               NULLIF(BTRIM(ae.detail->>'assigned_owner'), ''),
               NULLIF(BTRIM(ae.detail->>'owner'), '')
           ) AS assigned_owner
    FROM public.agent_claims ac
    JOIN public.audit_events ae
      ON ae.agent_id = ac.agent_id
     AND ae.tenant_id = ac.tenant_id
     AND (
          (ae.event_type = 'agent.created' AND ae.detail->>'action' = 'claimed')
          OR ae.event_type = 'agent.claimed'
     )
    WHERE ac.status = 'granted'
      AND NULLIF(BTRIM(ac.tenant_id), '') IS NOT NULL
      AND COALESCE(
              NULLIF(BTRIM(ae.detail->>'assigned_owner'), ''),
              NULLIF(BTRIM(ae.detail->>'owner'), '')
          ) IS NOT NULL
    ORDER BY ac.agent_id, ac.tenant_id, ae.timestamp DESC
)
UPDATE public.agent_registry ar
SET owner = pu.email,
    owner_id = pu.id
FROM ownership_evidence evidence
JOIN public.platform_users pu
  ON LOWER(pu.email) = LOWER(evidence.assigned_owner)
 AND pu.tenant_id = evidence.tenant_id
WHERE ar.id = evidence.agent_id
  AND ar.tenant_id = evidence.tenant_id
  AND NULLIF(BTRIM(ar.tenant_id), '') IS NOT NULL
  AND ar.owner_id IS NULL
  AND (ar.owner IS NULL OR BTRIM(ar.owner) = '');

COMMIT;
-- END 064_backfill_claimed_agent_ownership.sql

-- BEGIN 065_seed_granular_page_flags.sql
-- ══════════════════════════════════════════════════════════════════════════════
-- 065: seed granular page feature flags for design partner (kusari) and demo
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Seeds granular page flags for design partner tenant 'kusari' (EAP Pilot Preset):
--   - Enabled: page_discovery, page_agents, page_topology, page_weave, page_signals,
--              page_risk, page_policies, page_compliance, page_audit,
--              page_federated_services, page_cryptography, page_credential_inventory
--   - Disabled: page_signal_store, page_feeds, page_network_tests, page_agentmaxxing
--
-- Seeds granular page flags for demonstration tenant 'tenant-demo' (Full Demo Preset):
--   - Enabled: all granular page flags
--
-- Idempotent upserts via ON CONFLICT (tenant_id, flag_key).

BEGIN;

INSERT INTO public.tenant_feature_flags (
    tenant_id,
    flag_key,
    enabled,
    config_json,
    created_at,
    updated_at
) VALUES
    -- Kusari EAP Pilot Granular Flags (Operational & Governance enabled, Labs disabled)
    ('kusari', 'page_discovery',            TRUE,  '{"description": "Workload discovery and accounts inventory"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_agents',               TRUE,  '{"description": "Governed agent registry and state details"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_topology',             TRUE,  '{"description": "Agent trust topology and communication graph"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_weave',                TRUE,  '{"description": "Real-time agent interaction weave"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_signals',              TRUE,  '{"description": "Live agent signal stream and anomalies"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_risk',                 TRUE,  '{"description": "Risk exposure and vulnerability tracking"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_policies',             TRUE,  '{"description": "Agent governance policies and guardrail rules"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_compliance',           TRUE,  '{"description": "Regulatory posture and compliance frameworks"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_audit',                TRUE,  '{"description": "Immutable audit trail and provenance verification"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_federated_services',   TRUE,  '{"description": "Federated AI services and model connectors"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_cryptography',         TRUE,  '{"description": "Cryptographic material and key management"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_credential_inventory', TRUE,  '{"description": "Agent credential and token inventory"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_signal_store',         FALSE, '{"description": "Signal storage explorer and FrostDB segments"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_feeds',                FALSE, '{"description": "Raw telemetry feeds and transport debugging"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_network_tests',        FALSE, '{"description": "Diagnostic network testing and port probes"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_agentmaxxing',         FALSE, '{"description": "Experimental AgentMaxxing progressive containment lab"}'::jsonb, NOW(), NOW()),

    -- Tenant Demo Granular Flags (All Enabled for Full Demonstration)
    ('tenant-demo', 'page_discovery',            TRUE, '{"description": "Workload discovery and accounts inventory"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_agents',               TRUE, '{"description": "Governed agent registry and state details"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_topology',             TRUE, '{"description": "Agent trust topology and communication graph"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_weave',                TRUE, '{"description": "Real-time agent interaction weave"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_signals',              TRUE, '{"description": "Live agent signal stream and anomalies"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_risk',                 TRUE, '{"description": "Risk exposure and vulnerability tracking"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_policies',             TRUE, '{"description": "Agent governance policies and guardrail rules"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_compliance',           TRUE, '{"description": "Regulatory posture and compliance frameworks"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_audit',                TRUE, '{"description": "Immutable audit trail and provenance verification"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_federated_services',   TRUE, '{"description": "Federated AI services and model connectors"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_cryptography',         TRUE, '{"description": "Cryptographic material and key management"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_credential_inventory', TRUE, '{"description": "Agent credential and token inventory"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_signal_store',         TRUE, '{"description": "Signal storage explorer and FrostDB segments"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_feeds',                TRUE, '{"description": "Raw telemetry feeds and transport debugging"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_network_tests',        TRUE, '{"description": "Diagnostic network testing and port probes"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_agentmaxxing',         TRUE, '{"description": "Experimental AgentMaxxing progressive containment lab"}'::jsonb, NOW(), NOW())
ON CONFLICT (tenant_id, flag_key) DO UPDATE SET
    enabled = EXCLUDED.enabled,
    config_json = EXCLUDED.config_json,
    updated_at = NOW();

COMMIT;
-- END 065_seed_granular_page_flags.sql

-- BEGIN 066_governance_frameworks_unique_and_policies.sql
-- 066_governance_frameworks_unique_and_policies.sql
--
-- Deduplicate governance_frameworks by (tenant_id, name), repoint child controls,
-- and enforce a unique constraint index so multiple benchmark copies cannot recur.

BEGIN;

-- 1. Deduplicate governance_frameworks:
-- For any tenant having multiple rows with the exact same name (e.g. 3x 'CIS Kubernetes Benchmark'),
-- keep the oldest/canonical row, re-point child governance_controls, and remove duplicates.
DO $$
DECLARE
    dup RECORD;
    canonical_id UUID;
BEGIN
    FOR dup IN
        SELECT tenant_id, name, count(*) AS cnt
        FROM public.governance_frameworks
        GROUP BY tenant_id, name
        HAVING count(*) > 1
    LOOP
        -- Pick canonical row: prefer highest control_count, then earliest created_at
        SELECT id INTO canonical_id
        FROM public.governance_frameworks
        WHERE tenant_id = dup.tenant_id AND name = dup.name
        ORDER BY control_count DESC, created_at ASC
        LIMIT 1;

        -- Re-point any governance_controls referencing obsolete duplicate framework IDs
        UPDATE public.governance_controls
        SET framework_id = canonical_id
        WHERE tenant_id = dup.tenant_id
          AND framework_id IN (
              SELECT id FROM public.governance_frameworks
              WHERE tenant_id = dup.tenant_id AND name = dup.name AND id <> canonical_id
          );

        -- Delete duplicate framework rows
        DELETE FROM public.governance_frameworks
        WHERE tenant_id = dup.tenant_id
          AND name = dup.name
          AND id <> canonical_id;
    END LOOP;
END $$;

-- 2. Enforce UNIQUE index on (tenant_id, name) in governance_frameworks
CREATE UNIQUE INDEX IF NOT EXISTS uq_governance_frameworks_tenant_name
    ON public.governance_frameworks (tenant_id, name);

-- 3. Enforce UNIQUE index on (tenant_id, framework_id, name) in governance_controls
-- First remove any exact duplicate control names under the same framework
DO $$
DECLARE
    dup_ctrl RECORD;
    canonical_ctrl_id UUID;
BEGIN
    FOR dup_ctrl IN
        SELECT tenant_id, framework_id, name, count(*) AS cnt
        FROM public.governance_controls
        GROUP BY tenant_id, framework_id, name
        HAVING count(*) > 1
    LOOP
        SELECT id INTO canonical_ctrl_id
        FROM public.governance_controls
        WHERE tenant_id = dup_ctrl.tenant_id
          AND framework_id = dup_ctrl.framework_id
          AND name = dup_ctrl.name
        ORDER BY control_order ASC, created_at ASC
        LIMIT 1;

        DELETE FROM public.governance_controls
        WHERE tenant_id = dup_ctrl.tenant_id
          AND framework_id = dup_ctrl.framework_id
          AND name = dup_ctrl.name
          AND id <> canonical_ctrl_id;
    END LOOP;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_governance_controls_tenant_fw_name
    ON public.governance_controls (tenant_id, framework_id, name);

COMMIT;
-- END 066_governance_frameworks_unique_and_policies.sql

-- BEGIN 067_feature_flags_audit_event_type.sql
-- 067 — admit the 'feature_flags.updated' audit event type
--
-- PUT /api/v1/admin/features and PUT /api/v1/admin/features/{flag_key} audit
-- their mutations, because toggling tenant feature flags or applying preset bundles
-- alters tenant visibility, active capabilities, and security boundaries.
--
-- Replaces audit_events_event_type_check with 063 vocabulary plus this type.
-- Same guarded shape as 063: the new type is its own sentinel, so re-running is
-- a no-op and a database already carrying it is left alone.
BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
         )) NOT LIKE '%feature_flags.updated%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%feature_flags.updated%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'afm.cluster_import_requested',
        'actor.promote_requested',
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stun_simulated',
        'agent.stunned',
        'agent.transition_failed',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'audit.cross_tenant_read',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'feature_flags.updated',
        'fleet.recover_requested',
        'fleet.resume_requested',
        'invite.created',
        'invite.redeemed',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'policy.bundle_submitted',
        'policy.rollback_requested',
        'rbac.scan_requested',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant.risk_profile_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user.deleted',
        'user.invited',
        'user.role_updated',
        'user.status_updated',
        'user.updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 067_feature_flags_audit_event_type.sql

-- BEGIN 068_seed_governance_frameworks.sql
-- Canonical CEL compliance frameworks and controls for the demo tenants, applied on
-- every estate by the startup migrator rather than only by prelive-clean-down.sh, whose
-- silent '|| true' left governance_frameworks empty and Settings > Governance blank.
-- Derived from db/seed-governance-frameworks.sql: frameworks/controls upsert as there;
-- tenant_settings rows are created when missing but an existing selection is never overwritten.

-- seed-governance-frameworks.sql
-- Canonical seed for default CEL compliance frameworks, controls, and tenant settings.
-- Idempotent: safe to run multiple times across both demo and live/production environments.


-- ══════════════════════════════════════════════════════════════════════════════
-- 1. Governance Frameworks for tenant-demo
-- ══════════════════════════════════════════════════════════════════════════════

-- EU AI Act
INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body, compliance_deadline,
    control_count, activated_by
) VALUES (
    'f0000000-0000-0000-0000-000000000001', 'tenant-demo',
    'EU AI Act', 'v1.0.0', 'European Parliament', '2026-08-02',
    7, 'admin@acme.co'
) ON CONFLICT (tenant_id, name) DO UPDATE SET
    control_count = EXCLUDED.control_count,
    version = EXCLUDED.version,
    regulatory_body = EXCLUDED.regulatory_body,
    compliance_deadline = EXCLUDED.compliance_deadline;

-- SOC 2 Type II
INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body,
    control_count, activated_by
) VALUES (
    'f0000000-0000-0000-0000-000000000002', 'tenant-demo',
    'SOC 2 Type II', 'TSC 2017', 'AICPA',
    3, 'admin@acme.co'
) ON CONFLICT (tenant_id, name) DO UPDATE SET
    control_count = EXCLUDED.control_count,
    version = EXCLUDED.version,
    regulatory_body = EXCLUDED.regulatory_body;

-- CIS Kubernetes Benchmark
INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body,
    control_count, activated_by
) VALUES (
    'f0000000-0000-0000-0000-000000000003', 'tenant-demo',
    'CIS Kubernetes Benchmark', 'v1.8.0', 'Center for Internet Security',
    17, 'admin@acme.co'
) ON CONFLICT (tenant_id, name) DO UPDATE SET
    control_count = EXCLUDED.control_count,
    version = EXCLUDED.version,
    regulatory_body = EXCLUDED.regulatory_body;

-- FINOS AI Governance Framework
INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body,
    control_count, activated_by
) VALUES (
    'f0000000-0000-0000-0000-000000000004', 'tenant-demo',
    'FINOS AI Governance Framework', 'v1.0.0', 'FINOS',
    16, 'admin@acme.co'
) ON CONFLICT (tenant_id, name) DO UPDATE SET
    control_count = EXCLUDED.control_count,
    version = EXCLUDED.version,
    regulatory_body = EXCLUDED.regulatory_body;

-- NIST SP 800-53
INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body,
    control_count, activated_by
) VALUES (
    'f0000000-0000-0000-0000-000000000005', 'tenant-demo',
    'NIST SP 800-53', 'v1.0.0', 'NIST',
    14, 'admin@acme.co'
) ON CONFLICT (tenant_id, name) DO UPDATE SET
    control_count = EXCLUDED.control_count,
    version = EXCLUDED.version,
    regulatory_body = EXCLUDED.regulatory_body;

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. Governance Controls for tenant-demo
-- ══════════════════════════════════════════════════════════════════════════════

-- EU AI Act controls (7, evaluated by eu-ai-act pack)
INSERT INTO public.governance_controls (
    id, tenant_id, framework_id, name, description, control_order,
    policy_framework_id, policy_check_id
) VALUES
('c0000000-0000-0000-0000-000000000001', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Art. 9 -- Containers Run as Non-Root',
 'Containers must run as non-root to reduce blast radius. Evaluated by eu-ai-act/container-run-as-non-root.',
 1, 'eu-ai-act', 'container-run-as-non-root'),
('c0000000-0000-0000-0000-000000000002', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Art. 14 -- Human Oversight (HITL Label)',
 'Agent has a named Identity Owner and HITL label. Evaluated by eu-ai-act/hitl-label.',
 2, 'eu-ai-act', 'hitl-label'),
('c0000000-0000-0000-0000-000000000003', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Art. 10 -- Data Governance (Classification Label)',
 'Data classification label exists on workload. Evaluated by eu-ai-act/data-classification-label.',
 3, 'eu-ai-act', 'data-classification-label'),
('c0000000-0000-0000-0000-000000000040', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Art. 9 -- No Privilege Escalation',
 'Minimize the admission of containers with allowPrivilegeEscalation. Evaluated by eu-ai-act/no-privilege-escalation.',
 4, 'eu-ai-act', 'no-privilege-escalation'),
('c0000000-0000-0000-0000-000000000041', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Art. 9 -- No Privileged Mode',
 'Privileged mode disabled on containers. Evaluated by eu-ai-act/no-privileged-mode.',
 5, 'eu-ai-act', 'no-privileged-mode'),
('c0000000-0000-0000-0000-000000000042', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Art. 15 -- Resource Limits Defined',
 'CPU and memory limits must be defined. Evaluated by eu-ai-act/resource-limits-set.',
 6, 'eu-ai-act', 'resource-limits-set'),
('c0000000-0000-0000-0000-000000000043', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Art. 17 -- Image Digest Required',
 'Image must use sha256 digest. Evaluated by eu-ai-act/image-digest-required.',
 7, 'eu-ai-act', 'image-digest-required')
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    control_order = EXCLUDED.control_order,
    policy_framework_id = EXCLUDED.policy_framework_id,
    policy_check_id = EXCLUDED.policy_check_id;

-- SOC 2 controls
INSERT INTO public.governance_controls (id, tenant_id, framework_id, name, description, control_order) VALUES
('c0000000-0000-0000-0000-000000000004', 'tenant-demo', 'f0000000-0000-0000-0000-000000000002',
 'CC6.1 -- Logical Access Security',
 'Agent has Identity Owner assigned. Credentials are scoped (not wildcard). Token TTL <= 60 minutes.',
 1),
('c0000000-0000-0000-0000-000000000005', 'tenant-demo', 'f0000000-0000-0000-0000-000000000002',
 'CC6.2 -- System Access Controls',
 'Agent lifecycle state is active (not enrolled/suspended/revoked) for production access. Auth token validated before each action.',
 2),
('c0000000-0000-0000-0000-000000000006', 'tenant-demo', 'f0000000-0000-0000-0000-000000000002',
 'CC7.2 -- System Monitoring',
 'Agent has audit trail events within last 24 hours. No unresolved critical violations. Heartbeat received within SLA.',
 3)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description;

-- CIS Kubernetes Benchmark controls (17, evaluated by cis-kubernetes pack)
INSERT INTO public.governance_controls (
    id, tenant_id, framework_id, name, description, control_order,
    policy_framework_id, policy_check_id
) VALUES
('c0000000-0000-0000-0000-000000000010', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.1.6 -- SA Token Automount Disabled',
 'Service account tokens are only mounted where necessary. Evaluated by cis-kubernetes/sa-token-automount-disabled.',
 1, 'cis-kubernetes', 'sa-token-automount-disabled'),
('c0000000-0000-0000-0000-000000000012', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.2 -- No Privileged Containers',
 'Minimize the admission of privileged containers. Evaluated by cis-kubernetes/no-privileged-containers.',
 2, 'cis-kubernetes', 'no-privileged-containers'),
('c0000000-0000-0000-0000-000000000011', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.3 -- No Host PID',
 'Minimize the admission of containers sharing the host process ID namespace. Evaluated by cis-kubernetes/no-host-pid.',
 3, 'cis-kubernetes', 'no-host-pid'),
('c0000000-0000-0000-0000-000000000013', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.4 -- No Host IPC',
 'Minimize the admission of containers sharing the host IPC namespace. Evaluated by cis-kubernetes/no-host-ipc.',
 4, 'cis-kubernetes', 'no-host-ipc'),
('c0000000-0000-0000-0000-000000000014', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.5 -- No Host Network',
 'Minimize the admission of containers sharing the host network namespace. Evaluated by cis-kubernetes/no-host-network.',
 5, 'cis-kubernetes', 'no-host-network'),
('c0000000-0000-0000-0000-000000000008', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.6 -- No Privilege Escalation',
 'Minimize the admission of containers with allowPrivilegeEscalation. Evaluated by cis-kubernetes/no-privilege-escalation.',
 6, 'cis-kubernetes', 'no-privilege-escalation'),
('c0000000-0000-0000-0000-000000000007', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.7 -- No Root Containers',
 'Minimize the admission of root containers. Evaluated by cis-kubernetes/no-root-containers.',
 7, 'cis-kubernetes', 'no-root-containers'),
('c0000000-0000-0000-0000-000000000015', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.8 -- No NET_RAW',
 'Minimize the admission of containers with the NET_RAW capability. Evaluated by cis-kubernetes/no-net-raw.',
 8, 'cis-kubernetes', 'no-net-raw'),
('c0000000-0000-0000-0000-000000000016', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.9 -- No Added Capabilities',
 'Minimize the admission of containers with added capabilities. Evaluated by cis-kubernetes/no-added-capabilities.',
 9, 'cis-kubernetes', 'no-added-capabilities'),
('c0000000-0000-0000-0000-000000000017', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.10 -- Capabilities Dropped ALL',
 'Minimize the admission of containers with capabilities assigned. Evaluated by cis-kubernetes/capabilities-dropped-all.',
 10, 'cis-kubernetes', 'capabilities-dropped-all'),
('c0000000-0000-0000-0000-000000000018', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.11 -- No Windows HostProcess',
 'Minimize the admission of Windows HostProcess containers. Evaluated by cis-kubernetes/no-windows-hostprocess.',
 11, 'cis-kubernetes', 'no-windows-hostprocess'),
('c0000000-0000-0000-0000-000000000019', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.12 -- No HostPath Volumes',
 'Minimize the admission of HostPath volumes. Evaluated by cis-kubernetes/no-hostpath-volumes.',
 12, 'cis-kubernetes', 'no-hostpath-volumes'),
('c0000000-0000-0000-0000-000000000020', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.13 -- No Host Ports',
 'Minimize the admission of containers which use HostPorts. Evaluated by cis-kubernetes/no-host-ports.',
 13, 'cis-kubernetes', 'no-host-ports'),
('c0000000-0000-0000-0000-000000000021', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.4.1 -- No Secrets in Env',
 'Prefer secrets as files over secrets as environment variables. Evaluated by cis-kubernetes/no-secrets-in-env.',
 14, 'cis-kubernetes', 'no-secrets-in-env'),
('c0000000-0000-0000-0000-000000000009', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.7.2 -- Seccomp RuntimeDefault',
 'Ensure the seccomp profile is set to RuntimeDefault in pod definitions. Evaluated by cis-kubernetes/seccomp-runtime-default.',
 15, 'cis-kubernetes', 'seccomp-runtime-default'),
('c0000000-0000-0000-0000-000000000022', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.7.3 -- Security Context Applied',
 'Apply a security context to pods and containers. Evaluated by cis-kubernetes/security-context-applied.',
 16, 'cis-kubernetes', 'security-context-applied'),
('c0000000-0000-0000-0000-000000000023', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.7.4 -- No Default Namespace',
 'The default namespace should not be used. Evaluated by cis-kubernetes/no-default-namespace.',
 17, 'cis-kubernetes', 'no-default-namespace')
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    control_order = EXCLUDED.control_order,
    policy_framework_id = EXCLUDED.policy_framework_id,
    policy_check_id = EXCLUDED.policy_check_id;

-- FINOS AI Governance Framework controls (16, evaluated by finos-aigf pack)
INSERT INTO public.governance_controls (
    id, tenant_id, framework_id, name, description, control_order,
    policy_framework_id, policy_check_id
) VALUES
('c0000000-0000-0000-0000-000000000027', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-002 RAG ingestion filters sensitive data',
 'If the agent uses retrieval-augmented generation (agent.data.rag_enabled is true), sensitive-data filtering must be active on ingestion. Not applicable, and passes, when rag_enabled is false. Undeclared or non-boolean rag_enabled fails. Evaluated by finos-aigf/rag-ingestion-sensitive-data-filtered.',
 1, 'finos-aigf', 'rag-ingestion-sensitive-data-filtered'),
('c0000000-0000-0000-0000-000000000025', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-003 Active prompt injection filter guardrail',
 'Enforces real-time input guardrails to detect adversarial prompt injection attacks (agent.guardrails.prompt_injection_filter is true). Evaluated by finos-aigf/prompt-injection-guardrail-active.',
 2, 'finos-aigf', 'prompt-injection-guardrail-active'),
('c0000000-0000-0000-0000-000000000028', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-003 Model output filtered for leakage and harmful content',
 'Model responses are inspected for sensitive-data leakage and policy-violating content before they leave the system (agent.guardrails.output_filter is true). Evaluated by finos-aigf/output-leakage-filter-active.',
 3, 'finos-aigf', 'output-leakage-filter-active'),
('c0000000-0000-0000-0000-000000000029', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-008 Inference request rate limit configured',
 'A positive per-minute request limit is enforced on the agent (agent.rate_limits.requests_per_minute is a JSON number > 0). Evaluated by finos-aigf/inference-rate-limit-configured.',
 4, 'finos-aigf', 'inference-rate-limit-configured'),
('c0000000-0000-0000-0000-000000000024', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-010 Model catalog registration and approval',
 'Verifies AI agent model is registered and actively approved in the enterprise model inventory (agent.registry.model_registered is true). Evaluated by finos-aigf/registered-model-registry-entry.',
 5, 'finos-aigf', 'registered-model-registry-entry'),
('c0000000-0000-0000-0000-000000000030', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-010 Model version pinned, not a floating alias',
 'agent.registry.model_version is a non-empty string without whitespace that does not end in a ''latest'' alias segment (case-insensitive, e.g. ''-latest'', '':latest'', or bare ''latest''). Evaluated by finos-aigf/model-version-pinned.',
 6, 'finos-aigf', 'model-version-pinned'),
('c0000000-0000-0000-0000-000000000031', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-012 Caller authentication and RBAC enforced',
 'Callers must authenticate (agent.access.authentication_required is true) and role-based authorisation is enforced (agent.access.rbac_enforced is true). Evaluated by finos-aigf/user-authn-and-rbac-enforced.',
 7, 'finos-aigf', 'user-authn-and-rbac-enforced'),
('c0000000-0000-0000-0000-000000000032', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-014 All persistent AI data stores encrypted at rest',
 'Every entry of agent.data.persistent_stores has encrypted_at_rest true. An empty list (the agent persists nothing) passes; an absent or non-list field fails. Evaluated by finos-aigf/ai-data-encrypted-at-rest.',
 8, 'finos-aigf', 'ai-data-encrypted-at-rest'),
('c0000000-0000-0000-0000-000000000033', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-018 Tool grants are explicitly scoped, no wildcards',
 'Every entry of agent.tools declares a non-empty scopes list of non-empty strings, none ending in ''*'' (no ''*'' or prefix wildcards). An empty tools list passes; an absent or non-list field fails. Evaluated by finos-aigf/tool-grants-least-privilege.',
 9, 'finos-aigf', 'tool-grants-least-privilege'),
('c0000000-0000-0000-0000-000000000034', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-020 Only allow-listed MCP servers connected',
 'Every entry of agent.mcp_servers has allowlisted true. An empty list (no MCP servers) passes; an absent or non-list field fails. Evaluated by finos-aigf/mcp-servers-allowlisted.',
 10, 'finos-aigf', 'mcp-servers-allowlisted'),
('c0000000-0000-0000-0000-000000000035', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-023 No long-lived credentials exposed to the agent',
 'agent.credentials.long_lived_secrets_exposed is boolean false. Absent or non-boolean fails: lack of a finding is not evidence of protection. Evaluated by finos-aigf/no-long-lived-credentials-exposed.',
 11, 'finos-aigf', 'no-long-lived-credentials-exposed'),
('c0000000-0000-0000-0000-000000000036', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-024 High-impact tools gated by human approval',
 'Every entry of agent.tools either declares impact ''low'' or ''medium'', or has requires_human_approval true. Tools with impact ''high'' or no impact classification are treated as high (fail-closed). Not applicable, and passes, when every tool is low/medium or the list is empty; an absent or non-list field fails. Evaluated by finos-aigf/high-impact-actions-human-approved.',
 12, 'finos-aigf', 'high-impact-actions-human-approved'),
('c0000000-0000-0000-0000-000000000037', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-DET-004 Agent interaction audit logging enabled',
 'agent.observability.audit_logging is true. Evaluated by finos-aigf/ai-interaction-audit-logging.',
 13, 'finos-aigf', 'ai-interaction-audit-logging'),
('c0000000-0000-0000-0000-000000000038', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-DET-009 Spend budget and alerting configured',
 'agent.cost_controls.budget_limit is a JSON number > 0 and agent.cost_controls.spend_alerting is true. Evaluated by finos-aigf/spend-budget-alerting-configured.',
 14, 'finos-aigf', 'spend-budget-alerting-configured'),
('c0000000-0000-0000-0000-000000000026', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-DET-021 Decision explainability and reasoning trace',
 'Requires recorded reasoning traces and explainability metadata for compliance auditing (agent.governance.decision_explainability is true). Evaluated by finos-aigf/decision-explainability-metadata.',
 15, 'finos-aigf', 'decision-explainability-metadata'),
('c0000000-0000-0000-0000-000000000039', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-DET-021 Decision audit log is tamper-evident',
 'agent.governance.audit_log_tamper_evident is true (cryptographic integrity protection on the decision log). Evaluated by finos-aigf/decision-audit-tamper-evident.',
 16, 'finos-aigf', 'decision-audit-tamper-evident')
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    control_order = EXCLUDED.control_order,
    policy_framework_id = EXCLUDED.policy_framework_id,
    policy_check_id = EXCLUDED.policy_check_id;

-- NIST SP 800-53 controls (14, evaluated by nist-800-53 pack)
INSERT INTO public.governance_controls (
    id, tenant_id, framework_id, name, description, control_order,
    policy_framework_id, policy_check_id
) VALUES
('c0000000-0000-0000-0000-000000000050', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AC-6 -- Non-Root Containers',
 'AC-6: Principle of least privilege -- containers must not run as root. Evaluated by nist-800-53/container-run-as-non-root.',
 1, 'nist-800-53', 'container-run-as-non-root'),
('c0000000-0000-0000-0000-000000000051', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AC-6 -- No Host IPC',
 'Host IPC namespace not shared. Evaluated by nist-800-53/no-host-ipc.',
 2, 'nist-800-53', 'no-host-ipc'),
('c0000000-0000-0000-0000-000000000052', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AC-6 -- No Host PID',
 'Host PID namespace not shared. Evaluated by nist-800-53/no-host-pid.',
 3, 'nist-800-53', 'no-host-pid'),
('c0000000-0000-0000-0000-000000000053', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AC-6 -- No Host Network',
 'Host network namespace not shared. Evaluated by nist-800-53/no-host-network.',
 4, 'nist-800-53', 'no-host-network'),
('c0000000-0000-0000-0000-000000000054', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AC-6(1) -- No Privilege Escalation',
 'Containers must not allow privilege escalation. Evaluated by nist-800-53/no-privilege-escalation.',
 5, 'nist-800-53', 'no-privilege-escalation'),
('c0000000-0000-0000-0000-000000000055', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AC-6(2) -- No Privileged Mode',
 'Privileged mode disabled on containers. Evaluated by nist-800-53/no-privileged-mode.',
 6, 'nist-800-53', 'no-privileged-mode'),
('c0000000-0000-0000-0000-000000000056', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AC-6 -- No Automount SA Token',
 'Service account token auto-mount disabled. Evaluated by nist-800-53/no-automount-sa-token.',
 7, 'nist-800-53', 'no-automount-sa-token'),
('c0000000-0000-0000-0000-000000000057', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'CM-8 -- Application Label',
 'Application label exists on workload. Evaluated by nist-800-53/app-label.',
 8, 'nist-800-53', 'app-label'),
('c0000000-0000-0000-0000-000000000058', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'CM-8 -- Version Label',
 'Version label exists on workload. Evaluated by nist-800-53/version-label.',
 9, 'nist-800-53', 'version-label'),
('c0000000-0000-0000-0000-000000000059', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'SC-6 -- Resource Limits Set',
 'CPU and memory limits must be defined. Evaluated by nist-800-53/resource-limits-set.',
 10, 'nist-800-53', 'resource-limits-set'),
('c0000000-0000-0000-0000-000000000060', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'SC-7 -- Drop All Capabilities',
 'All capabilities dropped from containers. Evaluated by nist-800-53/drop-all-capabilities.',
 11, 'nist-800-53', 'drop-all-capabilities'),
('c0000000-0000-0000-0000-000000000061', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'SI-7 -- Read-Only Root Filesystem',
 'Read-only root filesystem enforced. Evaluated by nist-800-53/read-only-rootfs.',
 12, 'nist-800-53', 'read-only-rootfs'),
('c0000000-0000-0000-0000-000000000062', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'SI-7 -- Image Digest Required',
 'Image must use sha256 digest. Evaluated by nist-800-53/image-digest-required.',
 13, 'nist-800-53', 'image-digest-required'),
('c0000000-0000-0000-0000-000000000063', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AU-2 -- Audit Label',
 'Audit logging label present. Evaluated by nist-800-53/audit-label.',
 14, 'nist-800-53', 'audit-label')
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    control_order = EXCLUDED.control_order,
    policy_framework_id = EXCLUDED.policy_framework_id,
    policy_check_id = EXCLUDED.policy_check_id;

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. Tenant Settings for tenant-demo (with default CEL frameworks active)
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.tenant_settings (
    tenant_id, org_name, plan_tier, status,
    selected_frameworks, api_key_status, cookie_preferences
) VALUES (
    'tenant-demo', 'tenant-demo Org', 'enterprise', 'active',
    '["eu-ai-act", "k8s-cis-benchmark", "cis-kubernetes", "finos-ai-governance-framework", "finos-aigf", "soc2", "nist-800-53"]'::jsonb,
    'active',
    '{"strictly_necessary": true, "analytics": true}'::jsonb
) ON CONFLICT (tenant_id) DO NOTHING;

-- ══════════════════════════════════════════════════════════════════════════════
-- 4. Replicate canonical frameworks & controls to kusari
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body, compliance_deadline, control_count, activated_by
)
SELECT 
    ('f0000000-0000-0000-0001-' || substr(id::text, 25))::uuid,
    'kusari', name, version, regulatory_body, compliance_deadline, control_count, activated_by
FROM public.governance_frameworks WHERE tenant_id = 'tenant-demo'
ON CONFLICT (tenant_id, name) DO UPDATE SET
    control_count = EXCLUDED.control_count,
    version = EXCLUDED.version,
    regulatory_body = EXCLUDED.regulatory_body,
    compliance_deadline = EXCLUDED.compliance_deadline;

INSERT INTO public.governance_controls (
    id, tenant_id, framework_id, name, description, control_order, policy_framework_id, policy_check_id
)
SELECT 
    ('c0000000-0000-0001-' || substr(c.id::text, 20))::uuid,
    'kusari',
    ('f0000000-0000-0000-0001-' || substr(c.framework_id::text, 25))::uuid,
    c.name, c.description, c.control_order, c.policy_framework_id, c.policy_check_id
FROM public.governance_controls c WHERE c.tenant_id = 'tenant-demo'
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    control_order = EXCLUDED.control_order,
    policy_framework_id = EXCLUDED.policy_framework_id,
    policy_check_id = EXCLUDED.policy_check_id;

INSERT INTO public.tenant_settings (
    tenant_id, org_name, plan_tier, status,
    selected_frameworks, api_key_status, cookie_preferences
) VALUES (
    'kusari', 'Kusari Org', 'enterprise', 'active',
    '["eu-ai-act", "k8s-cis-benchmark", "cis-kubernetes", "finos-ai-governance-framework", "finos-aigf", "soc2", "nist-800-53"]'::jsonb,
    'active',
    '{"strictly_necessary": true, "analytics": true}'::jsonb
) ON CONFLICT (tenant_id) DO NOTHING;

-- ══════════════════════════════════════════════════════════════════════════════
-- 5. Replicate canonical frameworks & controls to default tenant
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body, compliance_deadline, control_count, activated_by
)
SELECT 
    ('f0000000-0000-0000-0002-' || substr(id::text, 25))::uuid,
    'default', name, version, regulatory_body, compliance_deadline, control_count, activated_by
FROM public.governance_frameworks WHERE tenant_id = 'tenant-demo'
ON CONFLICT (tenant_id, name) DO UPDATE SET
    control_count = EXCLUDED.control_count,
    version = EXCLUDED.version,
    regulatory_body = EXCLUDED.regulatory_body,
    compliance_deadline = EXCLUDED.compliance_deadline;

INSERT INTO public.governance_controls (
    id, tenant_id, framework_id, name, description, control_order, policy_framework_id, policy_check_id
)
SELECT 
    ('c0000000-0000-0002-' || substr(c.id::text, 20))::uuid,
    'default',
    ('f0000000-0000-0000-0002-' || substr(c.framework_id::text, 25))::uuid,
    c.name, c.description, c.control_order, c.policy_framework_id, c.policy_check_id
FROM public.governance_controls c WHERE c.tenant_id = 'tenant-demo'
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    control_order = EXCLUDED.control_order,
    policy_framework_id = EXCLUDED.policy_framework_id,
    policy_check_id = EXCLUDED.policy_check_id;

INSERT INTO public.tenant_settings (
    tenant_id, org_name, plan_tier, status,
    selected_frameworks, api_key_status, cookie_preferences
) VALUES (
    'default', 'Default Org', 'enterprise', 'active',
    '["eu-ai-act", "k8s-cis-benchmark", "cis-kubernetes", "finos-ai-governance-framework", "finos-aigf", "soc2", "nist-800-53"]'::jsonb,
    'active',
    '{"strictly_necessary": true, "analytics": true}'::jsonb
) ON CONFLICT (tenant_id) DO NOTHING;
-- END 068_seed_governance_frameworks.sql

-- BEGIN 069_connector_scan_audit_event_type.sql
-- 069 — admit the 'connector.scan_requested' audit event type
--
-- POST /connectors/{provider_id}/scan asks an upstream provider (Anthropic)
-- to enumerate the tenant's agents and models with the tenant's stored
-- credentials. The request is audited before the outbound call through
-- _audit_outbound_request, like policy.bundle_submitted and rbac.scan_requested.
--
-- Replaces audit_events_event_type_check with the 067 vocabulary plus this
-- type. Same guarded shape as 063/067: the new type is its own sentinel, so
-- re-running is a no-op and a database already carrying it is left alone.
BEGIN;

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
         )) NOT LIKE '%connector.scan_requested%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%connector.scan_requested%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'afm.cluster_import_requested',
        'actor.promote_requested',
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stun_simulated',
        'agent.stunned',
        'agent.transition_failed',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'audit.cross_tenant_read',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'connector.scan_requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'feature_flags.updated',
        'fleet.recover_requested',
        'fleet.resume_requested',
        'invite.created',
        'invite.redeemed',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'policy.bundle_submitted',
        'policy.rollback_requested',
        'rbac.scan_requested',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant.risk_profile_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user.deleted',
        'user.invited',
        'user.role_updated',
        'user.status_updated',
        'user.updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 069_connector_scan_audit_event_type.sql

-- BEGIN 070_tenant_connectors.sql
-- 070 — tenant_connectors: connectors, sealed credentials and last scan, per tenant
--
-- Before this, a live deployment kept every tenant's connectors, their
-- credentials and their scan results in fe-signalloom process memory
-- (routers/connectors.py). A pod restart forgot all of it: a tenant that had
-- configured and tested Anthropic Claude saw "Not configured" after the next
-- deploy. It also handed every live tenant five demo connectors marked
-- "connected" with invented timestamps.
--
-- One row per (tenant, provider); connector_id is unique within the tenant.
-- Every query filters on tenant_id.
--
-- credentials_ciphertext is never plaintext: it is
-- connector_credentials.seal_credentials output, AES-256-GCM in the
-- `vault:v1:` wire format, with the tenant and connector as associated data so
-- a ciphertext moved to another row does not decrypt. The key is mounted from
-- Secret fe-signalloom-connector-credential-key, never stored here.
--
-- Timestamps are observations: last_tested_at and last_scan_at are written only
-- when a test or a fully successful scan happened; NULL means it has not.
BEGIN;

CREATE TABLE IF NOT EXISTS public.tenant_connectors (
    tenant_id              TEXT         NOT NULL,
    connector_id           TEXT         NOT NULL,
    provider_id            TEXT         NOT NULL,
    display_name           TEXT,
    status                 TEXT         NOT NULL
                                        CHECK (status IN ('connected', 'disconnected', 'error')),
    credential_expires_at  TIMESTAMPTZ,
    last_tested_at         TIMESTAMPTZ,
    last_scan_at           TIMESTAMPTZ,
    last_scan_status       TEXT         CHECK (last_scan_status IN ('success', 'warning', 'error')),
    last_scan_error        TEXT,
    last_scan_result       JSONB,
    metadata               JSONB        NOT NULL DEFAULT '{}'::jsonb,
    credentials_ciphertext TEXT         CHECK (credentials_ciphertext LIKE 'vault:v1:%'),
    created_at             TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, connector_id),
    UNIQUE (tenant_id, provider_id)
);

COMMIT;
-- END 070_tenant_connectors.sql

-- BEGIN 071_remote_agents.sql
-- 071 — remote_agents and remote_agent_sync_state: the remote agentic runtime, per tenant connector
--
-- A connector to a managed agent platform (Anthropic Managed Agents, the
-- OpenAI Agents API) is continuously synchronised by remote_agent_sync.py:
-- a full paginated listing every CONNECTOR_SYNC_INTERVAL_SECONDS, an SSE
-- event stream for Anthropic sessions that are running, and an optional
-- signed webhook. This table is what that sync observed, so the platform
-- reflects the remote state rather than a demo fixture.
--
-- One row per (tenant, connector, external_id). Every query filters on
-- tenant_id. Nothing is deleted silently: an item that disappears from a
-- complete listing gets gone_at, and gets it cleared if it comes back.
--
-- Columns carry only what the provider reported: status is the provider's own
-- word ('running', 'idle', 'terminated', 'archived' for an archived agent),
-- never a translation; NULL means the provider did not say. raw is a whitelisted
-- subset of the provider's object (ids, names, model, status, timestamps); it
-- never holds credentials, prompts, tool definitions or MCP URLs.
--
-- first_seen_at / last_seen_at / last_changed_at / gone_at are this platform's
-- observation times. external_updated_at is the provider's own timestamp.
BEGIN;

CREATE TABLE IF NOT EXISTS public.remote_agents (
    tenant_id            TEXT         NOT NULL,
    connector_id         TEXT         NOT NULL,
    provider_id          TEXT         NOT NULL,
    external_id          TEXT         NOT NULL,
    kind                 TEXT         NOT NULL
                                      CHECK (kind IN ('agent', 'session', 'assistant', 'workflow')),
    name                 TEXT,
    model                TEXT,
    status               TEXT,
    version              TEXT,
    external_updated_at  TIMESTAMPTZ,
    first_seen_at        TIMESTAMPTZ  NOT NULL,
    last_seen_at         TIMESTAMPTZ  NOT NULL,
    last_changed_at      TIMESTAMPTZ  NOT NULL,
    gone_at              TIMESTAMPTZ,
    raw                  JSONB        NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (tenant_id, connector_id, external_id),
    FOREIGN KEY (tenant_id, connector_id)
        REFERENCES public.tenant_connectors (tenant_id, connector_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS remote_agents_tenant_live_idx
    ON public.remote_agents (tenant_id, connector_id) WHERE gone_at IS NULL;

-- Per-connector sync bookkeeping, shown to the tenant and shared by replicas:
-- a replica that takes the advisory lock and finds next_poll_at in the future
-- leaves the poll to whoever set it.
CREATE TABLE IF NOT EXISTS public.remote_agent_sync_state (
    tenant_id             TEXT         NOT NULL,
    connector_id          TEXT         NOT NULL,
    provider_id           TEXT         NOT NULL,
    mode                  TEXT         NOT NULL
                                       CHECK (mode IN ('poll', 'poll+stream', 'backoff')),
    last_poll_at          TIMESTAMPTZ,
    last_success_at       TIMESTAMPTZ,
    last_error            TEXT,
    next_poll_at          TIMESTAMPTZ,
    consecutive_failures  INTEGER      NOT NULL DEFAULT 0,
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, connector_id),
    FOREIGN KEY (tenant_id, connector_id)
        REFERENCES public.tenant_connectors (tenant_id, connector_id) ON DELETE CASCADE
);

COMMIT;
-- END 071_remote_agents.sql

-- BEGIN 072_remote_agent_claims.sql
-- 072 — remote_agents.claimed_agent_id: a remote provider agent claimed into the tenant
--
-- POST /api/v1/connectors/{provider_id}/remote-agents/{external_id}/claim
-- (routers/connectors.py) creates or links an agent_registry record carrying the
-- provider provenance (provider_id, connector_id, external_id, kind, model in
-- agent_registry.config->'remote_agent') and records the link here, so Discovery
-- and the remote environment page can show "Claimed" and link to the agent.
--
-- The sync's upsert never writes these columns, so a re-listing keeps the link.
-- Deleting the registry agent clears the link (ON DELETE SET NULL) and the remote
-- agent becomes claimable again; deleting the connector cascades the row away.
BEGIN;

ALTER TABLE public.remote_agents
    ADD COLUMN IF NOT EXISTS claimed_agent_id UUID
        REFERENCES public.agent_registry (id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ;

COMMIT;
-- END 072_remote_agent_claims.sql

-- BEGIN 073_remote_agent_snapshots.sql
-- 073 — remote_agent_snapshots: content-addressed versioned snapshots for remote agents
--
-- Stores versioned immutable snapshots of remote agents, sessions, and environments.
-- Deduplication is enforced by PRIMARY KEY (tenant_id, connector_id, external_id, raw_hash).
BEGIN;

ALTER TABLE public.remote_agents
    DROP CONSTRAINT IF EXISTS remote_agents_kind_check;

ALTER TABLE public.remote_agents
    ADD CONSTRAINT remote_agents_kind_check
    CHECK (kind IN ('agent', 'session', 'assistant', 'workflow', 'environment'));

ALTER TABLE public.remote_agents
    ADD COLUMN IF NOT EXISTS raw_hash TEXT,
    ADD COLUMN IF NOT EXISTS system_prompt TEXT,
    ADD COLUMN IF NOT EXISTS environment_config JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS user_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS metrics JSONB NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS public.remote_agent_snapshots (
    tenant_id            TEXT         NOT NULL,
    connector_id         TEXT         NOT NULL,
    external_id          TEXT         NOT NULL,
    raw_hash             TEXT         NOT NULL,
    kind                 TEXT         NOT NULL
                                      CHECK (kind IN ('agent', 'session', 'assistant', 'workflow', 'environment')),
    name                 TEXT,
    model                TEXT,
    status               TEXT,
    version              TEXT,
    system_prompt        TEXT,
    tools                JSONB        NOT NULL DEFAULT '[]'::jsonb,
    environment_config   JSONB        NOT NULL DEFAULT '{}'::jsonb,
    user_metadata        JSONB        NOT NULL DEFAULT '{}'::jsonb,
    metrics              JSONB        NOT NULL DEFAULT '{}'::jsonb,
    raw                  JSONB        NOT NULL DEFAULT '{}'::jsonb,
    observed_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, connector_id, external_id, raw_hash),
    FOREIGN KEY (tenant_id, connector_id)
        REFERENCES public.tenant_connectors (tenant_id, connector_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS remote_agent_snapshots_lookup_idx
    ON public.remote_agent_snapshots (tenant_id, connector_id, external_id, observed_at DESC);

COMMIT;
-- END 073_remote_agent_snapshots.sql

-- BEGIN 074_tenant_account_types.sql
-- 074 — tenant_account_types: the account type applied to each tenant
--
-- An account type (EAP View, EAP Full, Full) is a named, exact feature-flag set
-- (feature_flags.FEATURE_PRESETS). PUT /api/v1/admin/features with a preset
-- writes the flags into tenant_feature_flags (057) AND records the type here.
--
-- `customised` is TRUE when a later manual toggle left the tenant's effective
-- flags different from the recorded type's set; the Feature Flags page then
-- shows "Custom, based on <type>" instead of claiming the type. It is
-- re-derived after every flag mutation, so toggling back clears it.
--
-- Design: docs/signalloom/feature-flag-account-types.md
BEGIN;

CREATE TABLE IF NOT EXISTS public.tenant_account_types (
    tenant_id    VARCHAR(128) PRIMARY KEY,
    account_type VARCHAR(64)  NOT NULL,
    customised   BOOLEAN      NOT NULL DEFAULT FALSE,
    updated_by   VARCHAR(256),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMIT;
-- END 074_tenant_account_types.sql

-- BEGIN 075_retire_minimal_governance_account_type.sql
-- 075 — retire the "Minimal Governance" preset
--
-- "minimal_governance" was never an account type (EAP View, EAP Full, Full):
-- it was a non-account-type "bundle" preset in feature_flags.FEATURE_PRESETS,
-- listed with kind="bundle" on GET /api/v1/admin/features/presets. The
-- principal decided to retire it entirely -- removed from the contract file,
-- FEATURE_PRESETS, the dashboard constants, the acceptance-test harness, and
-- every test that referenced it.
--
-- Any tenant that had it applied is still recorded in public.tenant_account_types
-- (migration 074) with account_type = 'minimal_governance'. That id no longer
-- resolves to anything, so describe_account_type() would report such a tenant
-- "Unassigned" even though its flags still reflect the old preset -- losing
-- the fact that a type was ever applied. This migration remaps those rows to
-- the nearest supported account type instead of just deleting the fact.
--
-- "Nearest" by flag-set Hamming distance over the 23 registered flags:
--   eap_view: 4 differ   (compliance, page_discovery, page_policies, page_audit)
--   eap_full: 9 differ
--   full:    19 differ
-- eap_view is nearest by a wide margin, so remapped tenants go there.
--
-- The tenant's actual flags in tenant_feature_flags (057) are NOT touched by
-- this migration -- only the recorded type label. Since minimal_governance's
-- flags differ from eap_view's in 4 places, the remapped row is marked
-- customised = TRUE, so the Feature Flags page shows "Custom, based on
-- EAP View (read-only)" rather than falsely claiming an exact match.
--
-- Idempotent: re-running finds no row with account_type = 'minimal_governance'
-- left to update (they are all 'eap_view' by then) and is a no-op.
--
-- Design: docs/signalloom/feature-flag-account-types.md
BEGIN;

UPDATE public.tenant_account_types
SET account_type = 'eap_view',
    customised = TRUE,
    updated_at = NOW()
WHERE account_type = 'minimal_governance';

COMMIT;
-- END 075_retire_minimal_governance_account_type.sql

-- BEGIN 076_custom_account_types.sql
-- 076 — custom account types, superadmin-defined
--
-- A custom account type is a named, explicit feature-flag set a superadmin
-- can create, rename and delete (api/admin_account_types.py), on top of the
-- three built-in account types (EAP View, EAP Full, Full; migration 074) and
-- the now-retired "minimal_governance" bundle (075). It is persisted here and
-- tenant-assignable exactly like a built-in: PUT /api/v1/admin/features
-- accepts its id as `preset`, and it is listed alongside the built-ins by
-- GET /api/v1/admin/features/presets (kind="custom").
--
-- `flags` is a full JSONB flag map, same shape as tenant_feature_flags' values
-- but keyed by flag within a single row rather than one row per flag, because
-- a custom account type is one unit: feature_flags.CustomAccountTypeRepository
-- validates it sets exactly the registered flag keys before insert.
--
-- `id` is the primary key and doubles as the preset id applied to tenants, so
-- it is validated (lowercase, digits, underscores; starts with a letter) and
-- checked against RESERVED_ACCOUNT_TYPE_IDS (every built-in id, every
-- deprecated alias, and 'minimal_governance') before insert -- a custom type
-- can never collide with or shadow a built-in one.
--
-- Built-in account types are not rows in this table: they live in
-- feature_flags.FEATURE_PRESETS, a Python constant, which is exactly why they
-- "cannot be deleted or edited" -- there is no row here to delete or edit.
--
-- Design: docs/signalloom/feature-flag-account-types.md
BEGIN;

CREATE TABLE IF NOT EXISTS public.custom_account_types (
    id          VARCHAR(64)  PRIMARY KEY,
    name        VARCHAR(256) NOT NULL,
    flags       JSONB        NOT NULL,
    created_by  VARCHAR(256),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_by  VARCHAR(256),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────────────────────────────────────
-- Admit the 'account_type.created' / 'account_type.renamed' /
-- 'account_type.deleted' audit event types
-- ──────────────────────────────────────────────────────────────────────────────
-- Same guarded drop-and-recreate shape as 063/067/069: the new types are their
-- own sentinel, so re-running is a no-op and a database already carrying them
-- is left alone. 069 is the migration that last recreated this constraint (070
-- through 075 touch neither audit_events nor its CHECK); this one replaces it
-- with the 069 vocabulary plus the three new types.

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
         )) NOT LIKE '%account_type.created%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%account_type.created%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'account_type.created',
        'account_type.deleted',
        'account_type.renamed',
        'afm.cluster_import_requested',
        'actor.promote_requested',
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stun_simulated',
        'agent.stunned',
        'agent.transition_failed',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'audit.cross_tenant_read',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'connector.scan_requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'feature_flags.updated',
        'fleet.recover_requested',
        'fleet.resume_requested',
        'invite.created',
        'invite.redeemed',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'policy.bundle_submitted',
        'policy.rollback_requested',
        'rbac.scan_requested',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant.risk_profile_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user.deleted',
        'user.invited',
        'user.role_updated',
        'user.status_updated',
        'user.updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
-- END 076_custom_account_types.sql
