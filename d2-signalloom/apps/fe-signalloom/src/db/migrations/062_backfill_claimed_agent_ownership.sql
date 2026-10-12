-- Migration 062: Backfill claimed agent ownership from audit events and claims
-- Attributes owner and owner_id in public.agent_registry for active/enrolled agents that have a granted claim
-- but previously had NULL or empty owner.

UPDATE public.agent_registry ar
SET owner = COALESCE(
    NULLIF(ar.owner, ''),
    c.actor,
    c.user_email,
    'demo-user@signalloom.local'
),
owner_id = COALESCE(
    ar.owner_id,
    c.user_id
)
FROM (
    SELECT ac.agent_id,
           ae.actor,
           pu.id AS user_id,
           pu.email AS user_email
    FROM public.agent_claims ac
    LEFT JOIN LATERAL (
        SELECT actor
        FROM public.audit_events
        WHERE event_type = 'agent.created'
          AND detail::text LIKE '%"action": "claimed"%'
          AND (agent_id = ac.agent_id OR detail::text LIKE '%' || ac.pod_name || '%')
        ORDER BY timestamp DESC
        LIMIT 1
    ) ae ON true
    LEFT JOIN public.platform_users pu
        ON LOWER(pu.email) = LOWER(ae.actor)
       AND (pu.tenant_id = ac.tenant_id OR pu.tenant_id = 'tenant-demo')
    WHERE ac.status = 'granted'
) c
WHERE ar.id = c.agent_id
  AND (ar.owner IS NULL OR ar.owner = '');
