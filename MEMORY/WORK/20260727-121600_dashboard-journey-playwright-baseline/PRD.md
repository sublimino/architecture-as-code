---
task: Document journeys and baseline Playwright browser tests
slug: 20260727-121600_dashboard-journey-playwright-baseline
effort: extended
phase: complete
progress: 20/20
mode: interactive
started: 2026-07-27T12:16:00+01:00
updated: 2026-07-27T12:30:00+01:00
---

## Context

Document the current Estate 95 dashboard's user journeys and establish truthful
Playwright baseline coverage for login, dashboard view, scan initiation, and
results display. The work must remain in the assigned integration worktree,
preserve existing unrelated changes, leave board metadata untouched, avoid any
push or pull request, and retain a reproducible browser-run record. The matrix
must distinguish source-backed live interactions from demo-only interactions.

### Risks

- Login may be handled by Dex rather than the broker dashboard.
- The dashboard may expose scans through a demo-console endpoint, not a browser route.
- The local broker or Chrome channel may be unavailable during baseline execution.
- Existing uncommitted changes could make a broad commit unsafe.

## Criteria

- [x] ISC-1: Assigned worktree path matches the task contract exactly.
- [x] ISC-2: Integration base ref is an ancestor of HEAD.
- [x] ISC-3: Repository identity outside assigned worktree remains unmodified.
- [x] ISC-4: Dashboard entrypoint journey appears in the matrix.
- [x] ISC-5: Authentication boundary appears in the matrix.
- [x] ISC-6: Scan initiation journey appears in the matrix.
- [x] ISC-7: Results display journey appears in the matrix.
- [x] ISC-8: Matrix identifies each critical journey's source evidence.
- [x] ISC-9: Matrix identifies each critical journey's Playwright coverage.
- [x] ISC-10: Login baseline test stub exists in acceptance tests.
- [x] ISC-11: Dashboard-view baseline test stub exists in acceptance tests.
- [x] ISC-12: Scan-initiation baseline test stub exists in acceptance tests.
- [x] ISC-13: Results-display baseline test stub exists in acceptance tests.
- [x] ISC-14: Test stubs use repository Playwright configuration.
- [x] ISC-15: Baseline Playwright command executes after test changes.
- [x] ISC-16: Baseline command exit status is recorded truthfully.
- [x] ISC-17: Browser outcome distinguishes passing assertions from failures.
- [x] ISC-18: Proposal errata records the card's machine-readable evidence.
- [x] ISC-19: Commit contains only scoped card artifacts.
- [x] ISC-20: No board metadata file is modified.

## Decisions

- Inspect current committed browser assets before adding a narrowly scoped baseline.
- Use deterministic request interception for Security Sandbox UI coverage; preserve live Dex integration coverage already owned by `signalloom-test-1.spec.ts`.

## Verification

- Assigned path was confirmed by `git rev-parse --show-toplevel`.
- `git merge-base --is-ancestor refs/heads/integration/signalloom-d2-v2.5.0 HEAD` exited 0 before and after changes.
- Matrix rows cover Dex login, Estate95 dashboard, Security Sandbox scan submission, and verdict rendering.
- `test/acceptance/dashboard-journey.spec.ts` adds three source-backed browser tests and uses the existing Dex test for login.
- `cd test/acceptance && bunx playwright test --config=playwright.config.ts dashboard-journey.spec.ts` exited 0: 7 passed in 3.1s.
- Commit `8c5e575a8575358db762b0362603395a0cfb2620` contains only the matrix and browser specification; commit `79522843c3abe1f057b18c352489824bbe478735` contains only proposal errata.
- `git diff --name-only refs/heads/integration/signalloom-d2-v2.5.0~2..HEAD` returned no `board.json` path.
- QATester identified a pre-existing Orbit selector ambiguity; the exact-text locator was fixed and the final browser run passed.
- Browser skill was invoked but its standalone diagnostic session could not start; Playwright produced the browser evidence. CodeReview was invoked, but roborev is unavailable on PATH.
