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
 * TODO: migrate tables to DataTable for client-side pagination and sorting
 * (4 tables: Escalation Paths, Collusion Pairs, Shared-Role Pivots, Remediation)
 */
import { useCallback, useEffect, useMemo, useState, type CSSProperties, type ReactNode } from 'react'
import { StatCard, Section, Table, Pill, td } from '../components/DashKit'
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
        with King&apos;s College London) — bounded model checking for privilege escalation and multi-subject
        collusion, with TraceGuard remediation.
      </p>

      {demo && (
        <div style={{
          background: 'rgba(245,158,11,0.08)', border: '1px solid rgba(245,158,11,0.25)',
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
          one specific historical job.
        </HelpHint>
        {isLoadingList && <LoadingState status="loading" label="AFM runs" testId="collusion-list-loading" />}
        {isLoadingView && <LoadingState status="loading" label="run" testId="collusion-run-loading" />}
      </div>

      {!demo && fatalError && (
        <div data-testid="collusion-fatal-error" style={{
          border: '1px solid rgba(239,68,68,0.35)', background: 'rgba(239,68,68,0.08)',
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
            {view.singleEscalations.length === 0 ? (
              <div style={{ fontSize: 12, color: 'var(--muted)' }} data-testid="single-escalations-empty">
                No single-subject escalation paths found in this run.
              </div>
            ) : (
              <Table headers={['Subject', 'Escalation type', 'Scope', 'Gained permission', 'Risk', 'Proof']}>
                {view.singleEscalations.map(({ finding: e, proofs }, i) => (
                  <ProofRow key={i} id={`single-${i}`} span={6} proofs={proofs} open={openProof[`single-${i}`] === true}>
                    <td style={{ ...td, fontWeight: 500 }}>{e.subject}</td>
                    <td style={td}><code style={{ color: 'var(--violet)', fontSize: 12 }}>{e.escalationType}</code></td>
                    <td style={{ ...td, color: 'var(--muted)' }}>{e.scope}</td>
                    <td style={td}><code style={{ color: 'var(--amber)', fontSize: 12 }}>{permissionLabel(e.gainedPermission)}</code></td>
                    <td style={td}><Pill label={riskLevel(e.risk)} /></td>
                    <td style={td}><ProofButton id={`single-${i}`} proofs={proofs} /></td>
                  </ProofRow>
                ))}
              </Table>
            )}
          </Section>

          <Section title="Collusion Pairs" hint={`${view.label} — subjects that jointly escalate`}>
            {view.groupEscalations.length === 0 ? (
              <div style={{ fontSize: 12, color: 'var(--muted)' }} data-testid="group-escalations-empty">
                No collusion (multi-subject) escalation paths found in this run.
              </div>
            ) : (
              <Table headers={['Group', 'Primary actor', 'Primary gain', 'Collaborator gains', 'Risk', 'Proof']}>
                {view.groupEscalations.map(({ finding: g, proofs }, i) => (
                  <ProofRow key={i} id={`group-${i}`} span={6} proofs={proofs} open={openProof[`group-${i}`] === true}>
                    <td style={{ ...td, fontWeight: 500, whiteSpace: 'normal' }}>{g.group.join(', ')}</td>
                    <td style={td}>{g.primaryActor}</td>
                    <td style={td}><code style={{ color: 'var(--amber)', fontSize: 12 }}>{permissionLabel(g.primaryGain)}</code></td>
                    <td style={{ ...td, color: 'var(--muted)', whiteSpace: 'normal' }}>
                      {g.collaboratorGains.map(c => `${c.subject}: ${permissionLabel(c.permission)}`).join('; ') || '—'}
                    </td>
                    <td style={td}><Pill label={riskLevel(g.risk)} /></td>
                    <td style={td}><ProofButton id={`group-${i}`} proofs={proofs} /></td>
                  </ProofRow>
                ))}
              </Table>
            )}
          </Section>

          <Section title="Shared-Role Pivot Points" hint="where permissions move between colluders">
            {view.sharedRoles.length === 0 ? (
              <div style={{ fontSize: 12, color: 'var(--muted)' }}>No shared-role pivots reported for this run.</div>
            ) : (
              <>
                <Table headers={['Role', 'Shared by', 'Privileged subjects', 'Risk']}>
                  {view.sharedRoles.map((p, i) => (
                    <tr key={`${p.role}-${i}`} style={{ borderBottom: '1px solid var(--border)' }}>
                      <td style={td}><code style={{ color: 'var(--violet)', fontSize: 12 }}>{p.role}</code></td>
                      <td style={{ ...td, color: 'var(--muted)' }}>{p.sharedBy} subject{p.sharedBy === 1 ? '' : 's'}</td>
                      <td style={{ ...td, color: 'var(--muted)', whiteSpace: 'normal' }}>{p.privilegedSubjects.join(', ') || '—'}</td>
                      <td style={td}><Pill label={p.privilegedSubjects.length > 0 ? 'high' : 'low'} /></td>
                    </tr>
                  ))}
                </Table>
                {/* One source per cluster covers the whole table, so the proof
                    sits on the section rather than repeating down the rows. */}
                <Disclosure id="shared-roles" proofs={view.sharedRolesProofs} />
              </>
            )}
          </Section>

          <Section title="Remediation Priorities" hint={view.guardsCaption}>
            {view.guards.length === 0 ? (
              <div style={{ fontSize: 12, color: 'var(--muted)' }}>No TraceGuard fixes available for this run.</div>
            ) : (
              <>
                <Table headers={['Fix', 'Kind', 'Participants', 'Would block']}>
                  {view.guards.map((g, i) => (
                    <tr key={`${g.name}-${i}`} style={{ borderBottom: '1px solid var(--border)' }}>
                      <td style={{ ...td, whiteSpace: 'normal', color: 'var(--text)' }}>{g.name}</td>
                      <td style={{ ...td, color: 'var(--muted)' }}>{g.kind}</td>
                      <td style={{ ...td, color: 'var(--muted)', whiteSpace: 'normal' }}>{g.participants.join(', ') || '—'}</td>
                      <td style={td}><Pill label={g.wouldBlock ? 'active' : 'pending'} /></td>
                    </tr>
                  ))}
                </Table>
                <Disclosure id="guards" proofs={view.guardsProofs} />
              </>
            )}
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
