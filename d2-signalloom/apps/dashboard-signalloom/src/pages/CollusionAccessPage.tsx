/**
 * Collusion & Access — ControlPlane KubeSec-AFM (KTP with King's College London).
 *
 * KubeSec-AFM is a formal-methods engine that model-checks Kubernetes RBAC for
 * privilege escalation and *collusion* — groups of subjects (users / service
 * accounts) that can exchange permissions to reach a goal role. It runs bounded
 * model checking over cluster-scoped resources, namespaces, roles and bindings,
 * highlights shared-role "pivot points", and prioritises fixes via a min-cut /
 * max-flow analysis weighted by CVSS + EPSS.
 *
 * The radial cluster graph is used as a page background placeholder now; live
 * graph data plumbs into the same surface later. All tabular data is mock.
 */
import { StatCard, Section, Table, Pill, td } from '../components/DashKit'

const BG = '/ktp-collusion-graph.png'

const PHASES = [
  { n: 'Phase 1', title: 'Admin & self-escalation removal', body: 'Drop subjects who are already cluster-admin or can self-escalate via the escalate verb — they have no incentive to collude.' },
  { n: 'Phase 1.5', title: 'Impersonation check', body: 'Test escalation through impersonation, including a group impersonating a service account in another namespace (unscoped pre-1.36).' },
  { n: 'Phase 2', title: 'Collusion escalation', body: 'Model-check whether pairs of subjects can exchange permissions to jointly reach a higher-privileged role.' },
]

const COLLUSION_PAIRS = [
  { a: 'group:dev-eu', b: 'sa:ci/runner', pivot: 'role:flux-reconciler', goal: 'clusterrole:admin', depth: 4, risk: 'critical' },
  { a: 'sa:apps/frontend', b: 'sa:apps/worker', pivot: 'role:secret-reader', goal: 'role:namespace-admin', depth: 3, risk: 'high' },
  { a: 'group:ops-oncall', b: 'sa:platform/backup', pivot: 'role:pv-manager', goal: 'clusterrole:node-proxy', depth: 5, risk: 'high' },
  { a: 'group:analysts', b: 'sa:data/etl', pivot: 'role:configmap-writer', goal: 'role:workflow-admin', depth: 2, risk: 'medium' },
]

const PIVOTS = [
  { role: 'role:flux-reconciler', sharedBy: 4, reason: 'bound to CI + dev groups; can patch RBAC', risk: 'critical' },
  { role: 'role:secret-reader', sharedBy: 7, reason: 'reads secrets across two namespaces', risk: 'high' },
  { role: 'role:pv-manager', sharedBy: 3, reason: 'PV/PVC mutate → node reach via Longhorn GUI', risk: 'high' },
]

const REMEDIATIONS = [
  { fix: 'Remove escalate verb from role:flux-reconciler', cut: 'min-cut edge', cvss: 8.8, epss: 0.42, reward: 'high' },
  { fix: 'Scope sa:ci/runner to namespace flux-system', cut: 'max-flow bottleneck', cvss: 7.5, epss: 0.18, reward: 'high' },
  { fix: 'Split role:secret-reader per namespace', cut: 'pivot isolation', cvss: 6.5, epss: 0.09, reward: 'medium' },
  { fix: 'NetworkPolicy deny to longhorn-backend', cut: 'lateral cut', cvss: 9.1, epss: 0.55, reward: 'high' },
]

export default function CollusionAccessPage() {
  return (
    <div style={{ position: 'relative', paddingBottom: 40 }}>
      {/* Radial cluster-graph background placeholder — live graph plumbs in here later. */}
      <div
        aria-hidden
        data-testid="ktp-graph-bg"
        data-bg={BG}
        style={{
          position: 'absolute', inset: '-28px -32px 0',
          backgroundImage: `linear-gradient(180deg, rgba(2,6,23,0.72), rgba(2,6,23,0.93)), url(${BG})`,
          backgroundSize: 'cover', backgroundPosition: 'top center', backgroundRepeat: 'no-repeat',
          pointerEvents: 'none', zIndex: 0,
        }}
      />
      <div style={{ position: 'relative', zIndex: 1 }}>
        <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>Collusion &amp; Access</h1>
        <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 22, maxWidth: 780 }}>
          Formal-methods RBAC analysis from ControlPlane <strong style={{ color: 'var(--text)' }}>KubeSec-AFM</strong> (KTP
          with King&apos;s College London) — bounded model checking for privilege escalation and multi-subject
          collusion, with min-cut / max-flow remediation. The radial cluster graph is a live-data placeholder.
        </p>

        <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 28 }}>
          <StatCard label="Subjects analysed" value="212" sub="users, groups, service accounts" accent="var(--cyan)" />
          <StatCard label="Collusion pairs" value={String(COLLUSION_PAIRS.length)} sub="escalation via cooperation" accent="var(--violet)" />
          <StatCard label="Pivot roles" value={String(PIVOTS.length)} sub="shared-role attack surface" accent="var(--amber)" />
          <StatCard label="Priority fixes" value={String(REMEDIATIONS.length)} sub="min-cut / max-flow ranked" accent="var(--teal)" />
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

        <Section title="Collusion Pairs" hint="subjects that jointly escalate">
          <Table headers={['Subject A', 'Subject B', 'Pivot role', 'Goal reached', 'Trace depth', 'Risk']}>
            {COLLUSION_PAIRS.map((c, i) => (
              <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={{ ...td, fontWeight: 500 }}>{c.a}</td>
                <td style={{ ...td, fontWeight: 500 }}>{c.b}</td>
                <td style={td}><code style={{ color: 'var(--violet)', fontSize: 12 }}>{c.pivot}</code></td>
                <td style={td}><code style={{ color: 'var(--amber)', fontSize: 12 }}>{c.goal}</code></td>
                <td style={{ ...td, color: 'var(--muted)' }}>{c.depth} steps</td>
                <td style={td}><Pill label={c.risk} /></td>
              </tr>
            ))}
          </Table>
        </Section>

        <Section title="Shared-Role Pivot Points" hint="where permissions move between colluders">
          <Table headers={['Role', 'Shared by', 'Why it pivots', 'Risk']}>
            {PIVOTS.map((p) => (
              <tr key={p.role} style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={td}><code style={{ color: 'var(--violet)', fontSize: 12 }}>{p.role}</code></td>
                <td style={{ ...td, color: 'var(--muted)' }}>{p.sharedBy} subjects</td>
                <td style={{ ...td, color: 'var(--muted)', whiteSpace: 'normal' }}>{p.reason}</td>
                <td style={td}><Pill label={p.risk} /></td>
              </tr>
            ))}
          </Table>
        </Section>

        <Section title="Remediation Priorities" hint="min-cut / max-flow, weighted by CVSS + EPSS">
          <Table headers={['Fix', 'Cut type', 'CVSS', 'EPSS', 'Reward']}>
            {REMEDIATIONS.map((r, i) => (
              <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={{ ...td, whiteSpace: 'normal', color: 'var(--text)' }}>{r.fix}</td>
                <td style={{ ...td, color: 'var(--muted)' }}>{r.cut}</td>
                <td style={td}>{r.cvss.toFixed(1)}</td>
                <td style={td}>{r.epss.toFixed(2)}</td>
                <td style={td}><Pill label={r.reward} /></td>
              </tr>
            ))}
          </Table>
        </Section>
      </div>
    </div>
  )
}
