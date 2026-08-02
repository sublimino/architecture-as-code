// Fake-data fixtures for demo mode.
//
// resolveFake(method, path, body) returns a shape-valid fixture for any of the
// 27 client endpoints when demo mode is on, or `undefined` if no route matches
// (in which case client.ts falls through to a real HTTP call). Every fixture is
// typed against ../types/api so the compiler enforces contract fidelity — the
// same guarantee the backend Pydantic models give server-side.

import type {
  AgentListResponse,
  AgentResponse,
  AuditListResponse,
  ComplianceSummaryResponse,
  ConsentAcceptResponse,
  ConsentStatusResponse,
  CookiePreferencesResponse,
  FrameworkResponse,
  InitialApiKeyResponse,
  IssueCredentialResponse,
  NHIDiscoveredResponse,
  NHIScanListResponse,
  PostureResponse,
  ReassessmentResponse,
  RotateApiKeyResponse,
  SupportRequestResponse,
  TenantSettingsResponse,
  TransitionResponse,
  ViolationListResponse,
} from '../types/api'

import { COMPLIANCE_POLICY_ROUTES, COMPLIANCE_POLICY_ROUTE_COUNT } from './fakeComplianceData'

const TENANT = 'tenant-demo'
const NOW = '2026-07-27T12:00:00Z'

// ─── Agents ──────────────────────────────────────────────────────────────────

function agent(
  id: string,
  name: string,
  state: string,
  risk: string,
  overrides?: Partial<AgentResponse['compliance_summary']> & { type?: string; owner?: string },
): AgentResponse {
  return {
    id: `${TENANT}:${id}`,
    name,
    type: overrides?.type ?? 'Signal Loom Built',
    owner: overrides?.owner ?? 'demo-user',
    tenant_id: TENANT,
    lifecycle_state: state,
    last_transition_at: '2026-07-20T10:00:00Z',
    last_transition_by: 'demo-user',
    eu_ai_act_risk_class: risk,
    compliance_summary: {
      total_controls: overrides?.total_controls ?? 12,
      passing: overrides?.passing ?? 10,
      failing: overrides?.failing ?? 0,
      pending: overrides?.pending ?? 2,
      posture_score: overrides?.posture_score ?? 83,
    },
    model_name: 'gpt-4o',
    created_at: '2026-06-01T09:00:00Z',
  }
}

const AGENTS: AgentResponse[] = [
  agent('agent-inventory', 'Inventory Agent', 'active', 'limited'),
  agent('agent-triage', 'Triage Agent', 'active', 'high', { failing: 2, passing: 8, posture_score: 68 }),
  agent('agent-sandbox', 'Sandbox Agent', 'enrolled', 'minimal', { posture_score: null, passing: 0, pending: 12 }),
  agent('agent-remediation', 'Remediation Agent', 'active', 'high', { failing: 0, passing: 12, posture_score: 95 }),
  agent('agent-scanner', 'Vulnerability Scanner', 'suspended', 'limited', { failing: 3, passing: 7, posture_score: 42, type: 'COTS', owner: 'security-team' }),
  agent('agent-reporter', 'Compliance Reporter', 'active', 'minimal', { failing: 1, passing: 9, posture_score: 78, type: 'Custom' }),
]

const agentList: AgentListResponse = { agents: AGENTS, total: AGENTS.length }

const issueCredential: IssueCredentialResponse = {
  agent_id: `${TENANT}:agent-inventory`,
  name: 'Inventory Agent',
  identity_token: 'demo.jwt.token-shown-once',
  token_expires_at: '2026-08-27T12:00:00Z',
  token_note: 'Demo credential — not a real secret.',
}

const transition: TransitionResponse = {
  agent_id: `${TENANT}:agent-inventory`,
  from_state: 'draft',
  to_state: 'active',
  actor: 'demo-user',
  reason: 'Promoted in demo mode',
  timestamp: NOW,
}

const reassessment: ReassessmentResponse = {
  agent_id: `${TENANT}:agent-inventory`,
  control_id: 'AIC-1',
  status: 'reassessment_requested',
  reassessment_requested_at: NOW,
  reassessment_requested_by: 'demo-user',
  clickup_task_id: null,
}

const violations: ViolationListResponse = {
  violations: [
    {
      id: `${TENANT}:v-1`,
      agent_id: `${TENANT}:agent-triage`,
      violation_type: 'excessive_scope',
      severity: 'medium',
      analysis: 'Agent requested scopes beyond its declared purpose.',
      recommended_action: 'Reduce granted scopes to read-only.',
      status: 'new',
      acknowledged_by: null,
      acknowledged_at: null,
      resolved_at: null,
      created_at: '2026-07-25T08:00:00Z',
    },
  ],
  total: 1,
}

// ─── Compliance ───────────────────────────────────────────────────────────────

const complianceSummary: ComplianceSummaryResponse = {
  total_agents: AGENTS.length,
  agents_assessed: AGENTS.length,
  controls_passing: 28,
  controls_failing: 6,
  controls_pending: 5,
  posture_score: 74,
}

const posture: PostureResponse = {
  agents: AGENTS.map((a) => ({
    agent_id: a.id,
    agent_name: a.name,
    posture_score: 83,
    results: [
      {
        agent_id: a.id,
        control_id: 'AIC-1',
        control_name: 'Access boundary enforced',
        framework_name: 'EU AI Act',
        status: 'pass',
        assessed_at: '2026-07-26T00:00:00Z',
        evidence_ref: 'evidence://demo/aic-1',
      },
    ],
  })),
}

const frameworks: FrameworkResponse[] = [
  {
    id: 'eu-ai-act',
    name: 'EU AI Act',
    version: '2024',
    regulatory_body: 'European Commission',
    compliance_deadline: '2026-08-02',
    control_count: 2,
    controls: [
      { id: 'AIC-1', name: 'Access boundary enforced', description: 'Tenant isolation holds.', control_order: 1 },
      { id: 'AIC-2', name: 'Human oversight', description: 'A human can halt the agent.', control_order: 2 },
    ],
  },
]

const complianceExport = { format: 'json', generated_at: NOW, url: 'blob://demo/compliance-report.json' }

// ─── Audit ───────────────────────────────────────────────────────────────────

const audit: AuditListResponse = {
  events: [
    {
      id: `${TENANT}:evt-1`,
      timestamp: NOW,
      event_type: 'agent.registered',
      agent_id: `${TENANT}:agent-inventory`,
      agent_name: 'Inventory Agent',
      actor: 'demo-user',
      detail: { source: 'demo' },
    },
    {
      id: `${TENANT}:evt-2`,
      timestamp: '2026-07-26T09:30:00Z',
      event_type: 'agent.transitioned',
      agent_id: `${TENANT}:agent-triage`,
      agent_name: 'Triage Agent',
      actor: 'demo-user',
      detail: { from: 'draft', to: 'active' },
    },
  ],
  total: 2,
  page: 1,
  limit: 25,
}

// ─── NHI ─────────────────────────────────────────────────────────────────────

const nhiScans: NHIScanListResponse = {
  scans: [
    {
      id: `${TENANT}:scan-1`,
      tenant_id: TENANT,
      scan_source: 'entra',
      started_at: '2026-07-27T06:00:00Z',
      completed_at: '2026-07-27T06:05:00Z',
      total_entries_scanned: 420,
      service_accounts_found: 37,
      total_at_risk: 4,
      status: 'completed',
    },
  ],
}

const nhiDiscovered: NHIDiscoveredResponse = {
  accounts: [
    {
      id: `${TENANT}:nhi-1`,
      scan_id: `${TENANT}:scan-1`,
      account_name: 'svc-billing-sync',
      directory_source: 'entra',
      owner_email: 'ops@signalloom.local',
      last_credential_rotation: '2025-01-10T00:00:00Z',
      privilege_level: 'high',
      status: 'discovered',
      findings: ['stale_credential', 'over_privileged'],
      scan_count: 3,
      dismissed_at: null,
      dismissed_by: null,
      changes_since_dismissal: null,
      previous_risk_flags: null,
      first_discovered_at: '2026-06-01T00:00:00Z',
      last_seen_at: NOW,
    },
  ],
  total: 1,
  summary: { total_discovered: 1, needs_triage: 1, previously_dismissed: 0 },
}

const nhiReport = { tenant_id: TENANT, generated_at: NOW, at_risk: 4, format: 'json' }

// ─── Tenant / settings ─────────────────────────────────────────────────────────

const COOKIE_PREFS = { strictly_necessary: true, analytics: false }

function tenantSettings(selected: string[] = ['eu-ai-act']): TenantSettingsResponse {
  return {
    tenant_id: TENANT,
    org_name: 'Acme Co. (demo)',
    plan_tier: 'enterprise',
    agent_count: AGENTS.length,
    billing_tier: 'enterprise',
    api_key_status: 'active',
    selected_frameworks: selected,
    consent_required: false,
    cookie_preferences: COOKIE_PREFS,
  }
}

const support: SupportRequestResponse = {
  id: `${TENANT}:sup-1`,
  subject: 'Demo support request',
  urgency: 'normal',
  submitted_at: NOW,
  clickup_task_id: null,
}

// ─── API keys ──────────────────────────────────────────────────────────────────

const initialApiKey: InitialApiKeyResponse = {
  key: 'sl_live_demo0000000000000000000000',
  prefix_hint: 'sl_live_demo00',
  revealed_at: NOW,
}
const rotateApiKey: RotateApiKeyResponse = { ...initialApiKey, scope: 'tenant:rw' }

// ─── Consent / cookies ─────────────────────────────────────────────────────────

const DOC_VERSIONS = { terms: '1.2', eula: '1.2', privacy: '1.2' }

const consentStatus: ConsentStatusResponse = {
  accepted: true,
  consent_required: false,
  accepted_at: NOW,
  document_versions: DOC_VERSIONS,
  cookie_preferences: COOKIE_PREFS,
}
const consentAccept: ConsentAcceptResponse = {
  accepted: true,
  accepted_at: NOW,
  document_versions: DOC_VERSIONS,
  cookie_preferences: COOKIE_PREFS,
}
const cookiePrefs: CookiePreferencesResponse = { cookie_preferences: COOKIE_PREFS }

// ─── Resolver ──────────────────────────────────────────────────────────────────

type Match = {
  method: string
  test: (path: string) => boolean
  data: (path: string, body?: unknown) => unknown
}

const re = (r: RegExp) => (path: string) => r.test(path)

// Ordered most-specific-first; paths are the raw values passed to req() in
// client.ts (query string stripped before matching).
const ROUTES: Match[] = [
  // agents
  { method: 'GET', test: re(/^\/agents$/), data: () => agentList },
  { method: 'POST', test: re(/^\/agents$/), data: (_p, body) => ({
      ...agent('agent-new', (body as { name?: string })?.name ?? 'New Agent', 'draft', 'minimal'),
    }) },
  { method: 'POST', test: re(/^\/agents\/[^/]+\/credentials$/), data: () => issueCredential },
  { method: 'POST', test: re(/^\/agents\/[^/]+\/transition$/), data: () => transition },
  { method: 'GET', test: re(/^\/agents\/[^/]+\/violations$/), data: () => violations },
  { method: 'POST', test: re(/^\/agents\/violations\/[^/]+\/acknowledge$/), data: () => ({ status: 'acknowledged' }) },
  { method: 'POST', test: re(/^\/agents\/[^/]+\/compliance\/[^/]+\/reassess$/), data: () => reassessment },
  { method: 'GET', test: re(/^\/agents\/[^/]+$/), data: () => AGENTS[0] },
  // compliance
  { method: 'GET', test: re(/^\/compliance\/summary$/), data: () => complianceSummary },
  { method: 'GET', test: re(/^\/compliance\/posture$/), data: () => posture },
  { method: 'GET', test: re(/^\/compliance\/frameworks$/), data: () => frameworks },
  { method: 'GET', test: re(/^\/compliance\/export$/), data: () => complianceExport },
  // audit
  { method: 'GET', test: re(/^\/audit$/), data: () => audit },
  // nhi
  { method: 'GET', test: re(/^\/nhi\/scans$/), data: () => nhiScans },
  { method: 'GET', test: re(/^\/nhi\/discovered$/), data: () => nhiDiscovered },
  { method: 'POST', test: re(/^\/nhi\/discovered\/[^/]+\/enroll$/), data: (p) => ({ account_id: p.split('/')[3], status: 'enrollment_requested' }) },
  { method: 'POST', test: re(/^\/nhi\/discovered\/[^/]+\/dismiss$/), data: (p) => ({ account_id: p.split('/')[3], status: 'dismissed' }) },
  { method: 'GET', test: re(/^\/nhi\/report\/json$/), data: () => nhiReport },
  // tenant / support
  { method: 'GET', test: re(/^\/tenant\/settings$/), data: () => tenantSettings() },
  { method: 'PATCH', test: re(/^\/tenant\/settings\/frameworks$/), data: (_p, body) =>
      tenantSettings((body as { selected_frameworks?: string[] })?.selected_frameworks ?? ['eu-ai-act']) },
  { method: 'POST', test: re(/^\/support$/), data: () => support },
  // api keys
  { method: 'POST', test: re(/^\/tenants\/[^/]+\/api-keys\/initial$/), data: () => initialApiKey },
  { method: 'POST', test: re(/^\/tenants\/[^/]+\/api-keys\/rotate$/), data: () => rotateApiKey },
  // consent / cookies
  { method: 'GET', test: re(/^\/consent\/status$/), data: () => consentStatus },
  { method: 'POST', test: re(/^\/consent\/accept$/), data: () => consentAccept },
  { method: 'GET', test: re(/^\/cookie-preferences$/), data: () => cookiePrefs },
  { method: 'PATCH', test: re(/^\/cookie-preferences$/), data: () => cookiePrefs },
  // compliance-policy routes (policy-as-versioned-code)
  ...COMPLIANCE_POLICY_ROUTES,
]

/** Number of distinct demo routes — asserted by the vitest to match the client surface.
 *  27 base + 3 compliance-policy = 30 */
export const FAKE_ROUTE_COUNT = ROUTES.length

/**
 * Resolve a fixture for a client request, or undefined if no demo route matches.
 * `path` is the raw path passed to req() (e.g. '/agents/123', '/audit?page=1').
 */
export function resolveFake(method: string, path: string, body?: unknown): unknown | undefined {
  const clean = path.replace(/^\/api/, '').split('?')[0]
  const m = ROUTES.find((r) => r.method === method.toUpperCase() && r.test(clean))
  return m ? m.data(clean, body) : undefined
}
