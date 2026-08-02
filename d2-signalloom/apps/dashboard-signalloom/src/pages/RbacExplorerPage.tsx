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
 */
import { Component, useCallback, useEffect, useMemo, useState, type ErrorInfo, type ReactNode } from 'react'
import { StatCard, Section, Table, Pill, td } from '../components/DashKit'
import { colors } from '../styles/tokens'
import { isDemoMode } from '../api/demoMode'
import { useAuth0 } from '../auth/oidc'
import {
  fetchCorrelatedRbac,
  fetchRbacClusters,
  type ClusterMeta,
  type CorrelatedRbac,
  type RbacBinding,
  type RbacRole,
  type RbacSubject,
} from '../api/rbacCorrelationApi'
import AddClusterModal, { type NewClusterEntry } from '../components/AddClusterModal'

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

  // Subjects pagination
  const [subjectsPage, setSubjectsPage] = useState(1)
  const [subjectsPageSize, setSubjectsPageSize] = useState(30)

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
      setSubjectsPage(1)
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
      setSubjectsPage(1)
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

  // Stats
  const adminCount = data?.adminCount ?? 0
  const nonAdminCount = data?.nonAdminCount ?? 0
  const escalationCount = data?.escalations.length ?? 0
  const clusterName = clusters.find(c => c.id === clusterId)?.name ?? clusterId

  if (loading && clusters.length === 0) {
    return (
      <div style={{ padding: 64, textAlign: 'center', color: 'var(--muted)' }}>
        <p>Connecting to KubeSec-AFM…</p>
        <code style={{ fontSize: 12, color: 'var(--cyan)' }}>make demo-k8s-afm-up</code>
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
            data-testid="cluster-selector"
          >
            {displayClusters.map(c => (
              <option key={c.id} value={c.id}>{c.name} ({c.id})</option>
            ))}
          </select>
          {/* Namespace selector */}
          <select
            value={nsFilter}
            onChange={e => { setNsFilter(e.target.value); setSubjectsPage(1) }}
            style={{ width: 180 }}
            data-testid="namespace-selector"
          >
            <option value="all">All namespaces</option>
            {namespaces.map(ns => (
              <option key={ns} value={ns}>{ns}</option>
            ))}
          </select>
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

      {loading && <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 40 }} data-testid="rbac-loading">Loading…</div>}

      {/* Live-mode failure — never silently substitutes demo data. */}
      {!loading && error && (
        <div style={{
          background: 'rgba(239,68,68,0.08)', border: '1px solid rgba(239,68,68,0.3)',
          borderRadius: 6, padding: '10px 14px', marginBottom: 16, color: 'var(--error)', fontSize: 13,
        }} data-testid="rbac-live-error">
          <strong>KubeSec-AFM is unreachable.</strong> {error}
          <div style={{ marginTop: 6 }}>
            <button className="btn btn-secondary" style={{ fontSize: 12, padding: '4px 10px' }} onClick={() => void loadCluster(clusterId)}>Retry</button>
          </div>
        </div>
      )}

      {!loading && !error && !data && clusterId && (
        <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 40 }}>
          <p>No RBAC data available for cluster <strong>{clusterId}</strong>.</p>
          <p style={{ fontSize: 12 }}>Ensure the cluster is seeded: <code>scripts/rbac-to-afm.py</code></p>
          <button className="btn btn-secondary" style={{ marginTop: 12 }} onClick={() => void loadCluster(clusterId)}>Retry</button>
        </div>
      )}

      {!loading && data && (
        <>
          {/* Stats */}
          <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 24 }} data-testid="rbac-stats">
            <StatCard label="Cluster" value={clusterName} sub={`${namespaces.length} namespaces`} accent="var(--cyan)" />
            <StatCard label="Subjects" value={String(filteredSubjects.length)} sub={`${adminCount} admins, ${nonAdminCount} non-admin`} accent="var(--teal)" />
            <StatCard label="Roles" value={String(filteredRoles.length)} sub={`${filteredRoles.filter(r => r.scope === 'Cluster').length} cluster-scoped`} accent="var(--violet)" />
            <StatCard label="Escalation Paths" value={String(escalationCount)} sub={escalationCount === 0 ? 'No escalation detected' : 'Requires attention'} accent={escalationCount > 0 ? 'var(--error)' : 'var(--teal)'} />
          </div>

          {/* Escalation findings — correlated server-side from AFM's Z3 engine */}
          {data.escalations.length > 0 && (
            <Section title="Escalation Findings" hint={`${data.escalations.length} findings`}>
              <Table headers={['Subject', 'Type', 'Risk', 'Detail']}>
                {data.escalations.slice(0, 20).map((finding, i) => (
                  <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
                    <td style={td}><code style={{ fontSize: 12, color: 'var(--violet)' }}>{finding.subjectDisplay ?? finding.subject}</code></td>
                    <td style={{ ...td, color: 'var(--muted)' }}>{finding.escalationType ?? finding.kind}</td>
                    <td style={td}>{finding.riskLevel ? <Pill label={finding.riskLevel} /> : '—'}</td>
                    <td style={{ ...td, color: 'var(--muted)', whiteSpace: 'normal', maxWidth: 350 }}>{finding.summary ?? '—'}</td>
                  </tr>
                ))}
              </Table>
            </Section>
          )}

          {/* Conformance issues */}
          {filteredConformance.length > 0 && (
            <Section title="Conformance Issues" hint={`${filteredConformance.length} findings`}>
              <Table headers={['Issue', 'Severity', 'Role', 'Namespace']}>
                {filteredConformance.slice(0, 20).map((c, i) => (
                  <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
                    <td style={{ ...td, whiteSpace: 'normal', maxWidth: 300 }}>{c.reason ?? '—'}</td>
                    <td style={td}><Pill label={c.severity ?? 'info'} /></td>
                    <td style={td}><code style={{ fontSize: 12, color: 'var(--violet)' }}>{c.roleName ?? '—'}</code></td>
                    <td style={{ ...td, color: 'var(--muted)' }}>{c.roleNamespace ?? 'cluster'}</td>
                  </tr>
                ))}
              </Table>
              {filteredConformance.length > 20 && (
                <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6 }}>
                  Showing 20 of {filteredConformance.length} issues
                </div>
              )}
            </Section>
          )}

          {/* Shared role pivot points */}
          {data.sharedRoles.length > 0 && (
            <Section title="Shared-Role Pivot Points" hint="roles shared by multiple subjects">
              <Table headers={['Role', 'Shared By', 'Privileged Subjects']}>
                {data.sharedRoles.slice(0, 15).map((sr, i) => (
                  <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
                    <td style={td}><code style={{ color: 'var(--violet)', fontSize: 12 }}>{sr.roleName}</code></td>
                    <td style={{ ...td, color: 'var(--muted)' }}>{sr.sharedBy} subjects</td>
                    <td style={td}>{sr.privilegedSubjectCount > 0 ? <Pill label={`${sr.privilegedSubjectCount} privileged`} /> : '—'}</td>
                  </tr>
                ))}
              </Table>
            </Section>
          )}

          {/* Roles table */}
          <Section title="Roles" hint={`${nsFilter === 'all' ? 'all namespaces' : nsFilter} · ${filteredRoles.length} roles`}>
            <Table headers={['Name', 'Scope', 'Namespace', 'Rules', 'Verbs', 'Findings']}>
              {filteredRoles.slice(0, 30).map((r, i) => {
                const verbs = new Set<string>()
                r.rules.forEach(rule => rule.verbs.forEach(v => verbs.add(v)))
                const dangerousVerbs = ['create', 'delete', 'patch', 'update', 'bind', 'escalate', 'impersonate']
                const hasDangerous = dangerousVerbs.some(v => verbs.has(v) || verbs.has('*'))
                return (
                  <tr key={`${r.name}-${r.namespace}-${i}`} style={{ borderBottom: '1px solid var(--border)' }}>
                    <td style={{ ...td, fontWeight: 500 }}>{r.name}</td>
                    <td style={td}><Pill label={r.scope === 'Cluster' ? 'cluster' : 'namespace'} /></td>
                    <td style={{ ...td, color: 'var(--muted)' }}>{r.namespace ?? '—'}</td>
                    <td style={{ ...td, color: 'var(--muted)' }}>{r.rules.length}</td>
                    <td style={td}>
                      <div style={{ display: 'flex', gap: 3, flexWrap: 'wrap' }}>
                        {Array.from(verbs).slice(0, 6).map(v => (
                          <span key={v} style={{
                            fontSize: 10, padding: '1px 5px', borderRadius: 3,
                            background: hasDangerous && dangerousVerbs.includes(v)
                              ? `${colors.red}20` : 'var(--surface2)',
                            color: hasDangerous && dangerousVerbs.includes(v)
                              ? colors.red : 'var(--muted)',
                            fontFamily: 'monospace',
                          }}>{v}</span>
                        ))}
                        {verbs.size > 6 && <span style={{ fontSize: 10, color: 'var(--muted)' }}>+{verbs.size - 6}</span>}
                      </div>
                    </td>
                    <td style={td}>
                      <div style={{ display: 'flex', gap: 4 }}>
                        {r.conformanceIssueCount > 0 && <Pill label={`${r.conformanceIssueCount} conformance`} />}
                        {r.hasPrivilegedSharing && <Pill label="privileged sharing" />}
                      </div>
                    </td>
                  </tr>
                )
              })}
            </Table>
            {filteredRoles.length > 30 && (
              <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6 }}>
                Showing 30 of {filteredRoles.length} roles
              </div>
            )}
          </Section>

          {/* Subjects table with pagination */}
          <Section title="Subjects" hint={`${filteredSubjects.length} subjects`}>
            <Table headers={['Name', 'Kind', 'Namespace', 'Bound Roles', 'Flags']}>
              {filteredSubjects.slice((subjectsPage - 1) * subjectsPageSize, subjectsPage * subjectsPageSize).map((s, i) => {
                const boundRoles = filteredBindings
                  .filter(b => b.subjects.some(bs => bs.name === s.name && bs.kind === s.kind))
                  .map(b => b.roleRef)
                return (
                  <tr key={`${s.kind}-${s.name}-${s.namespace}-${i}`} style={{ borderBottom: '1px solid var(--border)' }}>
                    <td style={{ ...td, fontWeight: 500 }}>{s.name}</td>
                    <td style={td}><Pill label={s.kind.toLowerCase()} /></td>
                    <td style={{ ...td, color: 'var(--muted)' }}>{s.namespace ?? '—'}</td>
                    <td style={td}>
                      <div style={{ display: 'flex', gap: 3, flexWrap: 'wrap' }}>
                        {boundRoles.slice(0, 4).map((r, j) => (
                          <code key={j} style={{ fontSize: 11, color: 'var(--cyan)' }}>{r}</code>
                        ))}
                        {boundRoles.length > 4 && <span style={{ fontSize: 10, color: 'var(--muted)' }}>+{boundRoles.length - 4}</span>}
                      </div>
                    </td>
                    <td style={td}>
                      <div style={{ display: 'flex', gap: 4 }}>
                        {s.isEscalationActor && <Pill label="escalation" />}
                        {s.isAdmin && <Pill label="admin" />}
                      </div>
                    </td>
                  </tr>
                )
              })}
            </Table>
            {/* Pagination controls */}
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 8, fontSize: 12, color: 'var(--muted)', flexWrap: 'wrap', gap: 8 }} data-testid="subjects-pagination">
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <span>
                  Showing {Math.min((subjectsPage - 1) * subjectsPageSize + 1, filteredSubjects.length)}–{Math.min(subjectsPage * subjectsPageSize, filteredSubjects.length)} of {filteredSubjects.length} subjects
                </span>
                <select
                  value={subjectsPageSize}
                  onChange={e => { setSubjectsPageSize(Number(e.target.value)); setSubjectsPage(1) }}
                  style={{ fontSize: 12, padding: '2px 6px' }}
                  data-testid="subjects-page-size"
                >
                  {[10, 30, 50, 100].map(n => (
                    <option key={n} value={n}>{n} per page</option>
                  ))}
                </select>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <button
                  className="btn btn-secondary"
                  style={{ fontSize: 11, padding: '3px 10px' }}
                  disabled={subjectsPage <= 1}
                  onClick={() => setSubjectsPage(p => Math.max(1, p - 1))}
                  data-testid="subjects-prev"
                >
                  Prev
                </button>
                <span data-testid="subjects-page-indicator">
                  Page {subjectsPage} of {Math.max(1, Math.ceil(filteredSubjects.length / subjectsPageSize))}
                </span>
                <button
                  className="btn btn-secondary"
                  style={{ fontSize: 11, padding: '3px 10px' }}
                  disabled={subjectsPage >= Math.ceil(filteredSubjects.length / subjectsPageSize)}
                  onClick={() => setSubjectsPage(p => p + 1)}
                  data-testid="subjects-next"
                >
                  Next
                </button>
              </div>
            </div>
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
