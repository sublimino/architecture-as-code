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
