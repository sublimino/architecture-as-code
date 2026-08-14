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
import { Fragment, useState, useEffect, useCallback, useMemo, useRef, type CSSProperties, type ReactNode } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { isDemoMode } from '../api/demoMode'
import { StatCard, Section } from '../components/DashKit'
import ButtonWait from '../components/ButtonWait'
import DataTable from '../components/DataTable'
import EmptyState from '../components/EmptyState'
import HelpHint from '../components/HelpHint'
import LoadingState from '../components/LoadingState'
import StatusBadge from '../components/StatusBadge'
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

/** Everything the run scored, including skips — what the eight rows below are a sample of. */
const CI_TOTAL = CI_SUMMARY.pass + CI_SUMMARY.fail + CI_SUMMARY.error + CI_SUMMARY.skip

/**
 * The full outcome vocabulary, deliberately not derived from the loaded rows.
 *
 * Every row in CI_RESULTS passed, so chips built from the data would offer
 * `all` and `pass` and nothing else — a filter group that quietly agrees the
 * pipeline is green while the same run recorded fourteen failures and an
 * error. The zeros are the information.
 */
const CI_OUTCOMES = ['all', 'pass', 'fail', 'error', 'skip'] as const

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

/** `all` plus every value the `status` field can take, so a zero chip stays visible. */
const AGENT_STATUSES = ['all', 'active', 'pending', 'degraded'] as const

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

// ── One filter vocabulary, three tables ──────────────────────────────────────

/**
 * The toolbar every table on this page gets, in the shape the Design System's
 * "Realistic — the shape AgentsPage needs" specimen documents: a search box,
 * one chip group with counts, a clear control, and a "n of m shown" tally,
 * handed to `DataTable`'s `toolbar` slot so it survives the empty branch.
 *
 * A LOCAL COMPONENT RATHER THAN THREE HAND-ROLLED STRIPS. Three tables on one
 * page is exactly the count at which copies start to drift — one gains a clear
 * button, another spells the tally differently, a third puts the search last —
 * and a reader then has to learn the page three times. The predicate still
 * belongs to each caller, per the DataTable note: this owns the chrome and the
 * a11y contract, never what "matches" means.
 *
 * Not promoted into `components/`: nine other pages are being migrated
 * concurrently and a shared component landing mid-flight is a merge conflict
 * with no owner. If a second page wants this shape it should be lifted then,
 * with both call sites visible.
 */
interface Chip {
  /** Stable id — also the `-filter-<key>` test id suffix. */
  key: string
  count: number
}

interface FilterToolbarProps {
  /** Test-id and control-id prefix, e.g. `netassert` → `netassert-search`. */
  idPrefix: string
  /** Names the `role="group"`; also the noun the search box borrows. */
  groupLabel: string
  searchLabel: string
  placeholder: string
  query: string
  onQuery: (q: string) => void
  chips: Chip[]
  activeChip: string
  onChip: (key: string) => void
  shown: number
  total: number
  /** True when the search box or a non-`all` chip is narrowing the table. */
  narrowed: boolean
  onClear: () => void
  /** Optional disclosure sat beside the tally, where a count needs a caveat. */
  tally?: ReactNode
}

const toolbarRow: CSSProperties = {
  display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8,
}

const searchBox: CSSProperties = {
  fontSize: 12, padding: '5px 9px', minWidth: 230, borderRadius: 4,
  color: 'var(--text)', background: 'var(--surface2)', border: '1px solid var(--border)',
}

/**
 * The sanctioned selected treatment: a tinted fill plus a full-strength border,
 * never a solid accent — text on solid cyan fails AA in at least one of Dark,
 * Light and Andy, and `color-mix` moves with the theme where an `rgba()`
 * literal is correct in exactly one of the three.
 */
function chipStyle(selected: boolean): CSSProperties {
  return {
    padding: '4px 10px', borderRadius: 4, fontSize: 11.5, cursor: 'pointer',
    textTransform: 'capitalize', fontWeight: selected ? 600 : 400,
    color: selected ? 'var(--cyan)' : 'var(--muted)',
    background: selected ? 'color-mix(in srgb, var(--cyan) 12%, transparent)' : 'var(--surface2)',
    border: `1px solid ${selected ? 'color-mix(in srgb, var(--cyan) 45%, transparent)' : 'var(--border)'}`,
  }
}

function FilterToolbar({
  idPrefix, groupLabel, searchLabel, placeholder, query, onQuery,
  chips, activeChip, onChip, shown, total, narrowed, onClear, tally,
}: FilterToolbarProps) {
  return (
    <div style={toolbarRow} role="group" aria-label={groupLabel}>
      <input
        type="search"
        aria-label={searchLabel}
        placeholder={placeholder}
        value={query}
        onChange={(e) => onQuery(e.target.value)}
        data-testid={`${idPrefix}-search`}
        style={searchBox}
      />
      {chips.map((c) => {
        const selected = activeChip === c.key
        return (
          <button
            key={c.key}
            type="button"
            onClick={() => onChip(c.key)}
            aria-pressed={selected}
            data-testid={`${idPrefix}-filter-${c.key}`}
            style={chipStyle(selected)}
          >
            {c.key} <span style={{ color: 'var(--dim)' }}>{c.count}</span>
          </button>
        )
      })}
      {/* Rendered only while something is narrowing the table, and never
          conditioned on the row count: an empty result is precisely when this
          control is needed, and DataTable keeps the toolbar above the empty
          panel so it is still here to click. No aria-label — the visible text
          is the accessible name, so the two can never disagree. */}
      {narrowed && (
        <button
          type="button"
          className="btn btn-secondary"
          style={{ fontSize: 11, padding: '4px 10px' }}
          data-testid={`${idPrefix}-clear`}
          onClick={onClear}
        >
          Clear filters
        </button>
      )}
      <span data-testid={`${idPrefix}-count`} style={{ fontSize: 11.5, color: 'var(--muted)' }}>
        {shown} of {total} shown
      </span>
      {tally}
    </div>
  )
}

/** Case-insensitive substring match over a row's searchable fields. */
function matches(query: string, haystack: (string | number)[]): boolean {
  const q = query.trim().toLowerCase()
  if (!q) return true
  return haystack.some((field) => String(field).toLowerCase().includes(q))
}

// ── Verdicts, and what a verdict is actually worth ───────────────────────────

/**
 * Which of a row's five `result` values are observations and which are not.
 *
 * This page has a documented history of probes reporting a verdict they had
 * not earned, and the server is careful about it: `_network_test_result` in
 * fake-integration-proxy/server.py emits `pass`/`fail` ONLY when netassert
 * actually printed a TAP line for that assertion, and `pending`/`running`/
 * `error` when it did not. Those last three are not weak verdicts, they are
 * the absence of one — an `error` row says nothing whatsoever about whether
 * traffic is permitted.
 *
 * DashKit's `Pill` collapsed that distinction: its colour map paints `error`,
 * `fail` and `unavailable` the same red, so a probe that could not run was
 * indistinguishable at a glance from a policy that had been breached. That is
 * the exact failure mode this product exists to make impossible, so the badge
 * is now `StatusBadge` — whose maps carry `pass` (teal) and `fail` (red) and
 * fall through to neutral for everything else, which is the honest colour for
 * "no verdict".
 */
export type VerdictClass = 'observed' | 'in-flight' | 'not-observed' | 'unavailable'

export function verdictClass(result: NetworkTestResult['result']): VerdictClass {
  if (result === 'pass' || result === 'fail') return 'observed'
  if (result === 'running') return 'in-flight'
  if (result === 'error') return 'unavailable'
  return 'not-observed'
}

/** The one-word qualifier printed under the badge, so the class is legible without hovering. */
const VERDICT_QUALIFIER: Record<VerdictClass, string> = {
  observed: 'observed',
  'in-flight': 'in flight',
  'not-observed': 'not observed',
  unavailable: 'no verdict',
}

/**
 * The tone of the row's "?" — HelpHint colours only the affordance, never the
 * popup, so this ties the hint to the class of claim it is explaining without
 * a coloured panel reading as an error in its own right.
 *
 * Amber for `unavailable` alone. It is the one class that needs a reader's
 * attention and is also the one most likely to be mistaken for a verdict:
 * `pending` and `in-flight` are ordinary states of a scan that has not
 * finished, where a probe that could not report has left a hole in the
 * evidence that nothing on this page will fill on its own.
 */
const VERDICT_TONE: Record<VerdictClass, string> = {
  observed: 'var(--cyan)',
  'in-flight': 'var(--cyan)',
  'not-observed': 'var(--muted)',
  unavailable: 'var(--amber)',
}

/**
 * What was actually observed for this row, and what would have proven the
 * opposite — the sentence a reader needs before treating a green row as proof.
 *
 * The specific traps this page keeps hitting, each stated where it applies:
 * a probe's exit code is one bit covering a dropped packet, an unresolvable
 * name, a missing binary and a dead listener alike; a NetworkPolicy is not
 * enforced at pod start, so a denial asserted early reports a hole that is not
 * there; and a denial with no positive control cannot tell "correctly blocked"
 * from "nothing was listening". The narrative never contradicts `result` — it
 * says what `result` is and is not evidence of.
 */
export function verdictNarrative(test: NetworkTestResult): string {
  const target = `${test.dst.namespace}/${test.dst.name}:${test.targetPort}`
  const cls = verdictClass(test.result)
  const evidence = test.evidence || 'no evidence was recorded'

  if (cls === 'unavailable') {
    return `No verdict — ${evidence}. The probe never reported, so this row is not a denial and not a pass: nothing about ${target} was observed either way.`
  }
  if (cls === 'in-flight') {
    return `No verdict yet — ${evidence}. The scan is still running, so anything shown here is from an earlier run, not this one.`
  }
  if (cls === 'not-observed') {
    return `Nothing observed — ${evidence}. No TAP line exists for this assertion, so ${target} is neither shown reachable nor shown blocked.`
  }
  if (test.expectedExit === 0) {
    return test.result === 'pass'
      ? `Observed — ${evidence}. The probe completed a connection to ${target}, which is positive evidence: a drop, an unresolvable name or a missing probe binary would each have produced a non-zero exit instead.`
      : `Observed — ${evidence}. The probe did not reach ${target} although policy permits it. One non-zero exit covers a dropped packet, a DNS failure and a dead listener alike, so the Job log is what distinguishes them.`
  }
  return test.result === 'pass'
    ? `Observed — ${evidence}. The probe failed to reach ${target}, which is what this deny assertion requires. A refused connection, an unresolvable name, a dead listener or a policy not yet programmed on a just-started pod all look identical here — only an allow assertion against the same destination shows there was something to be blocked from.`
    : `Observed — ${evidence}. The probe reached ${target} although policy denies it. This is the one verdict on the page needing no corroboration: a completed connection is positive evidence the path is open.`
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
  // One vocabulary per table: a free-text query plus the table's single
  // categorical chip group. Held here, not in DataTable, because the predicate
  // is the one thing that can never be shared — see the note on DataTable.
  const [netQuery, setNetQuery] = useState('')
  const [ciQuery, setCiQuery] = useState('')
  const [ciResult, setCiResult] = useState<string>('all')
  const [agentQuery, setAgentQuery] = useState('')
  const [agentStatus, setAgentStatus] = useState<string>('all')
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
  const byDirection = filter === 'allowed' ? allowed : filter === 'denied' ? denied : tests
  // The chip narrows by direction and the search box narrows by everything
  // else, verdict included: `verdictClass` is in the haystack so typing
  // "no verdict" or "unavailable" isolates the rows that observed nothing —
  // the state a reader most often needs to find and the one a pass/fail chip
  // group would have hidden.
  const displayed = useMemo(
    () =>
      byDirection.filter((t) =>
        matches(netQuery, [
          t.name, t.description, t.result, t.targetPort,
          `${t.src.namespace}/${t.src.name}`, `${t.dst.namespace}/${t.dst.name}`,
          VERDICT_QUALIFIER[verdictClass(t.result)],
        ]),
      ),
    [byDirection, netQuery],
  )

  const passCount = tests.filter((t) => t.result === 'pass').length
  const failCount = tests.filter((t) => t.result === 'fail' || t.result === 'error').length
  // Presentation only — `failCount` above is untouched. This is the split it
  // hides: the Failing tile adds probes that never reported to assertions that
  // were actually breached, and the Result column's hint says so rather than
  // the number quietly overstating how much is known to be wrong.
  const unavailableCount = tests.filter((t) => verdictClass(t.result) === 'unavailable').length
  const allPass = tests.length > 0 && tests.every((t) => t.result === 'pass')
  const scanInProgress = scanning || (isScanActive(data?.scanStatus) && !pollExhausted)
  const lastRun = latestLastRun(tests)

  const ciRows = useMemo(
    () =>
      CI_RESULTS.filter(
        (r) =>
          (ciResult === 'all' || r.result === ciResult) &&
          matches(ciQuery, [r.source, r.rule, r.category, r.result]),
      ),
    [ciQuery, ciResult],
  )

  const agentRows = useMemo(
    () =>
      AGENT_TESTS.filter(
        (a) =>
          (agentStatus === 'all' || a.status === agentStatus) &&
          matches(agentQuery, [a.name, a.namespace, a.type, a.status]),
      ),
    [agentQuery, agentStatus],
  )

  const totalAgentTests = AGENT_TESTS.reduce((s, a) => s + a.testsRun, 0)
  const totalAgentPassed = AGENT_TESTS.reduce((s, a) => s + a.testsPassed, 0)

  const netNarrowed = filter !== 'all' || netQuery.trim() !== ''
  const ciNarrowed = ciResult !== 'all' || ciQuery.trim() !== ''
  const agentNarrowed = agentStatus !== 'all' || agentQuery.trim() !== ''

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
        {/* The page's broadest claim, and the one most able to overstate itself:
            `allPass` requires every row to have PASSED, so a suite where one
            probe never reported reads "degraded" exactly as one with a real
            breach does. The badge keeps saying what it always said; the hint
            beside it says what that word is derived from. `pass`/`degraded`
            rather than `healthy`/`degraded` because StatusBadge's maps carry
            those two and paint them teal and amber — `healthy` is in DashKit's
            Pill map only, and Pill renders every badge with no fill at all
            (the known `hex()` defect the Design System page documents). */}
        {data && tests.length > 0 && (
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
            <StatusBadge
              status={allPass ? 'pass' : 'degraded'}
              variant="compliance"
              testId="netassert-suite-badge"
            />
            <HelpHint label="What the suite badge means" testId="netassert-suite-hint">
              {allPass
                ? `All ${tests.length} assertions returned a TAP line and every one of them passed.`
                : `Not every assertion passed. That covers breached policy and probes that never reported alike — ${passCount} passed, ${failCount} are counted failing, of which ${unavailableCount} produced no verdict at all.`}
            </HelpHint>
          </span>
        )}
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
            {
              key: 'description',
              label: 'Direction',
              help: 'Source pod, then destination pod. An arrow is an assertion that the connection must succeed; a cross is an assertion that it must not.',
            },
            { key: 'targetPort', label: 'Port', sortable: true, help: 'The TCP port on the destination that the probe attempts to open.' },
            {
              key: 'expectedExit',
              label: 'Expected',
              help: 'The exit code netassert requires from the probe: allow means it must connect, deny means it must not. A deny assertion passing is not on its own proof the destination was reachable — only an allow assertion against the same destination shows there was a listener to be blocked from.',
            },
            {
              key: 'result',
              label: 'Result',
              sortable: true,
              // The single most misread thing in this product, said once, at
              // the top of the column it applies to.
              help: `Only pass and fail are observations — netassert printed a TAP line for the assertion. pending, running and error are the absence of a verdict: no line was produced, so the row says nothing about whether traffic is permitted. The Failing tile counts error alongside fail, so ${unavailableCount} of the ${failCount} it reports produced no verdict at all.`,
            },
            {
              key: 'lastRun',
              label: 'Last Run',
              sortable: true,
              help: 'When this assertion last produced a TAP line. A timestamp older than the last policy change means the verdict predates it and has not been re-earned.',
            },
          ]}
          data={displayed}
          pageSize={25}
          testIdPrefix="netserts"
          toolbar={
            <FilterToolbar
              idPrefix="netassert"
              groupLabel="Filter NetAssert assertions"
              searchLabel="Search NetAssert assertions"
              placeholder="Search test, pod, port or verdict…"
              query={netQuery}
              onQuery={setNetQuery}
              chips={[
                { key: 'all', count: tests.length },
                { key: 'allowed', count: allowed.length },
                { key: 'denied', count: denied.length },
              ]}
              activeChip={filter}
              onChip={(k) => setFilter(k as TestFilter)}
              shown={displayed.length}
              total={tests.length}
              narrowed={netNarrowed}
              onClear={() => { setFilter('all'); setNetQuery('') }}
            />
          }
          emptyState={
            tests.length === 0 ? (
              // Not the same fact as "your filter matched nothing", and saying
              // so would invent a filter the reader never applied. Amber
              // because an empty suite is an absence of evidence, not a clean
              // bill of health.
              <EmptyState
                tone="amber"
                kicker="No assertions were returned"
                body={`The suite reported nothing to score, so nothing on this page has been observed. Scan status: ${data?.scanStatus ?? 'not loaded'}.`}
              />
            ) : (
              <EmptyState
                kicker="Nothing matches this filter"
                body="Clear the search box or choose All above to see every assertion again."
              />
            )
          }
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
              {/* An intent, not an outcome, so both values are deliberately
                  neutral: neither `allow` nor `deny` is in a StatusBadge map
                  and both land on the muted fallback. The words used to be
                  `active` and `blocked`, which painted a deny rule working
                  exactly as designed in alarm red — colour asserting a
                  judgement the column does not make. */}
              <td style={DataTable.td}>
                <StatusBadge
                  status={t.expectedExit === 0 ? 'allow' : 'deny'}
                  testId={`netassert-expected-${t.name}`}
                />
              </td>
              <td style={DataTable.td}>
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                  <StatusBadge status={t.result} variant="compliance" testId={`netassert-result-${t.name}`} />
                  <HelpHint
                    // Contains the row's visible test name, so the control a
                    // speech-input user must utter is one they can read.
                    label={`What the ${t.name} result means`}
                    testId={`netassert-verdict-hint-${t.name}`}
                    tone={VERDICT_TONE[verdictClass(t.result)]}
                  >
                    {verdictNarrative(t)}
                  </HelpHint>
                </span>
                {/* The class in words as well as colour. A reader scanning the
                    column should not have to hover to tell an assertion that
                    was checked from one that never was, and colour alone
                    cannot carry it — the neutral fill is shared by `pending`,
                    `running` and `error`, which are three different silences. */}
                <div
                  style={{ fontSize: 10, color: 'var(--muted)', marginTop: 3 }}
                  data-testid={`netassert-verdict-class-${t.name}`}
                >
                  {VERDICT_QUALIFIER[verdictClass(t.result)]}
                </div>
              </td>
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
            {
              key: 'result',
              label: 'Result',
              sortable: true,
              // The chips below make this arithmetic visible; the hint is what
              // stops a reader taking eight green rows for a green pipeline.
              help: `These ${CI_RESULTS.length} rows are a sample of ${CI_TOTAL} results and every one of them passed. The run itself recorded ${CI_SUMMARY.fail} failures and ${CI_SUMMARY.error} error, none of which are among the rows on this page — an empty fail chip below means none were loaded, not that none exist.`,
            },
          ]}
          data={ciRows}
          pageSize={25}
          testIdPrefix="ci-results"
          toolbar={
            <FilterToolbar
              idPrefix="ci"
              groupLabel="Filter CI pipeline results"
              searchLabel="Search CI pipeline results"
              placeholder="Search source, rule or category…"
              query={ciQuery}
              onQuery={setCiQuery}
              // The full outcome vocabulary, not just the outcomes present.
              // A `fail 0` chip beside a run that recorded fourteen failures
              // is the honest reading of this table; hiding the chip because
              // the array happens to hold none would let eight green rows
              // stand in for a pipeline that is not green.
              chips={CI_OUTCOMES.map((key) => ({
                key,
                count: key === 'all' ? CI_RESULTS.length : CI_RESULTS.filter((r) => r.result === key).length,
              }))}
              activeChip={ciResult}
              onChip={setCiResult}
              shown={ciRows.length}
              total={CI_RESULTS.length}
              narrowed={ciNarrowed}
              onClear={() => { setCiResult('all'); setCiQuery('') }}
              tally={
                <HelpHint label="What the CI result counts cover" testId="ci-sample-hint">
                  {`The chips count only the ${CI_RESULTS.length} rows loaded here. The run they came from scored ${CI_TOTAL}: ${CI_SUMMARY.pass} pass, ${CI_SUMMARY.fail} fail, ${CI_SUMMARY.error} error, ${CI_SUMMARY.skip} skip.`}
                </HelpHint>
              }
            />
          }
          emptyState={
            <EmptyState
              kicker="Nothing matches this filter"
              body={`Clear the search box or choose All above to see all ${CI_RESULTS.length} loaded results. A chip showing zero means no such row was loaded, not that the pipeline recorded none.`}
            />
          }
          renderRow={(r, i) => (
            <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...DataTable.td, fontWeight: 500 }}>{r.source}</td>
              <td style={{ ...DataTable.td, maxWidth: 420, whiteSpace: 'normal', lineHeight: 1.4 }}>{r.rule}</td>
              {/* A classification, not an outcome — no variant, so it takes
                  the neutral fallback rather than borrowing a verdict colour. */}
              <td style={DataTable.td}><StatusBadge status={r.category} /></td>
              {/* `skip` and `error` are unmapped and land neutral, which is
                  right: neither is a rule that was evaluated and found wanting. */}
              <td style={DataTable.td}><StatusBadge status={r.result} variant="compliance" /></td>
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
            {
              key: 'status',
              label: 'Status',
              sortable: true,
              help: 'The harness, not the tests. A pending harness has not reported this cycle, so its figures are from a previous one.',
            },
            {
              key: 'testsRun',
              label: 'Tests',
              sortable: true,
              help: 'Passed out of run, as last reported by that harness. Tests that never ran are absent from both figures rather than counted as failures.',
            },
            { key: 'lastRun', label: 'Last Run', sortable: true },
          ]}
          data={agentRows}
          pageSize={25}
          testIdPrefix="agent-tests"
          toolbar={
            <FilterToolbar
              idPrefix="agent"
              groupLabel="Filter agent test infrastructure"
              searchLabel="Search agent test infrastructure"
              placeholder="Search agent, namespace or type…"
              query={agentQuery}
              onQuery={setAgentQuery}
              chips={AGENT_STATUSES.map((key) => ({
                key,
                count: key === 'all' ? AGENT_TESTS.length : AGENT_TESTS.filter((a) => a.status === key).length,
              }))}
              activeChip={agentStatus}
              onChip={setAgentStatus}
              shown={agentRows.length}
              total={AGENT_TESTS.length}
              narrowed={agentNarrowed}
              onClear={() => { setAgentStatus('all'); setAgentQuery('') }}
            />
          }
          emptyState={
            <EmptyState
              kicker="Nothing matches this filter"
              body="Clear the search box or choose All above to see every agent harness again."
            />
          }
          renderRow={(a) => (
            <tr key={a.name} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...DataTable.td, fontWeight: 500 }}>{a.name}</td>
              <td style={DataTable.td}><code style={{ fontSize: 11, color: 'var(--cyan)' }}>{a.namespace}</code></td>
              <td style={DataTable.td}>{a.type}</td>
              <td style={DataTable.td}><StatusBadge status={a.status} variant="lifecycle" /></td>
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
