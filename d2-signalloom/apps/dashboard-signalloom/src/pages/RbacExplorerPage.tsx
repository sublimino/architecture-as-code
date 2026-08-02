/**
 * RBAC Explorer — native Signal Loom view of KubeSec-AFM analysis data.
 *
 * Pulls cluster RBAC, escalation analysis, conformance, and shared-role data
 * from the AFM API through the nginx proxy. Presents it in the Signal Loom UI
 * idiom with a namespace selector for filtering.
 *
 * Runs in parallel with the iframe'd AFM dashboard (RBAC Analysis page) so both
 * views can be compared. In future, remote cluster connectors will plug into the
 * same cluster selector pattern used here.
 */
import { Component, useCallback, useEffect, useMemo, useState, type ErrorInfo, type ReactNode } from 'react'
import { StatCard, Section, Table, Pill, td } from '../components/DashKit'
import { colors } from '../styles/tokens'

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

interface ClusterMeta { id: string; name: string }
interface Subject { name: string; kind: string; namespace?: string }
interface RoleRule { verbs: string[]; apiGroups: string[]; resources: string[] }
interface Role { name: string; scope: string; namespace?: string; rules: RoleRule[] }
interface Binding { name: string; scope: string; namespace?: string; roleRef: string; subjects: Subject[] }
interface RBACData { subjects: Subject[]; roles: Role[]; bindings: Binding[] }
interface AnalysisResult {
  metadata?: {
    admins?: string[]; full_admins?: string[]; non_admins?: string[]; namespaces?: string[]
  }
  escalation_paths?: unknown[]
  group_escalations?: unknown[]
}
interface ConformanceIssue { issue?: string; reason?: string; severity?: string; role?: unknown; namespace?: unknown; details?: string; rule?: unknown }
interface SharedRole { role: string; shared_by: number; reason?: string; risk?: string }

const AFM = '/afm'

async function fetchJson<T>(path: string): Promise<T | null> {
  const url = `${AFM}${path}`
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 15_000)
  try {
    const res = await fetch(url, { signal: controller.signal })
    clearTimeout(timeout)
    if (!res.ok) {
      console.warn(`[rbac-explorer] ${url} → ${res.status}`)
      return null
    }
    return await res.json() as T
  } catch (e) {
    clearTimeout(timeout)
    console.error(`[rbac-explorer] ${url} failed:`, e)
    return null
  }
}

export default function RbacExplorerPage() {
  const [clusters, setClusters] = useState<ClusterMeta[]>([])
  const [clusterId, setClusterId] = useState<string>('')
  const [rbac, setRbac] = useState<RBACData | null>(null)
  const [analysis, setAnalysis] = useState<AnalysisResult | null>(null)
  const [conformance, setConformance] = useState<ConformanceIssue[]>([])
  const [sharedRoles, setSharedRoles] = useState<SharedRole[]>([])
  const [loading, setLoading] = useState(true)
  const [nsFilter, setNsFilter] = useState<string>('all')

  // Load clusters on mount
  useEffect(() => {
    fetchJson<ClusterMeta[]>('/clusters').then(d => {
      if (d && d.length > 0) {
        setClusters(d)
        setClusterId(d.find(c => c.id === 'local')?.id ?? d[0].id)
      }
      setLoading(false)
    })
  }, [])

  // Load cluster data when cluster changes
  const loadCluster = useCallback(async (id: string) => {
    if (!id) return
    setLoading(true)
    try {
      const [r, a, c, s] = await Promise.all([
        fetchJson<RBACData>(`/clusters/${encodeURIComponent(id)}/rbac`),
        fetchJson<AnalysisResult>(`/clusters/${encodeURIComponent(id)}/analysis/latest`),
        fetchJson<ConformanceIssue[]>(`/clusters/${encodeURIComponent(id)}/rbac/conformance`),
        fetchJson<{ results?: SharedRole[] }>(`/clusters/${encodeURIComponent(id)}/analysis/shared_roles`),
      ])
      setRbac(r)
      setAnalysis(a)
      setConformance(Array.isArray(c) ? c : [])
      const roles = s && 'results' in s ? s.results : (Array.isArray(s) ? s : [])
      setSharedRoles(roles ?? [])
    } catch (e) {
      console.error('[rbac-explorer] loadCluster failed:', e)
    } finally {
      setLoading(false)
      setNsFilter('all')
    }
  }, [])

  useEffect(() => { if (clusterId) loadCluster(clusterId) }, [clusterId, loadCluster])

  // Extract namespaces from RBAC data
  const namespaces = useMemo(() => {
    if (!rbac) return []
    const ns = new Set<string>()
    rbac.roles.forEach(r => { if (r.namespace) ns.add(r.namespace) })
    rbac.bindings.forEach(b => { if (b.namespace) ns.add(b.namespace) })
    rbac.subjects.forEach(s => { if (s.namespace) ns.add(s.namespace) })
    return Array.from(ns).sort()
  }, [rbac])

  // Filter by namespace
  const filteredRoles = useMemo(() => {
    if (!rbac) return []
    if (nsFilter === 'all') return rbac.roles
    return rbac.roles.filter(r => r.scope === 'Cluster' || r.namespace === nsFilter)
  }, [rbac, nsFilter])

  const filteredBindings = useMemo(() => {
    if (!rbac) return []
    if (nsFilter === 'all') return rbac.bindings
    return rbac.bindings.filter(b => b.scope === 'Cluster' || b.namespace === nsFilter)
  }, [rbac, nsFilter])

  const filteredSubjects = useMemo(() => {
    if (!rbac) return []
    if (nsFilter === 'all') return rbac.subjects
    // Show subjects in the selected namespace + cluster-scoped subjects
    const nsBindingSubjects = new Set<string>()
    filteredBindings.forEach(b => b.subjects.forEach(s => nsBindingSubjects.add(`${s.kind}/${s.name}`)))
    return rbac.subjects.filter(s => {
      if (s.namespace === nsFilter) return true
      return nsBindingSubjects.has(`${s.kind}/${s.name}`)
    })
  }, [rbac, nsFilter, filteredBindings])

  const filteredConformance = useMemo(() => {
    if (nsFilter === 'all') return conformance
    return conformance.filter(c => {
      const ns = typeof c.namespace === 'object' && c.namespace ? (c.namespace as { namespace?: string }).namespace : c.namespace
      return !ns || ns === nsFilter
    })
  }, [conformance, nsFilter])

  // Stats
  const adminCount = (analysis?.metadata?.full_admins?.length ?? 0) + (analysis?.metadata?.admins?.length ?? 0)
  const nonAdminCount = analysis?.metadata?.non_admins?.length ?? 0
  const escalationCount = analysis?.escalation_paths?.length ?? 0
  const conformanceIssueCount = conformance.length
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
            {clusters.map(c => (
              <option key={c.id} value={c.id}>{c.name} ({c.id})</option>
            ))}
          </select>
          {/* Namespace selector */}
          <select
            value={nsFilter}
            onChange={e => setNsFilter(e.target.value)}
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
            onClick={() => loadCluster(clusterId)}
          >
            Refresh
          </button>
        </div>
      </div>

      {loading && <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 40 }} data-testid="rbac-loading">Loading…</div>}

      {!loading && !rbac && clusterId && (
        <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 40 }}>
          <p>No RBAC data available for cluster <strong>{clusterId}</strong>.</p>
          <p style={{ fontSize: 12 }}>Ensure the cluster is seeded: <code>scripts/rbac-to-afm.py</code></p>
          <button className="btn btn-secondary" style={{ marginTop: 12 }} onClick={() => loadCluster(clusterId)}>Retry</button>
        </div>
      )}

      {!loading && rbac && (
        <>
          {/* Stats */}
          <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 24 }} data-testid="rbac-stats">
            <StatCard label="Cluster" value={clusterName} sub={`${namespaces.length} namespaces`} accent="var(--cyan)" />
            <StatCard label="Subjects" value={String(filteredSubjects.length)} sub={`${adminCount} admins, ${nonAdminCount} non-admin`} accent="var(--teal)" />
            <StatCard label="Roles" value={String(filteredRoles.length)} sub={`${filteredRoles.filter(r => r.scope === 'Cluster').length} cluster-scoped`} accent="var(--violet)" />
            <StatCard label="Escalation Paths" value={String(escalationCount)} sub={escalationCount === 0 ? 'No escalation detected' : 'Requires attention'} accent={escalationCount > 0 ? 'var(--error)' : 'var(--teal)'} />
          </div>

          {/* Conformance issues */}
          {filteredConformance.length > 0 && (
            <Section title="Conformance Issues" hint={`${filteredConformance.length} findings`}>
              <Table headers={['Issue', 'Severity', 'Role', 'Namespace', 'Details']}>
                {filteredConformance.slice(0, 20).map((c, i) => (
                  <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
                    <td style={{ ...td, whiteSpace: 'normal', maxWidth: 300 }}>{c.reason ?? c.issue ?? '—'}</td>
                    <td style={td}><Pill label={c.severity ?? 'info'} /></td>
                    <td style={td}><code style={{ fontSize: 12, color: 'var(--violet)' }}>{typeof c.role === 'object' && c.role ? (c.role as { name?: string }).name ?? '—' : String(c.role ?? '—')}</code></td>
                    <td style={{ ...td, color: 'var(--muted)' }}>{typeof c.namespace === 'object' ? '—' : String(c.namespace ?? 'cluster')}</td>
                    <td style={{ ...td, color: 'var(--muted)', whiteSpace: 'normal', maxWidth: 250 }}>{typeof c.details === 'string' ? c.details : '—'}</td>
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
          {sharedRoles.length > 0 && (
            <Section title="Shared-Role Pivot Points" hint="roles shared by multiple subjects">
              <Table headers={['Role', 'Shared By', 'Why', 'Risk']}>
                {sharedRoles.slice(0, 15).map((sr, i) => (
                  <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
                    <td style={td}><code style={{ color: 'var(--violet)', fontSize: 12 }}>{sr.role}</code></td>
                    <td style={{ ...td, color: 'var(--muted)' }}>{sr.shared_by} subjects</td>
                    <td style={{ ...td, color: 'var(--muted)', whiteSpace: 'normal' }}>{sr.reason ?? '—'}</td>
                    <td style={td}>{sr.risk ? <Pill label={sr.risk} /> : '—'}</td>
                  </tr>
                ))}
              </Table>
            </Section>
          )}

          {/* Roles table */}
          <Section title="Roles" hint={`${nsFilter === 'all' ? 'all namespaces' : nsFilter} · ${filteredRoles.length} roles`}>
            <Table headers={['Name', 'Scope', 'Namespace', 'Rules', 'Verbs']}>
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

          {/* Subjects table */}
          <Section title="Subjects" hint={`${filteredSubjects.length} subjects`}>
            <Table headers={['Name', 'Kind', 'Namespace', 'Bound Roles']}>
              {filteredSubjects.slice(0, 30).map((s, i) => {
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
                  </tr>
                )
              })}
            </Table>
            {filteredSubjects.length > 30 && (
              <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6 }}>
                Showing 30 of {filteredSubjects.length} subjects
              </div>
            )}
          </Section>
        </>
      )}
    </div>
    </RbacErrorBoundary>
  )
}
