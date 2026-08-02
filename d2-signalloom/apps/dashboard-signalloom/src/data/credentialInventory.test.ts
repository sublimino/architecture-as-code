import { describe, it, expect } from 'vitest'
import {
  TRUST_DOMAIN,
  spiffeId,
  CONFIG_REGISTRATION_ENTRIES,
  DEMO_REGISTRATION_ENTRIES,
  deriveEntriesFromAgents,
  mergeEntries,
  credentialsForEntry,
  summariseCredentials,
  type RegistrationEntry,
  type RuntimeAgentIdentity,
} from './credentialInventory'

const NOW = new Date('2026-08-02T12:00:00Z')

function entry(overrides: Partial<RegistrationEntry> = {}): RegistrationEntry {
  return {
    spiffeId: spiffeId('fe-signalloom-agents', 'cardvault-agent'),
    namespace: 'fe-signalloom-agents',
    serviceAccount: 'cardvault-agent',
    workload: 'cardvault-agent',
    selectors: ['k8s:ns:fe-signalloom-agents', 'k8s:sa:cardvault-agent'],
    audience: 'openbao',
    baoRole: 'signalloom-cardvault-agent',
    baoPolicyPath: 'kv/data/signalloom/cardvault-agent',
    provenance: 'config',
    state: 'active',
    registered: true,
    ...overrides,
  }
}

// ─── Trust domain ───────────────────────────────────────────────────────────

describe('trust domain', () => {
  // The deployed SPIRE server config is the only authority here:
  // infra/inf-bao/controllers/base/spire-openbao-config.yaml sets
  // trust_domain = "signalloom.demo". CryptographyPage and SuperCredPage each
  // hard-code a different, contradicting domain — this module is the fix.
  it('matches the trust domain configured on the SPIRE server', () => {
    expect(TRUST_DOMAIN).toBe('signalloom.demo')
  })

  it('builds SPIFFE IDs in the k8s workload-registrar form', () => {
    expect(spiffeId('fe-signalloom', 'fe-signalloom')).toBe(
      'spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom',
    )
  })

  it('URI-encodes path segments so a hostile namespace cannot forge a SPIFFE path', () => {
    expect(spiffeId('a/../b', 'sa')).toBe('spiffe://signalloom.demo/ns/a%2F..%2Fb/sa/sa')
  })
})

// ─── Config-sourced registration entries ────────────────────────────────────

describe('CONFIG_REGISTRATION_ENTRIES', () => {
  it('carries the two SPIFFE identities actually registered in the cluster config', () => {
    const ids = CONFIG_REGISTRATION_ENTRIES.map((e) => e.spiffeId).sort()
    expect(ids).toEqual([
      'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent',
      'spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom',
    ])
  })

  it('records the OpenBao JWT role and policy path each identity is bound to', () => {
    const cardvault = CONFIG_REGISTRATION_ENTRIES.find((e) => e.serviceAccount === 'cardvault-agent')
    expect(cardvault?.baoRole).toBe('signalloom-cardvault-agent')
    expect(cardvault?.baoPolicyPath).toBe('kv/data/signalloom/cardvault-agent')
    expect(cardvault?.audience).toBe('openbao')
  })

  it('marks every config-sourced entry as such so the UI never claims it is live', () => {
    expect(CONFIG_REGISTRATION_ENTRIES.every((e) => e.provenance === 'config')).toBe(true)
  })
})

// ─── Live derivation ────────────────────────────────────────────────────────

describe('deriveEntriesFromAgents', () => {
  const agent: RuntimeAgentIdentity = {
    id: 'cardvault-agent-abc',
    name: 'Cardvault Agent',
    namespace: 'fe-signalloom-agents',
    service_account: 'cardvault-agent',
    state: 'idle',
  }

  it('derives a live registration entry from a discovered pod', () => {
    const [derived] = deriveEntriesFromAgents([agent])
    expect(derived.spiffeId).toBe('spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent')
    expect(derived.provenance).toBe('live')
    expect(derived.selectors).toEqual(['k8s:ns:fe-signalloom-agents', 'k8s:sa:cardvault-agent'])
  })

  it('drops agents with no namespace or service account rather than guessing one', () => {
    expect(deriveEntriesFromAgents([{ ...agent, service_account: null }])).toEqual([])
    expect(deriveEntriesFromAgents([{ ...agent, namespace: null }])).toEqual([])
  })

  it('reports a stunned agent as revoked', () => {
    const [derived] = deriveEntriesFromAgents([{ ...agent, state: 'stunned' }])
    expect(derived.state).toBe('revoked')
  })

  it('de-duplicates pods that share one service account', () => {
    const replicas = [agent, { ...agent, id: 'cardvault-agent-def' }]
    expect(deriveEntriesFromAgents(replicas)).toHaveLength(1)
  })

  // Verified against the running cluster on 2026-08-02: the five agent-* pods in
  // fe-signalloom-agents all run serviceAccountName `default`, and no SPIRE
  // registration entry exists for it. Reporting those as active identities
  // would invent an SVID that SPIRE never issued.
  it('marks a pod with no matching registration entry as pending, not active', () => {
    const unregistered: RuntimeAgentIdentity = {
      id: 'agent-dennis',
      name: 'Dennis',
      namespace: 'fe-signalloom-agents',
      service_account: 'default',
      state: 'active',
    }
    const [derived] = deriveEntriesFromAgents([unregistered], CONFIG_REGISTRATION_ENTRIES)
    expect(derived.state).toBe('pending')
    expect(derived.registered).toBe(false)
  })

  it('marks a pod that does match a registration entry as registered and active', () => {
    const [derived] = deriveEntriesFromAgents([agent], CONFIG_REGISTRATION_ENTRIES)
    expect(derived.state).toBe('active')
    expect(derived.registered).toBe(true)
  })

  it('still reports a stunned unregistered pod as revoked — revocation outranks pending', () => {
    const [derived] = deriveEntriesFromAgents(
      [{ ...agent, service_account: 'default', state: 'stunned' }],
      CONFIG_REGISTRATION_ENTRIES,
    )
    expect(derived.state).toBe('revoked')
  })

  it('treats every identity as registered when no registration set is supplied', () => {
    const [derived] = deriveEntriesFromAgents([{ ...agent, service_account: 'default' }])
    expect(derived.registered).toBe(true)
    expect(derived.state).toBe('active')
  })
})

describe('credentials for an unregistered identity', () => {
  it('are pending, not active — no SVID exists to report', () => {
    const unregistered = entry({ state: 'pending', registered: false })
    const creds = credentialsForEntry(unregistered, { now: NOW })
    expect(creds.every((c) => c.status === 'pending')).toBe(true)
  })

  it('are not counted as active in the summary', () => {
    const creds = credentialsForEntry(entry({ state: 'pending', registered: false }), { now: NOW })
    const summary = summariseCredentials(creds, NOW)
    expect(summary.active).toBe(0)
    expect(summary.pending).toBe(3)
  })

  it('do not get downgraded to failed by the OpenBao proof — there was no exchange', () => {
    const creds = credentialsForEntry(
      entry({ state: 'pending', registered: false }),
      { now: NOW, baoExchangeProven: false },
    )
    expect(creds.every((c) => c.status === 'pending')).toBe(true)
  })
})

describe('mergeEntries', () => {
  it('lets a live entry supersede the config entry for the same SPIFFE ID', () => {
    const live = entry({ provenance: 'live', state: 'revoked' })
    const merged = mergeEntries(CONFIG_REGISTRATION_ENTRIES, [live])
    const cardvault = merged.filter((e) => e.serviceAccount === 'cardvault-agent')
    expect(cardvault).toHaveLength(1)
    expect(cardvault[0].provenance).toBe('live')
    expect(cardvault[0].state).toBe('revoked')
  })

  it('keeps the config-only OpenBao binding when live discovery cannot supply it', () => {
    const live = entry({ provenance: 'live', baoRole: undefined, baoPolicyPath: undefined })
    const [cardvault] = mergeEntries(CONFIG_REGISTRATION_ENTRIES, [live])
      .filter((e) => e.serviceAccount === 'cardvault-agent')
    expect(cardvault.baoRole).toBe('signalloom-cardvault-agent')
    expect(cardvault.baoPolicyPath).toBe('kv/data/signalloom/cardvault-agent')
  })

  it('retains config entries that live discovery never saw', () => {
    const merged = mergeEntries(CONFIG_REGISTRATION_ENTRIES, [])
    expect(merged).toHaveLength(CONFIG_REGISTRATION_ENTRIES.length)
  })
})

// ─── Credential records ─────────────────────────────────────────────────────

describe('credentialsForEntry', () => {
  it('emits the three links of the identity chain: SVID, OpenBao lease, service token', () => {
    const creds = credentialsForEntry(entry(), { now: NOW })
    expect(creds.map((c) => c.kind)).toEqual(['x509-svid', 'openbao-lease', 'service-token'])
  })

  it('scopes the SVID to the SPIFFE ID and the lease to the OpenBao policy path', () => {
    const [svid, lease] = credentialsForEntry(entry(), { now: NOW })
    expect(svid.scope).toBe('spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent')
    expect(svid.issuer).toBe('spire-server.inf-bao')
    expect(lease.scope).toBe('kv/data/signalloom/cardvault-agent')
    expect(lease.issuer).toBe('openbao.inf-bao')
  })

  it('marks every credential revoked when the workload identity is revoked', () => {
    const creds = credentialsForEntry(entry({ state: 'revoked' }), { now: NOW })
    expect(creds.every((c) => c.status === 'revoked')).toBe(true)
    expect(creds.every((c) => c.revokedAt !== null)).toBe(true)
  })

  it('derives expiry from the credential TTL rather than a fixed timestamp', () => {
    const [svid] = credentialsForEntry(entry(), { now: NOW })
    const lifetimeMs = Date.parse(svid.expiresAt) - Date.parse(svid.issuedAt)
    expect(lifetimeMs).toBe(svid.ttlSeconds * 1000)
  })

  it('downgrades the OpenBao lease to failed when the live crypto proof failed', () => {
    const creds = credentialsForEntry(entry(), { now: NOW, baoExchangeProven: false })
    const lease = creds.find((c) => c.kind === 'openbao-lease')
    expect(lease?.status).toBe('failed')
  })

  it('leaves the lease active when the live crypto proof passed', () => {
    const creds = credentialsForEntry(entry(), { now: NOW, baoExchangeProven: true })
    expect(creds.find((c) => c.kind === 'openbao-lease')?.status).toBe('active')
  })

  it('inherits the entry provenance so no row can claim to be more real than its source', () => {
    const creds = credentialsForEntry(entry({ provenance: 'demo' }), { now: NOW })
    expect(creds.every((c) => c.provenance === 'demo')).toBe(true)
  })

  it('flags a credential expiring inside the warning window', () => {
    const creds = credentialsForEntry(entry(), { now: NOW })
    const svid = creds.find((c) => c.kind === 'x509-svid')!
    // A 1h SVID minted `now` is always inside the 15m warning window at 46m+.
    const at46m = new Date(NOW.getTime() + 46 * 60_000)
    expect(svid.ttlSeconds).toBe(3600)
    expect(Date.parse(svid.expiresAt) - at46m.getTime()).toBeLessThan(15 * 60_000)
  })
})

describe('summariseCredentials', () => {
  it('counts credentials by status and reports the distinct workload count', () => {
    const records = [
      ...credentialsForEntry(entry(), { now: NOW }),
      ...credentialsForEntry(
        entry({
          spiffeId: spiffeId('fe-signalloom', 'fe-signalloom'),
          namespace: 'fe-signalloom',
          serviceAccount: 'fe-signalloom',
          state: 'revoked',
        }),
        { now: NOW },
      ),
    ]
    const summary = summariseCredentials(records, NOW)
    expect(summary.total).toBe(6)
    expect(summary.active).toBe(3)
    expect(summary.revoked).toBe(3)
    expect(summary.workloads).toBe(2)
  })

  it('counts a credential whose expiry has passed as expired, not active', () => {
    const records = credentialsForEntry(entry(), { now: NOW })
    const wayLater = new Date(NOW.getTime() + 48 * 3600 * 1000)
    const summary = summariseCredentials(records, wayLater)
    expect(summary.active).toBe(0)
    expect(summary.expired).toBe(3)
  })
})

// ─── Demo fallback ──────────────────────────────────────────────────────────

describe('DEMO_REGISTRATION_ENTRIES', () => {
  it('labels every demo entry as demo provenance', () => {
    expect(DEMO_REGISTRATION_ENTRIES.every((e) => e.provenance === 'demo')).toBe(true)
  })

  it('covers more than the two config identities so the demo has something to show', () => {
    expect(DEMO_REGISTRATION_ENTRIES.length).toBeGreaterThan(CONFIG_REGISTRATION_ENTRIES.length)
  })

  it('includes at least one revoked identity so the revocation path renders offline', () => {
    expect(DEMO_REGISTRATION_ENTRIES.some((e) => e.state === 'revoked')).toBe(true)
  })

  it('uses the real trust domain — a demo row must not teach a wrong SPIFFE ID', () => {
    expect(DEMO_REGISTRATION_ENTRIES.every((e) => e.spiffeId.startsWith(`spiffe://${TRUST_DOMAIN}/`))).toBe(true)
  })
})
