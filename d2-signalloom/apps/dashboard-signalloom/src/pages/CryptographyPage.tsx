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
import { useState, useEffect, useCallback, type ReactNode, type CSSProperties } from 'react'
import { PieChart, Pie, Cell } from 'recharts'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import StatusBadge from '../components/StatusBadge'
import { colors } from '../styles/tokens'
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
  eolDate: string | null
  quantumSafe: boolean
}

const ALGORITHM_INVENTORY: AlgorithmEntry[] = [
  { algorithm: 'ML-KEM (Kyber)', standard: 'FIPS 203', type: 'KEM', nistStatus: 'Standardised 2024', eolDate: null, quantumSafe: true },
  { algorithm: 'ML-DSA (Dilithium)', standard: 'FIPS 204', type: 'Signature', nistStatus: 'Standardised 2024', eolDate: null, quantumSafe: true },
  { algorithm: 'SLH-DSA (SPHINCS+)', standard: 'FIPS 205', type: 'Signature (hash-based)', nistStatus: 'Standardised 2024', eolDate: null, quantumSafe: true },
  { algorithm: 'RSA-2048', standard: 'FIPS 186-5', type: 'Signature (classical)', nistStatus: 'Approved (disallow after 2030)', eolDate: '2030', quantumSafe: false },
  { algorithm: 'ECDSA P-256', standard: 'FIPS 186-5', type: 'Signature (classical)', nistStatus: 'Approved (disallow after 2030)', eolDate: '2030', quantumSafe: false },
  { algorithm: 'ECDSA P-384', standard: 'FIPS 186-5', type: 'Signature (classical)', nistStatus: 'Approved (disallow after 2030)', eolDate: '2030', quantumSafe: false },
  { algorithm: 'X25519', standard: 'RFC 7748', type: 'Key exchange', nistStatus: 'Approved', eolDate: '2030', quantumSafe: false },
  { algorithm: 'AES-256', standard: 'FIPS 197', type: 'Symmetric', nistStatus: 'Approved', eolDate: null, quantumSafe: true },
]

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

function hex(c: string, o: number) {
  return c + Math.round(o * 255).toString(16).padStart(2, '0')
}

const PILL: Record<string, string> = {
  active: colors.tealLoom,
  unsealed: colors.tealLoom,
  ready: colors.tealLoom,
  renewing: colors.cyanLoom,
  hybrid: colors.cyanLoom,
  pending: colors.cyanLoom,
  expiring: colors.amber,
  degraded: colors.amber,
  classical: colors.amber,
  sealed: colors.red,
  revoked: colors.red,
}

function Pill({ label }: { label: string }) {
  const c = PILL[label] ?? colors.muted
  return (
    <span className="tag" style={{ background: hex(c, 0.12), color: c }}>
      {label}
    </span>
  )
}

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

function StatCard({ label, value, sub, accent }: { label: string; value: string; sub: string; accent: string }) {
  return (
    <div className="card" style={{ flex: 1, minWidth: 190, padding: '16px 18px' }}>
      <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>{label}</div>
      <div style={{ fontSize: 26, fontWeight: 700, color: accent, lineHeight: 1 }}>{value}</div>
      <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6 }}>{sub}</div>
    </div>
  )
}

function Section({ title, hint, children }: { title: string; hint: string; children: ReactNode }) {
  return (
    <section style={{ marginBottom: 26 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 10 }}>
        <h2 style={{ fontSize: 16, fontWeight: 700, color: 'var(--text)' }}>{title}</h2>
        <span style={{ fontSize: 12, color: 'var(--muted)' }}>{hint}</span>
      </div>
      {children}
    </section>
  )
}

const th: CSSProperties = { padding: '9px 14px', textAlign: 'left', color: 'var(--muted)', fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em', whiteSpace: 'nowrap' }
const td: CSSProperties = { padding: '9px 14px', fontSize: 13, color: 'var(--text)', whiteSpace: 'nowrap' }

function Table({ headers, children }: { headers: string[]; children: ReactNode }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'auto' }}>
      <table style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead>
          <tr style={{ background: 'var(--surface2)', borderBottom: '1px solid var(--border)' }}>
            {headers.map((h) => <th key={h} style={th}>{h}</th>)}
          </tr>
        </thead>
        <tbody>{children}</tbody>
      </table>
    </div>
  )
}

// ── Page ─────────────────────────────────────────────────────────────────────

export default function CryptographyPage() {
  const { getAccessTokenSilently } = useAuth0()
  const [proofs, setProofs] = useState<CryptoProof[] | null>(null)
  const [proofError, setProofError] = useState(false)

  const load = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const res = await api.health.crypto(token)
      setProofs(res.proofs)
      setProofError(false)
    } catch {
      setProofs([])
      setProofError(true)
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    load()
  }, [load])

  return (
    <div style={{ paddingBottom: 40 }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>Cryptography</h1>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 22, maxWidth: 720 }}>
        Trust foundation for <code style={{ color: 'var(--cyan)' }}>{TRUST_DOMAIN}</code> — root of trust, secret
        bootstrap, workload identity, post-quantum readiness, and the identity-aware proxy fabric.
      </p>

      <Section title="Workload Identity Proofs (SPIFFE → OpenBao)" hint="live self-reported crypto trust health">
        {proofs === null ? (
          <div style={{ color: 'var(--muted)', fontSize: 13 }}>Loading workload-identity proofs…</div>
        ) : proofs.length === 0 ? (
          <div className="card" style={{ padding: '18px 16px' }}>
            <div style={{ fontSize: 15, fontWeight: 700, color: 'var(--text)', marginBottom: 6 }}>
              {proofError ? 'Workload-identity proof service unreachable' : 'No workload-identity proofs reported'}
            </div>
            <div style={{ fontSize: 13, color: 'var(--muted)', maxWidth: 720 }}>
              {proofError
                ? 'The dashboard could not reach the crypto-proof service (fe-signalloom → fake-integration-proxy → Kubernetes Job status for bao-spire-positive-proof / bao-spire-negative-proof). Check connectivity or backend health and retry.'
                : 'The crypto-proof service responded with zero proofs — the bao-spire-positive-proof / bao-spire-negative-proof Jobs may not have run yet in this namespace.'}
            </div>
          </div>
        ) : (
          <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap' }}>
            {proofs.map((proof) => {
              const badge = proofBadgeColor(proof.status)
              return (
                <div key={proof.name} className="card" style={{ flex: 1, minWidth: 320, padding: '18px 16px' }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 12, flexWrap: 'wrap' }}>
                    <span className="tag" style={{ background: hex(badge, 0.12), color: badge }}>
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
              <td style={td}><Pill label={ca.status} /></td>
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
              <td style={td}><Pill label={e.status} /></td>
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
        <Table headers={['SPIFFE ID', 'Workload', 'Selector', 'TTL', 'Status']}>
          {SPIRE.svids.map((s) => (
            <tr key={s.spiffeId} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={td}><code style={{ color: 'var(--cyan)', fontSize: 12 }}>{s.spiffeId}</code></td>
              <td style={{ ...td, color: 'var(--text)' }}>{s.workload}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{s.selector}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{s.ttl}</td>
              <td style={td}><StatusBadge status={s.status} variant="lifecycle" /></td>
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
            <Table headers={['Endpoint', 'TLS', 'Key exchange', 'PQC']}>
              {CIPHERS.map((c) => (
                <tr key={c.endpoint} style={{ borderBottom: '1px solid var(--border)' }}>
                  <td style={{ ...td, color: 'var(--text)' }}>{c.endpoint}</td>
                  <td style={{ ...td, color: 'var(--muted)' }}>{c.tls}</td>
                  <td style={td}><code style={{ color: 'var(--cyan)', fontSize: 12 }}>{c.kex}</code></td>
                  <td style={td}><Pill label={c.pqc} /></td>
                </tr>
              ))}
            </Table>
          </div>
        </div>
      </Section>

      {/* Algorithm Inventory — PQC migration readiness */}
      <Section title="Algorithm Inventory" hint="NIST post-quantum migration tracking">
        <Table headers={['Algorithm', 'Standard', 'Type', 'NIST Status', 'EOL Date', 'Quantum-safe']}>
          {ALGORITHM_INVENTORY.map((a) => (
            <tr key={a.algorithm} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...td, color: 'var(--text)', fontWeight: 500 }}>{a.algorithm}</td>
              <td style={td}><code style={{ color: 'var(--cyan)', fontSize: 12 }}>{a.standard}</code></td>
              <td style={{ ...td, color: 'var(--muted)' }}>{a.type}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{a.nistStatus}</td>
              <td style={td}>
                {a.eolDate
                  ? <span style={{ color: colors.amber, fontWeight: 600 }}>{a.eolDate}</span>
                  : <span style={{ color: colors.tealLoom }}>None</span>}
              </td>
              <td style={td}><Pill label={a.quantumSafe ? 'ready' : 'classical'} /></td>
            </tr>
          ))}
        </Table>
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
              <td style={td}><Pill label={p.status} /></td>
            </tr>
          ))}
        </Table>
      </Section>
    </div>
  )
}
