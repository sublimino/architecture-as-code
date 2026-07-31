---
task: Recover orphaned commits across active version branches
slug: 20260731-145000_recover-orphaned-commits-version-branches
effort: extended
phase: complete
progress: 16/16
mode: interactive
started: 2026-07-31T14:50:00+01:00
updated: 2026-07-31T14:54:20+01:00
---

## Context

Andrew asked to recover orphaned commits relevant to the main 2.5 branch and the latest active feature branch, which should be at parity with `integration/signalloom-d2-v2.5.0`. The operation must identify the intended branches and commit set before changing Git history. Existing local changes must be preserved; no reset, force-push, or unrelated recovery is permitted.

Andrew clarified that recovered behavior must be available in `/home/andy/src/cp/osramp-demo` on `feat/signal-loop-and-bootstrap-refactor` for local testing. Cherry-picking is optional; the required outcome is relevant D2 behavior patched, verified across necessary paths, and committed on that feature branch.

### Risks

- A candidate commit can be intentionally abandoned or superseded.
- An active worktree can contain uncommitted user work.
- Two target branches may need different commits despite desired parity.
- Cherry-picking can conflict with intervening integration changes.

## Criteria

- [x] ISC-1: Local branches matching version 2.5 are identified.
- [x] ISC-2: Integration branch ref is resolved to a commit.
- [x] ISC-3: Active worktrees are mapped to checked-out branch refs.
- [x] ISC-4: Latest feature branch candidate is identified using commit recency.
- [x] ISC-5: Working-tree changes are recorded before Git mutation.
- [x] ISC-6: Unreachable commits are enumerated using Git fsck.
- [x] ISC-7: Dangling commits are classified by changed-path relevance.
- [x] ISC-8: Already-reachable dangling commits are excluded from restoration.
- [x] ISC-9: Recovered candidates are checked against integration ancestry.
- [x] ISC-10: Recovered candidates are inspected for patch applicability.
- [x] ISC-11: Target branch owners are identified before branch mutation.
- [x] ISC-12: Integration branch receives only approved recoverable commits.
- [x] ISC-13: Feature branch receives intended parity commits.
- [x] ISC-14: Target branch heads are recorded after reconciliation.
- [x] ISC-15: Branch parity is verified using ancestry comparison.
- [x] ISC-16: Final report lists restored commits and exclusions.

## Decisions

- Use evidence-based cherry-picks or merges; never reset branch history.
- Treat unrelated dangling commits as forensic evidence, not restoration candidates.
- Local integration and `feat/signal-loop-and-bootstrap-refactor` already share `0d250f0` exactly.
- Do not cherry-pick into the dirty integration worktree without Andrew's direction.
- Recover only evidence-backed missing D2 behavior into the requested feature branch.

## Verification

- ISC-1–4: Local refs identify `integration/signalloom-d2-v2.5.0` and `feat/signal-loop-and-bootstrap-refactor` at `0d250f0`.
- ISC-5: Root user changes were recorded and left untouched.
- ISC-6–11: 206 unreachable commits were classified; meaningful candidate diffs were compared against feature behavior and path blobs.
- ISC-12: No source commit qualified for recovery; therefore integration received no unnecessary commit.
- ISC-13–15: Feature and integration refs have `0/0` divergence at identical `0d250f0` tips.
- ISC-16: Six candidate commits were excluded as superseded, duplicate, or in-flight snapshots; no source restoration was required.
- Relevant static D2 validation passed for SPIRE/Bao and Dex/OIDC checks. One existing gateway-routing assertion failed; isolated Python and dashboard test commands were blocked by local plugin and sparse-checkout constraints.
- Capability check: two explore agents and two Engineer agents were invoked for independent topology and behavioral-diff evidence.
