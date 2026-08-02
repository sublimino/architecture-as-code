/**
 * NetworkTestsPage — surfaces NetSerts (netassert) network policy test definitions
 * and CI pipeline results into the Signal Loom dashboard.
 *
 * Three sections:
 * 1. NetSerts network policy assertions (from netassert-signalloom.yaml)
 * 2. CI pipeline results summary (from signalloom-ci-report.yaml run 5)
 * 3. Agent test infrastructure status (fe-signalloom-agents namespace)
 *
 * Self-contained demo data — renders without any API/auth dependency.
 */
import { useState } from 'react'
import { StatCard, Section, Table, Pill, td } from '../components/DashKit'
import { colors } from '../styles/tokens'

// ── NetSerts test definitions (from d2-signalloom/test/netassert-signalloom.yaml) ──

interface NetAssertTest {
  name: string
  type: 'k8s'
  protocol: string
  targetPort: number
  timeoutSeconds: number
  attempts: number
  expectedExit: number // 0 = allowed, 1 = denied
  src: { kind: string; name: string; namespace: string }
  dst: { kind: string; name: string; namespace: string }
  description: string
  lastResult?: 'pass' | 'fail' | 'pending'
  lastRun?: string
}

const NETSERT_TESTS: NetAssertTest[] = [
  // ── ALLOWED paths ──
  {
    name: 'dashboard-to-api-allowed',
    type: 'k8s', protocol: 'tcp', targetPort: 8000, timeoutSeconds: 30, attempts: 3, expectedExit: 0,
    src: { kind: 'deployment', name: 'dashboard-signalloom', namespace: 'fe-signalloom' },
    dst: { kind: 'deployment', name: 'fe-signalloom', namespace: 'fe-signalloom' },
    description: 'Dashboard to API backend (nginx /api proxy)',
    lastResult: 'pass', lastRun: '2026-08-01T10:20:52Z',
  },
  {
    name: 'dashboard-to-dex-allowed',
    type: 'k8s', protocol: 'tcp', targetPort: 5556, timeoutSeconds: 30, attempts: 3, expectedExit: 0,
    src: { kind: 'deployment', name: 'dashboard-signalloom', namespace: 'fe-signalloom' },
    dst: { kind: 'deployment', name: 'dex', namespace: 'inf-signalloom' },
    description: 'Dashboard to Dex (OIDC discovery/auth/token)',
    lastResult: 'pass', lastRun: '2026-08-01T10:20:52Z',
  },
  {
    name: 'api-to-postgresql-allowed',
    type: 'k8s', protocol: 'tcp', targetPort: 5432, timeoutSeconds: 30, attempts: 3, expectedExit: 0,
    src: { kind: 'deployment', name: 'fe-signalloom', namespace: 'fe-signalloom' },
    dst: { kind: 'deployment', name: 'postgresql', namespace: 'inf-signalloom' },
    description: 'API to PostgreSQL (persistence)',
    lastResult: 'pass', lastRun: '2026-08-01T10:20:52Z',
  },
  {
    name: 'api-to-redis-allowed',
    type: 'k8s', protocol: 'tcp', targetPort: 6379, timeoutSeconds: 30, attempts: 3, expectedExit: 0,
    src: { kind: 'deployment', name: 'fe-signalloom', namespace: 'fe-signalloom' },
    dst: { kind: 'deployment', name: 'redis', namespace: 'inf-signalloom' },
    description: 'API to Redis (cache)',
    lastResult: 'pass', lastRun: '2026-08-01T10:20:52Z',
  },
  {
    name: 'api-to-minio-allowed',
    type: 'k8s', protocol: 'tcp', targetPort: 9000, timeoutSeconds: 30, attempts: 3, expectedExit: 0,
    src: { kind: 'deployment', name: 'fe-signalloom', namespace: 'fe-signalloom' },
    dst: { kind: 'deployment', name: 'minio', namespace: 'inf-signalloom' },
    description: 'API to MinIO (report storage)',
    lastResult: 'pass', lastRun: '2026-08-01T10:20:52Z',
  },
  // ── DENIED paths ──
  {
    name: 'agents-to-api-denied',
    type: 'k8s', protocol: 'tcp', targetPort: 8000, timeoutSeconds: 15, attempts: 2, expectedExit: 1,
    src: { kind: 'pod', name: 'agent-patsy', namespace: 'fe-signalloom-agents' },
    dst: { kind: 'deployment', name: 'fe-signalloom', namespace: 'fe-signalloom' },
    description: 'Agent pods MUST NOT reach the API backend directly',
    lastResult: 'pass', lastRun: '2026-08-01T10:20:52Z',
  },
  {
    name: 'agents-to-dashboard-denied',
    type: 'k8s', protocol: 'tcp', targetPort: 8080, timeoutSeconds: 15, attempts: 2, expectedExit: 1,
    src: { kind: 'pod', name: 'agent-patsy', namespace: 'fe-signalloom-agents' },
    dst: { kind: 'deployment', name: 'dashboard-signalloom', namespace: 'fe-signalloom' },
    description: 'Agent pods MUST NOT reach the dashboard',
    lastResult: 'pass', lastRun: '2026-08-01T10:20:52Z',
  },
  {
    name: 'agents-to-postgresql-denied',
    type: 'k8s', protocol: 'tcp', targetPort: 5432, timeoutSeconds: 15, attempts: 2, expectedExit: 1,
    src: { kind: 'pod', name: 'agent-patsy', namespace: 'fe-signalloom-agents' },
    dst: { kind: 'deployment', name: 'postgresql', namespace: 'inf-signalloom' },
    description: 'Agent pods MUST NOT reach PostgreSQL directly',
    lastResult: 'pass', lastRun: '2026-08-01T10:20:52Z',
  },
  {
    name: 'dashboard-to-postgresql-denied',
    type: 'k8s', protocol: 'tcp', targetPort: 5432, timeoutSeconds: 15, attempts: 2, expectedExit: 1,
    src: { kind: 'deployment', name: 'dashboard-signalloom', namespace: 'fe-signalloom' },
    dst: { kind: 'deployment', name: 'postgresql', namespace: 'inf-signalloom' },
    description: 'Dashboard MUST NOT reach PostgreSQL directly (only via API)',
    lastResult: 'pass', lastRun: '2026-08-01T10:20:52Z',
  },
  {
    name: 'dashboard-to-redis-denied',
    type: 'k8s', protocol: 'tcp', targetPort: 6379, timeoutSeconds: 15, attempts: 2, expectedExit: 1,
    src: { kind: 'deployment', name: 'dashboard-signalloom', namespace: 'fe-signalloom' },
    dst: { kind: 'deployment', name: 'redis', namespace: 'inf-signalloom' },
    description: 'Dashboard MUST NOT reach Redis directly',
    lastResult: 'pass', lastRun: '2026-08-01T10:20:52Z',
  },
]

// ── CI Pipeline results (from signalloom-ci-run-5/signalloom-ci-report.yaml) ──

interface CIResult {
  source: string
  rule: string
  category: string
  result: 'pass' | 'fail' | 'error' | 'skip'
}

const CI_SUMMARY = { pass: 176, fail: 14, warn: 0, error: 1, skip: 68 }

const CI_RESULTS: CIResult[] = [
  { source: 'bats-static-contracts', rule: 'split-ready Signalloom topology validates without a control-plane bootstrap', category: 'topology', result: 'pass' },
  { source: 'bats-static-contracts', rule: 'Phase 1 frontend reconciliation does not wait on later acceptance jobs', category: 'topology', result: 'pass' },
  { source: 'bats-static-contracts', rule: 'Discovery Portal package has the frozen runtime contract', category: 'topology', result: 'pass' },
  { source: 'bats-static-contracts', rule: 'Discovery Portal probes and dependency service URLs are explicit', category: 'topology', result: 'pass' },
  { source: 'bats-static-contracts', rule: 'Discovery Portal specifies the image user numerically', category: 'topology', result: 'pass' },
  { source: 'bats-static-contracts', rule: 'Discovery Portal has a service and named demo Secrets', category: 'topology', result: 'pass' },
  { source: 'bats-static-contracts', rule: 'committed bootstrap is regenerated without drift', category: 'topology', result: 'pass' },
  { source: 'bats-static-contracts', rule: 'generator rejects duplicate migration identifiers', category: 'topology', result: 'pass' },
]

// ── Agent test infrastructure (fe-signalloom-agents namespace) ──

interface AgentTestEntry {
  name: string
  namespace: string
  type: string
  status: 'active' | 'pending' | 'degraded'
  lastRun: string
  testsRun: number
  testsPassed: number
}

const AGENT_TESTS: AgentTestEntry[] = [
  { name: 'cardvault', namespace: 'fe-signalloom-agents', type: 'integration', status: 'active', lastRun: '2026-08-01T10:20:52Z', testsRun: 12, testsPassed: 12 },
  { name: 'cardvault-agent', namespace: 'fe-signalloom-agents', type: 'agent-lifecycle', status: 'active', lastRun: '2026-08-01T10:20:52Z', testsRun: 8, testsPassed: 7 },
  { name: 'policy-engine', namespace: 'fe-signalloom-agents', type: 'policy-eval', status: 'active', lastRun: '2026-08-01T10:20:52Z', testsRun: 24, testsPassed: 22 },
  { name: 'fake-integration-proxy', namespace: 'fe-signalloom-agents', type: 'proxy-mock', status: 'pending', lastRun: '2026-08-01T09:15:00Z', testsRun: 6, testsPassed: 6 },
]

// ── helpers ──

function fmtDate(iso: string) {
  return new Date(iso).toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })
}

type TestFilter = 'all' | 'allowed' | 'denied'

export default function NetworkTestsPage() {
  const [filter, setFilter] = useState<TestFilter>('all')

  const allowed = NETSERT_TESTS.filter((t) => t.expectedExit === 0)
  const denied = NETSERT_TESTS.filter((t) => t.expectedExit === 1)
  const displayed = filter === 'allowed' ? allowed : filter === 'denied' ? denied : NETSERT_TESTS

  const allPass = NETSERT_TESTS.every((t) => t.lastResult === 'pass')
  const totalAgentTests = AGENT_TESTS.reduce((s, a) => s + a.testsRun, 0)
  const totalAgentPassed = AGENT_TESTS.reduce((s, a) => s + a.testsPassed, 0)

  return (
    <div>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 24 }}>
        <div style={{ flex: 1 }}>
          <h1 style={{ fontSize: 22, fontWeight: 700, color: 'var(--text)', margin: 0 }}>
            Network Tests
          </h1>
          <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
            NetSerts integration, CI pipeline results, and agent test infrastructure
          </div>
        </div>
        <Pill label={allPass ? 'healthy' : 'degraded'} />
      </div>

      {/* Summary stats */}
      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 28 }}>
        <StatCard label="NetSerts assertions" value={String(NETSERT_TESTS.length)} sub={`${allowed.length} allowed, ${denied.length} denied`} accent={colors.cyanLoom} />
        <StatCard label="CI pass" value={String(CI_SUMMARY.pass)} sub={`of ${CI_SUMMARY.pass + CI_SUMMARY.fail + CI_SUMMARY.error} scored`} accent={colors.tealLoom} />
        <StatCard label="CI fail" value={String(CI_SUMMARY.fail)} sub={`${CI_SUMMARY.error} error, ${CI_SUMMARY.skip} skipped`} accent={CI_SUMMARY.fail > 0 ? colors.amber : colors.tealLoom} />
        <StatCard label="Agent tests" value={`${totalAgentPassed}/${totalAgentTests}`} sub="across fe-signalloom-agents" accent={totalAgentPassed === totalAgentTests ? colors.tealLoom : colors.amber} />
      </div>

      {/* ── NetSerts ── */}
      <Section title="NetSerts — Network Policy Assertions" hint="netassert-signalloom.yaml">
        <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
          {(['all', 'allowed', 'denied'] as TestFilter[]).map((f) => (
            <button
              key={f}
              onClick={() => setFilter(f)}
              style={{
                padding: '4px 12px',
                borderRadius: 6,
                fontSize: 12,
                fontWeight: filter === f ? 600 : 400,
                border: `1px solid ${filter === f ? 'var(--cyan)' : 'var(--border)'}`,
                background: filter === f ? 'rgba(6,182,212,0.10)' : 'transparent',
                color: filter === f ? 'var(--cyan)' : 'var(--muted)',
                cursor: 'pointer',
                textTransform: 'capitalize',
              }}
            >
              {f} {f === 'all' ? `(${NETSERT_TESTS.length})` : f === 'allowed' ? `(${allowed.length})` : `(${denied.length})`}
            </button>
          ))}
        </div>
        <Table headers={['Test', 'Direction', 'Port', 'Expected', 'Result', 'Last Run']}>
          {displayed.map((t) => (
            <tr key={t.name} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...td, fontWeight: 500 }}>
                <div>{t.name}</div>
                <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>{t.description}</div>
              </td>
              <td style={td}>
                <code style={{ fontSize: 11, color: 'var(--cyan)' }}>
                  {t.src.namespace}/{t.src.name}
                </code>
                <span style={{ margin: '0 4px', color: 'var(--muted)' }}>{t.expectedExit === 0 ? '\u2192' : '\u2718'}</span>
                <code style={{ fontSize: 11, color: 'var(--cyan)' }}>
                  {t.dst.namespace}/{t.dst.name}
                </code>
              </td>
              <td style={td}>{t.targetPort}</td>
              <td style={td}><Pill label={t.expectedExit === 0 ? 'active' : 'blocked'} /></td>
              <td style={td}><Pill label={t.lastResult ?? 'pending'} /></td>
              <td style={{ ...td, fontSize: 11, color: 'var(--muted)' }}>{t.lastRun ? fmtDate(t.lastRun) : '\u2014'}</td>
            </tr>
          ))}
        </Table>
        <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 8 }}>
          Run: <code style={{ color: 'var(--cyan)' }}>netassert run --config d2-signalloom/test/netassert-signalloom.yaml</code>
        </div>
      </Section>

      {/* ── CI Pipeline Results ── */}
      <Section title="CI Pipeline Results" hint="signalloom-ci-run-5 | 2026-08-01">
        <Table headers={['Source', 'Rule', 'Category', 'Result']}>
          {CI_RESULTS.map((r, i) => (
            <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...td, fontWeight: 500 }}>{r.source}</td>
              <td style={{ ...td, maxWidth: 420, whiteSpace: 'normal', lineHeight: 1.4 }}>{r.rule}</td>
              <td style={td}><Pill label={r.category === 'topology' ? 'info' : r.category} /></td>
              <td style={td}><Pill label={r.result} /></td>
            </tr>
          ))}
        </Table>
        <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 8 }}>
          Showing {CI_RESULTS.length} of {CI_SUMMARY.pass + CI_SUMMARY.fail + CI_SUMMARY.error + CI_SUMMARY.skip} total results from signalloom-ci-pipeline
        </div>
      </Section>

      {/* ── Agent Test Infrastructure ── */}
      <Section title="Agent Test Infrastructure" hint="fe-signalloom-agents namespace">
        <Table headers={['Agent', 'Namespace', 'Type', 'Status', 'Tests', 'Last Run']}>
          {AGENT_TESTS.map((a) => (
            <tr key={a.name} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...td, fontWeight: 500 }}>{a.name}</td>
              <td style={td}><code style={{ fontSize: 11, color: 'var(--cyan)' }}>{a.namespace}</code></td>
              <td style={td}>{a.type}</td>
              <td style={td}><Pill label={a.status} /></td>
              <td style={td}>
                <span style={{ color: a.testsPassed === a.testsRun ? colors.tealLoom : colors.amber, fontWeight: 600 }}>
                  {a.testsPassed}
                </span>
                <span style={{ color: 'var(--muted)' }}>/{a.testsRun}</span>
              </td>
              <td style={{ ...td, fontSize: 11, color: 'var(--muted)' }}>{fmtDate(a.lastRun)}</td>
            </tr>
          ))}
        </Table>
      </Section>
    </div>
  )
}
