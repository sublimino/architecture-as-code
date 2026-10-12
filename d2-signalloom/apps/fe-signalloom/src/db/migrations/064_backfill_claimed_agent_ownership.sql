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
