-- ══════════════════════════════════════════════════════════════════════════════
-- 061 — stable mapping from governance controls to policy-engine checks
-- ══════════════════════════════════════════════════════════════════════════════
--
-- The policy scan reconciles each engine verdict onto agent_compliance_results.
-- Before this migration it matched the engine's check id / control name against
-- governance_controls.name / id, which never matched a seeded row and, when it
-- did, stamped one verdict on every agent's row.
--
--   governance_controls.policy_framework_id  policy-engine pack id
--                                            (e.g. 'cis-kubernetes', 'finos-aigf')
--   governance_controls.policy_check_id      check id inside that pack
--                                            (e.g. 'no-privileged-containers')
--       Both NULL for controls no engine check evaluates.  Unique per tenant,
--       so a verdict maps to at most one control.
--
--   agent_registry.workload_spec             the agent's Kubernetes workload
--                                            (Pod, or a controller with a pod
--                                            template); the scan's CEL `object`.
--                                            NULL when none is recorded: the scan
--                                            then sends no object, it never
--                                            invents one.
--
--   agent_compliance_results.status          gains 'error': the check could not
--                                            evaluate.  Never a pass, never a fail.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS, and the
-- status CHECK is dropped and re-added under its original name.

BEGIN;

ALTER TABLE public.governance_controls
    ADD COLUMN IF NOT EXISTS policy_framework_id TEXT,
    ADD COLUMN IF NOT EXISTS policy_check_id     TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS uq_governance_controls_policy_check
    ON public.governance_controls (tenant_id, policy_framework_id, policy_check_id)
    WHERE policy_framework_id IS NOT NULL AND policy_check_id IS NOT NULL;

ALTER TABLE public.agent_registry
    ADD COLUMN IF NOT EXISTS workload_spec JSONB;

ALTER TABLE public.agent_compliance_results
    DROP CONSTRAINT IF EXISTS agent_compliance_results_status_check;
ALTER TABLE public.agent_compliance_results
    ADD CONSTRAINT agent_compliance_results_status_check
    CHECK (status IN ('pass', 'fail', 'error', 'pending', 'reassessment_requested'));

COMMIT;
