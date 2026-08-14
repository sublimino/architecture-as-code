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
  { file: 'stage2-api.xml',        parser: parseJunitXml,  source: 'pytest-api-contracts',       category: 'api' },
  { file: 'stage3-fakes.xml',      parser: parseJunitXml,  source: 'pytest-fake-integrations',   category: 'integration' },
  { file: 'stage4-dashboard.json', parser: parseGoJson,    source: 'go-test-dashboard-api',      category: 'api' },
  { file: 'stage5-harness.tap',    parser: parseTap,       source: 'bats-harness-contract',      category: 'harness' },
  { file: 'stage6-flux.tap',       parser: parseTap,       source: 'flux-convergence',           category: 'gitops' },
  { file: 'stage7-runtime.tap',    parser: parseTap,       source: 'bats-runtime-negatives',     category: 'security' },
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
