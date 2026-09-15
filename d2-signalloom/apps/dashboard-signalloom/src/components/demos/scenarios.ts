/**
 * Signal Loom AgentMaxxing Interactive Demo Console - Scenario Presets
 *
 * Defines the deterministic scenario presets for:
 * 1. Happy Path (baseline control case)
 * 2. Tamper Breach (adversarial SHA-256 hash corruption with dual mock/live injection sites)
 * 3. Revocation Race (instant attributable host revocation + terminal 403 upload denial)
 *
 * Both mock-mode and live-mode presets share a single, strictly validated schema
 * to prevent silent divergence.
 *
 * @module components/demos/scenarios
 */

export type StageId =
  | 'operator_init'
  | 'host_enrolled'
  | 'confinement_streaming'
  | 'adversarial_tamper'
  | 'revocation_denied'

export type StageOutcome =
  | 'success'
  | 'tamper_detected'
  | 'revocation_denied'

export type PresetMode = 'mock' | 'live'

export interface TargetEndpoint {
  readonly method: 'GET' | 'POST'
  readonly path: string
  readonly description: string
}

export interface PresetStage {
  readonly stage_id: StageId
  readonly stage_number: 1 | 2 | 3 | 4 | 5
  readonly name: string
  readonly description: string
  readonly expected_outcome: StageOutcome
  readonly expected_http_status: number
  readonly target_endpoint: TargetEndpoint
  readonly payload_fixture?: Readonly<Record<string, unknown>>
}

export interface MockInjectionSite {
  readonly target_field: string
  readonly original_value: string
  readonly corrupted_value: string
  readonly corruption_mechanism: string
  readonly expected_verification_result: string
}

export interface LiveInjectionSite {
  readonly mechanism: string
  readonly target_resource: string
  readonly tamper_operation: string
  readonly restore_operation: string
  readonly restore_principle: string
  readonly endpoint: string
}

export interface TamperConfig {
  readonly mock_site: MockInjectionSite
  readonly live_site: LiveInjectionSite
}

export interface RevocationConfig {
  readonly revoke_endpoint: string
  readonly upload_endpoint: string
  readonly expected_terminal_status: 403
  readonly expected_terminal_error: string
  readonly attribution_reason: string
  readonly race_sequence: readonly string[]
}

export interface PresetResetContract {
  readonly cleared_fields: readonly string[]
  readonly simulated_keys_to_purge: readonly string[]
  readonly mock_state_keys: readonly string[]
  readonly live_cleanup_actions?: readonly string[]
  readonly idempotent: boolean
}

export interface ScenarioPreset {
  readonly schemaVersion: '1.0.0'
  readonly id: string
  readonly name: string
  readonly description: string
  readonly mode: PresetMode
  readonly agent_id: string
  readonly host_id: string
  readonly tenant_id: string
  readonly stages: readonly PresetStage[]
  readonly tamper_config?: TamperConfig | null
  readonly revocation_config?: RevocationConfig | null
  readonly reset_contract: PresetResetContract
}

export interface ValidationResult {
  readonly valid: boolean
  readonly errors: readonly string[]
}

const REQUIRED_NAMESPACE_PREFIX = 'amxd-demo-'
const SUPPORTED_SCHEMA_VERSION = '1.0.0'
const EXPECTED_STAGE_SEQUENCE: readonly StageId[] = [
  'operator_init',
  'host_enrolled',
  'confinement_streaming',
  'adversarial_tamper',
  'revocation_denied',
]

/**
 * Validates a scenario preset object at runtime against the ScenarioPreset schema.
 */
export function validateScenarioPreset(preset: unknown): ValidationResult {
  const errors: string[] = []

  if (!preset || typeof preset !== 'object') {
    return { valid: false, errors: ['Preset must be a non-null object'] }
  }

  const p = preset as Record<string, unknown>

  // Schema version check
  if (typeof p.schemaVersion !== 'string') {
    errors.push('Preset missing string field "schemaVersion"')
  } else if (p.schemaVersion !== SUPPORTED_SCHEMA_VERSION) {
    errors.push(`Unsupported schemaVersion "${p.schemaVersion}". Expected "${SUPPORTED_SCHEMA_VERSION}"`)
  }

  // Identity checks
  if (typeof p.id !== 'string' || !p.id.trim()) {
    errors.push('Preset missing non-empty string field "id"')
  } else if (!p.id.startsWith(REQUIRED_NAMESPACE_PREFIX)) {
    errors.push(`Preset id "${p.id}" must start with namespace prefix "${REQUIRED_NAMESPACE_PREFIX}"`)
  }

  if (typeof p.name !== 'string' || !p.name.trim()) {
    errors.push('Preset missing non-empty string field "name"')
  }

  if (typeof p.description !== 'string' || !p.description.trim()) {
    errors.push('Preset missing non-empty string field "description"')
  }

  // Mode check
  if (p.mode !== 'mock' && p.mode !== 'live') {
    errors.push(`Preset mode must be "mock" or "live", got: ${String(p.mode)}`)
  }

  // Namespaced identifier checks
  for (const idField of ['agent_id', 'host_id', 'tenant_id'] as const) {
    const val = p[idField]
    if (typeof val !== 'string' || !val.trim()) {
      errors.push(`Preset missing non-empty string field "${idField}"`)
    } else if (!val.startsWith(REQUIRED_NAMESPACE_PREFIX)) {
      errors.push(`Identifier "${idField}" with value "${val}" must start with namespace prefix "${REQUIRED_NAMESPACE_PREFIX}"`)
    }
  }

  // Stages checks
  if (!Array.isArray(p.stages)) {
    errors.push('Preset field "stages" must be an array of exactly 5 stages')
  } else if (p.stages.length !== 5) {
    errors.push(`Preset field "stages" has ${p.stages.length} stages, expected exactly 5`)
  } else {
    p.stages.forEach((stage: unknown, idx: number) => {
      const expectedStageId = EXPECTED_STAGE_SEQUENCE[idx]
      const expectedStageNum = (idx + 1) as 1 | 2 | 3 | 4 | 5

      if (!stage || typeof stage !== 'object') {
        errors.push(`Stage at index ${idx} must be a non-null object`)
        return
      }

      const s = stage as Record<string, unknown>

      if (s.stage_id !== expectedStageId) {
        errors.push(`Stage at index ${idx} has stage_id "${String(s.stage_id)}", expected "${expectedStageId}"`)
      }

      if (s.stage_number !== expectedStageNum) {
        errors.push(`Stage at index ${idx} has stage_number "${String(s.stage_number)}", expected ${expectedStageNum}`)
      }

      if (typeof s.name !== 'string' || !s.name.trim()) {
        errors.push(`Stage at index ${idx} missing non-empty string "name"`)
      }

      if (typeof s.description !== 'string' || !s.description.trim()) {
        errors.push(`Stage at index ${idx} missing non-empty string "description"`)
      }

      const validOutcomes: readonly string[] = ['success', 'tamper_detected', 'revocation_denied']
      if (typeof s.expected_outcome !== 'string' || !validOutcomes.includes(s.expected_outcome)) {
        errors.push(`Stage at index ${idx} has invalid expected_outcome "${String(s.expected_outcome)}"`)
      }

      if (typeof s.expected_http_status !== 'number') {
        errors.push(`Stage at index ${idx} missing numeric field "expected_http_status"`)
      }

      if (!s.target_endpoint || typeof s.target_endpoint !== 'object') {
        errors.push(`Stage at index ${idx} missing object "target_endpoint"`)
      } else {
        const ep = s.target_endpoint as Record<string, unknown>
        if (ep.method !== 'GET' && ep.method !== 'POST') {
          errors.push(`Stage at index ${idx} target_endpoint method must be GET or POST`)
        }
        if (typeof ep.path !== 'string' || !ep.path.startsWith('/')) {
          errors.push(`Stage at index ${idx} target_endpoint path must be a string starting with "/"`)
        }
        if (typeof ep.description !== 'string' || !ep.description.trim()) {
          errors.push(`Stage at index ${idx} target_endpoint missing non-empty "description"`)
        }
      }
    })
  }

  // Tamper config validation (if preset is Tamper Breach or config is provided)
  if (p.tamper_config) {
    const tc = p.tamper_config as Record<string, unknown>
    if (typeof tc !== 'object') {
      errors.push('tamper_config must be an object')
    } else {
      // Mock site validation
      if (!tc.mock_site || typeof tc.mock_site !== 'object') {
        errors.push('tamper_config missing object "mock_site"')
      } else {
        const ms = tc.mock_site as Record<string, unknown>
        if (typeof ms.target_field !== 'string' || !ms.target_field.trim()) {
          errors.push('tamper_config.mock_site missing "target_field"')
        }
        if (typeof ms.original_value !== 'string' || !ms.original_value.trim()) {
          errors.push('tamper_config.mock_site missing "original_value"')
        }
        if (typeof ms.corrupted_value !== 'string' || !ms.corrupted_value.trim()) {
          errors.push('tamper_config.mock_site missing "corrupted_value"')
        }
        if (typeof ms.corruption_mechanism !== 'string' || !ms.corruption_mechanism.trim()) {
          errors.push('tamper_config.mock_site missing "corruption_mechanism"')
        }
        if (typeof ms.expected_verification_result !== 'string' || !ms.expected_verification_result.trim()) {
          errors.push('tamper_config.mock_site missing "expected_verification_result"')
        }
      }

      // Live site validation
      if (!tc.live_site || typeof tc.live_site !== 'object') {
        errors.push('tamper_config missing object "live_site"')
      } else {
        const ls = tc.live_site as Record<string, unknown>
        if (typeof ls.mechanism !== 'string' || !ls.mechanism.trim()) {
          errors.push('tamper_config.live_site missing "mechanism"')
        }
        if (typeof ls.target_resource !== 'string' || !ls.target_resource.trim()) {
          errors.push('tamper_config.live_site missing "target_resource"')
        }
        if (typeof ls.tamper_operation !== 'string' || !ls.tamper_operation.trim()) {
          errors.push('tamper_config.live_site missing "tamper_operation"')
        }
        if (typeof ls.restore_operation !== 'string' || !ls.restore_operation.trim()) {
          errors.push('tamper_config.live_site missing "restore_operation"')
        }
        if (typeof ls.restore_principle !== 'string' || !ls.restore_principle.trim()) {
          errors.push('tamper_config.live_site missing "restore_principle"')
        }
        if (typeof ls.endpoint !== 'string' || !ls.endpoint.startsWith('/')) {
          errors.push('tamper_config.live_site missing valid "endpoint"')
        }
      }
    }
  }

  // Revocation config validation (if preset is Revocation Race or config is provided)
  if (p.revocation_config) {
    const rc = p.revocation_config as Record<string, unknown>
    if (typeof rc !== 'object') {
      errors.push('revocation_config must be an object')
    } else {
      if (typeof rc.revoke_endpoint !== 'string' || !rc.revoke_endpoint.startsWith('/')) {
        errors.push('revocation_config missing valid "revoke_endpoint"')
      }
      if (typeof rc.upload_endpoint !== 'string' || !rc.upload_endpoint.startsWith('/')) {
        errors.push('revocation_config missing valid "upload_endpoint"')
      }
      if (rc.expected_terminal_status !== 403) {
        errors.push(`revocation_config expected_terminal_status must be numeric 403, got: ${String(rc.expected_terminal_status)}`)
      }
      if (typeof rc.expected_terminal_error !== 'string' || !rc.expected_terminal_error.trim()) {
        errors.push('revocation_config missing "expected_terminal_error"')
      }
      if (typeof rc.attribution_reason !== 'string' || !rc.attribution_reason.trim()) {
        errors.push('revocation_config missing "attribution_reason"')
      }
      if (!Array.isArray(rc.race_sequence) || rc.race_sequence.length === 0) {
        errors.push('revocation_config missing non-empty array "race_sequence"')
      }
    }
  }

  // Reset contract validation
  if (!p.reset_contract || typeof p.reset_contract !== 'object') {
    errors.push('Preset missing object "reset_contract"')
  } else {
    const rc = p.reset_contract as Record<string, unknown>
    if (!Array.isArray(rc.cleared_fields) || rc.cleared_fields.length === 0) {
      errors.push('reset_contract.cleared_fields must be a non-empty array of field names')
    }
    if (!Array.isArray(rc.simulated_keys_to_purge)) {
      errors.push('reset_contract.simulated_keys_to_purge must be an array of keys')
    }
    if (!Array.isArray(rc.mock_state_keys)) {
      errors.push('reset_contract.mock_state_keys must be an array of state keys')
    }
    if (rc.idempotent !== true) {
      errors.push('reset_contract.idempotent must be boolean true')
    }
  }

  return {
    valid: errors.length === 0,
    errors,
  }
}

/**
 * Type guard for ScenarioPreset.
 */
export function isScenarioPreset(preset: unknown): preset is ScenarioPreset {
  return validateScenarioPreset(preset).valid
}

/**
 * Asserts that an unknown value satisfies the ScenarioPreset schema, throwing an error if malformed.
 */
export function assertValidScenarioPreset(preset: unknown): asserts preset is ScenarioPreset {
  const result = validateScenarioPreset(preset)
  if (!result.valid) {
    throw new Error(`Invalid ScenarioPreset: ${result.errors.join('; ')}`)
  }
}

// ---------------------------------------------------------------------------
// Preset 1: Happy Path
// ---------------------------------------------------------------------------

export const HAPPY_PATH_PRESET: ScenarioPreset = {
  schemaVersion: '1.0.0',
  id: 'amxd-demo-happy-path',
  name: 'Happy Path',
  description: 'Deterministic baseline: all five stages resolve to their success sub-state with zero injected defects, providing a clean control case.',
  mode: 'mock',
  agent_id: 'amxd-demo-agent-happy-01',
  host_id: 'amxd-demo-host-happy-01',
  tenant_id: 'amxd-demo-tenant-primary',
  stages: [
    {
      stage_id: 'operator_init',
      stage_number: 1,
      name: 'Operator Token Issue',
      description: 'Issue short-lived operator registration token for external agent onboarding.',
      expected_outcome: 'success',
      expected_http_status: 201,
      target_endpoint: {
        method: 'POST',
        path: '/api/v1/external-agents/registrations/{agent_id}/token',
        description: 'Issues cryptographic registration token authorizing agent enrollment.',
      },
      payload_fixture: {
        token_id: 'amxd-demo-token-happy-01',
        expires_in_seconds: 900,
        allowed_scopes: ['audit-upload-only'],
      },
    },
    {
      stage_id: 'host_enrolled',
      stage_number: 2,
      name: 'Host Ed25519 Enrollment',
      description: 'Enroll host with verified Ed25519 public key and client nonce handshake.',
      expected_outcome: 'success',
      expected_http_status: 201,
      target_endpoint: {
        method: 'POST',
        path: '/api/v1/external-agents/enroll',
        description: 'Enrolls host cryptographic identity and binds public key to agent record.',
      },
      payload_fixture: {
        key_id: 'amxd-demo-key-happy-01',
        key_algorithm: 'Ed25519',
        credential_scope: 'audit-upload-only',
        status: 'enrolled',
      },
    },
    {
      stage_id: 'confinement_streaming',
      stage_number: 3,
      name: 'Landlock Confinement Telemetry',
      description: 'Stream confinement telemetry (CPU ticks, RSS bytes, SHA-256 digests) with zero customer code disclosure.',
      expected_outcome: 'success',
      expected_http_status: 202,
      target_endpoint: {
        method: 'POST',
        path: '/api/v1/external-agents/evidence-uploads',
        description: 'Submits zero-payload metadata evidence batches containing process telemetry and artifact digests.',
      },
      payload_fixture: {
        process_health: 'running',
        cpu_time_ms: 1420,
        resident_memory_bytes: 48234496,
        artifact_count: 3,
        artifact_sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      },
    },
    {
      stage_id: 'adversarial_tamper',
      stage_number: 4,
      name: 'Adversarial Tamper Simulation',
      description: 'Integrity verification stage with zero tamper injection; all artifact digests match signed provenance.',
      expected_outcome: 'success',
      expected_http_status: 200,
      target_endpoint: {
        method: 'POST',
        path: '/api/v1/external-agents/evidence-uploads',
        description: 'Evaluates artifact digest integrity against recorded session anchor.',
      },
      payload_fixture: {
        tamper_injected: false,
        integrity_state: 'integrity-verified',
        verification_status: 'passed',
      },
    },
    {
      stage_id: 'revocation_denied',
      stage_number: 5,
      name: 'Attributable Revocation & 403 Denial',
      description: 'Healthy lifecycle completion with active valid credentials and zero revocation denial.',
      expected_outcome: 'success',
      expected_http_status: 200,
      target_endpoint: {
        method: 'GET',
        path: '/api/v1/agents/{agent_id}/external-evidence',
        description: 'Retrieves finalized evidence log proving end-to-end healthy governance.',
      },
      payload_fixture: {
        agent_status: 'active',
        credential_state: 'valid',
        upload_authorized: true,
      },
    },
  ],
  tamper_config: null,
  revocation_config: null,
  reset_contract: {
    cleared_fields: [
      'operator_token',
      'enrolled_key_id',
      'host_public_key',
      'confinement_metrics',
      'telemetry_observations',
      'tamper_status',
      'revocation_state',
      'error_state',
    ],
    simulated_keys_to_purge: [
      'amxd-demo-token-happy-01',
      'amxd-demo-host-happy-01',
      'amxd-demo-evidence-happy-*',
    ],
    mock_state_keys: [
      'current_stage',
      'playback_state',
      'execution_logs',
      'active_preset_id',
    ],
    live_cleanup_actions: [
      'purge_agent_evidence_records',
      'deregister_demo_host',
    ],
    idempotent: true,
  },
}

// ---------------------------------------------------------------------------
// Preset 2: Tamper Breach
// ---------------------------------------------------------------------------

export const TAMPER_BREACH_PRESET: ScenarioPreset = {
  schemaVersion: '1.0.0',
  id: 'amxd-demo-tamper-breach',
  name: 'Tamper Breach',
  description: 'Adversarial defect simulation: SHA-256 artifact hash corruption caught by verification engine with dual mock and live injection sites.',
  mode: 'mock',
  agent_id: 'amxd-demo-agent-tamper-01',
  host_id: 'amxd-demo-host-tamper-01',
  tenant_id: 'amxd-demo-tenant-primary',
  stages: [
    {
      stage_id: 'operator_init',
      stage_number: 1,
      name: 'Operator Token Issue',
      description: 'Issue short-lived operator registration token for external agent onboarding.',
      expected_outcome: 'success',
      expected_http_status: 201,
      target_endpoint: {
        method: 'POST',
        path: '/api/v1/external-agents/registrations/{agent_id}/token',
        description: 'Issues cryptographic registration token authorizing agent enrollment.',
      },
      payload_fixture: {
        token_id: 'amxd-demo-token-tamper-01',
        expires_in_seconds: 900,
        allowed_scopes: ['audit-upload-only'],
      },
    },
    {
      stage_id: 'host_enrolled',
      stage_number: 2,
      name: 'Host Ed25519 Enrollment',
      description: 'Enroll host with verified Ed25519 public key and client nonce handshake.',
      expected_outcome: 'success',
      expected_http_status: 201,
      target_endpoint: {
        method: 'POST',
        path: '/api/v1/external-agents/enroll',
        description: 'Enrolls host cryptographic identity and binds public key to agent record.',
      },
      payload_fixture: {
        key_id: 'amxd-demo-key-tamper-01',
        key_algorithm: 'Ed25519',
        credential_scope: 'audit-upload-only',
        status: 'enrolled',
      },
    },
    {
      stage_id: 'confinement_streaming',
      stage_number: 3,
      name: 'Landlock Confinement Telemetry',
      description: 'Stream confinement telemetry and capture authentic baseline artifact SHA-256 digest prior to tamper.',
      expected_outcome: 'success',
      expected_http_status: 202,
      target_endpoint: {
        method: 'POST',
        path: '/api/v1/external-agents/evidence-uploads',
        description: 'Submits untampered metadata evidence baseline.',
      },
      payload_fixture: {
        process_health: 'running',
        cpu_time_ms: 2150,
        resident_memory_bytes: 62455808,
        artifact_id: 'artifact-demo-001',
        artifact_sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      },
    },
    {
      stage_id: 'adversarial_tamper',
      stage_number: 4,
      name: 'Adversarial Tamper Simulation',
      description: 'Inject SHA-256 mismatch defect; verification engine flags discrepancy, marks integrity tampered, and denies ingestion.',
      expected_outcome: 'tamper_detected',
      expected_http_status: 200,
      target_endpoint: {
        method: 'POST',
        path: '/api/v1/external-agents/evidence-uploads',
        description: 'Verifies evidence batch against session hash; triggers discrepancy alert upon digest mismatch.',
      },
      payload_fixture: {
        tamper_injected: true,
        tampered_field: 'sha256',
        original_digest: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        tampered_digest: 'deadbeef98fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        integrity_state: 'tampered',
        reason: 'event-tampered',
      },
    },
    {
      stage_id: 'revocation_denied',
      stage_number: 5,
      name: 'Attributable Revocation & 403 Denial',
      description: 'Tampered host flagged in security timeline; operator initiates attributable quarantine.',
      expected_outcome: 'success',
      expected_http_status: 200,
      target_endpoint: {
        method: 'GET',
        path: '/api/v1/agents/{agent_id}/external-evidence',
        description: 'Retrieves evidence ledger confirming tamper detection event recorded and flagged.',
      },
      payload_fixture: {
        agent_status: 'flagged_tamper',
        quarantine_recommended: true,
      },
    },
  ],
  tamper_config: {
    mock_site: {
      target_field: 'sha256',
      original_value: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      corrupted_value: 'deadbeef98fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      corruption_mechanism: 'client_held_hash_modification',
      expected_verification_result: 'tamper_integrity_mismatch_flagged',
    },
    live_site: {
      mechanism: 'database_tamper_and_restore',
      target_resource: 'external_agent_evidence',
      tamper_operation: 'UPDATE external_agent_evidence SET attributes = jsonb_set(attributes, \'{sha256}\', \'"deadbeef98fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"\') WHERE agent_id = \'amxd-demo-agent-tamper-01\';',
      restore_operation: 'UPDATE external_agent_evidence SET attributes = jsonb_set(attributes, \'{sha256}\', \'"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"\') WHERE agent_id = \'amxd-demo-agent-tamper-01\';',
      restore_principle: 'A verifier nobody has watched fail is not a verifier. Restoring the tampered row to its exact original value proves the verifier goes green again and demonstrates the digest is genuinely reproducible rather than unstable.',
      endpoint: '/api/v1/external-agents/evidence-uploads',
    },
  },
  revocation_config: null,
  reset_contract: {
    cleared_fields: [
      'operator_token',
      'enrolled_key_id',
      'host_public_key',
      'confinement_metrics',
      'telemetry_observations',
      'tamper_injected',
      'tamper_sha256_corrupted',
      'tamper_verification_result',
      'tamper_badge',
      'revocation_state',
      'error_state',
    ],
    simulated_keys_to_purge: [
      'amxd-demo-token-tamper-01',
      'amxd-demo-host-tamper-01',
      'amxd-demo-evidence-tamper-*',
      'amxd-demo-tampered-digest',
    ],
    mock_state_keys: [
      'current_stage',
      'playback_state',
      'tamper_injected',
      'tamper_active_site',
      'execution_logs',
    ],
    live_cleanup_actions: [
      'restore_tampered_evidence_digest',
      'purge_agent_evidence_records',
      'deregister_demo_host',
    ],
    idempotent: true,
  },
}

// ---------------------------------------------------------------------------
// Preset 3: Revocation Race
// ---------------------------------------------------------------------------

export const REVOCATION_RACE_PRESET: ScenarioPreset = {
  schemaVersion: '1.0.0',
  id: 'amxd-demo-revocation-race',
  name: 'Revocation Race',
  description: 'Attributable host revocation race: issue credential -> stream confinement -> revoke host -> immediate upload attempt, terminating with deterministic 403 Forbidden denial.',
  mode: 'mock',
  agent_id: 'amxd-demo-agent-revocation-01',
  host_id: 'amxd-demo-host-revocation-01',
  tenant_id: 'amxd-demo-tenant-primary',
  stages: [
    {
      stage_id: 'operator_init',
      stage_number: 1,
      name: 'Operator Token Issue',
      description: 'Issue initial operator token for host credential provisioning.',
      expected_outcome: 'success',
      expected_http_status: 201,
      target_endpoint: {
        method: 'POST',
        path: '/api/v1/external-agents/registrations/{agent_id}/token',
        description: 'Issues cryptographic registration token.',
      },
      payload_fixture: {
        token_id: 'amxd-demo-token-revocation-01',
        expires_in_seconds: 900,
        allowed_scopes: ['audit-upload-only'],
      },
    },
    {
      stage_id: 'host_enrolled',
      stage_number: 2,
      name: 'Host Ed25519 Enrollment',
      description: 'Host successfully enrolls with Ed25519 key pair prior to revocation race.',
      expected_outcome: 'success',
      expected_http_status: 201,
      target_endpoint: {
        method: 'POST',
        path: '/api/v1/external-agents/enroll',
        description: 'Completes initial host enrollment.',
      },
      payload_fixture: {
        key_id: 'amxd-demo-key-revocation-01',
        key_algorithm: 'Ed25519',
        credential_scope: 'audit-upload-only',
        status: 'enrolled',
      },
    },
    {
      stage_id: 'confinement_streaming',
      stage_number: 3,
      name: 'Landlock Confinement Telemetry',
      description: 'Telemetry streams normally while host credential remains valid and unrevoked.',
      expected_outcome: 'success',
      expected_http_status: 202,
      target_endpoint: {
        method: 'POST',
        path: '/api/v1/external-agents/evidence-uploads',
        description: 'Uploads confinement telemetry while credential is in good standing.',
      },
      payload_fixture: {
        process_health: 'running',
        cpu_time_ms: 980,
        resident_memory_bytes: 35651584,
        status: 'authorized',
      },
    },
    {
      stage_id: 'adversarial_tamper',
      stage_number: 4,
      name: 'Adversarial Tamper Simulation',
      description: 'Operator triggers immediate attributable revocation on host due to anomalous activity.',
      expected_outcome: 'success',
      expected_http_status: 200,
      target_endpoint: {
        method: 'POST',
        path: '/v1/external-agents/hosts/{host_id}/revoke',
        description: 'Authenticates operator revocation request and revokes host lease/SVID.',
      },
      payload_fixture: {
        revocation_status: 'revoked',
        attribution_reason: 'Operator initiated attributable revocation: suspected compromise',
        revoked_at: '2026-09-15T02:00:00Z',
      },
    },
    {
      stage_id: 'revocation_denied',
      stage_number: 5,
      name: 'Attributable Revocation & 403 Denial',
      description: 'Immediate post-revocation upload attempt is denied with HTTP 403 Forbidden, proving immediate authorization boundary enforcement.',
      expected_outcome: 'revocation_denied',
      expected_http_status: 403,
      target_endpoint: {
        method: 'POST',
        path: '/api/v1/external-agents/evidence-uploads',
        description: 'Upload attempt using revoked host credentials returns 403 Forbidden.',
      },
      payload_fixture: {
        error: 'Forbidden',
        status_code: 403,
        reason: 'Host credential has been revoked',
        upload_rejected: true,
      },
    },
  ],
  tamper_config: null,
  revocation_config: {
    revoke_endpoint: '/v1/external-agents/hosts/{host_id}/revoke',
    upload_endpoint: '/api/v1/external-agents/evidence-uploads',
    expected_terminal_status: 403,
    expected_terminal_error: 'Forbidden',
    attribution_reason: 'Operator initiated attributable revocation: suspected compromise',
    race_sequence: [
      'issue_credential',
      'host_enrolled',
      'confinement_streaming',
      'revoke_host_credential',
      'attempt_upload_denied_403',
    ],
  },
  reset_contract: {
    cleared_fields: [
      'operator_token',
      'enrolled_key_id',
      'host_public_key',
      'confinement_metrics',
      'telemetry_observations',
      'revocation_status',
      'revocation_timestamp',
      'revocation_attribution_reason',
      'terminal_denial_status',
      'post_revocation_upload_result',
      'error_state',
    ],
    simulated_keys_to_purge: [
      'amxd-demo-token-revocation-01',
      'amxd-demo-host-revocation-01',
      'amxd-demo-revocation-receipt',
      'amxd-demo-evidence-revocation-*',
    ],
    mock_state_keys: [
      'current_stage',
      'playback_state',
      'revoked_state',
      'terminal_outcome_recorded',
      'execution_logs',
    ],
    live_cleanup_actions: [
      'clear_revocation_lease_entry',
      'purge_agent_evidence_records',
      'deregister_demo_host',
    ],
    idempotent: true,
  },
}

// ---------------------------------------------------------------------------
// Preset Collections and Utilities
// ---------------------------------------------------------------------------

export const SCENARIO_PRESETS: readonly ScenarioPreset[] = [
  HAPPY_PATH_PRESET,
  TAMPER_BREACH_PRESET,
  REVOCATION_RACE_PRESET,
]

export const SCENARIO_PRESETS_BY_ID: Readonly<Record<string, ScenarioPreset>> = {
  [HAPPY_PATH_PRESET.id]: HAPPY_PATH_PRESET,
  [TAMPER_BREACH_PRESET.id]: TAMPER_BREACH_PRESET,
  [REVOCATION_RACE_PRESET.id]: REVOCATION_RACE_PRESET,
}

export function getScenarioPresetById(id: string): ScenarioPreset | undefined {
  return SCENARIO_PRESETS_BY_ID[id]
}

export function clonePresetWithMode(preset: ScenarioPreset, mode: PresetMode): ScenarioPreset {
  return {
    ...preset,
    mode,
  }
}
