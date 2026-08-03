// ─── Inline summaries ────────────────────────────────────────────────────────

export interface ComplianceSummaryInline {
  total_controls: number
  passing: number
  failing: number
  pending: number
  posture_score: number | null
}

// ─── Agents ──────────────────────────────────────────────────────────────────

export interface AgentCreateRequest {
  name: string
  type: string // 'Signal Loom Built' | 'COTS' | 'Custom'
  description?: string | null
  owner?: string | null
}

/**
 * The state of an agent's platform credentials, and why.
 *
 * `lifecycle_state` already says what the governance record thinks of the
 * agent ('suspended'), but a lifecycle word does not tell a reader whether the
 * agent can still authenticate, when that changed, or what caused it. Those
 * are three separate questions and an operator answering an auditor needs all
 * three, so they are carried explicitly rather than inferred from a status
 * word.
 *
 * Optional throughout: the field is absent for agents whose credentials have
 * never been touched, and every consumer treats absence as "nothing to say".
 */
export interface AgentCredentialState {
  /** Whether the agent can currently authenticate to the platform. */
  status: 'active' | 'revoked'
  /**
   * Why the credentials are in this state, in plain language.
   *
   * e.g. 'compliance-failure: securityContext not set'. Shown verbatim to the
   * user, so it must read as a sentence fragment, not a status enum.
   */
  reason?: string | null
  /** When the revocation took effect. */
  revoked_at?: string | null
  /** What performed the revocation — a platform component or an operator. */
  revoked_by?: string | null
}

export interface AgentResponse {
  id: string
  name: string
  type: string | null
  owner?: string | null
  tenant_id: string
  lifecycle_state: string
  last_transition_at: string | null
  last_transition_by?: string | null
  eu_ai_act_risk_class: string | null
  compliance_summary: ComplianceSummaryInline
  model_name?: string | null
  created_at: string | null
  credential_state?: AgentCredentialState | null
}

export interface AgentListResponse {
  agents: AgentResponse[]
  total: number
}

// Show-once credential issuance for an existing agent record (EHD-E3-001).
// identity_token is a secret returned exactly once; only its SHA-256 hash is
// persisted server-side (agent_tokens). It must be displayed once and never
// persisted in the browser (no-localStorage token policy).
export interface IssueCredentialResponse {
  agent_id: string
  name: string
  identity_token: string   // raw JWT — shown once, then gone
  token_expires_at: string
  token_note: string
  simulated?: boolean
}

// Self-serve revoke — revokes ALL active credentials for the agent (ClickUp 86cak75u7).
export interface RevokeCredentialResponse {
  agent_id: string
  name: string
  tokens_revoked: number
  simulated?: boolean
}

// Stun — the operator isolates a non-compliant agent. The k8s side-effect
// (pod relabel, credential revocation) belongs to the SuperCred proxy; this
// endpoint owns the RECORD of it: the agent's lifecycle state and the audit
// event, written in one transaction. The response echoes the audit row so the
// caller can show the trace it just created without a second round trip.
export interface StunAgentRequest {
  agent_name?: string | null
  namespace?: string | null
  reason?: string | null
  /** What actually happened — 'stunned' on success. Recorded in the event detail. */
  outcome?: string | null
}

export interface StunAgentResponse {
  agent_id: string
  from_state: string
  /** Lifecycle vocabulary, not UI wording: a stun lands the agent in
   *  'suspended' (migration 009). Mirrors TransitionResponse's naming. */
  to_state: string
  actor: string
  stunned_at: string
  event: AuditEventResponse
}

export interface TransitionRequest {
  to_state: string
  reason: string
}

export interface TransitionResponse {
  agent_id: string
  from_state: string
  to_state: string
  actor: string
  reason: string
  timestamp: string
  simulated?: boolean
}

export interface ReassessmentResponse {
  agent_id: string
  control_id: string
  status: string
  reassessment_requested_at: string
  reassessment_requested_by: string
  clickup_task_id: string | null
}

// ─── Violations ──────────────────────────────────────────────────────────────

export interface ViolationResponse {
  id: string
  agent_id: string
  violation_type: string | null
  severity: string | null
  analysis: string | null
  recommended_action: string | null
  status: string // new | acknowledged | resolved
  acknowledged_by: string | null
  acknowledged_at: string | null
  resolved_at: string | null
  created_at: string | null
}

export interface ViolationListResponse {
  violations: ViolationResponse[]
  total: number
}

// ─── Audit ───────────────────────────────────────────────────────────────────

export interface AuditEventResponse {
  id: string
  timestamp: string
  event_type: string
  agent_id: string | null
  agent_name: string | null
  actor: string
  detail: Record<string, unknown>
}

export interface AuditListResponse {
  events: AuditEventResponse[]
  total: number
  page: number
  limit: number
}

// ─── Compliance ───────────────────────────────────────────────────────────────

export interface ComplianceSummaryResponse {
  total_agents: number
  agents_assessed: number
  controls_passing: number
  controls_failing: number
  controls_pending: number
  posture_score: number | null
}

export interface ControlResponse {
  id: string
  name: string
  description: string | null
  control_order: number
}

export interface FrameworkResponse {
  id: string
  name: string
  version: string | null
  regulatory_body: string | null
  compliance_deadline: string | null
  control_count: number
  controls: ControlResponse[]
}

export interface AgentComplianceResultResponse {
  agent_id: string
  control_id: string
  control_name: string
  framework_name: string
  status: string // pass | fail | pending | reassessment_requested
  assessed_at: string | null
  evidence_ref: string | null
}

export interface AgentPosture {
  agent_id: string
  agent_name: string
  posture_score: number | null
  results: AgentComplianceResultResponse[]
}

export interface PostureResponse {
  agents: AgentPosture[]
}

export interface EUAIActControlStatus {
  control_name: string
  status: string
  detail: string | null
}

export interface EUAIActResponse {
  agent_id: string
  risk_class: string | null
  controls: EUAIActControlStatus[]
}

// ─── Crypto Health ───────────────────────────────────────────────────────────

export interface CryptoProof {
  name: string
  kind: 'positive' | 'negative'
  status: 'passed' | 'failed' | 'error' | 'pending'
  title: string
  description: string
  expectation: string
  evidence: string
}

export interface CryptoHealthResponse {
  tenant_id: string
  proofs: CryptoProof[]
}

// ─── Network Tests (netassert) ─────────────────────────────────────────────────

export interface NetworkTestEndpoint {
  namespace: string
  name: string
}

export interface NetworkTestResult {
  name: string
  expectedExit: number
  targetPort: number
  src: NetworkTestEndpoint
  dst: NetworkTestEndpoint
  description: string
  result: 'pass' | 'fail' | 'pending' | 'running' | 'error'
  evidence: string
  lastRun: string | null
}

export interface NetworkTestListResponse {
  tests: NetworkTestResult[]
  scanStatus: 'never-run' | 'pending' | 'running' | 'complete' | 'failed' | 'unavailable'
  job?: { name: string } | null
}

export interface NetworkTestScanResponse {
  job: string
  status: string
}

// ─── NHI Discovery ───────────────────────────────────────────────────────────

export interface NHIScan {
  id: string
  tenant_id: string
  scan_source: string
  started_at: string | null
  completed_at: string | null
  total_entries_scanned: number | null
  service_accounts_found: number | null
  total_at_risk: number | null
  status: string // running | completed | failed
}

export interface NHIScanListResponse {
  scans: NHIScan[]
}

export interface NHIAccount {
  id: string
  scan_id: string | null
  account_name: string
  directory_source: string
  owner_email: string | null
  last_credential_rotation: string | null // maps to last_rotated in DB
  privilege_level: string
  status: string // discovered | enrollment_requested | dismissed
  findings: string[]
  scan_count: number | null
  dismissed_at: string | null
  dismissed_by: string | null
  changes_since_dismissal: boolean | null
  previous_risk_flags: string[] | null
  first_discovered_at: string | null
  last_seen_at: string | null
  source_removed: boolean
  source_removed_at: string | null
}

export interface NHIDiscoveredSummary {
  total_discovered: number
  needs_triage: number
  previously_dismissed: number
}

export interface NHIDiscoveredResponse {
  accounts: NHIAccount[]
  total: number
  summary: NHIDiscoveredSummary
}

// Response shape of GET /nhi/discovered/{id} — richer than the list endpoint
// (adds dismiss_reason, scan_id, last_seen_at) and uses last_rotated (not
// last_credential_rotation) to match the backend's field name exactly.
export interface NHIAccountDetail {
  id: string
  scan_id: string | null
  account_name: string
  directory_source: string
  owner_email: string | null
  last_rotated: string | null
  privilege_level: string
  findings: string[]
  status: string
  first_discovered_at: string | null
  last_seen_at: string | null
  dismissed_at: string | null
  dismissed_by: string | null
  dismiss_reason: string | null
  scan_count: number
}

// ─── Settings ────────────────────────────────────────────────────────────────

export interface TenantSettingsResponse {
  tenant_id: string
  org_name: string
  plan_tier: string | null
  agent_count: number
  billing_tier: string | null
  api_key_status: string | null
  selected_frameworks: string[]
  consent_required: boolean
  cookie_preferences: CookiePreferences | null
  preferred_scan_cadence_hours: number
  alert_email: string | null
  alert_threshold: number
}

// PATCH /tenant/settings/preferences request body (Slice 1b, 86cajpvar QA item 4)
export interface PreferencesUpdateRequest {
  preferred_scan_cadence_hours: number
  alert_email: string | null
  alert_threshold: number
}

// ─── API Key Delivery & Rotation (Q6 / Q6 follow-on) ───────────────────────

export interface InitialApiKeyResponse {
  key: string           // Plaintext — shown exactly once, never re-fetchable
  prefix_hint: string   // First 14 chars (e.g. "sl_live_xbc1ab") for later reference
  revealed_at: string
}

export interface RotateApiKeyResponse {
  key: string           // New plaintext key — shown once, then gone
  prefix_hint: string
  revealed_at: string
  scope: string         // Inherited from the revoked key
}

// ─── Support ─────────────────────────────────────────────────────────────────

export interface SupportRequestCreate {
  subject: string
  urgency: 'low' | 'normal' | 'high' | 'critical'
  message: string
}

export interface SupportRequestResponse {
  id: string
  subject: string
  urgency: string
  submitted_at: string
  clickup_task_id: string | null
}

// ─── Consent & Cookie Preferences ────────────────────────────────────────────

export interface CookiePreferences {
  strictly_necessary: boolean
  analytics: boolean
}

export interface ConsentStatusResponse {
  accepted: boolean
  consent_required: boolean
  accepted_at: string | null
  document_versions: Record<string, string>
  cookie_preferences: CookiePreferences
}

export interface ConsentAcceptRequest {
  document_versions: Record<string, string>
  cookie_preferences: CookiePreferences
  b2b_warranty_accepted: true
}

export interface ConsentAcceptResponse {
  accepted: boolean
  accepted_at: string
  document_versions: Record<string, string>
  cookie_preferences: CookiePreferences
}

export interface CookiePreferencesResponse {
  cookie_preferences: CookiePreferences
}

// ─── Platform Users ─────────────────────────────────────────────────────────

export interface PlatformUser {
  id: string
  email: string
  display_name: string
  role: 'admin' | 'editor' | 'viewer'
  status: 'active' | 'invited' | 'suspended' | 'deactivated'
  department: string | null
  title: string | null
  last_login_at: string | null
  created_at: string
}

export interface PlatformUsersResponse {
  users: PlatformUser[]
  total: number
}
