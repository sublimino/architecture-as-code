/**
 * Feature flag type definitions and system defaults for Signal Loom.
 */

export interface FeatureFlagDetail {
  enabled: boolean
  config: Record<string, unknown>
}

export interface FeaturesResponse {
  tenant_id: string
  flags: Record<string, boolean>
  details?: Record<string, FeatureFlagDetail>
}

/**
 * System default flags matching backend defaults in fe-signalloom.
 * Core governance, audit, and compliance are enabled by default for enterprise pilots.
 * Experimental demos and advanced surfaces are disabled by default.
 */
export const DEFAULT_SYSTEM_FLAGS: Record<string, boolean> = {
  core_governance: true,
  audit: true,
  compliance: true,
  demos_fleet: false,
  supercred: false,
  rbac_analysis: false,
  collusion_access: false,
}

export type KnownFeatureFlag =
  | 'core_governance'
  | 'audit'
  | 'compliance'
  | 'demos_fleet'
  | 'supercred'
  | 'rbac_analysis'
  | 'collusion_access'

export type FeatureFlagKey = KnownFeatureFlag | (string & {})
