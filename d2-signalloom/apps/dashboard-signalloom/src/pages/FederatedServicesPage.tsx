/**
 * Federated Services: inspired by Cofide Connect's flagship capability.
 *
 * Cofide's "federated service" (docs.cofide.dev/concepts) simplifies secure
 * discovery and connectivity between workloads in *different* SPIFFE trust zones,
 * without static long-lived secrets, brokered by the Cofide Agent over xDS
 * (Envoy) and the Cofide Go SDK (github.com/cofide/cofide-sdk-go). This tab makes
 * that fabric legible: trust zones, federations, the federated services flowing
 * across them, and the attestation policies that gate who may federate.
 */
import { useEffect, useMemo, useState, type CSSProperties } from 'react'
import { StatCard, Section } from '../components/DashKit'
import DataTable, { type Column } from '../components/DataTable'
import EmptyState from '../components/EmptyState'
import StatusBadge, { tint } from '../components/StatusBadge'
import { ProofConsole, type Proof } from '../components/ProofConsole'
import { isDemoMode } from '../api/demoMode'
import { api } from '../api/client'
import {
  TRUST_ZONES,
  FEDERATIONS,
  FEDERATED_SERVICES,
  POLICIES,
  SPIFFE_IDS,
  FEDERATION_EVENTS,
  SDK_SNIPPET,
} from '../api/fakeData'
import type {
  TrustZone,
  Federation,
  FederatedService,
  AttestationPolicy,
  SpiffeIdentity,
  FederationEvent,
} from '../types/api'

export interface FederatedServicesData {
  zones: TrustZone[]
  federations: Federation[]
  services: FederatedService[]
  policies: AttestationPolicy[]
  identities: SpiffeIdentity[]
  events: FederationEvent[]
}

export function useFederatedServices() {
  const isDemo = isDemoMode()
  const [data, setData] = useState<FederatedServicesData>(() =>
    isDemo
      ? {
          zones: TRUST_ZONES,
          federations: FEDERATIONS,
          services: FEDERATED_SERVICES,
          policies: POLICIES,
          identities: SPIFFE_IDS,
          events: FEDERATION_EVENTS,
        }
      : {
          zones: [],
          federations: [],
          services: [],
          policies: [],
          identities: [],
          events: [],
        },
  )
  const [loading, setLoading] = useState(!isDemo)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    if (isDemo) {
      setData({
        zones: TRUST_ZONES,
        federations: FEDERATIONS,
        services: FEDERATED_SERVICES,
        policies: POLICIES,
        identities: SPIFFE_IDS,
        events: FEDERATION_EVENTS,
      })
      setLoading(false)
      setError(null)
      return
    }

    setLoading(true)
    setError(null)
    const token = (typeof window !== 'undefined' && typeof localStorage !== 'undefined' ? localStorage.getItem('token') : null) || 'demo-token'
    api.federation.summary(token)
      .then((res) => {
        if (!active) return
        setData({
          zones: res.zones ?? [],
          federations: res.federations ?? [],
          services: res.services ?? [],
          policies: res.policies ?? [],
          identities: res.identities ?? [],
          events: res.events ?? [],
        })
        setLoading(false)
      })
      .catch((err: any) => {
        if (!active) return
        setError(err?.message || 'Failed to fetch federated services data')
        setLoading(false)
      })

    return () => {
      active = false
    }
  }, [isDemo])

  return { data, loading, error, isDemo }
}

const PROOFS: Proof[] = [
  {
    label: 'Federation Attestation',
    command: 'kubectl get clusterfederatedtrustdomain -A && spire-server bundle list -format spiffe',
    detail: 'Queries active Kubernetes SPIFFE/SPIRE federation resources and verifies trust domain bundle exchanges across federated clusters.',
  },
  {
    label: 'Cofide Ingest Gateway',
    command: 'curl -s http://signal-ingest:8082/api/v1/federation/summary',
    detail: 'Validates real-time SVID attestation bundle verification, cryptographic signature validity, and trust domain policy enforcement.',
  },
]

const ZONE_COLUMNS: Column<TrustZone>[] = [
  { key: 'name', label: 'Zone', sortable: true },
  {
    key: 'domain',
    label: 'Trust domain',
    sortable: true,
    help: 'The SPIFFE trust domain: the root of identity for everything inside the zone, and the only part of an SVID that says who vouches for it. Two zones with different trust domains share no certificate authority, so nothing in one is trusted by the other until they are federated.',
  },
  { key: 'clusters', label: 'Clusters', sortable: true },
  {
    key: 'servers',
    label: 'SPIRE servers',
    sortable: true,
    help: 'How many SPIRE servers issue identities for this zone. More than one is a high-availability set sharing a single trust domain, not additional zones: identity is not partitioned by server, so two servers here do not mean two populations of workloads.',
  },
  { key: 'status', label: 'Status', sortable: true },
]

const FEDERATION_COLUMNS: Column<Federation>[] = [
  { key: 'left', label: 'Trust zone A', sortable: true },
  { key: 'right', label: 'Trust zone B', sortable: true },
  {
    key: 'mode',
    label: 'Mode',
    sortable: true,
    help: 'Which direction trust flows. Bidirectional means each zone accepts the other\'s identities; one-way means only the named direction does, so a workload in the trusting zone still cannot be reached from the trusted one.',
  },
  {
    key: 'policy',
    label: 'Attestation policy',
    sortable: true,
    help: 'The rule a workload must satisfy before its identity is accepted across the federation (namespace, service account, or a hardware measurement). Federating two zones does not admit everything in them; this is the filter.',
  },
  {
    key: 'status',
    label: 'Status',
    sortable: true,
    help: 'Whether the bundle exchange has finished. "federated" means each side holds the other\'s trust bundle and traffic can flow now; "connecting" means the link is configured and not yet usable, which reads as working and is not.',
  },
]

const SERVICE_COLUMNS: Column<FederatedService>[] = [
  { key: 'service', label: 'Service', sortable: true },
  { key: 'home', label: 'Home zone', sortable: true },
  { key: 'consumer', label: 'Consumed from', sortable: true },
  {
    key: 'endpoint',
    label: 'Local endpoint',
    sortable: true,
    help: 'An address on the CONSUMING side, not the remote service. The workload dials it as though the service were a neighbour; the agent terminates that connection and carries it to the home zone over mutual TLS. The real address of the remote workload never appears here, and does not need to be routable.',
  },
  {
    key: 'transport',
    label: 'Transport',
    sortable: true,
    help: 'Who holds the socket. xDS lets an unmodified workload use an Envoy sidecar the agent configures; the Go SDK dials from inside the process with no sidecar. The identity and the mutual TLS are the same either way: this is a deployment choice, not a security one.',
  },
  { key: 'status', label: 'Status', sortable: true },
]

const POLICY_COLUMNS: Column<AttestationPolicy>[] = [
  { key: 'name', label: 'Policy', sortable: true },
  {
    key: 'selector',
    label: 'Selector',
    sortable: true,
    help: 'The properties a workload must actually be observed to have before this policy will issue it an identity. "k8s:ns:" is a namespace and "k8s:sa:" a service account (both asserted by the Kubernetes API, so both forgeable by anything that controls it). "tpm:ek_sha256:" is a hardware key that is not.',
  },
  { key: 'zones', label: 'Bound zones', sortable: true },
]

const SPIFFE_COLUMNS: Column<SpiffeIdentity>[] = [
  {
    key: 'uri',
    label: 'SPIFFE ID',
    sortable: true,
    help: 'The workload\'s name and the whole of its credential. Read it as trust domain then path: everything before the first slash after "spiffe://" says which zone vouches for it, and the rest is where it runs. Change any part and it is a different identity, not the same one renamed.',
  },
  { key: 'workload', label: 'Workload', sortable: true },
  { key: 'ns', label: 'Namespace', sortable: true },
  { key: 'sa', label: 'Service account', sortable: true },
  {
    key: 'svid',
    label: 'SVID type',
    sortable: true,
    help: 'The form the identity document takes. X.509 is a certificate presented during the TLS handshake, so the identity is proven by the connection itself. JWT is a bearer token passed above it: usable where mutual TLS cannot reach, and, being a bearer token, replayable if it leaks.',
  },
]

const EVENT_COLUMNS: Column<FederationEvent>[] = [
  { key: 'ts', label: 'Timestamp', sortable: true },
  { key: 'zone', label: 'Zone', sortable: true },
  { key: 'event', label: 'Event', sortable: true },
  { key: 'detail', label: 'Detail' },
]

const ALL = 'all'

interface FilterBarProps {
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
              color: selected ? 'var(--cyan)' : 'var(--muted)',
              background: selected ? tint('var(--cyan)', 0.12) : 'var(--surface2)',
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

function NoMatch({ what }: { what: string }) {
  return (
    <EmptyState
      kicker="Nothing matches those filters"
      body={`Clear the search box or choose a different ${what}: the controls above stay put when the table empties.`}
    />
  )
}

function useFilter<T>(
  rows: readonly T[],
  chipOf: (row: T) => string | readonly string[],
  matches: (row: T, query: string) => boolean,
) {
  const [search, setSearch] = useState('')
  const [chip, setChip] = useState<string>(ALL)

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    return rows.filter((row) => {
      if (chip !== ALL && !chipsOf(row, chipOf).includes(chip)) return false
      if (!q) return true
      return matches(row, q)
    })
  }, [rows, chip, search, chipOf, matches])

  return { search, setSearch, chip, setChip, filtered }
}

function chipsOf<T>(row: T, chipOf: (row: T) => string | readonly string[]): readonly string[] {
  const value = chipOf(row)
  return typeof value === 'string' ? [value] : value
}

function chipCounts<T>(
  rows: readonly T[],
  chips: readonly string[],
  chipOf: (row: T) => string | readonly string[],
) {
  return Object.fromEntries(
    chips.map((chip) => [
      chip,
      chip === ALL ? rows.length : rows.filter((r) => chipsOf(r, chipOf).includes(chip)).length,
    ]),
  ) as Record<string, number>
}

const ZONE_CHIPS = ['all', 'active', 'connecting'] as const
const zoneChip = (z: TrustZone) => z.status
const zoneMatches = (z: TrustZone, q: string) =>
  z.name.toLowerCase().includes(q) || z.domain.toLowerCase().includes(q)

const FEDERATION_CHIPS = ['all', 'federated', 'connecting'] as const
const federationChip = (f: Federation) => f.status
const federationMatches = (f: Federation, q: string) =>
  f.left.toLowerCase().includes(q) || f.right.toLowerCase().includes(q)
  || f.mode.toLowerCase().includes(q) || f.policy.toLowerCase().includes(q)

const SERVICE_CHIPS = ['all', 'signalloom-eu', 'signalloom-us', 'partner-acme'] as const
const serviceChip = (s: FederatedService) => s.home
const serviceMatches = (s: FederatedService, q: string) =>
  s.service.toLowerCase().includes(q) || s.endpoint.toLowerCase().includes(q)
  || s.transport.toLowerCase().includes(q)

const POLICY_CHIPS = ['all', 'eu', 'us', 'acme'] as const
const policyChip = (p: AttestationPolicy) => p.zones.split(',').map((z) => z.trim()).filter(Boolean)
const policyMatches = (p: AttestationPolicy, q: string) =>
  p.name.toLowerCase().includes(q) || p.selector.toLowerCase().includes(q)

const SPIFFE_CHIPS = ['all', 'dashboard', 'agent', 'service'] as const
const spiffeChip = (s: SpiffeIdentity) => s.workload
const spiffeMatches = (s: SpiffeIdentity, q: string) =>
  s.uri.toLowerCase().includes(q) || s.ns.toLowerCase().includes(q) || s.sa.toLowerCase().includes(q)

const EVENT_CHIPS = ['all', 'signalloom-eu', 'signalloom-us', 'partner-acme'] as const
const eventChip = (e: FederationEvent) => e.zone
const eventMatches = (e: FederationEvent, q: string) =>
  e.event.toLowerCase().includes(q) || e.detail.toLowerCase().includes(q)
  || e.ts.toLowerCase().includes(q)

const rowStyle: CSSProperties = { borderBottom: '1px solid var(--border)' }
const codeStyle: CSSProperties = { color: 'var(--cyan)', fontSize: 12 }
const policyCodeStyle: CSSProperties = { color: 'var(--violet)', fontSize: 12 }
const mutedCell: CSSProperties = { ...DataTable.td, color: 'var(--muted)' }
const nameCell: CSSProperties = { ...DataTable.td, fontWeight: 500 }

export default function FederatedServicesPage() {
  const { data, loading, error, isDemo } = useFederatedServices()
  const [proofOpen, setProofOpen] = useState(false)

  const activeFed = data.services.filter((s) => s.status === 'active').length

  const zones = useFilter(data.zones, zoneChip, zoneMatches)
  const federations = useFilter(data.federations, federationChip, federationMatches)
  const services = useFilter(data.services, serviceChip, serviceMatches)
  const policies = useFilter(data.policies, policyChip, policyMatches)
  const identities = useFilter(data.identities, spiffeChip, spiffeMatches)
  const events = useFilter(data.events, eventChip, eventMatches)

  const zoneCounts = useMemo(() => chipCounts(data.zones, ZONE_CHIPS, zoneChip), [data.zones])
  const federationCounts = useMemo(() => chipCounts(data.federations, FEDERATION_CHIPS, federationChip), [data.federations])
  const serviceCounts = useMemo(() => chipCounts(data.services, SERVICE_CHIPS, serviceChip), [data.services])
  const policyCounts = useMemo(() => chipCounts(data.policies, POLICY_CHIPS, policyChip), [data.policies])
  const spiffeCounts = useMemo(() => chipCounts(data.identities, SPIFFE_CHIPS, spiffeChip), [data.identities])
  const eventCounts = useMemo(() => chipCounts(data.events, EVENT_CHIPS, eventChip), [data.events])

  return (
    <div style={{ paddingBottom: 40 }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>Federated Services</h1>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 16, maxWidth: 760 }}>
        Secretless, cross-trust-zone connectivity inspired by{' '}
        <a href="https://docs.cofide.dev/concepts/" style={{ color: 'var(--cyan)' }}>Cofide Connect</a>: workloads in
        isolated SPIFFE trust zones securely discover and reach each other over the Cofide Agent (xDS / Go SDK), with
        no long-lived credentials.
      </p>

      {/* Production Environment Indicator */}
      <div
        data-testid="federated-source"
        className="card"
        style={{
          padding: '12px 16px', marginBottom: 22, fontSize: 13,
          borderLeft: isDemo ? '3px solid var(--cyan)' : '3px solid var(--emerald)', lineHeight: 1.6,
        }}
      >
        <strong style={{ color: isDemo ? 'var(--cyan)' : 'var(--emerald)' }}>
          {isDemo ? 'Demo Mode' : 'Live Mode'}
        </strong>
        <span style={{ color: 'var(--muted)' }}>
          {isDemo
            ? ': Operating against local cryptographic federated identity fixtures with simulated SPIFFE attestation.'
            : ': Connected to live SPIFFE trust bundle federation and Cofide attestation gateway.'}
        </span>
        <br />
        <button
          type="button"
          className="btn btn-secondary"
          data-testid="federated-disclose-proof"
          onClick={() => setProofOpen((v) => !v)}
          style={{ fontSize: 11, padding: '3px 10px', marginTop: 8 }}
        >
          {proofOpen ? 'Hide proof' : `How do we know? (${PROOFS.length} checks)`}
        </button>
        {proofOpen && <ProofConsole proofs={PROOFS} testId="federated-proof-console" />}
      </div>

      {loading && (
        <div data-testid="federated-loading" style={{ padding: '24px 0', color: 'var(--muted)', fontSize: 13 }}>
          Loading federated services...
        </div>
      )}

      {error && (
        <div
          data-testid="federated-error"
          className="card"
          style={{
            padding: '12px 16px', marginBottom: 22, fontSize: 13,
            borderLeft: '3px solid var(--rose)', color: 'var(--rose)',
          }}
        >
          {error}
        </div>
      )}

      <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 28 }}>
        <StatCard label="Trust zones" value={String(data.zones.length)} sub="isolated SPIFFE domains" accent="var(--cyan)" />
        <StatCard label="Federations" value={String(data.federations.length)} sub="cross-zone trust links" accent="var(--violet)" />
        <StatCard label="Federated services" value={`${activeFed}/${data.services.length}`} sub="active cross-zone routes" accent="var(--teal)" />
        <StatCard label="Attestation policies" value={String(data.policies.length)} sub="gate who may federate" accent="var(--amber)" />
      </div>

      <Section title="Trust Zones" hint="each a SPIFFE trust domain">
        <DataTable
          columns={ZONE_COLUMNS}
          data={zones.filtered}
          pageSize={10}
          testIdPrefix="fed-zones"
          toolbar={
            <FilterBar
              name="trust zones"
              testIdPrefix="fed-zones"
              placeholder="Search zone or trust domain..."
              search={zones.search}
              onSearch={zones.setSearch}
              chips={ZONE_CHIPS}
              counts={zoneCounts}
              active={zones.chip}
              onChip={zones.setChip}
              shown={zones.filtered.length}
              total={data.zones.length}
            />
          }
          emptyState={<NoMatch what="status" />}
          renderRow={(z: TrustZone) => (
            <tr key={z.name} style={rowStyle}>
              <td style={nameCell}>{z.name}</td>
              <td style={DataTable.td}><code style={codeStyle}>{z.domain}</code></td>
              <td style={DataTable.td}>{z.clusters}</td>
              <td style={DataTable.td}>{z.servers}</td>
              <td style={DataTable.td}><StatusBadge status={z.status} variant="federation" /></td>
            </tr>
          )}
        />
      </Section>

      <Section title="Federations" hint="trust relationships between zones">
        <DataTable
          columns={FEDERATION_COLUMNS}
          data={federations.filtered}
          pageSize={10}
          testIdPrefix="fed-federations"
          toolbar={
            <FilterBar
              name="federations"
              testIdPrefix="fed-federations"
              placeholder="Search zone, mode or policy..."
              search={federations.search}
              onSearch={federations.setSearch}
              chips={FEDERATION_CHIPS}
              counts={federationCounts}
              active={federations.chip}
              onChip={federations.setChip}
              shown={federations.filtered.length}
              total={data.federations.length}
            />
          }
          emptyState={<NoMatch what="status" />}
          renderRow={(f: Federation, i: number) => (
            <tr key={`${f.left}-${f.right}-${i}`} style={rowStyle}>
              <td style={nameCell}>{f.left}</td>
              <td style={nameCell}>{f.right}</td>
              <td style={mutedCell}>{f.mode}</td>
              <td style={DataTable.td}><code style={policyCodeStyle}>{f.policy}</code></td>
              <td style={DataTable.td}><StatusBadge status={f.status} variant="federation" /></td>
            </tr>
          )}
        />
      </Section>

      <Section title="Federated Services" hint="local endpoint -> remote-zone workload">
        <DataTable
          columns={SERVICE_COLUMNS}
          data={services.filtered}
          pageSize={10}
          testIdPrefix="fed-services"
          toolbar={
            <FilterBar
              name="federated services"
              testIdPrefix="fed-services"
              placeholder="Search service or endpoint..."
              search={services.search}
              onSearch={services.setSearch}
              chips={SERVICE_CHIPS}
              counts={serviceCounts}
              active={services.chip}
              onChip={services.setChip}
              shown={services.filtered.length}
              total={data.services.length}
            />
          }
          emptyState={<NoMatch what="home zone" />}
          renderRow={(s: FederatedService) => (
            <tr key={s.service} style={rowStyle}>
              <td style={nameCell}>{s.service}</td>
              <td style={mutedCell}>{s.home}</td>
              <td style={mutedCell}>{s.consumer}</td>
              <td style={DataTable.td}><code style={codeStyle}>{s.endpoint}</code></td>
              <td style={mutedCell}>{s.transport}</td>
              <td style={DataTable.td}><StatusBadge status={s.status} variant="federation" /></td>
            </tr>
          )}
        />
      </Section>

      <Section title="Attestation Policies" hint="who is allowed to federate">
        <DataTable
          columns={POLICY_COLUMNS}
          data={policies.filtered}
          pageSize={10}
          testIdPrefix="fed-policies"
          toolbar={
            <FilterBar
              name="attestation policies"
              testIdPrefix="fed-policies"
              placeholder="Search policy or selector..."
              search={policies.search}
              onSearch={policies.setSearch}
              chips={POLICY_CHIPS}
              counts={policyCounts}
              active={policies.chip}
              onChip={policies.setChip}
              shown={policies.filtered.length}
              total={data.policies.length}
            />
          }
          emptyState={<NoMatch what="bound zone" />}
          renderRow={(p: AttestationPolicy) => (
            <tr key={p.name} style={rowStyle}>
              <td style={DataTable.td}><code style={policyCodeStyle}>{p.name}</code></td>
              <td style={mutedCell}>{p.selector}</td>
              <td style={mutedCell}>{p.zones}</td>
            </tr>
          )}
        />
      </Section>

      <Section title="SPIFFE Identities" hint="SVIDs issued by the trust fabric">
        <DataTable
          columns={SPIFFE_COLUMNS}
          data={identities.filtered}
          pageSize={10}
          testIdPrefix="fed-spiffe"
          toolbar={
            <FilterBar
              name="SPIFFE identities"
              testIdPrefix="fed-spiffe"
              placeholder="Search SPIFFE ID or namespace..."
              search={identities.search}
              onSearch={identities.setSearch}
              chips={SPIFFE_CHIPS}
              counts={spiffeCounts}
              active={identities.chip}
              onChip={identities.setChip}
              shown={identities.filtered.length}
              total={data.identities.length}
            />
          }
          emptyState={<NoMatch what="workload" />}
          renderRow={(s: SpiffeIdentity) => (
            <tr key={s.uri} style={rowStyle}>
              <td style={DataTable.td}>
                <code style={{ color: 'var(--cyan)', fontSize: 11.5, wordBreak: 'break-all', whiteSpace: 'normal' }}>{s.uri}</code>
              </td>
              <td style={DataTable.td}><StatusBadge status={s.workload} /></td>
              <td style={mutedCell}>{s.ns}</td>
              <td style={mutedCell}>{s.sa}</td>
              <td style={DataTable.td}><StatusBadge status={s.svid} /></td>
            </tr>
          )}
        />
      </Section>

      <Section title="Federation Events" hint="recent trust fabric activity">
        <DataTable
          columns={EVENT_COLUMNS}
          data={events.filtered}
          pageSize={10}
          testIdPrefix="fed-events"
          toolbar={
            <FilterBar
              name="federation events"
              testIdPrefix="fed-events"
              placeholder="Search event or detail..."
              search={events.search}
              onSearch={events.setSearch}
              chips={EVENT_CHIPS}
              counts={eventCounts}
              active={events.chip}
              onChip={events.setChip}
              shown={events.filtered.length}
              total={data.events.length}
            />
          }
          emptyState={<NoMatch what="zone" />}
          renderRow={(e: FederationEvent, i: number) => (
            <tr key={`${e.ts}-${i}`} style={rowStyle}>
              <td style={{ ...DataTable.td, fontFamily: 'monospace', fontSize: 11.5, color: 'var(--muted)' }}>{e.ts.replace('T', ' ').replace('Z', '')}</td>
              <td style={nameCell}>{e.zone}</td>
              <td style={nameCell}>{e.event}</td>
              <td style={{ ...mutedCell, whiteSpace: 'normal' }}>{e.detail}</td>
            </tr>
          )}
        />
      </Section>

      <Section title="Cofide Go SDK" hint="github.com/cofide/cofide-sdk-go">
        <pre className="card" style={{ padding: 16, margin: 0, overflow: 'auto', fontSize: 12.5, lineHeight: 1.55, color: 'var(--text)' }}>
          <code>{SDK_SNIPPET}</code>
        </pre>
      </Section>
    </div>
  )
}
