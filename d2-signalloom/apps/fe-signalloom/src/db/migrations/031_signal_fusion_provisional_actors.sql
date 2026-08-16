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
