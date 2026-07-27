// Connector framework types (US-ENHC-011).
//
// ADR-ENHC-012 §2 defines `plugin.wizard_config() -> dict` and says the shape
// is "intentionally untyped" — this ticket owns the schema. Stream A's shipped
// code (PR #19, feat/enhc-012-connector-framework) already has a working
// assumption baked into its docstrings/test fixture, so this schema aligns to
// that precedent rather than picking something new:
//   - field key is `name` (routers/connectors.py, connectors/base.py docstring)
//   - the masked-credential field type is `"password"` (tests/agent-registry/
//     test_connectors.py::_FakePlugin.wizard_config)
//
// Additions beyond that precedent (flagged in the PR for Stream A to confirm):
//   - `text` as the plain-string counterpart to `password` (only `password`
//     had a real example; no plain-text field existed to copy from)
//   - `select` field type + `options` (not exercised anywhere yet)
//   - `placeholder` (cosmetic, optional)

export type WizardFieldType = 'text' | 'password' | 'select'

export interface WizardFieldOption {
  value: string
  label: string
}

export interface WizardFieldSpec {
  name: string
  label: string
  type: WizardFieldType
  required?: boolean
  placeholder?: string
  help_text?: string
  // Required when type === 'select'.
  options?: WizardFieldOption[]
}

export interface WizardStepConfig {
  fields: WizardFieldSpec[]
  permissions: string[]
  docs_link: string
  help_text: string
}

export interface ConnectorProvider {
  provider_id: string
  display_name: string
  wizard_config: WizardStepConfig
}

// GET /connectors/providers response envelope (routers/connectors.py).
export interface ConnectorProvidersResponse {
  providers: ConnectorProvider[]
}

export type ConnectorStatus = 'connected' | 'disconnected' | 'error'

// Mirrors the GET /connectors row shape from routers/connectors.py exactly
// (field names match the wire format, not the DB column names — e.g. `id` on
// the table is serialized as `connector_id`).
export interface TenantConnector {
  connector_id: string
  provider_id: string
  display_name: string | null
  status: ConnectorStatus
  credential_expires_at: string | null
  last_tested_at: string | null
  last_scan_at: string | null
  metadata: Record<string, unknown>
  created_at: string
}

// GET /connectors response envelope.
export interface TenantConnectorsResponse {
  connectors: TenantConnector[]
}

export interface ConnectorCreateRequest {
  provider_id: string
  display_name?: string
  credentials: Record<string, string>
  metadata?: Record<string, unknown>
}

// POST /connectors response — deliberately thin (routers/connectors.py
// returns only these four fields, not a full TenantConnector row).
export interface ConnectorCreateResponse {
  connector_id: string
  provider_id: string
  status: ConnectorStatus
  created_at: string
}

// DELETE /connectors/{id} response.
export interface ConnectorDeleteResponse {
  connector_id: string
  status: ConnectorStatus
}

// POST /connectors/{id}/test response. Note: no `days_until_expiry` field —
// the route only returns `credential_expires_at` (an ISO timestamp or null);
// derive a day count client-side if needed.
export interface ConnectorTestResult {
  connector_id: string
  valid: boolean
  scopes_ok: boolean
  error_msg: string | null
  credential_expires_at: string | null
  needs_rotation: boolean
}
