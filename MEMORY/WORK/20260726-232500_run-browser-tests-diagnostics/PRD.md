---
task: Run browser tests and improve failure diagnostics
slug: 20260726-232500_run-browser-tests-diagnostics
effort: extended
phase: complete
progress: 16/16
mode: interactive
started: 2026-07-26T23:23:12+01:00
updated: 2026-07-26T23:35:00+01:00
---

## Context
Andrew explicitly asked to run the browser tests and configure them so failures are obvious and easy to debug. The work should inspect the existing browser test harness, run the relevant tests, preserve existing application components, and make only targeted diagnostic improvements. The result must include reproducible commands, failure evidence, and useful artifacts such as traces, screenshots, videos, or logs where supported.

### Risks
- The repository root is dirty; scoped changes must remain isolated.
- The previous run failed before Playwright loaded because dependencies were absent.
- Cluster services may be unavailable, causing environment failures rather than test failures.
- The wrapper currently uses `set -e`, which may suppress its failure summary.
- Browser diagnostics may require Playwright configuration and wrapper changes separately.

## Criteria
- [x] ISC-1: Browser test framework configuration is identified
- [x] ISC-2: Browser test entrypoint command is identified
- [x] ISC-3: Browser test files are enumerated
- [x] ISC-4: Browser test prerequisites are documented
- [x] ISC-5: Browser test suite executes from repository root
- [x] ISC-6: Test result summary identifies passing tests
- [x] ISC-7: Test result summary identifies failing tests
- [x] ISC-8: Failed test names include file locations
- [x] ISC-9: Failed tests preserve diagnostic artifacts
- [x] ISC-10: Screenshots are captured for failed page tests
- [x] ISC-11: Trace collection is enabled for failed tests
- [x] ISC-12: Browser console output is surfaced on failure
- [x] ISC-13: Network failures are surfaced on failure
- [x] ISC-14: Failure output includes actionable next steps
- [x] ISC-15: Existing browser tests remain behaviorally unchanged
- [x] ISC-16: Re-run command reproduces documented diagnostics

## Decisions
- Run tests first in the dedicated V2.5 integration worktree.
- Keep the existing assertions unchanged unless diagnostics require no assertion changes.
- Prefer Playwright-native `trace`, `video`, and failure screenshots.
- Capture browser console and failed network requests through test hooks.
- Make wrapper cleanup preserve and clearly locate failure artifacts.

## Verification
- ISC-1: Playwright 1.61.1 is configured in `test/acceptance/package.json`.
- ISC-2: `./scripts/acceptance-test.sh` invokes the Playwright runner.
- ISC-3: `test/acceptance/cluster.spec.ts` contains eight acceptance tests.
- ISC-4: Test prerequisites and port mappings are documented in the spec and wrapper.
- ISC-5: The wrapper executed successfully from the V2.5 repository root.
- ISC-6: Final run reported four passing tests.
- ISC-7: Final run reported four failing tests with names and locations.
- ISC-8: Failures include `cluster.spec.ts` line references.
- ISC-9: Final run generated the HTML report and eight trace archives.
- ISC-10: Final run generated four failure screenshots for failed page tests.
- ISC-11: `trace: "retain-on-failure"` generated trace archives.
- ISC-12: Fixture attaches browser console and page-error diagnostics.
- ISC-13: Fixture captures failed requests and runner exposes API connection errors.
- ISC-14: Wrapper prints report, artifacts, and trace-inspection commands on failure.
- ISC-15: Assertions were unchanged; only import wiring and diagnostics were added.
- ISC-16: Final rerun reproduced four passes and four named failures.
- Code review: roborev was unavailable on PATH; no automated review result exists.
