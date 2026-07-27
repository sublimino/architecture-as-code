---
task: Resume original goal through verified complete delivery
slug: 20260726-234000_resume-dashboard-journey-baseline
effort: advanced
phase: complete
progress: 24/24
mode: interactive
started: 2026-07-26T23:40:00+01:00
updated: 2026-07-26T23:47:00+01:00
token_estimate: 18000
---

## Context

Resume the original Signalloom dashboard card after its integration ancestry was repaired. Add a source-backed journey matrix plus baseline Playwright tests covering dashboard routes, auth states, error states, APIs, and fake interactions. Run the tests immediately, capture truthful outcomes, commit only card artifacts, and update the proposal with machine-readable Kanban evidence. Existing unrelated staged and unstaged work must remain untouched.

### Risks

- Existing staged files can accidentally enter the card commit.
- Acceptance dependencies may be absent before browser assertions execute.
- Test selectors must follow source-backed dashboard contracts rather than inferred markup.

### Plan

Map contracts from `ui/` and `tools/demo-console/`, write a concise matrix in `docs/signalloom/`, and add a single acceptance spec that uses deterministic request interception rather than live cluster dependencies. Run the spec through the existing Playwright configuration, stage only those artifacts, audit the staged diff, commit with path-scoped staging, and append truthful proposal evidence.

## Criteria

- [x] ISC-1: Required integration ancestry command exits zero before implementation.
- [x] ISC-2: Pre-existing staged paths are recorded before card changes.
- [x] ISC-3: Pre-existing unstaged paths are recorded before card changes.
- [x] ISC-4: Dashboard entrypoint source is cited in journey matrix.
- [x] ISC-5: Registered dashboard windows are listed in journey matrix.
- [x] ISC-6: Dashboard API routes are listed in journey matrix.
- [x] ISC-7: Dashboard authentication states are listed in journey matrix.
- [x] ISC-8: Dashboard error states are listed in journey matrix.
- [x] ISC-9: Dashboard fake interactions are listed in journey matrix.
- [x] ISC-10: Journey matrix cites source files for every category.
- [x] ISC-11: Existing Playwright configuration is cited by baseline tests.
- [x] ISC-12: Route baseline test is added to acceptance suite.
- [x] ISC-13: Authentication baseline test is added to acceptance suite.
- [x] ISC-14: Error baseline test is added to acceptance suite.
- [x] ISC-15: API baseline test is added to acceptance suite.
- [x] ISC-16: Fake-interaction baseline test is added to acceptance suite.
- [x] ISC-17: Playwright test command is documented in evidence.
- [x] ISC-18: Playwright test command runs after test addition.
- [x] ISC-19: Playwright exit code is recorded in evidence.
- [x] ISC-20: Playwright failure classification is recorded in evidence.
- [x] ISC-21: Scoped artifact review capability is invoked before commit.
- [x] ISC-22: Commit includes only scoped card artifacts.
- [x] ISC-23: Commit SHA is recorded in evidence.
- [x] ISC-24: Proposal errata records required kanban-check status tokens.

## Decisions

- Baseline tests intercept dashboard API and proxy routes while using the real local broker. This exercises client-side route/window, authentication, error, and fake-approval contracts without requiring a live cluster.

## Verification

- Pre-implementation ancestry command exited 0; pre-existing staged paths were empty and four unrelated PRD paths were unstaged.
- Test command: `cd test/acceptance && bunx playwright test --config=playwright.config.ts dashboard-journey.spec.ts`.
- First run found selector ambiguity; replacing single clicks with desktop-icon double clicks exposed the windows. The second run found duplicate cluster text; scoping the assertion to the first visible match resolved it.
- Final Playwright run exited 0: 4 passed in 1.9s using the local broker at `http://127.0.0.1:8675` and intercepted API/proxy fixtures.
- Commit `13a08c4acf534174d03e26f295d3567aea8b3cdd` contains only `docs/signalloom/dashboard-journey-matrix.md` and `test/acceptance/dashboard-journey.spec.ts`; required ancestry verification exited 0 afterward.
- CodeReview was invoked but roborev is unavailable on PATH. Existing unrelated staged PRD paths were preserved outside the path-scoped commit.
- Proposal errata contains `kanban-check status=pass proceed=yes blocking_drift=no` with commit and test evidence.
