// Fake-data fixtures for demo mode.
//
// resolveFake(method, path, body) returns a shape-valid fixture for any of the
// client endpoints when demo mode is on, or `undefined` if a matched demo route
// cannot resolve a resource (for example, GET /agents/{missing-id}). Every fixture is
// typed against ../types/api so the compiler enforces contract fidelity — the
// same guarantee the backend Pydantic models give server-side.

import type {
  AgentCreateRequest,
  AgentListResponse,
  AgentResponse,
  AuditListResponse,
  ComplianceSummaryResponse,
  ConsentAcceptResponse,
  ConsentStatusResponse,
  CookiePreferencesResponse,
  CryptoHealthResponse,
  FrameworkResponse,
  InitialApiKeyResponse,
  IssueCredentialResponse,
  NHIDiscoveredResponse,
  NHIScanListResponse,
  PlatformUsersResponse,
  PostureResponse,
  ReassessmentResponse,
  RevokeCredentialResponse,
  RotateApiKeyResponse,
  SupportRequestResponse,
  TenantSettingsResponse,
  TransitionResponse,
  ViolationListResponse,
} from '../types/api'

import type { StunAgentResponse } from '../types/api'
import { COMPLIANCE_POLICY_ROUTES } from './fakeComplianceData'
import { WEAVE_ROUTES } from './fakeWeaveData'
import { networkTestsFixture, networkTestsScanFixture } from './fakeNetworkTestsData'
import { demoActivityEvents, recordDemoActivity } from './demoActivity'
import { simulatedAgentIdentity } from './supercredTypes'

const TENANT = 'tenant-demo'
const NOW = '2026-07-27T12:00:00Z'

interface DemoAgentRecord {
  agent: AgentResponse
  activeCredentialCount: number
}

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

function buildInitialAgents(): DemoAgentRecord[] {
  return [
    { agent: agent('agent-inventory', 'Inventory Agent', 'active', 'limited'), activeCredentialCount: 1 },
    { agent: agent('agent-triage', 'Triage Agent', 'active', 'high', { failing: 2, passing: 8, posture_score: 68 }), activeCredentialCount: 2 },
    { agent: agent('agent-sandbox', 'Sandbox Agent', 'enrolled', 'minimal', { posture_score: null, passing: 0, pending: 12 }), activeCredentialCount: 0 },
    { agent: agent('agent-remediation', 'Remediation Agent', 'active', 'high', { failing: 0, passing: 12, posture_score: 95 }), activeCredentialCount: 1 },
    { agent: agent('agent-scanner', 'Vulnerability Scanner', 'suspended', 'limited', { failing: 3, passing: 7, posture_score: 42, type: 'COTS', owner: 'security-team' }), activeCredentialCount: 0 },
    { agent: agent('agent-reporter', 'Compliance Reporter', 'active', 'minimal', { failing: 1, passing: 9, posture_score: 78, type: 'Custom' }), activeCredentialCount: 1 },
  ]
}

let demoAgents = buildInitialAgents()

function cloneAgent(agentResponse: AgentResponse): AgentResponse {
  return {
    ...agentResponse,
    compliance_summary: { ...agentResponse.compliance_summary },
  }
}

function readAgentId(path: string): string {
  const [, , rawId = ''] = path.split('/')
  return decodeURIComponent(rawId)
}

function nowIso(): string {
  return new Date().toISOString()
}

function findDemoAgent(id: string): DemoAgentRecord | undefined {
  return demoAgents.find((record) => record.agent.id === id)
}

function listAgents(): AgentListResponse {
  const agents = demoAgents.map((record) => cloneAgent(record.agent))
  return { agents, total: agents.length }
}

function readAgent(path: string): AgentResponse | undefined {
  const record = findDemoAgent(readAgentId(path))
  return record ? cloneAgent(record.agent) : undefined
}

function readAgentUpdate(body: unknown): Partial<AgentResponse> {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new Error('Demo agent update requires an object body.')
  }
  return body as Partial<AgentResponse>
}

function updateAgent(path: string, body: unknown): AgentResponse | undefined {
  const record = findDemoAgent(readAgentId(path))
  if (!record) return undefined
  const update = readAgentUpdate(body)
  record.agent = {
    ...record.agent,
    ...update,
    compliance_summary: update.compliance_summary
      ? { ...record.agent.compliance_summary, ...update.compliance_summary }
      : record.agent.compliance_summary,
  }
  return cloneAgent(record.agent)
}

function readAgentCreate(body: unknown): AgentCreateRequest {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new Error('Demo agent register requires an object body.')
  }
  const { name, type, owner, description } = body as Partial<AgentCreateRequest>
  if (typeof name !== 'string' || !name.trim()) {
    throw new Error('Demo agent register requires a non-empty name.')
  }
  if (typeof type !== 'string' || !type.trim()) {
    throw new Error('Demo agent register requires a non-empty type.')
  }
  if (owner !== undefined && owner !== null && typeof owner !== 'string') {
    throw new Error('Demo agent register requires owner to be a string when provided.')
  }
  return {
    name: name.trim(),
    type: type.trim(),
    description: typeof description === 'string' ? description : null,
    owner: typeof owner === 'string' ? owner.trim() || null : null,
  }
}

function buildAgentSlug(name: string): string {
  const normalized = name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
  return normalized || 'agent'
}

function nextRegisteredAgentId(name: string): string {
  const baseLocalId = `agent-${buildAgentSlug(name)}`
  let candidate = `${TENANT}:${baseLocalId}`
  let suffix = 2
  while (findDemoAgent(candidate)) {
    candidate = `${TENANT}:${baseLocalId}-${suffix}`
    suffix += 1
  }
  return candidate
}

function registerAgent(body: unknown): AgentResponse {
  const input = readAgentCreate(body)
  const createdAt = nowIso()
  const registered: AgentResponse = {
    id: nextRegisteredAgentId(input.name),
    name: input.name,
    type: input.type,
    owner: input.owner,
    tenant_id: TENANT,
    lifecycle_state: 'registered',
    last_transition_at: createdAt,
    last_transition_by: 'demo-user',
    eu_ai_act_risk_class: 'minimal',
    compliance_summary: {
      total_controls: 12,
      passing: 0,
      failing: 0,
      pending: 12,
      posture_score: null,
    },
    model_name: 'gpt-4o',
    created_at: createdAt,
  }
  demoAgents.push({ agent: registered, activeCredentialCount: 0 })
  return cloneAgent(registered)
}

function issueCredentialForAgent(path: string): IssueCredentialResponse | undefined {
  const record = findDemoAgent(readAgentId(path))
  if (!record) return undefined
  record.activeCredentialCount += 1
  return {
    agent_id: record.agent.id,
    name: record.agent.name,
    identity_token: `demo.jwt.${record.agent.id}.issue-${record.activeCredentialCount}`,
    token_expires_at: '2026-08-27T12:00:00Z',
    token_note: 'Simulated demo credential — not a real SPIFFE SVID or secret.',
    simulated: true,
  }
}

function revokeCredentialsForAgent(path: string): RevokeCredentialResponse | undefined {
  const record = findDemoAgent(readAgentId(path))
  if (!record) return undefined
  const tokensRevoked = record.activeCredentialCount
  record.activeCredentialCount = 0
  return {
    agent_id: record.agent.id,
    name: record.agent.name,
    tokens_revoked: tokensRevoked,
    simulated: true,
  }
}

function readTransitionBody(body: unknown): { to_state: string; reason: string } {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new Error('Demo transition requires an object body.')
  }
  const toState = 'to_state' in body ? body.to_state : undefined
  const reason = 'reason' in body ? body.reason : undefined
  if (typeof toState !== 'string' || !toState.trim()) {
    throw new Error('Demo transition requires a non-empty to_state.')
  }
  if (typeof reason !== 'string' || !reason.trim()) {
    throw new Error('Demo transition requires a non-empty reason.')
  }
  return { to_state: toState, reason }
}

function transitionAgent(path: string, body: unknown): TransitionResponse | undefined {
  const record = findDemoAgent(readAgentId(path))
  if (!record) return undefined
  const { to_state, reason } = readTransitionBody(body)
  const timestamp = nowIso()
  const fromState = record.agent.lifecycle_state
  record.agent = {
    ...record.agent,
    lifecycle_state: to_state,
    last_transition_at: timestamp,
    last_transition_by: 'demo-user',
  }
  return {
    agent_id: record.agent.id,
    from_state: fromState,
    to_state,
    actor: 'demo-user',
    reason,
    timestamp,
    simulated: true,
  }
}

export function resetFakeData(): void {
  demoAgents = buildInitialAgents()
  demoDisplayCurrency = null
}

// ─── Per-user display currency (demo) ──────────────────────────────────────────
//
// Demo mode has no database, but the currency preference still has to survive a
// reload — a setting that resets when you refresh is not a setting. The live
// path persists to user_preferences.display_currency; this is its demo
// counterpart, backed by localStorage the same way the theme and sidebar
// preferences already are.
//
// Reads and writes are guarded: Node's built-in localStorage is inert without
// --localstorage-file and private-mode browsers throw on write, so an
// unguarded call here would take down every demo request that touches it.

/** localStorage key for the demo-mode currency preference. */
export const DEMO_CURRENCY_STORAGE_KEY = 'signalloom.displayCurrency'

/** In-memory cache so a blocked localStorage still holds the value per session. */
let demoDisplayCurrency: string | null = null

function readDemoCurrency(): string {
  if (demoDisplayCurrency !== null) return demoDisplayCurrency
  try {
    const stored = localStorage.getItem(DEMO_CURRENCY_STORAGE_KEY)
    if (stored) {
      demoDisplayCurrency = stored
      return stored
    }
  } catch {
    // Storage blocked — fall through to the documented default.
  }
  // Matches DEFAULT_CURRENCY in money/currency.ts and the column DEFAULT in
  // migration 020. All three have to say USD or a user sees one currency and
  // the audit trail records another.
  return 'USD'
}

function writeDemoCurrency(body: unknown): { display_currency: string } {
  const next = (body as { display_currency?: unknown })?.display_currency
  if (typeof next !== 'string') {
    // Echo the current value rather than storing rubbish. The client narrows
    // whatever comes back, so a bad write cannot move the display.
    return { display_currency: readDemoCurrency() }
  }
  demoDisplayCurrency = next
  try {
    localStorage.setItem(DEMO_CURRENCY_STORAGE_KEY, next)
  } catch {
    // Storage blocked — the choice stays session-only.
  }
  return { display_currency: next }
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
  total_agents: demoAgents.length,
  agents_assessed: demoAgents.length,
  controls_passing: 28,
  controls_failing: 6,
  controls_pending: 5,
  posture_score: 74,
}

const posture: PostureResponse = {
  agents: buildInitialAgents().map(({ agent: a }) => ({
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

/** Fixture history plus anything this demo session recorded, newest first.
 *
 *  Actions taken during the demo have to appear on the same trail as the
 *  seeded history — a demo where the audience presses a button and the audit
 *  page still shows only two week-old rows demonstrates the opposite of what
 *  the product claims.
 *
 *  Unpaginated, like the fixture it replaces: resolveFake() strips the query
 *  string before dispatch, so page/limit never reach a fixture. Returning the
 *  whole set with a matching total keeps AuditTrail's `hasMore` correctly
 *  false rather than offering a Load More that would fetch the same rows. */
function auditWithRecordedActivity(): AuditListResponse {
  const events = [...demoActivityEvents(), ...audit.events]
  return { events, total: events.length, page: 1, limit: events.length }
}

const DEMO_ACTOR = 'demo-operator'

/**
 * POST /agents/{id}/stun — record the event, then answer as the API would.
 *
 * The narrative half of the detail (`reason`, `outcome`) is authored here, not
 * read off the request, because that is what the real endpoint does. It used
 * to be `req.outcome ?? 'stunned'`, which quietly made this fixture a worse
 * liar than the backend it stands in for: whatever the browser claimed came
 * straight back as though the platform had observed it. A demo whose audit
 * trail echoes the client teaches exactly the wrong thing about the product.
 */
function stunFixture(path: string): StunAgentResponse {
  const agentId = path.split('/')[2]
  // Every field is sourced here, none from the request — the endpoint takes no
  // body. Identity comes from the simulated cluster, which is demo mode's stand
  // -in for the proxy the live endpoint asks.
  const identity = simulatedAgentIdentity(agentId)
  const event = recordDemoActivity({
    event_type: 'agent.stunned',
    agent_id: agentId,
    agent_name: identity?.name ?? agentId,
    actor: DEMO_ACTOR,
    detail: {
      outcome: 'stunned',
      reason: 'operator-initiated stun',
      namespace: identity?.namespace ?? null,
      from_state: 'active',
      to_state: 'suspended',
    },
  })
  return {
    agent_id: agentId,
    from_state: 'active',
    to_state: 'suspended',
    actor: DEMO_ACTOR,
    stunned_at: event.timestamp,
    event,
    // Kept in the same nested shape the live endpoint uses, so demo and live
    // render through one path. Flattening it here would make demo mode the
    // only place where a relayed claim is indistinguishable from a first-party
    // one, which is the exact distinction the nesting exists to preserve.
    proxy: {
      state: 'stunned',
      stunned_at: event.timestamp,
      message: `Agent ${agentId} stunned: credentials revoked, state marked as stunned`,
    },
  }
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
      source_removed: false,
      source_removed_at: null,
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
    agent_count: demoAgents.length,
    billing_tier: 'enterprise',
    api_key_status: 'active',
    selected_frameworks: selected,
    consent_required: false,
    cookie_preferences: COOKIE_PREFS,
    preferred_scan_cadence_hours: 24,
    alert_email: null,
    alert_threshold: 1,
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

// ─── Crypto Health ──────────────────────────────────────────────────────────────

const cryptoHealth: CryptoHealthResponse = {
  tenant_id: TENANT,
  proofs: [
    {
      name: 'dashboard-spiffe-jwt-exchange',
      kind: 'positive',
      status: 'passed',
      title: 'Dashboard workload exchanged SPIFFE identity for OpenBao access',
      description: 'The dashboard service authenticated as its workload identity without using a static secret.',
      expectation: 'A valid SPIFFE-backed identity should mint a short-lived OpenBao token for the dashboard path.',
      evidence: 'spiffe://signalloom.svc.cluster.local/ns/fe-signalloom/sa/dashboard -> openbao role dashboard-readonly -> lease ttl=300s',
    },
    {
      name: 'forged-sa-token-denied',
      kind: 'negative',
      status: 'passed',
      title: 'Forged service-account replay was rejected',
      description: 'A simulated identity replay using the wrong service account was denied before any secret was issued.',
      expectation: 'A non-matching workload identity must be blocked from the OpenBao role bound to dashboard.',
      evidence: 'subject mismatch for spiffe://signalloom.svc.cluster.local/ns/inf-signalloom/sa/legacy-batch -> permission denied',
    },
  ],
}

// ─── Platform Users ─────────────────────────────────────────────────────────

const platformUsers: PlatformUsersResponse = {
  users: [
    { id: 'a0000000-0000-0000-0000-000000000001', email: 'admin@acme.co', display_name: 'Alice Admin', role: 'admin', status: 'active', department: 'Platform Engineering', title: 'Platform Lead', last_login_at: '2026-07-31T09:15:00Z', created_at: '2026-06-15T10:00:00Z' },
    { id: 'a0000000-0000-0000-0000-000000000002', email: 'wendy@acme.co', display_name: 'Wendy Watkins', role: 'admin', status: 'active', department: 'Security', title: 'Security Engineer', last_login_at: '2026-07-30T14:22:00Z', created_at: '2026-06-15T10:00:00Z' },
    { id: 'a0000000-0000-0000-0000-000000000003', email: 'lancelot@acme.co', display_name: 'Lance Overture', role: 'editor', status: 'active', department: 'Platform Engineering', title: 'AI Engineer', last_login_at: '2026-07-29T11:00:00Z', created_at: '2026-06-20T09:00:00Z' },
    { id: 'a0000000-0000-0000-0000-000000000004', email: 'dennis@acme.co', display_name: 'Dennis Moore', role: 'editor', status: 'active', department: 'Platform Engineering', title: 'ML Engineer', last_login_at: '2026-07-28T16:45:00Z', created_at: '2026-06-22T09:00:00Z' },
    { id: 'a0000000-0000-0000-0000-000000000005', email: 'patsy@acme.co', display_name: 'Pat Gallahad', role: 'viewer', status: 'active', department: 'Product', title: 'Product Manager', last_login_at: '2026-07-25T10:30:00Z', created_at: '2026-07-01T09:00:00Z' },
    { id: 'a0000000-0000-0000-0000-000000000006', email: 'robin@acme.co', display_name: 'Robin Banks', role: 'editor', status: 'active', department: 'Platform Engineering', title: 'DevOps Engineer', last_login_at: '2026-07-27T08:00:00Z', created_at: '2026-06-25T09:00:00Z' },
    { id: 'a0000000-0000-0000-0000-000000000007', email: 'ciso@acme.co', display_name: 'Chris Isobel', role: 'admin', status: 'active', department: 'Security', title: 'CISO', last_login_at: '2026-07-31T17:00:00Z', created_at: '2026-06-15T10:00:00Z' },
    { id: 'a0000000-0000-0000-0000-000000000008', email: 'devops@acme.co', display_name: 'Devon Ops', role: 'editor', status: 'active', department: 'Infrastructure', title: 'Infrastructure Engineer', last_login_at: '2026-07-26T13:15:00Z', created_at: '2026-06-18T09:00:00Z' },
    { id: 'a0000000-0000-0000-0000-000000000009', email: 'ops@acme.co', display_name: 'Olivia Parsons', role: 'viewer', status: 'active', department: 'Infrastructure', title: 'Operations Analyst', last_login_at: '2026-07-20T09:00:00Z', created_at: '2026-07-05T09:00:00Z' },
  ],
  total: 9,
}

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
  { method: 'GET', test: re(/^\/agents$/), data: () => listAgents() },
  { method: 'POST', test: re(/^\/agents$/), data: (_p, body) => registerAgent(body) },
  { method: 'PUT', test: re(/^\/agents\/[^/]+$/), data: (path, body) => updateAgent(path, body) },
  { method: 'POST', test: re(/^\/agents\/[^/]+\/credentials\/revoke$/), data: (path) => revokeCredentialsForAgent(path) },
  { method: 'POST', test: re(/^\/agents\/[^/]+\/credentials$/), data: (path) => issueCredentialForAgent(path) },
  { method: 'POST', test: re(/^\/agents\/[^/]+\/transition$/), data: (path, body) => transitionAgent(path, body) },
  // Merge union: the stateful handlers above come from feat/supercred-agents-unify,
  // which replaced this branch's static fixtures. The stun route below exists only
  // on feat/supercred-stun-timeline — resolving this hunk to either side alone
  // would have silently dropped one of the two features.
  { method: 'POST', test: re(/^\/agents\/[^/]+\/stun$/), data: (p) => stunFixture(p) },
  { method: 'GET', test: re(/^\/agents\/[^/]+\/violations$/), data: () => violations },
  { method: 'POST', test: re(/^\/agents\/violations\/[^/]+\/acknowledge$/), data: () => ({ status: 'acknowledged' }) },
  { method: 'POST', test: re(/^\/agents\/[^/]+\/compliance\/[^/]+\/reassess$/), data: () => reassessment },
  { method: 'GET', test: re(/^\/agents\/[^/]+$/), data: (path) => readAgent(path) },
  // compliance
  { method: 'GET', test: re(/^\/compliance\/summary$/), data: () => complianceSummary },
  { method: 'GET', test: re(/^\/compliance\/posture$/), data: () => posture },
  { method: 'GET', test: re(/^\/compliance\/frameworks$/), data: () => frameworks },
  { method: 'GET', test: re(/^\/compliance\/export$/), data: () => complianceExport },
  // audit
  { method: 'GET', test: re(/^\/audit$/), data: () => auditWithRecordedActivity() },
  // nhi
  { method: 'GET', test: re(/^\/nhi\/scans$/), data: () => nhiScans },
  { method: 'GET', test: re(/^\/nhi\/discovered$/), data: () => nhiDiscovered },
  { method: 'POST', test: re(/^\/nhi\/discovered\/[^/]+\/enroll$/), data: (p) => ({ account_id: p.split('/')[3], status: 'enrollment_requested' }) },
  { method: 'POST', test: re(/^\/nhi\/discovered\/[^/]+\/dismiss$/), data: (p) => ({ account_id: p.split('/')[3], status: 'dismissed' }) },
  { method: 'GET', test: re(/^\/nhi\/report\/json$/), data: () => nhiReport },
  // tenant / support / users
  { method: 'GET', test: re(/^\/tenant\/users$/), data: () => platformUsers },
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
  // per-user preferences
  { method: 'GET', test: re(/^\/user\/preferences$/), data: () => ({ display_currency: readDemoCurrency() }) },
  { method: 'PATCH', test: re(/^\/user\/preferences$/), data: (_p, body) => writeDemoCurrency(body) },
  // health
  { method: 'GET', test: re(/^\/health\/crypto$/), data: () => cryptoHealth },
  // network tests (netassert)
  { method: 'GET', test: re(/^\/network-tests$/), data: () => networkTestsFixture() },
  { method: 'POST', test: re(/^\/network-tests\/scan$/), data: () => networkTestsScanFixture() },
  // compliance-policy routes (policy-as-versioned-code)
  ...COMPLIANCE_POLICY_ROUTES,
  // signal weave routes (observations, actors, coverage, correlation, seed)
  ...WEAVE_ROUTES,
]

/** Number of distinct demo routes — asserted by the vitest to match the client surface.
 *  33 base + 2 user-preferences + 2 network-tests + 3 compliance-policy + 7 weave = 46 */
export const FAKE_ROUTE_COUNT = ROUTES.length

function cleanPath(path: string): string {
  return path.replace(/^\/api/, '').split('?')[0]
}

export function hasFakeRoute(method: string, path: string): boolean {
  const clean = cleanPath(path)
  return ROUTES.some((route) => route.method === method.toUpperCase() && route.test(clean))
}

/**
 * Resolve a fixture for a client request, or undefined if a matched demo route
 * cannot resolve a specific resource (for example, an unknown agent ID).
 * `path` is the raw path passed to req() (e.g. '/agents/123', '/audit?page=1').
 */
export function resolveFake(method: string, path: string, body?: unknown): unknown | undefined {
  const clean = cleanPath(path)
  const route = ROUTES.find((r) => r.method === method.toUpperCase() && r.test(clean))
  return route ? route.data(clean, body) : undefined
}
