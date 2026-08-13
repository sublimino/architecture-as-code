/**
 * NetworkTestsPage — surfaces NetAssert network policy test
 * results, CI pipeline results, and agent test infrastructure status.
 *
 * The NetAssert section is live: it reads the current state of the
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
import { Fragment, useState, useEffect, useCallback, useRef, type CSSProperties } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { isDemoMode } from '../api/demoMode'
import { StatCard, Section, Pill } from '../components/DashKit'
import ButtonWait from '../components/ButtonWait'
import DataTable from '../components/DataTable'
import LoadingState from '../components/LoadingState'
import { ProofConsole, type Proof } from '../components/ProofConsole'
import { colors } from '../styles/tokens'
import { curlPipeJq, jqOutput, jqString } from './proofQuery'
import type { NetworkTestListResponse, NetworkTestResult } from '../types/api'

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

/**
 * The row-level "How do we know?" control.
 *
 * Deliberately the same 10px bordered-transparent shape CredentialEvidencePanel
 * gives its per-step disclosure rather than `.btn btn-secondary`: this sits
 * inside a dense table cell under an 11px description, and a 13px padded
 * button there outweighs the row it belongs to. Tokens throughout, so it
 * follows all three themes.
 */
const proofButton: CSSProperties = {
  marginTop: 6, fontSize: 10, padding: '3px 8px', borderRadius: 4, cursor: 'pointer',
  border: '1px solid var(--border)', background: 'transparent', color: 'var(--muted)',
  fontWeight: 400,
}

// Poll while a scan is running so the board reflects completion without a
// manual refresh. Bounded so a Job that never finishes (RBAC misconfigured,
// image pull failure, etc.) doesn't poll forever — the last-known state and
// the scanStatus pill both stay visible either way.
const POLL_MS = 2500
// A live NetAssert Job took 39 seconds; 48 polls retain 2.5-second
// responsiveness while allowing 120 seconds of bounded recovery headroom.
const MAX_POLLS = 48

export function isPollExhausted(pollCount: number): boolean {
  return pollCount >= MAX_POLLS
}

export function isScanActive(status: NetworkTestListResponse['scanStatus'] | undefined): boolean {
  return status === 'pending' || status === 'running'
}

/**
 * The endpoint whose response every NetAssert row on this page is a view of.
 *
 * Named here rather than inlined because the proof below promises it is the
 * route the client called, and the two must not be able to drift apart —
 * see `api.networkTests.list`.
 */
const NETWORK_TESTS_ENDPOINT = '/network-tests'

/**
 * Reserved so the control does not resize when its label becomes a loader.
 *
 * Fits the widest of the three states — "Refresh Results" — which is wider
 * than ButtonWait's own reserved width, so nothing in the header row moves at
 * either transition. A toolbar button that jumps mid-scan reads to a room as a
 * fault, and this page's whole subject is telling faults from non-faults.
 */
const SCAN_BUTTON_W = 152

/**
 * "How do we know this test passed?", answered from the response itself.
 *
 * The whole verdict for a row is three fields the server derived from the
 * netassert Job's own TAP output (see `_network_test_result` in
 * fake-integration-proxy/server.py): `result`, `evidence` — the literal TAP
 * line, or an explicit sentence saying why there is no verdict — and
 * `lastRun`. The assertion those were judged against is the other six. All
 * nine came down the same request, so one command reproduces the lot.
 *
 * Every field here is passed through by the client untouched, which is what
 * lets the printed object be the command's real output rather than a
 * re-rendering of it.
 *
 * DEMO MODE RETURNS NO PROOF, and that is the honest answer rather than a gap.
 * With the toggle on, `api.networkTests.list` short-circuits to
 * fakeNetworkTestsData before any HTTP happens (see fakeData's route table),
 * so no request was issued and no command would reproduce this row. Showing
 * one anyway is precisely the fabricated-probe failure this page has a history
 * of. ProofConsole renders an empty list as "(no proof was recorded for this
 * step)", which is true.
 */
export function netAssertProofs(
  test: NetworkTestResult,
  tests: NetworkTestResult[],
  demo: boolean,
): Proof[] {
  if (demo) return []
  const projection =
    '{name, description, src, dst, targetPort, expectedExit, result, evidence, lastRun}'
  // Every match, not just the row that was clicked: `select` is a stream, and
  // a duplicated test name would make the command print two objects.
  const matches = tests
    .filter((t) => t.name === test.name)
    .map((t) => ({
      name: t.name,
      description: t.description,
      src: t.src,
      dst: t.dst,
      targetPort: t.targetPort,
      expectedExit: t.expectedExit,
      result: t.result,
      evidence: t.evidence,
      lastRun: t.lastRun,
    }))
  return [
    {
      label: 'Verdict',
      command: curlPipeJq({
        path: NETWORK_TESTS_ENDPOINT,
        bearer: true,
        filter: `.tests[] | select(.name == ${jqString(test.name)}) | ${projection}`,
      }),
      detail: jqOutput(matches),
    },
  ]
}

function latestLastRun(tests: NetworkTestResult[]): string | null {
  return tests.reduce<string | null>((latest, test) => {
    if (!test.lastRun || Number.isNaN(Date.parse(test.lastRun))) return latest
    if (!latest || Date.parse(test.lastRun) > Date.parse(latest)) return test.lastRun
    return latest
  }, null)
}

export default function NetworkTestsPage() {
  const { getAccessTokenSilently } = useAuth0()
  const [filter, setFilter] = useState<TestFilter>('all')
  const [data, setData] = useState<NetworkTestListResponse | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [scanning, setScanning] = useState(false)
  const [scanError, setScanError] = useState<string | null>(null)
  const [pollExhausted, setPollExhausted] = useState(false)
  // Which rows have their proof console open, keyed by test name — the only
  // source of truth for that. A derived "show all" flag combined with `||` is
  // how the credential card shipped a row control that looked live and was
  // dead for as long as the global one was on.
  const [openProof, setOpenProof] = useState<Record<string, boolean>>({})
  const pollCount = useRef(0)
  const demo = isDemoMode()

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

  // Poll while the server has accepted a scan, including its pending phase.
  useEffect(() => {
    if (!isScanActive(data?.scanStatus)) {
      pollCount.current = 0
      setPollExhausted(false)
      return
    }
    if (isPollExhausted(pollCount.current)) {
      setPollExhausted(true)
      return
    }
    const t = setTimeout(() => {
      pollCount.current += 1
      load()
    }, POLL_MS)
    return () => clearTimeout(t)
  }, [data, load])

  async function handleScan() {
    setScanning(true)
    setScanError(null)
    setPollExhausted(false)
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

  async function handleRefresh() {
    pollCount.current = 0
    setPollExhausted(false)
    await load()
  }

  const tests = data?.tests ?? []
  const allowed = tests.filter((t) => t.expectedExit === 0)
  const denied = tests.filter((t) => t.expectedExit === 1)
  const displayed = filter === 'allowed' ? allowed : filter === 'denied' ? denied : tests

  const passCount = tests.filter((t) => t.result === 'pass').length
  const failCount = tests.filter((t) => t.result === 'fail' || t.result === 'error').length
  const allPass = tests.length > 0 && tests.every((t) => t.result === 'pass')
  const scanInProgress = scanning || (isScanActive(data?.scanStatus) && !pollExhausted)
  const lastRun = latestLastRun(tests)

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
            NetAssert integration, CI pipeline results, and agent test infrastructure
          </div>
        </div>
        {data && tests.length > 0 && <Pill label={allPass ? 'healthy' : 'degraded'} />}
        <button
          type="button"
          className="btn btn-primary"
          onClick={pollExhausted ? handleRefresh : handleScan}
          disabled={scanInProgress}
          aria-busy={scanInProgress}
          aria-label={scanInProgress ? 'Network test scan in progress' : pollExhausted ? 'Refresh network test results' : 'Run network test scan now'}
          // Reserved width and centring so the loader occupies exactly the
          // space the label vacated. See SCAN_BUTTON_W.
          style={{ minWidth: SCAN_BUTTON_W, justifyContent: 'center' }}
        >
          {/* The shared in-button wait, not a bespoke "Scanning…". A scan
              takes about forty seconds against a live cluster, and a static
              word reads identically at second two and second ninety —
              ButtonWait carries the elapsed figure that tells those apart,
              and owns no live region of its own because the button already
              has a name and a disabled state. */}
          {scanInProgress
            ? <ButtonWait testId="network-tests-scan-wait" label="Scanning" />
            : pollExhausted ? 'Refresh Results' : 'Scan Now'}
        </button>
      </div>

      {loadError && (
        <div className="card" style={{ padding: 16, marginBottom: 16 }}>
          <LoadingState
            status="error"
            label="network test results"
            error={loadError}
            onRetry={load}
            testId="network-tests-load-state"
          />
        </div>
      )}
      {scanError && (
        <div className="card" style={{ padding: 16, marginBottom: 16 }}>
          <LoadingState
            status="error"
            label="scan"
            error={`Scan failed: ${scanError}`}
            testId="network-tests-scan-state"
          />
        </div>
      )}
      {!data && !loadError && (
        <div className="card" style={{ padding: 16, marginBottom: 16 }}>
          <LoadingState status="loading" label="network test results" testId="network-tests-load-state" />
        </div>
      )}

      {/* Summary stats */}
      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 28 }}>
        <StatCard label="NetAssert assertions" value={String(tests.length)} sub={`${allowed.length} allowed, ${denied.length} denied`} accent={colors.cyanLoom} />
        <StatCard label="Passing" value={String(passCount)} sub={`of ${tests.length} scored`} accent={colors.tealLoom} />
        <StatCard label="Failing" value={String(failCount)} sub={data ? `scan: ${data.scanStatus}` : loadError ? 'unavailable' : 'loading…'} accent={failCount > 0 ? colors.amber : colors.tealLoom} />
        <StatCard label="CI pass" value={String(CI_SUMMARY.pass)} sub={`of ${CI_SUMMARY.pass + CI_SUMMARY.fail + CI_SUMMARY.error} scored`} accent={colors.tealLoom} />
        <StatCard label="Agent tests" value={`${totalAgentPassed}/${totalAgentTests}`} sub="across fe-signalloom-agents" accent={totalAgentPassed === totalAgentTests ? colors.tealLoom : colors.amber} />
      </div>

      {/* ── NetAssert ── */}
      <Section title="NetAssert — Network Policy Assertions" hint={lastRun ? `last run ${fmtDate(lastRun)}` : 'netassert-signalloom.yaml'}>
        {/* Lifecycle chips in the sanctioned shape — see the DataTable section
            of the Design System page, which documents this exact selected
            treatment. Two things were wrong before and both were invisible in
            Dark: the selected fill was a literal `rgba(6,182,212,0.10)` that
            does not move with the theme, and the group announced nothing —
            no `aria-pressed`, so a screen reader could not tell which of the
            three was in force. `type="button"` because an unqualified button
            inside a form submits it. */}
        <div style={{ display: 'flex', gap: 8, marginBottom: 12 }} role="group" aria-label="Filter NetAssert assertions">
          {(['all', 'allowed', 'denied'] as TestFilter[]).map((f) => {
            const selected = filter === f
            return (
              <button
                key={f}
                type="button"
                onClick={() => setFilter(f)}
                aria-pressed={selected}
                data-testid={`netassert-filter-${f}`}
                style={{
                  padding: '4px 12px',
                  borderRadius: 6,
                  fontSize: 12,
                  fontWeight: selected ? 600 : 400,
                  cursor: 'pointer',
                  textTransform: 'capitalize',
                  // A tinted fill plus a full-strength border rather than a
                  // solid accent: text on solid cyan fails AA in at least one
                  // of the three themes.
                  color: selected ? 'var(--cyan)' : 'var(--muted)',
                  background: selected ? 'color-mix(in srgb, var(--cyan) 12%, transparent)' : 'var(--surface2)',
                  border: `1px solid ${selected ? 'color-mix(in srgb, var(--cyan) 45%, transparent)' : 'var(--border)'}`,
                }}
              >
                {f} {f === 'all' ? `(${tests.length})` : f === 'allowed' ? `(${allowed.length})` : `(${denied.length})`}
              </button>
            )
          })}
        </div>
        {data?.scanStatus === 'never-run' && (
          <div className="card" style={{ padding: 16, marginBottom: 12 }}>
            <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}>
              No scan has been run yet
            </div>
            <div style={{ fontSize: 13, color: 'var(--muted)' }}>
              Click <strong>Scan Now</strong> to run the NetAssert suite against the live cluster.
            </div>
          </div>
        )}
        {pollExhausted && (
          <div className="card" role="status" style={{ padding: 16, marginBottom: 12 }}>
            Automatic refresh stopped after 120 seconds. Refresh results to check the scan status.
          </div>
        )}
        <DataTable<NetworkTestResult>
          columns={[
            { key: 'name', label: 'Test', sortable: true },
            { key: 'description', label: 'Direction' },
            { key: 'targetPort', label: 'Port', sortable: true },
            { key: 'expectedExit', label: 'Expected' },
            { key: 'result', label: 'Result', sortable: true },
            { key: 'lastRun', label: 'Last Run', sortable: true },
          ]}
          data={displayed}
          pageSize={25}
          testIdPrefix="netserts"
          renderRow={(t) => {
            const proofOpen = openProof[t.name] === true
            return (
            <Fragment key={t.name}>
            <tr style={{ borderBottom: proofOpen ? undefined : '1px solid var(--border)' }}>
              <td style={{ ...DataTable.td, fontWeight: 500 }}>
                <div>{t.name}</div>
                <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>{t.description}</div>
                {/* The same disclosure the Credential Lifecycle card uses, at
                    the same altitude: a reachability verdict is a claim about
                    the cluster, and a claim a reader cannot re-run is
                    indistinguishable from one nobody checked. */}
                <button
                  type="button"
                  data-testid={`netassert-disclose-${t.name}`}
                  onClick={() => setOpenProof((prev) => ({ ...prev, [t.name]: prev[t.name] !== true }))}
                  style={proofButton}
                >
                  {proofOpen ? 'Hide proof' : 'How do we know?'}
                </button>
              </td>
              <td style={DataTable.td}>
                <code style={{ fontSize: 11, color: 'var(--cyan)' }}>
                  {t.src.namespace}/{t.src.name}
                </code>
                <span style={{ margin: '0 4px', color: 'var(--muted)' }}>{t.expectedExit === 0 ? '→' : '✘'}</span>
                <code style={{ fontSize: 11, color: 'var(--cyan)' }}>
                  {t.dst.namespace}/{t.dst.name}
                </code>
              </td>
              <td style={DataTable.td}>{t.targetPort}</td>
              <td style={DataTable.td}><Pill label={t.expectedExit === 0 ? 'active' : 'blocked'} /></td>
              <td style={DataTable.td}><Pill label={t.result} /></td>
              <td style={{ ...DataTable.td, fontSize: 11, color: 'var(--muted)' }}>{fmtDate(t.lastRun)}</td>
            </tr>
            {proofOpen && (
              <tr style={{ borderBottom: '1px solid var(--border)' }}>
                <td colSpan={6} style={{ ...DataTable.td, padding: '0 14px 10px', whiteSpace: 'normal' }}>
                  <ProofConsole proofs={netAssertProofs(t, tests, demo)} testId={`netassert-console-${t.name}`} />
                </td>
              </tr>
            )}
            </Fragment>
            )
          }}
        />
        <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 8 }}>
          Run: <code style={{ color: 'var(--cyan)' }}>netassert run --config d2-signalloom/test/netassert-signalloom.yaml</code>
        </div>
      </Section>

      {/* ── CI Pipeline Results ── */}
      <Section title="CI Pipeline Results" hint="signalloom-ci-run-5 | 2026-08-01">
        <DataTable<CIResult>
          columns={[
            { key: 'source', label: 'Source', sortable: true },
            { key: 'rule', label: 'Rule', sortable: true },
            { key: 'category', label: 'Category', sortable: true },
            { key: 'result', label: 'Result', sortable: true },
          ]}
          data={CI_RESULTS}
          pageSize={25}
          testIdPrefix="ci-results"
          renderRow={(r, i) => (
            <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...DataTable.td, fontWeight: 500 }}>{r.source}</td>
              <td style={{ ...DataTable.td, maxWidth: 420, whiteSpace: 'normal', lineHeight: 1.4 }}>{r.rule}</td>
              <td style={DataTable.td}><Pill label={r.category === 'topology' ? 'info' : r.category} /></td>
              <td style={DataTable.td}><Pill label={r.result} /></td>
            </tr>
          )}
        />
        <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 8 }}>
          Showing {CI_RESULTS.length} of {CI_SUMMARY.pass + CI_SUMMARY.fail + CI_SUMMARY.error + CI_SUMMARY.skip} total results from signalloom-ci-pipeline
        </div>
      </Section>

      {/* ── Agent Test Infrastructure ── */}
      <Section title="Agent Test Infrastructure" hint="fe-signalloom-agents namespace">
        <DataTable<AgentTestEntry>
          columns={[
            { key: 'name', label: 'Agent', sortable: true },
            { key: 'namespace', label: 'Namespace' },
            { key: 'type', label: 'Type', sortable: true },
            { key: 'status', label: 'Status', sortable: true },
            { key: 'testsRun', label: 'Tests', sortable: true },
            { key: 'lastRun', label: 'Last Run', sortable: true },
          ]}
          data={AGENT_TESTS}
          pageSize={25}
          testIdPrefix="agent-tests"
          renderRow={(a) => (
            <tr key={a.name} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...DataTable.td, fontWeight: 500 }}>{a.name}</td>
              <td style={DataTable.td}><code style={{ fontSize: 11, color: 'var(--cyan)' }}>{a.namespace}</code></td>
              <td style={DataTable.td}>{a.type}</td>
              <td style={DataTable.td}><Pill label={a.status} /></td>
              <td style={DataTable.td}>
                <span style={{ color: a.testsPassed === a.testsRun ? colors.tealLoom : colors.amber, fontWeight: 600 }}>
                  {a.testsPassed}
                </span>
                <span style={{ color: 'var(--muted)' }}>/{a.testsRun}</span>
              </td>
              <td style={{ ...DataTable.td, fontSize: 11, color: 'var(--muted)' }}>{fmtDate(a.lastRun)}</td>
            </tr>
          )}
        />
      </Section>
    </div>
  )
}
