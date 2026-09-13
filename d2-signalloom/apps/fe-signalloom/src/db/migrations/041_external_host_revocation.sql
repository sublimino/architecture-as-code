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
