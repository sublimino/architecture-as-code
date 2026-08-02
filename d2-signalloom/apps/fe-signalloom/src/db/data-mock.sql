-- data-mock.sql
-- Inserts realistic demo data for the OSRAMP Signal Loom dashboard.
-- Run AFTER data-reset.sql (or use scripts/signalloom-data.sh mock).
--
-- Data scope:
--   5 agents (Monty Python theme — matches cluster pods)
--   2 frameworks (EU AI Act, SOC 2) with 6 controls total
--   30 agent compliance results (5 agents x 6 controls)
--   12 audit events
--   3 violations
--   1 tenant settings row
--   1 API key
--   2 NHI scans + 5 discovered accounts
--   1 consent event
--   1 support request
--
-- All timestamps are July 2026. tenant_id = 'tenant-demo' throughout.
-- Agent names/models MUST match the Kubernetes pod labels in
-- d2-osramp-fleet/tenants/local/signalloom.yaml — the live API enriches
-- discovered pods with governance data from this table via the name column.

BEGIN;

-- ══════════════════════════════════════════════════════════════════════════════
-- Agents (5)
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.agent_registry (
    id, tenant_id, name, display_name, description, version, status,
    capabilities, owner, team, origin, foundry_built,
    model_provider, model_name, model_approved,
    connectors, policies_applied, compliance_mappings, compliance_posture, violations,
    lifecycle_state, last_transition_at, eu_ai_act_risk_class,
    created_at, updated_at
) VALUES
-- 1. Sir Lancelot — active, high-risk, well-governed (kagent, claude-opus-4-8)
(
    'a0000000-0000-0000-0000-000000000001', 'tenant-demo',
    'sir-lancelot', 'Sir Lancelot', 'Customer onboarding agent handling KYC verification and identity checks for new account applications.',
    '2.1.0', 'active',
    ARRAY['document_processing', 'kyc_verification', 'identity_check'],
    'lancelot@acme.co', 'Platform Engineering', 'Signal Loom Built', true,
    'Anthropic', 'claude-opus-4-8', true,
    '[{"name": "Salesforce", "direction": "read_write", "data_classification": "confidential"}]'::jsonb,
    '[{"id": "pol-1", "name": "Identity & Access Control", "applied_at": "2026-01-15"}]'::jsonb,
    '{"EU AI Act": ["Art. 9", "Art. 14"], "SOC2": ["CC6.1", "CC6.2"]}'::jsonb,
    92, '[]'::jsonb,
    'active', '2026-07-05 09:30:00+00', 'high',
    '2026-03-15 10:00:00+00', '2026-07-20 14:00:00+00'
),
-- 2. Dennis — active, minimal risk, Signal Loom Built (kagent, claude-haiku-4-5)
(
    'a0000000-0000-0000-0000-000000000002', 'tenant-demo',
    'dennis', 'Dennis', 'Internal documentation assistant that summarises meeting notes and generates action items for constitutional peasants.',
    '1.4.2', 'active',
    ARRAY['summarisation', 'note_taking', 'anarcho_syndicalism'],
    'dennis@acme.co', 'Knowledge Management', 'Signal Loom Built', true,
    'Anthropic', 'claude-haiku-4-5', true,
    '[]'::jsonb,
    '[{"id": "pol-1", "name": "Identity & Access Control", "applied_at": "2026-02-10"}]'::jsonb,
    '{"SOC2": ["CC6.1"]}'::jsonb,
    78, '[]'::jsonb,
    'active', '2026-07-01 11:00:00+00', 'minimal',
    '2026-04-20 08:30:00+00', '2026-07-18 16:45:00+00'
),
-- 3. The Black Knight — suspended, has violations, COTS (no framework, llama-3-70b)
(
    'a0000000-0000-0000-0000-000000000003', 'tenant-demo',
    'black-knight', 'The Black Knight', 'Legacy invoice processor from third-party vendor. Flagged for missing identity owner and excessive permissions.',
    '0.9.1', 'violation',
    ARRAY['invoice_processing', 'payment_routing'],
    NULL, 'Finance', 'COTS', false,
    'Meta', 'llama-3-70b', NULL,
    '[{"name": "SAP", "direction": "read_write", "data_classification": "restricted"}]'::jsonb,
    '[]'::jsonb,
    '{}'::jsonb,
    23,
    '[{"type": "no_identity", "severity": "critical", "description": "No Identity Owner assigned", "remediation": "Assign an Identity Owner via the Governance tab"}]'::jsonb,
    'suspended', '2026-07-12 15:20:00+00', 'high',
    '2026-01-10 14:00:00+00', '2026-07-22 10:30:00+00'
),
-- 4. Patsy — enrolled, not yet active, COTS (no framework, gpt-4o-mini)
(
    'a0000000-0000-0000-0000-000000000004', 'tenant-demo',
    'patsy', 'Patsy', 'Faithful logistics coordinator handling supply chain tracking and inventory reconciliation. Pending governance review before activation.',
    '0.1.0', 'inactive',
    ARRAY['logistics', 'inventory_tracking', 'supply_chain'],
    'patsy@acme.co', 'Operations', 'COTS', false,
    'OpenAI', 'gpt-4o-mini', NULL,
    '[]'::jsonb,
    '[]'::jsonb,
    '{}'::jsonb,
    NULL, '[]'::jsonb,
    'enrolled', NULL, 'limited',
    '2026-07-15 09:00:00+00', '2026-07-15 09:00:00+00'
),
-- 5. Sir Robin — active, COTS, moderate governance (no framework, mistral-large)
(
    'a0000000-0000-0000-0000-000000000005', 'tenant-demo',
    'sir-robin', 'Sir Robin', 'Threat intelligence aggregator that monitors external feeds and correlates with internal asset inventory. Bravely runs away from false positives.',
    '1.2.0', 'active',
    ARRAY['threat_intel', 'feed_aggregation', 'correlation'],
    'robin@acme.co', 'Security Operations', 'COTS', false,
    'Mistral', 'mistral-large', true,
    '[{"name": "Splunk", "direction": "write", "data_classification": "internal"}, {"name": "VirusTotal", "direction": "read", "data_classification": "public"}]'::jsonb,
    '[{"id": "pol-2", "name": "Data Classification", "applied_at": "2026-03-01"}]'::jsonb,
    '{"SOC2": ["CC7.2"]}'::jsonb,
    65,
    '[{"type": "stale_credentials", "severity": "medium", "description": "API token not rotated in 90+ days", "remediation": "Rotate the VirusTotal API token"}]'::jsonb,
    'active', '2026-07-08 13:00:00+00', 'not_classified',
    '2026-05-01 11:30:00+00', '2026-07-19 08:15:00+00'
)
ON CONFLICT (name) DO UPDATE SET
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    version = EXCLUDED.version,
    status = EXCLUDED.status,
    capabilities = EXCLUDED.capabilities,
    owner = EXCLUDED.owner,
    team = EXCLUDED.team,
    origin = EXCLUDED.origin,
    foundry_built = EXCLUDED.foundry_built,
    model_provider = EXCLUDED.model_provider,
    model_name = EXCLUDED.model_name,
    model_approved = EXCLUDED.model_approved,
    connectors = EXCLUDED.connectors,
    policies_applied = EXCLUDED.policies_applied,
    compliance_mappings = EXCLUDED.compliance_mappings,
    compliance_posture = EXCLUDED.compliance_posture,
    violations = EXCLUDED.violations,
    lifecycle_state = EXCLUDED.lifecycle_state,
    last_transition_at = EXCLUDED.last_transition_at,
    eu_ai_act_risk_class = EXCLUDED.eu_ai_act_risk_class;

-- ══════════════════════════════════════════════════════════════════════════════
-- Governance Frameworks (2) + Controls (6)
-- ══════════════════════════════════════════════════════════════════════════════

-- EU AI Act
INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body, compliance_deadline,
    control_count, activated_by
) VALUES (
    'f0000000-0000-0000-0000-000000000001', 'tenant-demo',
    'EU AI Act', '2024/1689', 'European Parliament', '2026-08-02',
    3, 'admin@acme.co'
) ON CONFLICT DO NOTHING;

-- SOC 2 Type II
INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body,
    control_count, activated_by
) VALUES (
    'f0000000-0000-0000-0000-000000000002', 'tenant-demo',
    'SOC 2 Type II', 'TSC 2017', 'AICPA',
    3, 'admin@acme.co'
) ON CONFLICT DO NOTHING;

-- EU AI Act controls
INSERT INTO public.governance_controls (id, tenant_id, framework_id, name, description, control_order) VALUES
('c0000000-0000-0000-0000-000000000001', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Traceability',
 'Art. 9 -- Agent has complete enrollment metadata (name, type, capabilities, owner). All state transitions recorded in audit trail with actor and reason.',
 1),
('c0000000-0000-0000-0000-000000000002', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Human Oversight',
 'Art. 14 -- Agent has a named Identity Owner (HumanPrincipal). Owner is active in directory. Agent is not operating without human accountability.',
 2),
('c0000000-0000-0000-0000-000000000003', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Incident Attribution',
 'Every violation is attributable to a specific agent with a traceable OBO chain to a human. Violation records include severity, analysis, and recommended action.',
 3)
ON CONFLICT DO NOTHING;

-- SOC 2 controls
INSERT INTO public.governance_controls (id, tenant_id, framework_id, name, description, control_order) VALUES
('c0000000-0000-0000-0000-000000000004', 'tenant-demo', 'f0000000-0000-0000-0000-000000000002',
 'CC6.1 -- Logical Access Security',
 'Agent has Identity Owner assigned. Credentials are scoped (not wildcard). Token TTL <= 60 minutes.',
 1),
('c0000000-0000-0000-0000-000000000005', 'tenant-demo', 'f0000000-0000-0000-0000-000000000002',
 'CC6.2 -- System Access Controls',
 'Agent lifecycle state is active (not enrolled/suspended/revoked) for production access. Auth token validated before each action.',
 2),
('c0000000-0000-0000-0000-000000000006', 'tenant-demo', 'f0000000-0000-0000-0000-000000000002',
 'CC7.2 -- System Monitoring',
 'Agent has audit trail events within last 24 hours. No unresolved critical violations. Heartbeat received within SLA.',
 3)
ON CONFLICT DO NOTHING;

-- ══════════════════════════════════════════════════════════════════════════════
-- Agent Compliance Results (30 = 5 agents x 6 controls)
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.agent_compliance_results (
    tenant_id, agent_id, control_id, status, assessed_at, evidence_ref
) VALUES
-- Sir Lancelot: 5 pass, 1 pass
('tenant-demo', 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'pass', '2026-07-20 10:00:00+00', 'opa://assessments/lancelot/traceability/2026-07-20'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002', 'pass', '2026-07-20 10:00:00+00', 'opa://assessments/lancelot/human-oversight/2026-07-20'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000003', 'pass', '2026-07-20 10:00:00+00', 'opa://assessments/lancelot/incident-attribution/2026-07-20'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000004', 'pass', '2026-07-20 10:00:00+00', 'opa://assessments/lancelot/cc6.1/2026-07-20'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000005', 'pass', '2026-07-20 10:00:00+00', 'opa://assessments/lancelot/cc6.2/2026-07-20'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000006', 'pass', '2026-07-20 10:00:00+00', 'opa://assessments/lancelot/cc7.2/2026-07-20'),

-- Dennis: 4 pass, 1 pending, 1 pass
('tenant-demo', 'a0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001', 'pass', '2026-07-18 14:00:00+00', 'opa://assessments/dennis/traceability/2026-07-18'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'pass', '2026-07-18 14:00:00+00', 'opa://assessments/dennis/human-oversight/2026-07-18'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000003', 'pending', NULL, NULL),
('tenant-demo', 'a0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000004', 'pass', '2026-07-18 14:00:00+00', 'opa://assessments/dennis/cc6.1/2026-07-18'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000005', 'pass', '2026-07-18 14:00:00+00', 'opa://assessments/dennis/cc6.2/2026-07-18'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000006', 'pass', '2026-07-18 14:00:00+00', 'opa://assessments/dennis/cc7.2/2026-07-18'),

-- The Black Knight: 2 fail, 2 fail, 2 pending (worst governance)
('tenant-demo', 'a0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000001', 'fail', '2026-07-22 09:00:00+00', 'opa://assessments/black-knight/traceability/2026-07-22'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000002', 'fail', '2026-07-22 09:00:00+00', 'opa://assessments/black-knight/human-oversight/2026-07-22'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000003', 'fail', '2026-07-22 09:00:00+00', 'opa://assessments/black-knight/incident-attribution/2026-07-22'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000004', 'fail', '2026-07-22 09:00:00+00', 'opa://assessments/black-knight/cc6.1/2026-07-22'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000005', 'pending', NULL, NULL),
('tenant-demo', 'a0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000006', 'pending', NULL, NULL),

-- Patsy: all pending (newly enrolled, not yet assessed)
('tenant-demo', 'a0000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000001', 'pending', NULL, NULL),
('tenant-demo', 'a0000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000002', 'pending', NULL, NULL),
('tenant-demo', 'a0000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000003', 'pending', NULL, NULL),
('tenant-demo', 'a0000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000004', 'pending', NULL, NULL),
('tenant-demo', 'a0000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000005', 'pending', NULL, NULL),
('tenant-demo', 'a0000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000006', 'pending', NULL, NULL),

-- Sir Robin: 3 pass, 1 fail, 1 pass, 1 reassessment_requested
('tenant-demo', 'a0000000-0000-0000-0000-000000000005', 'c0000000-0000-0000-0000-000000000001', 'pass', '2026-07-19 11:00:00+00', 'opa://assessments/robin/traceability/2026-07-19'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000005', 'c0000000-0000-0000-0000-000000000002', 'pass', '2026-07-19 11:00:00+00', 'opa://assessments/robin/human-oversight/2026-07-19'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000005', 'c0000000-0000-0000-0000-000000000003', 'pass', '2026-07-19 11:00:00+00', 'opa://assessments/robin/incident-attribution/2026-07-19'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000005', 'c0000000-0000-0000-0000-000000000004', 'fail', '2026-07-19 11:00:00+00', 'opa://assessments/robin/cc6.1/2026-07-19'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000005', 'c0000000-0000-0000-0000-000000000005', 'pass', '2026-07-19 11:00:00+00', 'opa://assessments/robin/cc6.2/2026-07-19'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000005', 'c0000000-0000-0000-0000-000000000006', 'reassessment_requested', '2026-07-19 11:00:00+00', 'opa://assessments/robin/cc7.2/2026-07-19')
ON CONFLICT (agent_id, control_id) DO UPDATE SET
    status = EXCLUDED.status,
    assessed_at = EXCLUDED.assessed_at,
    evidence_ref = EXCLUDED.evidence_ref;

-- ══════════════════════════════════════════════════════════════════════════════
-- Lifecycle Transitions (6)
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.lifecycle_transitions (tenant_id, agent_id, from_state, to_state, actor, reason, timestamp) VALUES
('tenant-demo', 'a0000000-0000-0000-0000-000000000001', 'enrolled', 'active', 'admin@acme.co', 'Passed all governance checks during onboarding review.', '2026-07-05 09:30:00+00'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000002', 'enrolled', 'active', 'admin@acme.co', 'Documentation assistant approved for internal use.', '2026-07-01 11:00:00+00'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000003', 'enrolled', 'active', 'admin@acme.co', 'Legacy system onboarded from vendor contract.', '2026-02-10 14:00:00+00'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000003', 'active', 'suspended', 'wendy@acme.co', 'Critical violation: no identity owner assigned. Suspended pending remediation.', '2026-07-12 15:20:00+00'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000004', 'draft', 'enrolled', 'patsy@acme.co', 'Logistics coordinator submitted for governance review.', '2026-07-15 09:00:00+00'),
('tenant-demo', 'a0000000-0000-0000-0000-000000000005', 'enrolled', 'active', 'robin@acme.co', 'Threat intel agent activated after security review.', '2026-07-08 13:00:00+00');

-- ══════════════════════════════════════════════════════════════════════════════
-- Violations (3)
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.agent_violations (
    tenant_id, agent_id, violation_type, severity, analysis,
    recommended_action, framework, control, status,
    acknowledged_by, acknowledged_at, resolved_at,
    created_at
) VALUES
-- 1. Critical, new — The Black Knight missing identity owner
(
    'tenant-demo', 'a0000000-0000-0000-0000-000000000003',
    'no_identity', 'critical',
    'Agent has no Identity Owner assigned. This COTS agent was onboarded without governance review. No human principal is accountable for its actions.',
    'Assign an Identity Owner via the Governance tab. Consider suspending the agent until an owner is confirmed.',
    'EU AI Act', 'Human Oversight',
    'new', NULL, NULL, NULL,
    '2026-07-12 15:00:00+00'
),
-- 2. High, acknowledged — The Black Knight excessive permissions
(
    'tenant-demo', 'a0000000-0000-0000-0000-000000000003',
    'excessive_permissions', 'high',
    'Agent has read_write access to SAP financial data with no credential scoping. Token TTL exceeds 60-minute SLA.',
    'Scope credentials to invoice-read-only. Reduce token TTL to 60 minutes.',
    'SOC 2 Type II', 'CC6.1 -- Logical Access Security',
    'acknowledged', 'ciso@acme.co', '2026-07-14 10:00:00+00', NULL,
    '2026-07-12 15:05:00+00'
),
-- 3. Medium, resolved — Sir Robin stale credentials
(
    'tenant-demo', 'a0000000-0000-0000-0000-000000000005',
    'stale_credentials', 'medium',
    'VirusTotal API token has not been rotated in 92 days. Rotation SLA is 90 days.',
    'Rotate the VirusTotal API token and update the agent configuration.',
    'SOC 2 Type II', 'CC6.1 -- Logical Access Security',
    'resolved', 'robin@acme.co', '2026-07-10 09:00:00+00', '2026-07-11 16:30:00+00',
    '2026-07-09 08:00:00+00'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Audit Events (10)
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.audit_events (tenant_id, timestamp, event_type, agent_id, agent_name, actor, detail) VALUES
-- Enrollments
('tenant-demo', '2026-07-01 10:00:00+00', 'enrollment',
 'a0000000-0000-0000-0000-000000000002', 'Dennis',
 'admin@acme.co', '{"action": "agent_enrolled", "source": "foundry", "version": "1.4.2"}'::jsonb),
('tenant-demo', '2026-07-05 09:00:00+00', 'enrollment',
 'a0000000-0000-0000-0000-000000000001', 'Sir Lancelot',
 'admin@acme.co', '{"action": "agent_enrolled", "source": "foundry", "version": "2.1.0"}'::jsonb),
('tenant-demo', '2026-07-15 09:00:00+00', 'enrollment',
 'a0000000-0000-0000-0000-000000000004', 'Patsy',
 'patsy@acme.co', '{"action": "agent_enrolled", "source": "vendor", "version": "0.1.0"}'::jsonb),

-- State transitions
('tenant-demo', '2026-07-05 09:30:00+00', 'state_transition',
 'a0000000-0000-0000-0000-000000000001', 'Sir Lancelot',
 'admin@acme.co', '{"from_state": "enrolled", "to_state": "active", "reason": "Passed governance checks"}'::jsonb),
('tenant-demo', '2026-07-01 11:00:00+00', 'state_transition',
 'a0000000-0000-0000-0000-000000000002', 'Dennis',
 'admin@acme.co', '{"from_state": "enrolled", "to_state": "active", "reason": "Approved for internal use"}'::jsonb),
('tenant-demo', '2026-07-12 15:20:00+00', 'state_transition',
 'a0000000-0000-0000-0000-000000000003', 'The Black Knight',
 'wendy@acme.co', '{"from_state": "active", "to_state": "suspended", "reason": "Critical violation: no identity owner"}'::jsonb),

-- Compliance checks
('tenant-demo', '2026-07-20 10:00:00+00', 'compliance_check',
 'a0000000-0000-0000-0000-000000000001', 'Sir Lancelot',
 'opa-engine', '{"framework": "EU AI Act", "controls_passed": 3, "controls_failed": 0, "controls_pending": 0}'::jsonb),
('tenant-demo', '2026-07-18 14:00:00+00', 'compliance_check',
 'a0000000-0000-0000-0000-000000000002', 'Dennis',
 'opa-engine', '{"framework": "SOC 2 Type II", "controls_passed": 2, "controls_failed": 0, "controls_pending": 1}'::jsonb),
('tenant-demo', '2026-07-22 09:00:00+00', 'compliance_check',
 'a0000000-0000-0000-0000-000000000003', 'The Black Knight',
 'opa-engine', '{"framework": "EU AI Act", "controls_passed": 0, "controls_failed": 3, "controls_pending": 0}'::jsonb),

-- Violation detected
('tenant-demo', '2026-07-12 15:00:00+00', 'violation_detected',
 'a0000000-0000-0000-0000-000000000003', 'The Black Knight',
 'wendy@acme.co', '{"violation_type": "no_identity", "severity": "critical", "description": "No Identity Owner assigned"}'::jsonb),

-- Token issued
('tenant-demo', '2026-07-20 14:00:00+00', 'token_issued',
 'a0000000-0000-0000-0000-000000000001', 'Sir Lancelot',
 'token-service', '{"token_type": "bearer", "ttl_minutes": 60, "scopes": ["kyc:read", "kyc:write"]}'::jsonb);

-- ══════════════════════════════════════════════════════════════════════════════
-- Tenant Settings (1)
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.tenant_settings (
    tenant_id, org_name, plan_tier, status,
    selected_frameworks, api_key_status,
    consent_accepted_at, consent_document_versions, cookie_preferences
) VALUES (
    'tenant-demo', 'Acme Corporation', 'enterprise', 'active',
    '["eu-ai-act", "soc2"]'::jsonb, 'active',
    '2026-07-01 08:00:00+00',
    '{"terms": "1.2", "eula": "1.2", "privacy": "1.2"}'::jsonb,
    '{"strictly_necessary": true, "analytics": true}'::jsonb
) ON CONFLICT (tenant_id) DO UPDATE SET
    org_name = EXCLUDED.org_name,
    plan_tier = EXCLUDED.plan_tier,
    selected_frameworks = EXCLUDED.selected_frameworks;

-- ══════════════════════════════════════════════════════════════════════════════
-- API Key (1)
-- ══════════════════════════════════════════════════════════════════════════════
-- key_hash is SHA-256 of a fictional key. prefix_hint shows the first 14 chars.

INSERT INTO public.tenant_api_keys (
    tenant_id, key_hash, prefix_hint, scope, revealed_by_email
) VALUES (
    'tenant-demo',
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'sl_live_demo__',
    'tenant_admin',
    'admin@acme.co'
) ON CONFLICT DO NOTHING;

-- ══════════════════════════════════════════════════════════════════════════════
-- NHI Scans (2) + Discovered Accounts (5)
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.nhi_scans (
    id, tenant_id, scan_source, started_at, completed_at,
    total_entries_scanned, service_accounts_found, total_at_risk,
    accounts_discovered, triggered_by, status
) VALUES
('d0000000-0000-0000-0000-000000000001', 'tenant-demo',
 'entra_id', '2026-07-10 02:00:00+00', '2026-07-10 02:12:34+00',
 1247, 38, 5, 38, 'admin@acme.co', 'completed'),
('d0000000-0000-0000-0000-000000000002', 'tenant-demo',
 'entra_id', '2026-07-20 02:00:00+00', '2026-07-20 02:08:45+00',
 1312, 41, 4, 41, 'admin@acme.co', 'completed');

INSERT INTO public.nhi_discovered_accounts (
    tenant_id, scan_id, account_name, directory_source,
    owner_email, last_rotated, privilege_level, findings, status,
    scan_count, first_discovered_at, last_seen_at,
    rotation_status, expires_at
) VALUES
-- 1. svc-salesforce-sync — elevated, stale rotation
('tenant-demo', 'd0000000-0000-0000-0000-000000000002',
 'svc-salesforce-sync', 'entra_id',
 'lancelot@acme.co', '2026-04-01 00:00:00+00', 'elevated',
 '[{"type": "stale_rotation", "detail": "Last rotated 111 days ago"}]'::jsonb,
 'under_review', 2, '2026-07-10 02:05:00+00', '2026-07-20 02:03:00+00',
 'stale', '2027-04-01 00:00:00+00'),
-- 2. svc-ci-pipeline — standard, current
('tenant-demo', 'd0000000-0000-0000-0000-000000000002',
 'svc-ci-pipeline', 'entra_id',
 'devops@acme.co', '2026-07-15 00:00:00+00', 'standard',
 '[]'::jsonb,
 'enrolled', 2, '2026-07-10 02:06:00+00', '2026-07-20 02:04:00+00',
 'current', '2027-07-15 00:00:00+00'),
-- 3. svc-backup-agent — domain_admin, expiring soon
('tenant-demo', 'd0000000-0000-0000-0000-000000000002',
 'svc-backup-agent', 'entra_id',
 NULL, '2026-06-01 00:00:00+00', 'domain_admin',
 '[{"type": "excessive_privilege", "detail": "Domain admin for backup service"}, {"type": "expiring_soon", "detail": "Credential expires in 14 days"}]'::jsonb,
 'discovered', 2, '2026-07-10 02:07:00+00', '2026-07-20 02:05:00+00',
 'expiring_soon', '2026-08-10 00:00:00+00'),
-- 4. svc-monitoring — standard, dismissed
('tenant-demo', 'd0000000-0000-0000-0000-000000000001',
 'svc-monitoring', 'entra_id',
 'ops@acme.co', '2026-07-01 00:00:00+00', 'standard',
 '[]'::jsonb,
 'dismissed', 1, '2026-07-10 02:08:00+00', '2026-07-10 02:08:00+00',
 'current', '2027-07-01 00:00:00+00'),
-- 5. svc-legacy-erp — elevated, expired credential
('tenant-demo', 'd0000000-0000-0000-0000-000000000002',
 'svc-legacy-erp', 'entra_id',
 NULL, '2025-12-01 00:00:00+00', 'elevated',
 '[{"type": "expired_credential", "detail": "Credential expired 2026-06-01"}, {"type": "no_owner", "detail": "No owner email assigned"}]'::jsonb,
 'discovered', 2, '2026-07-10 02:09:00+00', '2026-07-20 02:06:00+00',
 'expired', '2026-06-01 00:00:00+00');

-- ══════════════════════════════════════════════════════════════════════════════
-- Consent Events (1)
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.consent_events (
    tenant_id, user_email, accepted_at,
    document_versions, cookie_preferences, b2b_warranty_accepted,
    user_agent
) VALUES (
    'tenant-demo', 'admin@acme.co', '2026-07-01 08:00:00+00',
    '{"terms": "1.2", "eula": "1.2", "privacy": "1.2"}'::jsonb,
    '{"strictly_necessary": true, "analytics": true}'::jsonb,
    true,
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/126.0.0.0'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Support Requests (1)
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.support_requests (
    tenant_id, subject, urgency, message, submitted_by
) VALUES (
    'tenant-demo',
    'Cannot assign Identity Owner to Black Knight agent',
    'high',
    'When I try to assign an Identity Owner to the Black Knight agent via the Governance tab, the save button remains greyed out. The agent is currently suspended. Browser: Chrome 126 on macOS. Tried clearing cache and different browser.',
    'ciso@acme.co'
);

COMMIT;
