/**
 * RBAC Explorer — native Signal Loom view of KubeSec-AFM analysis data.
 *
 * Pulls correlated RBAC + escalation + conformance + shared-role data from the
 * intermediate `/api/rbac/*` layer (see `rbac_correlation.py`), which itself
 * fetches from KubeSec-AFM server-side and joins the four AFM endpoints
 * together — the frontend used to do that stitching itself, against wire
 * shapes (`escalation_paths`, top-level conformance `namespace`, shared-role
 * `shared_by`/`risk`) that AFM never actually sends. See
 * docs/signalloom/rbac-live-wiring.md and rbac_correlation.py's module
 * docstring for the verified real shapes and the bugs that produced.
 *
 * Runs in parallel with the iframe'd AFM dashboard (RBAC Analysis page) so both
 * views can be compared. In future, remote cluster connectors will plug into the
 * same cluster selector pattern used here.
 *
 * All five tables are DataTable, each with the Design System's `toolbar` and
 * `emptyState` slots. The page keeps every predicate and hands DataTable an
 * already-narrowed array — see DataTable.tsx's "ONE COMPONENT, NOT TWO" note
 * for why the search lives here and not in the component.
 *
 * WHAT A COUNT ON THIS PAGE MEANS. The stat cards and the Section hints are
 * computed from the correlated response and the namespace selector only —
 * never from a table's own search box. A page whose headline "Escalation
 * Paths: 0" could be produced by typing in a search field would be the same
 * class of failure as the one rbac_correlation.py exists to prevent: a
 * security figure reading zero for a reason that is not "there are none". The
 * table toolbars carry their own "N of M shown", which is where a filtered
 * count belongs.
 */
import { Component, Fragment, useCallback, useEffect, useMemo, useState, type CSSProperties, type ErrorInfo, type ReactNode } from 'react'
import ErrorState from '../components/ErrorState'
import { StatCard, Section, Pill } from '../components/DashKit'
import { tint } from '../components/StatusBadge'
import DataTable, { type Column } from '../components/DataTable'
import EmptyState from '../components/EmptyState'
import HelpHint from '../components/HelpHint'
import { ProofConsole, type Proof } from '../components/ProofConsole'
import { isDemoMode } from '../api/demoMode'
import { useAuth0 } from '../auth/oidc'
import {
  fetchCorrelatedRbac,
  fetchRbacClusters,
  type ClusterMeta,
  type ConformanceFinding,
  type CorrelatedRbac,
  type EscalationFinding,
  type RbacBinding,
  type RbacRole,
  type RbacSubject,
  type SharedRoleFinding,
} from '../api/rbacCorrelationApi'
import AddClusterModal, { type NewClusterEntry } from '../components/AddClusterModal'
import LoadingState from '../components/LoadingState'
import { curlPipeJq, jqOutput, jqString } from './proofQuery'

class RbacErrorBoundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state: { error: Error | null } = { error: null }
  static getDerivedStateFromError(error: Error) { return { error } }
  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('[rbac-explorer] render crash:', error, info.componentStack)
  }
  render() {
    if (this.state.error) {
      return (
        <div style={{ padding: 40, color: 'var(--error)' }} data-testid="rbac-error">
          <h2>RBAC Explorer crashed</h2>
          <pre style={{ fontSize: 12, color: 'var(--muted)', whiteSpace: 'pre-wrap' }}>{this.state.error.message}</pre>
          <button className="btn btn-secondary" style={{ marginTop: 12 }} onClick={() => this.setState({ error: null })}>Retry</button>
        </div>
      )
    }
    return this.props.children
  }
}

// ─── "How do we know?" ───────────────────────────────────────────────────────
//
// Every finding on this page is a claim about someone else's cluster —
// "this ServiceAccount can become admin", "this role is non-conformant" — and
// the analysis that produced it ran two systems away, inside AFM's Z3 model
// checker. A reader cannot re-run Z3 from here, and pretending otherwise by
// printing an invented `kubectl auth can-i` would be the fabricated-probe
// failure this repo already has history with. What a reader CAN re-run is the
// request this page made, so that is what the proof is: the correlated
// endpoint, and the finding as it came off the wire, before anything on this
// page rendered or reworded it.
//
// The projections below are restricted to fields whose client-side parse maps
// a missing value to `undefined` — every one is `asOptionalString`, a
// validated enum, or `typeof === 'number' ? v : undefined` (see
// rbacCorrelationApi.ts). That restriction is what makes the printed object
// byte-identical to what the command prints: a field parsed with a `?? 0` or
// `?? []` default would read as 0 or [] here where jq reads null, and there is
// no honest way to show that under a jq command. It is also why the
// shared-role and role tables carry no proof — see the report; their
// substantive fields go through exactly those defaulting parses.

/** Matches `fetchCorrelatedRbac`, so the command names the route really called. */
export function correlatedPath(clusterId: string): string {
  return `/api/rbac/clusters/${encodeURIComponent(clusterId)}/correlated`
}

/** A jq comparison literal, with `null` for a field the parse left absent. */
function jqKey(value: string | undefined): string {
  return value === undefined ? 'null' : jqString(value)
}

/**
 * Proof for one escalation finding: the wire record AFM's analysis produced.
 *
 * Keyed on `subject` and printing EVERY match, because a subject can carry
 * more than one route and `select` is a stream — showing only the clicked row
 * would be a truthful object under a command that prints two.
 */
export function escalationProofs(
  finding: EscalationFinding,
  all: EscalationFinding[],
  clusterId: string,
  demo: boolean,
): Proof[] {
  if (demo) return []
  const projection = '{kind, subject, subject_display, escalation_type, risk_level, risk_score, summary}'
  const matches = all
    .filter((f) => f.subject === finding.subject)
    .map((f) => ({
      kind: f.kind,
      subject: f.subject,
      subject_display: f.subjectDisplay,
      escalation_type: f.escalationType,
      risk_level: f.riskLevel,
      risk_score: f.riskScore,
      summary: f.summary,
    }))
  return [{
    label: 'Finding',
    command: curlPipeJq({
      path: correlatedPath(clusterId),
      bearer: true,
      filter: `.escalations[] | select(.subject == ${jqKey(finding.subject)}) | ${projection}`,
    }),
    detail: jqOutput(matches),
  }]
}

/**
 * Proof for one conformance issue — and for every other issue against the same
 * role, which is the point rather than a side effect: a role's full
 * conformance record is more use than the single line the row happened to show.
 */
export function conformanceProofs(
  finding: ConformanceFinding,
  all: ConformanceFinding[],
  clusterId: string,
  demo: boolean,
): Proof[] {
  if (demo) return []
  const projection = '{role_name, role_scope, role_namespace, severity, reason}'
  const matches = all
    .filter((c) => c.roleName === finding.roleName)
    .map((c) => ({
      role_name: c.roleName,
      role_scope: c.roleScope,
      role_namespace: c.roleNamespace,
      severity: c.severity,
      reason: c.reason,
    }))
  return [{
    label: 'Finding',
    command: curlPipeJq({
      path: correlatedPath(clusterId),
      bearer: true,
      filter: `.conformance[] | select(.role_name == ${jqKey(finding.roleName)}) | ${projection}`,
    }),
    detail: jqOutput(matches),
  }]
}

/**
 * The row-level disclosure, matching Network Tests and the Credential
 * Lifecycle card. Not `.btn`: it sits under a 12px table cell, and a full-size
 * button there outranks the finding it belongs to.
 */
const proofButton: CSSProperties = {
  marginTop: 6, fontSize: 10, padding: '3px 8px', borderRadius: 4, cursor: 'pointer',
  border: '1px solid var(--border)', background: 'transparent', color: 'var(--muted)',
}

// ─── Toolbar idiom ───────────────────────────────────────────────────────────
//
// One implementation for all five tables, lifted from the Design System's
// "Realistic — the shape AgentsPage needs" specimen. Five hand-rolled strips
// would drift from each other within a release; this one drifts as a unit or
// not at all.

const searchInput: CSSProperties = {
  fontSize: 12, padding: '5px 9px', minWidth: 230,
  color: 'var(--text)', background: 'var(--surface2)',
  border: '1px solid var(--border)', borderRadius: 4,
}

/**
 * A selected chip is a tinted fill plus a full-strength border, never a solid
 * accent fill — text on solid cyan fails AA in at least one of the three
 * themes, and this page is read in all three.
 */
function chipStyle(selected: boolean): CSSProperties {
  return {
    fontSize: 11.5, padding: '4px 9px', borderRadius: 4, cursor: 'pointer',
    color: selected ? 'var(--cyan)' : 'var(--muted)',
    background: selected ? tint('var(--cyan)', 0.12) : 'var(--surface2)',
    border: `1px solid ${selected ? tint('var(--cyan)', 0.45) : 'var(--border)'}`,
  }
}

interface ChipOption { value: string; label: string; count: number }

interface ChipGroup {
  /** Accessible name for the set. The chips themselves carry visible text only. */
  label: string
  value: string
  onChange: (next: string) => void
  options: ChipOption[]
  testIdPrefix: string
}

/**
 * Counts every distinct value of `key` across `items`, plus an "all" option.
 *
 * Counted over the table's whole source array rather than its filtered one, so
 * a chip reading "high 3" keeps saying 3 while a search box hides two of them.
 * A count that moves when you narrow it cannot be used to decide what to click.
 */
export function chipOptions<T>(items: T[], key: (item: T) => string): ChipOption[] {
  const counts = new Map<string, number>()
  for (const item of items) {
    const k = key(item)
    counts.set(k, (counts.get(k) ?? 0) + 1)
  }
  return [
    { value: 'all', label: 'all', count: items.length },
    ...[...counts.entries()]
      .sort((a, b) => a[0].localeCompare(b[0]))
      .map(([value, count]) => ({ value, label: value, count })),
  ]
}

function TableToolbar({
  groupLabel, searchLabel, placeholder, search, onSearch, searchTestId, groups, shown, total, countTestId,
}: {
  groupLabel: string
  searchLabel: string
  placeholder: string
  search: string
  onSearch: (next: string) => void
  searchTestId: string
  groups: ChipGroup[]
  shown: number
  total: number
  countTestId: string
}) {
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8 }} role="group" aria-label={groupLabel}>
      <input
        type="search"
        aria-label={searchLabel}
        placeholder={placeholder}
        value={search}
        onChange={(e) => onSearch(e.target.value)}
        data-testid={searchTestId}
        style={searchInput}
      />
      {groups.map((group) => (
        <div key={group.testIdPrefix} role="group" aria-label={group.label} style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
          {group.options.map((option) => {
            const selected = group.value === option.value
            return (
              <button
                key={option.value}
                type="button"
                aria-pressed={selected}
                onClick={() => group.onChange(option.value)}
                data-testid={`${group.testIdPrefix}-${option.value}`}
                style={chipStyle(selected)}
              >
                {option.label} <span style={{ color: 'var(--dim)' }}>{option.count}</span>
              </button>
            )
          })}
        </div>
      ))}
      <span data-testid={countTestId} style={{ fontSize: 11.5, color: 'var(--muted)' }}>
        {shown} of {total} shown
      </span>
    </div>
  )
}

/**
 * The nothing-to-show panel, which has to say WHICH nothing this is.
 *
 * "The filter hid them" and "there are none" are different facts about the
 * cluster, and the second one is a security claim. They get different words
 * and different tones, and only the first offers a control — there is nothing
 * to clear when no filter is set. The third possibility, "AFM never answered",
 * cannot reach here at all: an unreachable upstream fails the whole panel
 * upstream of every table (see the ErrorState branch below), which is the
 * arrangement rbac_correlation.py's docstring argues for.
 */
function TableEmptyState({ filtered, onClear, kicker, body, clearTestId }: {
  filtered: boolean
  onClear: () => void
  kicker: string
  body: string
  clearTestId: string
}) {
  if (!filtered) return <EmptyState kicker={kicker} body={body} />
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center' }}>
      <EmptyState
        kicker="Nothing matches those filters"
        body="The rows are still here — the search box or a chip above is hiding them."
        tone="cyan"
      />
      {/* EmptyState has no action slot, and this control has to stay attached
          to the sentence that explains it rather than float below the panel,
          so it sits inside EmptyState's own bottom padding. */}
      <button
        className="btn btn-secondary"
        style={{ fontSize: 12, padding: '4px 10px', marginTop: -34 }}
        data-testid={clearTestId}
        onClick={onClear}
      >
        Clear filters
      </button>
    </div>
  )
}

// ─── Display projections ─────────────────────────────────────────────────────
//
// Neither of these adds information. Every field is computed from what the
// correlated endpoint already returned, and they exist so a column can name a
// sort key of its own: `Column.key` is `keyof T`, so "Rules" sorting by rule
// count and "Verbs" being a column at all both need a field to point at.

interface RoleRow extends RbacRole {
  ruleCount: number
  /** Distinct verbs in first-seen order — the same walk the cell used to do inline. */
  verbs: string[]
}

interface SubjectRow extends RbacSubject {
  boundRoles: string[]
  /** The flag pills as one string, so the column has a key and the search can reach it. */
  flags: string
}

/**
 * Verbs that let the holder change the cluster or take more power in it.
 *
 * The wildcard is deliberately not in this list even though it grants all of
 * them: it is what makes a role dangerous, not a verb that gets coloured. See
 * the fill logic in the Verbs cell.
 */
const DANGEROUS_VERBS = ['create', 'delete', 'patch', 'update', 'bind', 'escalate', 'impersonate']

// ─── Columns ─────────────────────────────────────────────────────────────────
//
// A `help` string only where the label does not already say it: a "?" that
// restates its header is noise, and the page is asserted on not growing one
// over "Name" or "Namespace" in the Roles table.

const ESCALATION_COLUMNS: Column<EscalationFinding>[] = [
  {
    key: 'subjectDisplay', label: 'Subject', sortable: true,
    help: 'The identity the analysis names as the actor. AFM works in its own internal identifiers (sa_kube_system_flux); what is shown here is that identifier resolved back to the Kubernetes Kind, namespace and name it refers to.',
  },
  {
    key: 'escalationType', label: 'Type', sortable: true,
    help: 'How the route works, in the analyser’s own categories, passed through unchanged. admin_via_impersonation means the subject can impersonate an identity that is already admin rather than holding admin itself.',
  },
  {
    key: 'riskScore', label: 'Risk', sortable: true,
    help: 'How much damage this path allows if someone walks it — derived by the analyser from what the subject could actually reach, not from a severity field a human typed in. A finding is a route that exists, not a breach that happened. Sorting this column ranks by the analyser’s underlying numeric score, so high sits above medium rather than below it alphabetically.',
  },
  { key: 'summary', label: 'Detail' },
]

const CONFORMANCE_COLUMNS: Column<ConformanceFinding>[] = [
  { key: 'reason', label: 'Issue' },
  // Not sortable: severity is a word, and sorting words puts "high" under
  // "low" and "low" under "medium". The chips are the honest affordance.
  {
    key: 'severity', label: 'Severity',
    help: 'How far the role departs from least privilege, as the conformance check graded it. It says nothing about whether anyone holds the role — a high-severity role nobody is bound to is still high.',
  },
  { key: 'roleName', label: 'Role', sortable: true },
  {
    key: 'roleNamespace', label: 'Namespace', sortable: true,
    help: 'Which namespace the role is confined to. "cluster" means it is a ClusterRole and applies in every namespace at once, so a namespace boundary does not contain it.',
  },
]

const SHARED_ROLE_COLUMNS: Column<SharedRoleFinding>[] = [
  { key: 'roleName', label: 'Role', sortable: true },
  {
    key: 'sharedBy', label: 'Shared By', sortable: true,
    help: 'How many distinct subjects hold this role. A widely-held role is a pivot point: reaching any one holder reaches everything the role grants, and one edit to the role changes it for all of them at once.',
  },
  {
    key: 'privilegedSubjectCount', label: 'Privileged Subjects', sortable: true,
    help: 'How many of the holders are already admin, or an actor in an escalation path. This is what separates a widely-shared read-only role from a widely-shared route to privilege.',
  },
]

const ROLE_COLUMNS: Column<RoleRow>[] = [
  { key: 'name', label: 'Name', sortable: true },
  {
    key: 'scope', label: 'Scope', sortable: true,
    help: 'Cluster means a ClusterRole — it applies in every namespace at once, and stays listed here whatever namespace filter is set, because a namespace boundary does not contain it. Namespace means a Role, which grants nothing outside the namespace it lives in.',
  },
  { key: 'namespace', label: 'Namespace', sortable: true },
  {
    key: 'ruleCount', label: 'Rules', sortable: true,
    help: 'How many policy rules the role carries. One rule is one grant of verbs over resources in API groups; a role with many narrow rules is not necessarily more powerful than a role with one wildcard rule.',
  },
  {
    key: 'verbs', label: 'Verbs',
    help: 'The actions this role permits. Verbs shown in red are the ones that let whoever holds the role change the cluster or take more power in it — create, delete, patch, update, bind, escalate, impersonate. The wildcard * is not coloured because it is not one verb: it grants every verb, including the red ones and every verb added by a future Kubernetes release.',
  },
  {
    key: 'conformanceIssueCount', label: 'Findings', sortable: true,
    help: 'What the other two analyses said about this role: how many conformance issues it has, and whether it is shared with a subject that is already privileged.',
  },
]

const SUBJECT_COLUMNS: Column<SubjectRow>[] = [
  { key: 'name', label: 'Name', sortable: true },
  {
    key: 'kind', label: 'Kind', sortable: true,
    help: 'ServiceAccount is an in-cluster identity Kubernetes issues a token for, and always lives in a namespace. User and Group come from outside — the API server trusts them from a certificate or an OIDC token and never stores them, which is why they have no namespace and cannot be listed from the cluster itself.',
  },
  { key: 'namespace', label: 'Namespace', sortable: true },
  {
    key: 'boundRoles', label: 'Bound Roles',
    help: 'The roles reaching this subject through the bindings currently in view. A binding carries its own scope, so a cluster-scoped binding keeps granting across every namespace while a namespace filter is set — which is why this column can change without the subject changing.',
  },
  {
    key: 'flags', label: 'Flags',
    help: 'admin means the subject already holds cluster-admin-equivalent permission. escalation means the analyser found a route by which it could reach permission it does not hold. Both can be true of the same subject.',
  },
]

// ─── Demo-mode fallback fixtures ─────────────────────────────────────────────
// When demo mode is on, this data is used directly — no network call is made
// at all (demo mode must stay offline and deterministic; live mode must never
// silently fall back to this).

function makeFakeSubjects(): RbacSubject[] {
  const kinds = ['ServiceAccount', 'User', 'Group']
  const namespaces = ['kube-system', 'default', 'apps', 'flux-system', 'monitoring', 'cert-manager', 'ingress-nginx']
  const subjects: RbacSubject[] = []
  for (let i = 0; i < 92; i++) {
    const kind = kinds[i % kinds.length]
    const ns = kind === 'ServiceAccount' ? namespaces[i % namespaces.length] : undefined
    subjects.push({
      name: `${kind.toLowerCase()}-${i}`,
      kind,
      namespace: ns,
      isAdmin: i === 0,
      isEscalationActor: i === 3,
    })
  }
  return subjects
}

function makeFakeRoles(): RbacRole[] {
  const namespaces = ['kube-system', 'default', 'apps', 'flux-system', 'monitoring']
  const roles: RbacRole[] = [
    {
      name: 'cluster-admin', scope: 'Cluster', rules: [{ verbs: ['*'], apiGroups: ['*'], resources: ['*'] }],
      conformanceIssueCount: 1, sharedByCount: 1, hasPrivilegedSharing: true,
    },
    {
      name: 'view', scope: 'Cluster', rules: [{ verbs: ['get', 'list', 'watch'], apiGroups: [''], resources: ['pods', 'services', 'configmaps'] }],
      conformanceIssueCount: 0, sharedByCount: 12, hasPrivilegedSharing: false,
    },
    {
      name: 'edit', scope: 'Cluster', rules: [{ verbs: ['get', 'list', 'watch', 'create', 'update', 'patch', 'delete'], apiGroups: [''], resources: ['pods', 'services', 'configmaps', 'secrets'] }],
      conformanceIssueCount: 1, sharedByCount: 5, hasPrivilegedSharing: false,
    },
  ]
  for (let i = 0; i < 15; i++) {
    roles.push({
      name: `ns-role-${i}`,
      scope: 'Namespace',
      namespace: namespaces[i % namespaces.length],
      rules: [{ verbs: ['get', 'list'], apiGroups: [''], resources: ['pods'] }],
      conformanceIssueCount: 0,
      sharedByCount: 0,
      hasPrivilegedSharing: false,
    })
  }
  return roles
}

function makeFakeBindings(subjects: RbacSubject[], roles: RbacRole[]): RbacBinding[] {
  return roles.slice(0, 10).map((r, i) => ({
    name: `binding-${r.name}`,
    scope: r.scope,
    namespace: r.namespace,
    roleRef: r.name,
    subjects: subjects.slice(i * 3, i * 3 + 3),
  }))
}

const FAKE_CLUSTERS: ClusterMeta[] = [{ id: 'demo', name: 'Demo Cluster' }]

function buildFakeCorrelated(): CorrelatedRbac {
  const subjects = makeFakeSubjects()
  const roles = makeFakeRoles()
  const bindings = makeFakeBindings(subjects, roles)
  return {
    cluster: FAKE_CLUSTERS[0],
    namespaces: ['kube-system', 'default', 'apps', 'flux-system', 'monitoring', 'cert-manager', 'ingress-nginx'],
    subjects,
    roles,
    bindings,
    escalations: [
      {
        kind: 'single',
        subject: 'sa_apps_serviceaccount_3',
        subjectDisplay: 'ServiceAccount/apps/serviceaccount-3',
        escalationType: 'admin_via_impersonation',
        riskLevel: 'high',
        riskScore: 48,
        summary: 'ServiceAccount apps/serviceaccount-3 reaches all on * at cluster scope through impersonation.',
      },
    ],
    conformance: [
      { roleName: 'cluster-admin', roleScope: 'Cluster', severity: 'high', reason: 'Contains escalate/bind or wildcard verb' },
      { roleName: 'edit', roleScope: 'Cluster', severity: 'medium', reason: 'Wildcard resource' },
    ],
    sharedRoles: [
      { roleName: 'view', roleScope: 'Cluster', sharedBy: 12, subjects: subjects.slice(0, 5).map(s => `${s.kind}/${s.name}`), privilegedSubjectCount: 0 },
      { roleName: 'cluster-admin', roleScope: 'Cluster', sharedBy: 1, subjects: [`${subjects[0].kind}/${subjects[0].name}`], privilegedSubjectCount: 1 },
    ],
    adminCount: 1,
    nonAdminCount: subjects.length - 1,
  }
}

export default function RbacExplorerPage() {
  const { getAccessTokenSilently } = useAuth0()
  const [clusters, setClusters] = useState<ClusterMeta[]>([])
  const [clusterId, setClusterId] = useState<string>('')
  const [data, setData] = useState<CorrelatedRbac | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [nsFilter, setNsFilter] = useState<string>('all')
  const [showAddCluster, setShowAddCluster] = useState(false)
  const [localClusters, setLocalClusters] = useState<ClusterMeta[]>([])
  /** Which proof consoles are open, keyed `table:index`. */
  const [openProof, setOpenProof] = useState<Record<string, boolean>>({})

  // Per-table filters. Each pair narrows exactly one table and nothing else —
  // in particular not the stat cards, which read the cluster, not the view.
  const [escalationSearch, setEscalationSearch] = useState('')
  const [escalationRisk, setEscalationRisk] = useState('all')
  const [conformanceSearch, setConformanceSearch] = useState('')
  const [conformanceSeverity, setConformanceSeverity] = useState('all')
  const [sharedSearch, setSharedSearch] = useState('')
  const [sharedPrivileged, setSharedPrivileged] = useState('all')
  const [roleSearch, setRoleSearch] = useState('')
  const [roleScope, setRoleScope] = useState('all')
  const [subjectSearch, setSubjectSearch] = useState('')
  const [subjectKind, setSubjectKind] = useState('all')
  const [subjectFlag, setSubjectFlag] = useState('all')

  const demo = isDemoMode()

  const handleAddCluster = (entry: NewClusterEntry) => {
    const id = entry.name.toLowerCase().replace(/[^a-z0-9-]/g, '-')
    setLocalClusters(prev => [...prev, { id, name: entry.name }])
  }

  // In live mode, show only the host cluster (first/local) + locally-added.
  // In demo mode, show all AFM clusters.
  const displayClusters = useMemo(() => {
    if (demo) return clusters
    if (clusters.length === 0) return localClusters
    const host = clusters.find(c => c.id === 'local') ?? clusters[0]
    const hostEntry: ClusterMeta = { id: host.id, name: 'Host Cluster' }
    return [hostEntry, ...localClusters]
  }, [clusters, demo, localClusters])

  // Load clusters on mount. Demo mode never touches the network.
  useEffect(() => {
    if (demo) {
      setClusters(FAKE_CLUSTERS)
      setClusterId(FAKE_CLUSTERS[0].id)
      setLoading(false)
      return
    }

    let cancelled = false
    ;(async () => {
      try {
        const token = await getAccessTokenSilently()
        const list = await fetchRbacClusters(token)
        if (cancelled) return
        setClusters(list)
        setClusterId(list.find(c => c.id === 'local')?.id ?? list[0]?.id ?? '')
      } catch (e) {
        if (cancelled) return
        console.error('[rbac-explorer] failed to list clusters:', e)
        setError(e instanceof Error ? e.message : 'Unable to load RBAC clusters.')
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()

    return () => { cancelled = true }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [demo])

  // Load cluster data when the selected cluster changes.
  const loadCluster = useCallback(async (id: string) => {
    if (!id) return
    setLoading(true)
    setError(null)

    if (demo) {
      setData(buildFakeCorrelated())
      setLoading(false)
      setNsFilter('all')
      return
    }

    // Live mode fetches the real intermediate API and fails visibly on error —
    // it must never silently substitute demo fixtures for a live cluster.
    try {
      const token = await getAccessTokenSilently()
      const correlated = await fetchCorrelatedRbac(token, id)
      setData(correlated)
    } catch (e) {
      console.error('[rbac-explorer] loadCluster failed:', e)
      setData(null)
      setError(e instanceof Error ? e.message : `Unable to load RBAC data for cluster ${id}.`)
    } finally {
      setLoading(false)
      setNsFilter('all')
    }
  }, [demo, getAccessTokenSilently])

  useEffect(() => { if (clusterId) void loadCluster(clusterId) }, [clusterId, loadCluster])

  // Extract namespaces from RBAC data
  const namespaces = useMemo(() => {
    if (!data) return []
    if (data.namespaces.length > 0) return data.namespaces
    const ns = new Set<string>()
    data.roles.forEach(r => { if (r.namespace) ns.add(r.namespace) })
    data.bindings.forEach(b => { if (b.namespace) ns.add(b.namespace) })
    data.subjects.forEach(s => { if (s.namespace) ns.add(s.namespace) })
    return Array.from(ns).sort()
  }, [data])

  // Filter by namespace
  const filteredRoles = useMemo(() => {
    if (!data) return []
    if (nsFilter === 'all') return data.roles
    return data.roles.filter(r => r.scope === 'Cluster' || r.namespace === nsFilter)
  }, [data, nsFilter])

  const filteredBindings = useMemo(() => {
    if (!data) return []
    if (nsFilter === 'all') return data.bindings
    return data.bindings.filter(b => b.scope === 'Cluster' || b.namespace === nsFilter)
  }, [data, nsFilter])

  const filteredSubjects = useMemo(() => {
    if (!data) return []
    if (nsFilter === 'all') return data.subjects
    // Show subjects in the selected namespace + cluster-scoped subjects
    const nsBindingSubjects = new Set<string>()
    filteredBindings.forEach(b => b.subjects.forEach(s => nsBindingSubjects.add(`${s.kind}/${s.name}`)))
    return data.subjects.filter(s => {
      if (s.namespace === nsFilter) return true
      return nsBindingSubjects.has(`${s.kind}/${s.name}`)
    })
  }, [data, nsFilter, filteredBindings])

  const filteredConformance = useMemo(() => {
    if (!data) return []
    if (nsFilter === 'all') return data.conformance
    return data.conformance.filter(c => !c.roleNamespace || c.roleNamespace === nsFilter)
  }, [data, nsFilter])

  // ── Table sources, then table filters ────────────────────────────────────
  // The namespace-filtered arrays above are each table's SOURCE; the toolbar
  // narrows that source further. Both counts are shown, which is what lets a
  // reader tell "the filter hid them" from "there are none".

  // Memoised so the identity is stable: these are dependencies of the filter
  // memos below, and a fresh `[]` every render would defeat all of them.
  const escalationSource = useMemo(() => data?.escalations ?? [], [data])
  const sharedRoleSource = useMemo(() => data?.sharedRoles ?? [], [data])

  const roleRows = useMemo<RoleRow[]>(() => filteredRoles.map(r => {
    const verbs = new Set<string>()
    r.rules.forEach(rule => rule.verbs.forEach(v => verbs.add(v)))
    return { ...r, ruleCount: r.rules.length, verbs: Array.from(verbs) }
  }), [filteredRoles])

  const subjectRows = useMemo<SubjectRow[]>(() => filteredSubjects.map(s => {
    const boundRoles = filteredBindings
      .filter(b => b.subjects.some(bs => bs.name === s.name && bs.kind === s.kind))
      .map(b => b.roleRef)
    const flags = [s.isEscalationActor ? 'escalation' : '', s.isAdmin ? 'admin' : ''].filter(Boolean).join(' ')
    return { ...s, boundRoles, flags }
  }), [filteredSubjects, filteredBindings])

  const escalationRiskOptions = useMemo(
    () => chipOptions(escalationSource, f => f.riskLevel ?? 'unrated'),
    [escalationSource],
  )
  const conformanceSeverityOptions = useMemo(
    () => chipOptions(filteredConformance, c => c.severity ?? 'unrated'),
    [filteredConformance],
  )
  const sharedPrivilegedOptions = useMemo(
    () => chipOptions(sharedRoleSource, sr => (sr.privilegedSubjectCount > 0 ? 'privileged' : 'unprivileged')),
    [sharedRoleSource],
  )
  const roleScopeOptions = useMemo(
    () => chipOptions(roleRows, r => (r.scope === 'Cluster' ? 'cluster' : 'namespace')),
    [roleRows],
  )
  const subjectKindOptions = useMemo(() => chipOptions(subjectRows, s => s.kind), [subjectRows])
  // Not chipOptions: a subject can be admin AND an escalation actor, so these
  // overlap and cannot be produced by partitioning on one key.
  const subjectFlagOptions = useMemo<ChipOption[]>(() => [
    { value: 'all', label: 'all', count: subjectRows.length },
    { value: 'admin', label: 'admin', count: subjectRows.filter(s => s.isAdmin).length },
    { value: 'escalation', label: 'escalation', count: subjectRows.filter(s => s.isEscalationActor).length },
  ], [subjectRows])

  const escalationRows = useMemo(() => {
    const q = escalationSearch.trim().toLowerCase()
    return escalationSource.filter(f => {
      if (escalationRisk !== 'all' && (f.riskLevel ?? 'unrated') !== escalationRisk) return false
      if (!q) return true
      return [f.subjectDisplay, f.subject, f.escalationType, f.kind, f.summary]
        .some(v => v?.toLowerCase().includes(q))
    })
  }, [escalationSource, escalationSearch, escalationRisk])

  const conformanceRows = useMemo(() => {
    const q = conformanceSearch.trim().toLowerCase()
    return filteredConformance.filter(c => {
      if (conformanceSeverity !== 'all' && (c.severity ?? 'unrated') !== conformanceSeverity) return false
      if (!q) return true
      return [c.reason, c.roleName, c.roleNamespace, c.roleScope].some(v => v?.toLowerCase().includes(q))
    })
  }, [filteredConformance, conformanceSearch, conformanceSeverity])

  const sharedRoleRows = useMemo(() => {
    const q = sharedSearch.trim().toLowerCase()
    return sharedRoleSource.filter(sr => {
      const bucket = sr.privilegedSubjectCount > 0 ? 'privileged' : 'unprivileged'
      if (sharedPrivileged !== 'all' && bucket !== sharedPrivileged) return false
      if (!q) return true
      return sr.roleName.toLowerCase().includes(q)
        || sr.subjects.some(s => s.toLowerCase().includes(q))
    })
  }, [sharedRoleSource, sharedSearch, sharedPrivileged])

  const roleTableRows = useMemo(() => {
    const q = roleSearch.trim().toLowerCase()
    return roleRows.filter(r => {
      if (roleScope !== 'all' && (r.scope === 'Cluster' ? 'cluster' : 'namespace') !== roleScope) return false
      if (!q) return true
      return r.name.toLowerCase().includes(q)
        || (r.namespace?.toLowerCase().includes(q) ?? false)
        || r.verbs.some(v => v.toLowerCase().includes(q))
    })
  }, [roleRows, roleSearch, roleScope])

  const subjectTableRows = useMemo(() => {
    const q = subjectSearch.trim().toLowerCase()
    return subjectRows.filter(s => {
      if (subjectKind !== 'all' && s.kind !== subjectKind) return false
      if (subjectFlag === 'admin' && !s.isAdmin) return false
      if (subjectFlag === 'escalation' && !s.isEscalationActor) return false
      if (!q) return true
      return s.name.toLowerCase().includes(q)
        || s.kind.toLowerCase().includes(q)
        || (s.namespace?.toLowerCase().includes(q) ?? false)
        || s.boundRoles.some(r => r.toLowerCase().includes(q))
    })
  }, [subjectRows, subjectSearch, subjectKind, subjectFlag])

  const escalationFiltered = escalationSearch !== '' || escalationRisk !== 'all'
  const conformanceFiltered = conformanceSearch !== '' || conformanceSeverity !== 'all'
  const sharedFiltered = sharedSearch !== '' || sharedPrivileged !== 'all'
  const roleFiltered = roleSearch !== '' || roleScope !== 'all'
  const subjectFiltered = subjectSearch !== '' || subjectKind !== 'all' || subjectFlag !== 'all'

  const clearEscalation = () => { setEscalationSearch(''); setEscalationRisk('all') }
  const clearConformance = () => { setConformanceSearch(''); setConformanceSeverity('all') }
  const clearShared = () => { setSharedSearch(''); setSharedPrivileged('all') }
  const clearRoles = () => { setRoleSearch(''); setRoleScope('all') }
  const clearSubjects = () => { setSubjectSearch(''); setSubjectKind('all'); setSubjectFlag('all') }

  // Stats — from the cluster and the namespace selector only. See the file header.
  const adminCount = data?.adminCount ?? 0
  const nonAdminCount = data?.nonAdminCount ?? 0
  const escalationCount = data?.escalations.length ?? 0
  const clusterName = clusters.find(c => c.id === clusterId)?.name ?? clusterId

  if (loading && clusters.length === 0) {
    return (
      <div style={{ padding: 64, textAlign: 'center', color: 'var(--muted)' }}>
        <LoadingState status="loading" label="KubeSec-AFM connection" testId="rbac-connecting" />
        <p style={{ marginTop: 12 }}>
          <code style={{ fontSize: 12, color: 'var(--cyan)' }}>make demo-k8s-afm-up</code>
        </p>
      </div>
    )
  }

  return (
    <RbacErrorBoundary>
    <div>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 18, flexWrap: 'wrap', gap: 10 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>RBAC Explorer</h1>
          <p style={{ fontSize: 13, color: 'var(--muted)', margin: 0 }}>
            Native view of KubeSec-AFM RBAC analysis — privilege escalation, conformance, and shared-role pivot points
          </p>
        </div>
        <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
          {/* Cluster selector */}
          <select
            value={clusterId}
            onChange={e => setClusterId(e.target.value)}
            style={{ width: 200 }}
            aria-label="Cluster"
            data-testid="cluster-selector"
          >
            {displayClusters.map(c => (
              <option key={c.id} value={c.id}>{c.name} ({c.id})</option>
            ))}
          </select>
          {/* Namespace selector */}
          <select
            value={nsFilter}
            onChange={e => setNsFilter(e.target.value)}
            style={{ width: 180 }}
            aria-label="Namespace"
            data-testid="namespace-selector"
          >
            <option value="all">All namespaces</option>
            {namespaces.map(ns => (
              <option key={ns} value={ns}>{ns}</option>
            ))}
          </select>
          <HelpHint label="What the Namespace filter does" testId="rbac-namespace-help">
            Narrows the tables to one namespace — but cluster-scoped objects stay listed whatever is picked, because a ClusterRole or a ClusterRoleBinding applies in every namespace at once and a namespace boundary does not contain it. Escalation findings are never narrowed: a route that starts in one namespace can end at cluster scope.
          </HelpHint>
          <button
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '5px 12px' }}
            onClick={() => void loadCluster(clusterId)}
          >
            Refresh
          </button>
          <button
            data-testid="add-cluster-btn"
            className="btn btn-secondary"
            style={{
              fontSize: 12, padding: '5px 12px',
              border: '1px solid var(--cyan)',
              color: 'var(--cyan)',
            }}
            onClick={() => setShowAddCluster(true)}
          >
            + Add Cluster
          </button>
        </div>
      </div>

      {loading && <LoadingState variant="block" status="loading" label="RBAC data" testId="rbac-loading" />}

      {/* Live-mode failure — never silently substitutes demo data, and never
          degrades into a table of zeroes. ErrorState owns the 401 branch: a
          401 is not unreachability, the service answered and refused, so Retry
          cannot fix it and is not offered. */}
      {!loading && error && (
        <div data-testid="rbac-live-error">
          <ErrorState message={error} onRetry={() => void loadCluster(clusterId)} />
        </div>
      )}

      {!loading && !error && !data && clusterId && (
        <div data-testid="rbac-no-data">
          <EmptyState
            kicker={`No RBAC data for ${clusterId}`}
            body="KubeSec-AFM answered for this cluster and had nothing to correlate — this is an empty cluster, not an unreachable one. Seed it with scripts/rbac-to-afm.py, then retry."
            tone="cyan"
          />
          <div style={{ textAlign: 'center', marginTop: -34 }}>
            <button className="btn btn-secondary" style={{ fontSize: 12, padding: '4px 10px' }} onClick={() => void loadCluster(clusterId)}>Retry</button>
          </div>
        </div>
      )}

      {!loading && data && (
        <>
          {/* Stats */}
          <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 24 }} data-testid="rbac-stats">
            <StatCard label="Cluster" value={clusterName} sub={`${namespaces.length} namespaces`} accent="var(--cyan)" />
            <StatCard label="Subjects" value={String(filteredSubjects.length)} sub={`${adminCount} admins, ${nonAdminCount} non-admin`} accent="var(--teal)" />
            <StatCard label="Roles" value={String(filteredRoles.length)} sub={`${filteredRoles.filter(r => r.scope === 'Cluster').length} cluster-scoped`} accent="var(--violet)" />
            {/* The one stat where a zero is a security claim, so it carries the
                reason it can be trusted. StatCard has no help slot, hence the
                overlay rather than a prop. */}
            <div style={{ position: 'relative', flex: 1, minWidth: 180, display: 'flex' }}>
              <StatCard
                label="Escalation Paths"
                value={String(escalationCount)}
                sub={escalationCount === 0 ? 'AFM reported none' : 'Requires attention'}
                accent={escalationCount > 0 ? 'var(--error)' : 'var(--teal)'}
              />
              <span style={{ position: 'absolute', top: 14, right: 14 }}>
                <HelpHint label="What Escalation Paths counts" testId="rbac-escalation-stat-help">
                  Counted from the escalation records AFM&rsquo;s Z3 engine returned for this cluster — its single_escalations and group_escalations, correlated server-side. A zero here means AFM answered and reported none: had AFM been unreachable this panel would not be on screen at all, because the page fails visibly instead of reporting zero.
                </HelpHint>
              </span>
            </div>
          </div>

          {/* Escalation findings — correlated server-side from AFM's Z3 engine */}
          {escalationSource.length > 0 && (
            <Section title="Escalation Findings" hint={`${escalationSource.length} findings`}>
              <DataTable
                columns={ESCALATION_COLUMNS}
                data={escalationRows}
                pageSize={20}
                testIdPrefix="rbac-escalations"
                toolbar={
                  <TableToolbar
                    groupLabel="Filter escalation findings"
                    searchLabel="Search escalation findings"
                    placeholder="Search subject, type or detail…"
                    search={escalationSearch}
                    onSearch={setEscalationSearch}
                    searchTestId="rbac-escalations-search"
                    groups={[{
                      label: 'Filter escalation findings by risk level',
                      value: escalationRisk,
                      onChange: setEscalationRisk,
                      options: escalationRiskOptions,
                      testIdPrefix: 'rbac-escalations-risk',
                    }]}
                    shown={escalationRows.length}
                    total={escalationSource.length}
                    countTestId="rbac-escalations-count"
                  />
                }
                emptyState={
                  <TableEmptyState
                    filtered={escalationFiltered}
                    onClear={clearEscalation}
                    kicker="No escalation findings"
                    body="AFM analysed this cluster and reported no privilege-escalation route."
                    clearTestId="rbac-escalations-clear"
                  />
                }
                renderRow={(finding, i) => {
                  const key = `escalation:${i}`
                  const open = openProof[key] === true
                  return (
                  <Fragment key={key}>
                  <tr style={{ borderBottom: open ? undefined : '1px solid var(--border)' }}>
                    <td style={DataTable.td}><code style={{ fontSize: 12, color: 'var(--violet)' }}>{finding.subjectDisplay ?? finding.subject}</code></td>
                    <td style={{ ...DataTable.td, color: 'var(--muted)' }}>{finding.escalationType ?? finding.kind}</td>
                    <td style={DataTable.td}>{finding.riskLevel ? <Pill label={finding.riskLevel} /> : '—'}</td>
                    <td style={{ ...DataTable.td, color: 'var(--muted)', whiteSpace: 'normal', maxWidth: 350 }}>
                      {finding.summary ?? '—'}
                      <div>
                        <button
                          type="button"
                          data-testid={`rbac-escalation-disclose-${i}`}
                          onClick={() => setOpenProof(prev => ({ ...prev, [key]: prev[key] !== true }))}
                          style={proofButton}
                        >
                          {open ? 'Hide proof' : 'How do we know?'}
                        </button>
                      </div>
                    </td>
                  </tr>
                  {open && (
                    <tr style={{ borderBottom: '1px solid var(--border)' }}>
                      <td colSpan={4} style={{ ...DataTable.td, padding: '0 14px 10px', whiteSpace: 'normal' }}>
                        <ProofConsole
                          // The unfiltered array, for the same reason as
                          // conformance below: the command selects on subject
                          // against the whole response, and a toolbar filter
                          // applied on this page changes nothing about what
                          // that command prints.
                          proofs={escalationProofs(finding, escalationSource, clusterId, demo)}
                          testId={`rbac-escalation-console-${i}`}
                        />
                      </td>
                    </tr>
                  )}
                  </Fragment>
                  )
                }}
              />
            </Section>
          )}

          {/* Conformance issues */}
          {filteredConformance.length > 0 && (
            <Section title="Conformance Issues" hint={`${filteredConformance.length} findings`}>
              <DataTable
                columns={CONFORMANCE_COLUMNS}
                data={conformanceRows}
                pageSize={20}
                testIdPrefix="rbac-conformance"
                toolbar={
                  <TableToolbar
                    groupLabel="Filter conformance issues"
                    searchLabel="Search conformance issues"
                    placeholder="Search issue, role or namespace…"
                    search={conformanceSearch}
                    onSearch={setConformanceSearch}
                    searchTestId="rbac-conformance-search"
                    groups={[{
                      label: 'Filter conformance issues by severity',
                      value: conformanceSeverity,
                      onChange: setConformanceSeverity,
                      options: conformanceSeverityOptions,
                      testIdPrefix: 'rbac-conformance-severity',
                    }]}
                    shown={conformanceRows.length}
                    total={filteredConformance.length}
                    countTestId="rbac-conformance-count"
                  />
                }
                emptyState={
                  <TableEmptyState
                    filtered={conformanceFiltered}
                    onClear={clearConformance}
                    kicker="No conformance issues"
                    body="AFM graded every role in view and found none departing from least privilege."
                    clearTestId="rbac-conformance-clear"
                  />
                }
                renderRow={(c, i) => {
                  const key = `conformance:${i}`
                  const open = openProof[key] === true
                  return (
                  <Fragment key={key}>
                  <tr style={{ borderBottom: open ? undefined : '1px solid var(--border)' }}>
                    <td style={{ ...DataTable.td, whiteSpace: 'normal', maxWidth: 300 }}>
                      {c.reason ?? '—'}
                      <div>
                        <button
                          type="button"
                          data-testid={`rbac-conformance-disclose-${i}`}
                          onClick={() => setOpenProof(prev => ({ ...prev, [key]: prev[key] !== true }))}
                          style={proofButton}
                        >
                          {open ? 'Hide proof' : 'How do we know?'}
                        </button>
                      </div>
                    </td>
                    <td style={DataTable.td}><Pill label={c.severity ?? 'info'} /></td>
                    <td style={DataTable.td}><code style={{ fontSize: 12, color: 'var(--violet)' }}>{c.roleName ?? '—'}</code></td>
                    <td style={{ ...DataTable.td, color: 'var(--muted)' }}>{c.roleNamespace ?? 'cluster'}</td>
                  </tr>
                  {open && (
                    <tr style={{ borderBottom: '1px solid var(--border)' }}>
                      <td colSpan={4} style={{ ...DataTable.td, padding: '0 14px 10px', whiteSpace: 'normal' }}>
                        <ProofConsole
                          // The unfiltered array: the command selects on
                          // role_name against the whole response, and a
                          // namespace filter applied on this page changes
                          // nothing about what that command prints.
                          proofs={conformanceProofs(c, data.conformance, clusterId, demo)}
                          testId={`rbac-conformance-console-${i}`}
                        />
                      </td>
                    </tr>
                  )}
                  </Fragment>
                  )
                }}
              />
            </Section>
          )}

          {/* Shared role pivot points */}
          {sharedRoleSource.length > 0 && (
            <Section title="Shared-Role Pivot Points" hint="roles shared by multiple subjects">
              <DataTable
                columns={SHARED_ROLE_COLUMNS}
                data={sharedRoleRows}
                pageSize={15}
                testIdPrefix="rbac-shared"
                toolbar={
                  <TableToolbar
                    groupLabel="Filter shared-role pivot points"
                    searchLabel="Search shared-role pivot points"
                    placeholder="Search role or holder…"
                    search={sharedSearch}
                    onSearch={setSharedSearch}
                    searchTestId="rbac-shared-search"
                    groups={[{
                      label: 'Filter shared roles by whether a holder is already privileged',
                      value: sharedPrivileged,
                      onChange: setSharedPrivileged,
                      options: sharedPrivilegedOptions,
                      testIdPrefix: 'rbac-shared-privileged',
                    }]}
                    shown={sharedRoleRows.length}
                    total={sharedRoleSource.length}
                    countTestId="rbac-shared-count"
                  />
                }
                emptyState={
                  <TableEmptyState
                    filtered={sharedFiltered}
                    onClear={clearShared}
                    kicker="No shared roles"
                    body="No role in this cluster is held by more than one subject."
                    clearTestId="rbac-shared-clear"
                  />
                }
                renderRow={(sr, i) => (
                  <tr key={`${sr.roleName}-${i}`} style={{ borderBottom: '1px solid var(--border)' }}>
                    <td style={DataTable.td}><code style={{ color: 'var(--violet)', fontSize: 12 }}>{sr.roleName}</code></td>
                    <td style={{ ...DataTable.td, color: 'var(--muted)' }}>{sr.sharedBy} subjects</td>
                    <td style={DataTable.td}>{sr.privilegedSubjectCount > 0 ? <Pill label={`${sr.privilegedSubjectCount} privileged`} /> : '—'}</td>
                  </tr>
                )}
              />
            </Section>
          )}

          {/* Roles table */}
          <Section title="Roles" hint={`${nsFilter === 'all' ? 'all namespaces' : nsFilter} · ${filteredRoles.length} roles`}>
            <DataTable
              columns={ROLE_COLUMNS}
              data={roleTableRows}
              pageSize={30}
              testIdPrefix="rbac-roles"
              toolbar={
                <TableToolbar
                  groupLabel="Filter roles"
                  searchLabel="Search roles"
                  placeholder="Search name, namespace or verb…"
                  search={roleSearch}
                  onSearch={setRoleSearch}
                  searchTestId="rbac-roles-search"
                  groups={[{
                    label: 'Filter roles by scope',
                    value: roleScope,
                    onChange: setRoleScope,
                    options: roleScopeOptions,
                    testIdPrefix: 'rbac-roles-scope',
                  }]}
                  shown={roleTableRows.length}
                  total={roleRows.length}
                  countTestId="rbac-roles-count"
                />
              }
              emptyState={
                <TableEmptyState
                  filtered={roleFiltered}
                  onClear={clearRoles}
                  kicker="No roles in view"
                  body="The correlated response carried no Role or ClusterRole for this namespace selection."
                  clearTestId="rbac-roles-clear"
                />
              }
              renderRow={(r, i) => {
                const hasDangerous = DANGEROUS_VERBS.some(v => r.verbs.includes(v) || r.verbs.includes('*'))
                return (
                  <tr key={`${r.name}-${r.namespace}-${i}`} style={{ borderBottom: '1px solid var(--border)' }}>
                    <td style={{ ...DataTable.td, fontWeight: 500 }}>{r.name}</td>
                    <td style={DataTable.td}><Pill label={r.scope === 'Cluster' ? 'cluster' : 'namespace'} /></td>
                    <td style={{ ...DataTable.td, color: 'var(--muted)' }}>{r.namespace ?? '—'}</td>
                    <td style={{ ...DataTable.td, color: 'var(--muted)' }}>{r.ruleCount}</td>
                    <td style={DataTable.td}>
                      <div style={{ display: 'flex', gap: 3, flexWrap: 'wrap' }}>
                        {r.verbs.slice(0, 6).map(v => {
                          // `${colors.red}20` was DashKit.hex()'s bug open-coded:
                          // colors.red has been `var(--error)` since the palette
                          // moved to tokens, so the concatenation produced
                          // `var(--error)20` — not a colour, silently dropped by
                          // every browser. The red verbs have been rendering
                          // with NO fill at all, while the Verbs help hint on
                          // this very table tells the reader red means dangerous.
                          // StatusBadge.tint is the working pattern (color-mix).
                          const dangerous = hasDangerous && DANGEROUS_VERBS.includes(v)
                          return (
                          <span key={v} style={{
                            fontSize: 10, padding: '1px 5px', borderRadius: 3,
                            background: dangerous ? tint('var(--error)', 0.12) : 'var(--surface2)',
                            color: dangerous ? 'var(--error)' : 'var(--muted)',
                            fontFamily: 'monospace',
                          }}>{v}</span>
                          )
                        })}
                        {r.verbs.length > 6 && <span style={{ fontSize: 10, color: 'var(--muted)' }}>+{r.verbs.length - 6}</span>}
                      </div>
                    </td>
                    <td style={DataTable.td}>
                      <div style={{ display: 'flex', gap: 4 }}>
                        {r.conformanceIssueCount > 0 && <Pill label={`${r.conformanceIssueCount} conformance`} />}
                        {r.hasPrivilegedSharing && <Pill label="privileged sharing" />}
                      </div>
                    </td>
                  </tr>
                )
              }}
            />
          </Section>

          {/* Subjects table */}
          <Section title="Subjects" hint={`${filteredSubjects.length} subjects`}>
            <DataTable
              columns={SUBJECT_COLUMNS}
              data={subjectTableRows}
              pageSize={30}
              testIdPrefix="subjects"
              toolbar={
                <TableToolbar
                  groupLabel="Filter subjects"
                  searchLabel="Search subjects"
                  placeholder="Search name, namespace or bound role…"
                  search={subjectSearch}
                  onSearch={setSubjectSearch}
                  searchTestId="subjects-search"
                  groups={[
                    {
                      label: 'Filter subjects by kind',
                      value: subjectKind,
                      onChange: setSubjectKind,
                      options: subjectKindOptions,
                      testIdPrefix: 'subjects-kind',
                    },
                    {
                      label: 'Filter subjects by flag',
                      value: subjectFlag,
                      onChange: setSubjectFlag,
                      options: subjectFlagOptions,
                      testIdPrefix: 'subjects-flag',
                    },
                  ]}
                  shown={subjectTableRows.length}
                  total={subjectRows.length}
                  countTestId="subjects-count"
                />
              }
              emptyState={
                <TableEmptyState
                  filtered={subjectFiltered}
                  onClear={clearSubjects}
                  kicker="No subjects in view"
                  body="The correlated response carried no ServiceAccount, User or Group for this namespace selection."
                  clearTestId="subjects-clear"
                />
              }
              renderRow={(s, i) => (
                <tr key={`${s.kind}-${s.name}-${s.namespace}-${i}`} style={{ borderBottom: '1px solid var(--border)' }}>
                  <td style={{ ...DataTable.td, fontWeight: 500 }}>{s.name}</td>
                  <td style={DataTable.td}><Pill label={s.kind.toLowerCase()} /></td>
                  <td style={{ ...DataTable.td, color: 'var(--muted)' }}>{s.namespace ?? '—'}</td>
                  <td style={DataTable.td}>
                    <div style={{ display: 'flex', gap: 3, flexWrap: 'wrap' }}>
                      {s.boundRoles.slice(0, 4).map((r, j) => (
                        <code key={j} style={{ fontSize: 11, color: 'var(--cyan)' }}>{r}</code>
                      ))}
                      {s.boundRoles.length > 4 && <span style={{ fontSize: 10, color: 'var(--muted)' }}>+{s.boundRoles.length - 4}</span>}
                    </div>
                  </td>
                  <td style={DataTable.td}>
                    <div style={{ display: 'flex', gap: 4 }}>
                      {s.isEscalationActor && <Pill label="escalation" />}
                      {s.isAdmin && <Pill label="admin" />}
                    </div>
                  </td>
                </tr>
              )}
            />
          </Section>
        </>
      )}
      {showAddCluster && (
        <AddClusterModal
          onAdd={handleAddCluster}
          onClose={() => setShowAddCluster(false)}
        />
      )}
    </div>
    </RbacErrorBoundary>
  )
}
