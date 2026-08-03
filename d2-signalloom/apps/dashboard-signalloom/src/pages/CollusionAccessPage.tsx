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
 * that was the bug. It now has a run selector: pick "All runs (aggregate)" for
 * a cross-run rollup, or a specific run to drill into that run's own escalation
 * findings. Demo mode renders two fixed, offline runs (afmDemoFixtures.ts) that
 * are exactly the page's original narrative content, split across two runs.
 * Live mode calls the real KubeSec-AFM API (afmApi.ts) and fails visibly —
 * never falls back to demo data — when the backend is unreachable.
 *
 * The radial cluster graph is used as a page background placeholder.
 *
 * TODO: migrate tables to DataTable for client-side pagination and sorting
 * (4 tables: Escalation Paths, Collusion Pairs, Shared-Role Pivots, Remediation)
 */
import { useCallback, useEffect, useMemo, useState } from 'react'
import { StatCard, Section, Table, Pill, td } from '../components/DashKit'
import LoadingState from '../components/LoadingState'
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
  type AnalysisResult,
  type ClusterMeta,
  type Guard,
  type SharedRoleEntry,
} from '../api/afmApi'
import { DEMO_AGGREGATE, DEMO_RUNS, type DemoRun } from '../api/afmDemoFixtures'

const BG = '/ktp-collusion-graph.png'
const AGGREGATE_ID = 'aggregate'

const PHASES = [
  { n: 'Phase 1', title: 'Admin & self-escalation removal', body: 'Drop subjects who are already cluster-admin or can self-escalate via the escalate verb — they have no incentive to collude.' },
  { n: 'Phase 1.5', title: 'Impersonation check', body: 'Test escalation through impersonation, including a group impersonating a service account in another namespace (unscoped pre-1.36).' },
  { n: 'Phase 2', title: 'Collusion escalation', body: 'Model-check whether pairs of subjects can exchange permissions to jointly reach a higher-privileged role.' },
]

/** One row in the run-selector dropdown. */
interface RunOption {
  id: string
  clusterId: string
  clusterName: string
  createdAt: string
  outcome: string
}

/** Whatever is currently rendered below the selector — a single run or the aggregate rollup. */
interface RunView {
  label: string
  clusterName: string
  timestampLabel: string
  analysis: AnalysisResult
  sharedRoles: SharedRoleEntry[]
  guards: Guard[]
  guardsCaption: string
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

function demoRunToView(run: DemoRun): RunView {
  return {
    label: run.clusterName,
    clusterName: run.clusterName,
    timestampLabel: formatTimestamp(run.createdAt),
    analysis: run.analysis,
    sharedRoles: run.sharedRoles,
    guards: run.guards,
    guardsCaption: 'Fixed offline demo data.',
  }
}

function demoOptions(): RunOption[] {
  return DEMO_RUNS.map(run => ({
    id: run.id,
    clusterId: run.clusterId,
    clusterName: run.clusterName,
    createdAt: run.createdAt,
    outcome: run.analysis.groupEscalations.length > 0
      ? `${run.analysis.groupEscalations.length} collusion pair${run.analysis.groupEscalations.length === 1 ? '' : 's'}`
      : 'clear',
  }))
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
            // whole selector — it just contributes no runs.
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

      if (withData.length === 0) {
        setView({
          label: 'All runs (aggregate)',
          clusterName: `${clusterList.length} cluster${clusterList.length === 1 ? '' : 's'}`,
          timestampLabel: '—',
          analysis: { schemaVersion: 'live', subjects: [], singleEscalations: [], groupEscalations: [] },
          sharedRoles: [],
          guards: [],
          guardsCaption: 'No completed analysis runs yet for any cluster.',
        })
        return
      }

      const missing = clusterList.length - withData.length
      setView({
        label: 'All runs (aggregate)',
        clusterName: `${withData.length} of ${clusterList.length} cluster${clusterList.length === 1 ? '' : 's'}`,
        timestampLabel: '—',
        analysis: {
          schemaVersion: 'live',
          subjects: Array.from(new Set(withData.flatMap(e => e.analysis.subjects))),
          singleEscalations: withData.flatMap(e => e.analysis.singleEscalations),
          groupEscalations: withData.flatMap(e => e.analysis.groupEscalations),
        },
        sharedRoles: withData.flatMap(e => e.sharedRoles),
        guards: withData.flatMap(e => e.guards),
        guardsCaption: missing > 0
          ? `${missing} cluster${missing === 1 ? '' : 's'} could not be included (unreachable or no completed run).`
          : 'Rolled up from every cluster with a completed analysis run.',
      })
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
      setView({
        label: run.clusterName,
        clusterName: run.clusterName,
        timestampLabel: formatTimestamp(run.createdAt),
        analysis,
        sharedRoles,
        guards: guards.guards,
        guardsCaption: 'Shared-role pivots and guards reflect the cluster\'s current RBAC state, not this specific historical run.',
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
    if (demo) {
      setFatalError(null)
      setRunError(null)
      setRunOptions(demoOptions())
      setSelectedRunId(AGGREGATE_ID)
      setView(demoRunToView(DEMO_AGGREGATE))
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

  function handleRunChange(nextId: string) {
    setSelectedRunId(nextId)

    if (demo) {
      setRunError(null)
      setView(nextId === AGGREGATE_ID ? demoRunToView(DEMO_AGGREGATE) : demoRunToView(DEMO_RUNS.find(r => r.id === nextId) ?? DEMO_AGGREGATE))
      return
    }

    if (nextId === AGGREGATE_ID) {
      void loadLiveAggregate(clusters)
      return
    }
    const run = runOptions.find(r => r.id === nextId)
    if (run) void loadLiveRun(run)
  }

  const statCards = useMemo(() => {
    const a = view?.analysis
    return [
      { label: 'Subjects analysed', value: String(a?.subjects.length ?? 0), sub: 'users, groups, service accounts', accent: 'var(--cyan)' },
      { label: 'Escalation paths', value: String(a?.singleEscalations.length ?? 0), sub: 'single-subject privilege escalation', accent: 'var(--violet)' },
      { label: 'Collusion pairs', value: String(a?.groupEscalations.length ?? 0), sub: 'escalation via cooperation', accent: 'var(--amber)' },
      { label: 'Pivot roles', value: String(view?.sharedRoles.length ?? 0), sub: 'shared-role attack surface', accent: 'var(--teal)' },
      { label: 'Priority fixes', value: String(view?.guards.length ?? 0), sub: 'applyable TraceGuards', accent: 'var(--cyan)' },
    ]
  }, [view])

  return (
    <div style={{ position: 'relative', paddingBottom: 40 }}>
      {/* Radial cluster-graph background placeholder. */}
      <div
        aria-hidden
        data-testid="ktp-graph-bg"
        data-bg={BG}
        style={{
          position: 'absolute', inset: '-28px -32px 0',
          backgroundImage: `linear-gradient(180deg, color-mix(in srgb, var(--bg) 72%, transparent), color-mix(in srgb, var(--bg) 93%, transparent)), url(${BG})`,
          backgroundSize: 'cover', backgroundPosition: 'top center', backgroundRepeat: 'no-repeat',
          pointerEvents: 'none', zIndex: 0,
        }}
      />
      <div style={{ position: 'relative', zIndex: 1 }}>
        <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>Collusion &amp; Access</h1>
        <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 18, maxWidth: 780 }}>
          Formal-methods RBAC analysis from ControlPlane <strong style={{ color: 'var(--text)' }}>KubeSec-AFM</strong> (KTP
          with King&apos;s College London) — bounded model checking for privilege escalation and multi-subject
          collusion, with TraceGuard remediation. The radial cluster graph is a live-data placeholder.
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
            {runOptions.map(run => (
              <option key={run.id} value={run.id}>
                {run.clusterName} · {formatTimestamp(run.createdAt)} · {run.outcome}
              </option>
            ))}
          </select>
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
              {view.analysis.singleEscalations.length === 0 ? (
                <div style={{ fontSize: 12, color: 'var(--muted)' }} data-testid="single-escalations-empty">
                  No single-subject escalation paths found in this run.
                </div>
              ) : (
                <Table headers={['Subject', 'Escalation type', 'Scope', 'Gained permission', 'Risk']}>
                  {view.analysis.singleEscalations.map((e, i) => (
                    <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
                      <td style={{ ...td, fontWeight: 500 }}>{e.subject}</td>
                      <td style={td}><code style={{ color: 'var(--violet)', fontSize: 12 }}>{e.escalationType}</code></td>
                      <td style={{ ...td, color: 'var(--muted)' }}>{e.scope}</td>
                      <td style={td}><code style={{ color: 'var(--amber)', fontSize: 12 }}>{permissionLabel(e.gainedPermission)}</code></td>
                      <td style={td}><Pill label={riskLevel(e.risk)} /></td>
                    </tr>
                  ))}
                </Table>
              )}
            </Section>

            <Section title="Collusion Pairs" hint={`${view.label} — subjects that jointly escalate`}>
              {view.analysis.groupEscalations.length === 0 ? (
                <div style={{ fontSize: 12, color: 'var(--muted)' }} data-testid="group-escalations-empty">
                  No collusion (multi-subject) escalation paths found in this run.
                </div>
              ) : (
                <Table headers={['Group', 'Primary actor', 'Primary gain', 'Collaborator gains', 'Risk']}>
                  {view.analysis.groupEscalations.map((g, i) => (
                    <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
                      <td style={{ ...td, fontWeight: 500, whiteSpace: 'normal' }}>{g.group.join(', ')}</td>
                      <td style={td}>{g.primaryActor}</td>
                      <td style={td}><code style={{ color: 'var(--amber)', fontSize: 12 }}>{permissionLabel(g.primaryGain)}</code></td>
                      <td style={{ ...td, color: 'var(--muted)', whiteSpace: 'normal' }}>
                        {g.collaboratorGains.map(c => `${c.subject}: ${permissionLabel(c.permission)}`).join('; ') || '—'}
                      </td>
                      <td style={td}><Pill label={riskLevel(g.risk)} /></td>
                    </tr>
                  ))}
                </Table>
              )}
            </Section>

            <Section title="Shared-Role Pivot Points" hint="where permissions move between colluders">
              {view.sharedRoles.length === 0 ? (
                <div style={{ fontSize: 12, color: 'var(--muted)' }}>No shared-role pivots reported for this run.</div>
              ) : (
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
              )}
            </Section>

            <Section title="Remediation Priorities" hint={view.guardsCaption}>
              {view.guards.length === 0 ? (
                <div style={{ fontSize: 12, color: 'var(--muted)' }}>No TraceGuard fixes available for this run.</div>
              ) : (
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
              )}
            </Section>
          </>
        )}
      </div>
    </div>
  )
}
