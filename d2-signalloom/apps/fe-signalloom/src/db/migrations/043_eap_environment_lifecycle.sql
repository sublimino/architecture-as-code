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
