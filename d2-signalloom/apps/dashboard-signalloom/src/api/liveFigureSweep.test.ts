/**
 * Live-mode figure sweep: self-test, baseline lock, and gate behaviour.
 *
 * Three jobs, in order of importance:
 *
 * 1. PROVE THE INSTRUMENT. A sweep that cannot see a fabricated figure tells
 *    you nothing about the codebase, and "I looked and found nothing" is not a
 *    finding. So the first suite plants every shape the sweep claims to detect
 *    into a synthetic tree and asserts each one is found. This caught a real
 *    bug during authoring: the rule for `if (x.length === 0) return 20` was
 *    anchored at line start and therefore missed the exact archetype it
 *    existed for — the worst defect in the sweep. A clean run would have
 *    looked like success.
 *
 * 2. LOCK THE BASELINE. The real tree still carries known fabrications. They
 *    are recorded here with a reason each, so a NEW one fails the build and a
 *    FIXED one also fails (prompting you to delete its baseline row). Silence
 *    is never the pass condition.
 *
 * 3. GATE BEHAVIOUR. Assert that demo content is actually unreachable with
 *    isDemoMode() false, which is the property the sweep can only approximate.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  sweep,
  EXCEPTIONS,
  type LiveFigureFinding as Finding,
} from '../../scripts/live-figure-sweep.mjs'

const REAL_SRC = join(import.meta.dirname ?? __dirname, '..')

// ── 1. Instrument self-test (the planted-literal proof) ────────────────────

describe('live-figure-sweep detects every shape it claims to', () => {
  let root: string

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'figure-sweep-'))
    mkdirSync(join(root, 'pages'), { recursive: true })
    mkdirSync(join(root, 'api'), { recursive: true })
  })

  afterEach(() => {
    rmSync(root, { recursive: true, force: true })
  })

  function plant(rel: string, body: string) {
    writeFileSync(join(root, rel), body)
    return sweep(root) as Finding[]
  }

  it('finds a figure-named integer property', () => {
    const f = plant('pages/P.tsx', 'export const X = { posture_score: 93 }\n')
    expect(f.map((x) => x.detail)).toContain('posture_score: 93')
  })

  it('finds a money-named figure property', () => {
    const f = plant('pages/P.tsx', 'export const X = { ale: 1240000 }\n')
    expect(f.map((x) => x.detail)).toContain('ale: 1240000')
  })

  it('finds a figure-named float property', () => {
    const f = plant('pages/P.tsx', 'export const X = { coverage: 87.5 }\n')
    expect(f.map((x) => x.detail)).toContain('coverage: 87.5')
  })

  it('finds a percentage string literal', () => {
    const f = plant('pages/P.tsx', "export const X = '42%'\n")
    expect(f.some((x) => x.detail.includes("'42%'"))).toBe(true)
  })

  it('finds a money string literal', () => {
    const f = plant('pages/P.tsx', "export const X = '£1,240,000'\n")
    expect(f.some((x) => x.detail.startsWith('money literal'))).toBe(true)
  })

  it('finds a literal returned from a derived value, guard on the same line', () => {
    // Verbatim shape of the worst defect found: the fabricated population that
    // was then consumed as `ratio = count / total` and rescaled real money.
    const f = plant(
      'pages/P.tsx',
      [
        'export function useCounts(agentList: unknown[]) {',
        '  const totalAgentCount = useMemo(() => {',
        '    if (agentList.length === 0) return 20',
        '    return agentList.length',
        '  }, [agentList])',
        '  return totalAgentCount',
        '}',
      ].join('\n'),
    )
    expect(f.some((x) => x.detail === 'derived value returns the literal 20')).toBe(true)
  })

  // ── The gate must be INVOKED, not merely imported ────────────────────────
  //
  // This is the planted case for the worst defect found on this build, and it
  // is planted into a file shape the sweep previously declared CLEAN.
  // pages/FleetDemoPage.tsx imported `isDemoMode` and never called it: the
  // sole occurrence of the identifier in 1,200 lines was the import line, and
  // rule 1's old check -- `/\bisDemoMode\b/.test(src)` -- was satisfied by
  // exactly that line. `noUnusedLocals` is false, so the compiler said
  // nothing. The demo fixture was therefore reachable in uat and prod by
  // clicking "Use Demo Fixture", which is a security issue rather than a
  // credibility one.
  //
  // A rule that asserts PRESENCE can never catch this. The three cases below
  // pin the distinction in both directions, because a rule that demanded
  // invocation but could not see a real one would be just as useless.
  it('finds a fixture import whose gate is imported but NEVER CALLED', () => {
    const f = plant(
      'pages/P.tsx',
      [
        "import { FLEET_DEMO_FIXTURE } from '../api/fakeData'",
        "import { isDemoMode } from '../api/demoMode'",
        '',
        'export const X = FLEET_DEMO_FIXTURE',
      ].join('\n'),
    )
    const hit = f.find((x) => x.rule === 'ungated-fixture-import')
    expect(hit, 'an unused gate import must not count as a defence').toBeDefined()
    expect(hit?.detail).toMatch(/WITHOUT CALLING IT/)
  })

  it('accepts a gate that is actually called', () => {
    const f = plant(
      'pages/P.tsx',
      [
        "import { FLEET_DEMO_FIXTURE } from '../api/fakeData'",
        "import { isDemoMode } from '../api/demoMode'",
        '',
        'export const X = isDemoMode() ? FLEET_DEMO_FIXTURE : null',
      ].join('\n'),
    )
    expect(f.filter((x) => x.rule === 'ungated-fixture-import')).toEqual([])
  })

  it('accepts the environment tier as a gate, not only isDemoMode', () => {
    // FleetDemoPage's fix gates on the TIER rather than the per-browser
    // toggle, because an operator legitimately wants the fixture with the
    // toggle off. The rule has to accept that or it pushes code towards the
    // weaker check to stay green.
    const f = plant(
      'pages/P.tsx',
      [
        "import { FLEET_DEMO_FIXTURE } from '../api/fakeData'",
        "import { isProductionEnv, showDemoToggle } from '../api/demoMode'",
        '',
        'export const X = !isProductionEnv && showDemoToggle ? FLEET_DEMO_FIXTURE : null',
      ].join('\n'),
    )
    expect(f.filter((x) => x.rule === 'ungated-fixture-import')).toEqual([])
  })

  it('does not accept a gate mentioned only inside a comment', () => {
    // The adjacent failure mode: "isDemoMode handles this" written above the
    // fixture. Prose is not a gate.
    const f = plant(
      'pages/P.tsx',
      [
        "import { FLEET_DEMO_FIXTURE } from '../api/fakeData'",
        "import { isDemoMode } from '../api/demoMode'",
        '',
        '// isDemoMode() guards this upstream in client.ts, so it is fine here.',
        'export const X = FLEET_DEMO_FIXTURE',
      ].join('\n'),
    )
    // This failed on first run, which is why the rule now blanks comments as
    // well as imports before looking for the symbol. Writing the test first
    // and watching it pass would have hidden the gap.
    const hit = f.find((x) => x.rule === 'ungated-fixture-import')
    expect(hit, 'a gate named only in a comment must not read as applied').toBeDefined()
    expect(hit?.detail).toMatch(/WITHOUT CALLING IT/)
  })

  // ── The fabricated unit rate ─────────────────────────────────────────────

  it('finds a figure multiplied by a literal rate', () => {
    // Verbatim shape of RiskExposurePage:663. Worse than a displayed constant:
    // it manufactures money from a REAL count, so the output moves with real
    // input and reads as derived.
    const f = plant(
      'pages/P.tsx',
      'export const col = { accessor: (a) => (a.compliance_summary?.failing ?? 0) * 12000 }\n',
    )
    expect(f.some((x) => x.rule === 'fabricated-unit-rate')).toBe(true)
  })

  it('finds the rate with the literal on the left as well', () => {
    const f = plant('pages/P.tsx', 'const exposure = 12000 * failingControls\n')
    expect(f.some((x) => x.rule === 'fabricated-unit-rate')).toBe(true)
  })

  it('does not flag a unit conversion, which carries no pricing claim', () => {
    // Every one of these is real code in this tree. A rule that flagged them
    // would be turned off within a week.
    for (const line of [
      'const pct = score <= 1.0 ? score * 100 : score',
      'const confidencePct = Math.round(actor.confidence * 100)',
      'const rssMb = rssBytes / (1024 * 1024)',
      'const annualised = monthly * 12',
    ]) {
      const f = plant('pages/P.tsx', line + '\n')
      expect(
        f.filter((x) => x.rule === 'fabricated-unit-rate'),
        `flagged a unit conversion: ${line}`,
      ).toEqual([])
    }
  })

  it('finds a fixture value imported by a file that never imports the gate', () => {
    const f = plant(
      'pages/P.tsx',
      "import { FAKE_THING } from '../api/fakeData'\nexport const X = FAKE_THING\n",
    )
    expect(f.some((x) => x.rule === 'ungated-fixture-import')).toBe(true)
  })

  // ── Assignment syntax ────────────────────────────────────────────────────
  //
  // Every proof above this block is written with a COLON, because rule 2b
  // matches `prop: value` and the proofs were authored from the rule. That
  // made the suite validate the regex against its own preimage: there was no
  // rule for an assignment at all, and an audit planted `const postureScore =
  // 93` into RiskExposurePage.tsx -- a page the suite below explicitly asserts
  // carries no findings -- and all 16 tests passed, including the one named
  // "reports exactly the known fabrications, no more and no fewer".
  //
  // These proofs are therefore deliberately written in the syntax the rule was
  // NOT built from. In TSX a `const` is arguably the more idiomatic way to
  // write a fabricated figure than a snake_case object property.

  it('finds a figure-named const assigned an integer', () => {
    // The verbatim audit plant.
    const f = plant('pages/P.tsx', 'export const postureScore = 93\n')
    expect(f.map((x) => x.detail)).toContain('postureScore = 93')
  })

  it('finds a figure-named let assigned money', () => {
    const f = plant('pages/P.tsx', 'let ale = 1240000\n')
    expect(f.map((x) => x.detail)).toContain('ale = 1240000')
  })

  it('finds a figure-named var assigned a float', () => {
    const f = plant('pages/P.tsx', 'var coverage = 87.5\n')
    expect(f.map((x) => x.detail)).toContain('coverage = 87.5')
  })

  it('finds a figure assigned to an already-declared binding', () => {
    const f = plant('pages/P.tsx', 'let postureScore = 0\npostureScore = 93\n')
    expect(f.map((x) => x.detail)).toContain('postureScore = 93')
  })

  it('finds a figure assigned through a member path', () => {
    const f = plant('pages/P.tsx', 'state.riskExposure = 847000\n')
    expect(f.map((x) => x.detail)).toContain('riskExposure = 847000')
  })

  it('sees through digit separators, which express the same figure', () => {
    const f = plant('pages/P.tsx', 'export const ale = 1_240_000\n')
    expect(f.map((x) => x.detail)).toContain('ale = 1_240_000')
  })

  it('sees through exponent notation, which expresses the same figure', () => {
    const f = plant('pages/P.tsx', 'export const ale = 8.47e5\n')
    expect(f.map((x) => x.detail)).toContain('ale = 8.47e5')
  })

  it('finds a numeric literal interpolated into rendered text', () => {
    const f = plant('pages/P.tsx', 'export const L = `${93}% covered`\n')
    expect(f.map((x) => x.detail)).toContain('template interpolation ${93}')
  })

  it('finds a numeric literal passed straight to a figure-named JSX prop', () => {
    const f = plant('pages/P.tsx', 'export const E = <Gauge score={93} />\n')
    expect(f.map((x) => x.detail)).toContain('prop score={93}')
  })

  it('finds a figure prop on a line that also carries presentation props', () => {
    // The line-level presentation filter is too coarse for this shape: it
    // matches `width` and would discard the line, taking the finding with it.
    // Rules 2d-2f filter per match on the binding name instead.
    const f = plant('pages/P.tsx', 'export const E = <Gauge width={100} score={93} />\n')
    expect(f.map((x) => x.detail)).toContain('prop score={93}')
  })

  // ── Known residual, asserted so it cannot be mistaken for coverage ───────

  it('does NOT catch a numeric literal bound to a non-figure name', () => {
    // `const x = 93` is a real hole and this test exists to keep it visible
    // rather than letting a reader assume the assignment rules are complete.
    //
    // Rules 2d and 2f gate on the binding NAME. That is what keeps false
    // positives near zero -- a page is full of indices, limits, page sizes and
    // poll intervals, and flagging every `const x = 93` would make the sweep
    // noise. The consequence is that renaming the binding to something outside
    // the vocabulary defeats the rule.
    //
    // The principled fix is dataflow, not a bigger vocabulary: parse the TSX
    // and flag numeric literals that REACH JSX. That is a different instrument
    // from a line-oriented regex sweep and is deliberately not attempted here.
    // Until it exists, the sweep's guarantee is "no figure-NAMED literal",
    // not "no fabricated figure".
    const f = plant('pages/P.tsx', 'export const x = 93\n')
    expect(f).toHaveLength(0)
  })

  // Negative controls. A sweep that flags everything is as useless as one that
  // flags nothing, and these are the false positives that actually occurred.
  it('does not flag CSS percentages', () => {
    const f = plant(
      'pages/P.tsx',
      "export const S = { position: 'absolute', top: '50%', left: '100%' }\n",
    )
    expect(f).toHaveLength(0)
  })

  it('does not flag a figure merely discussed in a block comment', () => {
    const f = plant('pages/P.tsx', '/* counts hybrids as safe, not visible in "67%" */\n')
    expect(f).toHaveLength(0)
  })

  it('does not flag zero, which is honest absence', () => {
    const f = plant('pages/P.tsx', 'export const X = { passing: 0, total: 0 }\n')
    expect(f).toHaveLength(0)
  })

  it('does not flag a type-only fixture import', () => {
    const f = plant('pages/P.tsx', "import type { Rec } from '../api/fakeSwarmData'\n")
    expect(f).toHaveLength(0)
  })

  // Negative controls for the assignment rules specifically. These are the
  // shapes a page is genuinely full of, and flagging them would make the sweep
  // noise rather than an instrument.
  it('does not flag a non-figure UI constant', () => {
    const f = plant('pages/P.tsx', 'const pageSize = 25\nconst pollIntervalMs = 5000\n')
    expect(f).toHaveLength(0)
  })

  it('does not mistake a comparison for an assignment', () => {
    const f = plant(
      'pages/P.tsx',
      [
        'export function f(total: number) {',
        '  if (total === 12) return true',
        '  if (total >= 847000) return true',
        '  if (total != 93) return false',
        '  return [1, 2].map((n) => n * 2).length > 0',
        '}',
      ].join('\n'),
    )
    expect(f).toHaveLength(0)
  })

  it('does not flag a figure binding assigned zero, which is honest absence', () => {
    const f = plant('pages/P.tsx', 'const ale = 0\nlet coverage = 0\n')
    expect(f).toHaveLength(0)
  })

  it('does not flag a presentational dimension prop', () => {
    const f = plant('pages/P.tsx', 'export const E = <Box width={100} height={40} />\n')
    expect(f).toHaveLength(0)
  })
})

// ── 2. Baseline lock on the real tree ──────────────────────────────────────

/**
 * Known, un-fixed fabrications. Each row is a defect, NOT an approval.
 * Deleting a row is how you record a fix; adding one requires a reason.
 */
const BASELINE: Array<{ file: string; line: number; detail: string; note: string }> = [
  // RECONCILED AT INTEGRATION, and the reconciliation is the point of this list.
  //
  // Two workers extended this baseline independently. One of them then FIXED ten
  // of the rows the other had just recorded, so the merged list declared fourteen
  // fabrications where four survive. Git merged the two row sets textually without
  // noticing, and the lock below caught it immediately -- not as "a new figure
  // appeared" but as "a baseline finding is gone", which is the half of a
  // bidirectional lock people are tempted to leave out. A list that only fails on
  // ADDITIONS rots into a list of things that used to be wrong.
  //
  // Zero fabrications survive on this tree: all four previously locked
  // fabrications (AgentActivityTab confidence, IdentityAuditPanel activeLeasesCount,
  // agentDiscovery ungated fixture import, and CryptographyPage SPIRE bootstrap)
  // have been fully eliminated or properly gated behind isDemoMode with honest live state.
]


describe('live-mode figure baseline', () => {
  it('reports exactly the known fabrications, no more and no fewer', () => {
    const findings = sweep(REAL_SRC) as Finding[]
    const actual = findings.map((f) => `${f.file}:${f.line} ${f.detail}`).sort()
    const expected = BASELINE.map((b) => `${b.file}:${b.line} ${b.detail}`).sort()

    const added = actual.filter((a) => !expected.includes(a))
    const removed = expected.filter((e) => !actual.includes(e))

    expect(
      added,
      'New un-gated figure(s). A literal in a page renders in live mode too: source it from the API or render an empty state.',
    ).toEqual([])
    expect(
      removed,
      'A baseline finding is gone. If you fixed it, delete its row in BASELINE so the lock keeps meaning something.',
    ).toEqual([])
  })

  it('has a stated reason for every baseline row', () => {
    for (const row of BASELINE) {
      expect(row.note.length, `${row.file}:${row.line} needs a reason`).toBeGreaterThan(20)
    }
    expect(BASELINE).toHaveLength(0)
  })

  it('has a stated reason for every pinned sweep exception', () => {
    // Same standard as the baseline rows: an exception without a stated reason
    // is indistinguishable from a defect someone silenced.
    for (const e of EXCEPTIONS) {
      expect(e.reason?.length ?? 0, `${e.file} [${e.rule}] needs a reason`).toBeGreaterThan(20)
    }
  })

  it('confirms the pages fixed in this change carry no findings', () => {
    const findings = sweep(REAL_SRC) as Finding[]
    const fixed = [
      'pages/RiskExposurePage.tsx',
      'pages/CompliancePolicyPage.tsx',
      'pages/CollusionAccessPage.tsx',
      'components/AgentOverviewTab.tsx',
      // W5: the four BASELINE_RISK/ESCALATED_RISK literals moved into
      // api/fakeData.ts behind the demo gate, and the live path now reports
      // the API's refusal instead of a scripted figure.
      'pages/FleetDemoPage.tsx',
      // W5: the fourth copy of the fabricated per-agent compliance summary is
      // gone; a discovered workload now reports the honest empty shape.
      'pages/DiscoveryPage.tsx',
      // W6: CryptographyPage hardcoded SPIRE inventory moved to fakeFederationData fixture
      // and gated behind isDemoMode, reporting honest unavailable state in live mode.
      'pages/CryptographyPage.tsx',
    ]
    for (const file of fixed) {
      expect(
        findings.filter((f) => f.file === file),
        `${file} regressed`,
      ).toEqual([])
    }
  })
})

// ── 3. Gate behaviour ──────────────────────────────────────────────────────

describe('demo content is unreachable with the gate off', () => {
  afterEach(() => {
    vi.resetModules()
    vi.restoreAllMocks()
  })

  it('lookupPolicyForControl yields no rule metadata in live mode', async () => {
    vi.doMock('./demoMode', () => ({
      isDemoMode: () => false,
      isProductionEnv: true,
      showDemoToggle: false,
      setDemoMode: () => {},
      toggleDemoMode: () => false,
      subscribeDemoMode: () => () => {},
    }))
    const { lookupPolicyForControl } = await import('../components/AgentOverviewTab')
    // A control that previously matched a seeded CIS rule, and one that
    // previously fell through to the invented 'object.spec.metadata.name != ""'.
    expect(lookupPolicyForControl('CIS 5.2.6 root containers', 'CIS Kubernetes Benchmark')).toBeNull()
    expect(lookupPolicyForControl('Some Unmapped Control', 'Unknown Framework')).toBeNull()
  })

  it('lookupPolicyForControl still serves the demo rule set in demo mode', async () => {
    vi.doMock('./demoMode', () => ({
      isDemoMode: () => true,
      isProductionEnv: false,
      showDemoToggle: true,
      setDemoMode: () => {},
      toggleDemoMode: () => true,
      subscribeDemoMode: () => () => {},
    }))
    const { lookupPolicyForControl } = await import('../components/AgentOverviewTab')
    const hit = lookupPolicyForControl('CIS 5.2.6 root containers', 'CIS Kubernetes Benchmark')
    expect(hit).not.toBeNull()
    expect(hit?.celExpression).toBeTruthy()
  })
})
