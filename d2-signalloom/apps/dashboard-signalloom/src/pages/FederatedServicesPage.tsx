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
 * The shape of that strip is CryptographyPage's, deliberately and to the
 * character — same `FilterBar` props, same chip styling, same `NoMatch` wording,
 * same `useFilter` signature — because it got here first and ten pages that each
 * invented their own good idea would be nine pages of drift. One widening, named
 * at `useFilter`: `chipOf` may return a list, for the single table on this page
 * whose rows belong to more than one chip at once.
 *
 * What has NOT changed: no data, no fetch (there is still none), no route, no
 * copy on any row. The arrays below are byte-for-byte the ones that were here.
 */
import { useMemo, useState, type CSSProperties } from 'react'
import { StatCard, Section } from '../components/DashKit'
import DataTable, { type Column } from '../components/DataTable'
import EmptyState from '../components/EmptyState'
import StatusBadge, { tint } from '../components/StatusBadge'
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

// ── Filtering ────────────────────────────────────────────────────────────────
//
// Six tables, one strip, matching CryptographyPage. Every table here is a
// DataTable in the shape the Design System page calls "Realistic": a `toolbar`
// slot carrying the controls and an `emptyState` for the filter that matches
// nothing. The page still owns the state and the predicate — DataTable reads
// neither and is handed an already-narrowed array — which is exactly why the
// strip itself can be shared here without sharing an opinion about what
// "search" means.
//
// FilterBar is local to this file rather than a component, deliberately, and
// deliberately NOT shared with CryptographyPage's identically-named one. What
// it standardises is layout and wording across six sibling tables on ONE page;
// the moment a second page wants it, the predicate argument starts growing
// options and it becomes the thing DataTable's header comment warns against.
// The predicates stay per-table, as they must — "search" means a trust domain
// here and a SPIFFE path three sections down.

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
        // Every placeholder on this page is written to FIT this 230px box at
        // 12px. The first drafts named all three searched fields and Chrome
        // clipped two of them mid-word ("…or trans"), which reads as a
        // rendering fault rather than as a hint.
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
            {/* No aria-label: the accessible name is the visible text, which is
                what a speech-input user can actually say. */}
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
 * A separate wording from a healthy zero on purpose — no table on this page
 * ever legitimately has no rows, so an empty table here is always something the
 * reader just did, and the body says how to undo it. The toolbar is still above
 * it, because DataTable renders the toolbar on the empty branch too.
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
 *
 * ONE WIDENING of CryptographyPage's signature, and only one: `chipOf` may
 * return a LIST as well as a single value. Every table on that page had a row
 * sitting on exactly one chip; Attestation Policies here binds several zones at
 * once (`zones: 'eu, acme'`) and honestly belongs under both. Returning an
 * array is the same code path with more than one element, and the five
 * single-valued call sites below are byte-identical to the ones over there.
 */
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

/** Normalises `chipOf`'s single-or-list return to the list the callers want. */
function chipsOf<T>(row: T, chipOf: (row: T) => string | readonly string[]): readonly string[] {
  const value = chipOf(row)
  return typeof value === 'string' ? [value] : value
}

/**
 * Row counts per chip, for the badge on each chip. Fixed data, so computed once.
 *
 * Counted against the WHOLE table rather than the current result. A chip that
 * reported the filtered set would read 0 for every option not selected and stop
 * being a way back to the rows it hides.
 */
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

// ── Predicates and chip vocabularies ─────────────────────────────────────────
//
// Declared rather than derived from the rows. A vocabulary taken from today's
// data can only ever offer chips that match something, which quietly removes
// the one control that reaches the empty state — see `connecting` on Trust
// Zones, a real state of the Status column that no zone is in right now.

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
/** The one many-valued axis on the page: a policy binds several zones and files
 *  under each. Split on the same comma the cell displays, so a reader can see
 *  why a row matched. Chip counts therefore sum to more than the row count. */
const policyChip = (p: AttestationPolicy) => p.zones.split(',').map((z) => z.trim()).filter(Boolean)
const policyMatches = (p: AttestationPolicy, q: string) =>
  p.name.toLowerCase().includes(q) || p.selector.toLowerCase().includes(q)

const SPIFFE_CHIPS = ['all', 'dashboard', 'agent', 'service'] as const
const spiffeChip = (s: SpiffeIdentity) => s.workload
const spiffeMatches = (s: SpiffeIdentity, q: string) =>
  s.uri.toLowerCase().includes(q) || s.ns.toLowerCase().includes(q) || s.sa.toLowerCase().includes(q)

const EVENT_CHIPS = ['all', 'signalloom-eu', 'signalloom-us', 'partner-acme'] as const
/** Zone, not severity. `severity` is on the data and on no column, and a chip
 *  strip that removes rows on a property the reader cannot see anywhere in the
 *  table is a filter they have no way to reason about. */
const eventChip = (e: FederationEvent) => e.zone
const eventMatches = (e: FederationEvent, q: string) =>
  e.event.toLowerCase().includes(q) || e.detail.toLowerCase().includes(q)
  || e.ts.toLowerCase().includes(q)

const ZONE_COUNTS = chipCounts(TRUST_ZONES, ZONE_CHIPS, zoneChip)
const FEDERATION_COUNTS = chipCounts(FEDERATIONS, FEDERATION_CHIPS, federationChip)
const SERVICE_COUNTS = chipCounts(FEDERATED_SERVICES, SERVICE_CHIPS, serviceChip)
const POLICY_COUNTS = chipCounts(POLICIES, POLICY_CHIPS, policyChip)
const SPIFFE_COUNTS = chipCounts(SPIFFE_IDS, SPIFFE_CHIPS, spiffeChip)
const EVENT_COUNTS = chipCounts(FEDERATION_EVENTS, EVENT_CHIPS, eventChip)

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

  const zones = useFilter(TRUST_ZONES, zoneChip, zoneMatches)
  const federations = useFilter(FEDERATIONS, federationChip, federationMatches)
  const services = useFilter(FEDERATED_SERVICES, serviceChip, serviceMatches)
  const policies = useFilter(POLICIES, policyChip, policyMatches)
  const identities = useFilter(SPIFFE_IDS, spiffeChip, spiffeMatches)
  const events = useFilter(FEDERATION_EVENTS, eventChip, eventMatches)

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
          data={zones.filtered}
          pageSize={10}
          testIdPrefix="fed-zones"
          toolbar={
            <FilterBar
              name="trust zones"
              testIdPrefix="fed-zones"
              placeholder="Search zone or trust domain…"
              search={zones.search}
              onSearch={zones.setSearch}
              chips={ZONE_CHIPS}
              counts={ZONE_COUNTS}
              active={zones.chip}
              onChip={zones.setChip}
              shown={zones.filtered.length}
              total={TRUST_ZONES.length}
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
              placeholder="Search zone, mode or policy…"
              search={federations.search}
              onSearch={federations.setSearch}
              chips={FEDERATION_CHIPS}
              counts={FEDERATION_COUNTS}
              active={federations.chip}
              onChip={federations.setChip}
              shown={federations.filtered.length}
              total={FEDERATIONS.length}
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

      <Section title="Federated Services" hint="local endpoint → remote-zone workload">
        <DataTable
          columns={SERVICE_COLUMNS}
          data={services.filtered}
          pageSize={10}
          testIdPrefix="fed-services"
          toolbar={
            <FilterBar
              name="federated services"
              testIdPrefix="fed-services"
              placeholder="Search service or endpoint…"
              search={services.search}
              onSearch={services.setSearch}
              chips={SERVICE_CHIPS}
              counts={SERVICE_COUNTS}
              active={services.chip}
              onChip={services.setChip}
              shown={services.filtered.length}
              total={FEDERATED_SERVICES.length}
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
              placeholder="Search policy or selector…"
              search={policies.search}
              onSearch={policies.setSearch}
              chips={POLICY_CHIPS}
              counts={POLICY_COUNTS}
              active={policies.chip}
              onChip={policies.setChip}
              shown={policies.filtered.length}
              total={POLICIES.length}
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
              placeholder="Search SPIFFE ID or namespace…"
              search={identities.search}
              onSearch={identities.setSearch}
              chips={SPIFFE_CHIPS}
              counts={SPIFFE_COUNTS}
              active={identities.chip}
              onChip={identities.setChip}
              shown={identities.filtered.length}
              total={SPIFFE_IDS.length}
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
              placeholder="Search event or detail…"
              search={events.search}
              onSearch={events.setSearch}
              chips={EVENT_CHIPS}
              counts={EVENT_COUNTS}
              active={events.chip}
              onChip={events.setChip}
              shown={events.filtered.length}
              total={FEDERATION_EVENTS.length}
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
