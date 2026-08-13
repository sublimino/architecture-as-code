/**
 * Federated Services — inspired by Cofide Connect's flagship capability.
 *
 * Cofide's "federated service" (docs.cofide.dev/concepts) simplifies secure
 * discovery and connectivity between workloads in *different* SPIFFE trust zones,
 * without static long-lived secrets — brokered by the Cofide Agent over xDS
 * (Envoy) and the Cofide Go SDK (github.com/cofide/cofide-sdk-go). This tab makes
 * that fabric legible: trust zones, federations, the federated services flowing
 * across them, and the attestation policies that gate who may federate.
 *
 * Self-contained mock data — renders without any API/auth dependency, which is
 * the single most important thing to say out loud about this page. Nothing here
 * was measured; the provenance banner and its proof console say so, because a
 * trust-fabric dashboard that reads as live and is not is worse than no page.
 *
 * Tables stay on DashKit's static `Table` rather than DataTable, resolving the
 * standing TODO: DataTable earns its keep at "more rows than fit on a screen,
 * and the reader needs to sort them" (Design System, DataTable). These are six
 * tables of three to five rows. Pagination would be furniture and sorting a
 * five-row list is a control nobody reaches for.
 */
import { useState } from 'react'
import { StatCard, Section, Table, td } from '../components/DashKit'
import StatusBadge from '../components/StatusBadge'
import { ProofConsole, type Proof } from '../components/ProofConsole'

const TRUST_ZONES = [
  { name: 'signalloom-eu', domain: 'eu.signalloom.svc.cluster.local', clusters: 2, servers: 2, status: 'active' },
  { name: 'signalloom-us', domain: 'us.signalloom.svc.cluster.local', clusters: 1, servers: 1, status: 'active' },
  { name: 'partner-acme', domain: 'acme.partner.example', clusters: 1, servers: 1, status: 'active' },
]

const FEDERATIONS = [
  { left: 'signalloom-eu', right: 'signalloom-us', mode: 'bidirectional', policy: 'ap-payments', status: 'federated' },
  { left: 'signalloom-eu', right: 'partner-acme', mode: 'one-way (eu → acme)', policy: 'ap-partner-read', status: 'federated' },
  { left: 'signalloom-us', right: 'partner-acme', mode: 'pending bundle exchange', policy: 'ap-partner-read', status: 'connecting' },
]

const FEDERATED_SERVICES = [
  { service: 'payments-api', home: 'signalloom-eu', consumer: 'signalloom-us', endpoint: 'payments.local:8443', transport: 'xDS (Envoy)', status: 'active' },
  { service: 'ledger-grpc', home: 'signalloom-eu', consumer: 'signalloom-us', endpoint: 'ledger.local:9443', transport: 'Cofide Go SDK', status: 'active' },
  { service: 'kyc-lookup', home: 'partner-acme', consumer: 'signalloom-eu', endpoint: 'kyc.local:8443', transport: 'xDS (Envoy)', status: 'active' },
  { service: 'settlement-feed', home: 'signalloom-us', consumer: 'partner-acme', endpoint: 'settle.local:8443', transport: 'Cofide Go SDK', status: 'connecting' },
]

const POLICIES = [
  { name: 'ap-payments', selector: 'k8s:ns:payments, k8s:sa:api', zones: 'eu, us' },
  { name: 'ap-partner-read', selector: 'k8s:ns:partner, k8s:label:federate=true', zones: 'eu, acme' },
  { name: 'ap-node-tpm', selector: 'tpm:ek_sha256:9f3c…', zones: 'eu, us' },
]

const SPIFFE_IDS = [
  { uri: 'spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom', workload: 'dashboard', ns: 'fe-signalloom', sa: 'fe-signalloom', svid: 'X.509', expiry: '2026-08-02T18:00:00Z' },
  { uri: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent', workload: 'agent', ns: 'fe-signalloom-agents', sa: 'cardvault-agent', svid: 'JWT', expiry: '2026-08-02T14:30:00Z' },
  { uri: 'spiffe://signalloom.demo/ns/payments/sa/payments-api', workload: 'service', ns: 'payments', sa: 'payments-api', svid: 'X.509', expiry: '2026-08-03T06:00:00Z' },
  { uri: 'spiffe://signalloom.demo/ns/payments/sa/ledger-grpc', workload: 'service', ns: 'payments', sa: 'ledger-grpc', svid: 'X.509', expiry: '2026-08-03T06:00:00Z' },
  { uri: 'spiffe://acme.partner.example/ns/kyc/sa/kyc-lookup', workload: 'service', ns: 'kyc', sa: 'kyc-lookup', svid: 'X.509', expiry: '2026-08-02T22:00:00Z' },
]

const FEDERATION_EVENTS = [
  { ts: '2026-08-02T09:14:22Z', zone: 'signalloom-eu', event: 'Bundle refreshed', detail: 'Trust bundle rotated (SHA-256: 9f3c…a1b2)', severity: 'info' },
  { ts: '2026-08-02T09:12:05Z', zone: 'signalloom-us', event: 'Federation established', detail: 'Bidirectional bundle exchange with signalloom-eu complete', severity: 'info' },
  { ts: '2026-08-02T08:58:33Z', zone: 'partner-acme', event: 'Bundle exchange pending', detail: 'Awaiting signalloom-us bundle acceptance', severity: 'pending' },
  { ts: '2026-08-02T08:45:01Z', zone: 'signalloom-eu', event: 'SVID issued', detail: 'payments-api X.509 SVID renewed (TTL 24h)', severity: 'info' },
  { ts: '2026-08-02T08:30:00Z', zone: 'signalloom-eu', event: 'Attestation passed', detail: 'cardvault-agent k8s workload attestation (SA match)', severity: 'info' },
]

const SDK_SNIPPET = `import "github.com/cofide/cofide-sdk-go/cofide"

// No static secrets: the SDK fetches this workload's SVID from the
// Cofide Agent and dials the federated service in a remote trust zone
// over mutual-TLS, with identity established by SPIFFE attestation.
client, _ := cofide.NewClient(ctx)
conn, _ := client.DialFederated(ctx, "payments-api") // resolves via federation
resp, _ := payments.NewPaymentsClient(conn).Charge(ctx, req)`

/**
 * What produced this page — which is nothing, and it has to say so.
 *
 * Every other superadmin surface that makes a claim about the platform can be
 * opened up to the request behind it. This page makes the strongest claims of
 * the three (three trust zones federated, four services flowing across them,
 * bundle exchanges completing) and has no data path at all: the arrays are
 * literals in this file. Without this disclosure a reader has no way to tell it
 * apart from Credential Inventory's live view, which looks the same.
 */
const FIXTURE_PROOFS: Proof[] = [
  {
    label: 'Data source',
    command: "rg -n 'const (TRUST_ZONES|FEDERATIONS|FEDERATED_SERVICES) =' "
      + 'd2-signalloom/apps/dashboard-signalloom/src/pages/FederatedServicesPage.tsx',
    detail: 'Every table on this page reads from an array literal declared in the page file. '
      + 'The component issues no fetch, holds no auth token and has no API client imported — '
      + 'it renders identically with the cluster switched off.\n\n'
      + 'So: zero of the figures above were measured. The trust domains, SVID expiries and '
      + 'bundle-exchange states are illustrative, chosen to show the shape of a federated '
      + 'deployment.',
  },
  {
    label: 'What would make it real',
    command: 'kubectl get clusterfederatedtrustdomain -A '
      + '&& spire-server bundle list -format spiffe',
    detail: 'NOT RUN. This is the pair of commands that would answer the question this page '
      + 'illustrates — which trust domains are federated, and which bundles have actually been '
      + 'exchanged. Neither has an endpoint behind this dashboard today.\n\n'
      + 'Recorded here so the gap is a named piece of work rather than an unstated assumption.',
  },
]

export default function FederatedServicesPage() {
  const activeFed = FEDERATED_SERVICES.filter((s) => s.status === 'active').length
  const [proofOpen, setProofOpen] = useState(false)

  return (
    <div style={{ paddingBottom: 40 }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>Federated Services</h1>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 16, maxWidth: 760 }}>
        Secretless, cross-trust-zone connectivity inspired by{' '}
        <a href="https://docs.cofide.dev/concepts/" style={{ color: 'var(--cyan)' }}>Cofide Connect</a> — workloads in
        isolated SPIFFE trust zones securely discover and reach each other over the Cofide Agent (xDS / Go SDK), with
        no long-lived credentials.
      </p>

      {/* Same banner shape and the same console as Credential Inventory, so a
          reader who has learned one disclosure has learned both. */}
      <div
        data-testid="federated-source"
        className="card"
        style={{
          padding: '12px 16px', marginBottom: 22, fontSize: 13,
          borderLeft: '3px solid var(--amber)', lineHeight: 1.6,
        }}
      >
        <strong style={{ color: 'var(--amber)' }}>Illustrative</strong>
        <span style={{ color: 'var(--muted)' }}>
          {' '}— no trust zone, federation or SVID below was observed. This page is a fixture that
          shows what the fabric would look like; nothing on it is a measurement of this platform.
        </span>
        <br />
        <button
          type="button"
          className="btn btn-secondary"
          data-testid="federated-disclose-proof"
          onClick={() => setProofOpen((v) => !v)}
          style={{ fontSize: 11, padding: '3px 10px', marginTop: 8 }}
        >
          {proofOpen ? 'Hide proof' : `How do we know? (${FIXTURE_PROOFS.length} checks)`}
        </button>
        {proofOpen && <ProofConsole proofs={FIXTURE_PROOFS} testId="federated-proof-console" />}
      </div>

      <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 28 }}>
        <StatCard label="Trust zones" value={String(TRUST_ZONES.length)} sub="isolated SPIFFE domains" accent="var(--cyan)" />
        <StatCard label="Federations" value={String(FEDERATIONS.length)} sub="cross-zone trust links" accent="var(--violet)" />
        <StatCard label="Federated services" value={`${activeFed}/${FEDERATED_SERVICES.length}`} sub="active cross-zone routes" accent="var(--teal)" />
        <StatCard label="Attestation policies" value={String(POLICIES.length)} sub="gate who may federate" accent="var(--amber)" />
      </div>

      <Section title="Trust Zones" hint="each a SPIFFE trust domain">
        <Table headers={['Zone', 'Trust domain', 'Clusters', 'SPIRE servers', 'Status']}>
          {TRUST_ZONES.map((z) => (
            <tr key={z.name} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...td, fontWeight: 500 }}>{z.name}</td>
              <td style={td}><code style={{ color: 'var(--cyan)', fontSize: 12 }}>{z.domain}</code></td>
              <td style={td}>{z.clusters}</td>
              <td style={td}>{z.servers}</td>
              <td style={td}><StatusBadge status={z.status} variant="federation" /></td>
            </tr>
          ))}
        </Table>
      </Section>

      <Section title="Federations" hint="trust relationships between zones">
        <Table
          headers={[
            'Trust zone A',
            'Trust zone B',
            {
              label: 'Mode',
              help: 'Which direction trust flows. Bidirectional means each zone accepts the other\'s identities; one-way means only the named direction does, so a workload in the trusting zone still cannot be reached from the trusted one.',
              testId: 'federation-mode-help',
            },
            {
              label: 'Attestation policy',
              help: 'The rule a workload must satisfy before its identity is accepted across the federation — namespace, service account, or a hardware measurement. Federating two zones does not admit everything in them; this is the filter.',
              testId: 'federation-policy-help',
            },
            'Status',
          ]}
        >
          {FEDERATIONS.map((f, i) => (
            <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...td, fontWeight: 500 }}>{f.left}</td>
              <td style={{ ...td, fontWeight: 500 }}>{f.right}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{f.mode}</td>
              <td style={td}><code style={{ color: 'var(--violet)', fontSize: 12 }}>{f.policy}</code></td>
              <td style={td}><StatusBadge status={f.status} variant="federation" /></td>
            </tr>
          ))}
        </Table>
      </Section>

      <Section title="Federated Services" hint="local endpoint → remote-zone workload">
        <Table headers={['Service', 'Home zone', 'Consumed from', 'Local endpoint', 'Transport', 'Status']}>
          {FEDERATED_SERVICES.map((s) => (
            <tr key={s.service} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...td, fontWeight: 500 }}>{s.service}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{s.home}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{s.consumer}</td>
              <td style={td}><code style={{ color: 'var(--cyan)', fontSize: 12 }}>{s.endpoint}</code></td>
              <td style={{ ...td, color: 'var(--muted)' }}>{s.transport}</td>
              <td style={td}><StatusBadge status={s.status} variant="federation" /></td>
            </tr>
          ))}
        </Table>
      </Section>

      <Section title="Attestation Policies" hint="who is allowed to federate">
        <Table headers={['Policy', 'Selector', 'Bound zones']}>
          {POLICIES.map((p) => (
            <tr key={p.name} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={td}><code style={{ color: 'var(--violet)', fontSize: 12 }}>{p.name}</code></td>
              <td style={{ ...td, color: 'var(--muted)' }}>{p.selector}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{p.zones}</td>
            </tr>
          ))}
        </Table>
      </Section>

      <Section title="SPIFFE Identities" hint="SVIDs issued by the trust fabric">
        <Table
          headers={[
            'SPIFFE ID',
            'Workload',
            'Namespace',
            'Service account',
            {
              label: 'SVID type',
              help: 'The form the identity document takes. X.509 is a certificate presented during the TLS handshake, so the identity is proven by the connection itself. JWT is a bearer token passed above it — usable where mutual TLS cannot reach, and, being a bearer token, replayable if it leaks.',
              testId: 'federation-svid-help',
            },
          ]}
        >
          {SPIFFE_IDS.map((s) => (
            <tr key={s.uri} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={td}><code style={{ color: 'var(--cyan)', fontSize: 11.5, wordBreak: 'break-all', whiteSpace: 'normal' }}>{s.uri}</code></td>
              <td style={td}><StatusBadge status={s.workload} /></td>
              <td style={{ ...td, color: 'var(--muted)' }}>{s.ns}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{s.sa}</td>
              <td style={td}><StatusBadge status={s.svid} /></td>
            </tr>
          ))}
        </Table>
      </Section>

      <Section title="Federation Events" hint="recent trust fabric activity">
        <Table headers={['Timestamp', 'Zone', 'Event', 'Detail']}>
          {FEDERATION_EVENTS.map((e, i) => (
            <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...td, fontFamily: 'monospace', fontSize: 11.5, color: 'var(--muted)' }}>{e.ts.replace('T', ' ').replace('Z', '')}</td>
              <td style={{ ...td, fontWeight: 500 }}>{e.zone}</td>
              <td style={{ ...td, fontWeight: 500 }}>{e.event}</td>
              <td style={{ ...td, color: 'var(--muted)', whiteSpace: 'normal' }}>{e.detail}</td>
            </tr>
          ))}
        </Table>
      </Section>

      <Section title="Cofide Go SDK" hint="github.com/cofide/cofide-sdk-go">
        <pre className="card" style={{ padding: 16, margin: 0, overflow: 'auto', fontSize: 12.5, lineHeight: 1.55, color: 'var(--text)' }}>
          <code>{SDK_SNIPPET}</code>
        </pre>
      </Section>
    </div>
  )
}
