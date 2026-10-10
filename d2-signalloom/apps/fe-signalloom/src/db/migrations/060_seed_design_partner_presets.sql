-- ══════════════════════════════════════════════════════════════════════════════
-- 060: seed design partner presets (Kusari and tenant-demo) and initial superadmin
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Seeds default feature flags for design partner tenant 'kusari':
--   - Enabled: core_governance, audit, compliance
--   - Disabled: demos_fleet, supercred, rbac_analysis, collusion_access
--
-- Seeds default feature flags for demonstration tenant 'tenant-demo':
--   - Enabled: core_governance, audit, compliance, demos_fleet, supercred, rbac_analysis, collusion_access
--
-- Seeds initial platform superadmin accounts:
--   - demo-user@signalloom.local (tenant: tenant-demo, is_superadmin: true)
--   - admin@kusari.demo (tenant: kusari, is_superadmin: true)
--
-- All inserts use ON CONFLICT clauses to ensure strict forward-only idempotency.

BEGIN;

-- 1. Seed Kusari and Tenant-Demo Feature Flags
INSERT INTO public.tenant_feature_flags (
    tenant_id,
    flag_key,
    enabled,
    config_json,
    created_at,
    updated_at
) VALUES
    ('kusari', 'core_governance', TRUE,  '{"description": "Core governance policies, agent registry, and guardrails"}'::jsonb, NOW(), NOW()),
    ('kusari', 'audit',           TRUE,  '{"description": "Authoritative immutable audit log and provenance stream"}'::jsonb, NOW(), NOW()),
    ('kusari', 'compliance',      TRUE,  '{"description": "Compliance posture dashboards and regulatory framework evaluation"}'::jsonb, NOW(), NOW()),
    ('kusari', 'demos_fleet',     FALSE, '{"description": "Demo fleet simulation scenarios and testing controls"}'::jsonb, NOW(), NOW()),
    ('kusari', 'supercred',       FALSE, '{"description": "SuperCred privilege escalation demonstration surfaces"}'::jsonb, NOW(), NOW()),
    ('kusari', 'rbac_analysis',   FALSE, '{"description": "Experimental AFM formal RBAC graph visualization"}'::jsonb, NOW(), NOW()),
    ('kusari', 'collusion_access',FALSE, '{"description": "Experimental multi-agent collusion detection matrix"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'core_governance', TRUE,  '{"description": "Core governance policies, agent registry, and guardrails"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'audit',           TRUE,  '{"description": "Authoritative immutable audit log and provenance stream"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'compliance',      TRUE,  '{"description": "Compliance posture dashboards and regulatory framework evaluation"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'demos_fleet',     TRUE,  '{"description": "Demo fleet simulation scenarios and testing controls"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'supercred',       TRUE,  '{"description": "SuperCred privilege escalation demonstration surfaces"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'rbac_analysis',   TRUE,  '{"description": "Experimental AFM formal RBAC graph visualization"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'collusion_access',TRUE,  '{"description": "Experimental multi-agent collusion detection matrix"}'::jsonb, NOW(), NOW())
ON CONFLICT (tenant_id, flag_key) DO UPDATE SET
    enabled = EXCLUDED.enabled,
    config_json = EXCLUDED.config_json,
    updated_at = NOW();

-- 2. Seed Initial Platform Superadmin Users
-- Uses stable UUIDs for deterministic bootstrap reconciliation.
INSERT INTO public.platform_users (
    id,
    tenant_id,
    email,
    display_name,
    role,
    status,
    department,
    title,
    is_superadmin,
    created_at,
    updated_at
) VALUES
    (
        'a0000000-0000-0000-0000-000000000000',
        'tenant-demo',
        'demo-user@signalloom.local',
        'Platform Superadmin',
        'admin',
        'active',
        'Platform Engineering',
        'Superadmin Operator',
        TRUE,
        NOW(),
        NOW()
    ),
    (
        'a0000000-0000-0000-0000-000000000001',
        'kusari',
        'admin@kusari.demo',
        'Kusari Admin',
        'admin',
        'active',
        'Security Operations',
        'Design Partner Lead',
        TRUE,
        NOW(),
        NOW()
    )
ON CONFLICT (tenant_id, email) DO UPDATE SET
    role = EXCLUDED.role,
    status = EXCLUDED.status,
    is_superadmin = EXCLUDED.is_superadmin,
    updated_at = NOW();

-- Ensure any preexisting record for seeded superadmins is also elevated
UPDATE public.platform_users
SET is_superadmin = TRUE,
    role = 'admin',
    status = 'active',
    updated_at = NOW()
WHERE email IN ('demo-user@signalloom.local', 'admin@kusari.demo');

COMMIT;
