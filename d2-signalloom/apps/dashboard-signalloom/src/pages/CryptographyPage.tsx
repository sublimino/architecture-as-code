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
import { useState, useEffect, useCallback, useRef } from 'react'
import { Link } from 'react-router-dom'
import DataTable from '../components/DataTable'
import { PieChart, Pie, Cell } from 'recharts'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import StatusBadge, { tint } from '../components/StatusBadge'
import { StatCard, Section, Table, td } from '../components/DashKit'
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
  { name: 'PQC ready', value: pqcReady, color: colors.tealLoom },
  { name: 'Hybrid', value: pqcHybrid, color: colors.cyanLoom },
  { name: 'Classical', value: pqcClassical, color: colors.amber },
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
        <Table headers={['Common Name', 'Role', 'Algorithm', 'Expires', 'Status']}>
          {ROOT_OF_TRUST.map((ca) => (
            <tr key={ca.cn} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...td, color: 'var(--text)', fontWeight: 500 }}>{ca.cn}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{ca.role}</td>
              <td style={td}><code style={{ color: 'var(--cyan)' }}>{ca.algo}</code></td>
              <td style={{ ...td, color: 'var(--muted)' }}>{ca.expires}</td>
              <td style={td}><StatusBadge status={ca.status} variant="crypto" /></td>
            </tr>
          ))}
        </Table>
      </Section>

      {/* OpenBao Bootstrap */}
      <Section title="OpenBao Bootstrap" hint={`${BAO.version} · ${BAO.sealType}`}>
        <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 12 }}>
          <StatCard label="Seal status" value={BAO.seal} sub={`${BAO.keyThreshold} of ${BAO.keyShares} unseal shares`} accent="var(--teal)" />
          <StatCard label="HA mode" value="raft" sub={BAO.ha} accent="var(--cyan)" />
          <StatCard label="Engines" value={String(BAO.engines.length)} sub="mounted secret engines" accent="var(--violet)" />
        </div>
        <Table headers={['Mount path', 'Type', 'Active leases', 'Status']}>
          {BAO.engines.map((e) => (
            <tr key={e.path} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={td}><code style={{ color: 'var(--cyan)' }}>{e.path}</code></td>
              <td style={{ ...td, color: 'var(--muted)' }}>{e.type}</td>
              <td style={td}>{e.leases}</td>
              <td style={td}><StatusBadge status={e.status} variant="crypto" /></td>
            </tr>
          ))}
        </Table>
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
        <Table headers={['SPIFFE ID', 'Workload', 'Selector', 'TTL', 'Status']}>
          {SPIRE.svids.map((s) => (
            <tr key={s.spiffeId} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={td}><code style={{ color: 'var(--cyan)', fontSize: 12 }}>{s.spiffeId}</code></td>
              <td style={{ ...td, color: 'var(--text)' }}>{s.workload}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{s.selector}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{s.ttl}</td>
              <td style={td}><StatusBadge status={s.status} variant="credential" /></td>
            </tr>
          ))}
        </Table>
      </Section>

      {/* PQC Cipher Discovery */}
      <Section title="Cipher Discovery (PQC)" hint="post-quantum migration posture">
        <div style={{ display: 'flex', gap: 18, alignItems: 'flex-start', flexWrap: 'wrap' }}>
          <div className="card" style={{ padding: '18px 16px', display: 'flex', flexDirection: 'column', alignItems: 'center', width: 220, flexShrink: 0 }}>
            <div style={{ position: 'relative', width: 160, height: 160 }}>
              <PieChart width={160} height={160}>
                <Pie data={PQC_DONUT} cx={80} cy={80} innerRadius={52} outerRadius={72} dataKey="value" paddingAngle={2}>
                  {PQC_DONUT.map((d) => <Cell key={d.name} fill={d.color} />)}
                </Pie>
              </PieChart>
              <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', pointerEvents: 'none' }}>
                <span style={{ fontSize: 24, fontWeight: 700, color: 'var(--text)', lineHeight: 1 }}>{pqcReadyPct}%</span>
                <span style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>quantum-safe</span>
              </div>
            </div>
            <div style={{ marginTop: 12, display: 'flex', flexDirection: 'column', gap: 5, width: '100%' }}>
              {PQC_DONUT.map((d) => (
                <div key={d.name} style={{ display: 'flex', alignItems: 'center', gap: 7, padding: '2px 4px' }}>
                  <span style={{ width: 10, height: 10, borderRadius: 2, background: d.color, flexShrink: 0 }} />
                  <span style={{ fontSize: 12, color: 'var(--text)', flex: 1 }}>{d.name}</span>
                  <span style={{ fontSize: 12, color: 'var(--muted)', fontWeight: 600 }}>{d.value}</span>
                </div>
              ))}
            </div>
          </div>
          <div style={{ flex: 1, minWidth: 320 }}>
            <DataTable<CipherEndpoint>
              columns={[
                { key: 'endpoint', label: 'Endpoint', sortable: true },
                { key: 'tls', label: 'TLS', sortable: true },
                { key: 'kex', label: 'Key exchange', sortable: true },
                { key: 'pqc', label: 'PQC', sortable: true },
                { key: 'endpoint', label: 'End of life' },
              ]}
              data={CIPHERS}
              pageSize={25}
              testIdPrefix="cipher-discovery"
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
          columns={[
            { key: 'algorithm', label: 'Algorithm', sortable: true },
            { key: 'standard', label: 'Standard', sortable: true },
            { key: 'type', label: 'Type', sortable: true },
            { key: 'nistStatus', label: 'NIST Status' },
            { key: 'algorithm', label: 'End of life' },
            { key: 'quantumSafe', label: 'Quantum-safe', sortable: true },
          ]}
          data={ALGORITHM_INVENTORY}
          pageSize={25}
          testIdPrefix="algo-inventory"
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
        <Table headers={['Proxy', 'Kind', 'Upstream', 'Identity provider', 'Status']}>
          {PROXIES.map((p) => (
            <tr key={p.name} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...td, color: 'var(--text)', fontWeight: 500 }}>{p.name}</td>
              <td style={td}><code style={{ color: 'var(--violet)' }}>{p.kind}</code></td>
              <td style={{ ...td, color: 'var(--muted)' }}>{p.upstream}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{p.provider}</td>
              <td style={td}><StatusBadge status={p.status} variant="crypto" /></td>
            </tr>
          ))}
        </Table>
      </Section>
    </div>
  )
}
