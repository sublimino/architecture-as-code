#!/usr/bin/env bash
# openreports-convert.sh — Convert test output to OpenReports format.
#
# Generates a Kubernetes Report CRD (openreports.io/v1alpha1) from the
# test suite output (the stageMap below is the authoritative stage list).
# Each test becomes a ReportResult entry with
# policy, rule, result (pass/fail/error), severity, and category.
#
# Usage: ./openreports-convert.sh <report-dir> [report-filename]
#
# Output: <report-dir>/<report-filename>

set -euo pipefail

REPORT_DIR="${1:?Usage: openreports-convert.sh <report-dir>}"
REPORT_FILENAME="${2:-signalloom-ci-report.yaml}"

node - "$REPORT_DIR" "$REPORT_FILENAME" <<'OPENREPORTS_SCRIPT'
const { readFileSync, writeFileSync } = require('fs');
const { join } = require('path');

const reportDir = process.argv[2];
const reportFilename = process.argv[3];

// ── Parsers ─────────────────────────────────────────────────────────

function parseTap(content, source, category) {
  const results = [];
  for (const line of content.split('\n')) {
    const m = line.match(/^(ok|not ok)\s+(\d+)\s+[-–]?\s*(.*)$/);
    if (!m) continue;
    const passed = m[1] === 'ok';
    const desc = m[3].trim();
    const skip = /# (skip|todo)\b/i.test(desc);
    results.push({
      source,
      policy: `${source}-test-${m[2]}`,
      rule: desc || `test-${m[2]}`,
      category,
      severity: skip ? 'info' : (passed ? 'info' : 'high'),
      result: skip ? 'skip' : (passed ? 'pass' : 'fail'),
      scored: !skip,
      message: desc,
      timestamp: { seconds: Math.floor(Date.now() / 1000) }
    });
  }
  return results;
}

function parseJunitXml(content, source, category) {
  const results = [];
  const tcRe = /<testcase\s+([^>]*?)(?:\/>|>([\s\S]*?)<\/testcase>)/g;
  const attrRe = /(\w+)="([^"]*)"/g;
  const failRe = /<failure[^>]*?(?:\/>|>([\s\S]*?)<\/failure>)/;
  const errRe = /<error[^>]*?(?:\/>|>([\s\S]*?)<\/error>)/;
  const skipRe = /<skipped/;

  let m;
  while ((m = tcRe.exec(content)) !== null) {
    const attrStr = m[1];
    const body = m[2] || '';
    const attrs = {};
    let am;
    while ((am = attrRe.exec(attrStr)) !== null) { attrs[am[1]] = am[2]; }
    attrRe.lastIndex = 0;

    const name = attrs.name || 'unknown';
    const classname = attrs.classname || '';
    const failure = body.match(failRe);
    const error = body.match(errRe);
    const skipped = skipRe.test(body);
    const failed = !!(failure || error);
    const msg = failed
      ? (failure?.[1] || error?.[1] || 'assertion failed').trim().slice(0, 500)
      : `${name}: passed`;

    results.push({
      source,
      policy: `${source}/${classname || 'default'}`,
      rule: name,
      category,
      severity: skipped ? 'info' : (failed ? 'high' : 'info'),
      result: skipped ? 'skip' : (failed ? 'fail' : 'pass'),
      scored: !skipped,
      message: msg,
      timestamp: { seconds: Math.floor(Date.now() / 1000) }
    });
  }
  return results;
}

function parseGoJson(content, source, category) {
  const results = [];
  for (const line of content.split('\n').filter(Boolean)) {
    let event;
    try { event = JSON.parse(line); } catch { continue; }
    if (event.Action !== 'pass' && event.Action !== 'fail') continue;
    if (!event.Test) continue;

    results.push({
      source,
      policy: `${source}/${event.Package || 'unknown'}`,
      rule: event.Test,
      category,
      severity: event.Action === 'fail' ? 'high' : 'info',
      result: event.Action,
      scored: true,
      message: `${event.Test}: ${event.Action}`,
      timestamp: { seconds: Math.floor(Date.now() / 1000) }
    });
  }
  return results;
}

// ── Stage map ───────────────────────────────────────────────────────

const stageMap = [
  { file: 'stage1-static.tap',     parser: parseTap,       source: 'bats-static-contracts',     category: 'topology' },
  // vitest emits JUnit natively (--reporter=junit), so this reuses parseJunitXml
  // rather than adding a parser. Nesting is irrelevant to it: the parser walks
  // <testcase> elements with a regex and never looks at their <testsuite>.
  { file: 'stage1b-dashboard-unit.xml', parser: parseJunitXml, source: 'vitest-dashboard-unit', category: 'unit' },
  // The acceptance-spec coverage registry. Categorised as 'meta' because it
  // asserts nothing about the product -- it asserts that the other stages run
  // what they claim to run.
  { file: 'stage1c-acceptance-coverage.tap', parser: parseTap, source: 'bats-acceptance-coverage', category: 'meta' },
  // Also 'meta': it asserts that stage [4/7] builds everything
  // demo-signalloom-up builds, not anything about the product. Reported
  // separately from 1c because the two answer different questions -- 1c asks
  // whether the tests run, this asks whether the thing under test was built.
  { file: 'stage1d-build-parity.tap', parser: parseTap, source: 'bats-ci-build-parity', category: 'meta' },
  // 'meta' for the same reason as 1c and 1d: it asserts that a diagnostic tells
  // the truth about this profile, not anything about the product. Without a row
  // here the stage would run and its results would be dropped from the report --
  // which is the silent-degradation shape 1c exists to catch.
  { file: 'stage1e-node-images.tap', parser: parseTap, source: 'bats-doctor-node-images', category: 'meta' },
  // 'meta' for the same reason again: it asserts nothing about the product. It
  // asserts that the artifacts this pipeline leaves behind say which run they
  // belong to and how it ended -- the guard on the harness reporting honestly
  // about itself. 1f rather than a second 1e: this and the node-image stage were
  // written in parallel and both claimed the 1e slot. The suffixes exist to keep
  // insertion cheap, which only holds while each one names exactly one stage.
  { file: 'stage1f-ci-terminal-state.tap', parser: parseTap, source: 'bats-ci-terminal-state', category: 'meta' },
  // 1g/1h/1i: the suites that used to run nowhere, and the guards that keep
  // them running. 'meta' for 1h and 1i and 'contract' for 1g -- 1g asserts
  // things about the product (RBAC, images, flux substitution, port-forward
  // supervision), whereas 1h and 1i assert that the harness is honest about
  // what it ran. That distinction is why 1g's results belong in the product
  // categories of the report and the other two do not.
  //
  // These three entries are not decoration. `CITERM every TAP stage report is
  // registered in the stage map` in test/ci-terminal-state.bats failed on the
  // CI VM the moment stage 1g was added without this line -- a stage whose
  // report is unmapped still RUNS, and its results are silently dropped from
  // the OpenReports artifact, so the run goes green having reported less than
  // it tested. Precisely the shape of defect stage 1g exists to end, reappearing
  // one layer up in the reporting.
  { file: 'stage1g-unregistered-guards.tap', parser: parseTap, source: 'bats-previously-unrun-guards', category: 'contract' },
  { file: 'stage1h-bats-registry.tap', parser: parseTap, source: 'bats-registry-coverage', category: 'meta' },
  { file: 'stage1j-ci-report-integrity.tap', parser: parseTap, source: 'ci-report-integrity', category: 'meta' },
  // 1k bans kubectl exec as a probe in test files. Categorised 'contract'
  // rather than 'meta' on the same distinction 1g is: it asserts a property of
  // the tests that guard the product -- specifically that a probe's failure can
  // be told apart from the property failing -- which is what let a distroless
  // image silently disarm the cardvault auth test while it stayed green. That
  // belongs in the product categories of the report, not with the harness
  // self-checks.
  { file: 'stage1k-exec-probe-ban.tap', parser: parseTap, source: 'bats-exec-probe-ban', category: 'contract' },
  // 1k asserts a property of the product's manifests -- that every RBAC binding
  // resolves to a ServiceAccount and a Role that exist -- so it is 'contract'
  // alongside 1g, not 'meta'.
  { file: 'stage1l-rbac-subjects.tap', parser: parseTap, source: 'bats-rbac-subject-resolution', category: 'contract' },
  //
  // Stage 1m (vocabulary seam mutation proof) is deliberately NOT mapped, for
  // the identical reason as 1i below: its output is prose -- "ok <label>" plus a
  // quoted AssertionError -- not TAP and not JUnit. Pointing a parser at it
  // would contribute ZERO rows while reading as configured coverage, which is
  // worse than no entry. It is named stage1m-*.txt rather than .tap precisely so
  // `every TAP stage report is registered in the stage map` in
  // test/ci-terminal-state.bats does not demand an entry that could only lie.
  //
  // The stage still gates the pipeline: run_stage records its pass/fail in
  // summary.json regardless, so a guard that stops firing still fails the run.
  //
  // Stage 1i (audit-guard reintroduction proof) is deliberately NOT mapped.
  // Its output is prose -- "RED as required" / "GUARD DID NOT FIRE" -- not TAP
  // and not JUnit, so any parser here would match nothing and contribute ZERO
  // rows while looking configured. That is the junit-reporter defect
  // playwright.config.ts documents: a missing input degrading to nothing rather
  // than to an error, and the suite staying green having reported less than it
  // tested. An entry that parses nothing is worse than no entry, because it
  // reads as coverage.
  //
  // The stage still gates the pipeline: run_stage records its pass/fail and
  // exit code in summary.json regardless of whether anything here parses it, so
  // a guard that stops firing still fails the run. If per-case rows are wanted
  // in OpenReports later, the fix is to make the proof emit TAP and rename it
  // .tap -- not to point a parser at prose.
  // 1n is the vacuous lint's own falsification suite (TAP). 1m, the lint itself,
  // is deliberately NOT mapped: its output is prose, and a parser matching
  // nothing contributes zero rows while looking configured. The stage still
  // gates the run, because run_stage records its exit code either way.
  { file: 'stage1p-vacuous-lint-proof.tap', parser: parseTap, source: 'bats-vacuous-lint-proof', category: 'meta' },
  { file: 'stage2-api.xml',        parser: parseJunitXml,  source: 'pytest-api-contracts',       category: 'api' },
  { file: 'stage3-fakes.xml',      parser: parseJunitXml,  source: 'pytest-fake-integrations',   category: 'integration' },
  { file: 'stage4-dashboard.json', parser: parseGoJson,    source: 'go-test-dashboard-api',      category: 'api' },
  { file: 'stage5-harness.tap',    parser: parseTap,       source: 'bats-harness-contract',      category: 'harness' },
  { file: 'stage6-flux.tap',       parser: parseTap,       source: 'flux-convergence',           category: 'gitops' },
  { file: 'stage7-runtime.tap',    parser: parseTap,       source: 'bats-runtime-negatives',     category: 'security' },
  { file: 'stage7b-adversarial.tap', parser: parseTap,    source: 'bats-adversarial-api',       category: 'security' },
  { file: 'stage8-browser.xml',    parser: parseJunitXml,  source: 'playwright-browser-journey', category: 'e2e' },
  { file: 'stage8b-smoke.xml',     parser: parseJunitXml,  source: 'playwright-page-smoke',      category: 'e2e' },
];

// ── Process all stages ──────────────────────────────────────────────

let allResults = [];

for (const stage of stageMap) {
  const path = join(reportDir, stage.file);
  try {
    const content = readFileSync(path, 'utf-8');
    allResults = allResults.concat(stage.parser(content, stage.source, stage.category));
  } catch (e) {
    allResults.push({
      source: stage.source,
      policy: `${stage.source}/missing-report`,
      rule: stage.file,
      category: stage.category,
      severity: 'critical',
      result: 'error',
      scored: false,
      message: `Report file missing or unreadable: ${stage.file} (${e.message})`,
      timestamp: { seconds: Math.floor(Date.now() / 1000) }
    });
  }
}

// ── Build summary counts ────────────────────────────────────────────

const summary = { pass: 0, fail: 0, warn: 0, error: 0, skip: 0 };
for (const r of allResults) {
  if (summary[r.result] !== undefined) summary[r.result]++;
}

// ── Generate OpenReports YAML (openreports.io/v1alpha1 Report) ──────

function yamlStr(s) {
  if (!s) return '""';
  if (/[:\n"'#{}[\],&*!|>%@`]/.test(s) || s.length > 120) {
    return `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n')}"`;
  }
  return s;
}

const now = new Date().toISOString();
const lines = [];

lines.push('apiVersion: openreports.io/v1alpha1');
lines.push('kind: Report');
lines.push('metadata:');
lines.push(`  name: signalloom-ci-${now.replace(/[:.]/g, '-').slice(0, 19)}`);
lines.push('  namespace: signalloom-ci');
lines.push('  labels:');
lines.push('    app.kubernetes.io/name: signalloom-d2');
lines.push('    app.kubernetes.io/component: ci');
lines.push('    openreports.io/source: signalloom-ci-pipeline');
lines.push(`source: signalloom-ci-pipeline`);
lines.push('summary:');
lines.push(`  pass: ${summary.pass}`);
lines.push(`  fail: ${summary.fail}`);
lines.push(`  warn: ${summary.warn}`);
lines.push(`  error: ${summary.error}`);
lines.push(`  skip: ${summary.skip}`);
lines.push('results:');

for (const r of allResults) {
  lines.push(`  - source: ${yamlStr(r.source)}`);
  lines.push(`    policy: ${yamlStr(r.policy)}`);
  lines.push(`    rule: ${yamlStr(r.rule)}`);
  lines.push(`    category: ${yamlStr(r.category)}`);
  lines.push(`    severity: ${r.severity}`);
  lines.push(`    result: ${r.result}`);
  lines.push(`    scored: ${r.scored}`);
  lines.push(`    message: ${yamlStr(r.message)}`);
  lines.push(`    timestamp:`);
  lines.push(`      seconds: ${r.timestamp.seconds}`);
}

const yaml = lines.join('\n') + '\n';
const outPath = join(reportDir, reportFilename);
writeFileSync(outPath, yaml);

console.log(`OpenReports: ${outPath}`);
console.log(`  results: ${allResults.length} (pass=${summary.pass} fail=${summary.fail} error=${summary.error} skip=${summary.skip})`);
OPENREPORTS_SCRIPT
