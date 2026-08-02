/**
 * NetworkTestsPage — surfaces NetSerts (netassert) network policy test
 * results, CI pipeline results, and agent test infrastructure status.
 *
 * The NetSerts section is live: it reads the current state of the
 * netassert-run Kubernetes Job (see d2-signalloom/apps/fake-integration-proxy
 * /server.py) via GET /network-tests, and the "Scan Now" button triggers a
 * real run of the committed d2-signalloom/test/netassert-signalloom.yaml
 * suite via POST /network-tests/scan. In demo mode both calls are served from
 * deterministic offline fixtures (src/api/fakeNetworkTestsData.ts) that
 * simulate the same running -> complete transition.
 *
 * CI Pipeline Results and Agent Test Infrastructure below are unrelated
 * subsystems and remain self-contained demo data.
 */
import { useState, useEffect, useCallback, useRef } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { StatCard, Section, Table, Pill, td } from '../components/DashKit'
import { colors } from '../styles/tokens'
import type { NetworkTestListResponse } from '../types/api'

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

function fmtDate(iso: string | null) {
  if (!iso) return '—'
  return new Date(iso).toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })
}

type TestFilter = 'all' | 'allowed' | 'denied'

// Poll while a scan is running so the board reflects completion without a
// manual refresh. Bounded so a Job that never finishes (RBAC misconfigured,
// image pull failure, etc.) doesn't poll forever — the last-known state and
// the scanStatus pill both stay visible either way.
const POLL_MS = 2500
const MAX_POLLS = 40

export default function NetworkTestsPage() {
  const { getAccessTokenSilently } = useAuth0()
  const [filter, setFilter] = useState<TestFilter>('all')
  const [data, setData] = useState<NetworkTestListResponse | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [scanning, setScanning] = useState(false)
  const [scanError, setScanError] = useState<string | null>(null)
  const pollCount = useRef(0)

  const load = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const res = await api.networkTests.list(token)
      setData(res)
      setLoadError(null)
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : 'Failed to load network test results')
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    load()
  }, [load])

  // Poll only while a scan is actually in progress.
  useEffect(() => {
    if (data?.scanStatus !== 'running') {
      pollCount.current = 0
      return
    }
    if (pollCount.current >= MAX_POLLS) return
    const t = setTimeout(() => {
      pollCount.current += 1
      load()
    }, POLL_MS)
    return () => clearTimeout(t)
  }, [data?.scanStatus, load])

  async function handleScan() {
    setScanning(true)
    setScanError(null)
    try {
      const token = await getAccessTokenSilently()
      await api.networkTests.scan(token)
      pollCount.current = 0
      await load()
    } catch (e) {
      setScanError(e instanceof Error ? e.message : 'Scan failed to start')
    } finally {
      setScanning(false)
    }
  }

  const tests = data?.tests ?? []
  const allowed = tests.filter((t) => t.expectedExit === 0)
  const denied = tests.filter((t) => t.expectedExit === 1)
  const displayed = filter === 'allowed' ? allowed : filter === 'denied' ? denied : tests

  const passCount = tests.filter((t) => t.result === 'pass').length
  const failCount = tests.filter((t) => t.result === 'fail' || t.result === 'error').length
  const allPass = tests.length > 0 && tests.every((t) => t.result === 'pass')
  const scanInProgress = scanning || data?.scanStatus === 'running'
  const lastRun = tests.find((t) => t.lastRun)?.lastRun ?? null

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
        {data && tests.length > 0 && <Pill label={allPass ? 'healthy' : 'degraded'} />}
        <button
          type="button"
          className="btn btn-primary"
          onClick={handleScan}
          disabled={scanInProgress}
          aria-busy={scanInProgress}
          aria-label={scanInProgress ? 'Network test scan in progress' : 'Run network test scan now'}
        >
          {scanInProgress ? 'Scanning…' : 'Scan Now'}
        </button>
      </div>

      {loadError && (
        <div className="card" role="alert" style={{ padding: 16, marginBottom: 16, color: 'var(--error)' }}>
          {loadError}
        </div>
      )}
      {scanError && (
        <div className="card" role="alert" style={{ padding: 16, marginBottom: 16, color: 'var(--error)' }}>
          Scan failed: {scanError}
        </div>
      )}

      {/* Summary stats */}
      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 28 }}>
        <StatCard label="NetSerts assertions" value={String(tests.length)} sub={`${allowed.length} allowed, ${denied.length} denied`} accent={colors.cyanLoom} />
        <StatCard label="Passing" value={String(passCount)} sub={`of ${tests.length} scored`} accent={colors.tealLoom} />
        <StatCard label="Failing" value={String(failCount)} sub={data ? `scan: ${data.scanStatus}` : 'loading…'} accent={failCount > 0 ? colors.amber : colors.tealLoom} />
        <StatCard label="CI pass" value={String(CI_SUMMARY.pass)} sub={`of ${CI_SUMMARY.pass + CI_SUMMARY.fail + CI_SUMMARY.error} scored`} accent={colors.tealLoom} />
        <StatCard label="Agent tests" value={`${totalAgentPassed}/${totalAgentTests}`} sub="across fe-signalloom-agents" accent={totalAgentPassed === totalAgentTests ? colors.tealLoom : colors.amber} />
      </div>

      {/* ── NetSerts ── */}
      <Section title="NetSerts — Network Policy Assertions" hint={lastRun ? `last run ${fmtDate(lastRun)}` : 'netassert-signalloom.yaml'}>
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
              {f} {f === 'all' ? `(${tests.length})` : f === 'allowed' ? `(${allowed.length})` : `(${denied.length})`}
            </button>
          ))}
        </div>
        {data?.scanStatus === 'never-run' && (
          <div className="card" style={{ padding: 16, marginBottom: 12 }}>
            <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}>
              No scan has been run yet
            </div>
            <div style={{ fontSize: 13, color: 'var(--muted)' }}>
              Click <strong>Scan Now</strong> to run the NetSerts suite against the live cluster.
            </div>
          </div>
        )}
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
                <span style={{ margin: '0 4px', color: 'var(--muted)' }}>{t.expectedExit === 0 ? '→' : '✘'}</span>
                <code style={{ fontSize: 11, color: 'var(--cyan)' }}>
                  {t.dst.namespace}/{t.dst.name}
                </code>
              </td>
              <td style={td}>{t.targetPort}</td>
              <td style={td}><Pill label={t.expectedExit === 0 ? 'active' : 'blocked'} /></td>
              <td style={td}><Pill label={t.result} /></td>
              <td style={{ ...td, fontSize: 11, color: 'var(--muted)' }}>{fmtDate(t.lastRun)}</td>
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
