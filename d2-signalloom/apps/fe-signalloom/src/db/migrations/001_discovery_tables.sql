-- Migration: 001_discovery_tables
--
-- Creates discovery_scan_sessions and discovered_agents tables.
-- Idempotent: CREATE TABLE IF NOT EXISTS + CREATE INDEX IF NOT EXISTS.

BEGIN;

CREATE TABLE IF NOT EXISTS public.discovery_scan_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR NOT NULL,
    email_domain VARCHAR NOT NULL,
    company_name VARCHAR NOT NULL,
    industry VARCHAR NOT NULL,
    platforms JSONB NOT NULL,
    status VARCHAR NOT NULL DEFAULT 'pending',
    agent_count INTEGER,
    governance_score INTEGER,
    ungoverned_count INTEGER,
    report_blob_url VARCHAR,
    hubspot_contact_id VARCHAR,
    error_message VARCHAR,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS public.discovered_agents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID REFERENCES discovery_scan_sessions(id) ON DELETE CASCADE,
    platform VARCHAR NOT NULL,
    external_id VARCHAR NOT NULL,
    name VARCHAR NOT NULL,
    model VARCHAR,
    tools_enabled JSONB,
    logging_enabled BOOLEAN DEFAULT FALSE,
    has_system_prompt BOOLEAN DEFAULT FALSE,
    creation_date TIMESTAMPTZ,
    governance_score INTEGER,
    compliance_gaps JSONB,
    risk_level VARCHAR,
    discovered_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_discovered_agents_session_id ON discovered_agents(session_id);
CREATE INDEX IF NOT EXISTS idx_discovery_scan_sessions_email_domain ON discovery_scan_sessions(email_domain);

COMMIT;
