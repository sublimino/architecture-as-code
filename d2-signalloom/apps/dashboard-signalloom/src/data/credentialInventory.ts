/**
 * Credential inventory — canonical model of the platform's workload identities
 * and the credentials minted from them.
 *
 * ## Why this module exists
 *
 * Three pages independently hard-coded a SPIFFE table and three different trust
 * domains: CryptographyPage (`signalloom.svc.cluster.local`), SuperCredPage
 * (`signalloom.ai`), FederatedServicesPage (`signalloom.demo`). Only the last
 * one is right. The deployed SPIRE server config is the authority —
 * `infra/inf-bao/controllers/base/spire-openbao-config.yaml` sets
 * `trust_domain = "signalloom.demo"` — so this module sources it from there and
 * the Credential Inventory page reads it from here.
 *
 * ## Provenance is a first-class field
 *
 * Every entry and every credential carries `provenance`:
 *   - `live`   — derived from a pod the proxy actually discovered in-cluster
 *   - `config` — read from the SPIRE/OpenBao manifests committed to this repo
 *   - `demo`   — fixture, shown only when the live path is unreachable
 *
 * The page renders that tag on every row. A dashboard that presents modelled
 * figures as measured ones is worse than no dashboard, so the distinction is
 * carried in the data, not left to a page-level banner that gets lost.
 */

// ─── Trust domain ───────────────────────────────────────────────────────────

/** Source: infra/inf-bao/controllers/base/spire-openbao-config.yaml (server.conf). */
export const TRUST_DOMAIN = 'signalloom.demo'

/**
 * Build a SPIFFE ID in the form SPIRE's k8s workload registrar issues.
 *
 * Segments are URI-encoded: a namespace or service-account name is attacker-
 * adjacent input once it comes from live pod metadata, and an unencoded `/`
 * would let it forge a different identity path.
 */
export function spiffeId(namespace: string, serviceAccount: string): string {
  return `spiffe://${TRUST_DOMAIN}/ns/${encodeURIComponent(namespace)}/sa/${encodeURIComponent(serviceAccount)}`
}

// ─── Types ──────────────────────────────────────────────────────────────────

export type Provenance = 'live' | 'config' | 'demo'

export type IdentityState = 'active' | 'revoked' | 'pending'

export interface RegistrationEntry {
  /** Canonical SPIFFE ID — the join key across config and live sources. */
  spiffeId: string
  namespace: string
  serviceAccount: string
  /** Human label; falls back to the service account when no display name exists. */
  workload: string
  selectors: string[]
  /** JWT-SVID audience the identity is minted for. */
  audience: string
  /** OpenBao JWT auth role bound to this SPIFFE ID, when one is configured. */
  baoRole?: string
  /** OpenBao path the bound role is permitted to read. */
  baoPolicyPath?: string
  provenance: Provenance
  state: IdentityState
  /**
   * Whether a SPIRE registration entry actually exists for this SPIFFE ID.
   *
   * A running pod is not an identity. Verified against the cluster on
   * 2026-08-02: the five `agent-*` pods in `fe-signalloom-agents` run
   * serviceAccountName `default`, for which nothing is registered — they hold
   * no SVID at all. That is a finding worth surfacing, not a row to paint
   * green.
   */
  registered: boolean
}

export type CredentialKind = 'x509-svid' | 'openbao-lease' | 'service-token'

export type CredentialStatus = 'active' | 'revoked' | 'expired' | 'failed' | 'pending'

export interface CredentialRecord {
  id: string
  spiffeId: string
  workload: string
  namespace: string
  kind: CredentialKind
  issuer: string
  scope: string
  status: CredentialStatus
  issuedAt: string
  expiresAt: string
  revokedAt: string | null
  ttlSeconds: number
  rotationCount: number
  provenance: Provenance
}

/** The subset of the `/supercred-api/agents` payload this module needs. */
export interface RuntimeAgentIdentity {
  id: string
  name?: string | null
  namespace?: string | null
  /** Pod `spec.serviceAccountName` — the second half of the SPIFFE ID. */
  service_account?: string | null
  state?: string | null
}

// ─── Config-sourced registration entries ────────────────────────────────────

/**
 * The SPIFFE identities registered by the manifests in this repo.
 *
 * Entry 1 — infra/inf-bao/controllers/base/spire-openbao-config.yaml (identity.json)
 * Entry 2 — infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml (JWT role)
 *
 * These are `config`, not `live`: the manifest says the identity should exist,
 * which is not the same as SPIRE having issued it.
 */
export const CONFIG_REGISTRATION_ENTRIES: RegistrationEntry[] = [
  {
    spiffeId: spiffeId('fe-signalloom', 'fe-signalloom'),
    namespace: 'fe-signalloom',
    serviceAccount: 'fe-signalloom',
    workload: 'fe-signalloom-api',
    selectors: ['k8s:ns:fe-signalloom', 'k8s:sa:fe-signalloom'],
    audience: 'openbao',
    baoRole: 'signalloom-fe-signalloom',
    baoPolicyPath: 'kv/data/signalloom/fe-signalloom',
    provenance: 'config',
    state: 'active',
    registered: true,
  },
  {
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
  },
]

// ─── Demo fallback ──────────────────────────────────────────────────────────

/**
 * Offline fixture set. Uses the real trust domain deliberately — a demo row
 * that teaches an operator the wrong SPIFFE ID format is a defect, not a
 * placeholder.
 */
export const DEMO_REGISTRATION_ENTRIES: RegistrationEntry[] = [
  ...CONFIG_REGISTRATION_ENTRIES.map((e): RegistrationEntry => ({ ...e, provenance: 'demo' })),
  {
    spiffeId: spiffeId('fe-signalloom', 'dashboard-signalloom'),
    namespace: 'fe-signalloom',
    serviceAccount: 'dashboard-signalloom',
    workload: 'dashboard-signalloom',
    selectors: ['k8s:ns:fe-signalloom', 'k8s:sa:dashboard-signalloom'],
    audience: 'openbao',
    provenance: 'demo',
    state: 'active',
    registered: true,
  },
  {
    spiffeId: spiffeId('inf-signalloom', 'fake-integration-proxy'),
    namespace: 'inf-signalloom',
    serviceAccount: 'fake-integration-proxy',
    workload: 'fake-integration-proxy',
    selectors: ['k8s:ns:inf-signalloom', 'k8s:sa:fake-integration-proxy'],
    audience: 'openbao',
    provenance: 'demo',
    state: 'active',
    registered: true,
  },
  {
    spiffeId: spiffeId('inf-signalloom', 'legacy-batch-runner'),
    namespace: 'inf-signalloom',
    serviceAccount: 'legacy-batch-runner',
    workload: 'legacy-batch-runner',
    selectors: ['k8s:ns:inf-signalloom', 'k8s:sa:legacy-batch-runner'],
    audience: 'openbao',
    provenance: 'demo',
    state: 'revoked',
    registered: true,
  },
]

// ─── Live derivation ────────────────────────────────────────────────────────

/**
 * Turn discovered pods into registration entries.
 *
 * A pod without a namespace or service account is dropped rather than
 * defaulted: guessing `default` would render a SPIFFE ID that does not exist,
 * which is worse than a short list.
 *
 * `registeredEntries` is the set of SPIFFE IDs SPIRE is actually configured to
 * issue. A discovered pod outside that set gets `state: 'pending'` and
 * `registered: false` — it is running with no workload identity. Omit the
 * argument and every pod is assumed registered.
 */
export function deriveEntriesFromAgents(
  agents: RuntimeAgentIdentity[],
  registeredEntries?: RegistrationEntry[],
): RegistrationEntry[] {
  const registeredIds = registeredEntries ? new Set(registeredEntries.map((e) => e.spiffeId)) : null
  const bySpiffeId = new Map<string, RegistrationEntry>()
  for (const agent of agents) {
    const namespace = agent.namespace
    const serviceAccount = agent.service_account
    if (!namespace || !serviceAccount) continue

    const id = spiffeId(namespace, serviceAccount)
    const registered = registeredIds === null || registeredIds.has(id)
    // Revocation outranks pending: a stunned pod was deliberately cut off, and
    // that is the fact the operator needs, registered or not.
    const state: IdentityState =
      agent.state === 'stunned' ? 'revoked'
      : registered ? 'active'
      : 'pending'

    // Replicas of one Deployment share a service account, so they share one
    // SPIFFE ID. First pod wins; a later revoked replica still downgrades the
    // entry, because a revoked identity is the operator-relevant state.
    const existing = bySpiffeId.get(id)
    if (existing) {
      if (state === 'revoked') existing.state = 'revoked'
      continue
    }
    bySpiffeId.set(id, {
      spiffeId: id,
      namespace,
      serviceAccount,
      workload: agent.name || serviceAccount,
      selectors: [`k8s:ns:${namespace}`, `k8s:sa:${serviceAccount}`],
      audience: 'openbao',
      provenance: 'live',
      state,
      registered,
    })
  }
  return [...bySpiffeId.values()]
}

/**
 * Overlay live entries onto config entries, keyed on SPIFFE ID.
 *
 * Live observation wins on state and provenance; the config keeps supplying the
 * OpenBao role and policy path, which live pod metadata cannot know.
 */
export function mergeEntries(
  configEntries: RegistrationEntry[],
  liveEntries: RegistrationEntry[],
): RegistrationEntry[] {
  const merged = new Map<string, RegistrationEntry>()
  for (const entry of configEntries) merged.set(entry.spiffeId, { ...entry })
  for (const live of liveEntries) {
    const base = merged.get(live.spiffeId)
    merged.set(live.spiffeId, base ? {
      ...base,
      ...live,
      baoRole: live.baoRole ?? base.baoRole,
      baoPolicyPath: live.baoPolicyPath ?? base.baoPolicyPath,
      // A config entry existing IS the registration, so a live match is
      // registered even if the caller derived it without a registration set.
      registered: true,
    } : { ...live })
  }
  return [...merged.values()]
}

// ─── Credential records ─────────────────────────────────────────────────────

/** TTLs match the SPIRE default SVID lifetime and OpenBao's dynamic lease. */
const TTL_SECONDS: Record<CredentialKind, number> = {
  'x509-svid': 3600,
  'openbao-lease': 300,
  'service-token': 600,
}

const ISSUERS: Record<CredentialKind, string> = {
  'x509-svid': 'spire-server.inf-bao',
  'openbao-lease': 'openbao.inf-bao',
  'service-token': 'cardvault.inf-signalloom',
}

export interface CredentialOptions {
  /** Clock injection — no `Date.now()` inside, so tests are deterministic. */
  now: Date
  /**
   * Result of the live SPIFFE→OpenBao proof (`/health/crypto`). When the proof
   * failed we say the lease failed rather than painting it green.
   * `undefined` means "no live signal", which leaves the lease as-is.
   */
  baoExchangeProven?: boolean
  /** Revocation instant when the identity is revoked. Defaults to `now`. */
  revokedAt?: string
}

const CREDENTIAL_ORDER: CredentialKind[] = ['x509-svid', 'openbao-lease', 'service-token']

export function credentialsForEntry(
  entry: RegistrationEntry,
  opts: CredentialOptions,
): CredentialRecord[] {
  const issuedAt = opts.now.toISOString()
  const revoked = entry.state === 'revoked'
  const revokedAt = revoked ? (opts.revokedAt ?? issuedAt) : null

  return CREDENTIAL_ORDER.map((kind) => {
    const ttlSeconds = TTL_SECONDS[kind]
    const scope =
      kind === 'x509-svid' ? entry.spiffeId
      : kind === 'openbao-lease' ? (entry.baoPolicyPath ?? `auth/jwt/role/${entry.serviceAccount}`)
      : `${entry.workload}:api/v1:read`

    // An unregistered identity holds nothing. Every credential is pending —
    // reporting an SVID SPIRE never issued is the fabrication this page exists
    // to prevent, and a failed exchange cannot apply to an exchange that never
    // happened.
    const unregistered = !entry.registered
    let status: CredentialStatus =
      revoked ? 'revoked'
      : unregistered ? 'pending'
      : 'active'
    // A failed SPIFFE→OpenBao exchange only invalidates the lease. The SVID was
    // still issued — conflating the two would hide which link of the chain broke.
    if (status === 'active' && kind === 'openbao-lease' && opts.baoExchangeProven === false) {
      status = 'failed'
    }

    return {
      id: `${entry.serviceAccount}-${kind}`,
      spiffeId: entry.spiffeId,
      workload: entry.workload,
      namespace: entry.namespace,
      kind,
      issuer: ISSUERS[kind],
      scope,
      status,
      issuedAt,
      expiresAt: new Date(opts.now.getTime() + ttlSeconds * 1000).toISOString(),
      revokedAt,
      ttlSeconds,
      // Rotation count is a function of elapsed lifetime over TTL for a
      // short-lived credential — SPIRE rotates continuously.
      rotationCount: kind === 'x509-svid' ? 0 : Math.floor(3600 / ttlSeconds) - 1,
      provenance: entry.provenance,
    }
  })
}

// ─── Summary ────────────────────────────────────────────────────────────────

export interface CredentialSummary {
  total: number
  active: number
  revoked: number
  expired: number
  failed: number
  /** Identities discovered in-cluster with no SPIRE registration entry. */
  pending: number
  expiringSoon: number
  workloads: number
}

/** Credentials inside this window of expiry are surfaced as "expiring soon". */
export const EXPIRY_WARNING_MS = 15 * 60 * 1000

export function summariseCredentials(records: CredentialRecord[], now: Date): CredentialSummary {
  const summary: CredentialSummary = {
    total: records.length,
    active: 0,
    revoked: 0,
    expired: 0,
    failed: 0,
    pending: 0,
    expiringSoon: 0,
    workloads: new Set(records.map((r) => r.spiffeId)).size,
  }
  for (const record of records) {
    const status = effectiveStatus(record, now)
    if (status === 'active') {
      summary.active += 1
      if (Date.parse(record.expiresAt) - now.getTime() <= EXPIRY_WARNING_MS) summary.expiringSoon += 1
    } else if (status === 'revoked') summary.revoked += 1
    else if (status === 'expired') summary.expired += 1
    else if (status === 'failed') summary.failed += 1
    else if (status === 'pending') summary.pending += 1
  }
  return summary
}

/**
 * Status with the clock applied. A stored `active` whose expiry has passed is
 * `expired` — short-lived credentials go stale between renders, and reporting a
 * dead credential as active is the exact failure this page exists to catch.
 */
export function effectiveStatus(record: CredentialRecord, now: Date): CredentialStatus {
  // A pending credential has no real expiry to pass — it was never issued.
  if (record.status !== 'active') return record.status
  return Date.parse(record.expiresAt) <= now.getTime() ? 'expired' : record.status
}
