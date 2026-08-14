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
 * WHY THE TABLES MOVED TO DataTable, having previously argued they should not.
 *
 * The note that stood here said these are six tables of three to five rows, that
 * pagination would be furniture and that "sorting a five-row list is a control
 * nobody reaches for". Both halves of that are still true and neither was the
 * question. What DataTable is being adopted for is the third prop, `toolbar`,
 * and the guarantee attached to it: a filter control that survives its own
 * result. The old argument weighed DataTable purely as a pager, because when it
 * was written that is mostly what it was.
 *
 * Filtering a five-row table is admittedly not the point either — nobody needs
 * to search three trust zones. The point is that this page is the widest
 * vocabulary of the superadmin set (zones, federations, services, policies,
 * identities, events, six different axes) and the fixtures are small only until
 * they are not. The controls that let a reader cut a fabric down by zone are the
 * ones that stop being optional at thirty rows, and the moment to establish
 * where they live and how they read is while the tables are small enough that
 * getting it wrong costs nothing. Uniformity is the deliverable: every table on
 * this page filters the same way, in the same order, with the same undo.
 *
 * What has NOT changed: no data, no fetch (there is still none), no route, no
 * copy on any row. The arrays below are byte-for-byte the ones that were here.
 */
import { useCallback, useMemo, useState, type CSSProperties } from 'react'
import { StatCard, Section } from '../components/DashKit'
import DataTable, { type Column } from '../components/DataTable'
import EmptyState from '../components/EmptyState'
import StatusBadge from '../components/StatusBadge'
import { ProofConsole, type Proof } from '../components/ProofConsole'

// ── Data ────────────────────────────────────────────────────────────────────
//
// Typed rather than inferred, because `Column<T>['key']` is `keyof T & string`:
// the column definitions below are now checked against these shapes, so a
// renamed field fails the build instead of silently sorting by nothing.

interface TrustZone {
  name: string
  domain: string
  clusters: number
  servers: number
  status: string
}

interface Federation {
  left: string
  right: string
  mode: string
  policy: string
  status: string
}

interface FederatedService {
  service: string
  home: string
  consumer: string
  endpoint: string
  transport: string
  status: string
}

interface AttestationPolicy {
  name: string
  selector: string
  zones: string
}

interface SpiffeIdentity {
  uri: string
  workload: string
  ns: string
  sa: string
  svid: string
  expiry: string
}

interface FederationEvent {
  ts: string
  zone: string
  event: string
  detail: string
  severity: string
}

const TRUST_ZONES: TrustZone[] = [
  { name: 'signalloom-eu', domain: 'eu.signalloom.svc.cluster.local', clusters: 2, servers: 2, status: 'active' },
  { name: 'signalloom-us', domain: 'us.signalloom.svc.cluster.local', clusters: 1, servers: 1, status: 'active' },
  { name: 'partner-acme', domain: 'acme.partner.example', clusters: 1, servers: 1, status: 'active' },
]

const FEDERATIONS: Federation[] = [
  { left: 'signalloom-eu', right: 'signalloom-us', mode: 'bidirectional', policy: 'ap-payments', status: 'federated' },
  { left: 'signalloom-eu', right: 'partner-acme', mode: 'one-way (eu → acme)', policy: 'ap-partner-read', status: 'federated' },
  { left: 'signalloom-us', right: 'partner-acme', mode: 'pending bundle exchange', policy: 'ap-partner-read', status: 'connecting' },
]

const FEDERATED_SERVICES: FederatedService[] = [
  { service: 'payments-api', home: 'signalloom-eu', consumer: 'signalloom-us', endpoint: 'payments.local:8443', transport: 'xDS (Envoy)', status: 'active' },
  { service: 'ledger-grpc', home: 'signalloom-eu', consumer: 'signalloom-us', endpoint: 'ledger.local:9443', transport: 'Cofide Go SDK', status: 'active' },
  { service: 'kyc-lookup', home: 'partner-acme', consumer: 'signalloom-eu', endpoint: 'kyc.local:8443', transport: 'xDS (Envoy)', status: 'active' },
  { service: 'settlement-feed', home: 'signalloom-us', consumer: 'partner-acme', endpoint: 'settle.local:8443', transport: 'Cofide Go SDK', status: 'connecting' },
]

const POLICIES: AttestationPolicy[] = [
  { name: 'ap-payments', selector: 'k8s:ns:payments, k8s:sa:api', zones: 'eu, us' },
  { name: 'ap-partner-read', selector: 'k8s:ns:partner, k8s:label:federate=true', zones: 'eu, acme' },
  { name: 'ap-node-tpm', selector: 'tpm:ek_sha256:9f3c…', zones: 'eu, us' },
]

const SPIFFE_IDS: SpiffeIdentity[] = [
  { uri: 'spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom', workload: 'dashboard', ns: 'fe-signalloom', sa: 'fe-signalloom', svid: 'X.509', expiry: '2026-08-02T18:00:00Z' },
  { uri: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent', workload: 'agent', ns: 'fe-signalloom-agents', sa: 'cardvault-agent', svid: 'JWT', expiry: '2026-08-02T14:30:00Z' },
  { uri: 'spiffe://signalloom.demo/ns/payments/sa/payments-api', workload: 'service', ns: 'payments', sa: 'payments-api', svid: 'X.509', expiry: '2026-08-03T06:00:00Z' },
  { uri: 'spiffe://signalloom.demo/ns/payments/sa/ledger-grpc', workload: 'service', ns: 'payments', sa: 'ledger-grpc', svid: 'X.509', expiry: '2026-08-03T06:00:00Z' },
  { uri: 'spiffe://acme.partner.example/ns/kyc/sa/kyc-lookup', workload: 'service', ns: 'kyc', sa: 'kyc-lookup', svid: 'X.509', expiry: '2026-08-02T22:00:00Z' },
]

const FEDERATION_EVENTS: FederationEvent[] = [
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

// ── Columns ─────────────────────────────────────────────────────────────────
//
// TOOLTIP DENSITY. A column carries `help` when its label is a term of art that
// a competent engineer who has not read the Cofide docs would confidently guess
// WRONG about — not merely one they have never seen. "Trust domain" and "Local
// endpoint" both look like ordinary words and mean something specific and
// counter-intuitive; "Zone", "Namespace" and "Timestamp" mean what they say.
// Federation Events therefore carries none at all, deliberately: a convention
// that fires on every table is decoration, and the floor is what proves it is a
// judgement rather than a habit.
//
// Three of these strings (Mode, Attestation policy, SVID type) are carried over
// verbatim from the hand-rolled headers this page used before. They are not
// rewritten, because the migration is not the place to relitigate copy.

const ZONE_COLUMNS: Column<TrustZone>[] = [
  { key: 'name', label: 'Zone', sortable: true },
  {
    key: 'domain',
    label: 'Trust domain',
    sortable: true,
    help: 'The SPIFFE trust domain — the root of identity for everything inside the zone, and the only part of an SVID that says who vouches for it. Two zones with different trust domains share no certificate authority, so nothing in one is trusted by the other until they are federated.',
  },
  { key: 'clusters', label: 'Clusters', sortable: true },
  {
    key: 'servers',
    label: 'SPIRE servers',
    sortable: true,
    help: 'How many SPIRE servers issue identities for this zone. More than one is a high-availability set sharing a single trust domain, not additional zones — identity is not partitioned by server, so two servers here do not mean two populations of workloads.',
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
    help: 'The rule a workload must satisfy before its identity is accepted across the federation — namespace, service account, or a hardware measurement. Federating two zones does not admit everything in them; this is the filter.',
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
    help: 'Who holds the socket. xDS lets an unmodified workload use an Envoy sidecar the agent configures; the Go SDK dials from inside the process with no sidecar. The identity and the mutual TLS are the same either way — this is a deployment choice, not a security one.',
  },
  { key: 'status', label: 'Status', sortable: true },
]

const POLICY_COLUMNS: Column<AttestationPolicy>[] = [
  { key: 'name', label: 'Policy', sortable: true },
  {
    key: 'selector',
    label: 'Selector',
    sortable: true,
    help: 'The properties a workload must actually be observed to have before this policy will issue it an identity. "k8s:ns:" is a namespace and "k8s:sa:" a service account — both asserted by the Kubernetes API, so both forgeable by anything that controls it. "tpm:ek_sha256:" is a hardware key that is not.',
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
    help: 'The form the identity document takes. X.509 is a certificate presented during the TLS handshake, so the identity is proven by the connection itself. JWT is a bearer token passed above it — usable where mutual TLS cannot reach, and, being a bearer token, replayable if it leaks.',
  },
]

const EVENT_COLUMNS: Column<FederationEvent>[] = [
  { key: 'ts', label: 'Timestamp', sortable: true },
  { key: 'zone', label: 'Zone', sortable: true },
  { key: 'event', label: 'Event', sortable: true },
  // Not sortable, and the only column on the page that is not. Alphabetising
  // free prose sorts by whichever word happens to be first, which is a control
  // that appears to do something and does nothing a reader wanted.
  { key: 'detail', label: 'Detail' },
]

// ── Filtering ───────────────────────────────────────────────────────────────

/**
 * How one table is searched and faceted.
 *
 * Module-level constants rather than literals at the call site: `useTableFilter`
 * memoises on the spec, and an object rebuilt every render would recompute the
 * chip options on every keystroke.
 *
 * `facet` returns a LIST because a row can sit on several values of one axis —
 * an attestation policy binds two zones and belongs under both chips. Every
 * other table returns one, which is the same code path with one element.
 */
interface FilterSpec<T> {
  /** Fields the search box matches, case-insensitively, as substrings. */
  search: (row: T) => string[]
  /** Which chip values this row belongs to. */
  facet: (row: T) => string[]
}

interface TableFilter<T> {
  query: string
  setQuery: (value: string) => void
  selected: string
  setSelected: (value: string) => void
  /** Already narrowed — this is what goes to DataTable's `data`. */
  rows: T[]
  /** Chip values, `all` first. */
  options: string[]
  /** Row count per chip, against the FULL source rather than the narrowed one. */
  counts: Record<string, number>
  /** Whether anything is currently narrowing the table. */
  active: boolean
  clear: () => void
  total: number
}

const ALL = 'all'

function useTableFilter<T>(source: T[], spec: FilterSpec<T>): TableFilter<T> {
  const [query, setQuery] = useState('')
  const [selected, setSelected] = useState(ALL)

  // First-appearance order, not alphabetical, so the chip strip and the table
  // below it read in the same order.
  const options = useMemo(() => {
    const seen: string[] = []
    for (const row of source) {
      for (const value of spec.facet(row)) {
        if (!seen.includes(value)) seen.push(value)
      }
    }
    return [ALL, ...seen]
  }, [source, spec])

  // Counts are of the source, not of `rows`. A chip that reported its count
  // after its own filter had been applied would read "1" for whichever chip is
  // selected and "0" for every other one — the strip would stop being a map of
  // the data and become an echo of the click.
  const counts = useMemo(() => {
    const out: Record<string, number> = { [ALL]: source.length }
    for (const option of options) {
      if (option === ALL) continue
      out[option] = source.filter((row) => spec.facet(row).includes(option)).length
    }
    return out
  }, [source, spec, options])

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase()
    return source.filter((row) => {
      if (selected !== ALL && !spec.facet(row).includes(selected)) return false
      if (!q) return true
      return spec.search(row).some((field) => field.toLowerCase().includes(q))
    })
  }, [source, spec, query, selected])

  const clear = useCallback(() => {
    setQuery('')
    setSelected(ALL)
  }, [])

  return {
    query,
    setQuery,
    selected,
    setSelected,
    rows,
    options,
    counts,
    active: query.trim() !== '' || selected !== ALL,
    clear,
    total: source.length,
  }
}

const ZONE_FILTER: FilterSpec<TrustZone> = {
  search: (z) => [z.name, z.domain],
  facet: (z) => [z.status],
}

const FEDERATION_FILTER: FilterSpec<Federation> = {
  search: (f) => [f.left, f.right, f.mode, f.policy],
  facet: (f) => [f.status],
}

const SERVICE_FILTER: FilterSpec<FederatedService> = {
  search: (s) => [s.service, s.endpoint, s.transport],
  facet: (s) => [s.home],
}

const POLICY_FILTER: FilterSpec<AttestationPolicy> = {
  search: (p) => [p.name, p.selector],
  // A policy binds several zones, so it appears under each of them. Split on
  // the same comma the cell displays, so a reader can see why a row matched.
  facet: (p) => p.zones.split(',').map((z) => z.trim()).filter(Boolean),
}

const SPIFFE_FILTER: FilterSpec<SpiffeIdentity> = {
  search: (s) => [s.uri, s.ns, s.sa],
  facet: (s) => [s.workload],
}

const EVENT_FILTER: FilterSpec<FederationEvent> = {
  search: (e) => [e.event, e.detail, e.ts],
  // Zone, not severity. `severity` is on the data and on no column, and a chip
  // strip that removes rows on a property the reader cannot see anywhere in the
  // table is a filter they have no way to reason about.
  facet: (e) => [e.zone],
}

// ── Toolbar ─────────────────────────────────────────────────────────────────

/**
 * `minWidth: 230` is the Design System specimen's, kept so the six strips on
 * this page and the ten pages migrating alongside it line up. Every placeholder
 * below is written to FIT that box at 12px — the first drafts named all three
 * searched fields and Chrome clipped two of them mid-word ("…or trans"), which
 * reads as a rendering fault rather than as a hint. A placeholder that names two
 * of the three fields is a shorter promise; one that is visibly cut off is a
 * broken-looking control.
 */
const searchStyle: CSSProperties = {
  fontSize: 12,
  padding: '5px 9px',
  minWidth: 230,
  color: 'var(--text)',
  background: 'var(--surface2)',
  border: '1px solid var(--border)',
  borderRadius: 4,
}

/**
 * Selected is a tinted fill plus a full-strength border, never a solid accent
 * fill — text on solid amber or cyan fails AA in at least one of the three
 * themes. Copied from the Design System's DataTable specimen rather than
 * re-derived, so the ten pages migrating in parallel land on one chip.
 */
function chipStyle(selected: boolean): CSSProperties {
  return {
    fontSize: 11.5,
    padding: '4px 9px',
    borderRadius: 4,
    cursor: 'pointer',
    color: selected ? 'var(--cyan)' : 'var(--muted)',
    background: selected ? 'color-mix(in srgb, var(--cyan) 12%, transparent)' : 'var(--surface2)',
    border: `1px solid ${selected ? 'color-mix(in srgb, var(--cyan) 45%, transparent)' : 'var(--border)'}`,
  }
}

/**
 * The strip above every table on this page, in a fixed order: search, chips,
 * clear, count.
 *
 * The order is the convention and it is not arbitrary. Search first because it
 * is the control a reader reaches for without being prompted; chips next
 * because they are a map of the data as much as a control, and reading them
 * costs nothing; clear next because it undoes everything to its left; the count
 * last because it is the OUTCOME of all three and belongs after its causes.
 *
 * Clear is always rendered and merely disabled when there is nothing to clear.
 * A control that appears only once it is needed moves everything beside it at
 * the exact moment the reader is aiming at something — and DataTable's own
 * footer carries a comment about the neighbouring version of this bug, where a
 * control's own value decided whether that control rendered.
 */
function FilterToolbar<T>({
  name,
  facetLabel,
  placeholder,
  filter,
  testIdPrefix,
}: {
  /** Names the table inside the control labels: "Search federations". */
  name: string
  /** What the chips filter on: "status", "home zone". */
  facetLabel: string
  placeholder: string
  filter: TableFilter<T>
  testIdPrefix: string
}) {
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
        value={filter.query}
        onChange={(e) => filter.setQuery(e.target.value)}
        data-testid={`${testIdPrefix}-search`}
        style={searchStyle}
      />
      <div
        style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8 }}
        role="group"
        aria-label={`Filter ${name} by ${facetLabel}`}
      >
        {filter.options.map((option) => {
          const selected = filter.selected === option
          return (
            <button
              key={option}
              type="button"
              onClick={() => filter.setSelected(option)}
              aria-pressed={selected}
              data-testid={`${testIdPrefix}-filter-${option}`}
              style={chipStyle(selected)}
            >
              {/* No aria-label: the accessible name is the visible text, which
                  is what a speech-input user can actually say. The surrounding
                  group supplies the "by status" the chip itself omits. */}
              {option} <span style={{ color: 'var(--dim)' }}>{filter.counts[option]}</span>
            </button>
          )
        })}
      </div>
      <button
        type="button"
        className="btn btn-secondary"
        onClick={filter.clear}
        disabled={!filter.active}
        data-testid={`${testIdPrefix}-clear`}
        style={{ fontSize: 11.5, padding: '4px 9px' }}
      >
        Clear filters
      </button>
      <span data-testid={`${testIdPrefix}-count`} style={{ fontSize: 11.5, color: 'var(--muted)' }}>
        {filter.rows.length} of {filter.total} shown
      </span>
    </div>
  )
}

/** The same panel under every table, naming the two controls that emptied it. */
function NothingMatched({ facetLabel }: { facetLabel: string }) {
  return (
    <EmptyState
      kicker="Nothing matches those filters"
      body={`Clear the search box, choose a different ${facetLabel}, or use Clear filters above.`}
    />
  )
}

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

const rowStyle: CSSProperties = { borderBottom: '1px solid var(--border)' }
const codeStyle: CSSProperties = { color: 'var(--cyan)', fontSize: 12 }
const policyCodeStyle: CSSProperties = { color: 'var(--violet)', fontSize: 12 }
const mutedCell: CSSProperties = { ...DataTable.td, color: 'var(--muted)' }
const nameCell: CSSProperties = { ...DataTable.td, fontWeight: 500 }

export default function FederatedServicesPage() {
  const activeFed = FEDERATED_SERVICES.filter((s) => s.status === 'active').length
  const [proofOpen, setProofOpen] = useState(false)

  const zones = useTableFilter(TRUST_ZONES, ZONE_FILTER)
  const federations = useTableFilter(FEDERATIONS, FEDERATION_FILTER)
  const services = useTableFilter(FEDERATED_SERVICES, SERVICE_FILTER)
  const policies = useTableFilter(POLICIES, POLICY_FILTER)
  const identities = useTableFilter(SPIFFE_IDS, SPIFFE_FILTER)
  const events = useTableFilter(FEDERATION_EVENTS, EVENT_FILTER)

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

      {/* The StatCards above deliberately count the SOURCE arrays, not the
          filtered ones. They are a description of the fabric; narrowing a table
          is a question the reader is asking of it, and a headline figure that
          moved with the question would make the two indistinguishable. */}

      <Section title="Trust Zones" hint="each a SPIFFE trust domain">
        <DataTable
          columns={ZONE_COLUMNS}
          data={zones.rows}
          pageSize={10}
          testIdPrefix="fed-zones"
          toolbar={
            <FilterToolbar
              name="trust zones"
              facetLabel="status"
              placeholder="Search zone or trust domain…"
              filter={zones}
              testIdPrefix="fed-zones"
            />
          }
          emptyState={<NothingMatched facetLabel="status" />}
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
          data={federations.rows}
          pageSize={10}
          testIdPrefix="fed-federations"
          toolbar={
            <FilterToolbar
              name="federations"
              facetLabel="status"
              placeholder="Search zone, mode or policy…"
              filter={federations}
              testIdPrefix="fed-federations"
            />
          }
          emptyState={<NothingMatched facetLabel="status" />}
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

      <Section title="Federated Services" hint="local endpoint → remote-zone workload">
        <DataTable
          columns={SERVICE_COLUMNS}
          data={services.rows}
          pageSize={10}
          testIdPrefix="fed-services"
          toolbar={
            <FilterToolbar
              name="federated services"
              facetLabel="home zone"
              placeholder="Search service or endpoint…"
              filter={services}
              testIdPrefix="fed-services"
            />
          }
          emptyState={<NothingMatched facetLabel="home zone" />}
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
          data={policies.rows}
          pageSize={10}
          testIdPrefix="fed-policies"
          toolbar={
            <FilterToolbar
              name="attestation policies"
              facetLabel="bound zone"
              placeholder="Search policy or selector…"
              filter={policies}
              testIdPrefix="fed-policies"
            />
          }
          emptyState={<NothingMatched facetLabel="bound zone" />}
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
          data={identities.rows}
          pageSize={10}
          testIdPrefix="fed-spiffe"
          toolbar={
            <FilterToolbar
              name="SPIFFE identities"
              facetLabel="workload"
              placeholder="Search SPIFFE ID or namespace…"
              filter={identities}
              testIdPrefix="fed-spiffe"
            />
          }
          emptyState={<NothingMatched facetLabel="workload" />}
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
          data={events.rows}
          pageSize={10}
          testIdPrefix="fed-events"
          toolbar={
            <FilterToolbar
              name="federation events"
              facetLabel="zone"
              placeholder="Search event or detail…"
              filter={events}
              testIdPrefix="fed-events"
            />
          }
          emptyState={<NothingMatched facetLabel="zone" />}
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
