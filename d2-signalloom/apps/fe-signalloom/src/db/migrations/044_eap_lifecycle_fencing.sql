-- Migration 044: Add claim fencing token to EAP environment lifecycle and index outbox by customer_hash
BEGIN;

ALTER TABLE public.eap_environment_lifecycle
    ADD COLUMN IF NOT EXISTS claim_fencing_token BIGINT NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_eap_lifecycle_outbox_customer_hash
    ON public.eap_lifecycle_outbox (customer_hash);

COMMIT;
