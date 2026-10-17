/**
 * Contract test: every account type's exact flag set.
 *
 * EAP View is written out literally (captured live from tenant-demo on
 * 2026-10-17), so changing one flag in EAP_VIEW_FLAGS turns this red. The rest
 * is parity with d2-signalloom/contracts/feature-account-types.json, which the
 * server test (test_feature_account_types.py) and the Playwright helper read too.
 */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { NAV } from '../components/Sidebar'
import { ACCOUNT_TYPES, EAP_FULL_FLAGS, EAP_VIEW_FLAGS, FULL_FLAGS } from './accountTypes'
import { DEFAULT_SYSTEM_FLAGS } from './features'

interface Contract {
  flag_keys: string[]
  account_types: { id: string; name: string; status: string; aliases: string[]; flags: Record<string, boolean> }[]
  tenant_nav: { label: string; route: string; flag: string }[]
}

const CONTRACT: Contract = JSON.parse(
  readFileSync(join(__dirname, '..', '..', '..', '..', 'contracts', 'feature-account-types.json'), 'utf8'),
)

describe('account type contract', () => {
  it('EAP View is exactly the configuration captured from tenant-demo', () => {
    expect(EAP_VIEW_FLAGS).toEqual({
      audit: true,
      collusion_access: false,
      compliance: true,
      core_governance: true,
      demos_fleet: false,
      page_agentmaxxing: false,
      page_agents: true,
      page_audit: false,
      page_compliance: false,
      page_credential_inventory: false,
      page_cryptography: false,
      page_discovery: true,
      page_federated_services: false,
      page_feeds: false,
      page_network_tests: false,
      page_policies: true,
      page_risk: false,
      page_signal_store: false,
      page_signals: false,
      page_topology: false,
      page_weave: false,
      rbac_analysis: false,
      supercred: false,
    })
  })

  it('Full enables every registered flag', () => {
    expect(FULL_FLAGS).toEqual(Object.fromEntries(Object.keys(DEFAULT_SYSTEM_FLAGS).map((k) => [k, true])))
  })

  it('every account type sets exactly the registered flags', () => {
    for (const t of ACCOUNT_TYPES) {
      expect(Object.keys(t.flags).sort(), t.id).toEqual(Object.keys(DEFAULT_SYSTEM_FLAGS).sort())
    }
    expect(CONTRACT.flag_keys).toEqual(Object.keys(DEFAULT_SYSTEM_FLAGS))
  })

  it('matches the cross-language contract file', () => {
    expect(ACCOUNT_TYPES.map((t) => t.id)).toEqual(CONTRACT.account_types.map((t) => t.id))
    for (const entry of CONTRACT.account_types) {
      const local = ACCOUNT_TYPES.find((t) => t.id === entry.id)!
      expect(local.flags, entry.id).toEqual(entry.flags)
      expect(local.name, entry.id).toBe(entry.name)
      expect(local.status, entry.id).toBe(entry.status)
      expect(local.aliases, entry.id).toEqual(entry.aliases)
    }
    expect(EAP_FULL_FLAGS).toEqual(CONTRACT.account_types[1]!.flags)
  })

  it("the contract's tenant nav is exactly the Sidebar's flag-gated tenant items", () => {
    const tenantNav = NAV.filter((n) => !n.superadminOnly && n.flag).map((n) => ({
      label: n.label,
      route: n.to,
      flag: n.flag,
    }))
    expect(tenantNav).toEqual(CONTRACT.tenant_nav)
  })
})
