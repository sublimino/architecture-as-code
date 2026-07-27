---
task: Revalidate integration ancestry and complete dashboard baseline
slug: 20260726-232000_revalidate-integration-dashboard-baseline
effort: advanced
phase: complete
progress: 4/24
mode: interactive
started: 2026-07-26T23:20:00+01:00
updated: 2026-07-26T23:22:40+01:00
token_estimate: 14000
iteration: 2
---

## Context

Revalidate the required `integration/signalloom-d2-v2.5.0` ancestry before touching scoped repository artifacts. If repaired, create and commit a source-backed dashboard journey matrix, baseline Playwright tests, execution evidence, and a truthful proposal errata record. The prior run stopped correctly because the supplied integration target was not an ancestor. Never modify board.json, another worktree, remotes, or pull-request state.

### Risks

- The worktree may still target an obsolete integration line.
- Prior uncommitted work must remain outside this card's commit.
- Playwright bootstrap may fail independently of dashboard behavior.

## Criteria

- [x] ISC-1: Required integration ancestry command is executed before scoped repository modifications.
- [ ] ISC-2: Required integration ancestry command exits zero before implementation begins.
- [x] ISC-3: Current branch name is recorded in repository evidence.
- [x] ISC-4: Current worktree status is recorded in repository evidence.
- [ ] ISC-5: Dashboard entrypoint source is cited in journey matrix.
- [ ] ISC-6: Registered dashboard windows are listed in journey matrix.
- [ ] ISC-7: Broker API routes are listed in journey matrix.
- [ ] ISC-8: Authentication states are listed in journey matrix.
- [ ] ISC-9: Error states are listed in journey matrix.
- [ ] ISC-10: Fake dashboard interactions are listed in journey matrix.
- [ ] ISC-11: Journey matrix links each category to source files.
- [ ] ISC-12: Playwright configuration is cited in baseline test evidence.
- [ ] ISC-13: Dashboard route baseline test is added.
- [ ] ISC-14: Authentication-state baseline test is added.
- [ ] ISC-15: Error-state baseline test is added.
- [ ] ISC-16: API-journey baseline test is added.
- [ ] ISC-17: Fake-interaction baseline test is added.
- [ ] ISC-18: Initial Playwright command is executed after test addition.
- [ ] ISC-19: Initial Playwright exit code is recorded in evidence.
- [ ] ISC-20: Initial Playwright failures are classified in evidence.
- [ ] ISC-21: Repository review is executed against scoped changes.
- [ ] ISC-22: Scoped repository artifacts are committed in one commit.
- [ ] ISC-23: Commit SHA is recorded in repository evidence.
- [x] ISC-24: Proposal errata records required kanban-check status tokens.

## Decisions

- Revalidation remains blocking: the required v2.5 integration branch is not an ancestor of HEAD `4bdfc2912b1d75fa73baa5fe58893817a4b47e3e` on `integration/signalloom-d2-v2.0.0`; no scoped implementation, test additions, or commit is permitted.

## Verification

- `git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 HEAD` exited 1 during this rerun.
- `git branch --show-current` reported `integration/signalloom-d2-v2.0.0`.
- `git status --short` recorded pre-existing unrelated modifications and untracked task artifacts.
- `obsidian read` exited 0 and confirmed the latest proposal errata: `kanban-check: status=fail proceed=no blocking_drift=yes`.
- Code review invocation could not run because roborev is not installed; no scoped implementation exists to review.
