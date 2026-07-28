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
 * Self-contained mock data — renders without any API/auth dependency.
 */
import { StatCard, Section, Table, Pill, td } from '../components/DashKit'

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

const SDK_SNIPPET = `import "github.com/cofide/cofide-sdk-go/cofide"

// No static secrets: the SDK fetches this workload's SVID from the
// Cofide Agent and dials the federated service in a remote trust zone
// over mutual-TLS, with identity established by SPIFFE attestation.
client, _ := cofide.NewClient(ctx)
conn, _ := client.DialFederated(ctx, "payments-api") // resolves via federation
resp, _ := payments.NewPaymentsClient(conn).Charge(ctx, req)`

export default function FederatedServicesPage() {
  const activeFed = FEDERATED_SERVICES.filter((s) => s.status === 'active').length
  return (
    <div style={{ paddingBottom: 40 }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>Federated Services</h1>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 22, maxWidth: 760 }}>
        Secretless, cross-trust-zone connectivity inspired by{' '}
        <a href="https://docs.cofide.dev/concepts/" style={{ color: 'var(--cyan)' }}>Cofide Connect</a> — workloads in
        isolated SPIFFE trust zones securely discover and reach each other over the Cofide Agent (xDS / Go SDK), with
        no long-lived credentials.
      </p>

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
              <td style={td}><Pill label={z.status} /></td>
            </tr>
          ))}
        </Table>
      </Section>

      <Section title="Federations" hint="trust relationships between zones">
        <Table headers={['Trust zone A', 'Trust zone B', 'Mode', 'Attestation policy', 'Status']}>
          {FEDERATIONS.map((f, i) => (
            <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...td, fontWeight: 500 }}>{f.left}</td>
              <td style={{ ...td, fontWeight: 500 }}>{f.right}</td>
              <td style={{ ...td, color: 'var(--muted)' }}>{f.mode}</td>
              <td style={td}><code style={{ color: 'var(--violet)', fontSize: 12 }}>{f.policy}</code></td>
              <td style={td}><Pill label={f.status} /></td>
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
              <td style={td}><Pill label={s.status} /></td>
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

      <Section title="Cofide Go SDK" hint="github.com/cofide/cofide-sdk-go">
        <pre className="card" style={{ padding: 16, margin: 0, overflow: 'auto', fontSize: 12.5, lineHeight: 1.55, color: 'var(--text)' }}>
          <code>{SDK_SNIPPET}</code>
        </pre>
      </Section>
    </div>
  )
}
