/**
 * Cryptography — platform trust-foundation dashboard.
 *
 * A self-contained, mock-backed operator view over the cryptographic trust
 * fabric of the Signal Loom platform: cluster root of trust, OpenBao bootstrap,
 * SPIFFE/SPIRE workload identity, post-quantum cipher readiness, and the
 * OAuth2/MCP proxy layer. Framing follows the workload-identity model popularised
 * by Cofide Connect (SPIFFE + OIDC, no static long-lived secrets).
 *
 * The page remains mock-backed for its main sections, with a live/demo hybrid
 * workload-identity proof section at the top so the trust story can render both
 * online and offline.
 */
import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { Link } from 'react-router-dom'
import DataTable, { type Column } from '../components/DataTable'
import DonutChart from '../components/DonutChart'
import HelpHint from '../components/HelpHint'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import StatusBadge, { tint } from '../components/StatusBadge'
import { StatCard, Section, td } from '../components/DashKit'
import EmptyState from '../components/EmptyState'
import ErrorState from '../components/ErrorState'
import LoadingState from '../components/LoadingState'
import { colors } from '../styles/tokens'
import { cryptoLifecycle } from '../data/cryptoLifecycle'
import type { CryptoProof } from '../types/api'

// ── Mock data ────────────────────────────────────────────────────────────────

const TRUST_DOMAIN = 'signalloom.svc.cluster.local'

interface CaLink {
  cn: string
  role: 'Root CA' | 'Intermediate CA' | 'Leaf issuer'
  algo: string
  expires: string
  status: 'active' | 'renewing' | 'expiring'
}

const ROOT_OF_TRUST: CaLink[] = [
  { cn: 'SignalLoom Cluster Root R1', role: 'Root CA', algo: 'ECDSA P-384', expires: '2035-01-14', status: 'active' },
  { cn: 'OpenBao PKI Intermediate I1', role: 'Intermediate CA', algo: 'ECDSA P-256', expires: '2029-03-02', status: 'active' },
  { cn: 'SPIRE Server CA', role: 'Intermediate CA', algo: 'ECDSA P-256', expires: '2027-11-20', status: 'renewing' },
  { cn: 'mTLS Mesh Leaf Issuer', role: 'Leaf issuer', algo: 'ECDSA P-256', expires: '2026-08-30', status: 'expiring' },
]

interface SecretEngine {
  path: string
  type: string
  leases: number
  status: 'active' | 'sealed'
}

const BAO = {
  version: 'v2.1.1',
  seal: 'unsealed' as const,
  sealType: 'Shamir (3 of 5)',
  keyShares: 5,
  keyThreshold: 3,
  ha: 'active (raft, 3 nodes)',
  engines: [
    { path: 'pki/cluster-root', type: 'pki', leases: 42, status: 'active' },
    { path: 'pki/spire', type: 'pki', leases: 118, status: 'active' },
    { path: 'kv/signalloom', type: 'kv-v2', leases: 0, status: 'active' },
    { path: 'transit/envelope', type: 'transit', leases: 7, status: 'active' },
    { path: 'database/postgres', type: 'database', leases: 3, status: 'active' },
  ] as SecretEngine[],
}

interface Svid {
  spiffeId: string
  workload: string
  selector: string
  ttl: string
  status: 'active' | 'revoked' | 'pending'
}

const SPIRE = {
  trustDomain: TRUST_DOMAIN,
  server: { version: '1.9.4', nodeAttestor: 'k8s_psat', keyManager: 'disk', ha: '1 server / raft datastore' },
  agents: { total: 6, attested: 6, method: 'k8s_psat' },
  svids: [
    { spiffeId: `spiffe://${TRUST_DOMAIN}/ns/fe-signalloom/sa/dashboard`, workload: 'dashboard-signalloom', selector: 'k8s:sa:dashboard', ttl: '1h', status: 'active' },
    { spiffeId: `spiffe://${TRUST_DOMAIN}/ns/fe-signalloom/sa/api`, workload: 'fe-signalloom-api', selector: 'k8s:sa:api', ttl: '1h', status: 'active' },
    { spiffeId: `spiffe://${TRUST_DOMAIN}/ns/inf-signalloom/sa/fake-proxy`, workload: 'fake-integration-proxy', selector: 'k8s:sa:fake-proxy', ttl: '30m', status: 'active' },
    { spiffeId: `spiffe://${TRUST_DOMAIN}/ns/inf-bao/sa/openbao`, workload: 'openbao', selector: 'k8s:sa:openbao', ttl: '1h', status: 'active' },
    { spiffeId: `spiffe://${TRUST_DOMAIN}/ns/inf-signalloom/sa/legacy-batch`, workload: 'legacy-batch-runner', selector: 'k8s:sa:legacy-batch', ttl: '15m', status: 'revoked' },
  ] as Svid[],
}

interface AlgorithmEntry {
  algorithm: string
  standard: string
  type: 'KEM' | 'Signature' | 'Signature (hash-based)' | 'Key exchange' | 'Signature (classical)' | 'Symmetric'
  nistStatus: string
  quantumSafe: boolean
}

// EOL dates are deliberately NOT inline here — they're derived at render time
// from cryptoLifecycle.ts (CRYPTO_LIFECYCLE), the single sourced/cited data
// file also used by the Cipher Discovery table, so the two tables can never
// disagree about the same underlying algorithm.
const ALGORITHM_INVENTORY: AlgorithmEntry[] = [
  { algorithm: 'ML-KEM (Kyber)', standard: 'FIPS 203', type: 'KEM', nistStatus: 'Standardised 2024', quantumSafe: true },
  { algorithm: 'ML-DSA (Dilithium)', standard: 'FIPS 204', type: 'Signature', nistStatus: 'Standardised 2024', quantumSafe: true },
  { algorithm: 'SLH-DSA (SPHINCS+)', standard: 'FIPS 205', type: 'Signature (hash-based)', nistStatus: 'Standardised 2024', quantumSafe: true },
  { algorithm: 'RSA-2048', standard: 'FIPS 186-5', type: 'Signature (classical)', nistStatus: 'Quantum-vulnerable — disallowed after 2035 (NIST IR 8547 IPD)', quantumSafe: false },
  { algorithm: 'ECDSA P-256', standard: 'FIPS 186-5', type: 'Signature (classical)', nistStatus: 'Quantum-vulnerable — disallowed after 2035 (NIST IR 8547 IPD)', quantumSafe: false },
  { algorithm: 'ECDSA P-384', standard: 'FIPS 186-5', type: 'Signature (classical)', nistStatus: 'Quantum-vulnerable — disallowed after 2035 (NIST IR 8547 IPD)', quantumSafe: false },
  { algorithm: 'X25519', standard: 'RFC 7748', type: 'Key exchange', nistStatus: 'Quantum-vulnerable — disallowed after 2035 (NIST IR 8547 IPD)', quantumSafe: false },
  { algorithm: 'ECDH P-256', standard: 'NIST SP 800-56A Rev. 3', type: 'Key exchange', nistStatus: 'Quantum-vulnerable — disallowed after 2035 (NIST IR 8547 IPD)', quantumSafe: false },
  { algorithm: 'AES-256', standard: 'FIPS 197', type: 'Symmetric', nistStatus: 'Approved', quantumSafe: true },
]

// Cipher Discovery's `kex` values name TLS cipher groups, not the Algorithm
// Inventory's canonical algorithm names — this maps one onto the other so the
// "Key exchange" column can click through to a real, matching inventory row.
const KEX_TO_ALGORITHM_INVENTORY: Record<string, string> = {
  X25519MLKEM768: 'ML-KEM (Kyber)',
  'X25519 + ML-KEM-768': 'ML-KEM (Kyber)',
  'ECDHE P-256': 'ECDH P-256',
}

function algorithmRowId(algorithm: string): string {
  return `algo-inventory-${algorithm.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/(^-|-$)/g, '')}`
}

interface CipherEndpoint {
  endpoint: string
  tls: string
  kex: string
  pqc: 'ready' | 'hybrid' | 'classical'
}

const CIPHERS: CipherEndpoint[] = [
  { endpoint: 'gateway.signalloom (ingress)', tls: 'TLS 1.3', kex: 'X25519MLKEM768', pqc: 'ready' },
  { endpoint: 'fe-signalloom-api', tls: 'TLS 1.3', kex: 'X25519MLKEM768', pqc: 'ready' },
  { endpoint: 'dex (OIDC issuer)', tls: 'TLS 1.3', kex: 'X25519 + ML-KEM-768', pqc: 'hybrid' },
  { endpoint: 'openbao', tls: 'TLS 1.3', kex: 'X25519 + ML-KEM-768', pqc: 'hybrid' },
  { endpoint: 'postgres (internal)', tls: 'TLS 1.2', kex: 'ECDHE P-256', pqc: 'classical' },
  { endpoint: 'redis (internal)', tls: 'TLS 1.2', kex: 'ECDHE P-256', pqc: 'classical' },
]

interface Proxy {
  name: string
  kind: 'oauth2-proxy' | 'mcp-proxy'
  upstream: string
  provider: string
  status: 'active' | 'degraded'
}

const PROXIES: Proxy[] = [
  { name: 'oauth2-proxy/dashboard', kind: 'oauth2-proxy', upstream: 'dashboard-signalloom:8080', provider: 'Dex (OIDC)', status: 'active' },
  { name: 'oauth2-proxy/api', kind: 'oauth2-proxy', upstream: 'fe-signalloom-api:8000', provider: 'Dex (OIDC)', status: 'active' },
  { name: 'mcp-proxy/llm-gateway', kind: 'mcp-proxy', upstream: 'fake-integration-proxy:9000', provider: 'SPIFFE mTLS', status: 'active' },
  { name: 'mcp-proxy/tools', kind: 'mcp-proxy', upstream: 'fake-integration-proxy:9001', provider: 'SPIFFE mTLS', status: 'degraded' },
]

// ── Derived summary ──────────────────────────────────────────────────────────

const pqcReady = CIPHERS.filter((c) => c.pqc === 'ready').length
const pqcHybrid = CIPHERS.filter((c) => c.pqc === 'hybrid').length
const pqcClassical = CIPHERS.filter((c) => c.pqc === 'classical').length
const pqcReadyPct = Math.round(((pqcReady + pqcHybrid) / CIPHERS.length) * 100)
const activeSvids = SPIRE.svids.filter((s) => s.status === 'active').length

const PQC_DONUT = [
  { label: 'PQC ready', value: pqcReady, color: colors.tealLoom },
  { label: 'Hybrid', value: pqcHybrid, color: colors.cyanLoom },
  { label: 'Classical', value: pqcClassical, color: colors.amber },
]

// ── Small presentational helpers ─────────────────────────────────────────────
//
// The local `hex()`, `Pill`, `StatCard`, `Section` and `Table` that used to
// live here are gone. The last four were character-level duplicates of
// DashKit's; `hex()` was worse than duplication — it concatenated an alpha
// suffix onto its argument, and every colour it was handed is a `var(--teal)`
// token rather than a hex literal (see styles/tokens.ts), so every pill on this
// page computed `background: var(--teal)1f`, which is not a colour and was
// dropped. Every badge here has been rendering with no fill at all in all three
// themes. StatusBadge's `tint()` is the working pattern — `color-mix`, which
// composes with custom properties — and it is what the Design System page
// already points at for this exact defect.

function proofBadgeColor(status: CryptoProof['status']) {
  switch (status) {
    case 'passed':
      return colors.tealLoom
    case 'failed':
    case 'error':
      return colors.red
    case 'pending':
      return colors.amber
  }
}

// ── Filtering ────────────────────────────────────────────────────────────────
//
// Six tables, one strip. Every table on this page is a DataTable in the shape
// the Design System page calls "Realistic": a `toolbar` slot carrying the
// controls and an `emptyState` for the filter that matches nothing. The page
// still owns the state and the predicate — DataTable reads neither and is
// handed an already-narrowed array — which is exactly why the strip itself can
// be shared here without sharing an opinion about what "search" means.
//
// FilterBar is local to this file rather than a component, deliberately. What
// it standardises is layout and wording across six sibling tables on ONE page;
// the moment a second page wants it, the predicate argument starts growing
// options and it becomes the thing DataTable's header comment warns against.

/** The chip that clears the categorical filter. Present on every table. */
const ALL = 'all'

interface FilterBarProps {
  /**
   * What this strip filters, phrased to complete "Search …" and "Filter …".
   *
   * It is the accessible name of the search box and of the group, so it has to
   * name the table rather than describe the control: six boxes all called
   * "Search" are six controls a speech-input user cannot tell apart.
   */
  name: string
  testIdPrefix: string
  placeholder: string
  search: string
  onSearch: (value: string) => void
  chips: readonly string[]
  counts: Record<string, number>
  active: string
  onChip: (chip: string) => void
  shown: number
  total: number
}

function FilterBar({
  name, testIdPrefix, placeholder, search, onSearch,
  chips, counts, active, onChip, shown, total,
}: FilterBarProps) {
  return (
    <div
      style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8 }}
      role="group"
      aria-label={`Filter ${name}`}
    >
      <input
        type="search"
        aria-label={`Search ${name}`}
        placeholder={placeholder}
        value={search}
        onChange={(e) => onSearch(e.target.value)}
        data-testid={`${testIdPrefix}-search`}
        style={{
          fontSize: 12, padding: '5px 9px', minWidth: 230,
          color: 'var(--text)', background: 'var(--surface2)',
          border: '1px solid var(--border)', borderRadius: 4,
        }}
      />
      {chips.map((chip) => {
        const selected = chip === active
        return (
          <button
            key={chip}
            type="button"
            onClick={() => onChip(chip)}
            aria-pressed={selected}
            data-testid={`${testIdPrefix}-filter-${chip}`}
            style={{
              fontSize: 11.5, padding: '4px 9px', borderRadius: 4, cursor: 'pointer',
              // Tinted fill plus a full-strength border, never a solid accent
              // fill: text on solid amber or cyan fails AA in at least one of
              // the three themes. Copied from the Design System's specimen so
              // the selected chip reads the same here as it does there.
              color: selected ? 'var(--cyan)' : 'var(--muted)',
              background: selected ? tint('var(--cyan)', 0.12) : 'var(--surface2)',
              // Longhands, not the `border` shorthand: a shorthand carrying a
              // color-mix() is unreadable to jsdom, which would put the whole
              // selected/unselected distinction beyond a test's reach.
              borderWidth: 1,
              borderStyle: 'solid',
              borderColor: selected ? tint('var(--cyan)', 0.45) : 'var(--border)',
            }}
          >
            {chip} <span style={{ color: 'var(--dim)' }}>{counts[chip]}</span>
          </button>
        )
      })}
      <span data-testid={`${testIdPrefix}-count`} style={{ fontSize: 11.5, color: 'var(--muted)' }}>
        {shown} of {total} shown
      </span>
    </div>
  )
}

/**
 * What a table shows when the filters match nothing.
 *
 * A separate wording from a healthy zero on purpose — nothing here ever
 * legitimately has no rows, so an empty table on this page is always something
 * the reader just did, and the body says how to undo it. The toolbar is still
 * above it, because DataTable renders the toolbar on the empty branch too.
 */
function NoMatch({ what }: { what: string }) {
  return (
    <EmptyState
      kicker="Nothing matches those filters"
      body={`Clear the search box or choose a different ${what} — the controls above stay put when the table empties.`}
    />
  )
}

/**
 * Search-and-chip state over a fixed array.
 *
 * `chipOf` and `matches` must be module-scope constants; a predicate rebuilt in
 * render re-runs the memo on every keystroke in an unrelated table.
 */
function useFilter<T>(
  rows: readonly T[],
  chipOf: (row: T) => string,
  matches: (row: T, query: string) => boolean,
) {
  const [search, setSearch] = useState('')
  const [chip, setChip] = useState<string>(ALL)

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    return rows.filter((row) => {
      if (chip !== ALL && chipOf(row) !== chip) return false
      if (!q) return true
      return matches(row, q)
    })
  }, [rows, chip, search, chipOf, matches])

  return { search, setSearch, chip, setChip, filtered }
}

/** Row counts per chip, for the badge on each chip. Fixed data, so computed once. */
function chipCounts<T>(rows: readonly T[], chips: readonly string[], chipOf: (row: T) => string) {
  return Object.fromEntries(
    chips.map((chip) => [chip, chip === ALL ? rows.length : rows.filter((r) => chipOf(r) === chip).length]),
  ) as Record<string, number>
}

// ── Table definitions ────────────────────────────────────────────────────────
//
// Columns, predicates and chip vocabularies live at module scope: the column
// arrays are then stable across renders, and the predicates are stable enough
// for useFilter's memo to mean something.
//
// `help` is set only where the header does not already say it. A "?" that
// restates its label is noise, and noise is what makes the ones carrying a
// threshold, a piece of SPIFFE vocabulary or a citation stop being read.

const CA_STATUSES = [ALL, 'active', 'renewing', 'expiring'] as const
const caChip = (ca: CaLink) => ca.status
const caMatches = (ca: CaLink, q: string) =>
  ca.cn.toLowerCase().includes(q) || ca.role.toLowerCase().includes(q) || ca.algo.toLowerCase().includes(q)
const CA_COUNTS = chipCounts(ROOT_OF_TRUST, CA_STATUSES, caChip)

const CA_COLUMNS: Column<CaLink>[] = [
  { key: 'cn', label: 'Common Name', sortable: true },
  {
    key: 'role',
    label: 'Role',
    sortable: true,
    help: 'Where this certificate sits in the chain. The Root CA is the self-signed anchor everything else traces back to and is the one thing that cannot be re-issued without redistributing trust. An Intermediate CA is signed by the root and does the day-to-day issuing. A Leaf issuer mints the short-lived certificates workloads actually present.',
  },
  { key: 'algo', label: 'Algorithm', sortable: true },
  { key: 'expires', label: 'Expires', sortable: true },
  {
    key: 'status',
    label: 'Status',
    sortable: true,
    help: 'active — valid, with no renewal under way. renewing — a replacement has been requested and both certificates are trusted while the swap completes. expiring — inside the renewal window with no replacement issued yet, so this one needs attention before the date beside it, not on it.',
  },
]

const ENGINE_STATUSES = [ALL, 'active', 'sealed'] as const
const engineChip = (e: SecretEngine) => e.status
const engineMatches = (e: SecretEngine, q: string) =>
  e.path.toLowerCase().includes(q) || e.type.toLowerCase().includes(q)
const ENGINE_COUNTS = chipCounts(BAO.engines, ENGINE_STATUSES, engineChip)

const ENGINE_COLUMNS: Column<SecretEngine>[] = [
  { key: 'path', label: 'Mount path', sortable: true },
  {
    key: 'type',
    label: 'Type',
    sortable: true,
    help: 'What the engine mounted at this path issues. pki signs certificates. kv-v2 stores versioned static secrets — the only kind here that is not short-lived. transit encrypts data on behalf of a caller without ever releasing the key. database mints per-request credentials against a real database and expires them.',
  },
  {
    key: 'leases',
    label: 'Active leases',
    sortable: true,
    help: 'How many credentials this engine has issued that have not yet expired or been revoked. It is a live count, not a total ever issued, so it falls on its own as leases time out. A kv-v2 engine reads zero because static secrets are not leased — that is the engine type, not a fault.',
  },
  { key: 'status', label: 'Status', sortable: true },
]

const SVID_STATUSES = [ALL, 'active', 'pending', 'revoked'] as const
const svidChip = (s: Svid) => s.status
const svidMatches = (s: Svid, q: string) =>
  s.spiffeId.toLowerCase().includes(q) || s.workload.toLowerCase().includes(q) || s.selector.toLowerCase().includes(q)
const SVID_COUNTS = chipCounts(SPIRE.svids, SVID_STATUSES, svidChip)

const SVID_COLUMNS: Column<Svid>[] = [
  {
    key: 'spiffeId',
    label: 'SPIFFE ID',
    sortable: true,
    help: 'The workload’s name in the trust domain, and the whole of its identity — there is no accompanying password or key file. The path segments are its namespace and service account, so the identity states where the workload runs rather than asserting who wrote it.',
  },
  { key: 'workload', label: 'Workload', sortable: true },
  {
    key: 'selector',
    label: 'Selector',
    sortable: true,
    help: 'What SPIRE checks about a running pod before it will hand that pod this identity. A workload that does not match cannot obtain the SVID even if it knows the name of it, which is what makes the identity non-forgeable rather than merely secret.',
  },
  { key: 'ttl', label: 'TTL', sortable: true },
  { key: 'status', label: 'Status', sortable: true },
]

const PQC_STATES = [ALL, 'ready', 'hybrid', 'classical'] as const
const cipherChip = (c: CipherEndpoint) => c.pqc
const cipherMatches = (c: CipherEndpoint, q: string) =>
  c.endpoint.toLowerCase().includes(q) || c.tls.toLowerCase().includes(q) || c.kex.toLowerCase().includes(q)
const CIPHER_COUNTS = chipCounts(CIPHERS, PQC_STATES, cipherChip)

const CIPHER_COLUMNS: Column<CipherEndpoint>[] = [
  { key: 'endpoint', label: 'Endpoint', sortable: true },
  { key: 'tls', label: 'TLS', sortable: true },
  {
    key: 'kex',
    label: 'Key exchange',
    sortable: true,
    help: 'The TLS group that negotiates the session key for this endpoint — the step a future quantum computer breaks retroactively, because traffic captured today can be decrypted once the key exchange falls. Underlined entries click through to the matching row in Algorithm Inventory below.',
  },
  {
    key: 'pqc',
    label: 'PQC',
    sortable: true,
    help: 'ready — the key exchange is post-quantum on its own. hybrid — a classical and a post-quantum exchange are combined, so the session stays safe unless both break; this counts as quantum-safe here. classical — quantum-vulnerable today, and vulnerable to traffic captured today and decrypted later.',
  },
  {
    key: 'endpoint',
    label: 'End of life',
    help: 'The date after which NIST disallows this algorithm, not a vendor support date or a guess by this dashboard. Read from the cited source in cryptoLifecycle.ts, which also backs Algorithm Inventory below — hover a badge for the citation.',
  },
]

const QUANTUM_SAFE = 'quantum-safe'
const QUANTUM_VULNERABLE = 'quantum-vulnerable'
const ALGO_CLASSES = [ALL, QUANTUM_SAFE, QUANTUM_VULNERABLE] as const
const algoChip = (a: AlgorithmEntry) => (a.quantumSafe ? QUANTUM_SAFE : QUANTUM_VULNERABLE)
const algoMatches = (a: AlgorithmEntry, q: string) =>
  a.algorithm.toLowerCase().includes(q) || a.standard.toLowerCase().includes(q) || a.type.toLowerCase().includes(q)
const ALGO_COUNTS = chipCounts(ALGORITHM_INVENTORY, ALGO_CLASSES, algoChip)

const ALGO_COLUMNS: Column<AlgorithmEntry>[] = [
  { key: 'algorithm', label: 'Algorithm', sortable: true },
  { key: 'standard', label: 'Standard', sortable: true },
  { key: 'type', label: 'Type', sortable: true },
  {
    key: 'nistStatus',
    label: 'NIST Status',
    help: 'Where NIST has placed this algorithm. Standardised means a published FIPS anyone may implement now. IPD means Initial Public Draft — the 2035 dates come from a draft that is not final, so treat them as the current direction of travel rather than a settled deadline.',
  },
  {
    key: 'algorithm',
    label: 'End of life',
    help: 'The date after which NIST disallows this algorithm, not a vendor support date or a guess by this dashboard. Read from the cited source in cryptoLifecycle.ts, which also backs Cipher Discovery above — hover a badge for the citation.',
  },
  {
    key: 'quantumSafe',
    label: 'Quantum-safe',
    sortable: true,
    help: 'Whether the algorithm survives a cryptographically relevant quantum computer. Public-key algorithms do not: Shor’s algorithm breaks RSA and every elliptic curve outright. Symmetric ones largely do, because Grover’s only halves the effective key length — which is why AES-256 is here and RSA-2048 is not.',
  },
]

const PROXY_KINDS = [ALL, 'oauth2-proxy', 'mcp-proxy'] as const
const proxyChip = (p: Proxy) => p.kind
const proxyMatches = (p: Proxy, q: string) =>
  p.name.toLowerCase().includes(q) || p.upstream.toLowerCase().includes(q) || p.provider.toLowerCase().includes(q)
const PROXY_COUNTS = chipCounts(PROXIES, PROXY_KINDS, proxyChip)

const PROXY_COLUMNS: Column<Proxy>[] = [
  { key: 'name', label: 'Proxy', sortable: true },
  {
    key: 'kind',
    label: 'Kind',
    sortable: true,
    help: 'oauth2-proxy sits in front of a human-facing service and turns an OIDC login into a request the upstream can trust. mcp-proxy does the same job for a model-context-protocol tool call, where the caller is an agent rather than a person and the identity is a workload SVID rather than a session.',
  },
  { key: 'upstream', label: 'Upstream', sortable: true },
  {
    key: 'provider',
    label: 'Identity provider',
    sortable: true,
    help: 'What the proxy checks the caller against. Dex (OIDC) verifies a token a human obtained by logging in. SPIFFE mTLS verifies the client certificate presented during the handshake, so there is no bearer token to steal and replay.',
  },
  {
    key: 'status',
    label: 'Status',
    sortable: true,
    help: 'degraded means the proxy is still serving but has lost redundancy or is failing a share of its health checks — requests through it are answered, so this will not show up as an outage until it is one.',
  },
]

// ── Page ─────────────────────────────────────────────────────────────────────

export default function CryptographyPage() {
  const { getAccessTokenSilently } = useAuth0()
  const [proofs, setProofs] = useState<CryptoProof[] | null>(null)
  const [proofError, setProofError] = useState(false)
  const [highlightedAlgo, setHighlightedAlgo] = useState<string | null>(null)

  // Holds whichever attempt is currently outstanding, so that both ways of
  // abandoning one — unmounting the page, and pressing Retry while the previous
  // request is still in flight — cancel it through the same path.
  const inFlight = useRef<AbortController | null>(null)

  const load = useCallback(async () => {
    inFlight.current?.abort()
    const attempt = new AbortController()
    inFlight.current = attempt
    try {
      const token = await getAccessTokenSilently()
      const res = await api.health.crypto(token, attempt.signal)
      if (attempt.signal.aborted) return
      setProofs(res.proofs)
      setProofError(false)
    } catch {
      // An abort means this page went away or a newer attempt superseded this
      // one — not that the proof service failed, and rendering it as a failure
      // would report an outage that never happened. It also must not reach
      // setProofs: after unmount React has no tree to dispatch into, and this
      // catch would then throw a second time from inside the handler itself,
      // with nothing above it left to catch that.
      if (attempt.signal.aborted) return
      setProofs([])
      setProofError(true)
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    load()
    return () => inFlight.current?.abort()
  }, [load])

  // Scrolls the Algorithm Inventory table to the row matching a Cipher
  // Discovery key-exchange entry and highlights it briefly. scrollIntoView is
  // optional-chained because jsdom (test env) doesn't implement it.
  const scrollToAlgorithm = useCallback((algorithm: string) => {
    document.getElementById(algorithmRowId(algorithm))?.scrollIntoView?.({ behavior: 'smooth', block: 'center' })
    setHighlightedAlgo(algorithm)
    window.setTimeout(() => {
      setHighlightedAlgo((current) => (current === algorithm ? null : current))
    }, 2400)
  }, [])

  // One per table. Each owns its own search and chip, so narrowing the ciphers
  // does not disturb the inventory the reader is comparing them against.
  const cas = useFilter(ROOT_OF_TRUST, caChip, caMatches)
  const engines = useFilter(BAO.engines, engineChip, engineMatches)
  const svids = useFilter(SPIRE.svids, svidChip, svidMatches)
  const ciphers = useFilter(CIPHERS, cipherChip, cipherMatches)
  const algos = useFilter(ALGORITHM_INVENTORY, algoChip, algoMatches)
  const proxies = useFilter(PROXIES, proxyChip, proxyMatches)

  return (
    <div style={{ paddingBottom: 40 }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>Cryptography</h1>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 22, maxWidth: 720 }}>
        Trust foundation for <code style={{ color: 'var(--cyan)' }}>{TRUST_DOMAIN}</code> — root of trust, secret
        bootstrap, workload identity, post-quantum readiness, and the identity-aware proxy fabric.
      </p>

      <Section title="Workload Identity Proofs (SPIFFE → OpenBao)" hint="live self-reported crypto trust health">
        {proofs === null ? (
          <LoadingState status="loading" label="workload-identity proofs" testId="crypto-proofs-load-state" />
        ) : proofs.length === 0 ? (
          // Two different answers that used to share one grey card. The design
          // system's rule is that a healthy zero and a fetch that never ran must
          // not look alike: ErrorState for the failure, EmptyState for the zero.
          // ErrorState also brings the Retry this dead end never had.
          <div className="card" data-testid="crypto-proofs-outcome" style={{ padding: 0 }}>
            {proofError ? (
              <ErrorState
                message={'Workload-identity proof service unreachable. The dashboard could not reach it '
                  + '(fe-signalloom → fake-integration-proxy → Kubernetes Job status for '
                  + 'bao-spire-positive-proof / bao-spire-negative-proof). Check connectivity or backend health.'}
                onRetry={() => void load()}
              />
            ) : (
              <EmptyState
                tone="amber"
                kicker="No workload-identity proofs reported"
                body={'The crypto-proof service responded with zero proofs — the bao-spire-positive-proof / '
                  + 'bao-spire-negative-proof Jobs may not have run yet in this namespace.'}
              />
            )}
          </div>
        ) : (
          <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap' }}>
            {proofs.map((proof) => {
              const badge = proofBadgeColor(proof.status)
              return (
                <div key={proof.name} className="card" style={{ flex: 1, minWidth: 320, padding: '18px 16px' }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 12, flexWrap: 'wrap' }}>
                    {/* Not StatusBadge: `pending` means "the Job has not
                        finished" here (amber, a wait) and "in flight" in the
                        crypto map (cyan), and one word cannot carry both. The
                        shared `tint` is what fixes the missing fill. */}
                    <span className="tag" style={{ background: tint(badge, 0.12), borderColor: tint(badge, 0.25), color: badge }}>
                      {proof.status}
                    </span>
                    <span style={{ fontSize: 12, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                      {proof.kind} proof
                    </span>
                  </div>
                  <div style={{ fontSize: 15, fontWeight: 700, color: 'var(--text)', marginBottom: 8 }}>{proof.title}</div>
                  <div style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 8 }}>{proof.description}</div>
                  <div style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 12 }}>{proof.expectation}</div>
                  <code style={{ display: 'block', fontSize: 12, lineHeight: 1.5, color: 'var(--muted)', whiteSpace: 'pre-wrap' }}>
                    {proof.evidence}
                  </code>
                </div>
              )
            })}
          </div>
        )}
      </Section>

      {/* Summary stat cards */}
      <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 28 }}>
        <StatCard label="Trust anchors" value={String(ROOT_OF_TRUST.length)} sub="root + intermediate CAs" accent="var(--cyan)" />
        <StatCard label="Workload identities" value={`${activeSvids}/${SPIRE.svids.length}`} sub="active SPIFFE SVIDs" accent="var(--violet)" />
        <StatCard label="PQC coverage" value={`${pqcReadyPct}%`} sub={`${pqcReady} ready · ${pqcHybrid} hybrid`} accent="var(--teal)" />
        <StatCard label="Secrets under mgmt" value={String(BAO.engines.reduce((n, e) => n + e.leases, 0))} sub={`${BAO.engines.length} OpenBao engines`} accent="var(--amber)" />
        <StatCard label="Identity proxies" value={String(PROXIES.length)} sub="OAuth2 + MCP" accent="var(--cyan)" />
      </div>

      {/* Cluster Root of Trust */}
      <Section title="Cluster Root of Trust" hint="certificate authority chain">
        <DataTable<CaLink>
          columns={CA_COLUMNS}
          data={cas.filtered}
          pageSize={25}
          testIdPrefix="root-of-trust"
          toolbar={
            <FilterBar
              name="the certificate authority chain"
              testIdPrefix="root-of-trust"
              placeholder="Search common name, role or algorithm…"
              search={cas.search}
              onSearch={cas.setSearch}
              chips={CA_STATUSES}
              counts={CA_COUNTS}
              active={cas.chip}
              onChip={cas.setChip}
              shown={cas.filtered.length}
              total={ROOT_OF_TRUST.length}
            />
          }
          emptyState={<NoMatch what="certificate status" />}
          renderRow={(ca) => (
            <tr key={ca.cn} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...td, color: 'var(--text)', fontWeight: 500 }}>{ca.cn}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{ca.role}</td>
              <td style={td}><code style={{ color: 'var(--cyan)' }}>{ca.algo}</code></td>
              <td style={{ ...td, color: 'var(--muted)' }}>{ca.expires}</td>
              <td style={td}><StatusBadge status={ca.status} variant="crypto" /></td>
            </tr>
          )}
        />
      </Section>

      {/* OpenBao Bootstrap */}
      <Section title="OpenBao Bootstrap" hint={`${BAO.version} · ${BAO.sealType}`}>
        <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 12 }}>
          <StatCard label="Seal status" value={BAO.seal} sub={`${BAO.keyThreshold} of ${BAO.keyShares} unseal shares`} accent="var(--teal)" />
          <StatCard label="HA mode" value="raft" sub={BAO.ha} accent="var(--cyan)" />
          <StatCard label="Engines" value={String(BAO.engines.length)} sub="mounted secret engines" accent="var(--violet)" />
        </div>
        <DataTable<SecretEngine>
          columns={ENGINE_COLUMNS}
          data={engines.filtered}
          pageSize={25}
          testIdPrefix="bao-engines"
          toolbar={
            <FilterBar
              name="the mounted secret engines"
              testIdPrefix="bao-engines"
              placeholder="Search mount path or type…"
              search={engines.search}
              onSearch={engines.setSearch}
              chips={ENGINE_STATUSES}
              counts={ENGINE_COUNTS}
              active={engines.chip}
              onChip={engines.setChip}
              shown={engines.filtered.length}
              total={BAO.engines.length}
            />
          }
          emptyState={<NoMatch what="seal status" />}
          renderRow={(e) => (
            <tr key={e.path} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={td}><code style={{ color: 'var(--cyan)' }}>{e.path}</code></td>
              <td style={{ ...td, color: 'var(--muted)' }}>{e.type}</td>
              <td style={td}>{e.leases}</td>
              <td style={td}><StatusBadge status={e.status} variant="crypto" /></td>
            </tr>
          )}
        />
      </Section>

      {/* SPIFFE / SPIRE Bootstrap */}
      <Section title="SPIFFE / SPIRE Bootstrap" hint={`trust domain ${SPIRE.trustDomain}`}>
        <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 12 }}>
          <StatCard label="SPIRE server" value={`v${SPIRE.server.version}`} sub={SPIRE.server.ha} accent="var(--cyan)" />
          <StatCard label="Agents attested" value={`${SPIRE.agents.attested}/${SPIRE.agents.total}`} sub={`via ${SPIRE.agents.method}`} accent="var(--teal)" />
          <StatCard label="Node attestor" value="k8s_psat" sub={`key manager: ${SPIRE.server.keyManager}`} accent="var(--violet)" />
        </div>
        <p style={{ fontSize: 12, color: 'var(--muted)', margin: '0 0 10px' }}>
          Bootstrap posture only. The live, per-workload credential state — SVID, OpenBao lease and
          service token, with issuance and expiry — is on{' '}
          <Link to="/credential-inventory" style={{ color: 'var(--cyan)' }}>Credential Inventory</Link>.
        </p>
        <DataTable<Svid>
          columns={SVID_COLUMNS}
          data={svids.filtered}
          pageSize={25}
          testIdPrefix="spire-svids"
          toolbar={
            <FilterBar
              name="the issued workload identities"
              testIdPrefix="spire-svids"
              placeholder="Search SPIFFE ID, workload or selector…"
              search={svids.search}
              onSearch={svids.setSearch}
              chips={SVID_STATUSES}
              counts={SVID_COUNTS}
              active={svids.chip}
              onChip={svids.setChip}
              shown={svids.filtered.length}
              total={SPIRE.svids.length}
            />
          }
          emptyState={<NoMatch what="SVID status" />}
          renderRow={(s) => (
            <tr key={s.spiffeId} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={td}><code style={{ color: 'var(--cyan)', fontSize: 12 }}>{s.spiffeId}</code></td>
              <td style={{ ...td, color: 'var(--text)' }}>{s.workload}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{s.selector}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{s.ttl}</td>
              <td style={td}><StatusBadge status={s.status} variant="credential" /></td>
            </tr>
          )}
        />
      </Section>

      {/* PQC Cipher Discovery */}
      <Section title="Cipher Discovery (PQC)" hint="post-quantum migration posture">
        <div style={{ display: 'flex', gap: 18, alignItems: 'flex-start', flexWrap: 'wrap' }}>
          {/* DonutChart, not Recharts. The design system's rule is that a
              single proportion of three segments is hand-rolled SVG and that
              Recharts is for things with axes — and the two things this page
              was hand-rolling around the PieChart, a centre label positioned by
              an absolute overlay and a legend built from the same array, are
              both already inside DonutChart. Same three segments, same colours,
              same percentage. */}
          <div className="card" style={{ padding: '18px 16px', display: 'flex', flexDirection: 'column', alignItems: 'center', width: 220, flexShrink: 0, gap: 10 }}>
            <DonutChart segments={PQC_DONUT} label={`${pqcReadyPct}%`} sublabel="quantum-safe" size={160} />
            {/* The figure counts hybrid endpoints as safe, which is a judgement
                rather than an observation and is not visible in "67%". */}
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <span style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                How this is counted
              </span>
              <HelpHint label="What the quantum-safe percentage counts" testId="pqc-coverage-hint">
                Endpoints whose key exchange is post-quantum ready OR hybrid, over all endpoints on this page — so a hybrid endpoint counts as safe, on the basis that an attacker must break both halves. It is a count of endpoints, not of traffic: the two classical ones here carry internal database and cache connections.
              </HelpHint>
            </div>
          </div>
          <div style={{ flex: 1, minWidth: 320 }}>
            <DataTable<CipherEndpoint>
              columns={CIPHER_COLUMNS}
              data={ciphers.filtered}
              pageSize={25}
              testIdPrefix="cipher-discovery"
              toolbar={
                <FilterBar
                  name="the discovered endpoints"
                  testIdPrefix="cipher-discovery"
                  placeholder="Search endpoint, TLS version or key exchange…"
                  search={ciphers.search}
                  onSearch={ciphers.setSearch}
                  chips={PQC_STATES}
                  counts={CIPHER_COUNTS}
                  active={ciphers.chip}
                  onChip={ciphers.setChip}
                  shown={ciphers.filtered.length}
                  total={CIPHERS.length}
                />
              }
              emptyState={<NoMatch what="post-quantum posture" />}
              renderRow={(c) => {
                const targetAlgorithm = KEX_TO_ALGORITHM_INVENTORY[c.kex]
                const lifecycle = cryptoLifecycle(c.kex)
                return (
                  <tr key={c.endpoint} style={{ borderBottom: '1px solid var(--border)' }}>
                    <td style={{ ...td, color: 'var(--text)' }}>{c.endpoint}</td>
                    <td style={{ ...td, color: 'var(--muted)' }}>{c.tls}</td>
                    <td style={td}>
                      {targetAlgorithm ? (
                        <button
                          type="button"
                          onClick={() => scrollToAlgorithm(targetAlgorithm)}
                          aria-label={`View ${c.kex} in Algorithm Inventory (${targetAlgorithm})`}
                          style={{
                            background: 'none',
                            border: 'none',
                            padding: 0,
                            margin: 0,
                            font: 'inherit',
                            cursor: 'pointer',
                          }}
                        >
                          <code
                            style={{
                              color: 'var(--cyan)',
                              fontSize: 12,
                              textDecoration: 'underline',
                              textUnderlineOffset: 3,
                            }}
                          >
                            {c.kex}
                          </code>
                        </button>
                      ) : (
                        <code style={{ color: 'var(--cyan)', fontSize: 12 }}>{c.kex}</code>
                      )}
                    </td>
                    <td style={td}><StatusBadge status={c.pqc} variant="crypto" /></td>
                    <td style={td}>
                      {lifecycle?.eolDate ? (
                        <span
                          className="tag"
                          title={lifecycle.source}
                          style={{ background: tint(colors.red, 0.12), borderColor: tint(colors.red, 0.25), color: colors.red }}
                        >
                          EOL {lifecycle.eolDate}
                        </span>
                      ) : (
                        <span style={{ color: colors.tealLoom }}>None</span>
                      )}
                    </td>
                  </tr>
                )
              }}
            />
          </div>
        </div>
      </Section>

      {/* Algorithm Inventory — PQC migration readiness */}
      <Section title="Algorithm Inventory" hint="NIST post-quantum migration tracking">
        <DataTable<AlgorithmEntry>
          columns={ALGO_COLUMNS}
          data={algos.filtered}
          pageSize={25}
          testIdPrefix="algo-inventory"
          toolbar={
            <FilterBar
              name="the algorithm inventory"
              testIdPrefix="algo-inventory"
              placeholder="Search algorithm, standard or type…"
              search={algos.search}
              onSearch={algos.setSearch}
              chips={ALGO_CLASSES}
              counts={ALGO_COUNTS}
              active={algos.chip}
              onChip={algos.setChip}
              shown={algos.filtered.length}
              total={ALGORITHM_INVENTORY.length}
            />
          }
          emptyState={<NoMatch what="quantum-safety class" />}
          renderRow={(a) => {
            const lifecycle = cryptoLifecycle(a.algorithm)
            return (
              <tr
                key={a.algorithm}
                id={algorithmRowId(a.algorithm)}
                data-highlighted={a.algorithm === highlightedAlgo}
                style={{
                  borderBottom: '1px solid var(--border)',
                  background: a.algorithm === highlightedAlgo ? tint(colors.cyanLoom, 0.16) : undefined,
                  transition: 'background 200ms ease',
                }}
              >
                <td style={{ ...td, color: 'var(--text)', fontWeight: 500 }}>{a.algorithm}</td>
                <td style={td}><code style={{ color: 'var(--cyan)', fontSize: 12 }}>{a.standard}</code></td>
                <td style={{ ...td, color: 'var(--muted)' }}>{a.type}</td>
                <td style={{ ...td, color: 'var(--muted)' }}>{a.nistStatus}</td>
                <td style={td}>
                  {lifecycle?.eolDate ? (
                    <span
                      className="tag"
                      title={lifecycle.source}
                      style={{ background: tint(colors.red, 0.12), borderColor: tint(colors.red, 0.25), color: colors.red }}
                    >
                      EOL {lifecycle.eolDate}
                    </span>
                  ) : (
                    <span style={{ color: colors.tealLoom }}>None</span>
                  )}
                </td>
                <td style={td}><StatusBadge status={a.quantumSafe ? 'ready' : 'classical'} variant="crypto" /></td>
              </tr>
            )
          }}
        />
      </Section>

      {/* OAuth2 / MCP Proxies */}
      <Section title="OAuth2 / MCP Proxies" hint="identity-aware proxy fabric">
        <DataTable<Proxy>
          columns={PROXY_COLUMNS}
          data={proxies.filtered}
          pageSize={25}
          testIdPrefix="proxies"
          toolbar={
            <FilterBar
              name="the identity-aware proxies"
              testIdPrefix="proxies"
              placeholder="Search proxy, upstream or provider…"
              search={proxies.search}
              onSearch={proxies.setSearch}
              chips={PROXY_KINDS}
              counts={PROXY_COUNTS}
              active={proxies.chip}
              onChip={proxies.setChip}
              shown={proxies.filtered.length}
              total={PROXIES.length}
            />
          }
          emptyState={<NoMatch what="proxy kind" />}
          renderRow={(p) => (
            <tr key={p.name} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...td, color: 'var(--text)', fontWeight: 500 }}>{p.name}</td>
              <td style={td}><code style={{ color: 'var(--violet)' }}>{p.kind}</code></td>
              <td style={{ ...td, color: 'var(--muted)' }}>{p.upstream}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{p.provider}</td>
              <td style={td}><StatusBadge status={p.status} variant="crypto" /></td>
            </tr>
          )}
        />
      </Section>
    </div>
  )
}
