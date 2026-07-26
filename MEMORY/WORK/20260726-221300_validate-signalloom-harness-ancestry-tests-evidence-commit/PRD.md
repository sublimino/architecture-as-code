---
task: Validate Signalloom harness wiring, ancestry, tests, evidence, commit
slug: 20260726-221300_validate-signalloom-harness-ancestry-tests-evidence-commit
effort: extended
phase: verify
progress: 15/17
mode: interactive
started: 2026-07-26T22:13:00+01:00
updated: 2026-07-26T22:24:00+01:00
---

## Context

This card validates the Signalloom D2 V2.5 harness baseline in the isolated
Governor worktree. It covers repository wiring, integration ancestry, existing
smoke/static test commands, proposal task-graph assumptions, evidence capture,
and a machine-readable proposal errata entry. It must not implement dashboard
features, edit board.json, touch another worktree, push, or create a PR.

### Risks

- The checked-out commit may be detached while the named integration ref exists.
- The Makefile or delivery contract may still identify the prior V2.0 branch.
- Existing tests may validate the old contract rather than the V2.5 graph.
- External source roots may be unavailable for the full preflight command.
- Proposal errata must distinguish baseline pass from feature readiness.

### Premortem

- A stale V2.0 branch default could make a green smoke test validate the wrong
  integration target.
- A detached HEAD could produce an untraceable commit unless the named branch
  is checked out before committing.
- Full root preflight may fail because sibling repositories are not mounted in
  this isolated worktree.
- Updating historical errata instead of only active wiring would create scope
  drift and corrupt prior evidence.

### Prerequisites check

- The target branch and release branch must exist locally.
- `jq`, `bats`, `make`, and Bash must be installed.
- The four configured sibling repository roots must be available for preflight.
- The proposal file must be writable through its authoritative path.

## Criteria

- [x] ISC-1: Worktree identifies integration/signalloom-d2-v2.5.0 as target ref
- [x] ISC-2: Worktree starts without tracked repository modifications
- [x] ISC-3: Target integration branch exists as a local ref
- [x] ISC-4: Target integration branch is an ancestor of HEAD
- [ ] ISC-5: Main release branch is an ancestor of target integration
- [x] ISC-6: Delivery contract names the osramp-demo repository
- [x] ISC-7: Delivery contract names the V2.5 integration branch
- [x] ISC-8: Makefile default branch matches delivery contract
- [x] ISC-9: Contract checker validates required delivery fields
- [x] ISC-10: Preflight checker validates four configured source roots
- [ ] ISC-11: Signalloom contract smoke command exits successfully
- [x] ISC-12: Signalloom help command exits successfully
- [x] ISC-13: Local Signalloom lifecycle BATS suite exits successfully
- [x] ISC-14: Signalloom static configuration test exits successfully
- [x] ISC-15: Harness scripts pass shell syntax validation
- [x] ISC-16: Proposal graph preserves P0 before P1 pre-flight dependency
- [x] ISC-17: Changes remain limited to harness wiring and evidence records

## Decisions

- Treat the V2.5 integration ref in the card as canonical for active harness
  wiring, while retaining historical V2.0 references in historical errata.
- Run only fast deterministic smoke/static commands; do not start Kind or edit
  delivery features.
- Record baseline qualification separately from V2.5 implementation readiness.
- The target branch is already checked out by another worktree, so this
  isolated worktree remains detached and will commit its verified delta by SHA.

### Plan

1. Establish the named V2.5 branch and ancestry evidence before edits.
2. Baseline the active contract, Makefile wiring, deterministic BATS/static
   commands, shell syntax, and proposal graph.
3. Patch only stale active branch wiring and its direct test fixture.
4. Re-run the fastest checks, append proposal errata, and commit repository
   changes without push or PR creation.

## Verification

- `git status --short --branch` showed detached HEAD with no tracked changes;
  the target ref and HEAD both resolved to `cb0b7df44462f5c8af913dae3d47ce501565b3ca`.
- `git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 HEAD` exited 0.
- `git merge-base --is-ancestor main integration/signalloom-d2-v2.5.0` exited 1;
  the contract smoke therefore remains blocked by repository ancestry drift.
- Active branch wiring was corrected in `Makefile` and
  `docs/signalloom/delivery-contract.json`; direct BATS expectations now match
  the durable `signalloom-up.sh` and `signalloom-down.sh` targets.
- `env LC_ALL=C LANG=C bats test/signalloom-local-lifecycle.bats` passed 4/4.
- `env LC_ALL=C LANG=C make -C d2-signalloom test` passed 20/20.
- Bash syntax checks passed for active Signalloom and agent harness scripts.
- Proposal graph checks found P0 and P1 pre-flight dependency rows.
- `git diff --check` passed. `roborev` was unavailable, so AI review evidence
  was not available; manual diff review found only six targeted line changes.
