import { describe, expect, it } from 'vitest'
import {
  assertValidScenarioPreset,
  clonePresetWithMode,
  getScenarioPresetById,
  HAPPY_PATH_PRESET,
  isScenarioPreset,
  REVOCATION_RACE_PRESET,
  SCENARIO_PRESETS,
  SCENARIO_PRESETS_BY_ID,
  TAMPER_BREACH_PRESET,
  validateScenarioPreset,
} from './scenarios'

describe('Scenario Presets and Validator (AMXD-P1-2)', () => {
  describe('Schema validation of canonical presets', () => {
    it('validates Happy Path preset successfully', () => {
      const result = validateScenarioPreset(HAPPY_PATH_PRESET)
      expect(result.valid).toBe(true)
      expect(result.errors).toHaveLength(0)
      expect(isScenarioPreset(HAPPY_PATH_PRESET)).toBe(true)
      expect(() => assertValidScenarioPreset(HAPPY_PATH_PRESET)).not.toThrow()
    })

    it('validates Tamper Breach preset successfully', () => {
      const result = validateScenarioPreset(TAMPER_BREACH_PRESET)
      expect(result.valid).toBe(true)
      expect(result.errors).toHaveLength(0)
      expect(isScenarioPreset(TAMPER_BREACH_PRESET)).toBe(true)
      expect(() => assertValidScenarioPreset(TAMPER_BREACH_PRESET)).not.toThrow()
    })

    it('validates Revocation Race preset successfully', () => {
      const result = validateScenarioPreset(REVOCATION_RACE_PRESET)
      expect(result.valid).toBe(true)
      expect(result.errors).toHaveLength(0)
      expect(isScenarioPreset(REVOCATION_RACE_PRESET)).toBe(true)
      expect(() => assertValidScenarioPreset(REVOCATION_RACE_PRESET)).not.toThrow()
    })

    it('validates all presets in SCENARIO_PRESETS collection', () => {
      expect(SCENARIO_PRESETS).toHaveLength(3)
      for (const preset of SCENARIO_PRESETS) {
        const result = validateScenarioPreset(preset)
        expect(result.valid).toBe(true)
      }
    })
  })

  describe('Rejection of malformed preset objects at runtime', () => {
    it('rejects null, undefined, or non-object values', () => {
      expect(validateScenarioPreset(null).valid).toBe(false)
      expect(validateScenarioPreset(undefined).valid).toBe(false)
      expect(validateScenarioPreset('preset-string').valid).toBe(false)
      expect(validateScenarioPreset(42).valid).toBe(false)
    })

    it('rejects preset with missing or unsupported schemaVersion', () => {
      const missingVersion = { ...HAPPY_PATH_PRESET, schemaVersion: undefined }
      expect(validateScenarioPreset(missingVersion).valid).toBe(false)

      const badVersion = { ...HAPPY_PATH_PRESET, schemaVersion: '2.0.0' }
      const res = validateScenarioPreset(badVersion)
      expect(res.valid).toBe(false)
      expect(res.errors.some((e) => e.includes('Unsupported schemaVersion'))).toBe(true)
    })

    it('rejects preset missing required amxd-demo- prefix in identifiers', () => {
      const badId = { ...HAPPY_PATH_PRESET, id: 'happy-path-without-prefix' }
      expect(validateScenarioPreset(badId).valid).toBe(false)

      const badAgentId = { ...HAPPY_PATH_PRESET, agent_id: 'prod-agent-99' }
      const res = validateScenarioPreset(badAgentId)
      expect(res.valid).toBe(false)
      expect(res.errors.some((e) => e.includes('amxd-demo-'))).toBe(true)

      const badHostId = { ...HAPPY_PATH_PRESET, host_id: 'host-123' }
      expect(validateScenarioPreset(badHostId).valid).toBe(false)

      const badTenantId = { ...HAPPY_PATH_PRESET, tenant_id: 'default' }
      expect(validateScenarioPreset(badTenantId).valid).toBe(false)
    })

    it('rejects preset with invalid mode', () => {
      const badMode = { ...HAPPY_PATH_PRESET, mode: 'invalid-mode' }
      const res = validateScenarioPreset(badMode)
      expect(res.valid).toBe(false)
      expect(res.errors.some((e) => e.includes('mode must be "mock" or "live"'))).toBe(true)
    })

    it('rejects preset with invalid stage count or sequence', () => {
      const tooFewStages = { ...HAPPY_PATH_PRESET, stages: HAPPY_PATH_PRESET.stages.slice(0, 4) }
      expect(validateScenarioPreset(tooFewStages).valid).toBe(false)

      const shuffledStages = {
        ...HAPPY_PATH_PRESET,
        stages: [
          HAPPY_PATH_PRESET.stages[1],
          HAPPY_PATH_PRESET.stages[0],
          ...HAPPY_PATH_PRESET.stages.slice(2),
        ],
      }
      const res = validateScenarioPreset(shuffledStages)
      expect(res.valid).toBe(false)
      expect(res.errors.some((e) => e.includes('stage_id'))).toBe(true)
    })

    it('rejects preset with missing reset_contract or empty cleared_fields', () => {
      const missingReset = { ...HAPPY_PATH_PRESET, reset_contract: undefined }
      expect(validateScenarioPreset(missingReset).valid).toBe(false)

      const emptyCleared = {
        ...HAPPY_PATH_PRESET,
        reset_contract: { ...HAPPY_PATH_PRESET.reset_contract, cleared_fields: [] },
      }
      expect(validateScenarioPreset(emptyCleared).valid).toBe(false)
    })

    it('throws in assertValidScenarioPreset when given a malformed preset', () => {
      const malformed = { name: 'Malformed', id: 'bad' }
      expect(() => assertValidScenarioPreset(malformed)).toThrowError(/Invalid ScenarioPreset/)
    })
  })

  describe('Tamper Breach Dual Injection Sites (Deliverable 3)', () => {
    it('expresses both mock-mode and live-mode injection sites under the shared schema', () => {
      expect(TAMPER_BREACH_PRESET.tamper_config).toBeDefined()
      expect(TAMPER_BREACH_PRESET.tamper_config).not.toBeNull()

      const tc = TAMPER_BREACH_PRESET.tamper_config
      if (!tc) throw new Error('tamper_config must be defined')

      // Mock site checks
      expect(tc.mock_site.target_field).toBe('sha256')
      expect(tc.mock_site.original_value).toMatch(/^[0-9a-f]{64}$/)
      expect(tc.mock_site.corrupted_value).toMatch(/^[0-9a-f]{64}$/)
      expect(tc.mock_site.original_value).not.toBe(tc.mock_site.corrupted_value)
      expect(tc.mock_site.corruption_mechanism).toBe('client_held_hash_modification')
      expect(tc.mock_site.expected_verification_result).toBe('tamper_integrity_mismatch_flagged')

      // Live site checks
      expect(tc.live_site.mechanism).toBe('database_tamper_and_restore')
      expect(tc.live_site.target_resource).toBe('external_agent_evidence')
      expect(tc.live_site.tamper_operation).toContain('UPDATE external_agent_evidence')
      expect(tc.live_site.restore_operation).toContain('UPDATE external_agent_evidence')
      expect(tc.live_site.endpoint).toBe('/api/v1/external-agents/evidence-uploads')

      // Honest verifier principle from scripts/audit-anchor-tamper-demo.sh
      expect(tc.live_site.restore_principle).toContain('A verifier nobody has watched fail is not a verifier')
      expect(tc.live_site.restore_principle).toContain('reproducible rather than unstable')
    })
  })

  describe('Revocation Race Expected Outcome (Deliverable 4)', () => {
    it('records expected terminal status 403 as numeric data', () => {
      expect(REVOCATION_RACE_PRESET.revocation_config).toBeDefined()
      expect(REVOCATION_RACE_PRESET.revocation_config).not.toBeNull()

      const rc = REVOCATION_RACE_PRESET.revocation_config
      if (!rc) throw new Error('revocation_config must be defined')

      expect(rc.expected_terminal_status).toBe(403)
      expect(rc.expected_terminal_error).toBe('Forbidden')
      expect(rc.revoke_endpoint).toBe('/v1/external-agents/hosts/{host_id}/revoke')
      expect(rc.upload_endpoint).toBe('/api/v1/external-agents/evidence-uploads')
      expect(rc.race_sequence).toEqual([
        'issue_credential',
        'host_enrolled',
        'confinement_streaming',
        'revoke_host_credential',
        'attempt_upload_denied_403',
      ])

      // Stage 5 expected outcome
      const stage5 = REVOCATION_RACE_PRESET.stages[4]
      expect(stage5.stage_id).toBe('revocation_denied')
      expect(stage5.expected_outcome).toBe('revocation_denied')
      expect(stage5.expected_http_status).toBe(403)
    })
  })

  describe('Per-Preset Reset Contract (Deliverable 5)', () => {
    it('names explicit fields to clear for Happy Path', () => {
      const reset = HAPPY_PATH_PRESET.reset_contract
      expect(reset.idempotent).toBe(true)
      expect(reset.cleared_fields).toContain('operator_token')
      expect(reset.cleared_fields).toContain('confinement_metrics')
      expect(reset.simulated_keys_to_purge).toContain('amxd-demo-token-happy-01')
      expect(reset.mock_state_keys).toContain('current_stage')
    })

    it('names explicit fields to clear for Tamper Breach including digest restoration', () => {
      const reset = TAMPER_BREACH_PRESET.reset_contract
      expect(reset.idempotent).toBe(true)
      expect(reset.cleared_fields).toContain('tamper_injected')
      expect(reset.cleared_fields).toContain('tamper_sha256_corrupted')
      expect(reset.cleared_fields).toContain('tamper_verification_result')
      expect(reset.simulated_keys_to_purge).toContain('amxd-demo-tampered-digest')
      expect(reset.live_cleanup_actions).toContain('restore_tampered_evidence_digest')
    })

    it('names explicit fields to clear for Revocation Race including lease clearing', () => {
      const reset = REVOCATION_RACE_PRESET.reset_contract
      expect(reset.idempotent).toBe(true)
      expect(reset.cleared_fields).toContain('revocation_status')
      expect(reset.cleared_fields).toContain('terminal_denial_status')
      expect(reset.cleared_fields).toContain('post_revocation_upload_result')
      expect(reset.simulated_keys_to_purge).toContain('amxd-demo-revocation-receipt')
      expect(reset.live_cleanup_actions).toContain('clear_revocation_lease_entry')
    })
  })

  describe('Namespace and Schema Version Invariants', () => {
    it('verifies all presets and identifiers carry amxd-demo- prefix', () => {
      for (const preset of SCENARIO_PRESETS) {
        expect(preset.id).toMatch(/^amxd-demo-/)
        expect(preset.agent_id).toMatch(/^amxd-demo-/)
        expect(preset.host_id).toMatch(/^amxd-demo-/)
        expect(preset.tenant_id).toMatch(/^amxd-demo-/)
      }
    })

    it('verifies schemaVersion is 1.0.0 on all presets', () => {
      for (const preset of SCENARIO_PRESETS) {
        expect(preset.schemaVersion).toBe('1.0.0')
      }
    })
  })

  describe('Preset Lookup and Clone Utilities', () => {
    it('looks up presets by ID in dictionary and helper', () => {
      expect(getScenarioPresetById('amxd-demo-happy-path')).toBe(HAPPY_PATH_PRESET)
      expect(getScenarioPresetById('amxd-demo-tamper-breach')).toBe(TAMPER_BREACH_PRESET)
      expect(getScenarioPresetById('amxd-demo-revocation-race')).toBe(REVOCATION_RACE_PRESET)
      expect(getScenarioPresetById('unknown-id')).toBeUndefined()
      expect(SCENARIO_PRESETS_BY_ID['amxd-demo-happy-path']).toBe(HAPPY_PATH_PRESET)
    })

    it('clones preset with alternative mode without mutating original', () => {
      const livePreset = clonePresetWithMode(HAPPY_PATH_PRESET, 'live')
      expect(livePreset.mode).toBe('live')
      expect(HAPPY_PATH_PRESET.mode).toBe('mock')
      expect(livePreset.id).toBe(HAPPY_PATH_PRESET.id)
      expect(validateScenarioPreset(livePreset).valid).toBe(true)
    })
  })
})
