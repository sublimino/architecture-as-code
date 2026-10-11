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

import { sweep, type LiveFigureFinding as Finding } from '../../scripts/live-figure-sweep.mjs'

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

  it('finds a fixture value imported by a file that never imports the gate', () => {
    const f = plant(
      'pages/P.tsx',
      "import { FAKE_THING } from '../api/fakeData'\nexport const X = FAKE_THING\n",
    )
    expect(f.some((x) => x.rule === 'ungated-fixture-import')).toBe(true)
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
})

// ── 2. Baseline lock on the real tree ──────────────────────────────────────

/**
 * Known, un-fixed fabrications. Each row is a defect, NOT an approval.
 * Deleting a row is how you record a fix; adding one requires a reason.
 */
const BASELINE: Array<{ file: string; line: number; detail: string; note: string }> = [
  {
    file: 'components/AgentActivityTab.tsx',
    line: 147,
    detail: 'confidence: 0.99',
    note: 'Proof drawer asserts 0.99 confidence plus a hardcoded rekor entry ref. Unfixed.',
  },
  {
    file: 'data/agentDiscovery.ts',
    line: 34,
    detail: "imports fixture value(s) FAKE_SWARM_AGENTS from '../api/fakeSwarmData'",
    note: 'discoverAgents returns DEMO_AGENTS on failure. No production callers today: landmine, not a live defect.',
  },
  {
    file: 'pages/CryptographyPage.tsx',
    line: 83,
    detail: 'total: 6',
    note: 'Hardcoded SPIRE inventory (server version, agent count, SVID list). Unfixed.',
  },
  {
    file: 'pages/DiscoveryPage.tsx',
    line: 684,
    detail: 'total_controls: 12',
    note: 'Fourth copy of the fabricated per-agent compliance summary. Unfixed.',
  },
  {
    file: 'pages/DiscoveryPage.tsx',
    line: 685,
    detail: 'passing: 8',
    note: 'Fourth copy of the fabricated per-agent compliance summary. Unfixed.',
  },
  {
    file: 'pages/DiscoveryPage.tsx',
    line: 687,
    detail: 'pending: 4',
    note: 'Fourth copy of the fabricated per-agent compliance summary. Unfixed.',
  },
  {
    file: 'pages/DiscoveryPage.tsx',
    line: 688,
    detail: 'posture_score: 0.67',
    note: 'Fourth copy; this is the 67% that CryptographyPage comments on. Unfixed.',
  },
  {
    file: 'pages/FleetDemoPage.tsx',
    line: 184,
    detail: 'ale: 12400',
    note: 'BASELINE_RISK. Byte-identical to literals W1 removed server-side. Unfixed.',
  },
  {
    file: 'pages/FleetDemoPage.tsx',
    line: 185,
    detail: 'var95: 58000',
    note: 'BASELINE_RISK. Unfixed.',
  },
  {
    file: 'pages/FleetDemoPage.tsx',
    line: 191,
    detail: 'ale: 847000',
    note: 'ESCALATED_RISK. Unfixed.',
  },
  {
    file: 'pages/FleetDemoPage.tsx',
    line: 192,
    detail: 'var95: 1200000',
    note: 'ESCALATED_RISK. Unfixed.',
  },
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
    expect(BASELINE).toHaveLength(11)
  })

  it('confirms the pages fixed in this change carry no findings', () => {
    const findings = sweep(REAL_SRC) as Finding[]
    const fixed = [
      'pages/RiskExposurePage.tsx',
      'pages/CompliancePolicyPage.tsx',
      'pages/CollusionAccessPage.tsx',
      'components/AgentOverviewTab.tsx',
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
