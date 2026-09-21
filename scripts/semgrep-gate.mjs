#!/usr/bin/env node
// Semgrep gate: fail on NEW high-severity findings, not on the existing accepted set.
//
// Why this exists rather than `semgrep --error`:
//
//  1. Semgrep's exit code conflates findings with scan errors. This repository
//     produces 75 partial-parse errors (unsupported syntax in vendored and generated
//     files), which makes `--error` exit 2 — "fatal" — even when there are zero
//     findings at the gated severity. A gate that cannot tell "you introduced a
//     vulnerability" from "the parser does not understand a vendored file" is a gate
//     people learn to ignore. Parse errors are reported here and never fail the run.
//
//  2. `extra.fingerprint` is unusable on the free tier. Every finding returns the
//     literal string "requires login" for both `fingerprint` and `lines`, so the
//     field semgrep provides for exactly this purpose cannot key a baseline. Verified
//     against semgrep 1.176.1: 19 findings, 1 unique fingerprint value.
//
// The baseline key is therefore `check_id|path` with an expected count. That is
// deliberately coarser than a line number, because line numbers churn on every edit
// above the finding and would make the baseline fail constantly for no security
// reason. The documented consequence: if someone fixes one of two findings of the
// same rule in the same file and introduces a different one, the count still matches
// and the gate stays green. Accepted, because the alternative is a baseline nobody
// can keep current.
//
// Usage:
//   node scripts/semgrep-gate.mjs [--severity ERROR] [--update] [path ...]
//   --update rewrites the baseline from the current tree. Review that diff: each
//            entry needs a reason, and a growing baseline is a signal, not a fix.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const baselinePath = resolve(repoRoot, ".semgrep-baseline.json");

const argv = process.argv.slice(2);
const update = argv.includes("--update");
const sevIdx = argv.indexOf("--severity");
const severity = sevIdx === -1 ? "ERROR" : argv[sevIdx + 1];
const targets = argv.filter(
  (a, i) => !a.startsWith("--") && i !== sevIdx + 1,
);
const scanTargets = targets.length
  ? targets
  : ["d2-signalloom", "d2-osramp-apps", "scripts", "test"];

const config = process.env.SEMGREP_CONFIG || "p/default";

// HOME is forced because semgrep aborts with "Permission denied open
// ~/.semgrep/settings.yml" under any sandbox profile that does not grant that path,
// and because a CI container may have no writable home at all.
const semgrepHome =
  process.env.SEMGREP_HOME || resolve(repoRoot, ".cache/semgrep-home");

const run = spawnSync(
  "semgrep",
  [
    `--config=${config}`,
    "--metrics=off",
    "--json",
    "--quiet",
    "--disable-version-check",
    ...scanTargets,
  ],
  {
    cwd: repoRoot,
    env: { ...process.env, HOME: semgrepHome },
    encoding: "utf8",
    maxBuffer: 256 * 1024 * 1024,
  },
);

if (run.error) {
  process.stderr.write(`semgrep-gate: could not run semgrep: ${run.error.message}\n`);
  process.exit(127);
}

let report;
try {
  report = JSON.parse(run.stdout);
} catch {
  // Only now is a non-zero exit actually fatal: no parseable report came back, so
  // there is nothing to judge. Surfacing semgrep's own stderr matters here — this is
  // the one path where the tool genuinely failed rather than found something.
  process.stderr.write(
    `semgrep-gate: semgrep produced no parseable JSON (exit ${run.status}).\n`,
  );
  process.stderr.write((run.stderr || "").slice(0, 4000));
  process.exit(2);
}

const findings = (report.results || []).filter(
  (r) => r?.extra?.severity === severity,
);
const parseErrors = (report.errors || []).length;

/** Collapse findings to `check_id|path` -> count. */
const tally = (list) => {
  const out = {};
  for (const f of list) {
    const key = `${f.check_id}|${f.path}`;
    out[key] = (out[key] || 0) + 1;
  }
  return out;
};

const current = tally(findings);

if (update) {
  const existing = existsSync(baselinePath)
    ? JSON.parse(readFileSync(baselinePath, "utf8"))
    : { accepted: {} };
  const accepted = {};
  for (const [key, count] of Object.entries(current).sort()) {
    accepted[key] = {
      count,
      // Reasons are preserved across regeneration so --update never silently
      // discards the justification that made a finding acceptable.
      reason: existing.accepted?.[key]?.reason || "TODO: state why this is accepted",
    };
  }
  writeFileSync(
    baselinePath,
    `${JSON.stringify({ severity, accepted }, null, 2)}\n`,
  );
  const missing = Object.values(accepted).filter((v) =>
    v.reason.startsWith("TODO"),
  ).length;
  process.stdout.write(
    `semgrep-gate: wrote ${Object.keys(accepted).length} entries to .semgrep-baseline.json\n`,
  );
  if (missing) {
    process.stdout.write(
      `  ${missing} entr${missing === 1 ? "y" : "ies"} still need a reason — fill them in before committing.\n`,
    );
  }
  process.exit(0);
}

if (!existsSync(baselinePath)) {
  process.stderr.write(
    "semgrep-gate: no .semgrep-baseline.json. Run `make scan-sast-baseline` and review the diff.\n",
  );
  process.exit(2);
}

const baseline = JSON.parse(readFileSync(baselinePath, "utf8"));
const accepted = baseline.accepted || {};

const introduced = [];
for (const [key, count] of Object.entries(current)) {
  const allowed = accepted[key]?.count ?? 0;
  if (count > allowed) introduced.push({ key, count, allowed });
}
// A finding that disappeared is good news, but a stale baseline entry hides the next
// regression in that file, so it is reported (never fatal) to keep the file honest.
const resolved = Object.keys(accepted).filter((k) => !current[k]);

process.stdout.write(
  `==> semgrep: ${config}, gating on ${severity} above baseline\n`,
);
process.stdout.write(
  `    ${findings.length} ${severity} finding(s), ${Object.keys(accepted).length} accepted in baseline, ${parseErrors} parse error(s) (not gated)\n`,
);

if (resolved.length) {
  process.stdout.write(
    `    ${resolved.length} baseline entr${resolved.length === 1 ? "y" : "ies"} no longer firing — prune with \`make scan-sast-baseline\`:\n`,
  );
  for (const k of resolved) process.stdout.write(`      - ${k}\n`);
}

if (introduced.length) {
  process.stderr.write(`\nsemgrep-gate: NEW ${severity} finding(s):\n`);
  for (const { key, count, allowed } of introduced) {
    const [check, path] = key.split("|");
    process.stderr.write(`  ${path}\n    ${check}  (${count} found, ${allowed} accepted)\n`);
    for (const f of findings.filter(
      (x) => `${x.check_id}|${x.path}` === key,
    )) {
      process.stderr.write(`      line ${f.start?.line}: ${f.extra?.message?.split("\n")[0] ?? ""}\n`);
    }
  }
  process.stderr.write(
    "\n  Fix it, or — if it is a false positive or a deliberate fixture — add it to\n" +
      "  .semgrep-baseline.json WITH a reason via `make scan-sast-baseline`.\n",
  );
  process.exit(1);
}

process.stdout.write("==> semgrep: no new findings above baseline\n");
process.exit(0);
