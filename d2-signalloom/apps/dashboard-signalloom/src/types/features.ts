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

export interface FeaturePreset {
  id: string
  name: string
  description: string
  flags: Record<string, boolean>
}

export interface PresetsResponse {
  presets: FeaturePreset[]
}

export interface UpdateTenantFeaturesPayload {
  tenant_id: string
  flags?: Record<string, boolean>
  preset?: string
}

export interface UpdateSingleFeaturePayload {
  enabled: boolean
  config_json?: Record<string, unknown>
}

/**
 * System default flags matching backend defaults in fe-signalloom.
 * Core governance, audit, and operational pages are enabled by default.
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
  page_discovery: true,
  page_agents: true,
  page_topology: true,
  page_weave: true,
  page_signals: true,
  page_risk: true,
  page_policies: true,
  page_compliance: true,
  page_audit: true,
  page_federated_services: true,
  page_cryptography: true,
  page_credential_inventory: true,
  page_signal_store: false,
  page_feeds: false,
  page_network_tests: false,
  page_agentmaxxing: false,
}

export type KnownFeatureFlag =
  | 'core_governance'
  | 'audit'
  | 'compliance'
  | 'demos_fleet'
  | 'supercred'
  | 'rbac_analysis'
  | 'collusion_access'
  | 'page_discovery'
  | 'page_agents'
  | 'page_topology'
  | 'page_weave'
  | 'page_signals'
  | 'page_risk'
  | 'page_policies'
  | 'page_compliance'
  | 'page_audit'
  | 'page_federated_services'
  | 'page_cryptography'
  | 'page_credential_inventory'
  | 'page_signal_store'
  | 'page_feeds'
  | 'page_network_tests'
  | 'page_agentmaxxing'

export type FeatureFlagKey = KnownFeatureFlag | (string & {})

export interface FeatureCategoryGroup {
  id: string
  title: string
  description: string
  flags: {
    key: KnownFeatureFlag
    label: string
    description: string
    route?: string
  }[]
}

export const FEATURE_CATEGORIES: FeatureCategoryGroup[] = [
  {
    id: 'operational',
    title: 'Operational & Governance Pages',
    description: 'Core runtime views for discovering, monitoring, and auditing agent workloads.',
    flags: [
      { key: 'page_agents', label: 'Agents Registry', description: 'Governed agent list, state details, and containment cockpit', route: '/agents' },
      { key: 'page_discovery', label: 'Discovery & Accounts', description: 'In-cluster and cloud account workload discovery portal', route: '/discovery' },
      { key: 'page_topology', label: 'Agent Topology', description: 'Agent trust topology and communication graph', route: '/topology' },
      { key: 'page_weave', label: 'Interaction Weave', description: 'Real-time multi-agent interactions and messaging stream', route: '/weave' },
      { key: 'page_signals', label: 'Signal Stream', description: 'Live anomaly signals, security detections, and events', route: '/signals' },
      { key: 'page_audit', label: 'Audit Trail', description: 'Immutable provenance log and cryptographic audit trail', route: '/audit' },
    ],
  },
  {
    id: 'security',
    title: 'Security, Risk & Compliance',
    description: 'Regulatory compliance assessments, policy controls, and key management.',
    flags: [
      { key: 'page_compliance', label: 'Compliance Posture', description: 'Regulatory posture scoring and framework evaluation', route: '/compliance' },
      { key: 'page_risk', label: 'Risk Exposure', description: 'Vulnerability tracking and cross-agent risk analysis', route: '/risk' },
      { key: 'page_policies', label: 'Governance Policies', description: 'Active guardrail rules and policy definitions', route: '/policies' },
      { key: 'page_credential_inventory', label: 'Credential Inventory', description: 'OpenBao and SPIRE cryptographic token allocations', route: '/credential-inventory' },
      { key: 'page_cryptography', label: 'Cryptography & Keys', description: 'Platform signing keys, attestation roots, and HSM status', route: '/cryptography' },
      { key: 'page_federated_services', label: 'Federated Services', description: 'Third-party model providers and downstream proxy endpoints', route: '/federated-services' },
    ],
  },
  {
    id: 'demos',
    title: 'Demonstration & Experimental Labs',
    description: 'Interactive demo surfaces, chaos scenarios, and progressive containment labs.',
    flags: [
      { key: 'demos_fleet', label: 'Fleet Simulation Demo', description: 'Multi-cluster fleet cascade simulation and testing controls', route: '/fleet' },
      { key: 'supercred', label: 'SuperCredential Demo', description: 'Privilege escalation and token abuse demonstration', route: '/supercred' },
      { key: 'rbac_analysis', label: 'AFM RBAC Analysis', description: 'Formal RBAC graph verification and permission explorer', route: '/rbac-analysis' },
      { key: 'collusion_access', label: 'Collusion & Access Matrix', description: 'Multi-agent collusion detection and privilege correlation', route: '/collusion-access' },
      { key: 'page_agentmaxxing', label: 'AgentMaxxing Containment', description: 'Five-stage deterministic agent containment console', route: '/demos/agentmaxxing' },
      { key: 'page_network_tests', label: 'Network & Port Probes', description: 'Live diagnostic probes and ingress boundary verification', route: '/network-tests' },
      { key: 'page_signal_store', label: 'Signal Storage / FrostDB', description: 'Raw FrostDB segments and parquet telemetry query console', route: '/signal-store' },
      { key: 'page_feeds', label: 'Telemetry Feeds Explorer', description: 'Low-level streaming telemetry inspection', route: '/feeds' },
    ],
  },
]
