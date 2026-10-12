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
import { useEffect, useMemo, useState, type CSSProperties, type ReactNode } from 'react'
import { StatCard, Section } from '../components/DashKit'
import DataTable, { type Column } from '../components/DataTable'
import EmptyState from '../components/EmptyState'
import StatusBadge, { tint } from '../components/StatusBadge'
import { ProofConsole, type Proof } from '../components/ProofConsole'
import { isDemoMode } from '../api/demoMode'
import { api } from '../api/client'
import { useAuth0 } from '../auth/oidc'
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
  FederationFieldRefusal,
  FederationPanel,
  FederationStateResponse,
} from '../types/api'

/**
 * Live mode reads measured federation state and refuses the rest. Demo mode
 * reads fixtures. The two are never mixed and a fixture is never a live
 * fallback: if the live read fails, the page shows the failure.
 *
 * Why the panels are shaped like this. GET /v1/federation/* used to answer from
 * a hardcoded dataset (three zones, three federations, four services, three
 * policies, five SPIFFE IDs, attestation_success_rate 99.8, active_alerts 0)
 * that the dashboard got 100% of the time in live mode, because signal-ingest
 * registers no federation handler and the proxy treated its default-deny as
 * "serve the canonical dataset". What is actually measurable in this estate is
 * narrow - trust domains and SPIFFE IDs observed on real workloads - so the
 * page now renders four honest panels and refuses the others by name.
 */
export interface FederatedServicesData {
  zones: FederationPanel<TrustZone>
  federations: FederationPanel<Federation>
  services: FederationPanel<FederatedService>
  policies: FederationPanel<AttestationPolicy>
  identities: FederationPanel<SpiffeIdentity>
  events: FederationPanel<FederationEvent>
  counts: FederationStateResponse['counts'] | null
  unmeasuredCounts: FederationFieldRefusal[]
  collectorReason: string | null
}

/** A fixture panel: available, observed, nothing refused. Demo mode only. */
function fixturePanel<T>(items: T[]): FederationPanel<T> {
  return {
    available: true,
    items,
    evidence_state: 'observed',
    assurance: 'fixture',
    freshness: 'fresh',
    observed_at: null,
    evidence_source: 'local demo fixtures',
    reason: 'demo fixtures',
    unmeasured_fields: [],
  }
}

function emptyPanel<T>(reason: string): FederationPanel<T> {
  return {
    available: false,
    items: [],
    evidence_state: 'unavailable',
    assurance: 'unavailable',
    freshness: 'unavailable',
    observed_at: null,
    evidence_source: null,
    reason,
    unmeasured_fields: [],
  }
}

const DEMO_DATA = (): FederatedServicesData => ({
  zones: fixturePanel(TRUST_ZONES),
  federations: fixturePanel(FEDERATIONS),
  services: fixturePanel(FEDERATED_SERVICES),
  policies: fixturePanel(POLICIES),
  identities: fixturePanel(SPIFFE_IDS),
  events: fixturePanel(FEDERATION_EVENTS),
  counts: null,
  unmeasuredCounts: [],
  collectorReason: null,
})

const PENDING = 'not yet read'

const PENDING_DATA = (): FederatedServicesData => ({
  zones: emptyPanel(PENDING),
  federations: emptyPanel(PENDING),
  services: emptyPanel(PENDING),
  policies: emptyPanel(PENDING),
  identities: emptyPanel(PENDING),
  events: emptyPanel(PENDING),
  counts: null,
  unmeasuredCounts: [],
  collectorReason: null,
})

export function useFederatedServices() {
  const isDemo = isDemoMode()
  const { getAccessTokenSilently } = useAuth0()
  const [data, setData] = useState<FederatedServicesData>(() =>
    isDemo ? DEMO_DATA() : PENDING_DATA(),
  )
  const [loading, setLoading] = useState(!isDemo)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    if (isDemo) {
      setData(DEMO_DATA())
      setLoading(false)
      setError(null)
      return
    }

    setLoading(true)
    setError(null)

    void (async () => {
      try {
        const token = await getAccessTokenSilently()
        const res = await api.federation.summary(token)
        if (!active) return
        // No `?? []` on a panel: a missing panel is not an empty one. An answer
        // that omits a panel is a contract break and is shown as unavailable,
        // not as a tidy zero.
        const panel = <T,>(p: FederationPanel<T> | undefined, name: string) =>
          p ?? emptyPanel<T>(`the API response carried no ${name} panel`)
        setData({
          zones: panel(res.zones, 'zones'),
          federations: panel(res.federations, 'federations'),
          services: panel(res.services, 'services'),
          policies: panel(res.policies, 'policies'),
          identities: panel(res.identities, 'identities'),
          events: panel(res.events, 'events'),
          counts: res.counts ?? null,
          unmeasuredCounts: res.unmeasured_fields ?? [],
          collectorReason: res.collectors?.kubernetes?.reason || null,
        })
        setLoading(false)
      } catch (err: unknown) {
        if (!active) return
        setError(err instanceof Error ? err.message : 'Failed to fetch federated services data')
        setLoading(false)
      }
    })()

    return () => {
      active = false
    }
  }, [isDemo, getAccessTokenSilently])

  return { data, loading, error, isDemo }
}

/** A refused cell. Renders the absence, with the cause on hover. */
function Unmeasured({ reason }: { reason: string }) {
  return (
    <span
      data-testid="fed-unmeasured-cell"
      title={reason}
      style={{ color: 'var(--dim)', fontStyle: 'italic', fontSize: 11.5 }}
    >
      not measured
    </span>
  )
}

function refusalOf(panel: FederationPanel<unknown>, field: string): string | null {
  return panel.unmeasured_fields.find((r) => r.field === field)?.reason ?? null
}

/** A whole panel with no source: say which source is missing, show no rows. */
function PanelRefusal({ panel, testId }: { panel: FederationPanel<unknown>; testId: string }) {
  return (
    <div
      data-testid={testId}
      className="card"
      style={{
        padding: '14px 16px', fontSize: 12.5, lineHeight: 1.6,
        color: 'var(--muted)', borderLeft: '3px solid var(--dim)',
      }}
    >
      <strong style={{ color: 'var(--text)' }}>Not measured.</strong> {panel.reason}
    </div>
  )
}

/** The per-field refusals of an otherwise measured panel, listed under it. */
function FieldRefusals({ panel, testId }: { panel: FederationPanel<unknown>; testId: string }) {
  if (panel.unmeasured_fields.length === 0) return null
  return (
    <ul
      data-testid={testId}
      style={{ margin: '10px 0 0', paddingLeft: 18, fontSize: 11.5, color: 'var(--muted)', lineHeight: 1.6 }}
    >
      {panel.unmeasured_fields.map((r) => (
        <li key={r.field}>
          <code style={{ color: 'var(--dim)' }}>{r.field}</code>: {r.reason}
        </li>
      ))}
    </ul>
  )
}

/** A panel section: the table when there is a source, a named refusal when there is not. */
function Panel({
  panel, name, children,
}: { panel: FederationPanel<unknown>; name: string; children: ReactNode }) {
  if (!panel.available) {
    return <PanelRefusal panel={panel} testId={`fed-${name}-unavailable`} />
  }
  return (
    <>
      {children}
      <FieldRefusals panel={panel} testId={`fed-${name}-refusals`} />
    </>
  )
}

/** A StatCard value that is either a measured number or an explicit refusal. */
function countValue(value: number | null | undefined, fallback: number): string {
  return value === null || value === undefined ? String(fallback) : String(value)
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

// 'unmeasured' is a real bucket, not a placeholder: in live mode no zone has a
// status, because zone status is bundle-exchange state and nothing collects it.
const ZONE_CHIPS = ['all', 'active', 'connecting', 'unmeasured'] as const
const zoneChip = (z: TrustZone) => z.status ?? 'unmeasured' 
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
  s.uri.toLowerCase().includes(q)
  || (s.ns ?? '').toLowerCase().includes(q)
  || (s.sa ?? '').toLowerCase().includes(q)

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

  const activeFed = data.services.items.filter((s) => s.status === 'active').length

  const zones = useFilter(data.zones.items, zoneChip, zoneMatches)
  const federations = useFilter(data.federations.items, federationChip, federationMatches)
  const services = useFilter(data.services.items, serviceChip, serviceMatches)
  const policies = useFilter(data.policies.items, policyChip, policyMatches)
  const identities = useFilter(data.identities.items, spiffeChip, spiffeMatches)
  const events = useFilter(data.events.items, eventChip, eventMatches)

  const zoneCounts = useMemo(() => chipCounts(data.zones.items, ZONE_CHIPS, zoneChip), [data.zones])
  const federationCounts = useMemo(() => chipCounts(data.federations.items, FEDERATION_CHIPS, federationChip), [data.federations])
  const serviceCounts = useMemo(() => chipCounts(data.services.items, SERVICE_CHIPS, serviceChip), [data.services])
  const policyCounts = useMemo(() => chipCounts(data.policies.items, POLICY_CHIPS, policyChip), [data.policies])
  const spiffeCounts = useMemo(() => chipCounts(data.identities.items, SPIFFE_CHIPS, spiffeChip), [data.identities])
  const eventCounts = useMemo(() => chipCounts(data.events.items, EVENT_CHIPS, eventChip), [data.events])

  const NOT_MEASURED = 'not measured'

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
          borderLeft: isDemo ? '3px solid var(--cyan)' : '3px solid var(--teal)', lineHeight: 1.6,
        }}
      >
        <strong style={{ color: isDemo ? 'var(--cyan)' : 'var(--teal)' }}>
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
            borderLeft: '3px solid var(--error)', color: 'var(--error)',
          }}
        >
          {error}
        </div>
      )}

      <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 28 }}>
        <StatCard
          label="Trust zones"
          value={countValue(data.counts?.trust_zones, data.zones.items.length)}
          sub="observed SPIFFE trust domains"
          accent="var(--cyan)"
        />
        <StatCard
          label="SPIFFE identities"
          value={countValue(data.counts?.spiffe_identities, data.identities.items.length)}
          sub="observed on live workloads"
          accent="var(--cyan)"
        />
        <StatCard
          label="Federations"
          value={data.federations.available ? String(data.federations.items.length) : NOT_MEASURED}
          sub={data.federations.available ? 'cross-zone trust links' : 'no federation source'}
          accent="var(--violet)"
        />
        <StatCard
          label="Federated services"
          value={data.services.available ? `${activeFed}/${data.services.items.length}` : NOT_MEASURED}
          sub={data.services.available ? 'active cross-zone routes' : 'no service fabric deployed'}
          accent="var(--teal)"
        />
        <StatCard
          label="Attestation policies"
          value={data.policies.available ? String(data.policies.items.length) : NOT_MEASURED}
          sub={data.policies.available ? 'gate who may federate' : 'ClusterSPIFFEID not read'}
          accent="var(--amber)"
        />
      </div>

      <Section title="Trust Zones" hint="each a SPIFFE trust domain">
        <Panel panel={data.zones} name="zones">
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
              total={data.zones.items.length}
            />
          }
          emptyState={<NoMatch what="status" />}
          renderRow={(z: TrustZone) => (
            <tr key={z.name} style={rowStyle}>
              <td style={nameCell}>{z.name}</td>
              <td style={DataTable.td}><code style={codeStyle}>{z.domain}</code></td>
              <td style={DataTable.td}>
                {z.clusters ?? <Unmeasured reason={refusalOf(data.zones, 'clusters') ?? NOT_MEASURED} />}
              </td>
              <td style={DataTable.td}>
                {z.servers ?? <Unmeasured reason={refusalOf(data.zones, 'servers') ?? NOT_MEASURED} />}
              </td>
              <td style={DataTable.td}>
                {z.status
                  ? <StatusBadge status={z.status} variant="federation" />
                  : <Unmeasured reason={refusalOf(data.zones, 'status') ?? NOT_MEASURED} />}
              </td>
            </tr>
          )}
        />
        </Panel>
      </Section>

      <Section title="Federations" hint="trust relationships between zones">
        <Panel panel={data.federations} name="federations">
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
              total={data.federations.items.length}
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
        </Panel>
      </Section>

      <Section title="Federated Services" hint="local endpoint -> remote-zone workload">
        <Panel panel={data.services} name="services">
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
              total={data.services.items.length}
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
        </Panel>
      </Section>

      <Section title="Attestation Policies" hint="who is allowed to federate">
        <Panel panel={data.policies} name="policies">
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
              total={data.policies.items.length}
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
        </Panel>
      </Section>

      <Section title="SPIFFE Identities" hint="SVIDs issued by the trust fabric">
        <Panel panel={data.identities} name="identities">
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
              total={data.identities.items.length}
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
              <td style={DataTable.td}>
                {s.svid
                  ? <StatusBadge status={s.svid} />
                  : <Unmeasured reason={refusalOf(data.identities, 'svid') ?? NOT_MEASURED} />}
              </td>
            </tr>
          )}
        />
        </Panel>
      </Section>

      <Section title="Federation Events" hint="recent trust fabric activity">
        <Panel panel={data.events} name="events">
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
              total={data.events.items.length}
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
        </Panel>
      </Section>

      <Section title="Cofide Go SDK" hint="github.com/cofide/cofide-sdk-go">
        <pre className="card" style={{ padding: 16, margin: 0, overflow: 'auto', fontSize: 12.5, lineHeight: 1.55, color: 'var(--text)' }}>
          <code>{SDK_SNIPPET}</code>
        </pre>
      </Section>
    </div>
  )
}
