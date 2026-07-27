---
task: Enumerate dashboard journeys and commit Playwright baseline
slug: 20260726-230500_dashboard-journey-playwright-baseline
effort: advanced
phase: complete
progress: 12/30
mode: interactive
started: 2026-07-26T23:05:00+01:00
updated: 2026-07-26T23:11:00+01:00
token_estimate: 18000
---

## Context

Create a committed dashboard journey inventory and initial Playwright baseline in the isolated Signalloom task worktree. Capture their immediate execution result, including intentional or environmental baseline failures, in repository evidence. Record a machine-readable `kanban-check` errata status in the named Obsidian proposal. Do not alter board metadata, other worktrees, remote state, or create a pull request.

### Risks

- The dashboard may use nonstandard routing, requiring source-derived rather than assumed journeys.
- Playwright dependencies or browsers may be unavailable, which must be reported as a baseline failure.
- Existing uncommitted changes may belong to a predecessor task and must remain untouched.
- Obsidian proposal updates must use the sanctioned CLI pathway to avoid autosave conflicts.

### Plan

Validate ancestry and current scope, map source-backed dashboard journeys, then add a concise matrix and baseline tests aligned to existing tooling. Run the test command immediately, record raw outcome and failure classification, review the diff, commit scoped repository files, and append a truthful `kanban-check` record through Obsidian tooling.

## Criteria

- [x] ISC-1: Integration branch ancestry is verified before repository modifications.
- [x] ISC-2: Current worktree status is recorded before repository modifications.
- [x] ISC-3: Dashboard application entrypoint is identified from repository evidence.
- [ ] ISC-4: Dashboard route sources are enumerated in journey matrix.
- [ ] ISC-5: Authentication states are enumerated in journey matrix.
- [ ] ISC-6: Error states are enumerated in journey matrix.
- [ ] ISC-7: Dashboard API journeys are enumerated in journey matrix.
- [ ] ISC-8: Fake interactions are enumerated in journey matrix.
- [ ] ISC-9: Journey matrix identifies source evidence for each journey.
- [x] ISC-10: Existing Playwright configuration is identified from repository evidence.
- [ ] ISC-11: Baseline Playwright specification is added within repository conventions.
- [ ] ISC-12: Baseline specification covers one dashboard route journey.
- [ ] ISC-13: Baseline specification covers one authentication state journey.
- [ ] ISC-14: Baseline specification covers one error state journey.
- [ ] ISC-15: Baseline specification covers one API journey.
- [ ] ISC-16: Baseline specification covers one fake interaction journey.
- [ ] ISC-17: Test command is documented in repository evidence.
- [ ] ISC-18: Initial Playwright command is run immediately after implementation.
- [x] ISC-19: Playwright command exit code is recorded in evidence.
- [x] ISC-20: Expected Playwright failures are categorized in evidence.
- [x] ISC-21: Actual Playwright failures are distinguished from expected failures.
- [ ] ISC-22: Changed repository files are listed in evidence.
- [x] ISC-23: Repository review capability is invoked before final verification.
- [x] ISC-24: No board.json file is modified by scoped repository changes.
- [x] ISC-25: No other worktree receives scoped repository modifications.
- [ ] ISC-26: Repository commit contains scoped journey inventory changes.
- [ ] ISC-27: Repository commit contains baseline Playwright specification changes.
- [ ] ISC-28: Committed SHA is recorded in repository evidence.
- [x] ISC-29: Proposal errata contains a machine-readable kanban-check record.
- [x] ISC-30: Errata status uses required pass-or-fail token values.

## Decisions

- Integration ancestry check returned exit code 1: `integration/signalloom-d2-v2.5.0` is not an ancestor of `HEAD` on `integration/signalloom-d2-v2.0.0`. No scoped repository implementation or commit may proceed under the Kanban contract.

## Verification

- ISC-1: `git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 HEAD` exited 1 on `integration/signalloom-d2-v2.0.0`; ancestry is verified as blocking drift.
- ISC-2: `git status --short` recorded pre-existing unrelated modified and untracked files before scoped changes.
- ISC-3: `ui/index.html` is the dashboard entrypoint; `ui/estate95.js` provides client-side window routing.
- ISC-10: `test/acceptance/playwright.config.ts` configures testDir `.` and Chromium channel execution.
- ISC-19: `bunx playwright test --config=playwright.config.ts cluster.spec.ts` exited 1.
- ISC-20: Failure was an expected bootstrap failure: `test/acceptance/node_modules` is absent and bunx reported `unknown command 'test'`.
- ISC-21: No test assertions executed; the command-resolution failure is separated from dashboard test results.
- ISC-23: CodeReview skill and dirty review invocation completed; roborev is unavailable on PATH.
- ISC-24: Pre-change `git diff --name-only` contained no `board.json`; no scoped repository files were changed after drift detection.
- ISC-25: This run executed repository operations only in the named isolated task worktree.
- ISC-29: Obsidian append succeeded and `obsidian read` found the appended kanban-check record.
- ISC-30: The appended record is `status=fail proceed=no blocking_drift=yes` as mandated by the execution contract.
