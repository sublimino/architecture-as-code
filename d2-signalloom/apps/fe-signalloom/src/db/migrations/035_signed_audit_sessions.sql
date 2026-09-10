-- Migration: 035_signed_audit_sessions.sql
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
