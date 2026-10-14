-- ══════════════════════════════════════════════════════════════════════════════
-- 065: seed granular page feature flags for design partner (kusari) and demo
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Seeds granular page flags for design partner tenant 'kusari' (EAP Pilot Preset):
--   - Enabled: page_discovery, page_agents, page_topology, page_weave, page_signals,
--              page_risk, page_policies, page_compliance, page_audit,
--              page_federated_services, page_cryptography, page_credential_inventory
--   - Disabled: page_signal_store, page_feeds, page_network_tests, page_agentmaxxing
--
-- Seeds granular page flags for demonstration tenant 'tenant-demo' (Full Demo Preset):
--   - Enabled: all granular page flags
--
-- Idempotent upserts via ON CONFLICT (tenant_id, flag_key).

BEGIN;

INSERT INTO public.tenant_feature_flags (
    tenant_id,
    flag_key,
    enabled,
    config_json,
    created_at,
    updated_at
) VALUES
    -- Kusari EAP Pilot Granular Flags (Operational & Governance enabled, Labs disabled)
    ('kusari', 'page_discovery',            TRUE,  '{"description": "Workload discovery and accounts inventory"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_agents',               TRUE,  '{"description": "Governed agent registry and state details"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_topology',             TRUE,  '{"description": "Agent trust topology and communication graph"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_weave',                TRUE,  '{"description": "Real-time agent interaction weave"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_signals',              TRUE,  '{"description": "Live agent signal stream and anomalies"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_risk',                 TRUE,  '{"description": "Risk exposure and vulnerability tracking"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_policies',             TRUE,  '{"description": "Agent governance policies and guardrail rules"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_compliance',           TRUE,  '{"description": "Regulatory posture and compliance frameworks"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_audit',                TRUE,  '{"description": "Immutable audit trail and provenance verification"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_federated_services',   TRUE,  '{"description": "Federated AI services and model connectors"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_cryptography',         TRUE,  '{"description": "Cryptographic material and key management"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_credential_inventory', TRUE,  '{"description": "Agent credential and token inventory"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_signal_store',         FALSE, '{"description": "Signal storage explorer and FrostDB segments"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_feeds',                FALSE, '{"description": "Raw telemetry feeds and transport debugging"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_network_tests',        FALSE, '{"description": "Diagnostic network testing and port probes"}'::jsonb, NOW(), NOW()),
    ('kusari', 'page_agentmaxxing',         FALSE, '{"description": "Experimental AgentMaxxing progressive containment lab"}'::jsonb, NOW(), NOW()),

    -- Tenant Demo Granular Flags (All Enabled for Full Demonstration)
    ('tenant-demo', 'page_discovery',            TRUE, '{"description": "Workload discovery and accounts inventory"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_agents',               TRUE, '{"description": "Governed agent registry and state details"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_topology',             TRUE, '{"description": "Agent trust topology and communication graph"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_weave',                TRUE, '{"description": "Real-time agent interaction weave"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_signals',              TRUE, '{"description": "Live agent signal stream and anomalies"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_risk',                 TRUE, '{"description": "Risk exposure and vulnerability tracking"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_policies',             TRUE, '{"description": "Agent governance policies and guardrail rules"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_compliance',           TRUE, '{"description": "Regulatory posture and compliance frameworks"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_audit',                TRUE, '{"description": "Immutable audit trail and provenance verification"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_federated_services',   TRUE, '{"description": "Federated AI services and model connectors"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_cryptography',         TRUE, '{"description": "Cryptographic material and key management"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_credential_inventory', TRUE, '{"description": "Agent credential and token inventory"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_signal_store',         TRUE, '{"description": "Signal storage explorer and FrostDB segments"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_feeds',                TRUE, '{"description": "Raw telemetry feeds and transport debugging"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_network_tests',        TRUE, '{"description": "Diagnostic network testing and port probes"}'::jsonb, NOW(), NOW()),
    ('tenant-demo', 'page_agentmaxxing',         TRUE, '{"description": "Experimental AgentMaxxing progressive containment lab"}'::jsonb, NOW(), NOW())
ON CONFLICT (tenant_id, flag_key) DO UPDATE SET
    enabled = EXCLUDED.enabled,
    config_json = EXCLUDED.config_json,
    updated_at = NOW();

COMMIT;
