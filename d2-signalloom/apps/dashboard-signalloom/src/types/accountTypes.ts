/**
 * Account types: the exact feature-flag set each one applies.
 *
 * The server (fe-signalloom feature_flags.FEATURE_PRESETS) is the authority and
 * serves these through GET /api/v1/admin/features/presets. This copy is the
 * Feature Flags page's offline fallback and the input to the flag-matrix tests.
 * Both copies are tested against d2-signalloom/contracts/feature-account-types.json
 * (accountTypes.test.ts here, test_feature_account_types.py on the server).
 *
 * Design: docs/signalloom/feature-flag-account-types.md
 */
import type { FeaturePreset, KnownFeatureFlag } from './features'

export type AccountTypeId = 'eap_view' | 'eap_full' | 'full'

export type FlagSet = Record<KnownFeatureFlag, boolean>

/** EAP View, captured live from tenant-demo on 2026-10-17. Early access, read-only. */
export const EAP_VIEW_FLAGS: FlagSet = {
  core_governance: true,
  audit: true,
  compliance: true,
  demos_fleet: false,
  supercred: false,
  rbac_analysis: false,
  collusion_access: false,
  page_discovery: true,
  page_agents: true,
  page_topology: false,
  page_weave: false,
  page_signals: false,
  page_risk: false,
  page_policies: true,
  page_compliance: false,
  page_audit: false,
  page_federated_services: false,
  page_cryptography: false,
  page_credential_inventory: false,
  page_signal_store: false,
  page_feeds: false,
  page_network_tests: false,
  page_agentmaxxing: false,
}

/** EAP Full: the former eap_pilot set. Confirmed by the principal 2026-10-17. */
export const EAP_FULL_FLAGS: FlagSet = {
  core_governance: true,
  audit: true,
  compliance: true,
  demos_fleet: false,
  supercred: false,
  rbac_analysis: false,
  collusion_access: false,
  page_discovery: true,
  page_agents: true,
  page_topology: false,
  page_weave: true,
  page_signals: true,
  page_risk: true,
  page_policies: true,
  page_compliance: true,
  page_audit: true,
  page_federated_services: false,
  page_cryptography: true,
  page_credential_inventory: true,
  page_signal_store: false,
  page_feeds: false,
  page_network_tests: false,
  page_agentmaxxing: false,
}

/** Full: every flag on. */
export const FULL_FLAGS: FlagSet = Object.fromEntries(
  Object.keys(EAP_VIEW_FLAGS).map((k) => [k, true]),
) as FlagSet

export const ACCOUNT_TYPES: (FeaturePreset & { id: AccountTypeId })[] = [
  {
    id: 'eap_view',
    name: 'EAP View (read-only)',
    kind: 'account_type',
    status: 'confirmed',
    aliases: [],
    description:
      'Early access, read-only. Discovery, the agent registry and the policy catalogue. No signals, risk, audit or compliance pages, no demos or labs.',
    flags: EAP_VIEW_FLAGS,
  },
  {
    id: 'eap_full',
    name: 'EAP Full',
    kind: 'account_type',
    status: 'confirmed',
    aliases: ['eap_pilot'],
    description:
      'Early access, full system. Adds signals, the Weave, risk, compliance, audit, cryptography and credential inventory to EAP View; demos, labs, topology and federated services stay off.',
    flags: EAP_FULL_FLAGS,
  },
  {
    id: 'full',
    name: 'Full',
    kind: 'account_type',
    status: 'confirmed',
    aliases: ['full_demo'],
    description: 'Every page, demo scenario and experimental lab enabled.',
    flags: FULL_FLAGS,
  },
]
