---
task: Inventory dashboard API contracts and commit evidence
slug: 20260726-230525_inventory-dashboard-api-contracts
effort: advanced
phase: execute
progress: 5/24
mode: interactive
started: 2026-07-26T23:05:25+01:00
updated: 2026-07-26T23:45:25+01:00
token_estimate: 32000
continuation_token_estimate: 12000
iteration: 3
---

## Context

Inventory every dashboard HTTP call and its response type in the isolated Signalloom Governor worktree. Map each call to an existing local handler, adapter, persistence layer, or explicit waiver; add contract fixtures where the repository's existing test conventions support them; run the relevant tests; commit only repository changes; and append machine-readable Kanban evidence to the supplied Obsidian proposal. Do not edit `board.json`, another worktree, integration branch history, remotes, or create a PR. Integration ancestry must be checked before repository changes. The target card is `SLDPB25-P1-2`.

### Risks

- Dashboard source may be absent from this worktree, requiring an explicit waiver rather than inferred ownership.
- Existing contract-test conventions may be shell/BATS rather than application-unit fixtures.
- The checked-out Governor branch may not descend from the integration ref, blocking safe changes.
- Proposal is Obsidian-managed; errata must be appended through an Obsidian-safe writer.

### Plan

1. Verify worktree identity, clean baseline, integration reference, and ancestry.
2. Trace dashboard request call sites, response types, local service locations, and test harness patterns in parallel.
3. Add a reviewable endpoint inventory and contract fixtures using the discovered native format.
4. Run focused validation and relevant project tests; collect commands and exact exit codes.
5. Review, commit, then append proposal errata through the Obsidian CLI and verify its marker.

## Criteria

- [x] ISC-1: Target worktree resolves to the requested Governor repository.
- [x] ISC-2: Integration branch reference exists in target repository.
- [ ] ISC-3: Current commit descends from integration branch reference.
- [ ] ISC-4: Dashboard source locations are identified from repository references.
- [ ] ISC-5: Dashboard client HTTP calls are enumerated in inventory artifact.
- [ ] ISC-6: Each inventory row records an HTTP method.
- [ ] ISC-7: Each inventory row records a request path.
- [ ] ISC-8: Each inventory row records a response type.
- [ ] ISC-9: Each inventory row records a local ownership classification.
- [ ] ISC-10: Handler classifications name a local handler location.
- [ ] ISC-11: Adapter classifications name a local adapter location.
- [ ] ISC-12: Persistence classifications name a local persistence location.
- [ ] ISC-13: Waiver classifications state a concrete deferral reason.
- [ ] ISC-14: Inventory distinguishes implemented calls from deferred calls.
- [ ] ISC-15: Contract fixture format follows existing repository test conventions.
- [ ] ISC-16: Fixture covers at least one implemented dashboard response shape.
- [ ] ISC-17: Fixture covers at least one waived dashboard contract gap.
- [ ] ISC-18: Contract test command executes the new fixture coverage.
- [ ] ISC-19: Static validation command exits successfully for changed artifacts.
- [ ] ISC-20: Relevant project test command has recorded exit status.
- [x] ISC-21: Repository diff excludes board.json modifications.
- [ ] ISC-22: Repository changes are committed on the isolated branch.
- [x] ISC-23: Proposal errata contains machine-readable kanban-check status.
- [x] ISC-24: Proposal errata records commands, exits, and commit SHA.

## Decisions

- 2026-07-26 23:06: Use a committed inventory plus repository-native fixture format, avoiding speculative API implementation beyond this card.
- 2026-07-26 23:08: Stop before scoped repository changes because target HEAD is not descended from the required integration ref.
- 2026-07-26 23:21: Continuation recheck confirmed the same ancestry blocker; execution remains prohibited.

## Verification

- ISC-1: `git rev-parse --show-toplevel` returned the requested Governor path.
- ISC-2: `git show-ref --verify --quiet refs/heads/integration/signalloom-d2-v2.5.0` exited 0.
- ISC-3: `git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 HEAD` exited 1; this criterion failed and blocks execution.
- ISC-21: Baseline status did not list `board.json`; no scoped modifications were made after ancestry check.
- ISC-23: Obsidian CLI appended JSON `kanban-check` failure evidence to the supplied proposal.
- ISC-24: Errata records commands, exits, HEAD SHA, and no-commit status.
- ISC-3 continuation: reference `c95ac2f02c1fe73adfed9af9ed7f815f3254ee2a` remains non-ancestor of HEAD `4bdfc2912b1d75fa73baa5fe58893817a4b47e3e` (exit 1).
