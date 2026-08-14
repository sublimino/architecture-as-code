/**
 * Collusion & Access — ControlPlane KubeSec-AFM (KTP with King's College London).
 *
 * KubeSec-AFM is a formal-methods engine that model-checks Kubernetes RBAC for
 * privilege escalation and *collusion* — groups of subjects (users / service
 * accounts) that can exchange permissions to reach a goal role. It runs bounded
 * model checking over cluster-scoped resources, namespaces, roles and bindings,
 * and every fix it proposes ships as a downloadable TraceGuard.
 *
 * This page used to render four tables of hardcoded mock data with no fetch
 * call at all, so "demo" and "live" were visually identical by construction —
 * that was the bug. It now has a run selector backed by real data.
 *
 * The selector offers the same three altitudes the rest of the KubeSec-AFM
 * surfaces do, so the same results are reachable from here:
 *
 *   - "All runs (aggregate)"  — cross-cluster rollup;
 *   - one entry per CLUSTER   — that cluster's latest completed analysis. This
 *     is the selection the KTP/AFM dashboard (RBAC Analysis) and RBAC Explorer
 *     both offer, and its absence here is why a cluster visible on those pages
 *     could not be inspected on this one: a cluster with analysis results but
 *     no stored job history contributed to the aggregate and appeared nowhere
 *     in the dropdown;
 *   - one entry per RUN       — drill into a specific historical job.
 *
 * Demo mode renders two fixed, offline runs (afmDemoFixtures.ts) through the
 * same three altitudes. Live mode calls the real KubeSec-AFM API (afmApi.ts)
 * and fails visibly — never falls back to demo data — when it is unreachable.
 *
 * Every claim on the page carries its source. The "How do we know?" buttons
 * open the shared ProofConsole with the literal command that returns the row's
 * source object, and what the page actually received back. Proofs are built
 * from data this page already holds; nothing is asserted that was not fetched.
 *
 * ── The four tables ────────────────────────────────────────────────────────
 *
 * All four are now `DataTable` — the shared component — rather than DashKit's
 * `Table`, which is a `thead`/`tbody` wrapper and nothing else. What that buys,
 * and why each part of it is worth having on THIS page specifically:
 *
 *   - SORTING. The aggregate flattens every cluster into one list in whatever
 *     order the clusters were discovered, so "show me the critical findings
 *     first" was previously a manual scan. Risk is the column that matters and
 *     it is one click away.
 *   - PAGINATION. A real cluster's escalation count is not two. The demo
 *     fixtures fit on one page and the pager hides itself; a live rollup will
 *     not, and the page should not have to grow a scroll region for it.
 *   - THE TOOLBAR SLOT. Each table carries a search box and a facet chip row,
 *     and the page — not DataTable — owns the predicate. See `narrow` below.
 *     The slot's real value is stated in DataTable's own header: a hand-rolled
 *     `rows.length ? <Table/> : <Empty/>` ternary takes the filter control down
 *     with the table, stranding the operator with a filter they cannot clear.
 *     Passing `toolbar` and `emptyState` together makes that unbuildable, and
 *     the empty branch here carries a "Clear filters" button as well.
 *
 * Row keys are the finding's index in the UNFILTERED array, not its position in
 * whatever the sort and the filter left. A proof console is addressed by that
 * key, and keying off the rendered position would open the third row's proof
 * under the first row the moment anyone sorted the table.
 */
import { useCallback, useEffect, useMemo, useState, type CSSProperties, type ReactNode } from 'react'
import { StatCard, Section, Pill } from '../components/DashKit'
import DataTable, { type Column } from '../components/DataTable'
import EmptyState from '../components/EmptyState'
import LoadingState from '../components/LoadingState'
import HelpHint from '../components/HelpHint'
import { ProofConsole, type Proof } from '../components/ProofConsole'
import { isDemoMode, subscribeDemoMode } from '../api/demoMode'
import {
  fetchAnalysisStatus,
  fetchClusterJobs,
  fetchGuards,
  fetchJobResult,
  fetchJsonOrThrow,
  fetchAnalysisResult,
  fetchSharedRoles,
  parseClusterList,
  type ClusterMeta,
  type Guard,
  type GroupEscalation,
  type SharedRoleEntry,
  type SingleEscalation,
} from '../api/afmApi'
import { DEMO_RUNS, type DemoRun } from '../api/afmDemoFixtures'

const AGGREGATE_ID = 'aggregate'
/** Distinguishes a cluster selection from a job id, which is an opaque string. */
const CLUSTER_PREFIX = 'cluster:'
const DEMO_FIXTURE_PATH = 'd2-signalloom/apps/dashboard-signalloom/src/api/afmDemoFixtures.ts'

/** The unfiltered facet. A literal so the chip row and the predicate cannot disagree. */
const ALL_FACET = 'all'

/** Rows per page, the same on all four tables — see the header note on uniformity. */
const PAGE_SIZE = 10

const PHASES = [
  { n: 'Phase 1', title: 'Admin & self-escalation removal', body: 'Drop subjects who are already cluster-admin or can self-escalate via the escalate verb — they have no incentive to collude.' },
  { n: 'Phase 1.5', title: 'Impersonation check', body: 'Test escalation through impersonation, including a group impersonating a service account in another namespace (unscoped pre-1.36).' },
  { n: 'Phase 2', title: 'Collusion escalation', body: 'Model-check whether pairs of subjects can exchange permissions to jointly reach a higher-privileged role.' },
]

/** One row in the run-selector's "Run history" group. */
interface RunOption {
  id: string
  clusterId: string
  clusterName: string
  createdAt: string
  outcome: string
}

/**
 * A finding plus the proof of where it came from.
 *
 * Carried per finding, not per view: the aggregate flattens several clusters
 * into one table, and a single view-level "here is the endpoint" would name
 * the wrong cluster for most of the rows in it.
 */
interface Sourced<T> {
  finding: T
  proofs: Proof[]
}

/** Whatever is currently rendered below the selector — a run, a cluster, or the aggregate rollup. */
interface RunView {
  label: string
  clusterName: string
  timestampLabel: string
  subjects: string[]
  singleEscalations: Sourced<SingleEscalation>[]
  groupEscalations: Sourced<GroupEscalation>[]
  sharedRoles: SharedRoleEntry[]
  sharedRolesProofs: Proof[]
  guards: Guard[]
  guardsProofs: Proof[]
  guardsCaption: string
  /** How this whole view was assembled — the data path, not any one row. */
  provenanceProofs: Proof[]
}

function formatTimestamp(iso: string): string {
  const parsed = new Date(iso)
  if (Number.isNaN(parsed.getTime())) return iso
  // Fixed, locale-independent formatting — avoids CI/test-runner locale drift.
  return parsed.toISOString().slice(0, 16).replace('T', ' ')
}

function permissionLabel(p: { verb: string; resource: string; namespace: string }): string {
  const scope = p.namespace && p.namespace !== 'cluster' ? ` (ns=${p.namespace})` : ''
  return `${p.verb || '*'} ${p.resource || '*'}${scope}`
}

function riskLevel(risk: { level?: string } | null): string {
  return risk?.level ?? 'unknown'
}

// ── Proof bodies ──────────────────────────────────────────────────────────
// These print the finding's own fields and nothing else. Every line is a value
// the page received and rendered; none of it is re-derived, inferred or filled
// in. `risk.reason` is AFM's own sentence about why the path exists, which is
// the closest thing the engine gives us to a trace, so it is always shown —
// including when it is absent, which is itself worth knowing.

function singleDetail(e: SingleEscalation): string {
  return [
    `subject:           ${e.subject}`,
    `escalation_type:   ${e.escalationType}`,
    `scope:             ${e.scope}`,
    `gained_permission: ${permissionLabel(e.gainedPermission)}`,
    `risk.level:        ${riskLevel(e.risk)}`,
    `risk.reason:       ${e.risk?.reason ?? '(none reported by AFM)'}`,
  ].join('\n')
}

function groupDetail(g: GroupEscalation): string {
  return [
    `group:             ${g.group.join(', ') || '(empty)'}`,
    `primary_actor:     ${g.primaryActor}`,
    `scope:             ${g.scope}`,
    `primary_gain:      ${permissionLabel(g.primaryGain)}`,
    ...(g.collaboratorGains.length > 0
      ? g.collaboratorGains.map(c => `collaborator_gain: ${c.subject} → ${permissionLabel(c.permission)}`)
      : ['collaborator_gain: (none reported)']),
    `risk.level:        ${riskLevel(g.risk)}`,
    `risk.reason:       ${g.risk?.reason ?? '(none reported by AFM)'}`,
  ].join('\n')
}

function sharedRoleLines(entries: SharedRoleEntry[]): string {
  if (entries.length === 0) return '(no shared-role pivots returned)'
  return entries
    .map(p => `${p.role} — shared by ${p.sharedBy}, privileged: ${p.privilegedSubjects.join(', ') || 'none'}`)
    .join('\n')
}

function guardLines(guards: Guard[]): string {
  if (guards.length === 0) return '(no TraceGuards returned)'
  return guards
    .map(g => `${g.name} [${g.kind}] participants: ${g.participants.join(', ') || 'none'} — would_block: ${g.wouldBlock}`)
    .join('\n')
}

// ── Demo proofs ───────────────────────────────────────────────────────────
// Demo mode makes no network call, so there is no command output to show. What
// it can honestly offer is the file the figures come from and a statement that
// nothing was measured — the same disclosure the Credential Inventory page
// makes for its demo path.

const DEMO_SOURCE_PROOF: Proof = {
  label: 'Data source',
  command: 'localStorage.getItem("demoMode")   // ?demo=1 sets this',
  detail: 'Demo mode is on, so no KubeSec-AFM call was made. Every figure on this page is a fixture '
    + `in ${DEMO_FIXTURE_PATH} — nothing here was measured.`,
}

function demoProof(run: DemoRun, body: string): Proof {
  return {
    label: run.clusterName,
    command: `rg -n "id: '${run.id}'" -A 60 ${DEMO_FIXTURE_PATH}`,
    detail: `Demo mode — fixture for run ${run.id}, not a measurement:\n${body}`,
  }
}

/**
 * Build a view from one or more demo runs.
 *
 * Findings keep their originating run so the aggregate's proofs still name the
 * right fixture per row, which a flattened DEMO_AGGREGATE could not do.
 */
function demoView(runs: DemoRun[], label: string, clusterName: string, timestampLabel: string): RunView {
  return {
    label,
    clusterName,
    timestampLabel,
    subjects: Array.from(new Set(runs.flatMap(r => r.analysis.subjects))),
    singleEscalations: runs.flatMap(run =>
      run.analysis.singleEscalations.map((finding, i) => ({
        finding,
        proofs: [demoProof(run, `single_escalations[${i}]\n${singleDetail(finding)}`)],
      }))),
    groupEscalations: runs.flatMap(run =>
      run.analysis.groupEscalations.map((finding, i) => ({
        finding,
        proofs: [demoProof(run, `group_escalations[${i}]\n${groupDetail(finding)}`)],
      }))),
    sharedRoles: runs.flatMap(r => r.sharedRoles),
    sharedRolesProofs: runs.map(run => demoProof(run, sharedRoleLines(run.sharedRoles))),
    guards: runs.flatMap(r => r.guards),
    guardsProofs: runs.map(run => demoProof(run, guardLines(run.guards))),
    guardsCaption: 'Fixed offline demo data.',
    provenanceProofs: [
      DEMO_SOURCE_PROOF,
      ...runs.map(run => demoProof(run, [
        `cluster:            ${run.clusterName} (${run.clusterId})`,
        `created_at:         ${run.createdAt}`,
        `single_escalations: ${run.analysis.singleEscalations.length}`,
        `group_escalations:  ${run.analysis.groupEscalations.length}`,
        `shared_roles:       ${run.sharedRoles.length}`,
        `guards:             ${run.guards.length}`,
      ].join('\n'))),
    ],
  }
}

// ── Live proofs ───────────────────────────────────────────────────────────
// The command is the endpoint this page actually fetched, with a jq selector
// that narrows the body to the row in question. The detail is what came back
// for that row — no interpretation added.

function analysisUrl(clusterId: string): string {
  return `/afm/clusters/${encodeURIComponent(clusterId)}/analysis/latest`
}

function jobResultUrl(jobId: string): string {
  return `/afm/jobs/${encodeURIComponent(jobId)}/result`
}

function sharedRolesUrl(clusterId: string): string {
  return `/afm/clusters/${encodeURIComponent(clusterId)}/analysis/shared_roles`
}

function guardsUrl(clusterId: string): string {
  return `/afm/clusters/${encodeURIComponent(clusterId)}/analysis/guards`
}

function liveSingles(endpoint: string, clusterName: string, list: SingleEscalation[]): Sourced<SingleEscalation>[] {
  return list.map((finding, i) => ({
    finding,
    proofs: [{
      label: clusterName,
      command: `curl -s ${endpoint} | jq '.single_escalations[${i}]'`,
      detail: `KubeSec-AFM returned this finding for ${clusterName}:\n${singleDetail(finding)}`,
    }],
  }))
}

function liveGroups(endpoint: string, clusterName: string, list: GroupEscalation[]): Sourced<GroupEscalation>[] {
  return list.map((finding, i) => ({
    finding,
    proofs: [{
      label: clusterName,
      command: `curl -s ${endpoint} | jq '.group_escalations[${i}]'`,
      detail: `KubeSec-AFM returned this finding for ${clusterName}:\n${groupDetail(finding)}`,
    }],
  }))
}

function liveSharedRolesProof(clusterId: string, clusterName: string, entries: SharedRoleEntry[]): Proof {
  return {
    label: clusterName,
    command: `curl -s ${sharedRolesUrl(clusterId)} | jq '.results'`,
    detail: sharedRoleLines(entries),
  }
}

function liveGuardsProof(clusterId: string, clusterName: string, guards: Guard[]): Proof {
  return {
    label: clusterName,
    command: `curl -s ${guardsUrl(clusterId)} | jq '.guards'`,
    detail: guardLines(guards),
  }
}

// ── Table rows ────────────────────────────────────────────────────────────
//
// DataTable sorts by `item[column.key]`, so each row is FLAT: the columns it
// can sort on are primitives sitting directly on the row, and anything the
// cell needs but nobody sorts by (the proofs) rides alongside. The alternative
// — handing it `Sourced<SingleEscalation>` — gives it two keys, `finding` and
// `proofs`, and sorting by either is meaningless.
//
// These are PRESENTATION shapes. Every field is a string this page already
// rendered, produced by the same helper it already used; no figure is derived,
// combined or re-ordered on the way in.

interface SingleRow {
  /** Index in the unfiltered array. Addresses the proof console — see the header. */
  key: string
  subject: string
  escalationType: string
  scope: string
  gained: string
  risk: string
  proofs: Proof[]
}

interface GroupRow {
  key: string
  group: string
  primaryActor: string
  primaryGain: string
  collaboratorGains: string
  risk: string
  proofs: Proof[]
}

interface PivotRow {
  key: string
  role: string
  /** Numeric so the column sorts by size rather than by the string "10" < "4". */
  sharedBy: number
  sharedByLabel: string
  privileged: string
  risk: string
}

interface GuardRow {
  key: string
  name: string
  kind: string
  participants: string
  wouldBlock: string
}

// ── Filtering ─────────────────────────────────────────────────────────────
//
// The predicate lives here, not in DataTable, and that division is the point
// DataTable's own header makes: what differs between a filtered table and a
// plain one is the predicate, and the predicate is the one part that can never
// be shared. Each table below names the fields its search box looks at.

/** A chip in a facet row: the value, what it reads as, and how many rows carry it. */
interface Facet {
  value: string
  label: string
  count: number
}

function narrow<T>(
  rows: T[],
  search: string,
  facet: string,
  fields: (row: T) => string[],
  facetOf: (row: T) => string,
): T[] {
  const q = search.trim().toLowerCase()
  return rows.filter(row => {
    if (facet !== ALL_FACET && facetOf(row) !== facet) return false
    if (q === '') return true
    return fields(row).some(field => field.toLowerCase().includes(q))
  })
}

/**
 * Worst first, and only the levels that occur.
 *
 * Derived from the rows rather than declared, so a level AFM invents tomorrow
 * gets a chip instead of being silently unfilterable — and a level absent from
 * this run does not get a chip that always reads zero. `RISK_ORDER` puts the
 * ones we do know in severity order; anything unrecognised sorts after them,
 * alphabetically, rather than being dropped.
 */
const RISK_ORDER = ['critical', 'high', 'medium', 'low', 'unknown']

function severityRank(value: string): number {
  const at = RISK_ORDER.indexOf(value)
  return at === -1 ? RISK_ORDER.length : at
}

function facetsOf<T>(rows: T[], facetOf: (row: T) => string, rank: (value: string) => number): Facet[] {
  const counts = new Map<string, number>()
  rows.forEach(row => {
    const value = facetOf(row)
    counts.set(value, (counts.get(value) ?? 0) + 1)
  })
  const values = Array.from(counts.keys())
    .sort((a, b) => rank(a) - rank(b) || a.localeCompare(b))
  return [
    { value: ALL_FACET, label: ALL_FACET, count: rows.length },
    ...values.map(value => ({ value, label: value, count: counts.get(value) ?? 0 })),
  ]
}

/** Facets with no severity meaning — guard kinds — sort alphabetically. */
function flatRank(): number {
  return 0
}

// ── Filter chrome ─────────────────────────────────────────────────────────
//
// One strip, four tables, identical markup. Ten pages are being migrated in
// parallel and a filter that looks slightly different on each of them is the
// thing that makes a product read as four products, so the shape here is
// copied from the Design System's "Realistic — the shape AgentsPage needs"
// specimen rather than invented.
//
// The selected chip is a TINTED FILL plus a full-strength border, never a solid
// accent fill: text on solid cyan or amber fails AA in at least one of Dark,
// Light and Andy, and the same reasoning is written out on the specimen.
//
// ONE DELIBERATE DEPARTURE FROM THE SPECIMEN, measured rather than preferred.
// The specimen renders the facet label and the per-chip count in `--dim`. That
// is 3.07:1 on `--surface2` in Dark, and 2.51:1 once the selected chip's cyan
// tint is underneath it — an AA failure on the digit that is the entire reason
// the chip is worth pressing. `--muted` is the same grey family at the same
// visual weight, and its worst case across Dark, Light and Andy and across both
// chip states is 4.66:1. Two shades of grey apart; one of them is legible.
//
// The specimen carries the same defect, so this wants fixing there rather than
// in ten pages independently — raised with the lead rather than patched into a
// shared component mid-migration.

const searchInputStyle: CSSProperties = {
  fontSize: 12,
  padding: '5px 9px',
  minWidth: 230,
  color: 'var(--text)',
  background: 'var(--surface2)',
  border: '1px solid var(--border)',
  borderRadius: 4,
}

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

function FilterStrip({
  id,
  subject,
  placeholder,
  search,
  onSearch,
  facetLabel,
  facets,
  facet,
  onFacet,
  shown,
  total,
  hint,
}: {
  id: string
  /**
   * What this strip filters, in the plural — "escalation paths".
   *
   * One noun, two names: the strip is "Filter escalation paths" and the box
   * inside it is "Search escalation paths". Giving both the same name puts two
   * differently-shaped controls under one utterance for a speech-input user.
   */
  subject: string
  placeholder: string
  search: string
  onSearch: (next: string) => void
  facetLabel: string
  facets: Facet[]
  facet: string
  onFacet: (next: string) => void
  shown: number
  total: number
  /** What the facet column actually means, where the chip labels alone do not say it. */
  hint?: string
}) {
  return (
    <div
      style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8 }}
      role="group"
      aria-label={`Filter ${subject}`}
    >
      <input
        type="search"
        aria-label={`Search ${subject}`}
        placeholder={placeholder}
        value={search}
        onChange={event => onSearch(event.target.value)}
        data-testid={`${id}-search`}
        style={searchInputStyle}
      />
      <span style={{ fontSize: 11.5, color: 'var(--muted)' }}>{facetLabel}</span>
      {hint && (
        <HelpHint label={`What ${facetLabel} means`} testId={`${id}-facet-help`}>
          {hint}
        </HelpHint>
      )}
      {facets.map(option => {
        const selected = facet === option.value
        return (
          <button
            key={option.value}
            type="button"
            onClick={() => onFacet(option.value)}
            aria-pressed={selected}
            data-testid={`${id}-filter-${option.value}`}
            style={chipStyle(selected)}
          >
            {option.label} <span style={{ color: 'var(--muted)' }}>{option.count}</span>
          </button>
        )
      })}
      <span data-testid={`${id}-count`} style={{ fontSize: 11.5, color: 'var(--muted)' }}>
        {shown} of {total} shown
      </span>
    </div>
  )
}

/**
 * How far up into EmptyState's own bottom padding the Clear button sits.
 *
 * EmptyState is a centred panel with `padding: 60px 24px` and no action slot,
 * so a button appended after it lands 60px below the sentence it answers and
 * reads as belonging to the next thing on the page. This pulls it back to
 * roughly the panel's internal gap. It is a deliberate coupling to a number in
 * EmptyState.tsx; the clean fix is an action slot on EmptyState itself, which
 * is a shared component and not this page's to change.
 */
const EMPTY_ACTION_PULL_UP = -32

/**
 * The panel a filter that matched nothing leaves behind.
 *
 * The way back sits beside EmptyState rather than inside it. That button is not
 * a convenience: the toolbar above stays mounted (DataTable guarantees that
 * much), but clearing two controls to undo one mistake is a worse answer than
 * clearing both at once, from where the mistake is visible.
 */
function FilteredEmpty({ id, onClear }: { id: string; onClear: () => void }) {
  return (
    <div data-testid={`${id}-filtered-empty`}>
      <EmptyState
        kicker="Nothing matches these filters"
        body="Every finding in this run is still here — the search box or the chip above is hiding them."
      />
      <div style={{ display: 'flex', justifyContent: 'center', marginTop: EMPTY_ACTION_PULL_UP, marginBottom: 12 }}>
        <button
          type="button"
          className="btn btn-secondary"
          onClick={onClear}
          data-testid={`${id}-clear-filters`}
          style={{ fontSize: 12, padding: '5px 12px' }}
        >
          Clear filters
        </button>
      </div>
    </div>
  )
}

/** The honest zero: the run really did report nothing here. Not a filter artefact. */
function NoFindings({ testId, kicker, body }: { testId: string; kicker: string; body: string }) {
  return (
    <div data-testid={testId}>
      <EmptyState kicker={kicker} body={body} />
    </div>
  )
}

// ── Columns ───────────────────────────────────────────────────────────────
//
// `help` is set only where the header does not already say it — DataTable's
// own note on the prop, and the rule that keeps a "?" from becoming furniture.
// The bar used here: would a competent engineer who has never met KubeSec-AFM
// read this header and know what the cell under it is claiming? "Subject" and
// "Role" pass. "Scope", "Primary gain" and "Shared by" do not.

const SINGLE_COLUMNS: Column<SingleRow>[] = [
  {
    key: 'subject',
    label: 'Subject',
    sortable: true,
    help: 'The identity the escalation belongs to — a user, a group, or a service account, in AFM\'s kind:namespace/name notation.',
  },
  {
    key: 'escalationType',
    label: 'Escalation type',
    sortable: true,
    help: 'Which mechanism AFM proved reaches the higher privilege: binding creation, the escalate verb, impersonation, and so on.',
  },
  {
    key: 'scope',
    label: 'Scope',
    sortable: true,
    help: 'How far the gained privilege reaches. Cluster-wide is every namespace at once; a namespace scope is confined to that one.',
  },
  {
    key: 'gained',
    label: 'Gained permission',
    sortable: true,
    help: 'The verb and resource the subject ends up holding that it was never granted — the actual prize at the end of the path.',
  },
  {
    key: 'risk',
    label: 'Risk',
    sortable: true,
    help: 'AFM\'s own severity for the path. Sorts worst-first on the first click, so the findings that matter surface without a scan.',
  },
  {
    key: 'proofs',
    label: 'Proof',
    help: 'Opens the literal command that returns this row\'s source object, and what the page received back. Nothing here is asserted that was not fetched.',
  },
]

const GROUP_COLUMNS: Column<GroupRow>[] = [
  {
    key: 'group',
    label: 'Group',
    sortable: true,
    help: 'The set of subjects that must cooperate. Neither of them can reach the goal role alone — that is what makes this collusion rather than an escalation path.',
  },
  {
    key: 'primaryActor',
    label: 'Primary actor',
    sortable: true,
    help: 'The subject that ends up holding the escalated privilege. The rest of the group supplies permissions it does not keep.',
  },
  {
    key: 'primaryGain',
    label: 'Primary gain',
    sortable: true,
    help: 'What the primary actor walks away with once the group has exchanged permissions.',
  },
  {
    key: 'collaboratorGains',
    label: 'Collaborator gains',
    help: 'What each of the other subjects picks up along the way. Often nothing — a collaborator can be useful without profiting.',
  },
  {
    key: 'risk',
    label: 'Risk',
    sortable: true,
    help: 'AFM\'s own severity for the joint path, scored on what the group reaches together rather than on any one member.',
  },
  {
    key: 'proofs',
    label: 'Proof',
    help: 'Opens the literal command that returns this row\'s source object, and what the page received back. Nothing here is asserted that was not fetched.',
  },
]

const PIVOT_COLUMNS: Column<PivotRow>[] = [
  {
    key: 'role',
    label: 'Role',
    sortable: true,
    help: 'The role two or more subjects both hold. It is the shared surface through which permissions can move between them.',
  },
  {
    key: 'sharedBy',
    label: 'Shared by',
    sortable: true,
    help: 'How many subjects hold this role. The more of them there are, the more pairs of colluders it can connect.',
  },
  {
    key: 'privileged',
    label: 'Privileged subjects',
    sortable: true,
    help: 'Which of the sharers already hold elevated privilege. A pivot with none of them is a shared role; a pivot with one is a route to it.',
  },
  {
    key: 'risk',
    label: 'Risk',
    sortable: true,
    help: 'Derived on this page, not returned by AFM: high when at least one sharer is privileged, low when none is.',
  },
]

const GUARD_COLUMNS: Column<GuardRow>[] = [
  {
    key: 'name',
    label: 'Fix',
    sortable: true,
    help: 'A TraceGuard — the RBAC change AFM proposes, generated from the trace it proved rather than from a rule of thumb.',
  },
  {
    key: 'kind',
    label: 'Kind',
    sortable: true,
    help: 'Whether the guard closes a single-subject escalation or a collusion path involving several.',
  },
  {
    key: 'participants',
    label: 'Participants',
    sortable: true,
    help: 'The subjects on the path this fix cuts. Applying it changes what these identities can do.',
  },
  {
    key: 'wouldBlock',
    label: 'Would block',
    sortable: true,
    help: 'Whether AFM re-ran the model check with this guard applied and confirmed the path closes. Pending means it has not been verified.',
  },
]

export default function CollusionAccessPage() {
  const [demo, setDemo] = useState(isDemoMode())
  const [clusters, setClusters] = useState<ClusterMeta[]>([])
  const [runOptions, setRunOptions] = useState<RunOption[]>([])
  const [selectedRunId, setSelectedRunId] = useState<string>(AGGREGATE_ID)
  const [view, setView] = useState<RunView | null>(null)
  const [fatalError, setFatalError] = useState<string | null>(null)
  const [runError, setRunError] = useState<string | null>(null)
  const [isLoadingList, setIsLoadingList] = useState(false)
  const [isLoadingView, setIsLoadingView] = useState(false)
  const [openProof, setOpenProof] = useState<Record<string, boolean>>({})

  // Per-table filter state. Four tables, one search + one facet each; the
  // predicate for every one of them is `narrow` below.
  const [singleSearch, setSingleSearch] = useState('')
  const [singleRisk, setSingleRisk] = useState(ALL_FACET)
  const [groupSearch, setGroupSearch] = useState('')
  const [groupRisk, setGroupRisk] = useState(ALL_FACET)
  const [pivotSearch, setPivotSearch] = useState('')
  const [pivotRisk, setPivotRisk] = useState(ALL_FACET)
  const [guardSearch, setGuardSearch] = useState('')
  const [guardKind, setGuardKind] = useState(ALL_FACET)

  /**
   * Filters belong to the run they were typed against.
   *
   * "critical" is a live selection on one cluster and matches nothing on the
   * next, so carrying a filter across a run change hands the operator four
   * empty tables and no obvious cause. Cleared on every selection change and
   * on the demo/live flip, for the same reason `openProof` is.
   */
  const clearAllFilters = useCallback(() => {
    setSingleSearch('')
    setSingleRisk(ALL_FACET)
    setGroupSearch('')
    setGroupRisk(ALL_FACET)
    setPivotSearch('')
    setPivotRisk(ALL_FACET)
    setGuardSearch('')
    setGuardKind(ALL_FACET)
  }, [])

  useEffect(() => subscribeDemoMode(setDemo), [])

  // ── Live mode: discover clusters + their run history ──────────────────
  const loadLiveRunList = useCallback(async () => {
    setIsLoadingList(true)
    setFatalError(null)
    setRunError(null)
    try {
      const clusterList = parseClusterList(await fetchJsonOrThrow('/clusters'))
      setClusters(clusterList)

      const perCluster = await Promise.all(
        clusterList.map(async (cluster): Promise<RunOption[]> => {
          try {
            const jobs = await fetchClusterJobs(cluster.id, 10)
            return jobs.map(job => ({
              id: job.id,
              clusterId: cluster.id,
              clusterName: cluster.name,
              createdAt: job.createdAt,
              outcome: job.status,
            }))
          } catch {
            // One cluster's job history failing to load should not blank the
            // whole selector — it just contributes no runs. The cluster itself
            // stays selectable via its "latest analysis" entry, which is the
            // whole reason that group exists.
            return []
          }
        }),
      )
      const merged = perCluster.flat().sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      setRunOptions(merged)
      setSelectedRunId(AGGREGATE_ID)
    } catch (error) {
      setClusters([])
      setRunOptions([])
      setFatalError(error instanceof Error ? error.message : 'Unable to reach the KubeSec-AFM platform.')
    } finally {
      setIsLoadingList(false)
    }
  }, [])

  // ── Live mode: build the aggregate rollup across every cluster with data ──
  const loadLiveAggregate = useCallback(async (clusterList: ClusterMeta[]) => {
    setIsLoadingView(true)
    setRunError(null)
    try {
      const perCluster = await Promise.all(
        clusterList.map(async (cluster) => {
          try {
            const status = await fetchAnalysisStatus(cluster.id)
            if (!status.lastCompletedJobId) return null
            const [analysis, sharedRoles, guards] = await Promise.all([
              fetchAnalysisResult(cluster.id),
              fetchSharedRoles(cluster.id).catch(() => []),
              fetchGuards(cluster.id).catch(() => ({ jobId: '', guards: [] })),
            ])
            if (analysis === null) return null
            return { cluster, analysis, sharedRoles, guards: guards.guards }
          } catch {
            return null
          }
        }),
      )
      const withData = perCluster.filter((entry): entry is NonNullable<typeof entry> => entry !== null)

      const discoveryProof: Proof = {
        label: 'Cluster discovery',
        command: 'curl -s /afm/clusters | jq -r ".[].id"',
        detail: `${clusterList.length} cluster(s) returned: ${clusterList.map(c => c.id).join(', ') || '(none)'}\n`
          + `${withData.length} of them have a completed analysis run and are rolled up below.`,
      }

      if (withData.length === 0) {
        setView({
          label: 'All runs (aggregate)',
          clusterName: `${clusterList.length} cluster${clusterList.length === 1 ? '' : 's'}`,
          timestampLabel: '—',
          subjects: [],
          singleEscalations: [],
          groupEscalations: [],
          sharedRoles: [],
          sharedRolesProofs: [],
          guards: [],
          guardsProofs: [],
          guardsCaption: 'No completed analysis runs yet for any cluster.',
          provenanceProofs: [discoveryProof],
        })
        return
      }

      const missing = clusterList.length - withData.length
      setView({
        label: 'All runs (aggregate)',
        clusterName: `${withData.length} of ${clusterList.length} cluster${clusterList.length === 1 ? '' : 's'}`,
        timestampLabel: '—',
        subjects: Array.from(new Set(withData.flatMap(e => e.analysis.subjects))),
        singleEscalations: withData.flatMap(e =>
          liveSingles(analysisUrl(e.cluster.id), e.cluster.name, e.analysis.singleEscalations)),
        groupEscalations: withData.flatMap(e =>
          liveGroups(analysisUrl(e.cluster.id), e.cluster.name, e.analysis.groupEscalations)),
        sharedRoles: withData.flatMap(e => e.sharedRoles),
        sharedRolesProofs: withData.map(e => liveSharedRolesProof(e.cluster.id, e.cluster.name, e.sharedRoles)),
        guards: withData.flatMap(e => e.guards),
        guardsProofs: withData.map(e => liveGuardsProof(e.cluster.id, e.cluster.name, e.guards)),
        guardsCaption: missing > 0
          ? `${missing} cluster${missing === 1 ? '' : 's'} could not be included (unreachable or no completed run).`
          : 'Rolled up from every cluster with a completed analysis run.',
        provenanceProofs: [
          discoveryProof,
          ...withData.map((e): Proof => ({
            label: e.cluster.name,
            command: `curl -s ${analysisUrl(e.cluster.id)} | jq '{schema_version, single: (.single_escalations|length), group: (.group_escalations|length)}'`,
            detail: `schema_version:     ${e.analysis.schemaVersion}\n`
              + `subjects:           ${e.analysis.subjects.length}\n`
              + `single_escalations: ${e.analysis.singleEscalations.length}\n`
              + `group_escalations:  ${e.analysis.groupEscalations.length}`,
          })),
        ],
      })
    } finally {
      setIsLoadingView(false)
    }
  }, [])

  /**
   * ── Live mode: one cluster's latest completed analysis ──────────────────
   *
   * The selection the KTP/AFM dashboard and RBAC Explorer both offer. It is
   * NOT the same as picking the newest job: a cluster whose job history is
   * empty or unreadable still answers /analysis/latest, and before this
   * existed such a cluster was unreachable from this page.
   */
  const loadLiveCluster = useCallback(async (cluster: ClusterMeta) => {
    setIsLoadingView(true)
    setRunError(null)
    try {
      const [analysis, sharedRoles, guards] = await Promise.all([
        fetchAnalysisResult(cluster.id),
        fetchSharedRoles(cluster.id).catch(() => []),
        fetchGuards(cluster.id).catch(() => ({ jobId: '', guards: [] })),
      ])
      if (analysis === null) {
        setRunError(`${cluster.name} has no completed analysis run yet.`)
        setView(null)
        return
      }
      const endpoint = analysisUrl(cluster.id)
      setView({
        label: cluster.name,
        clusterName: cluster.name,
        timestampLabel: 'latest',
        subjects: analysis.subjects,
        singleEscalations: liveSingles(endpoint, cluster.name, analysis.singleEscalations),
        groupEscalations: liveGroups(endpoint, cluster.name, analysis.groupEscalations),
        sharedRoles,
        sharedRolesProofs: [liveSharedRolesProof(cluster.id, cluster.name, sharedRoles)],
        guards: guards.guards,
        guardsProofs: [liveGuardsProof(cluster.id, cluster.name, guards.guards)],
        guardsCaption: 'Current RBAC state for this cluster.',
        provenanceProofs: [{
          label: cluster.name,
          command: `curl -s ${endpoint}`,
          detail: `Latest completed analysis for cluster ${cluster.id}.\n`
            + `schema_version:     ${analysis.schemaVersion}\n`
            + `subjects:           ${analysis.subjects.length}\n`
            + `single_escalations: ${analysis.singleEscalations.length}\n`
            + `group_escalations:  ${analysis.groupEscalations.length}`,
        }],
      })
    } catch (error) {
      setView(null)
      setRunError(error instanceof Error ? error.message : `Unable to load cluster ${cluster.id}.`)
    } finally {
      setIsLoadingView(false)
    }
  }, [])

  // ── Live mode: drill into one specific historical run ──────────────────
  const loadLiveRun = useCallback(async (run: RunOption) => {
    setIsLoadingView(true)
    setRunError(null)
    try {
      const analysis = await fetchJobResult(run.id)
      if (analysis === null) {
        setRunError(`Run ${run.id} has no stored result.`)
        setView(null)
        return
      }
      const [sharedRoles, guards] = await Promise.all([
        fetchSharedRoles(run.clusterId).catch(() => []),
        fetchGuards(run.clusterId).catch(() => ({ jobId: '', guards: [] })),
      ])
      const endpoint = jobResultUrl(run.id)
      setView({
        label: run.clusterName,
        clusterName: run.clusterName,
        timestampLabel: formatTimestamp(run.createdAt),
        subjects: analysis.subjects,
        singleEscalations: liveSingles(endpoint, run.clusterName, analysis.singleEscalations),
        groupEscalations: liveGroups(endpoint, run.clusterName, analysis.groupEscalations),
        sharedRoles,
        sharedRolesProofs: [liveSharedRolesProof(run.clusterId, run.clusterName, sharedRoles)],
        guards: guards.guards,
        guardsProofs: [liveGuardsProof(run.clusterId, run.clusterName, guards.guards)],
        guardsCaption: 'Shared-role pivots and guards reflect the cluster\'s current RBAC state, not this specific historical run.',
        provenanceProofs: [{
          label: `Run ${run.id}`,
          command: `curl -s ${endpoint}`,
          detail: `Stored result for job ${run.id} (cluster ${run.clusterId}, created ${run.createdAt}).\n`
            + `schema_version:     ${analysis.schemaVersion}\n`
            + `subjects:           ${analysis.subjects.length}\n`
            + `single_escalations: ${analysis.singleEscalations.length}\n`
            + `group_escalations:  ${analysis.groupEscalations.length}`,
        }],
      })
    } catch (error) {
      setView(null)
      setRunError(error instanceof Error ? error.message : `Unable to load run ${run.id}.`)
    } finally {
      setIsLoadingView(false)
    }
  }, [])

  // Initial load + reload whenever the demo/live toggle flips.
  useEffect(() => {
    setOpenProof({})
    clearAllFilters()
    if (demo) {
      setFatalError(null)
      setRunError(null)
      setRunOptions(DEMO_RUNS.map(run => ({
        id: run.id,
        clusterId: run.clusterId,
        clusterName: run.clusterName,
        createdAt: run.createdAt,
        outcome: run.analysis.groupEscalations.length > 0
          ? `${run.analysis.groupEscalations.length} collusion pair${run.analysis.groupEscalations.length === 1 ? '' : 's'}`
          : 'clear',
      })))
      setSelectedRunId(AGGREGATE_ID)
      setView(demoView(DEMO_RUNS, 'All runs (aggregate)', 'All demo clusters', '—'))
      return
    }
    void loadLiveRunList()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [demo])

  // Once the live cluster/run list is in, populate the default aggregate view.
  useEffect(() => {
    if (demo || fatalError || clusters.length === 0) return
    void loadLiveAggregate(clusters)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [demo, fatalError, clusters])

  /**
   * The clusters the selector offers, derived from the same source the other
   * KubeSec-AFM surfaces use — /afm/clusters in live mode, the fixtures'
   * distinct clusters in demo mode. Never a hand-maintained list.
   */
  const clusterOptions = useMemo<ClusterMeta[]>(() => {
    if (demo) {
      const seen = new Map<string, string>()
      DEMO_RUNS.forEach(run => { if (!seen.has(run.clusterId)) seen.set(run.clusterId, run.clusterName) })
      return Array.from(seen, ([id, name]) => ({ id, name }))
    }
    return clusters
  }, [demo, clusters])

  function handleRunChange(nextId: string) {
    setSelectedRunId(nextId)
    // A console left open across a selection change would show the previous
    // view's proof beside the new view's row.
    setOpenProof({})
    clearAllFilters()

    if (nextId === AGGREGATE_ID) {
      if (demo) {
        setRunError(null)
        setView(demoView(DEMO_RUNS, 'All runs (aggregate)', 'All demo clusters', '—'))
        return
      }
      void loadLiveAggregate(clusters)
      return
    }

    if (nextId.startsWith(CLUSTER_PREFIX)) {
      const clusterId = nextId.slice(CLUSTER_PREFIX.length)
      if (demo) {
        const runs = DEMO_RUNS.filter(run => run.clusterId === clusterId)
        setRunError(null)
        setView(runs.length > 0
          ? demoView(runs, runs[0].clusterName, runs[0].clusterName, formatTimestamp(runs[runs.length - 1].createdAt))
          : null)
        return
      }
      const cluster = clusters.find(c => c.id === clusterId)
      if (cluster) void loadLiveCluster(cluster)
      return
    }

    if (demo) {
      const run = DEMO_RUNS.find(r => r.id === nextId)
      setRunError(null)
      setView(run ? demoView([run], run.clusterName, run.clusterName, formatTimestamp(run.createdAt)) : null)
      return
    }
    const run = runOptions.find(r => r.id === nextId)
    if (run) void loadLiveRun(run)
  }

  const toggleProof = useCallback((key: string) => {
    setOpenProof(prev => ({ ...prev, [key]: prev[key] !== true }))
  }, [])

  const statCards = useMemo(() => {
    return [
      { label: 'Subjects analysed', value: String(view?.subjects.length ?? 0), sub: 'users, groups, service accounts', accent: 'var(--cyan)' },
      { label: 'Escalation paths', value: String(view?.singleEscalations.length ?? 0), sub: 'single-subject privilege escalation', accent: 'var(--violet)' },
      { label: 'Collusion pairs', value: String(view?.groupEscalations.length ?? 0), sub: 'escalation via cooperation', accent: 'var(--amber)' },
      { label: 'Pivot roles', value: String(view?.sharedRoles.length ?? 0), sub: 'shared-role attack surface', accent: 'var(--teal)' },
      { label: 'Priority fixes', value: String(view?.guards.length ?? 0), sub: 'applyable TraceGuards', accent: 'var(--cyan)' },
    ]
  }, [view])

  // ── Rows, then filtered rows ──────────────────────────────────────────
  // Two steps on purpose: the facet counts and the "n of m shown" figure are
  // both computed against the FULL set, so a chip never reports the effect of
  // the search box sitting next to it.

  const singleRows = useMemo<SingleRow[]>(() => (view?.singleEscalations ?? []).map(({ finding, proofs }, i) => ({
    key: `single-${i}`,
    subject: finding.subject,
    escalationType: finding.escalationType,
    scope: finding.scope,
    gained: permissionLabel(finding.gainedPermission),
    risk: riskLevel(finding.risk),
    proofs,
  })), [view])

  const groupRows = useMemo<GroupRow[]>(() => (view?.groupEscalations ?? []).map(({ finding, proofs }, i) => ({
    key: `group-${i}`,
    group: finding.group.join(', '),
    primaryActor: finding.primaryActor,
    primaryGain: permissionLabel(finding.primaryGain),
    collaboratorGains: finding.collaboratorGains
      .map(c => `${c.subject}: ${permissionLabel(c.permission)}`)
      .join('; ') || '—',
    risk: riskLevel(finding.risk),
    proofs,
  })), [view])

  const pivotRows = useMemo<PivotRow[]>(() => (view?.sharedRoles ?? []).map((p, i) => ({
    key: `${p.role}-${i}`,
    role: p.role,
    sharedBy: p.sharedBy,
    sharedByLabel: `${p.sharedBy} subject${p.sharedBy === 1 ? '' : 's'}`,
    privileged: p.privilegedSubjects.join(', ') || '—',
    // The same derivation the Pill has always shown, lifted out so the chip
    // row and the cell cannot disagree about what "high" means here.
    risk: p.privilegedSubjects.length > 0 ? 'high' : 'low',
  })), [view])

  const guardRows = useMemo<GuardRow[]>(() => (view?.guards ?? []).map((g, i) => ({
    key: `${g.name}-${i}`,
    name: g.name,
    kind: g.kind,
    participants: g.participants.join(', ') || '—',
    wouldBlock: g.wouldBlock ? 'active' : 'pending',
  })), [view])

  const singleFacets = useMemo(() => facetsOf(singleRows, r => r.risk, severityRank), [singleRows])
  const groupFacets = useMemo(() => facetsOf(groupRows, r => r.risk, severityRank), [groupRows])
  const pivotFacets = useMemo(() => facetsOf(pivotRows, r => r.risk, severityRank), [pivotRows])
  const guardFacets = useMemo(() => facetsOf(guardRows, r => r.kind, flatRank), [guardRows])

  const singleShown = useMemo(
    () => narrow(singleRows, singleSearch, singleRisk, r => [r.subject, r.escalationType, r.scope, r.gained], r => r.risk),
    [singleRows, singleSearch, singleRisk],
  )
  const groupShown = useMemo(
    () => narrow(groupRows, groupSearch, groupRisk, r => [r.group, r.primaryActor, r.primaryGain, r.collaboratorGains], r => r.risk),
    [groupRows, groupSearch, groupRisk],
  )
  const pivotShown = useMemo(
    () => narrow(pivotRows, pivotSearch, pivotRisk, r => [r.role, r.privileged], r => r.risk),
    [pivotRows, pivotSearch, pivotRisk],
  )
  const guardShown = useMemo(
    () => narrow(guardRows, guardSearch, guardKind, r => [r.name, r.participants, r.wouldBlock], r => r.kind),
    [guardRows, guardSearch, guardKind],
  )

  /** The "How do we know?" affordance on its own — the console it opens is rendered by the caller. */
  function ProofButton({ id, proofs }: { id: string; proofs: Proof[] }) {
    if (proofs.length === 0) return null
    const isOpen = openProof[id] === true
    return (
      <button
        type="button"
        className="btn btn-secondary"
        data-testid={`collusion-proof-${id}`}
        onClick={() => toggleProof(id)}
        style={proofButton}
      >
        {isOpen
          ? 'Hide proof'
          : proofs.length > 1
            ? `How do we know? (${proofs.length} sources)`
            : 'How do we know?'}
      </button>
    )
  }

  /** Button and console together, for the claims that are not table rows. */
  function Disclosure({ id, proofs }: { id: string; proofs: Proof[] }) {
    if (proofs.length === 0) return null
    return (
      <div style={{ marginTop: 8 }}>
        <ProofButton id={id} proofs={proofs} />
        {openProof[id] === true && <ProofConsole proofs={proofs} testId={`collusion-console-${id}`} />}
      </div>
    )
  }

  return (
    <div>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>Collusion &amp; Access</h1>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 18, maxWidth: 780 }}>
        Formal-methods RBAC analysis from ControlPlane <strong style={{ color: 'var(--text)' }}>KubeSec-AFM</strong> (KTP
        with King&apos;s College London) — <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
          bounded model checking
          <HelpHint label="What bounded model checking means" testId="collusion-bmc-help">
            An exhaustive search of every sequence of RBAC operations up to a fixed length. Within that
            bound the answer is a proof rather than a sample: if it finds no path, none exists in that
            many steps. It says nothing about longer ones.
          </HelpHint>
        </span> for privilege escalation and <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
          multi-subject collusion
          <HelpHint label="What collusion means" testId="collusion-concept-help">
            Two or more identities that cannot reach a privileged role on their own, but can if they
            cooperate — one grants, the other uses. Nothing here is a breach; it is a route that exists
            in the RBAC configuration whether or not anyone has walked it.
          </HelpHint>
        </span>, with TraceGuard remediation.
      </p>

      {demo && (
        <div style={{
          background: 'color-mix(in srgb, var(--amber) 8%, transparent)',
          border: '1px solid color-mix(in srgb, var(--amber) 25%, transparent)',
          borderRadius: 6, padding: '8px 14px', marginBottom: 16, fontSize: 12, color: 'var(--amber)',
        }}>
          Demo mode — fixed, offline collusion/escalation data across two sample runs. Switch to live mode
          for the real KubeSec-AFM analysis.
        </div>
      )}

      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 18, flexWrap: 'wrap' }}>
        <label htmlFor="collusion-run-select" style={{ fontSize: 12, color: 'var(--muted)' }}>Run</label>
        <select
          id="collusion-run-select"
          data-testid="collusion-run-select"
          value={selectedRunId}
          onChange={event => handleRunChange(event.target.value)}
          disabled={isLoadingList || (!demo && Boolean(fatalError))}
          style={{ minWidth: 320 }}
        >
          <option value={AGGREGATE_ID}>All runs (aggregate)</option>
          {clusterOptions.length > 0 && (
            <optgroup label="Cluster (latest analysis)">
              {clusterOptions.map(cluster => (
                <option key={cluster.id} value={`${CLUSTER_PREFIX}${cluster.id}`}>
                  {cluster.name} · latest analysis
                </option>
              ))}
            </optgroup>
          )}
          {runOptions.length > 0 && (
            <optgroup label="Run history">
              {runOptions.map(run => (
                <option key={run.id} value={run.id}>
                  {run.clusterName} · {formatTimestamp(run.createdAt)} · {run.outcome}
                </option>
              ))}
            </optgroup>
          )}
        </select>
        <HelpHint label="What the Run selector offers" testId="collusion-run-help">
          Three altitudes on the same KubeSec-AFM data. The aggregate rolls every cluster up. A cluster
          entry is that cluster&apos;s latest completed analysis — the same selection the KubeSec-AFM
          dashboard and RBAC Explorer offer, so the results match across all three pages. A run entry is
          one specific historical job. Changing it clears the table filters, which belonged to the run
          you were looking at.
        </HelpHint>
        {isLoadingList && <LoadingState status="loading" label="AFM runs" testId="collusion-list-loading" />}
        {isLoadingView && <LoadingState status="loading" label="run" testId="collusion-run-loading" />}
      </div>

      {!demo && fatalError && (
        <div data-testid="collusion-fatal-error" style={{
          border: '1px solid color-mix(in srgb, var(--error) 35%, transparent)',
          background: 'color-mix(in srgb, var(--error) 8%, transparent)',
          borderRadius: 8, padding: '16px 20px', marginBottom: 20, fontSize: 13, color: 'var(--text)',
        }}>
          <div style={{ fontWeight: 600, marginBottom: 6, color: 'var(--error)' }}>KubeSec-AFM is not reachable</div>
          <div style={{ color: 'var(--muted)', marginBottom: 10 }}>{fatalError}</div>
          <button type="button" className="btn btn-secondary" style={{ fontSize: 12, padding: '5px 12px' }} onClick={() => void loadLiveRunList()}>
            Retry connection
          </button>
        </div>
      )}

      {runError && (
        <div data-testid="collusion-run-error" style={{
          fontSize: 12, color: 'var(--error)', marginBottom: 16,
        }}>
          {runError}
        </div>
      )}

      {view && (
        <>
          {/* Provenance — which data path produced everything below, and the
              commands that return it. The tables carry their own row-level
              proofs; this one answers "where did this whole view come from". */}
          <div
            data-testid="collusion-provenance"
            className="card"
            style={{ padding: '12px 16px', marginBottom: 20, fontSize: 13, lineHeight: 1.6, borderLeft: '3px solid var(--cyan)' }}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
              <strong style={{ color: demo ? 'var(--amber)' : 'var(--cyan)' }}>{demo ? 'Demo data' : 'Live'}</strong>
              <span style={{ color: 'var(--muted)' }}>
                {view.label} · {view.clusterName} · {view.timestampLabel}
              </span>
              <HelpHint label="What showing the proof does" testId="collusion-proof-help" tone="var(--cyan)">
                Opens the literal command that returns the source of what is on screen, and what this page
                actually received back. Each finding row has its own button for the one row. Paste the
                command into a terminal to check the platform rather than trust it.
              </HelpHint>
            </div>
            <Disclosure id="provenance" proofs={view.provenanceProofs} />
          </div>

          <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 28 }}>
            {statCards.map(card => <StatCard key={card.label} {...card} />)}
          </div>

          <Section title="Analysis Phases" hint="bounded model checking (depth ≤ 10)">
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))', gap: 12 }}>
              {PHASES.map((p) => (
                <div key={p.n} className="card" style={{ padding: '14px 16px' }}>
                  <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--cyan)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>{p.n}</div>
                  <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)', margin: '4px 0 6px' }}>{p.title}</div>
                  <div style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.5 }}>{p.body}</div>
                </div>
              ))}
            </div>
          </Section>

          <Section title="Privilege Escalation Paths" hint={`${view.label} — single-subject findings`}>
            <DataTable
              columns={SINGLE_COLUMNS}
              data={singleShown}
              pageSize={PAGE_SIZE}
              testIdPrefix="single-escalations-table"
              toolbar={singleRows.length === 0 ? undefined : (
                <FilterStrip
                  id="single-escalations"
                  subject="escalation paths"
                  placeholder="Search subject, type, scope or permission…"
                  search={singleSearch}
                  onSearch={setSingleSearch}
                  facetLabel="risk"
                  facets={singleFacets}
                  facet={singleRisk}
                  onFacet={setSingleRisk}
                  shown={singleShown.length}
                  total={singleRows.length}
                />
              )}
              emptyState={singleRows.length === 0 ? (
                <NoFindings
                  testId="single-escalations-empty"
                  kicker="No single-subject escalation paths found in this run."
                  body="AFM model-checked the RBAC graph and proved no subject reaches a higher privilege on its own."
                />
              ) : (
                <FilteredEmpty
                  id="single-escalations"
                  onClear={() => { setSingleSearch(''); setSingleRisk(ALL_FACET) }}
                />
              )}
              renderRow={(row: SingleRow) => (
                <ProofRow key={row.key} id={row.key} span={SINGLE_COLUMNS.length} proofs={row.proofs} open={openProof[row.key] === true}>
                  <td style={{ ...DataTable.td, fontWeight: 500 }}>{row.subject}</td>
                  <td style={DataTable.td}><code style={{ color: 'var(--violet)', fontSize: 12 }}>{row.escalationType}</code></td>
                  <td style={{ ...DataTable.td, color: 'var(--muted)' }}>{row.scope}</td>
                  <td style={DataTable.td}><code style={{ color: 'var(--amber)', fontSize: 12 }}>{row.gained}</code></td>
                  <td style={DataTable.td}><Pill label={row.risk} /></td>
                  <td style={DataTable.td}><ProofButton id={row.key} proofs={row.proofs} /></td>
                </ProofRow>
              )}
            />
          </Section>

          <Section title="Collusion Pairs" hint={`${view.label} — subjects that jointly escalate`}>
            <DataTable
              columns={GROUP_COLUMNS}
              data={groupShown}
              pageSize={PAGE_SIZE}
              testIdPrefix="group-escalations-table"
              toolbar={groupRows.length === 0 ? undefined : (
                <FilterStrip
                  id="group-escalations"
                  subject="collusion pairs"
                  placeholder="Search a member, actor or permission…"
                  search={groupSearch}
                  onSearch={setGroupSearch}
                  facetLabel="risk"
                  facets={groupFacets}
                  facet={groupRisk}
                  onFacet={setGroupRisk}
                  shown={groupShown.length}
                  total={groupRows.length}
                />
              )}
              emptyState={groupRows.length === 0 ? (
                <NoFindings
                  testId="group-escalations-empty"
                  kicker="No collusion (multi-subject) escalation paths found in this run."
                  body="No group of subjects in this cluster can combine their permissions to reach a role none of them holds."
                />
              ) : (
                <FilteredEmpty
                  id="group-escalations"
                  onClear={() => { setGroupSearch(''); setGroupRisk(ALL_FACET) }}
                />
              )}
              renderRow={(row: GroupRow) => (
                <ProofRow key={row.key} id={row.key} span={GROUP_COLUMNS.length} proofs={row.proofs} open={openProof[row.key] === true}>
                  <td style={{ ...DataTable.td, fontWeight: 500, whiteSpace: 'normal' }}>{row.group}</td>
                  <td style={DataTable.td}>{row.primaryActor}</td>
                  <td style={DataTable.td}><code style={{ color: 'var(--amber)', fontSize: 12 }}>{row.primaryGain}</code></td>
                  <td style={{ ...DataTable.td, color: 'var(--muted)', whiteSpace: 'normal' }}>{row.collaboratorGains}</td>
                  <td style={DataTable.td}><Pill label={row.risk} /></td>
                  <td style={DataTable.td}><ProofButton id={row.key} proofs={row.proofs} /></td>
                </ProofRow>
              )}
            />
          </Section>

          <Section title="Shared-Role Pivot Points" hint="where permissions move between colluders">
            <DataTable
              columns={PIVOT_COLUMNS}
              data={pivotShown}
              pageSize={PAGE_SIZE}
              testIdPrefix="shared-roles-table"
              toolbar={pivotRows.length === 0 ? undefined : (
                <FilterStrip
                  id="shared-roles"
                  subject="shared-role pivots"
                  placeholder="Search a role or a privileged subject…"
                  search={pivotSearch}
                  onSearch={setPivotSearch}
                  facetLabel="risk"
                  facets={pivotFacets}
                  facet={pivotRisk}
                  onFacet={setPivotRisk}
                  shown={pivotShown.length}
                  total={pivotRows.length}
                  hint="Derived on this page rather than returned by AFM: high when at least one sharer of the role is already privileged, low when none is."
                />
              )}
              emptyState={pivotRows.length === 0 ? (
                <NoFindings
                  testId="shared-roles-empty"
                  kicker="No shared-role pivots reported for this run."
                  body="No role in this cluster is held by enough subjects to act as an exchange point between them."
                />
              ) : (
                <FilteredEmpty
                  id="shared-roles"
                  onClear={() => { setPivotSearch(''); setPivotRisk(ALL_FACET) }}
                />
              )}
              renderRow={(row: PivotRow) => (
                <tr key={row.key} style={{ borderBottom: '1px solid var(--border)' }}>
                  <td style={DataTable.td}><code style={{ color: 'var(--violet)', fontSize: 12 }}>{row.role}</code></td>
                  <td style={{ ...DataTable.td, color: 'var(--muted)' }}>{row.sharedByLabel}</td>
                  <td style={{ ...DataTable.td, color: 'var(--muted)', whiteSpace: 'normal' }}>{row.privileged}</td>
                  <td style={DataTable.td}><Pill label={row.risk} /></td>
                </tr>
              )}
            />
            {/* One source per cluster covers the whole table, so the proof
                sits on the section rather than repeating down the rows. */}
            {pivotRows.length > 0 && <Disclosure id="shared-roles" proofs={view.sharedRolesProofs} />}
          </Section>

          <Section title="Remediation Priorities" hint={view.guardsCaption}>
            <DataTable
              columns={GUARD_COLUMNS}
              data={guardShown}
              pageSize={PAGE_SIZE}
              testIdPrefix="guards-table"
              toolbar={guardRows.length === 0 ? undefined : (
                <FilterStrip
                  id="guards"
                  subject="remediation fixes"
                  placeholder="Search a fix or a participant…"
                  search={guardSearch}
                  onSearch={setGuardSearch}
                  facetLabel="kind"
                  facets={guardFacets}
                  facet={guardKind}
                  onFacet={setGuardKind}
                  shown={guardShown.length}
                  total={guardRows.length}
                  hint="Whether the guard closes a single-subject escalation or a collusion path involving several."
                />
              )}
              emptyState={guardRows.length === 0 ? (
                <NoFindings
                  testId="guards-empty"
                  kicker="No TraceGuard fixes available for this run."
                  body="AFM generates a guard from a proven trace, so no findings means nothing to remediate."
                />
              ) : (
                <FilteredEmpty
                  id="guards"
                  onClear={() => { setGuardSearch(''); setGuardKind(ALL_FACET) }}
                />
              )}
              renderRow={(row: GuardRow) => (
                <tr key={row.key} style={{ borderBottom: '1px solid var(--border)' }}>
                  <td style={{ ...DataTable.td, whiteSpace: 'normal', color: 'var(--text)' }}>{row.name}</td>
                  <td style={{ ...DataTable.td, color: 'var(--muted)' }}>{row.kind}</td>
                  <td style={{ ...DataTable.td, color: 'var(--muted)', whiteSpace: 'normal' }}>{row.participants}</td>
                  <td style={DataTable.td}><Pill label={row.wouldBlock} /></td>
                </tr>
              )}
            />
            {guardRows.length > 0 && <Disclosure id="guards" proofs={view.guardsProofs} />}
          </Section>
        </>
      )}
    </div>
  )
}

/**
 * A finding row, plus the full-width row its console expands into.
 *
 * A console rendered inside one <td> would be squeezed into that column's
 * width and wrap a pasteable command into nonsense; a sibling <tr> spanning
 * the table gives it the room, and keeps it adjacent to the row it explains.
 */
function ProofRow({ id, span, proofs, open, children }: {
  id: string
  span: number
  proofs: Proof[]
  open: boolean
  children: ReactNode
}) {
  return (
    <>
      <tr style={{ borderBottom: open ? 'none' : '1px solid var(--border)' }}>{children}</tr>
      {open && (
        <tr style={{ borderBottom: '1px solid var(--border)' }}>
          <td colSpan={span} style={{ padding: '0 14px 10px' }}>
            <ProofConsole proofs={proofs} testId={`collusion-console-${id}`} />
          </td>
        </tr>
      )}
    </>
  )
}

const proofButton: CSSProperties = {
  fontSize: 10, padding: '3px 8px', whiteSpace: 'nowrap',
}
