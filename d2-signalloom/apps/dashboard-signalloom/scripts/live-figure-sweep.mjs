#!/usr/bin/env node
// Live-mode figure sweep.
//
// WHY THIS EXISTS
// ---------------
// api/client.ts short-circuits to local fixtures only when isDemoMode() is
// true, and isProductionEnv forces that off in uat/prod. That gate is correct
// and the ~14 fake*/demo* fixture modules behind it are a legitimate feature.
//
// What the gate cannot catch is a figure that never passes through it: a
// numeric literal written into a page component renders identically in both
// modes, and a fixture module imported directly by a page bypasses the gate
// entirely. This sweep looks for exactly those two shapes.
//
// It is deliberately a separate instrument from the type checker and the unit
// tests, because both of those are satisfied by a fabricated figure.
//
// USAGE
//   node scripts/live-figure-sweep.mjs [--json] [--root <dir>]
// EXIT
//   0 = no findings, 1 = findings, 2 = bad invocation.

import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative, basename, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))

// ── The fixture graph ───────────────────────────────────────────────────────
// Module basenames that exist to serve demo data. Importing a VALUE from one
// of these is only legitimate inside the gate or inside tests.
const FIXTURE_MODULES = new Set([
  'fakeData',
  'fakeComplianceData',
  'fakeFairData',
  'fakeWeaveData',
  'fakeSwarmData',
  'fakeCodingAgentData',
  'fakeFederationData',
  'fakeNetworkTestsData',
  'afmDemoFixtures',
  'demoActivity',
])

// Files permitted to import fixture values: the gate itself, the fixture
// graph's own internals, and the test bootstrap.
const GATE_ALLOW_LIST = new Set([
  'api/client.ts',
  'api/demoMode.ts',
  'test-setup.ts',
])

// ── Figure vocabulary ──────────────────────────────────────────────────────
// Property names whose value is a figure a user reads as fact.
const FIGURE_WORDS = [
  'score', 'percent', 'pct', 'coverage', 'compliance', 'total', 'totals',
  'total_controls', 'cost', 'ale', 'var95', 'tvar', 'exposure', 'carried',
  'savings', 'spend', 'budget', 'revenue', 'loss', 'passing', 'failing',
  'passed', 'failed', 'pending', 'controls', 'posture_score', 'confidence',
  'likelihood', 'impact', 'magnitude', 'annual', 'monthly', 'amount', 'count',
  'ratio', 'rate', 'uptime', 'sla', 'mttr',
]

const FIGURE_PROP = new RegExp(`^(${FIGURE_WORDS.join('|')})$`, 'i')

/** The same vocabulary as a fragment, for matching inside an expression. */
const FIGURE_WORD = FIGURE_WORDS.join('|')

// Literals that are a UNIT, not a price.
//
// Multiplying a figure by one of these converts its units -- a ratio to a
// percentage, seconds to milliseconds, bytes to KiB, a turn to degrees. That
// is arithmetic on a declared unit and carries no pricing claim. Multiplying a
// figure by any OTHER literal asserts a rate, and a rate is a calibration
// decision that belongs in the risk pack.
//
// Kept deliberately short. A number that wants to join this set should have to
// argue for itself: the cost of a missing entry is one false positive, and the
// cost of a spurious one is a fabricated rate that never gets reported.
const UNIT_CONVERSION = new Set([
  10, 100, 1000, 10_000, 1_000_000, // decimal scale and percent
  1024, 1_048_576,                  // binary scale
  60, 3600, 86_400,                 // time
  255,                              // 8-bit channel
  180, 360,                         // degrees
  12,                               // months in a year
])

// Lines that are unambiguously CSS/SVG/layout. A '%' or a number here is
// presentation, not a figure. Kept broad on purpose: a false negative in this
// list costs a missed finding, so the planted-literal proof below pins that
// the list does not swallow real figures.
const PRESENTATION =
  /color-mix|linear-gradient|radial-gradient|borderRadius|border:|background|width|height|padding|margin|transform|translate|backgroundSize|flexBasis|fontSize|lineHeight|strokeWidth|stroke|fill=|opacity|boxShadow|gridTemplate|rgba?\(|hsla?\(|transition|outline|inset|zIndex|cursor|overflow|textAlign|whiteSpace|letterSpacing|clipPath|viewBox|aspectRatio|innerRadius|outerRadius|\bcx=|\bcy=|\bgap\b|maxWidth|minWidth|minHeight|maxHeight|\bposition\s*:|\b(top|left|right|bottom)\s*:|\bcalc\(|\bflexShrink|\bflexGrow|\btranslate[XY]/

const RENDERED_DIRS = ['pages', 'components', 'views']

// ── Pinned exceptions ──────────────────────────────────────────────────────
// Every entry is a deliberate, reviewed decision. `reason` is mandatory: an
// exception without a stated reason is indistinguishable from a defect that
// someone silenced.
const EXCEPTIONS = [
  {
    file: 'pages/DesignSystemPage.tsx',
    rule: 'figure-literal',
    reason:
      'Component gallery. Its numbers are specimen props for the design system, not estate figures.',
  },
  {
    file: 'pages/admin/UserTable.tsx',
    rule: 'figure-literal',
    reason: 'Page-size options (10/25/50) are UI controls, not measurements.',
  },
]

function isException(rel, rule) {
  return EXCEPTIONS.some((e) => e.file === rel && e.rule === rule)
}

// ── Walk ───────────────────────────────────────────────────────────────────
function walk(dir, out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name)
    if (entry.isDirectory()) walk(p, out)
    else if (/\.(ts|tsx)$/.test(entry.name)) out.push(p)
  }
  return out
}

function isTestFile(rel) {
  return (
    /\.(test|spec)\.(ts|tsx)$/.test(rel) ||
    rel.startsWith('test-utils/') ||
    rel.startsWith('test/') ||
    rel.includes('__tests__/')
  )
}

// ── The gate symbols ───────────────────────────────────────────────────────
// Every export of api/demoMode.ts that can decide whether demo content may
// render. `isDemoMode` is the per-browser toggle; `isProductionEnv` and
// `showDemoToggle` are the environment tier. Any of them, APPLIED, counts.
const GATE_SYMBOLS = ['isDemoMode', 'isProductionEnv', 'showDemoToggle']

/**
 * Is a gate symbol actually USED in this file, or merely imported?
 *
 * WHY THIS IS NOT THE SAME QUESTION AS "IS IT IMPORTED".
 * The previous version of rule 1 asked `/\bisDemoMode\b/.test(src)`, which the
 * import line itself satisfies. pages/FleetDemoPage.tsx imported `isDemoMode`
 * and NEVER CALLED IT -- the only occurrence of the identifier in 1,200 lines
 * was the import. `noUnusedLocals` is false in tsconfig.json, so the compiler
 * said nothing, and this sweep reported the file clean while one click on
 * "Use Demo Fixture" served ale 847000 / var95 1200000 in uat and prod.
 *
 * That is the one defect on this build that is a security issue rather than a
 * credibility one, and a rule asserting PRESENCE could never have caught it.
 * So: blank the import statements, then look for the symbol in what is left.
 * An identifier that survives that is referenced by code.
 */
function gateApplied(src) {
  const imported = new Set()
  for (const m of src.matchAll(/import\s+(?:type\s+)?\{([^}]*)\}\s+from\s+'([^']*demoMode)'/g)) {
    for (const name of m[1].split(',')) {
      const bare = name.trim().replace(/^type\s+/, '').split(/\s+as\s+/).pop()?.trim()
      if (bare && GATE_SYMBOLS.includes(bare)) imported.add(bare)
    }
  }
  if (imported.size === 0) return { imported: false, applied: false }

  // Blank every import statement AND every comment, preserving line count.
  //
  // Comments too, because the adjacent failure mode is a file that says
  // "isDemoMode() guards this upstream" above an ungated fixture. Prose is not
  // a gate, and a rule that accepted a mention in a comment as evidence of
  // invocation would be back to asserting presence by a slower route.
  const body = src
    .replace(/^[ \t]*import\s[\s\S]*?from\s+'[^']+'[ \t]*;?[ \t]*$/gm, (m) =>
      m.replace(/[^\n]/g, ' '),
    )
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
    .replace(/\/\/[^\n]*/g, (m) => ' '.repeat(m.length))
  const applied = [...imported].some((n) => new RegExp(`\\b${n}\\b`).test(body))
  return { imported: true, applied }
}

// ── Rule 1: fixture values imported outside the gate ───────────────────────
// A type-only import is harmless: types carry no values and cannot render.
function checkUngatedFixtureImports(rel, src) {
  const findings = []
  if (GATE_ALLOW_LIST.has(rel)) return findings
  // A fixture module may import its siblings.
  if (FIXTURE_MODULES.has(basename(rel).replace(/\.(ts|tsx)$/, ''))) return findings

  // A file that imports fixture values must also APPLY the gate. This still
  // does not prove the gate guards every use -- only a test can do that (see
  // liveFigureSweep.test.ts, and pages/fleetRiskRefusal.test.tsx for the
  // FleetDemoPage case) -- but it no longer accepts an unused import as
  // evidence, which is what let the worst defect on this build through. Being
  // explicit about what this check does NOT prove still matters more than the
  // check: a green sweep is not a guarantee of correct gating.
  const gate = gateApplied(src)
  const importsGate = gate.applied

  const re = /import\s+(type\s+)?([\s\S]*?)\s+from\s+'([^']+)'/g
  let m
  while ((m = re.exec(src)) !== null) {
    const [, typeKeyword, clause, spec] = m
    if (!FIXTURE_MODULES.has(basename(spec))) continue
    if (typeKeyword) continue

    // `{ type Foo, type Bar }` is also type-only.
    const names = clause
      .replace(/[{}]/g, '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean)
    const valueNames = names.filter((n) => !/^type\s/.test(n))
    if (valueNames.length === 0) continue
    if (importsGate) continue

    findings.push({
      rule: 'ungated-fixture-import',
      file: rel,
      line: src.slice(0, m.index).split('\n').length,
      detail: gate.imported
        ? `imports fixture value(s) ${valueNames.join(', ')} from '${spec}' and imports the gate WITHOUT CALLING IT`
        : `imports fixture value(s) ${valueNames.join(', ')} from '${spec}'`,
      why: gate.imported
        ? 'The gate is imported but never referenced outside the import line, so nothing gates anything. An unused import is not a defence.'
        : 'A fixture imported directly renders in live mode too. Route it through api/client.ts, or gate the use on isDemoMode().',
    })
  }
  return findings
}

// ── Rule 2: figure literals in rendered code ───────────────────────────────
function checkFigureLiterals(rel, src) {
  const findings = []
  if (!RENDERED_DIRS.some((d) => rel.startsWith(d + '/'))) return findings
  if (isException(rel, 'figure-literal')) return findings

  // Blank out block-comment bodies while preserving line numbering: a comment
  // that *discusses* a figure ("is not visible in \"67%\"") is not a figure.
  const lines = src
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
    .split('\n')
  // Track useMemo/useCallback depth so `return 20` inside a derived value is
  // distinguishable from `return 20` in a formatter.
  let memoDepth = 0
  let braceAtMemoStart = 0
  let brace = 0

  lines.forEach((raw, i) => {
    const line = raw
    const t = raw.trim()
    const n = i + 1

    const opens = (line.match(/[{(]/g) || []).length
    const closes = (line.match(/[})]/g) || []).length

    if (/\buseMemo\s*\(|\buseCallback\s*\(/.test(line) && memoDepth === 0) {
      memoDepth = 1
      braceAtMemoStart = brace
    }

    const skip = !t || t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')

    if (!skip && !PRESENTATION.test(t)) {
      // 2a. A bare numeric return inside a derived value. This is the
      //     `if (agentList.length === 0) return 20` archetype: a placeholder
      //     that is indistinguishable from a measurement once rendered, and
      //     which may be consumed downstream as if it were one.
      // NOT anchored at line start: the archetype puts the guard and the
      // return on one line — `if (agentList.length === 0) return 20`. An
      // anchored match missed exactly the defect this rule exists for, which
      // the planted-literal proof caught and a clean sweep would not have.
      const ret = t.match(/\breturn\s+(-?\d[\d_]*(?:\.\d+)?)\s*$/)
      const retVal = ret ? Number(ret[1].replace(/_/g, '')) : null
      // 0 is honest absence; ±1 is the sort-comparator idiom, not a figure.
      if (ret && memoDepth > 0 && retVal !== 0 && Math.abs(retVal) !== 1) {
        findings.push({
          rule: 'figure-literal',
          file: rel,
          line: n,
          detail: `derived value returns the literal ${ret[1]}`,
          why:
            'A placeholder inside a useMemo is rendered as a measurement. Report absence (0, null, empty state) instead.',
        })
      }

      // 2b. A figure-named property assigned a non-zero numeric literal.
      //     Zero is allowed: it is an honest accumulator seed.
      for (const pm of t.matchAll(/([A-Za-z_$][\w$]*)\s*:\s*(-?\d[\d_]*(?:\.\d+)?)\s*(?:,|$|\})/g)) {
        const [, prop, value] = pm
        if (!FIGURE_PROP.test(prop)) continue
        if (Number(value.replace(/_/g, '')) === 0) continue
        findings.push({
          rule: 'figure-literal',
          file: rel,
          line: n,
          detail: `${prop}: ${value}`,
          why:
            'A figure-named property with a literal value renders the same in live mode as in demo mode.',
        })
      }

      // 2c. A money or percentage string literal.
      const money = t.match(/['"`]\s*[$£€]\s?\d[\d,_]*(?:\.\d+)?\s*[KMB]?\s*['"`]/)
      if (money) {
        findings.push({
          rule: 'figure-literal',
          file: rel,
          line: n,
          detail: `money literal ${money[0].trim()}`,
          why: 'Money must come from the API, never from the source.',
        })
      }
      // 2d. A fabricated UNIT RATE: a figure-named quantity multiplied by a
      //     numeric literal that is not a unit conversion.
      //
      //     This is a worse shape than 2b and the reason it needs its own
      //     rule. `(a.compliance_summary?.failing ?? 0) * 12000` is not a
      //     displayed constant -- it manufactures money from a REAL count, so
      //     the output moves with real input and therefore looks derived.
      //     That is the same property that made the discarded Monte Carlo
      //     hard to spot by review: a number that responds to the data reads
      //     as a measurement even when the coefficient was invented.
      //
      //     The literal must be excluded from UNIT_CONVERSION, or the rule
      //     fires on every `score * 100` percentage and `bytes / 1024`, which
      //     are arithmetic on a declared unit rather than a priced rate.
      const rate = t.match(
        new RegExp(
          `(?:(${FIGURE_WORD})[^*\\n]{0,60}\\*\\s*(-?\\d[\\d_]*(?:\\.\\d+)?)` +
            `|(-?\\d[\\d_]*(?:\\.\\d+)?)\\s*\\*[^*\\n]{0,60}?(${FIGURE_WORD}))`,
          'i',
        ),
      )
      if (rate) {
        const literal = (rate[2] ?? rate[3] ?? '').replace(/_/g, '')
        // NOT named `n`: that is the line number in this scope, and shadowing
        // it reported every finding at "RiskExposurePage.tsx:12000". Caught by
        // reading the sweep's own output rather than by a test, which is the
        // argument for the instrument printing a line number at all.
        const rateValue = Math.abs(Number(literal))
        if (rateValue >= 2 && !UNIT_CONVERSION.has(rateValue)) {
          findings.push({
            rule: 'fabricated-unit-rate',
            file: rel,
            line: n,
            detail: `figure multiplied by the literal rate ${literal}`,
            why:
              'A per-unit rate applied to a real count manufactures money that moves with real input, so it reads as derived. Source the rate from the risk pack, or report the figure as unpriced.',
          })
        }
      }

      const pct = t.match(/['"`]\s*\d{1,3}(?:\.\d+)?\s*%\s*['"`]/)
      if (pct && !/'0%'|"0%"|`0%`/.test(t)) {
        findings.push({
          rule: 'figure-literal',
          file: rel,
          line: n,
          detail: `percentage literal ${pct[0].trim()}`,
          why: 'A percentage must be computed from API values, never written in.',
        })
      }
    }

    brace += opens - closes
    if (memoDepth > 0 && brace <= braceAtMemoStart && closes > 0) memoDepth = 0
  })

  return findings
}

// ── Driver ─────────────────────────────────────────────────────────────────
export function sweep(srcRoot) {
  const findings = []
  for (const abs of walk(srcRoot)) {
    const rel = relative(srcRoot, abs).split(/[\\/]/).join('/')
    if (isTestFile(rel)) continue
    const src = readFileSync(abs, 'utf8')
    findings.push(...checkUngatedFixtureImports(rel, src))
    findings.push(...checkFigureLiterals(rel, src))
  }
  findings.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line)
  return findings
}

function main(argv) {
  const args = argv.slice(2)
  let json = false
  let root = join(HERE, '..', 'src')
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--json') json = true
    else if (args[i] === '--root') root = args[++i]
    else if (args[i] === '--help') {
      console.log('usage: live-figure-sweep.mjs [--json] [--root <src dir>]')
      return 0
    } else {
      console.error(`unknown option: ${args[i]}`)
      return 2
    }
  }

  try {
    if (!statSync(root).isDirectory()) throw new Error('not a directory')
  } catch {
    console.error(`not a readable directory: ${root}`)
    return 2
  }

  const findings = sweep(root)

  if (json) {
    console.log(JSON.stringify({ root, count: findings.length, findings }, null, 2))
  } else if (findings.length === 0) {
    console.log(`live-figure-sweep: no findings under ${root}`)
  } else {
    console.error(`live-figure-sweep: ${findings.length} finding(s) under ${root}\n`)
    for (const f of findings) {
      console.error(`  ${f.file}:${f.line}  [${f.rule}]  ${f.detail}`)
      console.error(`      ${f.why}`)
    }
  }
  return findings.length === 0 ? 0 : 1
}

// `main "$@"`, not `main "${@:-}"`: with no arguments the latter passes one
// empty string and the option loop rejects it.
if (process.argv[1] && process.argv[1].endsWith('live-figure-sweep.mjs')) {
  process.exit(main(process.argv))
}
