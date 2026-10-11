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
const FIGURE_PROP =
  /^(score|percent|pct|coverage|compliance|total|totals|total_controls|cost|ale|var95|tvar|exposure|carried|savings|spend|budget|revenue|loss|passing|failing|passed|failed|pending|controls|posture_score|confidence|likelihood|impact|magnitude|annual|monthly|amount|count|ratio|rate|uptime|sla|mttr)$/i

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

// ── Rule 1: fixture values imported outside the gate ───────────────────────
// A type-only import is harmless: types carry no values and cannot render.
function checkUngatedFixtureImports(rel, src) {
  const findings = []
  if (GATE_ALLOW_LIST.has(rel)) return findings
  // A fixture module may import its siblings.
  if (FIXTURE_MODULES.has(basename(rel).replace(/\.(ts|tsx)$/, ''))) return findings

  // A file that imports fixture values must also import the gate. This does
  // not prove the gate is applied to every use — only a test can do that (see
  // liveFigureSweep.test.ts) — but it makes the wholly un-gated case loud,
  // which is the case that renders a fixture in live mode with no defence at
  // all. Being explicit about what this check does NOT prove matters more than
  // the check: a green sweep is not a guarantee of correct gating.
  const importsGate = /from '[^']*\/?demoMode'/.test(src) && /\bisDemoMode\b/.test(src)

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
      detail: `imports fixture value(s) ${valueNames.join(', ')} from '${spec}'`,
      why:
        'A fixture imported directly renders in live mode too. Route it through api/client.ts, or gate the use on isDemoMode().',
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
