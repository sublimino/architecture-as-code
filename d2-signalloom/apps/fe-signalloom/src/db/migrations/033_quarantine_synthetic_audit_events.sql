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
