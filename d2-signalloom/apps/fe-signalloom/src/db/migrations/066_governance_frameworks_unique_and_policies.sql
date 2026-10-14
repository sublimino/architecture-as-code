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
