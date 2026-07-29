---
task: Baseline dashboard journeys and Playwright coverage evidence
slug: 20260727-142300_dashboard-journey-playwright-baseline
effort: extended
phase: complete
progress: 16/16
mode: interactive
started: 2026-07-27T14:23:00+01:00
updated: 2026-07-27T14:35:00+01:00
---

## Context

Implement SLDPB25-P1-1 only in the mandated integration worktree. The card
requires a complete dashboard journey inventory, coverage mapping, initial
Playwright baseline for login through scan results, baseline run evidence,
proposal errata, and one isolated commit. Existing journey documentation and
test files may be prior partial work; this run validates them against the
actual source and records the current baseline rather than assuming they meet
the contract. Do not change board metadata, sibling worktrees, remotes, or PR
state.

### Risks

- Existing files can describe an older dashboard surface while source has changed.
- Browser tests can produce misleading failures if the local broker or Chrome prerequisite is absent.
- The target worktree can contain unrelated staged or untracked artifacts that must not enter the card commit.
- The listed base reference can be stale or absent locally, preventing ancestry proof.

## Criteria

- [x] ISC-1: Mandated worktree resolves to requested integration repository root
- [x] ISC-2: HEAD descends from requested integration base reference
- [x] ISC-3: Journey matrix lists dashboard root navigation
- [x] ISC-4: Journey matrix lists every implemented dashboard window
- [x] ISC-5: Journey matrix lists each broker API consumer journey
- [x] ISC-6: Journey matrix identifies documented authentication boundary
- [x] ISC-7: Journey matrix maps critical paths to test files
- [x] ISC-8: Login browser test states its required live dependency
- [x] ISC-9: Dashboard browser test asserts launcher rendering
- [x] ISC-10: Scan initiation browser test observes request payload
- [x] ISC-11: Results browser test asserts flagged verdict rendering
- [x] ISC-12: Baseline browser command records deterministic run output
- [x] ISC-13: Baseline failure evidence identifies runtime prerequisite status
- [x] ISC-14: Proposal errata records baseline observations precisely
- [x] ISC-15: No board metadata file receives modification
- [x] ISC-16: Commit contains documented card artifacts only

## Decisions

- 2026-07-27 14:25: Treat existing dashboard artifacts as unverified baseline evidence until source, test execution, ancestry, and commit history confirm their state.
- 2026-07-27 14:32: Corrected the matrix's WebSocket verb and incident-detail consumer attribution after source reconciliation.

## Verification

- ISC-1: `git rev-parse --show-toplevel` returned the mandated Governor integration worktree.
- ISC-2: `git merge-base --is-ancestor refs/heads/integration/signalloom-d2-v2.5.0 HEAD` exited `0`.
- ISC-3: Matrix records the `/` dashboard root and Read Me entry.
- ISC-4: Matrix lists 14 source-registered Estate95 windows.
- ISC-5: Matrix records broker API consumers and failure states; terminal is correctly labelled WebSocket.
- ISC-6: Matrix identifies Dex `/dex/auth` ownership and absent broker session middleware.
- ISC-7: Critical flow table maps login, dashboard, scan, and results to exact specs.
- ISC-8: Login row states the live Dex and integrated API dependency.
- ISC-9: `dashboard-journey.spec.ts` asserts the Security Sandbox launcher.
- ISC-10: `dashboard-journey.spec.ts` captures the selected request payload.
- ISC-11: `dashboard-journey.spec.ts` asserts verdict, scanner, and sanitisation labels.
- ISC-12: `cd test/acceptance && bunx playwright test dashboard-journey.spec.ts` exited `0` with seven passing tests in 3.6 seconds.
- ISC-13: `curl --fail http://127.0.0.1:8675/` exited `0`, proving the local broker prerequisite was available.
- ISC-14: `docs/plans/d2-bao-integration.md` records the baseline and reconciliation result.
- ISC-15: Board exclusion audit returned no `board.json` modifications or staged entries.
- ISC-16: Commit `cdb3e9c` contains only the journey matrix and proposal errata corrections.
